# Research

## Goal

Compare Palworld's built-in cooked Niagara systems on active Rank 1 and Rank 2
fishing salvage spots without rebuilding a PAK or restarting between every
candidate.

## Asset inventory

`repak 0.2.3` listed 1,523 `NS_*.uasset` Niagara systems in the installed
Palworld archive on 2026-07-29. The first broad runtime pass proved that 15 of
16 systems could be assigned from Lua; `NS_LotusGlow` did not resolve its
expected exported object name.

The second shortlist favors persistent, long-range systems from:

- `/Game/Pal/Effect/Common/Glow`
- `/Game/Pal/Effect/Treasure`

Cooked-property inspection found:

- `NS_RareKingFishGlow`: `MaintainInCameraParticleScale` and camera query.
- `NS_WhaleWhistle_Glow`: camera-maintained scale, camera query, and
  `ET_PalEffectType_FarRange_TravelPoint`.
- `NS_Boss_KingWhale_Stone`: camera-maintained scale and camera query.
- `NS_TowerPanelGlow`: camera-maintained scale and
  `ET_PalEffectType_FarRange_AreaBarrierLock`.
- Fast Travel and Observation Point variants: camera query and
  `ET_PalEffectType_FarRange_TravelPoint`.
- `NS_ItemPickupTower_Glow`: camera query and
  `ET_PalEffectType_FarRange_AreaBarrierLock`.

Attack, explosion, cutscene, weather, middle-range, and ordinary localized
glows were excluded from the second pass. Candidate paths remain in `main.lua`.

No game assets were extracted or committed.

## Runtime design

The tool performs no Tick work and no recurring world scan. A command or
hotkey:

1. calls `LoadAsset` for one built-in Niagara system;
2. resolves the loaded `UNiagaraSystem` with `StaticFindObject`;
3. scans currently loaded `NiagaraComponent` objects once;
4. selects components whose object or owner name contains either fishing-junk
   Rank 1 or Rank 2 actor name;
5. calls reflected `SetAsset`, `ReinitializeSystem`, and `Activate`.

If `SetAsset` is unavailable in the installed UE4SS reflection surface, the
prototype attempts the inherited `Asset` property. Every risky reflection call
is protected with `pcall` and emits runtime evidence.

## Feasibility and risk

- **Authority:** local/client visual state only; no server or save mutation.
- **Hot reload:** candidate changes are runtime-only and need no cook/restart.
- **Dependencies:** Palworld's official-loader UE4SS package and its console,
  or the supplied hotkeys.
- **Performance:** one global component scan per explicit user action; counters
  expose scan and assignment totals.
- **Compatibility:** actor-name and reflected-function changes can break the
  probe after a Palworld or UE4SS update.
- **Visual interpretation:** some systems require parameters, attachments,
  orientation, or scale supplied by their original actors. An invisible or
  oversized result is not proof that the asset itself is broken.

This is intentionally an exploratory development tool. Runtime testing must
prove the reflected calls before any production design adopts this approach.
