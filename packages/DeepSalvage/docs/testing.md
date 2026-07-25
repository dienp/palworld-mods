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
