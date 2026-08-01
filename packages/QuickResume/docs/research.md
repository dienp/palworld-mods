# Research

## Goal

Start the most recently played local Palworld world from the title screen
without user confirmation, but never bypass Palworld's recent-crash/mod
warning.

## Installed-build evidence

- Steam build ID: `24467282`.
- Target minimum revision: `82182`.
- `WBP_TItle.CheckModError` calls
  `PalModLoaderLibrary.IsNeedShowErrorOnNextStart` before creating the
  `MOD_DIALOG_NOTICE_CrashWithExternalMods` dialog.
- `WBP_TitleLocalWorldSelect.SetupWorldList` obtains a world display map,
  calls `GetSortedWorldDisplayInfoArray`, and supplies that array to
  `WBP_Title_WorldSelect.AddLocalWorldDisplayData`.
- `AddLocalWorldDisplayData` creates save-entry widgets in array order and
  appends the new-world entry afterward. The first scroll-box child is
  therefore the first timestamp-sorted existing world.
- Normal selection flows through
  `OnClickedWorldButton_Internal` and
  `OnClickedStartWorldButtonEventInternal`.

The evidence above was reproduced from the installed `Pal-Windows.pak`.
Extracted game assets and serialized inspection JSON remain under ignored
`work/original` and are not distributed.

## Candidate solutions

### Replace title or world-select assets

- Feasible as a Paks override.
- High update/compatibility cost because it replaces large UI Blueprints.
- Requires repacking copyrighted derived assets and conflicts with other UI
  mods.
- Rejected.

### Poll widgets and simulate button input

- Feasible in UE4SS Lua.
- Repeated global widget scans create an unnecessary title-screen hot path.
- Timing-sensitive and more likely to interact through a warning dialog.
- Rejected.

### Event-driven UE4SS Lua hooks

- Hooks the existing title safety decision and completed world-list setup.
- Uses `NotifyOnNewObject` for `PalUserWidgetOverlayUI` to observe dialog
  creation rather than infer it from timing.
- Automatically invokes the ordinary `WBP_ModCautionDialog` confirmation
  handler only after verifying that the recent-crash flag is false.
- Treats creation of a standard Pal dialog while the recent-crash flag is set
  as a permanent block for that launch.
- Calls Palworld's normal select/start functions on its already sorted first
  save entry.
- Rechecks the crash flag and startup-modal presence before both transitions.
- No Tick hook, timer loop, global actor scan, networking, or persistent save
  mutation.
- Selected.

## Dependencies and authority

- Client-side only.
- Requires `UE4SSExperimentalPW`.
- Uses local title UI and local save metadata; no server authority or network
  RPC is involved.
- Does not edit a save or Palworld's main pak.

## Performance budget

- Two Blueprint callbacks per normal launch.
- One overlay-widget creation observer and one ordinary-caution confirmation
  callback during startup.
- Two one-shot delays: 250 ms after the title safety check and 50 ms after the
  world list is populated.
- One additional 80 ms one-shot delay when the ordinary mod-caution widget is
  created.
- At most four fallback `FindFirstOf` modal checks per safety gate.
- Zero work after a world start is requested.
- Diagnostic counters cover title checks, crash blocks, modal blocks,
  world-list callbacks, starts, and failures.

## Compatibility notes

- Blueprint asset and function names may change in a Palworld update.
- The mod fails closed when the exact crash-state library is unavailable.
- The first-entry assumption depends on Palworld retaining its current
  timestamp sort before `AddLocalWorldDisplayData`.
- Hot reload can register hooks for the active Lua instance, but behavior
  should be verified from a clean title-screen launch.

## External reference

`AutomaticallySkipModCaution` 1.0.1 by AYNJ was inspected from its published
CurseForge archive (file ID `8478892`, SHA-256
`B53353DA9DC65EB03326579D59297A2380AB63497658A59E447EF6902D136C74`).
It observes `PalUserWidgetOverlayUI` creation, matches the ordinary
mod-caution/disclaimer widget name, waits 80 ms, and invokes its OK handler.
It does not inspect or distinguish Palworld's recent-crash warning. Its
creation-observer approach informed the independent lifecycle handling in
Quick Resume; the downloaded reference remains under ignored `work/original`.
