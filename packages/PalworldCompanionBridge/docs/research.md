# Research

## Goal

Palworld Companion Bridge

## Candidate assets or hooks

- Selected: a local single-command mailbox under
  `%LOCALAPPDATA%\PalworldCompanionBridge`.
- UE4SS polls on the game thread every 250 ms. It performs no recurring global
  object scan beyond resolving the local player controller for the 1-second
  heartbeat.
- A localhost HTTP/WebSocket server was rejected for the first version because
  UE4SS Lua does not provide a small built-in network surface and it would
  expand the attack surface.
- Generic reflected function invocation was rejected. Each write action must
  be explicitly implemented and allowlisted.

## Dependencies

- UE4SS with Lua mod support.
- Palworld MCP Server 0.6 or newer.
- The shared mailbox directory is created by the MCP server.

## Compatibility notes

- Player-controller and `PalLogManager` names are Palworld-specific and must be
  revalidated after game updates.
- The local controller must be selected with `IsLocalController()` or
  `IsLocalPlayerController()`. `FindFirstOf("PalPlayerController")` can select
  a remote listen-server player.
- The local guild comes from
  `PalPlayerState.GuildBelongTo.GetId()`. It must not be inferred from the base
  currently containing the player.
- Current-base detection uses the local controller's view target
  `K2_GetActorLocation()` with
  `PalBaseCampManager.GetInRangedBaseCamp(Location, 0.0)`. This is independent
  of ownership and therefore detects loaded friend bases.
- Fixed base-work assignment uses
  `BP_MonsterAIController_BaseCamp_C.SetBaseCampActionWithFixAssign` with the
  selected work object's native work ID. The reflected call chain resolves that
  ID through the owning base and registers the fixed assignment.
- Active workers expose base IDs through
  `PalCharacterParameterComponent.GetBaseCampId()` and stable Pal IDs through
  `PalIndividualCharacterParameter.IndividualId`.
- Work targets expose base IDs through `PalWorkBase.BaseCampIdBelongTo` and
  native target IDs through `GetWorkId()`.
- Palbox pages are exposed through `PalPlayerDataPalStorage.GetPageNum()` and
  `GetSlot(pageIndex, slotIndex)`. Base worker slots come from the owning
  `PalBaseCampWorkerDirector.CharacterContainer`.
- Authoritative worker deployment uses
  `PalNetworkBaseCampComponent.RequestMoveCharacterToWorker_ToServer`.
  Worker withdrawal uses `RequestMoveWorkerToPalBox_ToServer`. These calls
  trigger the worker actor's visible spawn/despawn lifecycle; a generic
  `PalNetworkCharacterContainerComponent.RequestSwap_ToServer_Rep` only changes
  the roster.
- Raid Manager bulk deployment stages the first N-1 Pals with generic roster
  swaps, then uses the authoritative worker deployment call for the final Pal.
  The final call reconciles and visibly spawns the complete batch. Downed-Pal
  replacements continue to use authoritative withdrawal and deployment calls
  individually.
- Edit mode is opt-out at either the MCP or bridge local configuration layer.
  Every live action remains allowlisted and idempotent.

## Inventory access findings

- Player inventory has a stable direct route:
  `PalPlayerState.GetInventoryData()` returns
  `BP_PalPlayerInventoryData_C`, whose `InventoryMultiHelper.Containers`
  contains the six player-owned containers. Reading those six arrays is not a
  scan of world storage.
- The Item Retrieval Machine asset is
  `/Game/Pal/Blueprint/MapObject/BuildObject/`
  `BP_BuildObject_BaseCampItemDispenser`. Its runtime model is
  `PalMapObjectBaseCampItemDispenserModel`.
- A loaded model resolves its owning `PalBaseCampModel` through
  `GetBaseCampModelBelongTo()`.
- The inherited `GetItemContainerAccess()` and
  `GetItemChestContainerAccess()` functions return interface values, but both
  are null while the machine is idle. `GetItemContainerModule()` is also null.
  The model declares no reflected functions of its own.
