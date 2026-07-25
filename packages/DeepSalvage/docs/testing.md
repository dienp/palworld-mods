# Testing

## Build

- Game revision: 82182 or newer
- Build version: `0.1.0-dev.16`
- Package: `DeepSalvage-0.1.0-dev.16.zip`
- Deployment: server and every participating client
- Debug mode: enabled

## Mandatory startup checks

With `CONFIG.debug_enabled = true`, confirm diagnostics appear as Palworld
notification messages. Set it to `false`, restart, and confirm no diagnostic
notifications appear while Deep Salvage remains functional. Development builds
use `debug_console = true`; temporarily set it to `false` only when validating
notification-only behavior.

For the crash-safe Lua checkpoint, confirm these required hooks report
`event=hook_registration | ... | ok=true`:

- `trigger_interact`
- `chat_receive`
- `request_open`
- `salvage_result`
- `create_items`
- `cancel_salvage`

Confirm `event=interaction_option_disabled` reports
`reason=unsafe-interface-detour`. Neither `get_indicator_info` nor
`get_indicator_text` may be registered in this checkpoint.

Also confirm `event=object_notification_registration | ... | ok=true`.
Any failure blocks release.

## Performance checks

- Look at a salvage point for at least 30 seconds.
- Confirm there is no per-refresh `indicator_deep_option` event.
- Confirm `performance_counters` appears at most once per 10 seconds while
  interaction checks are active.
- Confirm `salvage_cache_hit_rate` approaches `1.0000` after the first lookup
  for a component.
- Trigger the same warning repeatedly and confirm Palworld notifications are
  limited to one per event every two seconds while console evidence remains
  complete.
- Stand away from salvage points with no active attempt and confirm the
  cleanup loop emits no events and schedules no observable work.
- Compare frame time for 60 seconds with Deep Salvage enabled and disabled.

## Client/server installation

Install the same package on the server and every participating client. Confirm
there are no `handshake_*`, `HELLO`, or `ACK` messages. A missing client copy
means the second interaction is unavailable; a missing server copy means the
authoritative wager and reward rules are unavailable. Vanilla Salvage must
remain available in either case.

## Native interaction proof gate

The current Lua checkpoint does not expose Deep Salvage. Before enabling the
gameplay tests below, the native component and cooked asset must prove:

`approach salvage -> two action slots -> press Interact2 -> native callback`

The native proof must use no Tick, recurring timer, global object scan, or
indicator-query logging. It requires a game restart; Lua gameplay-policy
changes remain hot-reloadable.

Build and install the source in `native-proof/`, then require these UE4SS log
events:

- `event=init_ok`
- `event=indicator_patch_ok` once after the first matching salvage point
- `event=interact2_callback_ok` when the second action is pressed

Treat `event=indicator_conflict`, `event=interact2_ignored`, or any
`event=indicator_patch_failed` entry as a failed gate. The callback succeeds
only when `TargetInteractiveObject` resolves to an allowed Rank 1 or Rank 2
fishing-junk salvage object.

The first proof deliberately uses the existing `CommonInteract04` label. Do
not add the Deep Salvage text override until the action-to-callback chain
passes without a crash.

## Interaction and difficulty (pending native proof)

- Approach a Magnet salvage spot with at least one Fishing Magnet.
- Confirm both vanilla Salvage and `Deep Salvage — Wager 1 Magnet` appear.
- Confirm vanilla Salvage retains the original parameters.
- Select Deep Salvage and confirm:
  - `event=deep_input_selected`
  - `event=deep_selection_accepted`
  - `event=deep_attempt_bound`
  - `event=deep_model_configured`
  - range changes to `5.0`
  - cursor speed changes to `90.0`
- Repeat with zero Fishing Magnets; Deep Salvage must be blocked.

## Failure and cancellation

Record Fishing Magnet count before the attempt.

- Fail Deep Salvage intentionally.
- Confirm `event=magnet_consume_audit` reports:
  - `item=Salvage_TreasureBoxKey01`
  - `expected_delta=-1`
  - `observed_delta=-1`
  - `verified=true`
- Confirm no reward is granted.
- Cancel after the minigame begins and verify the authoritative false result
  produces the same one-Magnet loss.
- Confirm duplicate result callbacks never consume two Magnets.
- Disconnect and expire an attempt; inspect `deep_attempt_expired`. Do not
  release until the desired disconnect charging policy is confirmed.

## Reward formula

For every successful Deep Salvage item, require:

`final = round(base × (1 + Jellroy bonus + 1.00))`

The server prints one `reward_formula_item` line per stack containing:

- `item`
- `vanilla_after_jellroy`
- `estimated_base`
- `jellroy_multiplier`
- `jellroy_bonus`
- `deep_bonus`
- `expected_final`
- `actual_final`
- `formula_match`

The summary must report:

`event=reward_formula_summary | formula_match=true | reward_applied=true`

Test:

- no Jellroy: expected `2.00x`;
- Jellroy +50%: expected `2.50x`;
- Jellroy +95%: expected `2.95x`;
- multiple reward item stacks;
- base quantities that expose integer-rounding differences.

