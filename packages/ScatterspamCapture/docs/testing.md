# Testing

- Game revision:
- Build version: 0.1.0-dev.26
- Source archive hash:
  `3403520A107D56467E8CA5FD0D1A3D786B5B6024D40C375928F33FDF2677542D`
- Installed archive hash:
  Lua script SHA-256:
  `E3ADDE19076CB49729EED5B2BBBE7159131D2D96B16A0FEC5E8FCD0B165D7701`
- Expected observable result:
- Capture probability shows exactly three fractional digits.
- An underlying `0.001` displays as `0.001`, not `0.00`.
- Trailing zeroes remain visible (for example, `12.500`).
- Capture behavior and unrelated percentage displays remain unchanged.
- The aiming readout omits `%`; the additional character position is used for
  the third fractional digit.
- Actual result:
- **FAILED — do not distribute.**
- Palworld crashes when a sphere is thrown and `OnStartedCapture` invokes the
  patched formatter.
- Crash: undefined Blueprint opcode `0x70` at byte offset `2510` in
  `WBP_PalGetReticle_C:Set Display Capture Rate Force`.
- Crash report:
  `C:\Users\dienp\AppData\Local\Pal\Saved\Crashes\UECC-Windows-080E68354028419485E973B572DCB07C_0000\CrashContext.runtime-xml`
- Installed pak was removed from `~mods` and preserved under
  `work/quarantined/ScatterspamCapture_0.1.0-dev.1_P.crashes-on-throw.pak`.

## UE4SS dev.2

- Replaces the cooked Blueprint patch with a post-formatter Lua hook.
- Installed under
  `Pal\Binaries\Win64\ue4ss\Mods\ScatterspamCapture`.
- Verify UE4SS loads the script and logs
  `[ScatterspamCapture] Loaded; waiting for the capture reticle`.
- Aim a sphere before throwing and confirm the final character is digit three.
- Throw a sphere and verify that capture starts without a crash.

Result: hook registration failed because the widget Blueprint was not loaded
when UE4SS started.

## UE4SS dev.3

- Loads the widget asset on the game thread before hook registration.
- Retries after game-state initialization and once per second until registered.
- Supports automatic Lua hot reload during development.

Result: delayed hook registration succeeded, but direct property lookup could
not access the non-variable digit widget.

## UE4SS dev.4

- Falls back to `GetWidgetFromName` so the cooked widget can be resolved
  through the UMG widget tree.

Result: `GetWidgetFromName` did not resolve the cooked child widget.

## UE4SS dev.5

- Adds `WidgetTree:FindWidget` and global short-name lookup fallbacks.
- Logs individual lookup failures for live diagnosis.

Result: aiming display successfully showed three fractional digits. The
post-throw sequence uses a separate widget and remained at two digits plus `%`.

## UE4SS dev.6

- Adds a delayed hook for
  `WBP_CaptureFailedPercent_C:Set Percent`.
- Reuses its reflected `Text_Pecent` widget for the third fractional digit.

Result: the aiming instance changed, but the reticle created when the sphere
hit still showed the vanilla value. Global widget lookup was selecting the
older reticle instance.

## UE4SS dev.7

- Resolves the third-digit widget by walking each candidate's outer chain and
  matching it to the exact reticle instance received by the hook.

Result: **FAILED — disabled during live testing.** The scoped lookup called
`FindObjects` repeatedly on the capture-rate update path and caused severe
frame loss while aiming. The installed script was hot-replaced with
`work/emergency-disable.lua`.

## UE4SS dev.8

- Uses `NotifyOnNewObject` to cache the most recently constructed third-digit
  widget.
- Seeds an existing widget with one lookup after startup/hot reload.
- Performs no object-array scans in the per-frame formatter hook.
- Screenshot/log:

Result: aiming and the sphere-hit display both showed the third decimal
without the dev.7 frame loss. The replaced suffix widget omitted `%`, and
single-digit rates such as `1.2%` appeared as `12`.

## UE4SS dev.9

- Retains `%` after the injected third digit in the normal layout.
- Reconstructs the full three-decimal suffix when Palworld hides decimal
  places for a single-digit rate (`1.2%` becomes `1.200%`).
- Silences the repeated unavailable-widget message on the hot formatter path.

## UE4SS dev.10

- Filters `UPalLogManager::AddLog` by exact English message prefix.
- Replaces only `This Sphere isn't working on ...` with empty text before the
  log manager displays it.
- Leaves all other gameplay log messages unchanged.

Result: the warning text became invisible, but each scatter projectile still
created a blank normal-log record.

## UE4SS dev.11

- Changes the exact warning's log priority to `EPalLogPriority::None` before
  `UPalLogManager::AddLog` dispatches it.
- This uses Palworld's non-queue path so scatter bursts do not accumulate
  invisible notification records.

