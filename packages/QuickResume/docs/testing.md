# Testing

## Build

- Game revision: 82182 or newer
- Installed Steam build ID researched: 24467282
- Build version: 0.1.0-dev.2
- Build mode: Development
- Loader DebugMode: true
- Runtime debug notifications: true
- Runtime debug console: true

## Clean-launch case

1. Exit Palworld normally.
2. Ensure at least one local world exists.
3. Start Palworld.
4. Expect the ordinary mod-caution widget to be confirmed automatically.
5. Expect the first timestamp-sorted local world to start automatically.
6. Verify the UE4SS log contains `mod_caution_created`,
   `mod_caution_confirmed`, and `resume_start_requested` exactly once.

## Crash-warning safety case

This case must only be performed after backing up saves.

1. Arrange for Palworld's own recent-crash/mod warning to appear on the next
   launch without modifying the game's main pak.
2. Start Palworld.
3. Expect the warning to remain visible and the world not to start.
4. Verify the UE4SS log contains `crash_warning_detected`.
5. Verify there is no `resume_start_requested` event in that launch.

## Other startup modal case

1. Start a launch that shows the mod disclaimer, EULA, health warning, or
   another standard title dialog.
2. Expect Quick Resume not to interact through that dialog.
3. Verify the UE4SS log contains `startup_modal_detected`.

## Compatibility case

1. Ensure `AutomaticallySkipModCaution` is not installed; Quick Resume already
   includes its ordinary-caution behavior.
2. Verify only one ordinary-caution confirmation is logged.

## Payload verification

- Source archive SHA-256:
  `3394395489D0073E3D5A95978E5892A15F3EC6709D3DC38C5FB09FBC02657ECC`
- Installed archive hash:
- Installed Lua path:
  `Mods/NativeMods/UE4SS/Mods/QuickResume/Scripts/main.lua`
- Install manifest:
  `Mods/ManagedMods/QuickResume/InstallManifest.json`
- Actual result: not yet run in game
- Screenshot/log:
