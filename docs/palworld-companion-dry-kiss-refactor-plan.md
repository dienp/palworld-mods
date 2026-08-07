# Palworld Companion Bridge DRY/KISS refactor plan

Status: Stages 1 and 2 are implemented as a source-only change in
`0.1.0-dev.112`. Stages 3 to 6 are still planned. Nothing has been installed
or hot reloaded.

Last updated: 2026-08-07

## Objective

Reduce duplication and complexity in Palworld Companion Bridge while preserving
its live-verified behavior, protocol compatibility, diagnostics, and runtime
safety.

The refactor should favor small, explicit functions and a single authoritative
path for each operation. It should not add framework, packaging, loader, or
scheduler complexity merely to make the source look more modular.

## Current baseline

The UE4SS Lua entry point is:

`packages/PalworldCompanionBridge/package/PalworldCompanionBridge/Scripts/main.lua`

At the time this plan was written (historical baseline; see Stages 1 and 2 for
what has since changed):

- The file is approximately 8,105 lines.
- Four Raid Manager functions have two definitions, with the later definition
  silently shadowing the earlier one:
  - `pcb_get_raid_state`
  - `pcb_set_raid_manager`
  - `pcb_stop_raid_manager`
  - `pcb_raid_manager_tick`
- Several local functions have no callers.
- Worker deployment, withdrawal, verification, rollback, state reset, and
  notification behavior are repeated in multiple paths.
- Diagnostic and production Raid Manager logic are interleaved.
- The package version most recently installed before this plan was
  `0.1.0-dev.110`.

## Guiding rules

- DRY: one authoritative implementation for each operation.
- KISS: prefer direct functions and explicit state over generic abstraction.
- Keep the single `main.lua` entry point during the initial refactor.
- Do not add another loop or timer.
- Preserve runtime diagnostic switches in source.
- Preserve the MCP protocol and existing capability names.
- Do not modify Palworld's main pak.
- Do not install a refactor build without explicit user approval.
- Increment the mod version for every distributed test build.
- Run `npm run validate` after every payload or metadata change.

## Stage 1: establish guardrails (implemented)

Record and protect:

- Command names and argument contracts.
- Response and heartbeat fields.
- Capability advertisement.
- Idempotency and rollback behavior.
- Notification severity behavior.
- Scheduler intervals and event-coalescing behavior.
- Live-verified raid phases:
  - `2`: `PalRaidBossAreaPhaseReadyState`
  - `4`: `PalRaidBossAreaPhaseBattleState`
  - `5`: `PalRaidBossAreaPhaseResultState`

`scripts/validate-mods.mjs` now rejects, for every Lua package:

- Duplicate top-level function definitions, which covers the known shadowed
  Raid Manager entry points. A later `name = function(...)` assigns to the
  earlier `local function name(...)` in the same chunk, so the first definition
  becomes unreachable without any warning.
- Unreferenced top-level local functions. This is an error for packages that
  set `"RejectUnreferencedLuaFunctions": true` in `mod-project.json`
  (Companion Bridge) and a warning elsewhere, so one mod's dead-code backlog
  cannot block another mod's release.

`packages/PalworldCompanionBridge/scripts/smoke.lua` adds the executable half
of the guardrail. Every engine global the mod touches is already guarded, so a
plain Lua interpreter can load the chunk, run its initialization path, and
drive real commands through the command mailbox with no game objects present.
It asserts that the probe and reserve flags are honored, that Raid Manager
gating rejects activation without a loaded roster, that an unknown action is
refused, and that bare scheduler wakes write a heartbeat without raising. It
runs as the `smoke` target, which `validate` depends on; a machine without a
Lua interpreter skips it with a warning instead of failing, since a standalone
interpreter is not part of the Windows modding toolchain.

This does not replace live verification. It protects the remaining stages from
load-order, nil-call, and protocol regressions on any platform.

## Stage 2: remove shadowed legacy code (implemented)

`main.lua` went from 8,228 to 6,423 lines.

- Removed the shadowed first definitions of `pcb_get_raid_state`,
  `pcb_set_raid_manager`, `pcb_stop_raid_manager`, and
  `pcb_raid_manager_tick`, and restored the four survivors as ordinary
  `local function` declarations.
- Removed the legacy tick-driven raid path that only those definitions used:
  the nearby-controller fighter scan (`pcb_collect_raid_fighters`,
  `pcb_raid_controller_classes`, `raid_controller_class_cache`,
  `raid_fighter_cache`) and the duplicate raid-activity detector
  (`pcb_raid_objects`, `pcb_raid_class_candidates`). Raid phase now has one
  authoritative source, `pcb_raid_area_roster`, and the fighter roster one
  authoritative source, the deployment container.
