# Palworld MCP server: Version 1 design

Research date: 2026-08-04

> Historical design note: the implemented v0.8 public API consolidates these
> early tool sketches into 12 entity-oriented tools. See
> `packages/PalworldMcpServer/README.md` for the active names and schemas.

## Goal

Version 1 is a local, read-only MCP server that can inspect a player's owned
Pals and produce an explainable breeding plan for a requested target. A request
may name exact passive skills and IV thresholds, or describe an objective such
as farming, general base work, attack, defense, or balanced combat.

The server advises only. It must never edit a save, move a Pal, start or stop a
server, or mutate the running game.

## Recommended engine

Use the MIT-licensed `tylercamp/palcalc` projects as the save reader, Palworld
database, breeding database, and solver:

- `PalCalc.Model`
- `PalCalc.SaveReader`
- `PalCalc.Solver`

PalCalc 1.19.1 was released on 2026-08-02 and its repository was actively
maintained when this design was written. It already:

- reads local Steam and Xbox saves;
- indexes Palbox, party, base, viewing-cage, dimensional-storage, and global
  storage Pals;
- represents owned Pal instance IDs, locations, gender, passive skills, active
  skills, and IVs;
- uses current Palworld 1.0 species and breeding data;
- finds breeding trees from owned and optionally wild Pals;
- accepts required and optional passive skills, IV thresholds, gender, and
  search constraints; and
- ranks paths by estimated effort using passive, IV, and gender probabilities.

This is a materially better fit than putting a new optimizer on top of
Palworld Save Pal. Palworld Save Pal remains a possible future data-provider
adapter, especially for an already-running remote PSP backend, but it should
not be the core Version 1 solver.

Do not copy generated Palworld data or extracted game assets into this
repository. Pin PalCalc as an external source dependency and retain its license
and revision metadata. A distributed build must record the PalCalc commit and
embedded database version used to produce its advice.

## Data flow

```text
configured local save root
  -> stable read-only snapshot
  -> PalCalc save reader
  -> normalized owned-Pal index
  -> PalCalc game and breeding databases
  -> role/request normalization
  -> PalCalc breeding solver
  -> concise MCP result plus explainable breeding tree
```

Every result must include:

- save path alias, never an unnecessarily disclosed absolute path;
- save modification time and scan time;
- game-data and breeding-data versions;
- player ID and display name;
- whether each starting Pal is owned, wild, or the result of an earlier step;
- assumptions, unsupported mechanics, and confidence notes; and
- stable instance IDs for owned Pals so similarly named Pals are not confused.

## Version 1 tools

### `get_palworld_status`

Reports whether the configured save and data sources are available, which
players were discovered, snapshot freshness, game-data version, PalCalc
revision, and any compatibility warnings.

This tool takes no filesystem path. Paths are configured once in an ignored
`palworld-mcp.local.json` file.

### `list_players`

Lists players available in the selected save. Returns stable player IDs,
display names, guild names when available, and owned-Pal counts by location.

### `scan_owned_pals`

Returns a paginated, filterable owned-Pal index. Inputs:

- `playerId`
- `locations`: `palbox`, `party`, `base`, `viewing_cage`,
  `dimensional_storage`, or `global_storage`
- optional species, gender, passive, active-skill, minimum-IV, nickname, and
  text filters
- `cursor` and `limit`

The default location is `palbox`. Breeding planning may include other
locations only when the caller opts in or the configured policy enables them.

Each result includes instance ID, species ID and localized name, nickname,
location, container/page/slot when known, gender, level, passives, active
skills, HP/attack/defense IVs, rank, Lucky/Alpha flags, and relevant work
suitabilities.

### `get_owned_pal`

Returns the complete normalized record for one owned Pal instance. This is the
tool for resolving a candidate referenced by a breeding plan.

### `get_pal_species`

Returns species-level metadata, separated from owned-instance metadata:

- localized and internal names;
- Paldeck number;
- elements;
- breeding power and unique-combination notes;
- gender probability;
- base stats;
- natural and rank-adjusted work suitabilities;
- guaranteed or species-specific passives;
- partner-skill effects when available; and
- obtainable active skills.

### `search_passives`

Searches passive metadata and returns effects, rank, availability, whether the
passive can be inherited, whether it can be applied through Pal Surgery, and
any species, mutation, or other restrictions represented by the current data.

This prevents an advisor from recommending an attractive passive that cannot
legally reach the target through the proposed method.

### `recommend_target_build`

Translates an objective into an explicit target specification before solving.
Inputs:

- target species;
- one of `ranch_farming`, `base_worker`, `transport`, `attack`, `defense`,
  `combat_balanced`, or `custom`;
- optional work type, element, active-skill preference, and custom stat
  weights;
- optional required, preferred, and forbidden passives;
- optional minimum HP, attack, and defense IVs; and
- whether Surgery, mutations, special cakes, wild captures, or non-Palbox
  owned Pals may be considered.

The result is not a breeding path. It is an inspectable build specification:
required and optional passives, IV thresholds, desired active skills, ranking
weights, and rationale. The caller may edit this specification before asking
for a solve.

Preset names are conveniences, not universal truths:

- `ranch_farming` must optimize the requested Ranch drop behavior rather than
  blindly applying work-speed passives that may not affect that species'
  production.
- `base_worker` must require a concrete work type when different
  suitabilities lead to materially different builds.
- `attack` must distinguish player-mounted, partner-skill, elemental,
  skill-cooldown, and general attack objectives when those choices change the
  best passives.
- `defense` must distinguish survivability, raid-tank, and player-buff
  objectives where relevant.

When a role is underspecified, the tool returns ranked alternatives and the
assumption behind each one instead of silently choosing.

