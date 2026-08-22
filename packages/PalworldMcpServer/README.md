# Palworld MCP Server

Local MCP server for inspecting owned Pals, producing owned-aware Palworld
breeding plans, and performing narrowly allowlisted live companion actions.

Version 0.9 uses the MIT-licensed PalCalc 1.19.1 libraries. The pinned PalCalc
release contains the current Palworld database, save reader, breeding database,
and breeding solver. Third-party binaries are checksum-verified into ignored
`tools/palcalc`; they are not committed to this repository.

## Supported platform

- Windows 10 version 1809 or newer
- x64 processor
- A local Steam save, Xbox save synchronized by the Xbox app, or an explicitly
  configured world-save directory
- An MCP host that supports local stdio servers

The release artifact is self-contained and does not require a separately
installed .NET runtime. Other operating systems and Windows ARM64 are not
currently supported.

## Current tools

Version 0.9 exposes a concise 16-tool public surface:

- `get_status`
- `search_pals`
- `get_pal`
- `search_pal_data`
- `plan_breeding`
- `estimate_breeding`
- `get_player_state`
- `list_bases`
- `get_base_state`
- `get_raid_state`
- `discover_palcom_functions`
- `manage_raid`
- `swap_raid_pal`
- `move_pal`
- `assign_pal`
- `notify_player`

### Tool contracts

All Pal instance, base, station, player, and group IDs are opaque runtime or
save identifiers. Call `get_status` first, then obtain IDs from search or live
inspection tools rather than constructing or hardcoding them.

| Tool | Important arguments | Result and scope |
| --- | --- | --- |
| `get_status` | `refresh` | Save freshness, allowed players, plan-cache state, and live-bridge readiness. `refresh=true` rescans the save and invalidates plans. |
| `search_pals` | `playerId`; optional locations, species, passive, IV filters, offset, limit | Paginated owned-Pal summaries. Locations default to `Palbox`. |
| `get_pal` | `playerId`, `palId` | One complete normalized owned-Pal record. |
| `search_pal_data` | `kind`, `query`, `limit` | Species or passive reference metadata. |
| `plan_breeding` | `playerId`, `targetSpecies`; role/profile constraints | Ranked breeding, capture, or Surgery plans. |
| `estimate_breeding` | player and two parent IDs, desired passives | Estimated offspring species and passive inheritance. |
| `get_player_state` | `includeInventory` | Live local-player context and optional six-container inventory snapshot. |
| `list_bases` | none | Loaded bases belonging to the local player's live guild, with stable display names and inventory capability. |
| `get_base_state` | `baseId`, optional `sections` | Selected `summary`, `roster`, `workers`, `stations`, and/or `inventory` reads. |
| `get_raid_state` | optional probe and reserve flags | Current base, all worker slots, empty and downed slot counts, healthy Palbox reserves sorted by level, and the cached reinforcement queue/watchdog state. The Palbox is rescanned when the manager is off or `includeReserves` is set; otherwise the manager's own queue answers and `data_reserves_live` reports `false`. `includeProbe` adds the raid-area, raid-metadata, Palbox-metadata, and combat reflection dumps. |
| `discover_palcom_functions` | none | Explicitly runs the expensive PalCom loaded-function diagnostic. There is no permanently polled discovery trigger. |
| `manage_raid` | `off`, `observe`, or `auto`; optional player ID; dry-run/idempotency options | Binds the current owned base. Auto mode fills empty worker slots immediately and reacts to coalesced roster/downed events. Queue refresh and integrity reconciliation share one 60-second pass; there is no five-second roster scan. Blocked reserves are invalidated without retry, zero healthy reserves trigger a warning, and the manager stops after 15 minutes. |
| `swap_raid_pal` | base, downed Pal, and reserve Pal IDs; dry-run/idempotency options | Atomically swaps a verified-down base fighter with one specified Palbox reserve and verifies both slot identities. |
| `move_pal` | destination, base ID, Pal ID, dry-run/idempotency options | Verified Palbox/base roster move with rollback on failure. |
| `assign_pal` | base, Pal, station IDs, dry-run/idempotency options | Verified fixed work assignment with rollback on failure. |
| `notify_player` | message, priority, dry-run/idempotency options | Preview or display an in-game notification. |

Example read sequence:

```json
{"tool":"get_status","arguments":{"refresh":false}}
{"tool":"get_player_state","arguments":{"includeInventory":false}}
{"tool":"list_bases","arguments":{}}
{"tool":"get_base_state","arguments":{"baseId":"<ID from live data>","sections":["workers","stations"]}}
```

