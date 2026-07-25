# Research

## Goal

Display capture probability with three fractional digits while aiming a Pal
Sphere. For example, a value currently rendered as `0.00` should render as
`0.001` when the underlying value is `0.001`.

## Candidate assets or hooks

- Selected asset:
  `Pal/Content/Pal/Blueprint/UI/UserInterface/InGame/GetReticle/WBP_PalGetReticle`.
- Selected runtime hook: `Set Display Capture Rate Force`.
- Palworld decomposes the percentage into individual digit widgets instead of
  using a normal fractional-digit format option.
- UE4SS queues the text update after the original formatter returns.
- The hook reuses the former percent-sign widget as digit three and drives it
  with `Round(rate * 1000) % 10`.
- No cooked asset is overridden; capture calculation is preserved.

## Dependencies

- Palworld: `E:\SteamLibrary\steamapps\common\Palworld`
- FModel: `E:\Code\Palworld Modding\tools\FModel\FModel.exe`
- UAssetGUI: `E:\Code\Palworld Modding\tools\UAssetGUI.exe`
- repak: `E:\Code\Palworld Modding\tools\repak\repak.exe`
- mappings: `E:\Code\Palworld Modding\tools\Mappings.usmap`

## Compatibility notes

- Presentation-only: the mod must not change capture probability.
- A direct widget override may conflict with other mods that replace the same
  capture HUD asset.
- The compact aiming readout omits the percent sign to make room for digit
  three.
