# Testing

## Build

- Game revision: 82182 or newer
- Build version: `1.0.3`
- Mod type: Lua
- Deployment: server only; clients must not install the mod

## Startup

Temporarily set `debug_enabled = true` and `debug_console = true` for the
log-based checks in this document. The distributed configuration keeps both
disabled.

Require successful registration for:

- `request_open`
- `request_open_post`
- `salvage_result`
- `create_items`
- `salvage_result` must be a post-hook

Confirm `event=mod_loaded` reports `deployment=server-only` and the configured
modifier chance. No native `DeepSalvageNativeProof` mod may load.

## Deep Salvage cost

Use a temporary `modifier_chance = 1.0` server configuration:

1. Start a Rank 1 and Rank 2 fishing-salvage attempt.
2. Confirm `event=modifier_roll | selected=true`.
3. Confirm `event=extra_magnet_consumed`.
4. Confirm Rank 1 consumes two basic Fishing Magnets in total.
5. Confirm Rank 2 consumes two Powerful Fishing Magnets in total.
6. Confirm the vanilla Salvage interaction remains intact.
7. Confirm no UI changes appear beyond enabled debug notifications/messages.

Repeat with `modifier_chance = 0.0` and confirm only the vanilla single magnet
is consumed.

## Notification delivery

Run a listen server with the host and at least one remote client, using
`modifier_chance = 1.0`:

1. Salvage as the host. Confirm the host sees the activation notification and
   that `event=deep_salvage_notification | target=host | delivered=true` is
   logged.
2. Salvage as the remote client with `remote_notification_via_chat = false`.
   Confirm the host sees no notification and that
   `event=deep_salvage_notification | target=remote | delivered=false |
   reason=remote-chat-disabled` is logged.
3. Confirm the logged `player_id` matches the salvaging player in both cases.

Repeat step 2 with `remote_notification_via_chat = true`:

1. Confirm `delivered=true`.
2. Confirm the salvaging client receives the message.
3. Confirm no other player and no global channel receives it. A message that
   reaches everyone means `remote_notification_chat_category` does not select
   the whisper category on this game revision; restore the default and leave
   `remote_notification_via_chat` disabled until the correct value is known.

## Reward roll

Use `modifier_chance = 1.0` and succeed:

1. Confirm `event=modifier_roll | selected=true`.
2. Require a `reward_formula_item` audit for every returned stack.
3. Require `event=reward_formula_summary | formula_match=true`.
4. Confirm the final quantity follows:

   `final = round(base × (1 + Jellroy bonus + configured reward bonus))`
5. Confirm one `reward_formula_summary` debug notification displays each
   stack as:

   `base reward -> vanilla reward after Jellroy -> final modified reward`

Repeat with `modifier_chance = 0.0` and confirm no reward stack is changed.
Confirm failed and cancelled attempts grant no items.

## Random distribution

Restore the chance to `0.25`, run at least 100 attempts, and record the
selected count. Treat a grossly implausible distribution as a randomness or
lifecycle defect; do not require exactly 25 selections.

## Isolation and regression

- Ordinary treasure boxes must never produce `reward_roll`.
- Rank 1 and Rank 2 fishing-junk salvage must both produce attempt logs.
- A selected Rank 1 attempt consumes one extra
  `Salvage_TreasureBoxKey01`.
- A selected Rank 2 attempt consumes one extra
  `Salvage_TreasureBoxKey02`.
- With fewer than two matching magnets, the modifier fails closed and consumes
  no additional magnet.
- Two concurrent players must bind rewards to separate model keys.
- Expired attempts must be removed without affecting a later attempt.
- Removing the mod must restore completely vanilla behavior.
