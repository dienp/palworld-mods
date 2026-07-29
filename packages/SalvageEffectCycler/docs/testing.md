# Testing

## Installation

Install the official-loader package and verify the resulting payload is:

`Mods/NativeMods/UE4SS/Mods/SalvageEffectCycler/Scripts/main.lua`

Also verify the corresponding managed-mod install manifest. Do not infer
success from Palworld's generic mod warning.

## Runtime probe

1. Start Palworld with UE4SS and the console enabled.
2. Load a world and stand near a visible Rank 1 or Rank 2 fishing salvage spot.
3. Confirm the UE4SS log contains:
   `Loaded 13 candidates; use 'salvagefx help'`.
4. Run `salvagefx status`; confirm at least one loaded salvage component.
5. Run `salvagefx next`.
6. Confirm the log reports a successful assignment and the spot changes.
7. Use `Ctrl+PageDown` and `Ctrl+PageUp`; confirm the on-screen diagnostic
   identifies each candidate.
8. Run `salvagefx set Fast Travel Point`, then compare its apparent size at
   multiple camera distances.
9. Run `salvagefx tune 0.08 0.20`; confirm the marker becomes smaller and less
   busy while remaining visible at distance.
10. Run `salvagefx set 1` to restore vanilla `NS_SingleStar`.
11. Move to another salvage spot and run `salvagefx apply`.

## Failure evidence

- `No loaded salvage Niagara components`: confirm the spot is streamed and
  use `salvagefx status` near it.
- `LoadAsset failed`: verify the candidate remains in the current game build.
- `SetAsset/property assignment failed`: the current UE4SS reflection surface
  cannot perform the Lua swap; capture the full log for a native fallback.
- Asset assigned but reset/activation failed: inspect the installed
  `UNiagaraComponent` functions before adding another fallback.

## Safety and behavior

- Loot, spawn behavior, interaction range, and saves remain unchanged.
- No recurring scan or Tick work occurs.
- Do not distribute this development build as a production Workshop release.