- Therefore the machine does not expose a permanently materialized base-wide
  inventory through those accessors. The aggregate access is likely
  interaction/UI-scoped and should be tested while the machine UI is open.
- A background base-inventory tool should use the owning base identity and a
  cached, GUID-deduplicated list of eligible loaded storage containers. It
  should not invoke the machine interaction or UI path merely to read data.

## Base inventory implementation

- Bases are discovered through loaded `PalBaseCampModel` instances and filtered
  by the local player's live guild ID. Bases do not need an Item Retrieval
  Machine to appear in `list_bases`.
- `PalMapObjectBaseCampItemDispenserModel` is optional capability metadata. A
  matching loaded dispenser can help identify inventory-capable bases but is
  not the source of base identity or ownership.
- Eligible storage is limited to loaded `PalMapObjectItemChestModel`
  instances belonging to one of those base IDs. Guild-chest containers are
  excluded. Supply storage has no owning base and is excluded.
- Membership is deduplicated by the nested
  `PalContainerId.ID` FGuid returned by
  `PalMapObjectItemContainerModule.GetContainerId()`.
- Membership is cached for 15 seconds. Every read validates the player/world,
  base/dispenser, model, module, container, base ID, and container GUID before
  reusing cached membership.
- New chest construction invalidates membership through
  `NotifyOnNewObject`. Invalid objects, changed ownership, streaming changes,
  world changes, and TTL expiry invalidate during query-time validation.
- Item summaries cache quantities for 5 seconds. The
  `PalMapObjectItemChestModel.OnUpdateContainerContentInServer` hook
  invalidates the affected base summary, with TTL expiry as a fallback.

## Cross-guild inspection findings

- `PalBaseCampManager.GetInRangedBaseCamp` returns the containing base across
  guild boundaries.
- Active worker and workstation scans can be filtered by that runtime base ID.
- The local-guild membership cache intentionally backs `list_bases` and base
  inventory. A non-owned base therefore does not gain inventory access merely
  because the player is standing inside it.
- Base roster discovery is also not currently reliable for a non-owned base.
  `get_base_state` must report each requested section independently rather than
  treating workers/stations success as proof that roster/inventory succeeded.

## Raid battle phases

Live-verified on 2026-08-05 with Companion Bridge `0.1.0-dev.107`:

| Numeric phase | Runtime phase-state class | Meaning |
| --- | --- | --- |
| `2` | `PalRaidBossAreaPhaseReadyState` | Raid area is ready. This was observed before summoning and again after a completed raid. |
| `4` | `PalRaidBossAreaPhaseBattleState` | Raid battle is active. |
| `5` | `PalRaidBossAreaPhaseResultState` | The battle has ended and the result phase is active. |

The phase is read from the current raid area's
`PalRaidBossAreaInstanceModel.GetCurrentPhase()`. The authoritative state class
comes from
`PalRaidBossAreaInstanceModel.PhaseStateMachine.GetCurrentState()`.
`PalRaidBossAreaPhaseAppearanceState` exists in the runtime surface but its
numeric phase was not captured during this test, so it must not be assigned an
unverified number.

Raid Manager shutdown is transition-based:

- Activation does not require a particular raid phase and does not use the
  phase as a readiness or location gate.
- While Raid Manager is active, the existing 10-second bridge-readiness refresh
  samples the phase; no additional timer or loop is created.
- A positively observed `PalRaidBossAreaPhaseBattleState` arms the battle latch.
- After that latch is armed, any valid non-battle phase stops Raid Manager.
  The live verification observed `Battle (4) -> Result (5)` and stopped with
  reason `raid battle phase ended`.
- If the raid instance or phase state disappears after Battle, two consecutive
  missing samples stop Raid Manager. This is a guarded fallback and was not
  needed in the live verification.
- The 15-minute watchdog remains the final fallback.
- Hot reload resets Raid Manager and its battle latch, so a transition spanning
  a hot reload cannot verify automatic shutdown.
