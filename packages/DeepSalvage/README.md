# Deep Salvage

A Palworld 1.0 gameplay mod that adds **Deep Salvage**, a higher-risk salvage
choice, without replacing the vanilla interaction.

## Development target

The next development version is intended to:

- keep vanilla **Salvage** unchanged;
- add **Deep Salvage**, requiring the same 1 Magnet;
- give Deep Salvage a tighter success range and faster cursor;
- improve rewards only after a successful Deep Salvage attempt;
- permanently consume the Magnet when Deep Salvage fails or is abandoned;
- preserve vanilla failure behavior.

The validated target architecture is a native secondary-interaction component,
a cooked salvage-specific asset that attaches it, and UE4SS Lua for
hot-reloadable gameplay policy. Lua will carry the selected mode into the
minigame and modify only the authoritative successful reward.

## Status

The crash-safe `0.1.0-dev.16` Lua package is installed, but the Deep Salvage
interaction is not implemented yet. The prompt-only LogicMod bridge could not
create an action, the UE4SS interface hook crashed when inspecting a salvage
point, and PMK reflection confirmed that a cooked Blueprint alone cannot
override the native action-info function.
The hidden development Workshop item is `3771275627` (original uploader
placeholder: `MyAwesomeMod`, author `ptd`). Its registered local directory
must be populated only while Palworld is stopped.

The current Lua entry point includes:

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
- timeout cleanup and fail-closed hook registration.

It deliberately does not register the unsafe interaction hooks. The next gate
is a minimal native-component proof that creates `Interact2` and receives its
callback without invoking Lua from the indicator-query hot path.

The first native gate is implemented in [`native-proof/`](native-proof/). It
uses a UE4SS C++ post-hook to avoid Lua parameter marshalling, copies the
vanilla action metadata into `Interact2`, and logs the native
`StartTriggerInteract(Interact2)` callback. It is source-only until it passes
live client testing; no proof DLL is included in the Workshop payload.

## Layout

- `docs/` — research and test records
- `src/` — reproducible patch tooling
- `work/original/` — extracted vanilla assets (ignored)
- `work/staging/` — generated overrides (ignored)
- `dist/` — packaged test builds (ignored)
- `package/DeepSalvage/Scripts/` — UE4SS Lua entry point
- `package/DeepSalvage/` — official-loader package metadata
