using System.ComponentModel;
using System.Text.Json;
using ModelContextProtocol.Server;

namespace PalworldMcpServer;

[McpServerToolType]
public sealed class PalworldTools(
    PalworldService service,
    LiveBridgeClient liveBridge
)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase
    };

    [McpServerTool(Name = "get_status", ReadOnly = true)]
    [Description("Report save freshness, players, cache state, and live-bridge readiness. Set refresh=true to discard caches and rescan the save first.")]
    public string GetStatus(
        bool refresh = false,
        CancellationToken cancellationToken = default
    ) => Serialize(new
    {
        save = refresh
            ? service.Refresh(cancellationToken)
            : service.GetStatus(),
        live = liveBridge.GetStatus()
    });

    [McpServerTool(Name = "search_pals", ReadOnly = true)]
    [Description("Search owned Pals by player, location, species, passive, IV thresholds, and pagination. Defaults to Palbox.")]
    public string SearchPals(
        [Description("Player ID returned by get_status.")] string playerId,
        string[]? locations = null,
        string? species = null,
        string? passive = null,
        int? minimumHpIv = null,
        int? minimumAttackIv = null,
        int? minimumDefenseIv = null,
        int offset = 0,
        int? limit = null
    ) => Serialize(service.ScanOwnedPals(
        playerId,
        locations,
        species,
        passive,
        minimumHpIv,
        minimumAttackIv,
        minimumDefenseIv,
        offset,
        limit
    ));

    [McpServerTool(Name = "get_pal", ReadOnly = true)]
    [Description("Return the complete normalized record for one owned Pal instance.")]
    public string GetPal(string playerId, string palId) =>
        Serialize(service.GetOwnedPal(playerId, palId));

    [McpServerTool(Name = "search_pal_data", ReadOnly = true)]
    [Description("Search reference metadata. kind must be species or passive.")]
    public string SearchPalData(
        [Description("species or passive")] string kind,
        string query,
        int limit = 20
    )
    {
        return kind.Trim().ToLowerInvariant() switch
        {
            "species" => Serialize(service.GetSpecies(query)),
            "passive" => Serialize(service.SearchPassives(query, limit)),
            _ => throw new ArgumentException(
                "kind must be 'species' or 'passive'."
            )
        };
    }

    [McpServerTool(Name = "plan_breeding", ReadOnly = true)]
    [Description("Resolve a requested role into passive and IV targets, then find ranked breeding, wild-capture, or Surgery plans.")]
    public string PlanBreeding(
        string playerId,
        string targetSpecies,
        [Description("attack, defense, combat_balanced, ranch_farming, base_worker, transport, or custom")] string role = "custom",
        string? workType = null,
        string[]? requiredPassives = null,
        string[]? optionalPassives = null,
        int? minimumIv = null,
        int? minimumHpIv = null,
        int? minimumAttackIv = null,
        int? minimumDefenseIv = null,
        string[]? locations = null,
        bool allowWildPals = false,
        bool allowSurgery = false,
        int maxBreedingSteps = 2,
        int maxResults = 3,
        [Description("fast or exhaustive")] string searchMode = "fast",
        CancellationToken cancellationToken = default
    )
    {
        var profile = BuildProfiles.Recommend(
            role,
            workType,
            requiredPassives,
            optionalPassives,
            minimumIv
        );
        var hasExplicitRequirements = requiredPassives is { Length: > 0 };
        var resolvedRequired = (
            hasExplicitRequirements
                ? profile.RequiredPassives
                : profile.PreferredPassives
        ).ToArray();
        var resolvedOptional = (
            hasExplicitRequirements
                ? profile.PreferredPassives.Except(
                    profile.RequiredPassives,
                    StringComparer.OrdinalIgnoreCase
                )
                : []
        ).ToArray();
        var plan = service.FindBreedingPlan(
            playerId,
            targetSpecies,
            resolvedRequired,
            resolvedOptional,
            minimumHpIv ?? profile.MinimumHpIv,
            minimumAttackIv ?? profile.MinimumAttackIv,
            minimumDefenseIv ?? profile.MinimumDefenseIv,
            locations,
            allowWildPals,
            allowSurgery,
            maxBreedingSteps,
            maxResults,
            searchMode,
            cancellationToken
        );
        return Serialize(new
        {
            targetProfile = profile,
            resolvedRequiredPassives = resolvedRequired,
            resolvedOptionalPassives = resolvedOptional,
            plan
        });
    }

    [McpServerTool(Name = "estimate_breeding", ReadOnly = true)]
    [Description("Estimate offspring species and passive inheritance for two owned parents.")]
    public string EstimateBreeding(
        string playerId,
        string parent1PalId,
        string parent2PalId,
        string[] desiredPassives,
        bool allowExtraPassives = false
    ) => Serialize(service.EstimateInheritance(
        playerId,
        parent1PalId,
        parent2PalId,
        desiredPassives,
        allowExtraPassives
    ));

    [McpServerTool(Name = "get_player_state", ReadOnly = true)]
    [Description("Read live player and current-base context, optionally including all six player inventory containers.")]
    public async Task<string> GetPlayerState(
        bool includeInventory = false,
        CancellationToken cancellationToken = default
    )
    {
        var context = await liveBridge.GetPlayerContextAsync(cancellationToken);
        LiveBridgeCommandResult? inventory = includeInventory
            ? await liveBridge.GetInventorySnapshotAsync(cancellationToken)
            : null;
        return Serialize(new { context, inventory });
    }

    [McpServerTool(Name = "list_bases", ReadOnly = true)]
    [Description("List loaded live bases and their available inventory capability.")]
    public async Task<string> ListBases(
        CancellationToken cancellationToken = default
    ) => Serialize(await liveBridge.ListBasesAsync(cancellationToken));

    [McpServerTool(Name = "get_base_state", ReadOnly = true)]
    [Description("Inspect one loaded base. sections may contain summary, roster, workers, stations, or inventory; defaults to summary, roster, workers, and stations.")]
    public async Task<string> GetBaseState(
        string baseId,
        string[]? sections = null,
        CancellationToken cancellationToken = default
    )
    {
        var selected = (sections is { Length: > 0 }
                ? sections
                : ["summary", "roster", "workers", "stations"])
            .Select(section => section.Trim().ToLowerInvariant())
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var allowed = new HashSet<string>(
            ["summary", "roster", "workers", "stations", "inventory"],
            StringComparer.OrdinalIgnoreCase
        );
        var invalid = selected.Except(allowed).ToArray();
        if (invalid.Length > 0)
        {
            throw new ArgumentException(
                $"Unknown base sections: {string.Join(", ", invalid)}."
            );
        }

        var result = new Dictionary<string, object?>();
        if (selected.Contains("summary"))
        {
            result["summary"] =
                await liveBridge.ListBasesAsync(cancellationToken);
        }
        if (selected.Contains("roster"))
        {
            result["roster"] =
                HumanizePalRecords(
                    await liveBridge.GetBaseRosterAsync(
                        baseId,
                        cancellationToken
                    ),
                    "slots",
                    2
                );
        }
        if (selected.Contains("workers"))
        {
            result["workers"] =
                HumanizePalRecords(
                    await liveBridge.ListBaseWorkersAsync(
                        baseId,
                        cancellationToken
                    ),
                    "workers",
                    2
                );
        }
        if (selected.Contains("stations"))
        {
            result["stations"] =
                await liveBridge.ListWorkstationsAsync(baseId, cancellationToken);
        }
        if (selected.Contains("inventory"))
        {
            result["inventory"] =
                await liveBridge.GetBaseInventorySnapshotAsync(
                    baseId,
                    cancellationToken
                );
        }
        return Serialize(new { baseId, sections = result });
    }

    private LiveBridgeCommandResult HumanizePalRecords(
        LiveBridgeCommandResult result,
        string dataKey,
        int speciesFieldIndex
    )
    {
        if (!result.Data.TryGetValue(dataKey, out var encoded) ||
            string.IsNullOrWhiteSpace(encoded))
        {
            return result;
        }

        var records = encoded.Split('|');
        var changed = false;
        for (var index = 0; index < records.Length; index++)
        {
            var fields = records[index].Split('~');
            if (fields.Length <= speciesFieldIndex ||
                string.IsNullOrWhiteSpace(fields[speciesFieldIndex]))
            {
                continue;
            }

            var displayName = service.ResolveSpeciesDisplayName(
                fields[speciesFieldIndex]
            );
            if (displayName.Equals(
                fields[speciesFieldIndex],
                StringComparison.Ordinal
            ))
            {
                continue;
            }

            fields[speciesFieldIndex] = displayName;
            records[index] = string.Join("~", fields);
            changed = true;
        }

        if (!changed)
        {
            return result;
        }

        var data = new Dictionary<string, string>(
            result.Data,
            StringComparer.OrdinalIgnoreCase
        )
        {
            [$"{dataKey}_internal"] = encoded,
            [dataKey] = string.Join("|", records)
        };
        return result with { Data = data };
    }

    [McpServerTool(Name = "get_raid_state", ReadOnly = true)]
    [Description("Inspect the current base worker roster, all base Pal slots, empty slots, downed Pals, and live healthy Palbox reserves sorted by level, plus Raid Manager queue and timeout state.")]
    public async Task<string> GetRaidState(
        bool includeProbe = false,
        bool includeReserves = false,
        CancellationToken cancellationToken = default
    )
    {
        var state = await liveBridge.GetRaidStateAsync(
            includeProbe,
            includeReserves,
            cancellationToken
        );
        state = HumanizePalRecords(state, "fighters", 2);
        state = HumanizePalRecords(state, "reserves", 3);
        return Serialize(state);
    }

    [McpServerTool(Name = "discover_palcom_functions", ReadOnly = true)]
    [Description("Run the expensive loaded-function discovery for PalCom explicitly. This diagnostic no longer has a permanently polled trigger file.")]
    public async Task<string> DiscoverPalcomFunctions(
        CancellationToken cancellationToken = default
    ) => Serialize(await liveBridge.DiscoverPalcomFunctionsAsync(
        cancellationToken
    ));

    [McpServerTool(Name = "manage_raid", ReadOnly = false)]
    [Description("Start Raid Manager for the current owned base in observe or auto mode, or stop it. Auto mode fills empty base Pal slots immediately and reacts to coalesced roster/downed events. Queue refresh and integrity reconciliation share one 60-second pass; there is no five-second roster scan. Blocked candidates are invalidated without retry, zero healthy reserves trigger a warning, and the manager stops after 15 minutes.")]
    public async Task<string> ManageRaid(
        [Description("off, observe, or auto")] string mode,
        [Description("Optional when exactly one allowed player is configured.")] string? playerId = null,
        bool dryRun = true,
        [Description("Required for activation or stop; reuse the same 8-64 character key to prevent duplicate execution.")] string? idempotencyKey = null,
        CancellationToken cancellationToken = default
    )
    {
        var result = await liveBridge.SetRaidManagerAsync(
            mode,
            Array.Empty<RaidReserveCandidate>(),
            dryRun,
            idempotencyKey,
            cancellationToken
        );
        result = HumanizePalRecords(result, "fighters", 2);
        result = HumanizePalRecords(result, "reserves", 3);
        return Serialize(result);
    }

    [McpServerTool(Name = "swap_raid_pal", ReadOnly = false)]
    [Description("Atomically replace one authoritatively downed base Pal with a specified healthy Palbox reserve and verify both slot identities.")]
    public async Task<string> SwapRaidPal(
        string baseId,
        string downedPalId,
        string reservePalId,
        bool dryRun = true,
        [Description("Required for live actions; reuse the same 8-64 character key to prevent duplicate execution.")] string? idempotencyKey = null,
        CancellationToken cancellationToken = default
    ) => Serialize(await liveBridge.SwapRaidPalAsync(
        baseId,
        downedPalId,
        reservePalId,
        dryRun,
        idempotencyKey,
        cancellationToken
    ));

    [McpServerTool(Name = "move_pal", ReadOnly = false)]
    [Description("Atomically move a Pal between the Palbox and one base, with live verification, rollback on failure, and an in-game notification.")]
    public async Task<string> MovePal(
        [Description("base or palbox")] string destination,
        string baseId,
        string palId,
        bool dryRun = false,
        [Description("Required for live actions; reuse the same 8-64 character key to prevent duplicate execution.")] string? idempotencyKey = null,
        CancellationToken cancellationToken = default
    )
    {
        var direction = destination.Trim().ToLowerInvariant() switch
        {
            "base" => "to_base",
            "palbox" => "to_palbox",
            _ => throw new ArgumentException(
                "destination must be 'base' or 'palbox'."
            )
        };
        return Serialize(await liveBridge.MovePalRosterAsync(
            direction,
            baseId,
            palId,
            dryRun,
            idempotencyKey,
            cancellationToken
        ));
    }

    [McpServerTool(Name = "assign_pal", ReadOnly = false)]
    [Description("Atomically fixed-assign an active base Pal to one station, with verification, rollback on failure, and an in-game notification.")]
    public async Task<string> AssignPal(
        string baseId,
        string palId,
        string stationId,
        bool dryRun = false,
        [Description("Required for live actions; reuse the same 8-64 character key to prevent duplicate execution.")] string? idempotencyKey = null,
        CancellationToken cancellationToken = default
    ) => Serialize(await liveBridge.AssignPalToStationAsync(
        baseId,
        palId,
        stationId,
        dryRun,
        idempotencyKey,
        cancellationToken
    ));

    [McpServerTool(Name = "notify_player", ReadOnly = false)]
    [Description("Display or preview a short in-game companion notification.")]
    public async Task<string> NotifyPlayer(
        string message,
        [Description("1=info, 2=warning, 3=error.")] int priority = 1,
        bool dryRun = false,
        [Description("Required for live actions; reuse the same key to avoid duplicate execution.")] string? idempotencyKey = null,
        CancellationToken cancellationToken = default
    ) => Serialize(await liveBridge.ShowNotificationAsync(
        message,
        priority,
        dryRun,
        idempotencyKey,
        cancellationToken
    ));

    private static string Serialize(object value) =>
        JsonSerializer.Serialize(value, JsonOptions);
}
