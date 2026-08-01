# Quick Resume

Quick Resume continues the most recently played local world from Palworld's
title screen.

The mod deliberately does nothing when Palworld reports that its
recent-crash/mod warning is required. It also waits rather than interacting
through any startup modal dialog.

## Development status

`0.1.0-dev.2` is an instrumented development build for Palworld revision
82182 or newer. The implementation is based on the current installed game
assets and still requires an in-game verification pass.

## Runtime

- Client-side UE4SS Lua mod.
- Requires `UE4SSExperimentalPW`.
- Uses title-screen and local-world-list events; it has no Tick hook or
  recurring polling.
- Observes Palworld overlay-widget creation, automatically confirms only the
  ordinary mod-caution widget, and permanently blocks that launch when the
  recent-crash flag is set.
- Selects the first entry in Palworld's timestamp-sorted local-world list,
  then invokes the game's normal selection and start flow.

Do not install `AutomaticallySkipModCaution` alongside Quick Resume. Quick
Resume includes the same ordinary-caution behavior and adds the crash-warning
safety distinction.

## Installation payload

The exact loader payload is under `package/QuickResume`. The Lua install rule
targets `"."`, preserving `QuickResume/Scripts/main.lua` in the installed mod.
