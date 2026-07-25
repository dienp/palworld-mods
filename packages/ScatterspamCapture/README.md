# Scatterspam Capture

Built for cheap-sphere scatter-launcher attempts against low-odds targets.

Production release: `1.0.0`

## Implementation

The UE4SS mod:

- Shows three truncated decimals while aiming when capture chance is below
  `1%`.
- Leaves capture rates at or above `1%` to Palworld's vanilla formatter.
- Suppresses ineffective-sphere warning records to reduce notification churn
  during scatter-launcher sphere spam.

Internal package ID: `ScatterspamCapture`.

The mod does not modify capture probability.

## Requirements

- Palworld revision 82182 or newer.
- UE4SS support supplied by Palworld's official mod loader.

## Workshop release

The clean upload payload is generated under `release/ScatterspamCapture-1.0.0`.
Register a real Workshop item with Palworld Mod Uploader, keep the first upload
hidden for validation, then verify the managed install manifest and installed
Lua hash before publishing.

Registered Workshop item: `3770359988`.
