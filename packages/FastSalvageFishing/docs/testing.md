# Test plan

Palworld was running while this build was created, so the package was not
deployed or overwritten. Restart the game after installing a distributed test
build.

## Static checks

- Validate `Info.json` and the Lua payload through the repository validator.
- Confirm the install target is `.` so the installed entry point remains
  `FastSalvageFishing/Scripts/main.lua`.
- Confirm only `Info.json`, `thumbnail.png`, and `Scripts/main.lua` are
  packaged.
- Confirm development diagnostics and loader debug mode are enabled.

## Runtime checks

1. Back up the world save before the first gameplay test.
2. Install the mod on the client and restart Palworld.
3. Verify `FastSalvageFishing/Scripts/main.lua` in the deployed package and
   check `Mods/ManagedMods/FastSalvageFishing/InstallManifest.json`.
4. Confirm the native `CalcGaugeRandomRange`, `TerminateInteract`, and
   salvage-widget `OnSetup` hooks
   register; there must be no actor or concrete-model hooks.
5. Hold the normal interact key at a rank-1 fishing salvage spot. Confirm
   Palworld retains its normal hold threshold and player animation.
6. Confirm the minigame never becomes interactable or visible. Require one
   `salvage_ui_render_suppressed` event with `target=Overlay_0`,
   `forced_close=false`, and no hide failure.
7. Confirm exactly one `automatic_success_sent` event is logged.
8. Confirm one Fishing Magnet is consumed, the vanilla reward appears once,
   active fishing-salvage passives still affect it normally, and the spot
   completes normally.
9. Repeat the hold-interact test at a rank-2 spot and in multiplayer. Every
   player who expects automatic completion must have the client
   mod installed.
10. Sprint into range of a newly streamed spot and use the normal hold
    interaction while the mount carries the player back out of range. If the
    server rejects the attempt, require one
    `orphaned_salvage_action_cancelled` event, no reward, and no stuck action.
    If the server accepts it, require one reward and no cancellation event.
11. Complete at least ten consecutive salvage attempts. Confirm there are no
    duplicate rewards, cancellation races, stuck actions, orphaned UI, or
    recurring log output.

If the native gauge hook or `SendResult` fails, the mod must leave the vanilla
minigame active and log `automatic_success_failed`.
