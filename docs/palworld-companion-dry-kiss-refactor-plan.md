# Palworld Companion Bridge DRY/KISS refactor plan

Status: planned; no refactor implementation or installation has started.

Last updated: 2026-08-06

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

At the time of this plan:

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

## Stage 1: establish guardrails

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

Add static validation that rejects:

- Duplicate function definitions.
- Known shadowed Raid Manager entry points.
- Obvious unused local functions where practical.

## Stage 2: remove shadowed legacy code

- Remove the obsolete definitions of:
  - `pcb_get_raid_state`
  - `pcb_set_raid_manager`
  - `pcb_stop_raid_manager`
  - `pcb_raid_manager_tick`
- Remove genuinely dead helpers.
- Preserve useful diagnostic probes by routing them through the single
  authoritative `get_raid_state` implementation.
- Make no intentional runtime behavior changes in this stage.

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