Example write preview followed by execution:

```json
{"tool":"assign_pal","arguments":{"baseId":"<base ID>","palId":"<active worker ID>","stationId":"<station object ID>","dryRun":true}}
{"tool":"assign_pal","arguments":{"baseId":"<base ID>","palId":"<active worker ID>","stationId":"<station object ID>","dryRun":false,"idempotencyKey":"research-assignment-001"}}
```

`plan_breeding` resolves the requested role into an explicit target and accepts
the target species, required and optional passives,
minimum HP/attack/defense IVs, allowed owned-Pal locations, and constraints on
wild Pals, Surgery, breeding steps, and result count. It returns complete
parent trees with owned instance IDs, locations, per-step expected eggs,
passive and IV probabilities, and total estimated effort.

### Plan search modes

- `fast` is the default. It searches owned candidates at depths 0, 1, and 2,
  stopping at the first depth that produces a valid plan. It also prunes
  candidates with several irrelevant passives.
- `exhaustive` runs one broader search at `maxBreedingSteps`. Use it when fast
  mode finds no plan or when a deeper, potentially lower-effort optimum is
  worth the additional time.

The default `maxBreedingSteps` is 2. Search cost grows rapidly with depth, so
depths above 2 should be intentional.

### Query indexes and plan cache

The save snapshot is indexed in memory by player and owned-Pal instance. Pal
species and passive metadata are indexed by display and internal names. The
embedded PalCalc breeding database is loaded once per server process rather
than once per request.

The server keeps 64 plan responses in a memory LRU backed by an optional
256-entry SQLite LRU. SQLite makes completed plans available after a server or
Codex restart. Cache keys include the cache format, PalCalc database version,
save identity, breeding-input fingerprint, player, species, passives, IV
thresholds, locations, wild/Surgery policy, search mode, depth, and result
count.

Invalidation rules:

- `get_status(refresh=true)` always clears both cache tiers.
- When a save timestamp changes, the server reloads the snapshot and compares
  a breeding-input fingerprint. The plan cache is cleared only if owned
  species, gender, passives, IVs, availability, or location changed.
- Inventory, world-state, or other unrelated save changes preserve plans.
- Restarting the server clears memory, while compatible SQLite entries remain.
- Database and cache-format versions prevent incompatible persistent hits.
- Each tier independently evicts its least-recently-used entries at capacity.

`get_status` reports memory and persistent entries, hits, misses,
evictions, invalidations, and persistent-cache initialization errors.

PalCalc's character snapshot contains players, Pals, bases, guilds, and Pal
containers, but not player item inventory. Surgery-enabled results therefore
include an explicit warning that implants and currency were not validated.

### Optional live UE4SS bridge

The release ZIP includes `ue4ss-mod/PalworldCompanionBridge`. Install that
folder as a UE4SS Lua mod to enable live tools. The bridge uses an atomic
single-command mailbox under `%LOCALAPPDATA%\PalworldCompanionBridge`; it does
not open a network port.

Live edit mode is enabled by default for explicitly allowlisted actions:

1. Set `liveBridgeEnabled: true` in `palworld-mcp.local.json`.
2. Set `liveBridgeWriteEnabled: false` to opt out at the server.
3. Optionally copy `bridge-settings.example.pcb` to
   `%LOCALAPPDATA%\PalworldCompanionBridge\bridge-settings.pcb` and set
   `write_actions_enabled=false` to opt out in-game.

Non-dry-run actions require a stable idempotency key. Completed results and
separate MCP/Lua audit logs are retained locally. Assignment validates the
base, active worker Pal, and work target; uses Palworld's native fixed-work
backend; verifies the resulting current work; attempts to restore the previous
assignment on failure; and clearly notifies the player in-game.

### Private in-game PalCom chat

The companion bridge can intercept a local-player chat message such as
`Hey PalCom, how is this base doing?`, keep it out of normal chat, and return
the answer through private local notifications. The agent runs out of process,
so Codex never blocks Palworld's game thread.

The primary prefix and aliases are case-insensitive. Defaults are
`Hey PalCom,`, `PalCom,`, `Pal,`, and `PC,`; every phrase keeps the trailing
comma to reduce accidental matches. Customize or clear the aliases with
`palComChatAliases`.

This feature is opt-in. Add the following fields to
`palworld-mcp.local.json`. The normal MCP server provisions a fixed launcher
under `%LOCALAPPDATA%\PalworldCompanionBridge`; the Lua bridge uses it to start
the dedicated broker on the first matching chat command when needed. You can
also launch the broker manually with
`palworld-mcp-server.exe --palcom-agent`:

```json
{
  "liveBridgeEnabled": true,
  "palComChatEnabled": true,
  "palComChatPrefix": "Hey PalCom,",
  "palComChatAliases": ["PalCom,", "Pal,", "PC,"],
  "palComCodexExecutable": "codex.exe",
  "palComPrimaryModel": "gpt-5.6-sol",
  "palComFallbackModels": ["gpt-5.5"],
  "palComMcpEnabled": true,
  "palComMcpServerExecutable": "C:\\Tools\\palworld-mcp-server.exe",
  "palComMcpConfigPath": "C:\\Tools\\palworld-mcp.local.json",
  "palComTimeoutMilliseconds": 60000
}
```

The local Codex CLI must already be installed and signed in. PalCom invokes
`codex exec` with an ephemeral session and a read-only sandbox. It ignores the
general user configuration, removes credential-like environment variables,
disables shell, web, apps, plugins, and multi-agent tools, then injects only
the configured Palworld MCP server. All Palworld MCP tools are available and
pre-approved for explicit in-game requests; live writes still pass through the
server's idempotency, verification, rollback, and audit controls. The primary
model is `gpt-5.6-sol`; configured fallbacks are tried in order when it fails.
It keeps up to six recent exchanges in broker memory for conversational
continuity, but does not persist the transcript.

When `palComCodexExecutable` is `codex.exe`, the server prefers the newest
user-local Codex Desktop CLI under `%LOCALAPPDATA%\OpenAI\Codex\bin`. This
avoids the WindowsApps alias, which background broker processes may be unable
to execute. Set an absolute path to override automatic resolution.

The broker blocks on a coalescing `FileSystemWatcher` channel instead of polling
for requests. It renews a 15-second readiness lease every five seconds; this is
its only recurring PalCom timer. If the lease is stale, the Lua hook privately
suppresses the prefixed command, attempts one lazy broker start, and queues the
request. A missing launcher produces an immediate private warning; failure to
renew the lease within 15 seconds produces a second private warning and removes
the unclaimed request. A broker lock prevents duplicate agent instances. Set
`palcom_lazy_start_enabled=false` in `bridge-settings.pcb` to opt out. While an
answer is pending, Lua checks the response through the existing bridge scheduler with adaptive 500 ms,
one-second, and two-second deadlines. A direct prefixed action request is
treated as player authorization and executes without a separate
companion-control confirmation.

The broker status records watcher events/coalescing/recovery, claims,
processing failures, lease writes, and the latest claim/response latency. The
bridge heartbeat records PalCom response probes, pending age/current interval,
responses, timeouts, and latest response latency.

### Live base identity and current location

`list_bases` is live data, not a saved-container-to-base mapping. The bridge
reads the local player's actual `GuildBelongTo` group and enumerates loaded
`PalBaseCampModel` instances in that group. It never hardcodes base IDs or
container mappings.

Default Palworld template names receive stable sequential display names on
first discovery. The ID-to-name registry is stored locally in
`%LOCALAPPDATA%\PalworldCompanionBridge\base-names.pcb`. A real in-game base
name always takes precedence.

`get_player_state` selects the actual local controller and queries
`PalBaseCampManager.GetInRangedBaseCamp` using the controller's view-target
position. This geometric resolver can identify any loaded base containing the
player, including another guild's base. Current-base data includes:

- `current_base_id`
- `current_base_name`
- `current_base_group_id`
- `current_base_group_name`
- `current_base_is_owned`
- `current_base_detection` (`controller`, `geometry`, or `membership`)

The membership-array resolver remains a fallback only. A blank current base
means no loaded base range contains the player or no usable live position was
available.

Cross-guild inspection is intentionally asymmetric in the current build.
Loaded worker and station surfaces can be inspected by base ID. The main base
catalog, roster, and inventory membership routes remain scoped to the local
player's guild, so `get_base_state` may return workers/stations for a visited
base while returning roster or inventory as unavailable.

## Bootstrap and build

From the repository root:

```powershell
npx nx run palworld-mcp-server:bootstrap
npx nx run palworld-mcp-server:build
npx nx run palworld-mcp-server:test
npx nx run palworld-mcp-server:package
npx nx run palworld-mcp-server:smoke-release
```

The `package` target creates:

```text
packages/PalworldMcpServer/dist/
  artifact-manifest.json
  SHA256SUMS.txt
  palworld-mcp-server-v0.9.7-win-x64.zip
```

The ZIP contains a self-contained `palworld-mcp-server.exe`, the example
configuration, documentation, and license notices.