## UE4SS dev.12

- Restores the leading zero that Palworld hides for rates below `1%`.
- The suffix widget owns the complete low-rate value, such as `0.500%`,
  instead of rendering `.500%`.

Result: **FAILED.** Palworld already retained two decimals below `1%`, so the
reconstructed suffix duplicated them (for example, `0.85.000`).

## UE4SS dev.13

- Reconstructs hidden decimals only from `1%` through `9.999%`.
- Below `1%`, retains Palworld's existing `0.xx` and appends only the third
  digit plus `%`.
- Calculates the third digit from percentage units rather than the raw
  fractional capture rate.

Result: **FAILED.** A temporary dev.14 diagnostic showed that the hook
parameter already uses percentage units; multiplying it by 100 produced the
wrong suffix.

## UE4SS dev.15

- Treats the hook parameter directly as the displayed percentage.
- Confirmed examples from the diagnostic: raw `0.094211728` means `0.094%`,
  and raw `1.456129968` means `1.456%`.
- Removes the temporary rate diagnostic.

Result: **FAILED.** A dev.16 layout diagnostic showed that
`BP_PalTextBlock_C_6` already owns the stock hundredth digit and `%`
(`5%` for raw `0.455...`). Replacing it with only the thousandth discarded
the existing digit.

## UE4SS dev.17

- Writes the hundredth and thousandth together into the suffix widget.
- Example: raw `0.455...` changes the stock `5%` suffix to `55%`, producing
  `0.455%` with the preceding widgets.
- Keeps full `.xxx%` reconstruction for Palworld's rounded `1–9.999%`
  layout.

Result: **FAILED.** Multiple live reticles interleaved formatter callbacks;
the global cached widget could receive a suffix calculated for a different
reticle, producing output such as `0.45.000%`.

## UE4SS dev.18

- Walks a newly constructed digit widget's outer chain once and caches it by
  its owning `WBP_PalGetReticle_C` full name.
- Resolves formatter updates against the exact reticle instance passed to the
  hook.
- Performs no global object scan or outer-chain search across object arrays
  on the formatter path.

Result: **FAILED.** The numeric range did not reliably identify which
Palworld layout was active; visible `0.45` could still receive a reconstructed
`.000%` suffix.

## UE4SS dev.19

- Reads the stock suffix synchronously after Palworld's formatter completes.
- A suffix containing a digit (such as `5%`) means the decimal layout is
  already visible, so the mod writes the hundredth and thousandth together.
- A suffix containing only `%` selects full `.xxx%` reconstruction.

## UE4SS dev.26

- Uses the verified reticle fields: `C_3` for `.`, `C_4` for all three
  fractional digits, and `C_2` for `%`.
- Collapses `C_5` and `C_6`, producing three logical value fields such as
  `0` + `455` + `%` (rendered as `0.455%`).

Result: the combined decimal field retained its original centered alignment,
causing the first fractional digit to overlap the integer.

## UE4SS dev.27

- Left-aligns the combined three-digit decimal field so it expands into the
  space freed by the collapsed fractional widgets.

Result: overlap was removed, but the original percent field was clipped by
the widened decimal field.

## UE4SS dev.28

- Places `%` in the adjacent `C_5` field after the combined `C_4` decimal
  value.
- Collapses the old `C_2` percent field and unused `C_6` field.

Result: the fixed-width decimal and adjacent percent fields overlapped.

## UE4SS dev.29

- Restores Palworld's intended one-character-per-widget layout.
- Uses `C_4`, `C_5`, and `C_6` for the three decimal digits and `C_2` for
  `%`, avoiding overlap and clipping.

## UE4SS dev.30

- Combines the final decimal digit and percent sign in `C_6` (for example,
  `5%`).
- Collapses the now-redundant separate percent widget `C_2`.

## UE4SS dev.31

- Truncates capture rates to three decimal places instead of rounding.
- A value such as `0.9999%` remains `0.999%` rather than becoming `1.000%`.

## UE4SS dev.32

- Formats the post-throw/failure `Text_Pecent` widget as a complete
  truncated `X.XXX%` string instead of replacing it with one digit.
- Keeps aiming and post-throw capture-rate displays consistent.

## UE4SS dev.33

- Caches the latest numeric value for each live reticle.
- Reapplies only the already-cached text fields every 50 ms so later vanilla
  animation updates cannot revert `1.227%` to `1%`.
- Performs no object lookup or enumeration in the refresh loop.

Result: the timer still lost ordering to Palworld's per-frame layout update.

## UE4SS dev.34

- Replaces the timer with post-hooks on `SetCaptureRateForce`,
  `SetCaptureRateFromListIndex`, and `SetCaptureRateList`.
