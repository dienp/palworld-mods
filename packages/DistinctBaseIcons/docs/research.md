# Research log

## Environment

- Palworld install: `E:/SteamLibrary/steamapps/common/Palworld`
- Game content timestamp: 2026-07-15
- Main pak: `Pal/Content/Paks/Pal-Windows.pak`
- UE4SS present: no
- Existing Workshop content: none detected

## Target assets found in the 1.0 manifest

Primary target:

`Pal/Content/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconCamp.uasset`

Control/comparison target:

`Pal/Content/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower.uasset`

The separate widgets are strong evidence that camps can be styled without
affecting all fast-travel locations. This must still be verified by inspecting
their widget trees, imports, textures, and default brush colors.

## Implementation decision

Choose the first successful path in this order:

1. **Texture replacement** — if `WBP_Map_IconCamp` references a camp-only
   texture, recolor that texture and package it at the original virtual path.
2. **Widget patch** — if the camp widget has its own image brush or default
   tint, patch only `WBP_Map_IconCamp`.
3. **Runtime tint** — if a shared widget/texture receives its color dynamically,
   hook camp widget construction and set its image color via UE4SS/LogicMod.

## Initial visual specification

- Default accent: orange (`#FF9F1C`) for contrast against Palworld's blue map
  locations.
- Preserve the original silhouette.
- Preserve selected/hovered/disabled state feedback.
- Avoid relying on red/green distinction alone.

## Acceptance tests

1. Player base markers use the new accent at every map zoom level.
2. Discovered fast-travel tower markers retain their vanilla color.
3. Hover, selection, and fast-travel interactions still work.
4. Multiple player bases are all styled consistently.
5. Single-player and a joined multiplayer session load without warnings.
6. Removing the mod restores vanilla visuals without affecting the save.

## Next inspection

- Export `WBP_Map_IconCamp`, `WBP_Map_IconFTTower`, and their dependencies with
  FModel using current Palworld 1.0 mappings.
- Compare their package properties and referenced textures.
- Record hashes of original assets and tool versions.

## Implemented prototype

The camp widget's `SetEnable` Blueprint function selects between two colors:

- Enabled: `(0.15, 0.905555, 1.0, 1.0)` — vanilla cyan
- Disabled: `(0.4, 0.4, 0.4, 1.0)` — retained unchanged

The prototype changes only the enabled RGB constants to approximately linear
RGB `(1.0, 0.346704, 0.011612, 1.0)`, corresponding to sRGB `#FF9F1C`.

Validation by re-parsing the generated asset shows exactly those three float
constants changed. The release pak contains only:

- `WBP_Map_IconCamp.uasset`
- `WBP_Map_IconCamp.uexp`

## Dev 6 color correction

The enabled camp icon receives two widget tints:

- `SetEnable` applies cyan for the enabled state.
- `SetSameGuild` applies a second cyan for same-guild camps.

Dev 5 neutralized `SetEnable` and the widget-template tint, but missed
`SetSameGuild`. Multiplying the orange material by that remaining cyan produced
the observed olive green. Dev 6 changes all three same-guild/enabled widget
tints to white, while leaving the different-guild red and disabled gray states
unchanged. The orange material instance remains the sole source of the normal
same-guild icon color.
