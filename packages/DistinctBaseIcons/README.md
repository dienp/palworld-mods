# Distinct Base Icons

Distinct Base Icons is a Palworld 1.0 client-side UI mod intended to make player
home bases immediately distinguishable from ordinary discovered map locations.

## Version 0.1 goal

- Recolor the existing home-base map marker without changing fast-travel towers.
- Keep save data and gameplay logic untouched.
- Prefer a lightweight patch pak; use a LogicMod only if the marker tint is
  assigned dynamically at runtime.
- Target the Steam build of Palworld 1.0 first.

## Current build

`dist/DistinctBaseIcons_Orange_P.pak` changes only the enabled, same-guild camp
marker color from vanilla cyan to orange (`#FF9F1C`). The disabled gray state and
fast-travel tower widget remain vanilla.

### Manual installation

Copy the pak into:

`Palworld/Pal/Content/Paks/~mods/DistinctBaseIcons_Orange_P.pak`

Create the `~mods` directory if it does not exist. Remove the pak to uninstall;
the mod does not modify saves.

## Current discovery

The Palworld 1.0 shipped asset manifest identifies separate widgets for camps
and fast-travel towers:

- `Pal/Content/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconCamp`
- `Pal/Content/Pal/Blueprint/UI/UserInterface/Map/WBP_Map_IconFTTower`

Related candidates include:

- `Pal/Content/Pal/Texture/UI/IngameMenu/T_icon_camp`
- `Pal/Content/Pal/Texture/UI/InGame/T_icon_compass_camp`
- `Pal/Content/Pal/Blueprint/System/BP_PalWorldMapUIData`
- `Pal/Content/Pal/DataTable/WorldMapUIData/DT_WorldMapUIData`

See [docs/research.md](docs/research.md) for the investigation log and decision
criteria.

## Repository layout

- `docs/` — research notes, decisions, and test plan
- `tools/` — local analysis tools (ignored by Git)
- `work/` — extracted/derived game assets (ignored by Git)
- `dist/` — packaged release artifacts (ignored by Git)
- `src/DistinctBaseIcons.AssetTool/` — reproducible Blueprint color patcher

No copyrighted game assets will be committed to this repository.

## Launching the asset browser

Run `launch-fmodel.cmd`. The launcher points FModel at the workspace-local .NET
8 runtime, so no machine-wide .NET installation is required.

On first launch, configure:

1. Add an undetected game named `Palworld`.
2. Set its directory to your local Palworld installation.
3. Select Unreal Engine version `GAME_UE5_1`.
4. In Settings, enable local mappings and select
   `tools\Mappings.usmap` from the monorepo root.

Then inspect/search for `WBP_Map_IconCamp` and compare it with
`WBP_Map_IconFTTower`.