- Reapplies `X.XXX%` immediately after the vanilla functions that restore
  the rounded layout.

Result: reset hooks were attempted before the reticle Blueprint finished
loading and were not retried.

## UE4SS dev.35

- Tracks each reset hook independently and retries unavailable hooks while the
  reticle Blueprint loads.
- Stops retrying once all three hooks are registered.

Result: reset hooks registered, but their corrections were deferred to the
next game-thread cycle and could still be overwritten.

## UE4SS dev.36

- Writes the `X.XXX%` fields synchronously inside the Blueprint post-hooks.
- Ensures the mod's formatter is the final operation in each vanilla reset
  function call.

Result: another lower-level UMG write still restored the rounded layout.

## UE4SS dev.37

- Intercepts native `UTextBlock::SetText` and `UWidget::SetVisibility`.
- Rewrites only the active reticle's verified capture-rate fields, regardless
  of which vanilla Blueprint function performs the final update.
- Uses no polling loop or object scan on the update path.

Result: abandoned for now. Fighting the vanilla UI at the reset and global
UMG layers added complexity without producing a stable persistent display.

## UE4SS dev.38

- Removes the timer, reset-function hooks, and global UMG interception.
- Returns to lightweight formatter hooks plus ineffective-sphere warning
  suppression.

## UE4SS dev.39

- Applies three-decimal formatting only when the capture rate is below `1%`.
- Leaves all rates at or above `1%` completely unchanged by the formatter.
- Retains the unrelated ineffective-sphere warning suppression.

Result: the separate vanilla percent widget remained collapsed after leaving
a sub-1% target.

## UE4SS dev.40

- Restores the vanilla `%` field and its visibility for rates at or above
  `1%`.
- Still leaves all numeric formatting in that range untouched.

## UE4SS dev.41

- Removes post-throw/failure number formatting entirely.
- Prevents a full formatted value from being written into the post-throw
  widget's third slot.
- Keeps sub-1% three-decimal formatting only on the aiming reticle.

## UE4SS dev.42

- Renames the public-facing mod to **Scatterspam Capture**.
- This was the final build before the internal package ID was renamed to
  `ScatterspamCapture` in dev.43.

## UE4SS dev.43

- Renames the internal package, project, source tool, Lua log prefix, and
  installed UE4SS folder to `ScatterspamCapture`.

## Version 1.0.7

- Corrects the formatting threshold: aiming rates at or above `1%` use three
  truncated decimal places.
- Leaves rates below `1%` to Palworld's vanilla formatter.

Result: **incorrect requirement.** The three-decimal formatter is only needed
for displayed rates below `0.01%`.

## Version 1.0.8

- Applies three-decimal formatting only when the displayed aiming rate is below
  `0.01%`.
- Leaves rates at or above `0.01%` to Palworld's vanilla formatter.

## Versions 1.0.9–1.0.14

- Makes hook registration work during UE4SS hot reload even when its deferred
  `EngineTick` dispatcher has stopped.
- Identifies Palworld 1.0's live aiming formatter as `SetCaptureRateForce`;
  the former `Set Display Capture Rate Force` function still exists but is no
  longer called while aiming.
- Applies the widget update synchronously from the live formatter hook.

Result: verified in game with a raw `0.00637288%` capture rate displayed as
`0.006%`.

## Version 1.0.15

- Clears and collapses the injected third-decimal widget when the aiming rate
  returns to `0.01%` or higher.
- Restores the separate vanilla percent widget so the previous low-rate digit
  cannot remain stuck on later targets.

Result: the third digit cleared correctly, but Palworld's subsequent
`Update Display Rate` collapsed the separate percent widget.

## Version 1.0.16

- Uses the persistent suffix slot as `%` at or above `0.01%`.
- Uses the same slot as `<third digit>%` below `0.01%`, avoiding a transition
  race with Palworld's separate percent widget.

Result: the percent symbol returned, but the mod still replaced vanilla's
percent-widget behavior unnecessarily.

## Version 1.0.17

- Leaves all vanilla numeric and percent widgets untouched during normal use.
- Injects only the third digit below `0.01%` and clears only that injected slot
  at or above the threshold.
- Repairs percent widgets collapsed by versions 1.0.15–1.0.16 once per active
  reticle during hot-reload migration.

Result: the migration targeted an obsolete separate percent widget; Palworld
1.0 owns the visible percent suffix in `C_6`.

## Version 1.0.18

- Relies on the Blueprint post-hook phase: `SetCaptureRateForce` restores the
  entire vanilla layout before the mod callback.
- Treats `SetCaptureRateForce` values as raw probabilities: `0.01` is the
  threshold for a displayed `1%` rate.
- Returns without any widget writes at or above displayed `1%`.
- Replaces only the vanilla `%` suffix with `<third digit>%` below displayed
  `1%`.
