# Palworld 1.0 packaging reference

## Official package

Each registered Workshop item contains:

```text
<WorkshopId>/
  .workshop.json
  Info.json
  thumbnail.png
  Paks/ | LogicMods/ | Scripts/ | PalSchema/
```

Core `Info.json` fields:

- `ModName`: user-facing name.
- `PackageName`: alphanumeric deployment identity.
- `Version`: increment for every distributed test build.
- `DebugMode`: reinstall each launch when true.
- `MinRevision`: minimum supported game revision; use 0 only for initial private development.
- `Dependencies`: package names, not display names.
- `InstallRule`: loader type and relative source folders.

Deployment targets:

- Paks → `Pal/Content/Paks/~WorkshopMods/<PackageName>`
- LogicMods → `Pal/Content/Paks/LogicMods`
- Lua → `Mods/NativeMods/UE4SS/Mods/<PackageName>`
- PalSchema → `Mods/NativeMods/UE4SS/Mods/PalSchema/mods/<PackageName>`

## Development registration

Use Pocketpair's Palworld Mod Uploader. Hold Shift when creating a local-only item if supported by the current uploader. A numeric folder invented manually is not sufficient: Steam subscription state is recorded in `steamapps/workshop/appworkshop_1623730.acf`.

For client testing:

1. Keep the item Hidden.
2. Upload it.
3. Subscribe to it.
4. Enable it in `Options → Mod Management`.
5. Save and allow restart.
6. Verify `Mods/ManagedMods/<PackageName>/InstallManifest.json`.

The uploader may hold stale form values or rewrite `DebugMode`. Reload/select the item and verify version, package name, type, and debug state immediately before upload.

## Pak validation

Before deployment:

1. List archive entries.
2. Verify mount point `../../../`.
3. Prefer a container version known to work with the current Palworld build.
4. Hash the source archive.
5. After deployment, hash the installed archive and compare.

Include only intentional overrides. A replacement requires the exact original virtual path.

## Common false signals

- Generic mod warning: detects modified/additional content, not successful asset override.
- Mod Management entry: proves metadata recognition, not deployment or behavior.
- Game launch: does not prove the intended asset/hook ran.

Use an observable behavior plus matching installed hash as proof.
