---
name: init-palworld-mod
description: Initialize, validate, and configure Palworld 1.0 mod projects with safe scaffolding, solution feasibility and performance gates, Workshop-compatible metadata and thumbnails, Paks/LogicMods/Lua/PalSchema selection, development versioning, toggleable diagnostics, packaging paths, and local tool discovery. Use when Codex needs to start, scaffold, bootstrap, design, debug, optimize, package, or standardize a Palworld mod.
---

# Initialize a Palworld mod

Use the bundled initializer for deterministic project creation:

```powershell
& powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File "<skill-dir>\scripts\init-palworld-mod.ps1" `
  -ProjectPath "<absolute-project-path>" `
  -ModName "<display name>" `
  -ModType Paks `
  -Author "<author>" `
  -BuildMode Development
```

The process-scoped bypass supports Windows systems that block direct `.ps1` execution; it does not change the user's execution policy.

Pass `-PackageName` only when the normalized default is unsuitable. Package names must be alphanumeric and contain no spaces.

The script refuses to initialize a non-empty directory unless `-Force` is explicitly authorized. Never use `-Force` merely for convenience.

## Workflow

1. Confirm the mod idea, mod type, destination, display name, package name, and author.
2. Run the initializer.
3. Inspect generated `mod-project.json` and `package/<PackageName>/Info.json`.
4. Discover the current Palworld installation and tools; update `mod-project.json` without copying large game/tool binaries into the project.
5. Before implementation, enumerate the viable technical solutions when the
   architecture is uncertain. Validate each against the installed game build,
   SDK/reflection data, local modding tools, authoritative documentation, and
   a minimal runtime probe when practical. Record:
   - feasibility and required dependencies;
   - client/server authority and trust boundaries;
   - hot-reload support versus restart/cook requirements;
   - packaging and deployment implications;
   - compatibility, update, and maintenance risks.
   Do not select a path merely because an API or Blueprint node appears to
   exist. Prove that the target function is reflected/callable and that the
   event reaches the required client or server context.
6. Evaluate performance before choosing a solution. Identify hot-path
   frequency, Tick/timer/polling work, global actor or object searches,
   reflection calls, network RPC/replication volume, transient allocations,
   debug/log volume, and state cleanup. Prefer event-driven hooks and a small,
   stable bridge with no Tick or recurring world scans. Treat repeated UI
   queries, notifications, or logs as hot paths. Define counters or timing
   probes that can verify the expected event budget in-game.
7. Compare the validated solutions and recommend the smallest option that
   meets the behavior, authority, compatibility, and performance constraints.
   Do not begin the production implementation until the chosen path passes
   these gates, unless the user explicitly requests an exploratory prototype.
8. Research the smallest exact asset or runtime hook needed. Keep originals under `work/original` and generated overrides under `work/staging`.
9. Package only intended override files. List and hash the resulting archive before installation.
10. For official-loader testing, create/register a hidden Workshop item with Palworld Mod Uploader, then place package contents in that registered item. Do not invent numeric Workshop IDs.
11. Create the Workshop thumbnail with the `imagegen` skill when polished
    raster art is appropriate:
    - inspect the mod's actual in-game behavior and gather authoritative
      visual references for featured Palworld items and rewards;
    - use user screenshots or public gameplay references rather than
      committing extracted game assets;
    - avoid generic stand-ins when a recognizable in-game item is central to
      the mod;
    - favor bright, readable, stylized 3D forms, clean outlines, and short
      exact text that remains legible at small Workshop-card size;
    - verify item counts, reward types, text spelling, square composition, and
      the final local `thumbnail.png` visually before packaging;
    - ensure the final preview image is at least 16 bytes and strictly below
      Steam's 1 MiB `SubmitItemUpdate` limit.
12. Increment `Version` for each distributed test build. Use loader
   `DebugMode: true` during development and verify the uploader did not reset
   it.
13. For Lua mods, retain runtime diagnostic switches in source:
   `debug_enabled`, `debug_notifications`, and `debug_console`. Enable all
   three for development. Prefer Palworld `PalLogManager:AddLog` notifications
   for player-visible diagnostics and console output for dedicated-server
   evidence. Add before/after values and explicit match flags around risky
   calculations or state mutations. Rate-limit or aggregate diagnostics in
   callbacks that may run repeatedly.
14. For a production release, keep the diagnostic code and scaffold/package
    with `-BuildMode Production`. This sets loader `DebugMode: false` and
    runtime `debug_enabled = false`; do not delete the instrumentation.
15. Verify the deployed file and
    `Mods/ManagedMods/<PackageName>/InstallManifest.json`, not merely the mod
    warning or menu entry. After deployment, use runtime evidence to confirm
    hook registration, event counts, authority, cleanup, and measured reward
    calculations. Re-open the solution decision if those observations
    contradict an assumption.

Read [references/palworld-packaging.md](references/palworld-packaging.md) when packaging, registering, deploying, or troubleshooting loader behavior.

## Guardrails

- Never modify Palworld's main pak.
- Never infer successful loading from the generic mod warning.
- Keep loose `~mods` tests separate from official Workshop-managed tests; disable duplicates.
- Do not publish publicly without explicit authorization. Keep development Workshop items hidden.
- Do not overwrite subscribed Workshop content while Palworld is running.
- Back up saves before testing mods that can persist content or state.