If the inferred base does not match observed vanilla loot-table behavior,
capture the full audit lines and replace inference with an earlier base-value
hook before release.

## Multiplayer isolation

- Two players start different salvage attempts concurrently.
- One chooses vanilla and one chooses Deep Salvage.
- Confirm only the Deep attempt receives harder parameters and bonus loot.
- Confirm rewards and Magnet loss are charged to the correct player.
- Repeat on a dedicated server and a listen server.

## Pre-release production gate

All items below block a public Workshop release. Record evidence for each
supported game and UE4SS build; do not infer success from startup alone.

### Reproducible native build

- Record the exact Palworld game revision.
- Record the exact `experimental-palworld` release and RE-UE4SS commit used to
  compile `main.dll`.
- Build `Game__Shipping__Win64` from a clean checkout on Windows.
- Confirm the source tree and submodules are clean after the build.
- Record SHA-256 hashes for `main.dll`, the Lua entry point, and the final
  Workshop archive.
- Confirm the DLL exports `start_mod` and `uninstall_mod`.
- Confirm the release archive contains no PDB, local paths, extracted assets,
  SDK files, caches, saves, or development configuration.

### Reflection and compatibility

- Confirm enum lookup resolves `Interact2` and `CommonInteract04` by name.
- Confirm `ActionInfo`, `Interact1_Indicator`, `Interact2_Indicator`,
  `IndicatorType`, and `bValid` pass runtime type validation.
- Confirm Rank 1 and Rank 2 salvage targets both pass the class allowlist.
- Confirm an unknown or changed class fails closed without modifying its
  interaction metadata.
- Confirm an existing valid `Interact2` produces `event=indicator_conflict`
  and remains unchanged.
- Repeat the compatibility check after every Palworld or UE4SS update.

### Native interaction stability

- Approach Rank 1 and Rank 2 salvage points at least 50 times each.
- Remain aimed at each salvage point for at least 60 seconds.
- Confirm there is no crash, hang, per-refresh logging, or growing memory use.
- Confirm exactly two action slots appear.
- Confirm vanilla Salvage remains unchanged and usable.
- Confirm controller and keyboard input both dispatch the second action.
- Confirm every successful proof contains the same allowed salvage target in
  `indicator_patch_ok` and `interact2_callback_ok`.
- Treat `indicator_patch_failed`, `indicator_conflict`,
  `interact2_ignored`, a missing callback, or a mismatched target as failure.

### Authority and concurrency

- Verify Deep Salvage selection is accepted authoritatively by the host or
  dedicated server, never solely by the client.
- Correlate player, treasure instance, and attempt ID before applying wager,
  difficulty, or reward changes.
- Test two players interacting with the same treasure concurrently.
- Test two players using different treasures concurrently.
- Test vanilla and Deep Salvage attempts concurrently.
- Test cancellation, failure, success, death, teleport, disconnect, reconnect,
  and server shutdown without duplicate charges or rewards.
- Confirm stale attempt state expires and cannot bind to a later vanilla
  attempt.

### Packaging and clean installation

- Package the C++ mod as `dlls/main.dll` without flattening the `dlls`
  directory.
- Confirm `Info.json` declares the required Lua/C++ installation rule and
  exact UE4SS dependency.
- Install the hidden Workshop item on a second clean client rather than copying
  files from the development installation.
- Install independently on a clean dedicated server.
- Confirm Workshop update and unsubscribe both replace/remove the expected
  files without leaving an older DLL behind.
- Confirm a missing client copy leaves vanilla Salvage usable.
- Confirm a missing server copy cannot apply client-authoritative rewards or
  inventory changes.
- Confirm antivirus scanning and Steam download do not quarantine or omit
  `main.dll`.

### Compatibility, rollback, and release evidence

- Test with Visible Fishing Salvage Spots and confirm shared asset changes are
  merged rather than selected by pak load order.
- Test with the declared UE4SS dependency only, then with the supported mod
  collection.
- Confirm Deep Salvage does not overwrite another mod's `Interact2`.
- Back up saves before all persistence tests and verify vanilla saves load
  after removing the mod.
- Prepare a tested rollback archive and removal instructions before public
  release.
- Disable development notifications while preserving console diagnostics
  needed for support.
- Capture client and server logs, screenshots or video of both action slots,
  the matching callback, Magnet accounting, and reward-formula results.
- Keep the Workshop item hidden until every blocking item has recorded
  evidence and no unexplained warning remains.

## Evidence

- Development archive SHA-256:
  `611BB7A4751B35413F9A196019DCBF103C7F560B3D88AE9A756CCB161CC2BF87`
- Packaged source `Scripts/main.lua` SHA-256:
  `5F207A9E70E01E6C80867E13500063993B4F605298B1FA23AA2D4101609C69EB`
- Packaged thumbnail SHA-256:
  `3008005C23DBC988F2AF24787F1D2AB3BEDCC69043B1C1C6D9E64047B3259B4E`
- Installed client script SHA-256:
- Installed server script SHA-256:
- Client UE4SS log:
- Server UE4SS log:
- Screenshot/video:
- Actual result:
