# Testing

- Game revision:
- Build version: 0.1.0-dev.63
- Build mode: Development
- Loader DebugMode: True
- Runtime debug notifications: True
- Runtime debug console: True
- Source archive hash:
- Installed archive hash:
- Expected observable result: heartbeat appears in the shared mailbox; dry-run
  notification produces no UI; enabled notification produces one Pal log;
  `list_bases` includes every loaded `PalBaseCampModel`, reports inventory
  capability independently of Item Retrieval Machine presence, and
  `get_player_state` reports the current live base ID and friendly name.
- Actual result: Hot-replacing the running `0.1.0-dev.39` Lua file with
  `0.1.0-dev.41` produced a fresh heartbeat and exposed the new
  `current_base_id` / `current_base_name` fields, but both were empty. The
  first `list_bases` call then exposed a Lua declaration-order defect in the
  new live-base path. That defect was corrected in `0.1.0-dev.42`, but a
  second hot replacement crashed Palworld before the new heartbeat appeared.
  Both crash reports were UE4SS access violations reading
  `0xffffffffffffffff`, so further verification requires a clean game launch
  rather than another Lua hot replacement. A clean launch with
  `0.1.0-dev.42` then succeeded and remained stable. The bridge reported
  `game_ready=true`; `list_bases` successfully returned the 2 currently loaded
  live bases with inventory capability, while the save snapshot still
  contained 3 owned bases. `get_player_state` exposed the new current-base
  fields, but both remained empty while the player was standing in a base, so
  the controller/state `GetInsideBaseCampID` surface is not sufficient on this
  game build. The current-base resolver still requires runtime surface
  diagnostics and another clean-launch test.
- `0.1.0-dev.43` adds a read-only reflected current-base surface probe to
  `get_player_state`. The probe is not executed by the heartbeat.
- `0.1.0-dev.44` adds the controller's native `K2_GetPawn` fallback and
  includes loaded base-model area surfaces in the explicit diagnostic read.
- `0.1.0-dev.45` falls back to the unique live base model whose
  `PlayerUIdsExistsInsideInServer` array is non-empty, resolving its live ID
  dynamically through the associated Item Retrieval Machine when available.
- Live verification of `0.1.0-dev.45` identified the current location as
  `Base 5`; the ID remained empty because that base had no associated Item
  Retrieval Machine. `0.1.0-dev.46` expands the explicit diagnostic probe to
  identifier-named base-model members.
- The `0.1.0-dev.46` probe identified `PalBaseCampModel.GetId()` / `ID` as
  the native live base identifier. `0.1.0-dev.47` uses that surface in the
  current-base resolver without broadening the live catalog to other guilds.
- Live verification of `0.1.0-dev.47` resolved current base
  `701A496A-46172D84-B4B3919F-AFB5B8C3` as `Base 5`. `0.1.0-dev.48` keeps the
  reflected probe in source but removes it from normal player-state responses.
- `0.1.0-dev.49` derives the local player's live group from
  `PlayerUIdsExistsInsideInServer` and filters `PalBaseCampModel` discovery by
  `GroupIdBelongTo`, replacing the dispenser-based ownership approximation.
- Live verification of `0.1.0-dev.49` showed that iterating the reflected
  player-UID `TArray` with Lua `ipairs` hangs the game thread.
  `0.1.0-dev.50` uses only the already-verified array count and requires a
  unique occupied live base model before caching its group.
- `0.1.0-dev.51` persists friendly names for newly discovered bases in
  `%LOCALAPPDATA%\PalworldCompanionBridge\base-names.pcb`. Default game
  template names receive stable sequential labels; an assigned in-game name
  always takes precedence.
- `0.1.0-dev.52` adds a temporary read-only geometric probe for player/camera
  positions, base ranges, and reflected location-query surfaces.
- `0.1.0-dev.53` uses the local controller's view-target location with
  `PalBaseCampManager.GetInRangedBaseCamp` as the primary current-base
  resolver. The response includes the detected group, ownership, and resolver
  source; reflected geometry diagnostics remain available only in probe mode.
- `0.1.0-dev.54` resolves the player's actual guild from
  `PalPlayerState.GuildBelongTo.GetId()` instead of inferring ownership from
  the occupied base. Visiting another guild's base therefore does not change
  the owned-base filter or ownership flag.
- `0.1.0-dev.55` enumerates controller instances and requires
  `IsLocalController()` / `IsLocalPlayerController()` before falling back,
  avoiding `FindFirstOf` selecting a remote listen-server player.