### `estimate_inheritance`

Calculates the estimated outcome for two specified parents and a desired
offspring gate:

- resulting species;
- compatible parent genders;
- desired passive inheritance probability;
- IV threshold probability;
- desired gender probability;
- combined per-egg probability;
- expected eggs;
- confidence and mechanics-version notes; and
- dilution caused by irrelevant parent passives.

This is useful both independently and for explaining a step in a larger plan.

### `find_breeding_plan`

The primary advisor tool. Inputs:

- `playerId`
- a target specification returned by `recommend_target_build`, or explicit
  species/passive/IV/gender requirements
- allowed owned-Pal locations
- whether wild Pals are allowed
- `fast` iterative search or `exhaustive` maximum-depth search
- maximum wild captures, breeding steps, irrelevant passives, estimated
  effort, Surgery cost, and result count
- whether Surgery, gender reversers, mutations, and special cakes are allowed

The result contains a ranked set of complete breeding trees. Each step names:

- the two parents, their genders, passives, IVs, and locations;
- owned instance IDs when applicable;
- the expected child species and the exact passives/IVs that must be retained;
- the reason this intermediate child is needed;
- estimated probability, eggs, and effort;
- whether the child must have a particular gender for the next step; and
- applicable preparation, such as removing unwanted passives through Surgery
  or equipping active skills before breeding.

The final result also explains why the first plan outranks alternatives and
identifies the most difficult inheritance bottleneck.

The Windows v0.2 implementation defaults to fast iterative search at depths
0, 1, and 2. Exact requests are stored in a 64-entry in-memory LRU backed by
an optional 256-entry embedded SQLite LRU for reuse across server restarts.
Explicit refresh always invalidates the cache. Automatic save refresh
invalidates plans only when a fingerprint of breeding-relevant owned-Pal data
changes; unrelated world or inventory writes preserve cached plans.

### `compare_breeding_plans`

Compares previously returned plan IDs by steps, expected eggs, estimated time,
wild captures, Surgery cost, owned-parent reuse, IV quality, and unsupported
or uncertain mechanics. Plan IDs are scoped to the current server process and
save snapshot.

## Optional MCP prompt

Expose a `breed_perfect_pal` prompt that directs an MCP host to:

1. call `get_palworld_status`;
2. resolve the intended build with `recommend_target_build`;
3. show the explicit build to the user when the objective is ambiguous;
4. call `find_breeding_plan`;
5. resolve important owned candidates with `get_owned_pal`; and
6. present a numbered breeding checklist with expected eggs and stop
   conditions for each generation.

The prompt is workflow guidance. All factual save and breeding claims must
come from tool results.

## Meaning of "perfect"

The server must never use "perfect" without expanding it into measurable
criteria. At minimum, the answer must state:

- target species;
- required and optional passives;
- minimum or exact IV expectations;
- required gender, if any;
- active-skill requirements, if supported;
- work-suitability assumptions;
- allowed post-breeding systems such as Surgery, condensation, souls,
  Awakening, mutations, or special cakes; and
- which improvements are not inherited and therefore belong to a
  post-breeding checklist.

Rank, souls, level, learned skill fruits, equipment, and other upgrades must
not be presented as inherited genetics unless the current game data explicitly
models them that way.

## Safety and privacy

- Use local stdio transport for Version 1.
- Never accept arbitrary save paths in MCP tool arguments.
- Resolve configured paths once and require them to remain under an explicitly
  configured save root.
- Read a copied or stable snapshot; never write the live save.
- Do not expose other players' Pals unless their player IDs are explicitly
  allowed in local configuration.
- Paginate Pal lists and cap solver results.
- Cancel a solve that exceeds configured CPU time or memory limits.
- Invalidate plan IDs when the save snapshot or breeding database changes.
- Never publish, upload, or transmit save contents.

## Acceptance criteria

Version 1 is complete when automated tests demonstrate that it can:

1. scan a fixture save and distinguish Palbox, party, base, dimensional, and
   global-storage Pals;
2. find an owned Pal by stable instance ID and report its passives and IVs;
3. translate each role preset into an explicit, inspectable build;
4. reject or warn about unavailable and non-inheritable passives;
5. find a breeding tree using only allowed owned Pals;
6. optionally incorporate permitted wild Pals and Surgery;
7. calculate and expose passive, IV, gender, and combined probabilities;
8. produce deterministic ranked results for a pinned PalCalc/database
   revision;
9. report snapshot and database freshness in every breeding answer; and
10. complete without modifying the source save or any Palworld installation
    file.

Game-derived fixtures must be synthetic or sanitized and must not contain
copyrighted extracted assets or personal save identifiers.

## Known Version 1 limitations

- Advice is a snapshot, not live game state.
- A Pal moved after the scan may be reported at an old location.
- Probability estimates are models, not guarantees.
- Mutation, special-cake, active-skill inheritance, Awakening, Surgery, and
  other Palworld 1.0 systems must be included only when the pinned PalCalc
  revision models them accurately. Otherwise the result must label them as
  post-processing or an unsupported optimization.
- Natural-language role interpretation remains partly subjective; the
  explicit build specification is the contract that makes the solve
  reproducible.

## Primary external references

- PalCalc: <https://github.com/tylercamp/palcalc>
- PalCalc releases: <https://github.com/tylercamp/palcalc/releases>
- MCP C# SDK: <https://github.com/modelcontextprotocol/csharp-sdk>
- Palworld official REST API:
  <https://docs.palworldgame.com/category/rest-api/>
- Community breeding mechanics reference:
  <https://palworld.wiki.gg/wiki/Breeding>
