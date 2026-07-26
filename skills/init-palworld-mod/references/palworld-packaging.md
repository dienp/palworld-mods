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

## Thumbnail

Keep the final square image at `package/<PackageName>/thumbnail.png` and ensure
`Info.json` references `thumbnail.png`.

When generating a thumbnail:

1. Use authoritative screenshots or public gameplay references for featured
   items, rewards, and mechanics.
2. Use the `imagegen` skill to produce polished raster artwork.
3. Represent recognizable Palworld items faithfully; do not substitute generic
   objects when the item's design communicates the mechanic.
4. Match Palworld's bright stylized 3D presentation without copying logos,
   characters, or extracted game assets.
5. Prefer one clear claim, large silhouettes, high contrast, and minimal exact
   text that remains legible when reduced to a Workshop card.
6. Resize or optimize the final preview so it is strictly below Steam's 1 MiB
   `SubmitItemUpdate` limit while remaining legible.
7. Inspect the final PNG, verify its item counts and spelling, copy it into the
   package, increment the mod version, and run repository validation.

Observed acceptance criteria:

- Steam rejects previews at or above its size limit with
  `k_EResultLimitExceeded`; this can also mean insufficient Steam Cloud quota,
  but check preview size first.
- Steam documents a valid preview range of at least 16 bytes and strictly less
  than 1 MiB.
- This repository requires a valid PNG below 1,048,576 bytes. Square artwork is
  strongly recommended for Workshop-card presentation but is not treated as a
  Steam acceptance requirement.
- Prefer a high-quality 512x512 downscale for detailed generated artwork. Check
  the reduced image visually: preserve the primary silhouettes, exact text,
  contrast, and recognizable item details rather than merely minimizing bytes.

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
