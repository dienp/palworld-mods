---
name: inspect-palworld-pak
description: Safely inventory, search, compare, and selectively read Palworld Unreal Engine PAK archives with repak, then route cooked asset serialization to FModel or UAssetAPI with matching mappings. Use when Codex needs to find game asset paths, enumerate Niagara systems or other package types, inspect PAK metadata, hash archive entries, extract one asset and its companions for research, or diagnose Palworld archive and mapping problems without bulk-extracting or committing copyrighted game assets.
---

# Inspect Palworld PAK

Use `scripts/inspect-palworld-pak.ps1` for deterministic archive operations.
Read [references/tool-selection.md](references/tool-selection.md) only when the
task requires cooked-property serialization, mappings, encrypted archives, tool
installation, or troubleshooting.

## Locate inputs

Prefer configured local paths, then discover:

- game root: Steam library containing `Palworld`;
- main archive: `<game>/Pal/Content/Paks/Pal-Windows.pak`;
- repak: `<repo>/tools/repak/repak.exe`;
- mappings: a local `Mappings.usmap` matching the installed game revision.

Keep machine paths out of committed `mod-project.json`. Use ignored
`*.local.json` files when persistence is necessary.

## Choose the smallest operation

1. Use `Info` for PAK version, mount point, and encryption facts.
2. Use `Search` to discover paths. Search the index before extracting.
3. Use `Get` for one exact entry. Add `-IncludeCompanions` for `.uasset`,
   `.uexp`, `.ubulk`, and `.uptnl` siblings that actually exist.
4. Use `HashList` only for explicit archive comparison or reproducibility; it
   reads every entry and is substantially more expensive.
5. Use FModel or UAssetAPI only after repak has identified the exact package.
   A `.usmap` is required for Palworld's unversioned cooked properties.

Examples:

```powershell
& skills/inspect-palworld-pak/scripts/inspect-palworld-pak.ps1 `
  -Mode Search `
  -PakPath "F:\SteamLibrary\steamapps\common\Palworld\Pal\Content\Paks\Pal-Windows.pak" `
  -Pattern '/NS_[^/]+\.uasset$'
```

```powershell
& skills/inspect-palworld-pak/scripts/inspect-palworld-pak.ps1 `
  -Mode Get `
  -PakPath "<Pal-Windows.pak>" `
  -Entry "Pal/Content/Pal/Effect/Common/Glow/NS_SingleStar.uasset" `
  -OutputDirectory "<ignored-work-dir>" `
  -IncludeCompanions
```

## Preserve evidence

- Record the game revision, PAK path, repak version, search expression, match
  count, and exact internal paths.
- Keep research extracts under an ignored `work/original` directory.
- Commit paths, hashes, commands, and derived research—not extracted assets.
- Verify candidates against the current archive instead of relying on memory.

## Guardrails

- Never modify Palworld's main PAK.
- Never bulk-unpack the main archive unless the user explicitly requires it
  and supplies an ignored destination with sufficient space.
- Never commit extracted game assets, mappings copied from the game, caches, or
  installed tools.
- Refuse ambiguous extraction targets and existing output files unless
  overwrite is explicitly authorized.
- Treat FModel preview limitations separately from archive readability:
  cooked Niagara systems can be enumerated and serialized, but not reliably
  animated outside the game.
