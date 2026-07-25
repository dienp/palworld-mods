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

## Interaction solution validation

Revalidated against revision 82182 reflection headers and the July 25 crash
evidence:

1. **Prompt-only LogicMod bridge — rejected.** It can observe
   `OnUpdateInteractiveObjectDelegate`, but cannot populate an interaction
   action. Its one-shot `PostBeginPlay` binding also races player-character
   creation. It adds a BPModLoader actor and requires a cooked pak, but does
   not make Palworld dispatch `Interact2`.
2. **Additional Blueprint interaction component — rejected.** The required
   `PalInteractiveObjectComponentInterface` is marked
   `CannotImplementInterfaceInBlueprint`. A second component therefore cannot
   supply action metadata without a native runtime class.
3. **Synchronous `GetIndicatorInfo` post-hook — rejected after runtime
   probe.** The reflected
   interface owns the exact `FPalInteractiveObjectActionInfoSet` output that
   Palworld consumes. For fishing salvage components only, copy the complete
   vanilla `Interact1_Indicator` metadata into `Interact2_Indicator`, change
   its indicator type, and return immediately. Never retain the temporary
   out parameter or schedule work with it. A matching synchronous
   `GetIndicatorText` post-hook supplies the Deep Salvage label. On revision
   82182 with Workshop UE4SS experimental-palworld-6, inspecting a salvage
   point crashes inside UE4SS with access violation `0x0000000400000042`
   before the callback emits its first diagnostic. This is the same failure
   signature as the earlier interface-hook probe, so synchronous access does
   not make this detour safe.

The Lua gameplay path requires UE4SS on each client and server, is restart-loaded
in the Workshop UE4SS configuration, and packages as Lua only. The Lua
install rule targets the package root (`"."`) so the official loader preserves
`Scripts/main.lua`; targeting `./Scripts/` flattens `main.lua` into the mod
root, which Workshop UE4SS does not discover. The unsafe indicator hooks now
fail closed and are not registered; a real interaction option requires a
targeted cooked-asset override or a native runtime component. It adds no
Tick, timer, actor, world scan, RPC, or allocation-heavy UI bridge. Indicator
queries are a UI hot path, so mutations are constant-time, object
classification is weak-key cached, diagnostics emit once per component, and
aggregate counters report at most once per configured interval.

## Decision retrospective: prompt bridge and interface hook

The initial LogicMod bridge was the wrong production choice.

- We correctly identified that mutating temporary interface output from an
  asynchronous callback was unsafe, but did not enforce the more important
  requirement that the proposed bridge must actually populate an interaction
  action and cause Palworld to dispatch `Interact2`.
- The bridge only observed `OnUpdateInteractiveObjectDelegate` and printed a
  prompt. It never wrote `FPalInteractiveObjectActionInfoSet`, so it could not
  create a selectable Deep Salvage option.
- Its one-shot `PostBeginPlay` binding also raced player-character creation.
- After the bridge failed, we revisited the already-risky reflected
  `GetIndicatorInfo` path. Registration success was mistaken for call safety.
  Both probes crashed on the first salvage inspection with the same UE4SS
  access-violation signature.

The missing gate was an end-to-end proof before production implementation:

`approach salvage -> two action slots -> press Interact2 -> StartTriggerInteract`

Reflection presence, Blueprint-node availability, hook registration, and a
printed prompt are not substitutes for that proof. Future Palworld interaction
features must demonstrate the full event chain with a minimal probe before
reward, inventory, networking, or packaging work proceeds.

The intended corrected architecture was hybrid:

- a salvage-specific cooked asset creates and labels `Interact2`;
- UE4SS Lua implements selection tracking, difficulty, authoritative Magnet
  loss, additive reward calculation, and diagnostics.

The cooked half then failed its own feasibility gate. Revision 82182 exposes
`FPalInteractiveObjectActionInfoSet::Interact2_Indicator`, but the method that
fills the set is the native-only
`IPalInteractiveObjectComponentInterface::GetIndicatorInfo`. The interface is
marked `CannotImplementInterfaceInBlueprint`, and the concrete capsule
component's function is `BlueprintCallable`, not a Blueprint override event.
The extracted `BP_InteractableCapsule` is data-only and contains no action-info
defaults or graph to patch. The salvage treasure classes likewise expose no
editable secondary-action field or Blueprint override point.

Therefore a cooked asset by itself cannot create Deep Salvage with the current
PMK surface. A viable implementation now requires a native runtime component
that safely owns the secondary interaction, with a cooked salvage-specific
asset attaching that component and UE4SS Lua retaining the gameplay policy.
The native component must pass this minimal proof before integration:

`approach salvage -> two action slots -> press Interact2 -> native callback`

Only after that proof may it forward the selected attempt to Lua. This keeps
the hot-reloadable gameplay logic while accepting that native-component and
cooked-asset changes require a restart.

The existing Visible Fishing Salvage Spots mod already overrides both Rank 1
and Rank 2 fishing-junk treasure assets. Any eventual Deep Salvage cooked
override must merge those visibility edits into the same assets; relying on
pak load order would make the two mods mutually destructive.

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
