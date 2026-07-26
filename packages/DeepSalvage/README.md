# Deep Salvage

A server-only Lua Palworld gameplay mod that occasionally turns vanilla
fishing salvage into a higher-cost, higher-reward Deep Salvage attempt for
every connected client.

## Behavior

Deep Salvage does not add another interaction. The normal **Salvage** action
remains unchanged in the UI.

One authoritative configurable roll occurs when a fishing-salvage attempt
opens:

- A selected roll requires one additional Fishing Magnet of the matching
  salvage rank.
- The same selected attempt receives a reward bonus if it succeeds.

The modifier applies to 100% of eligible salvage attempts. Each attempt costs
two magnets in total (one vanilla plus one Deep Salvage cost) and receives +100% of the
estimated base reward quantity while preserving any active Jellroy bonus.

Production build `1.0.1` uses the 100% modifier chance with runtime
diagnostics disabled.

## Safety

- No native DLL or cooked asset is distributed.
- No interaction-interface hooks are registered.
- Deep Salvage consumes exactly one additional rank-matched Fishing Magnet.
- No chat or RPC control protocol is used.
- Clients do not install the mod.
- No UI is changed except one notification when a Deep Salvage attempt
  successfully activates.
- Reward changes are limited to fishing-junk salvage models identified by
  their runtime object or owner name.
- The modifier fails closed without consuming anything unless the player has
  at least two matching magnets and the server can resolve their inventory.
- Runtime diagnostics remain available through configuration.

## Layout

- `package/DeepSalvage/Scripts/main.lua` — UE4SS Lua entry point
- `package/DeepSalvage/Info.json` — official-loader metadata
- `docs/research.md` — design decisions and retired experiments
- `docs/testing.md` — current validation checklist
