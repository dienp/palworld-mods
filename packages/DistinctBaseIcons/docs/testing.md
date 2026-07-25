# In-game test checklist

1. Back up the active save before testing any Palworld 1.0 mod.
2. Install `DistinctBaseIcons_Orange_P.pak` in `Pal/Content/Paks/~mods/`.
3. Start Palworld and load a single-player world with at least one base.
4. Open the world map and confirm the home-base marker is orange.
5. Confirm discovered fast-travel tower markers remain blue.
6. Hover and select both marker types; verify their interactions still work.
7. If available, check a second base and a joined multiplayer world.
8. Exit, remove the pak, relaunch, and confirm the marker returns to vanilla.

Dev 6 regression checks:

- The normal same-guild camp icon is orange, not olive green.
- The different-guild red state remains red.
- The disabled gray state remains gray.

If the game fails to launch, remove only this pak and preserve the game log for
diagnosis. Do not continue loading saves repeatedly with a broken UI package.
