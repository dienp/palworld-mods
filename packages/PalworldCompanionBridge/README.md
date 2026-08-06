# Palworld Companion Bridge

An optional UE4SS Lua bridge that gives the local Palworld MCP server a narrow,
auditable live-game channel.

The bridge uses atomic mailbox files under
`%LOCALAPPDATA%\PalworldCompanionBridge`. One generation-guarded scheduler
probes commands every 500 ms; it opens no network port.

## Private PalCom chat

When the local PalCom broker is ready, messages beginning with
`Hey PalCom,` are intercepted from the local player, suppressed from ordinary
chat, and answered through private `PalLogManager` notifications. Messages
from remote players are ignored.

The broker renews a 15-second readiness lease every five seconds. The hook does
not consume messages when that lease is absent or stale. One request may be
active at a
time; the player gets an immediate private echo, a `Thinking…` acknowledgement,
and chunked private response notifications.

The request, response, and readiness mailboxes live under
`%LOCALAPPDATA%\PalworldCompanionBridge` and are separate from the live-tool
command mailbox. The broker uses filesystem events rather than a request
polling loop. While one answer is pending, Lua checks for its response through
the existing bridge scheduler with 500 ms, one-second, then two-second backoff;
it creates no PalCom-specific timer.

## Safety model

- Live access still requires `liveBridgeEnabled: true`.
- Allowlisted edit actions are enabled by default. Set
  `liveBridgeWriteEnabled: false` in MCP configuration or
  `write_actions_enabled=false` in
  `%LOCALAPPDATA%\PalworldCompanionBridge\bridge-settings.pcb` to opt out.
- Edit tools default to live execution and expose `dryRun: true` for preview.
- Non-dry-run calls require an idempotency key.
- Only explicitly implemented actions are accepted.
- Assignment validates base, Pal, and station IDs, verifies the result,
  attempts rollback on failure, and displays an in-game result notification.
- MCP and Lua write separate audit logs.

Copy `bridge-settings.example.pcb` to `bridge-settings.pcb` when you want a
persistent local override.

## Current capabilities

- Two-second live heartbeat backed by a cached 10-second readiness probe
- Scheduler telemetry for mailbox probes, readiness refreshes, reinforcement
  events, roster/Palbox scans, and pass duration
- Local-controller selection that excludes remote listen-server controllers
- Geometric current-base detection through the local view-target position and
  `PalBaseCampManager.GetInRangedBaseCamp`, including other guilds' bases
- Current base ID, friendly name, group ID/name, ownership flag, and resolver
  source
- Complete snapshot of the six player inventory containers exposed by
  `PalPlayerInventoryData.InventoryMultiHelper`
- Local-guild identity from `PalPlayerState.GuildBelongTo.GetId()`
- Loaded local-guild base catalog sourced from live `PalBaseCampModel`
  instances, with per-base inventory capability and optional Item Retrieval
  Machine details
- Persistent first-discovery fallback names in
  `%LOCALAPPDATA%\PalworldCompanionBridge\base-names.pcb`; assigned in-game
  names take precedence
- GUID-deduplicated base chest membership with live item-quantity summaries
- 15-second membership and 5-second summary caches with lifecycle validation
- Active base-worker discovery by stable Pal individual ID
- Palbox paging and base-roster slot/capacity inspection
- Atomic Palbox-to-base and base-to-Palbox roster swaps using native slot IDs
- Current-base reinforcement inspection with every worker slot, empty/downed
  counts, and live healthy Palbox reserves ranked by level
- Observe-only and automatic Raid Manager sessions bound to the current owned
  base, with immediate empty-slot filling and event-triggered reinforcement
- Coalesced container-swap, worker-roster, and supported downed-state event
  requests, with one shared 60-second queue-refresh/integrity reconciliation
- Atomic same-slot replacement of a downed base Pal with the highest-level
  still-present healthy live Palbox reserve
- Explicit `discover_palcom_functions` diagnostics with no permanent discovery
  trigger-file polling
- Loaded work-target discovery by base ID, station object ID, and native work ID
- Atomic fixed assignment through Palworld's server-authoritative
  `SetBaseCampActionWithFixAssign` path
- Preview or display a Pal log notification

## Cross-guild behavior

Current-base detection is spatial and may return a loaded base owned by another
guild. The response marks it with `current_base_is_owned=false` and includes
the other group ID/name when available.

Worker and workstation discovery can inspect such a loaded base by its runtime
base ID. Base roster and inventory membership are currently local-guild
capabilities, so those sections may be unavailable for the same non-owned
base. `list_bases` deliberately remains the local guild's loaded catalog.

This release intentionally does not provide generic reflected calls, console
commands, item creation, save editing, or arbitrary input injection.