- Removed unreachable helpers: `legacy_inventory_snapshot`,
  `relevant_inventory_surface`, `assignment_surface`, `probe_roster_surface`,
  `probe_assignment_surface`, `local_player_uid`, `distance_squared`,
  `vector_components`, `pcb_notify_base_worker_slot_changed`, and
  `pcb_parse_ranked_reserves`.
- Removed write-only Raid Manager state that nothing read after the legacy
  path went away: `reserve_count`, `fighter_count`, `downed_count`,
  `auto_deployable_count`, `base_name`, and `tick_count`. `reserve_count` and
  `fighter_count` duplicated `#raid_manager.reserves` and
  `deployed_count`; `auto_deployable_count` was recomputed from live lists
  three times per reinforcement pass and never read.
- Preserved the diagnostic probes by routing them through the authoritative
  `get_raid_state`: `include_probe` emits the raid-area, raid-metadata,
  Palbox-metadata, module-declaration, and combat reflection dumps, and the
  reserve census samples. Both advertised flags were previously accepted and
  ignored.
- Restored two diagnostics the surviving implementation had dropped:
  `data_expected_fighter_queue_last_reason`, and the cumulative
  `data_deployment_count` and `data_replacement_count`. Published
  `readiness_controller_available` and `readiness_world_key` in the heartbeat
  rather than delete the two readiness fields nothing read.

One intentional behavior change, ahead of Stage 5 because it fell out of the
same code:

- `get_raid_state` no longer forces a full Palbox scan on every call. A running
  manager already maintains an authoritative reserve queue, so the scan now
  happens only when the manager is off or `include_reserves` is requested.
  `data_reserves_live` reports which source answered.

## Stage 3: consolidate small primitives

Create one small helper for each responsibility:

- Reset Raid Manager state.
- Sample raid phase.
- Resolve worker-move identities.
- Deploy a worker.
- Withdraw a worker.
- Verify a roster move.
- Roll back a failed move.
- Validate a reserve candidate.
- Display a notification with an explicit severity.

Avoid boolean APIs whose meaning is unclear. For example, replace
`action_notification(false, text)` with explicit normal, warning, or persistent
severity.

## Stage 4: simplify Raid Manager

Use one state machine with only these states:

- `off`
- `deploying`
- `active`
- `waiting_for_reserves`

Handle only these events:

- Activation.
- Deployment continuation.
- Worker downed.
- Integrity check.
- Queue exhausted.
- Battle ended.
- Watchdog timeout.

Keep battle completion transition-based:

- A positively observed Battle phase arms the battle latch.
- A subsequent valid non-Battle phase stops Raid Manager.
- Two missing raid-instance samples after Battle are the guarded fallback.
- The 15-minute watchdog remains the final fallback.

## Stage 5: isolate performance-sensitive work

- Budget at most one worker deployment per dispatcher pass.
- Pace bulk deployments without adding a scheduler loop.
- Do not scan fighter health while filling empty slots.
- Use lightweight downed checks for deployed workers.
- Cache ranked reserve metadata.
- Rebuild the reserve queue only when exhausted or genuinely stale.
- Keep expensive diagnostics command-driven.
- Record pass duration and queue-build duration in heartbeat telemetry.

Initial performance gates:

- No multi-second non-spawn reinforcement pass.
- No full Palbox health profile during each deployment continuation.
- No repeated global object scan for each Pal in the same operation.
- No repeated notification for each bulk-deployment step.
- Activation must return without waiting for all 33 actors to spawn.

## Stage 6: regression and live verification

Required invariants:

- `npm run validate` passes.
- All existing MCP tests pass.
- There is one definition per authoritative operation.
- No new recurring loop or timer exists.
- PalCom interception remains private.
- Manual Palbox-to-base moves visibly spawn workers.
- Base-to-Palbox moves visibly withdraw workers.
- Bulk deployment remains paced.
- Downed replacement remains event-driven.
- `Battle -> Result` and `Battle -> Ready` stop Raid Manager.
- Idempotency and rollback remain intact.
- Hot reload generation guards still suppress stale loops and hooks.

## Delivery policy

Each stage should be reviewed as a source-only change first.

Do not install or hot reload a refactor build until the user explicitly
approves that specific test build.
