using PalCalc.Model;
using PalCalc.SaveReader;
using PalCalc.SaveReader.SaveFile;
using PalCalc.Solver;
using PalCalc.Solver.PalReference;
using PalCalc.Solver.Probabilities;
using PalCalc.Solver.ResultPruning;
using System.Security.Cryptography;
using System.Text;

namespace PalworldMcpServer;

internal sealed record PlanCacheKey(
    string CacheFormatVersion,
    string DatabaseVersion,
    string SaveAlias,
    string BreedingInputFingerprint,
    long CacheGeneration,
    string PlayerId,
    string TargetSpecies,
    string RequiredPassives,
    string OptionalPassives,
    int MinimumHpIv,
    int MinimumAttackIv,
    int MinimumDefenseIv,
    string Locations,
    bool AllowWildPals,
    bool AllowSurgery,
    int MaximumBreedingSteps,
    int MaximumResults,
    string SearchMode
);

internal sealed record PlanSearchSummary(
    string Mode,
    int RequestedMaximumBreedingSteps,
    int SearchedMaximumBreedingSteps,
    int Attempts
);

internal sealed record PlanCacheSummary(
    bool Hit,
    string Source,
    PlanCacheStatistics Memory,
    PersistentPlanCacheStatistics Persistent
);

internal sealed record BreedingPlanResponse(
    string SaveAlias,
    DateTime SaveModifiedAt,
    DateTime ScannedAt,
    string DatabaseVersion,
    string PlayerId,
    object Target,
    IReadOnlyList<string> AllowedOwnedLocations,
    bool AllowWildPals,
    bool AllowSurgery,
    bool IsCanceled,
    IReadOnlyList<object> Plans,
    IReadOnlyList<string> Warnings,
    PlanSearchSummary Search,
    PlanCacheSummary Cache
);

public sealed record RaidReserveCandidate(
    string InstanceId,
    int Level,
    string Species,
    string Nickname
);

