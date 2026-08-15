# More Fishing Salvage Reward

A server-only Lua Palworld mod that increases fishing salvage rewards for
every connected player.

## Behavior

The normal **Salvage** action remains unchanged.

For each eligible fishing salvage attempt:

- One extra Fishing Magnet of the matching rank is used.
- A successful salvage grants 200% total estimated base reward.
- Any active Jellroy multiplier is applied after the reward increase.

The current configuration applies this to 100% of eligible attempts, so each
attempt uses two magnets in total: one vanilla cost and one extra cost.

Production build `1.0.5` increases rewards on every eligible attempt, with runtime
diagnostics disabled.

## Notification delivery

The activation notification belongs to the player whose salvage attempt was
selected, not to whoever runs the server.

- The salvaging player's controller is resolved from the authoritative attempt.
- A listen-server host sees the notification only for their own attempts.
- A server-only mod cannot draw on an unmodded remote client's HUD.
  `PalLogManager` exists once per process, so the host's log manager is the
  host's own HUD. Remote clients are reachable only through a replicated
  chat message.
- `remote_notification_via_chat` enables that replicated delivery. It is
  disabled by default because `remote_notification_chat_category` must be
  validated against the live chat enum first. With it disabled, a remote
  player's attempt produces no notification anywhere.

## Safety

- No native DLL or cooked asset is distributed.
- No interaction-interface hooks are registered.
- The mod consumes exactly one additional rank-matched Fishing Magnet.
- No chat or RPC control protocol is used. The default build sends no chat
  message; the opt-in remote notification is one outbound whisper to the
  salvaging player and accepts no inbound commands.
- Clients do not install the mod.
- No UI is changed except one notification when the extra reward activates.
- Reward changes are limited to fishing-junk salvage models identified by
  their runtime object or owner name.
- The extra reward does not activate or consume anything unless the player has
  at least two matching magnets and the server can resolve their inventory.
- Runtime diagnostics remain available through configuration.

## Layout

- `package/DeepSalvage/Scripts/main.lua` — UE4SS Lua entry point
- `package/DeepSalvage/Info.json` — official-loader metadata
- `docs/research.md` — design decisions and retired experiments
- `docs/testing.md` — current validation checklist
