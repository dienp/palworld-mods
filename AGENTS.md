# Agent guidance

This repository contains Palworld mods orchestrated by Nx.

## Repository conventions

- Keep each mod in `packages/<PackageName>`.
- Keep reusable Codex skills in `skills/<skill-name>`.
- Treat `package/<PackageName>` as the exact loader/Workshop payload.
- For Lua mods, keep the entry point at `package/<PackageName>/Scripts/main.lua`
  and set the Lua install rule target to `"."`. Targeting `"./Scripts/"`
  flattens `main.lua` into the installed mod root; UE4SS requires
  `<PackageName>/Scripts/main.lua` and will not load the flattened mod.
- Keep research notes and reproducible source code; do not commit extracted game assets, installed tools, caches, saves, or local backups.
- Store machine-specific paths in ignored `*.local.json` files. Committed `mod-project.json` files must use repository-relative paths or empty values.
- Preserve runtime diagnostic switches in Lua sources. Production releases disable diagnostics through configuration rather than deleting instrumentation.

## Required checks

- Run `npm run validate` after changing package metadata or payloads.
- Run `npm run build` after changing a .NET asset tool.
- Increment the mod version for every distributed test build.
- Verify packaged payloads and install manifests during game testing; the generic mod warning is not proof that a mod loaded.

## Safety

- Never modify Palworld's main pak.
- Never commit copyrighted game assets.
- Keep loose `~mods` tests separate from Workshop-managed tests.
- Do not publish a Workshop item or GitHub release without explicit authorization.
- Never close or terminate Palworld without explicit authorization from the
  user at that time.
- Back up saves before testing changes that may persist state.