The bootstrap target downloads `PalCalc-NoBundle.zip` for version 1.19.1 and
requires SHA-256:

```text
ee6d1853c835d4c0bf697e3dbe95967521231757ba9bf75d129c2e382c2de8a7
```

## Configuration

For a release ZIP, extract the complete top-level folder. Copy
`palworld-mcp.local.example.json` to `palworld-mcp.local.json` beside the EXE.
For a source build, the configuration may instead live in any ignored local
directory. Replace `savePath` with the world save folder containing `Level.sav`
and `Players`, or set it to `null` to select the newest discovered save.

Set `PALWORLD_MCP_CONFIG` to the absolute path of that file when starting the
server. If `SavePath` is omitted, the server selects the most recently modified
valid local Steam or Xbox save discovered by PalCalc.

An empty `allowedPlayerIds` array permits every player in the configured save.
For multiplayer saves, explicitly list the player IDs the MCP is allowed to
expose.

Run the source-built stdio server:

```powershell
$env:PALWORLD_MCP_CONFIG = "F:\private\palworld-mcp.local.json"
dotnet packages\PalworldMcpServer\src\PalworldMcpServer\bin\Release\net9.0-windows10.0.17763.0\win-x64\palworld-mcp-server.dll
```

Configure an MCP host to launch the same `dotnet` command with the built DLL as
its first argument and `PALWORLD_MCP_CONFIG` in its environment.

For the self-contained release, configure the MCP host to run the EXE directly:

```toml
[mcp_servers.palworld]
command = "C:\\Tools\\palworld-mcp-server-v0.9.7-win-x64\\palworld-mcp-server.exe"
startup_timeout_sec = 30
tool_timeout_sec = 120
```

If `palworld-mcp.local.json` is beside the EXE, no environment variable is
required.

After downloading a release, compare its checksum before extracting:

```powershell
Get-FileHash .\palworld-mcp-server-v0.9.7-win-x64.zip -Algorithm SHA256
```

The resulting hash must match the entry published in `SHA256SUMS.txt`.

## GitHub release workflow

The `Palworld MCP Server` GitHub Actions workflow builds, tests, smoke-tests,
and uploads a Windows artifact only when MCP server source, tests, packaging,
packaged bridge payload, or release metadata changes. Pull requests and
`codex/**` branches produce CI artifacts without publishing. A push to `main`
automatically publishes the versioned GitHub release only when runtime code
under `PalworldMcpServer/src` or the bundled bridge Lua `Scripts` directory
changes. Documentation, tests, workflow, thumbnails, and packaging-only
changes do not publish a release. The manual trigger can still publish when
`publish_release` is explicitly enabled.

Publishing fails early with an actionable version-bump error if the release
tag already exists. Same-version release jobs are serialized, and every new
release tag targets the exact commit whose artifact passed the workflow.

Before any public release, resolve the `libooz.dll` redistribution note in
`THIRD-PARTY-NOTICES.md`.

## Recommended advisor workflow

1. Call `get_status`.
2. Verify passive or species names with `search_pal_data` when needed.
3. Call `plan_breeding` with a role such as `attack`, `defense`,
   `combat_balanced`, `ranch_farming`, `base_worker`, or `transport`.
4. Use `get_pal` to inspect important starting parents.
5. Present each generation as a checklist, including the passives, IVs, and
   gender that must be retained before proceeding.

For live base work:

1. Call `get_status` and require `live.online=true` and
   `live.heartbeat.game_ready=true`.
2. Call `get_player_state` to resolve the current spatial base, if any.
3. Call `list_bases` for the local guild's loaded base IDs.
4. Call `get_base_state` before selecting workers or stations.
5. Use `search_pals` / `get_pal` to evaluate owned candidates.
6. Preview consequential writes with `dryRun=true`, then execute with one
   caller-stable idempotency key.

## Safety and limitations

- Save-reader and advisor tools remain read-only.
- Live write tools are explicitly allowlisted, opt-out, idempotent, and audited.
- The server never writes Palworld save files.
- Tool arguments cannot supply filesystem paths.
- Results describe the scanned save snapshot, not live game state.
- Live results describe currently loaded runtime objects and can change with
  streaming, movement, worker scheduling, or world transitions.
- Non-owned base roster and inventory reads are not currently supported even
  when geometric current-base detection succeeds.
- Probability and effort figures are estimates.
- Mutation, special-cake, and active-skill inheritance are not currently
  optimized and are disclosed as limitations in plan results.
- The solver is deliberately capped to eight breeding steps and ten returned
  results.
