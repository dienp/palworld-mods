# Palworld Companion Bridge DRY/KISS refactor plan

Status: Stages 1 to 5 are implemented as a source-only change, and Stage 6 is
complete except for the checks that need Windows or a running game. Stages 1
and 2 landed in `0.1.0-dev.112`; Stages 3 to 5 landed in `0.1.0-dev.113`.
Nothing has been installed or hot reloaded.

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

`main.lua` went from 8,228 to 6,423 lines here, and 6,484 after Stages 3 to 5
added the shared primitives back.

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

## Stage 3: consolidate small primitives (implemented)

One helper per responsibility, each with a single authoritative call site:

| Responsibility | Helper |
| --- | --- |
| Reset Raid Manager state | `pcb_reset_raid_manager_state` |
| Sample raid phase | `pcb_observe_raid_phase` |
| Resolve worker-move identities | `pcb_worker_move_identity` |
| Deploy a worker | `pcb_request_worker_deploy` |
| Withdraw a worker | `pcb_request_worker_withdraw` |
| Verify a roster move | `pcb_move_verified` |
| Locate a Palbox slot | `pcb_resolve_palbox_slot` |
| Validate a reserve candidate | `pcb_reserve_rejection` |
| Count invalidated reserves | `pcb_recount_invalidated_reserves` |
| Notify with an explicit severity | `notify` |

`action_notification(success, text)` is replaced by `notify(severity, text)`
with named `normal`, `warning`, and `persistent` severities mapping to the Pal
log's 1-3 priority. The numeric priorities each call site produces are
unchanged.

`pcb_stop_raid_manager` moved above `pcb_swap_raid_pal` so the failed
replacement path can call it. That path previously set `mode` and
`stopped_reason` by hand because the function was declared later in the file,
which left the reserve queue, timers, event flags, and `manager_state` behind
and skipped the player notification. It now goes through the one reset.

Deployment, replacement, and the manual roster move had three separate copies
of identity resolution, the two worker RPCs, verification, and rollback. They
now share the primitives above. Three copies of "check the Palbox slot the Pal
was last seen in, else scan every page" became one.

## Stage 4: simplify Raid Manager (implemented)

`manager_state` now takes exactly the four documented values, defined once as
`MANAGER_STATE_OFF`, `MANAGER_STATE_DEPLOYING`, `MANAGER_STATE_ACTIVE`, and
`MANAGER_STATE_WAITING`. The previous ad-hoc strings `observing`,
`waiting_for_healthy_reserves`, and `""` are gone; `mode` already records
whether the player asked for observe or auto, so a running observer is simply
`active`. `deploying` is now reported while a paced batch is still in flight,
which nothing expressed before.

Battle completion stays transition-based and is unchanged in behavior: a
positively observed Battle phase arms the latch, a later valid non-Battle phase
stops the manager, two consecutive missing instance samples after Battle are
the guarded fallback, and the 15-minute watchdog is the last resort. That logic
moved out of `refresh_bridge_readiness` into `pcb_observe_raid_phase` so the
readiness refresh does one job.

## Stage 5: isolate performance-sensitive work (implemented)

- One roster-write budget covers the whole reinforcement pass, replacements
  included. Replacements were previously unbounded: a wipe could ask the game
  to reconcile every downed slot in a single dispatcher pass. Leftover work
  continues through the existing coalesced request, so no loop or timer was
  added.
- Empty-slot filling still does not scan fighter health, deployed-worker checks
  still use the lightweight downed probe, and the ranked reserve queue is still
  rebuilt only when exhausted or stale.
- Queue-build duration joins pass duration in heartbeat telemetry as
  `scheduler_last_queue_build_ms`.
- `get_raid_state` no longer forces a Palbox scan (see Stage 2).

## Stage 6: regression and live verification

Verified offline:

| Invariant | Result |
| --- | --- |
| `npm run validate` passes | Pass, including the new Stage 1 guards |
| One definition per authoritative operation | Pass, enforced by the validator |
| No unreferenced local functions | Pass, enforced by the validator |
| No write-only Raid Manager state | Pass |
| No new recurring loop or timer exists | Pass; the mod still registers exactly one `LoopAsync` |
| Chunk compiles | Pass, `luac -p` |
| Load, command, and scheduler paths run | Pass, `scripts/smoke.lua` |
| PalCom interception remains private | Unchanged by this refactor |
| Hot reload generation guards | Unchanged by this refactor |
| MCP protocol fields | No field any MCP call reads was removed; the C# side is untouched |

Blocked here, not skipped:

- **The MCP test suite could not be run.** `PalworldMcpServer` targets
  `net9.0-windows10.0.17763.0`, so it neither builds nor runs off Windows. The
  refactor changes no C# and removes no field the server reads, but the suite
  still needs one run on Windows before this is called done.

Still requires a live game:

- Manual Palbox-to-base moves visibly spawn workers.
- Base-to-Palbox moves visibly withdraw workers.
- Bulk deployment remains paced, now including replacements under the shared
  write budget.
- Downed replacement remains event-driven, and a multi-Pal wipe drains over
  successive passes instead of one frame.
- `Battle -> Result` and `Battle -> Ready` stop Raid Manager.
- Idempotency and rollback remain intact.
- `get_raid_state` reports `data_reserves_live=false` with a correct queue
  while the manager runs, and `true` when it is off.

## Delivery policy

Each stage should be reviewed as a source-only change first.

Do not install or hot reload a refactor build until the user explicitly
approves that specific test build.
