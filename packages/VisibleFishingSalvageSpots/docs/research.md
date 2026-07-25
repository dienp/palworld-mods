# Research

## Goal

Make active fishing salvage spots easier to notice from a distance and against
visually busy water.

## Candidate assets or hooks

- `Pal/Content/Pal/Model/Other/SalvageSpot/SM_SalvageSpot`
- `Pal/Content/Pal/Model/Other/SalvageSpot/Material/MI_PalProp_SalvageSpot`
- `Pal/Content/Pal/Model/Other/SalvageSpot/Material/MI_PalProp_SalvageSpot_Rank2`

Start with a Paks-based asset override. Prefer a high-contrast emissive cue or
vertical beam that remains readable in daylight, at night, and through water
surface reflections.

## First implementation

The salvage materials inherit from
`Pal/Content/Pal/Material/Prop/MI_PalPropBase`, whose parent material
`M_PalLit` exposes `Base Color Intensity` and `Base Emissive Intensity`.

Build `0.1.0-dev.1` overrides those two scalar parameters on both salvage
material instances:

- Base Color Intensity: `2.0`
- Base Emissive Intensity: `8.0`

This changes four files (`.uasset` and `.uexp` for each material instance) and
does not replace the mesh or textures.

## Final marker implementation

Release `1.0.0` uses Palworld's built-in pickup marker:

- Source Niagara system:
  `Pal/Content/Pal/Effect/Common/Glow/NS_ItemPickupTower_Glow`
- Marker scale:
  `0.25`
- No Niagara or ray-material asset is packaged by the mod.

The normal and Rank 2 salvage treasure actors already contain a Niagara
component. Their original `NS_SingleStar` references are repointed to the
original pickup-marker system, avoiding additional Blueprint runtime logic and
unsafe cooked-Niagara cloning. The system retains its original color.

## Dependencies

- Palworld 1.0 game files at the configured `GamePath`.
- FModel and local mappings for asset discovery.
- repak for extraction and packaging.

## Compatibility notes

- Client-side visual behavior only.
- Do not modify loot tables, spawn logic, interaction range, or save data.
- Keep original extracted files under `work/original` and generated overrides
  under `work/staging`.
- If the chosen material or effect is shared with unrelated world objects,
  patch the owning salvage-spot asset instead of globally replacing it.
- Both overridden materials are dedicated to the salvage-spot model family.