- Live verification of `0.1.0-dev.55` selected local player ID `259`, kept
  the owned live catalog at three bases, and consistently detected nearby
  base `6004E4FB-4AC0882C-384B90AD-52368703` in group
  `CD1B772C-4F320585-77237784-8FDEDEC1` as not owned via the geometric
  resolver.

## Previous live verification

- `0.1.0-dev.64` verified `PalCharacterParameterComponent.GetLevel()`,
  `GetHP()`, `GetMaxHP()`, and `IsDead()` against all 28 deployed workers at
  the current base. It also discovered
  `PalNetworkRaidBossComponent.IsActive()` as the authoritative live raid
  signal; it was false outside a raid.
- A `0.1.0-dev.64` diagnostic attempted to invoke methods on boxed
  `PalIndividualCharacterParameter` wrappers. Those wrappers are not valid
  live UObjects, and the probe terminated the game process. `0.1.0-dev.65`
  permanently excludes non-UObject wrappers from reflective calls and obtains
  the ordered reserve IDs/levels from the local save snapshot instead. The
  installed bridge was replaced with this safe build before the next launch.
- `0.1.0-dev.67` correctly identified the dedicated Raid Area Palbox class
  `BP_BuildObject_PalBox_RaidBossArea_C` and matched it to the current Raid
  Area's live base ID. Before the raid starts, the ordinary base worker
  director/container is absent as expected.
- Hot-reloading `0.1.0-dev.68` during an active Raid Area encounter terminated
  Palworld before the bridge completed loading. Raid Manager was off and no
  roster write occurred. `0.1.0-dev.69` removes the added phase probe and is
  installed as the next-launch payload. Further Raid Area testing must load
  bridge changes before entering the encounter; no hot reload is permitted
  while a raid is active.

- `0.1.0-dev.112` is the DRY/KISS refactor plan's Stage 1 and Stage 2 build.
  It is source-only and unverified in game. Offline checks passed: `luac -p`
  compiles the chunk, `npm run validate` accepts the payload and its new
  duplicate-definition and unreferenced-local guards, and
  `packages/PalworldCompanionBridge/scripts/smoke.lua` loads the mod with the
  UE4SS globals stubbed, drives `get_raid_state` with and without the probe
  and reserve flags, exercises `set_raid_manager` gating, and writes a
  heartbeat without raising. In-game verification still required:
  Palbox-to-base and base-to-Palbox moves visibly spawn and withdraw workers;
  bulk deployment stays paced; downed replacement stays event-driven;
  `Battle -> Result` and `Battle -> Ready` stop Raid Manager; and
  `get_raid_state` reports `data_reserves_live=false` with a correct queue
  while the manager runs, `true` when it is off. Do not hot reload during an
  active Raid Area encounter.

Hot reload of `0.1.0-dev.39` succeeded in a loaded world. Heartbeat reported
  `0.1.0-dev.39`, edit mode was enabled by default, and the read-only inventory
  scan discovered 6 containers / 308 slots through
  `InventoryMultiHelper.Containers`. The loaded Item Retrieval Machine model
  resolved its owning base, while its container-access interfaces and module
  were null in the idle state. Base discovery found 2 loaded bases with Item
  Retrieval Machines. One live base snapshot read 5 GUID-deduplicated chests,
  200 slots, and 181 distinct items without truncation. An immediate repeat
  hit both caches; a repeat after 6 seconds hit membership and refreshed only
  the expired item summary. Assignment discovery listed 107 active base
  workers and 226 loaded work targets. A cross-checked base/Pal/station dry-run
  validated without mutation. A non-dry-run idempotent assignment of an
  already-fixed Pal to its current station returned `verified=true` and
  displayed the required in-game notification without changing assignment.
  Live roster discovery found 32 Palbox pages and a tested base with 33 worker
  slots (28 occupied, 5 empty). Dry runs resolved exact source and target slot
  IDs for both Palbox-to-base and base-to-Palbox directions without mutation.
  A non-dry-run request to move a Pal already present in the requested base
  returned `already_there=true`, `verified=true`, displayed the required
  in-game notification, and did not mutate either roster.
  Hot reload of `0.1.0-dev.39` normalized the game's internal Japanese base
  placeholders to `Base 1` and `Base 3` in list and roster responses while
  preserving the original values in `base_names_raw` / `base_name_raw`.
- Screenshot/log:
