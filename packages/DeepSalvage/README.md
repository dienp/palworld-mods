# Deep Salvage

A Palworld 1.0 gameplay mod that adds **Deep Salvage**, a higher-risk salvage
choice, without replacing the vanilla interaction.

## Development target

Version `0.1.0-dev.9` will:

- keep vanilla **Salvage** unchanged;
- add **Deep Salvage**, requiring the same 1 Magnet;
- give Deep Salvage a tighter success range and faster cursor;
- improve rewards only after a successful Deep Salvage attempt;
- permanently consume the Magnet when Deep Salvage fails or is abandoned;
- preserve vanilla failure behavior.

The project is a UE4SS Lua mod. Runtime hooks are needed to add an interaction
choice, wager the Magnet correctly, carry the selected mode into the
minigame, and enhance only the authoritative successful reward.

## Status

Development implementation complete; live client/server verification remains.
The hidden development Workshop item is `3771275627` (original uploader
placeholder: `MyAwesomeMod`, author `ptd`). Its registered local directory
must be populated only while Palworld is stopped.

The Lua entry point includes:

- a second `Interact2` Deep Salvage choice;
- unsafe interface-level indicator hooks disabled after runtime crash evidence;
- per-player and per-treasure attempt tracking;
- harder salvage-model parameters;
- failure-side Fishing Magnet consumption with before/after auditing;
- additive Jellroy/Deep reward calculation with per-item formula auditing;
- toggleable Palworld notification diagnostics, retained but disabled for
  production releases;
- cached hot-path object classification and Palworld log-manager lookup;
- aggregated interaction performance counters without per-refresh log spam;
- idle-aware state cleanup scheduling;
- avoid retaining temporary hook parameters across game-thread scheduling;
- no client/server version handshake or recurring protocol messages;
- hook the reflected interactive-object interface instead of the concrete
  capsule class, where the functions are not registered;
- timeout cleanup and fail-closed hook registration.

If a required reflected hook fails to register, the failure is written to the
UE4SS log rather than silently enabling a partial mechanic.

## Layout

- `docs/` — research and test records
- `src/` — reproducible patch tooling
- `work/original/` — extracted vanilla assets (ignored)
- `work/staging/` — generated overrides (ignored)
- `dist/` — packaged test builds (ignored)
- `package/DeepSalvage/Scripts/` — UE4SS Lua entry point
- `package/DeepSalvage/` — official-loader package metadata