public sealed class PalworldService : IDisposable
{
    private static readonly string PlanCacheFormatVersion =
        $"1:{typeof(PalworldService).Assembly.GetName().Version}";
    private const int PlanCacheCapacity = 64;
    private readonly object loadLock = new();
    private readonly SemaphoreSlim solverGate = new(1, 1);
    private readonly BoundedPlanCache<PlanCacheKey, BreedingPlanResponse> planCache =
        new(PlanCacheCapacity);
    private readonly PalworldConfig config;
    private readonly PersistentPlanCache<PlanCacheKey, BreedingPlanResponse> persistentPlanCache;
    private PalDB? database;
    private PalBreedingDB? breedingDatabase;
    private ISaveGame? saveGame;
    private GlobalPalStorageSaveFile? globalStorage;
    private LevelSaveData? saveData;
    private DateTime scannedAtUtc;
    private DateTime snapshotModifiedAtUtc;
    private string? breedingInputFingerprint;
    private long planCacheGeneration;
    private IReadOnlyList<PlayerInstance> allowedPlayers = [];
    private IReadOnlyDictionary<string, IReadOnlyList<PalInstance>> palsByPlayer =
        new Dictionary<string, IReadOnlyList<PalInstance>>(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyDictionary<string, IReadOnlyDictionary<string, PalInstance>> palsByPlayerAndInstance =
        new Dictionary<string, IReadOnlyDictionary<string, PalInstance>>(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyDictionary<string, IReadOnlyList<Pal>> speciesByName =
        new Dictionary<string, IReadOnlyList<Pal>>(StringComparer.OrdinalIgnoreCase);
    private IReadOnlyDictionary<string, IReadOnlyList<PassiveSkill>> passivesByName =
        new Dictionary<string, IReadOnlyList<PassiveSkill>>(StringComparer.OrdinalIgnoreCase);

    public PalworldService()
    {
        config = PalworldConfig.Load();
        persistentPlanCache = new(
            config.PersistentPlanCacheEnabled,
            config.PersistentPlanCachePath,
            config.PersistentPlanCacheCapacity
        );
    }

    public object GetStatus()
    {
        try
        {
            EnsureLoaded();
            return new
            {
                ready = true,
                readOnly = true,
                transport = "stdio",
                palCalcVersion = "1.19.1",
                databaseVersion = database!.Version,
                saveAlias = SaveAlias,
                saveModifiedAt = snapshotModifiedAtUtc,
                scannedAt = scannedAtUtc,
                players = AllowedPlayers().Select(PlayerSummary),
                planCache = new
                {
                    memory = planCache.Statistics(),
                    persistent = persistentPlanCache.Statistics()
                },
                planCachePolicy = new
                {
                    scope = $"64-entry in-memory LRU backed by an optional {config.PersistentPlanCacheCapacity}-entry SQLite LRU",
                    eviction = "least-recently-used within each cache tier",
                    invalidationRules = new[]
                    {
                        "Explicit refresh always invalidates all plans.",
                        "A changed save invalidates plans only when owned breeding inputs change.",
                        "Breeding inputs include species, gender, passives, IVs, availability, and location.",
                        "Database, save, and cache-format versions are part of every persistent key.",
                        "Server restart clears memory while valid SQLite entries remain available."
                    }
                },
                limitations = new[]
                {
                    "The scan is a saved-state snapshot, not live game state.",
                    "Breeding probabilities are estimates, not guarantees.",
                    "PalCalc 1.19.1 does not expose player item inventory, so Surgery implants and currency cannot be verified.",
                    "Mutation, special-cake, and active-skill inheritance advice is disabled until explicitly modeled."
                }
            };
        }
        catch (Exception error)
        {
            return new
            {
                ready = false,
                readOnly = true,
                palCalcVersion = "1.19.1",
                error = error.Message,
                setup = "Set SavePath in palworld-mcp.local.json or install a local Steam/Xbox Palworld save."
            };
        }
    }

    public object ListPlayers()
    {
        EnsureLoaded();
        return new
        {
            saveAlias = SaveAlias,
            saveModifiedAt = snapshotModifiedAtUtc,
            scannedAt = scannedAtUtc,
            players = AllowedPlayers().Select(PlayerSummary)
        };
    }

    public object ListBaseRosters()
    {
        EnsureLoaded();
        var bases = AllowedPlayers()
            .SelectMany(player => PalsForPlayer(player.PlayerId)
                .Where(p => p.Location.Type.ToString() == "Base")
                .Where(p => !string.IsNullOrWhiteSpace(p.Location.ContainerId))
                .Select(p => new { player.PlayerId, Pal = p }))
            .GroupBy(
                entry => new
                {
                    entry.PlayerId,
                    ContainerId = entry.Pal.Location.ContainerId
                }
            )
            .Select(group => new
            {
                playerId = group.Key.PlayerId,
                containerId = group.Key.ContainerId,
                occupiedCount = group.Count(),
                occupiedSlots = group
                    .Select(entry => entry.Pal.Location.Index)
                    .Distinct()
                    .OrderBy(index => index)
            })
            .OrderBy(baseRoster => baseRoster.playerId)
            .ThenBy(baseRoster => baseRoster.containerId)
            .ToList();

        return new
        {
            saveAlias = SaveAlias,
            saveModifiedAt = snapshotModifiedAtUtc,
            scannedAt = scannedAtUtc,
            baseCount = bases.Count,
            bases
        };
    }

    public object ScanOwnedPals(
        string playerId,
        string[]? locations,
        string? species,
        string? passive,
        int? minimumHpIv,
        int? minimumAttackIv,
        int? minimumDefenseIv,
        int offset,
        int? limit
    )
    {
        EnsureLoaded();
        EnsurePlayerAllowed(playerId);

        var allowedLocations = (locations is { Length: > 0 } ? locations : ["Palbox"])
            .Select(ParseLocation)
            .ToHashSet();
        var pageSize = Math.Clamp(limit ?? config.DefaultPageSize, 1, config.MaximumPageSize);

        var query = PalsForPlayer(playerId)
            .Where(p => allowedLocations.Contains(p.Location.Type))
            .Where(p => string.IsNullOrWhiteSpace(species) ||
                        p.Pal.Name.Contains(species, StringComparison.OrdinalIgnoreCase) ||
                        p.Pal.InternalName.Contains(species, StringComparison.OrdinalIgnoreCase))
            .Where(p => string.IsNullOrWhiteSpace(passive) ||
                        p.PassiveSkills.Any(s =>
                            s.Name.Contains(passive, StringComparison.OrdinalIgnoreCase) ||
                            s.InternalName.Contains(passive, StringComparison.OrdinalIgnoreCase)))
            .Where(p => p.IV_HP >= (minimumHpIv ?? 0))
            .Where(p => p.IV_Attack >= (minimumAttackIv ?? 0))
            .Where(p => p.IV_Defense >= (minimumDefenseIv ?? 0))
            .OrderBy(p => p.Pal.Name)
            .ThenBy(p => p.Location.Type)
            .ThenBy(p => p.Location.Index)
            .ToList();

        return new
        {
            saveAlias = SaveAlias,
            saveModifiedAt = snapshotModifiedAtUtc,
            scannedAt = scannedAtUtc,
            playerId,
            total = query.Count,
            offset,
            limit = pageSize,
            nextOffset = offset + pageSize < query.Count ? offset + pageSize : (int?)null,
            pals = query.Skip(Math.Max(0, offset)).Take(pageSize).Select(NormalizePal)
        };
    }

    public object GetOwnedPal(string playerId, string instanceId)
    {
        EnsureLoaded();
        EnsurePlayerAllowed(playerId);
        var pal = ResolveOwnedPal(playerId, instanceId);

        return new
        {
            saveAlias = SaveAlias,
            saveModifiedAt = snapshotModifiedAtUtc,
            scannedAt = scannedAtUtc,
            pal = NormalizePal(pal)
        };
    }

    public IReadOnlyList<RaidReserveCandidate> GetRaidReserveCandidates(
        string? playerId = null
    )
    {
        EnsureLoaded();
        var selectedPlayerId = playerId?.Trim();
        if (string.IsNullOrWhiteSpace(selectedPlayerId))
        {
            var players = AllowedPlayers().ToArray();
            if (players.Length != 1)
            {
                throw new ArgumentException(
                    "playerId is required when more than one allowed player is available."
                );
            }
            selectedPlayerId = players[0].PlayerId;
        }
        EnsurePlayerAllowed(selectedPlayerId);
        return PalsForPlayer(selectedPlayerId)
            .Where(pal => pal.Location.Type == LocationType.Palbox)
            .OrderByDescending(pal => pal.Level)
            .ThenBy(pal => pal.InstanceId, StringComparer.OrdinalIgnoreCase)
            .Select(pal => new RaidReserveCandidate(
                ToLiveGuid(pal.InstanceId),
                pal.Level,
                pal.Pal.Name,
                pal.NickName
            ))
            .ToArray();
    }

    internal static string ToLiveGuid(string instanceId)
    {
        var parts = instanceId.Trim().Split('-');
        if (
            parts.Length == 5 &&
            parts[0].Length == 8 &&
            parts[1].Length == 4 &&
            parts[2].Length == 4 &&
            parts[3].Length == 4 &&
            parts[4].Length == 12 &&
            parts.All(part => part.All(Uri.IsHexDigit))
        )
        {
            return string.Concat(
                parts[0], "-",
                parts[1], parts[2], "-",
                parts[3], parts[4][..4], "-",
                parts[4][4..]
            ).ToUpperInvariant();
        }
        return instanceId.Trim().ToUpperInvariant();
    }

    public object GetSpecies(string name)
    {
        EnsureLoaded();
        var matches = database!.Pals
            .Where(p => p.Name.Equals(name, StringComparison.OrdinalIgnoreCase) ||
                        p.InternalName.Equals(name, StringComparison.OrdinalIgnoreCase))
            .ToList();
        if (matches.Count == 0)
        {
            matches = database.Pals
                .Where(p => p.Name.Contains(name, StringComparison.OrdinalIgnoreCase) ||
                            p.InternalName.Contains(name, StringComparison.OrdinalIgnoreCase))
                .Take(20)
                .ToList();
        }

        return new
        {
            databaseVersion = database.Version,
            matches = matches.Select(p => new
            {
                internalName = p.InternalName,
                name = p.Name,
                paldeckId = p.Id.ToString(),
                p.BreedingPower,
                p.Hp,
                p.Attack,
                p.Defense,
                p.CraftSpeed,
                p.TransportSpeed,
                p.Nocturnal,
                workSuitability = p.WorkSuitability,
                guaranteedPassives = p.GuaranteedPassiveSkills(database).Select(s => s.Name),
                genderProbability = database.BreedingGenderProbability[p]
            })
        };
    }

    public string ResolveSpeciesDisplayName(string? internalName)
    {
        if (string.IsNullOrWhiteSpace(internalName))
        {
            return "";
        }

        EnsureLoaded();
        var match = database!.Pals.FirstOrDefault(
            pal => pal.InternalName.Equals(
                internalName.Trim(),
                StringComparison.OrdinalIgnoreCase
            )
        );
        return match?.Name ?? internalName.Trim();
    }

    public object SearchPassives(string query, int limit)
    {
        EnsureLoaded();
        var cappedLimit = Math.Clamp(limit, 1, 100);
        var matches = database!.StandardPassiveSkills
            .Where(p => p.Name.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                        p.InternalName.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                        (p.Description?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false))
            .OrderByDescending(p => p.Rank)
            .ThenBy(p => p.Name)
            .Take(cappedLimit)
            .Select(p => new
            {
                p.Name,
                p.InternalName,
                p.Rank,
                p.Description,
                p.RandomInheritanceAllowed,
                p.RandomInheritanceWeight,
                p.SupportsSurgery,
                p.SurgeryCost,
                p.SurgeryRequiredItem,
                effects = p.TrackedEffects
            });

        return new { databaseVersion = database.Version, matches };
    }

    public object FindBreedingPlan(
        string playerId,
        string targetSpecies,
        string[] requiredPassives,
        string[]? optionalPassives,
        int minimumHpIv,
        int minimumAttackIv,
        int minimumDefenseIv,
        string[]? locations,
        bool allowWildPals,
        bool allowSurgery,
        int maxBreedingSteps,
        int maxResults,
        string searchMode,
        CancellationToken cancellationToken
    )
    {
        solverGate.Wait(cancellationToken);
        try
        {
            EnsureLoaded();
            EnsurePlayerAllowed(playerId);

            var targetPal = ResolveSpecies(targetSpecies);
            var required = requiredPassives.Select(ResolvePassive).Distinct().ToList();
            var optional = (optionalPassives ?? [])
                .Select(ResolvePassive)
                .Except(required)
                .Distinct()
                .ToList();
            if (required.Count > GameConstants.MaxTotalPassives)
            {
                throw new ArgumentException($"At most {GameConstants.MaxTotalPassives} required passives are supported.");
            }

            var allowedLocations = (locations is { Length: > 0 } ? locations : ["Palbox"])
                .Select(ParseLocation)
                .ToHashSet();
            var owned = PalsForPlayer(playerId)
                .Where(p => allowedLocations.Contains(p.Location.Type))
                .ToList();
            var target = new PalSpecifier
            {
                Pal = targetPal,
                RequiredPassives = required,
                OptionalPassives = optional,
                IV_HP = Math.Clamp(minimumHpIv, 0, 100),
                IV_Attack = Math.Clamp(minimumAttackIv, 0, 100),
                IV_Defense = Math.Clamp(minimumDefenseIv, 0, 100)
            };

            var normalizedSearchMode = searchMode.Trim().ToLowerInvariant();
            if (normalizedSearchMode is not ("fast" or "exhaustive"))
            {
                throw new ArgumentException("Search mode must be 'fast' or 'exhaustive'.");
            }

            var requestedMaximumSteps = Math.Clamp(maxBreedingSteps, 0, 8);
            var cappedResults = Math.Clamp(maxResults, 1, 10);
            var cacheKey = new PlanCacheKey(
                CacheFormatVersion: PlanCacheFormatVersion,
                DatabaseVersion: database!.Version,
                SaveAlias: SaveAlias,
                BreedingInputFingerprint: breedingInputFingerprint!,
                CacheGeneration: planCacheGeneration,
                PlayerId: playerId.ToLowerInvariant(),
                TargetSpecies: targetPal.InternalName,
                RequiredPassives: string.Join(",", required.Select(p => p.InternalName).Order()),
                OptionalPassives: string.Join(",", optional.Select(p => p.InternalName).Order()),
                MinimumHpIv: target.IV_HP,
                MinimumAttackIv: target.IV_Attack,
                MinimumDefenseIv: target.IV_Defense,
                Locations: string.Join(",", allowedLocations.Order().Select(location => location.ToString())),
                AllowWildPals: allowWildPals,
                AllowSurgery: allowSurgery,
                MaximumBreedingSteps: requestedMaximumSteps,
                MaximumResults: cappedResults,
                SearchMode: normalizedSearchMode
            );

            if (planCache.TryGet(cacheKey, out var cached))
            {
                return cached! with
                {
                    SaveModifiedAt = snapshotModifiedAtUtc,
                    ScannedAt = scannedAtUtc,
                    Cache = CacheSummary(hit: true, source: "memory")
                };
            }

            if (persistentPlanCache.TryGet(cacheKey, out var persisted))
            {
                var restored = persisted! with
                {
                    SaveModifiedAt = snapshotModifiedAtUtc,
                    ScannedAt = scannedAtUtc
                };
                planCache.Set(cacheKey, restored);
                return restored with
                {
                    Cache = CacheSummary(hit: true, source: "sqlite")
                };
            }

            var activeBreedingDatabase = GetBreedingDatabase();
            IEnumerable<int> searchDepths = normalizedSearchMode == "fast"
                ? Enumerable.Range(0, Math.Min(requestedMaximumSteps, 2) + 1)
                : [requestedMaximumSteps];
            var plans = new List<object>();
            var isCanceled = false;
            var attempts = 0;
            var searchedMaximumSteps = 0;

            foreach (var searchDepth in searchDepths)
            {
                cancellationToken.ThrowIfCancellationRequested();
                attempts++;
                searchedMaximumSteps = searchDepth;

                var settings = new BreedingSolverSettings(
                    db: database!,
                    breedingDB: activeBreedingDatabase,
                    gameSettings: GameSettings.Defaults,
                    ownedPals: owned,
                    resultPruning: ResultPruningPolicy.Default,
                    maxBreedingSteps: searchDepth,
                    maxSolverIterations: Math.Clamp(searchDepth + 2, 2, 10),
                    maxWildPals: allowWildPals ? 2 : 0,
                    allowedWildPals: allowWildPals ? database!.Pals : [],
                    bannedBredPals: [],
                    maxInputIrrelevantPassives: normalizedSearchMode == "fast" ? 2 : 4,
                    maxBredIrrelevantPassives: normalizedSearchMode == "fast" ? 1 : 2,
                    maxEffort: TimeSpan.FromDays(7),
                    maxThreads: 0,
                    maxSurgeryCost: allowSurgery ? 1_000_000 : 0,
                    allowedSurgeryPassives: allowSurgery ? database!.SurgeryPassiveSkills : [],
                    useGenderReversers: false
                );
                var result = new BreedingSolver().Solve(
                    new BreedingSolverRequest(target, settings),
                    new SolverStateController(cancellationToken)
                );
                isCanceled = result.IsCanceled;
                plans = result.Results
                    .OrderBy(candidate => candidate.BreedingEffort)
                    .Take(cappedResults)
                    .Select((candidate, index) => (object)new
                    {
                        rank = index + 1,
                        expectedEggs = candidate.NumTotalEggs,
                        breedingSteps = candidate.NumTotalBreedingSteps,
                        wildPals = candidate.NumTotalWildPals,
                        estimatedEffort = candidate.BreedingEffort,
                        totalSurgeryCost = candidate.TotalCost,
                        result = NormalizePlanNode(candidate)
                    })
                    .ToList();

                if (isCanceled || plans.Count > 0)
                {
                    break;
                }
            }

            var warnings = new List<string>
            {
                "Expected eggs and effort are probabilistic estimates.",
                "Mutation, special-cake, and active-skill inheritance are not optimized in this plan."
            };
            if (allowSurgery)
            {
                warnings.Add(
                    "Surgery item and currency availability are not validated because PalCalc's character snapshot does not expose player inventory."
                );
            }
            if (normalizedSearchMode == "fast" && plans.Count == 0)
            {
                warnings.Add(
                    $"Fast mode found no plan through {searchedMaximumSteps} breeding steps. " +
                    "Retry with searchMode='exhaustive' for broader passive inputs or a deeper search."
                );
            }
            else if (normalizedSearchMode == "fast")
            {
                warnings.Add(
                    "Fast mode stops at the first generation depth with a valid plan. " +
                    "Exhaustive mode may find a lower-effort plan at a deeper generation."
                );
            }

            var response = new BreedingPlanResponse(
                SaveAlias: SaveAlias,
                SaveModifiedAt: snapshotModifiedAtUtc,
                ScannedAt: scannedAtUtc,
                DatabaseVersion: database!.Version,
                PlayerId: playerId,
                Target: new
                {
                    species = new { targetPal.Name, targetPal.InternalName },
                    requiredPassives = required.Select(p => p.Name),
                    optionalPassives = optional.Select(p => p.Name),
                    minimumIvs = new { hp = target.IV_HP, attack = target.IV_Attack, defense = target.IV_Defense }
                },
                AllowedOwnedLocations: allowedLocations.Select(location => location.ToString()).ToList(),
                AllowWildPals: allowWildPals,
                AllowSurgery: allowSurgery,
                IsCanceled: isCanceled,
                Plans: plans,
                Warnings: warnings,
                Search: new PlanSearchSummary(
                    Mode: normalizedSearchMode,
                    RequestedMaximumBreedingSteps: requestedMaximumSteps,
                    SearchedMaximumBreedingSteps: searchedMaximumSteps,
                    Attempts: attempts
                ),
                Cache: CacheSummary(hit: false, source: "solver")
            );

            if (!isCanceled)
            {
                planCache.Set(cacheKey, response);
                persistentPlanCache.Set(cacheKey, response);
                response = response with
                {
                    Cache = CacheSummary(hit: false, source: "solver")
                };
            }

            return response;
        }
        finally
        {
            solverGate.Release();
        }
    }

    public object EstimateInheritance(
        string playerId,
        string parent1InstanceId,
        string parent2InstanceId,
        string[] desiredPassives,
        bool allowExtraPassives
    )
    {
        EnsureLoaded();
        EnsurePlayerAllowed(playerId);
        var parent1 = ResolveOwnedPal(playerId, parent1InstanceId);
        var parent2 = ResolveOwnedPal(playerId, parent2InstanceId);
        if (parent1.Gender == parent2.Gender)
        {
            throw new ArgumentException("The selected parents have the same gender and cannot breed without changing one parent.");
        }

        var desired = desiredPassives.Select(ResolvePassive).Distinct().ToList();
        var parentPool = parent1.PassiveSkills.Concat(parent2.PassiveSkills).Distinct().ToList();
        var missing = desired.Except(parentPool).ToList();
        if (missing.Count > 0)
        {
            return new
            {
                possible = false,
                reason = "One or more desired passives are absent from both parents.",
                missingPassives = missing.Select(p => p.Name),
                parentPool = parentPool.Select(p => p.Name)
            };
        }

        var breeding = GetBreedingDatabase().BreedingByParent
            .GetValueOrDefault(parent1.Pal)?
            .GetValueOrDefault(parent2.Pal)?
            .FirstOrDefault(result => result.Matches(parent1.Pal, parent1.Gender, parent2.Pal, parent2.Gender))
            ?? throw new InvalidOperationException("No breeding result exists for the selected parent species and genders.");

        var finalCounts = allowExtraPassives
            ? Enumerable.Range(Math.Max(1, desired.Count), GameConstants.MaxTotalPassives - Math.Max(1, desired.Count) + 1)
            : [desired.Count];
        var passiveProbability = finalCounts.Sum(count =>
            Passives.ProbabilityInheritedTargetPassives(
                database!.BreedingMechanics,
                parentPool,
                desired,
                count
            )
        );

        return new
        {
            possible = passiveProbability > 0,
            databaseVersion = database!.Version,
            child = new { breeding.Child.Name, breeding.Child.InternalName },
            parent1 = new
            {
                instanceId = parent1.InstanceId,
                species = parent1.Pal.Name,
                gender = parent1.Gender.ToString(),
                passives = parent1.PassiveSkills.Select(p => p.Name)
            },
            parent2 = new
            {
                instanceId = parent2.InstanceId,
                species = parent2.Pal.Name,
                gender = parent2.Gender.ToString(),
                passives = parent2.PassiveSkills.Select(p => p.Name)
            },
            desiredPassives = desired.Select(p => p.Name),
            irrelevantParentPassives = parentPool.Except(desired).Select(p => p.Name),
            allowExtraPassives,
            passiveProbability,
            expectedEggs = passiveProbability <= 0 ? (int?)null : (int)Math.Ceiling(1.0 / passiveProbability),
            warning = "This estimate covers passive inheritance only. Use plan_breeding for combined passive and IV estimates."
        };
    }

    public object Refresh(CancellationToken cancellationToken = default)
    {
        solverGate.Wait(cancellationToken);
        try
        {
            lock (loadLock)
            {
                ClearSnapshotNoLock();
                InvalidatePlanCacheNoLock("explicit_refresh");
            }
            EnsureLoaded();
            return GetStatus();
        }
        finally
        {
            solverGate.Release();
        }
    }

    private void EnsureLoaded()
    {
        lock (loadLock)
        {
            if (database == null)
            {
                database = PalDB.LoadEmbedded();
                BuildMetadataIndexesNoLock();
            }
            if (saveData == null)
            {
                LoadSnapshotNoLock();
                return;
            }

            if (SourceModifiedAtUtc() != snapshotModifiedAtUtc)
            {
                var previousFingerprint = breedingInputFingerprint;
                ClearSnapshotNoLock();
                LoadSnapshotNoLock();
                if (!string.Equals(
                    previousFingerprint,
                    breedingInputFingerprint,
                    StringComparison.Ordinal
                ))
                {
                    InvalidatePlanCacheNoLock("breeding_inputs_changed");
                }
            }
        }
    }

    private void LoadSnapshotNoLock()
    {
        (saveGame, globalStorage) = SelectSave();
        saveData = saveGame.Level.ReadCharacterData(
            database!,
            GameSettings.Defaults,
            saveGame.Players,
            globalStorage
        );
        snapshotModifiedAtUtc = SourceModifiedAtUtc();
        scannedAtUtc = DateTime.UtcNow;
        BuildSnapshotIndexesNoLock();
        breedingInputFingerprint = ComputeBreedingInputFingerprint();
    }

    private void ClearSnapshotNoLock()
    {
        saveData = null;
        allowedPlayers = [];
        palsByPlayer = new Dictionary<string, IReadOnlyList<PalInstance>>(StringComparer.OrdinalIgnoreCase);
        palsByPlayerAndInstance =
            new Dictionary<string, IReadOnlyDictionary<string, PalInstance>>(StringComparer.OrdinalIgnoreCase);
        globalStorage = null;
        saveGame?.Dispose();
        saveGame = null;
    }

    private void InvalidatePlanCacheNoLock(string reason)
    {
        planCacheGeneration++;
        planCache.Invalidate(reason);
        persistentPlanCache.Invalidate();
    }

    private string ComputeBreedingInputFingerprint()
    {
        var content = new StringBuilder();
        var allowedOwnerIds = allowedPlayers
            .Select(player => player.PlayerId)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var pal in palsByPlayer.Values.SelectMany(pals => pals)
            .Where(p => allowedOwnerIds.Contains(p.OwnerPlayerId))
            .OrderBy(p => p.InstanceId, StringComparer.Ordinal))
        {
            content
                .Append(pal.OwnerPlayerId).Append('|')
                .Append(pal.InstanceId).Append('|')
                .Append(pal.Pal.InternalName).Append('|')
                .Append(pal.Gender).Append('|')
                .Append(pal.IV_HP).Append('|')
                .Append(pal.IV_Attack).Append('|')
                .Append(pal.IV_Defense).Append('|')
                .Append(pal.Location.Type).Append('|')
                .Append(pal.Location.ContainerId).Append('|')
                .Append(pal.Location.Index).Append('|')
                .Append(pal.IsOnExpedition).Append('|');

            foreach (var passive in pal.PassiveSkills.OrderBy(
                p => p.InternalName,
                StringComparer.Ordinal
            ))
            {
                content.Append(passive.InternalName).Append(',');
            }
            content.AppendLine();
        }

        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(content.ToString())));
    }

    private DateTime SourceModifiedAtUtc()
    {
        var saveModifiedAt = saveGame?.LastModified.ToUniversalTime() ?? DateTime.MinValue;
        var globalModifiedAt = globalStorage?.LastModified.ToUniversalTime() ?? DateTime.MinValue;
        return saveModifiedAt >= globalModifiedAt ? saveModifiedAt : globalModifiedAt;
    }

    private (ISaveGame Save, GlobalPalStorageSaveFile? GlobalStorage) SelectSave()
    {
        if (!string.IsNullOrWhiteSpace(config.SavePath))
        {
            var fullPath = Path.GetFullPath(Environment.ExpandEnvironmentVariables(config.SavePath));
            var save = new StandardSaveGame(fullPath);
            if (!save.IsValid)
            {
                save.Dispose();
                throw new InvalidOperationException($"The configured save folder is not a valid Palworld save: {fullPath}");
            }

            var userRoot = Directory.GetParent(fullPath)?.FullName;
            var global = userRoot == null ? null : new DirectSavesLocation(userRoot).GlobalPalStorage;
            return (save, global);
        }

        var candidates = new List<(ISaveGame Save, GlobalPalStorageSaveFile? GlobalStorage)>();
        foreach (var location in DirectSavesLocation.AllLocal.Cast<ISavesLocation>().Concat(XboxSavesLocation.FindAll()))
        {
            candidates.AddRange(location.ValidSaveGames.Select(save =>
                (Save: save, GlobalStorage: (GlobalPalStorageSaveFile?)location.GlobalPalStorage)
            ));
        }

        return candidates
            .OrderByDescending(candidate => candidate.Save.LastModified)
            .FirstOrDefault() is { Save: not null } selected
                ? selected
                : throw new InvalidOperationException("No valid local Palworld save was found.");
    }

    private IEnumerable<PlayerInstance> AllowedPlayers() => allowedPlayers;

    private void EnsurePlayerAllowed(string playerId)
    {
        if (!AllowedPlayers().Any(p => string.Equals(p.PlayerId, playerId, StringComparison.OrdinalIgnoreCase)))
        {
            throw new UnauthorizedAccessException($"Player '{playerId}' is not available or allowed.");
        }
    }

    private object PlayerSummary(PlayerInstance player)
    {
        var pals = PalsForPlayer(player.PlayerId);
        return new
        {
            playerId = player.PlayerId,
            name = player.Name,
            player.Level,
            totalPals = pals.Count,
            countsByLocation = pals.GroupBy(p => p.Location.Type.ToString())
                .ToDictionary(g => g.Key, g => g.Count())
        };
    }

    private static object NormalizePal(PalInstance pal)
    {
        var coordinate = PalDisplayCoord.FromLocation(GameSettings.Defaults, pal.Location);
        return new
        {
            instanceId = pal.InstanceId,
            ownerPlayerId = pal.OwnerPlayerId,
            species = new { internalName = pal.Pal.InternalName, name = pal.Pal.Name, paldeckId = pal.Pal.Id.ToString() },
            nickname = pal.NickName,
            pal.Level,
            gender = pal.Gender.ToString(),
            location = new
            {
                type = pal.Location.Type.ToString(),
                containerId = pal.Location.ContainerId,
                slotIndex = pal.Location.Index,
                page = coordinate.Tab,
                row = coordinate.Row,
                column = coordinate.Column
            },
            passives = pal.PassiveSkills.Select(p => new { p.Name, p.InternalName, p.Rank, p.Description }),
            activeSkills = pal.ActiveSkills.Select(s => s.Name),
            equippedActiveSkills = pal.EquippedActiveSkills.Select(s => s.Name),
            ivs = new { hp = pal.IV_HP, attack = pal.IV_Attack, defense = pal.IV_Defense },
            pal.Rank,
            pal.IsOnExpedition,
            workSuitability = pal.Pal.WorkSuitability
        };
    }

    private void BuildMetadataIndexesNoLock()
    {
        speciesByName = BuildLookup(
            database!.Pals,
            pal => [pal.Name, pal.InternalName]
        );
        passivesByName = BuildLookup(
            database.StandardPassiveSkills,
            passive => [passive.Name, passive.InternalName]
        );
    }

    private PalBreedingDB GetBreedingDatabase()
    {
        lock (loadLock)
        {
            return breedingDatabase ??= PalBreedingDB.LoadEmbedded(database!);
        }
    }

    private void BuildSnapshotIndexesNoLock()
    {
        allowedPlayers = saveData!.Players
            .Where(player =>
                config.AllowedPlayerIds.Length == 0 ||
                config.AllowedPlayerIds.Contains(player.PlayerId, StringComparer.OrdinalIgnoreCase)
            )
            .ToList();
        var allowedPlayerIds = allowedPlayers
            .Select(player => player.PlayerId)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var byPlayer = new Dictionary<string, IReadOnlyList<PalInstance>>(
            StringComparer.OrdinalIgnoreCase
        );
        var byPlayerAndInstance =
            new Dictionary<string, IReadOnlyDictionary<string, PalInstance>>(
                StringComparer.OrdinalIgnoreCase
            );
        foreach (var player in allowedPlayers)
        {
            var pals = saveData.Pals
                .Where(pal =>
                    allowedPlayerIds.Contains(pal.OwnerPlayerId) &&
                    string.Equals(
                        pal.OwnerPlayerId,
                        player.PlayerId,
                        StringComparison.OrdinalIgnoreCase
                    )
                )
                .ToList();
            byPlayer[player.PlayerId] = pals;
            byPlayerAndInstance[player.PlayerId] = pals.ToDictionary(
                pal => pal.InstanceId,
                StringComparer.OrdinalIgnoreCase
            );
        }

        palsByPlayer = byPlayer;
        palsByPlayerAndInstance = byPlayerAndInstance;
    }

    private static IReadOnlyDictionary<string, IReadOnlyList<T>> BuildLookup<T>(
        IEnumerable<T> values,
        Func<T, IEnumerable<string>> keys
    )
    {
        var mutable = new Dictionary<string, List<T>>(StringComparer.OrdinalIgnoreCase);
        foreach (var value in values)
        {
            foreach (var key in keys(value).Distinct(StringComparer.OrdinalIgnoreCase))
            {
                if (!mutable.TryGetValue(key, out var matches))
                {
                    matches = [];
                    mutable.Add(key, matches);
                }
                matches.Add(value);
            }
        }

        return mutable.ToDictionary(
            pair => pair.Key,
            pair => (IReadOnlyList<T>)pair.Value,
            StringComparer.OrdinalIgnoreCase
        );
    }

    private IReadOnlyList<PalInstance> PalsForPlayer(string playerId)
    {
        return palsByPlayer.GetValueOrDefault(playerId) ?? [];
    }

    private PlanCacheSummary CacheSummary(bool hit, string source)
    {
        return new(
            Hit: hit,
            Source: source,
            Memory: planCache.Statistics(),
            Persistent: persistentPlanCache.Statistics()
        );
    }

    private object NormalizePlanNode(IPalReference reference)
    {
        var common = new
        {
            species = new { reference.Pal.Name, reference.Pal.InternalName },
            gender = reference.Gender.ToString(),
            effectivePassives = reference.EffectivePassives.Select(p => p.Name),
            actualPassives = reference.ActualPassives.Select(p => p.Name),
            ivs = new
            {
                hp = reference.IVs.HP.ToString(),
                attack = reference.IVs.Attack.ToString(),
                defense = reference.IVs.Defense.ToString()
            },
            estimatedEffort = reference.BreedingEffort
        };

        return reference switch
        {
            OwnedPalReference owned => new
            {
                source = "owned",
                common,
                instanceId = owned.UnderlyingInstance.InstanceId,
                ownerPlayerId = owned.UnderlyingInstance.OwnerPlayerId,
                location = owned.UnderlyingInstance.Location.ToString()
            },
            BredPalReference bred => new
            {
                source = "bred",
                common,
                expectedEggsForStep = bred.AvgRequiredBreedings,
                passiveProbability = bred.PassivesProbability,
                ivProbability = bred.IVsProbability,
                parent1 = NormalizePlanNode(bred.Parent1),
                parent2 = NormalizePlanNode(bred.Parent2)
            },
            _ => new
            {
                source = reference.Location.GetType().Name,
                common,
                description = reference.ToString()
            }
        };
    }

    private Pal ResolveSpecies(string value)
    {
        var matches = speciesByName.GetValueOrDefault(value) ?? [];
        return matches.Count switch
        {
            1 => matches[0],
            0 => throw new KeyNotFoundException($"Unknown Pal species '{value}'. Use get_pal_species first."),
            _ => throw new ArgumentException($"Species '{value}' is ambiguous.")
        };
    }

    private PassiveSkill ResolvePassive(string value)
    {
        var matches = passivesByName.GetValueOrDefault(value) ?? [];
        return matches.Count switch
        {
            1 => matches[0],
            0 => throw new KeyNotFoundException($"Unknown passive '{value}'. Use search_passives first."),
            _ => throw new ArgumentException($"Passive '{value}' is ambiguous.")
        };
    }

    private PalInstance ResolveOwnedPal(string playerId, string instanceId)
    {
        return palsByPlayerAndInstance.GetValueOrDefault(playerId)?.GetValueOrDefault(instanceId)
            ?? throw new KeyNotFoundException($"No owned Pal instance '{instanceId}' was found for player '{playerId}'.");
    }

    private static LocationType ParseLocation(string value)
    {
        return value.Trim().ToLowerInvariant() switch
        {
            "palbox" => LocationType.Palbox,
            "party" or "playerparty" => LocationType.PlayerParty,
            "base" => LocationType.Base,
            "viewing_cage" or "viewingcage" => LocationType.ViewingCage,
            "dimensional_storage" or "dimensionalpalstorage" => LocationType.DimensionalPalStorage,
            "global_storage" or "globalpalstorage" => LocationType.GlobalPalStorage,
            _ => throw new ArgumentException($"Unknown Pal location '{value}'.")
        };
    }

    private string SaveAlias => saveGame == null ? "unloaded" : $"{saveGame.UserId}/{saveGame.GameId}";

    public void Dispose()
    {
        saveGame?.Dispose();
        persistentPlanCache.Dispose();
        solverGate.Dispose();
    }
}
