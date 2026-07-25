# Scatterspam Capture 1.0.0 release checklist

- [ ] Create or select a real item in Palworld Mod Uploader.
- [ ] Keep the initial Workshop visibility Hidden.
- [ ] Copy the contents of `ScatterspamCapture-1.0.0` into the registered item.
- [ ] Confirm package name `ScatterspamCapture`, version `1.0.0`, Lua type,
      `DebugMode: false`, and minimum revision `82182`.
- [ ] Upload, subscribe, and enable the mod in Palworld Mod Management.
- [ ] Add `WorkshopMedia/ScatterspamCapture-percentage-closeup.jpg` as the
      primary gameplay gallery image.
- [ ] Add `WorkshopMedia/ScatterspamCapture-let-it-ride.png` as a Workshop
      gallery image.
- [ ] Restart Palworld when prompted.
- [ ] Verify `Mods/ManagedMods/ScatterspamCapture/InstallManifest.json`.
- [ ] Compare the installed `Scripts/main.lua` SHA-256 with `SHA256SUMS.txt`.
- [ ] Confirm sub-1% aiming shows three truncated decimals.
- [ ] Confirm rates at or above 1% retain vanilla formatting and `%`.
- [ ] Confirm ineffective-sphere notifications are suppressed during scatter spam.
- [ ] Confirm no severe frame drop during repeated scatter-launcher use.
- [ ] Remove or disable the loose UE4SS development copy before managed testing.
- [ ] Make the Workshop item public only after all checks pass.
