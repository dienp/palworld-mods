# Research and design decisions

## Current design

Deep Salvage is a server-only Lua mod. It preserves the vanilla
fishing-salvage interaction and rolls one optional modifier per authoritative
attempt in `PalMapObjectTreasureBoxModel:RequestOpen_ServerInternal`.

For a selected attempt, the server temporarily changes the owning
`PalMapObjectTreasureBoxSalvageParameterComponent` and binds reward
eligibility to the same model. Successful item generation is adjusted in
`CreateItemInfo`; `OnReceiveSalvageResult` or timeout cleanup restores the
original component parameters and clears state.

The server component must be proven to provide or replicate the values used by
an unmodded remote client's minigame. If it does not, server-only difficulty is
not viable through this Lua surface and must fail closed; server-authoritative
reward modification remains viable.

## Reward stacking

Palworld exposes the Jellroy fishing-salvage passive through
`EPalPassiveSkillEffectType::FishingSalvage_ItemDrop`. The Lua implementation
estimates the base quantity from the already adjusted vanilla quantity, then
adds the configured random bonus alongside the Jellroy bonus:

`final = round(base × (1 + Jellroy bonus + random bonus))`

Every modified stack is audited in diagnostics. If live evidence shows that
base inference differs from Palworld's loot calculation, the reward modifier
must fail closed until an earlier reliable base-value hook is identified.

## Retired interaction experiments

Earlier versions attempted to create a selectable `Interact2` action through
Lua and a UE4SS C++ proof. The interface hook supplied an invalid receiver and
caused access violations. A receiver-free proof was stable but exposed no
salvage-specific discriminator: the returned action and indicator were both
zero, and `SituationInfo` contained only `InteractingActor` and `InteractId`.

The native proof, cooked-asset plan, second-action protocol, extra Magnet loss,
and related packaging work are permanently retired from this mod. Crash dumps
and local backups remain outside the distributed repository for historical
diagnosis only.
