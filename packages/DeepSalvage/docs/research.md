# Research

## Goal

Keep vanilla Salvage unchanged and add **Deep Salvage**, which requires the
same 1 Magnet but permanently loses it on failure in exchange for a harder
minigame and better success reward.

## Candidate assets or hooks

- `/Game/Pal/Blueprint/MapObject/Object/FIshing/BP_MapObject_TreasureBox_FishingJunkSpot_Junk_Rank1`
  owns a `PalMapObjectTreasureBoxSalvageParameterComponent`.
- The extracted Rank 1 component exposes:
  - `GaugeStartPercent = 20`
  - `GaugeEndPercent = 90`
  - `GaugeRangePercent = 8`
  - `CursorPercentSpeed = 66`
- `/Game/Pal/Blueprint/UI/Salvage/WBP_SalvageGame` is the UI class used by
  that component. Prefer changing the per-treasure component rather than
  replacing the shared widget.
- The reward/loot source still needs to be identified. Trace the treasure
  actor's loot configuration and Rank 2 variant before editing either asset.

## Initial design

1. Add `Deep Salvage (Wager 1 Magnet)` beside the vanilla interaction.
2. Validate that the player has 1 Magnet before starting.
3. Reserve or track that Magnet through the authoritative inventory API.
4. Associate the selected mode with that player and treasure instance.
5. Narrow the success range and increase cursor speed for the deep attempt.
6. On authoritative success, increase the existing reward.
7. On failure or abandonment, permanently consume the wagered Magnet.
8. Clear attempt state on success, failure, cancellation, disconnect, or
   treasure destruction without charging twice.

The implementation must first confirm vanilla Magnet behavior. If vanilla
already consumes the Magnet at challenge start, Deep Salvage must avoid a
second debit. If vanilla preserves it on failure, the Deep Salvage failure hook
performs the additional permanent loss.

## Runtime hooks to identify

- The function that gathers or constructs map-object interaction choices.
- The function that begins the salvage UI and supplies its parameter component.
- The authoritative inventory consume/check functions used by vanilla Salvage.
- The salvage success/failure or treasure-open completion functions.
- The authoritative loot roll/grant function and its reward payload.

## Jellroy Drop stacking

The current Pal headers expose a dedicated
`EPalPassiveSkillEffectType::FishingSalvage_ItemDrop` modifier and
`UPalMapObjectTreasureBoxModel::CreateItemInfo()`. Deep Salvage must preserve
that vanilla calculation:

1. Determine the vanilla base quantity before
   `FishingSalvage_ItemDrop` bonuses.
2. Read or preserve the accumulated vanilla salvage bonus, including Jellroy.
3. Add the Deep Salvage `+100%` bonus to that percentage, then calculate the
   final quantity for a successful tracked Deep Salvage attempt.
4. Round once, using the same integer rule for every item stack.
5. Do not inject Deep Salvage as another
   `FishingSalvage_ItemDrop` passive; doing so could enter vanilla passive
   aggregation, caps, or party stacking rules.

The intended formula is:

`final = base × (1 + Jellroy bonus + Deep Salvage bonus)`

With a `+100%` Deep Salvage bonus:

- no Jellroy: `1 + 0 + 1.00 = 2.00x` vanilla quantity;
- Jellroy +50%: `1 + 0.50 + 1.00 = 2.50x`;
- Jellroy +95%: `1 + 0.95 + 1.00 = 2.95x`.

This additive policy means we cannot simply double the already
Jellroy-adjusted `CreateItemInfo()` output. A live hook must capture the base
quantity or the applied passive rate so Deep Salvage can add its bonus before
the single final rounding step. Testing must confirm the exact Jellroy value,
integer rounding, party stacking, and whether `CreateItemInfo()` runs entirely
on the server in the current revision.

## Dependencies

- Palworld Steam revision 619 or newer.
- `repak` for deterministic packaging.
- A cooked-asset patcher such as the existing workspace UAssetAPI toolchain.

## Compatibility notes

- UE4SS must run on the host or dedicated server for inventory debit and reward
  mutation. A client-only grant risks desynchronization.
- UI presentation may still require a client-side copy on every participating
  player.
- Hook names and signatures can change between Palworld revisions.
- Keep original extracted assets in `work/original` and generated overrides in
  `work/staging`.
