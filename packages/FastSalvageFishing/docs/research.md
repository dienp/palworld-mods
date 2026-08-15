# Research and design decisions

## Goal

Keep Palworld's native fishing-salvage hold and animation, skip the minigame,
and report success through Palworld's existing result path. Reward selection
and granting must remain vanilla.

## Evidence from the installed build

The local Palworld 1.0 SDK exposes:

- `UPalUIMapObjectTreasureBoxSalvageGameModel::SendResult(bool bSuccess)`;
- `UPalMapObjectTreasureBoxModel::OnReceiveSalvageResult(bool bResult)`;
- `UPalMapObjectTreasureBoxModel::CreateItemInfo()`.

The rank-1 and rank-2 fishing-junk treasure Blueprint defaults each set the
reflected `LongHoldInteractDuration` property to `0.5`. Their class paths are
separate from ordinary treasure boxes.

The shipped `WBP_SalvageGame` and
`WBP_SalvageGame_GaugeStopMiniGame` assets were extracted into ignored
`work/original` storage and serialized for inspection. Both expose an
`OnSetup` event, obtain the initialized salvage UI model, configure its gauge,
and use `SendResult` for the minigame result.

The reflected functions and both exact Blueprint hook paths correspond to the
installed Steam build and MinRevision 82182 SDK data in this workspace.

## Solution comparison

### Selected: client Lua post-hook on salvage gauge initialization

Post-hook the reflected native
`UPalUIMapObjectTreasureBoxSalvageGameModel::CalcGaugeRandomRange` function and
call the initialized model's `SendResult(true)` once. This function runs after
Palworld has created the model and bound its result delegate, but before the
player can interact with the minigame. It preserves Palworld's normal
client-to-server result path and authoritative reward behavior. It requires
`UE4SSExperimentalPW` on each client that wants instant salvage. It supports a
normal game restart and needs no cook, native DLL, Tick, timer, object scan, or
custom RPC.

Compatibility risk is limited to the native gauge and `SendResult` functions.
A game update that changes them fails closed: the vanilla minigame remains and
diagnostics report the failure.

The same Lua package registers exact new-object notifications for the rank-1
and rank-2 fishing-junk treasure classes and changes only their reflected
`LongHoldInteractDuration` from `0.5` to `0.0`. This removes the hold threshold
without changing the global interact component or unrelated treasure boxes.
The same callback sets `InteractPlayerActionType` and
`OpeningPlayerActionType` to `None` and disables the actor open-animation flag,
preventing both the entry and success action animations. If a property write
fails, the affected spot retains vanilla behavior.

## Live evidence from dev.2

The official loader installed all intended files and created the managed
manifest for Workshop item `3780284418`. Runtime logs proved both fishing-junk
class notifications registered and changed the rank-2 hold duration from
`0.5` to `0.0`.

The two Blueprint `OnSetup` hooks failed registration because UE4SS could not
resolve those inherited Blueprint events as hookable UFunctions. Therefore
dev.2 correctly changed hold input but never emitted `SendResult(true)`, which
explains the observed minigame and animation. Dev.3 removes those invalid
hooks and uses the reflected native gauge function instead.

Dev.3 runtime evidence proved the native hook sent one successful result per
attempt and the reward arrived. It also proved that `SendResult(true)` alone
does not close Palworld's result presentation: the widget remains visible
after reward delivery. Dev.4 registers the now-loaded `WBP_SalvageGame:OnSetup`
hook dynamically from an exact new-object notification, collapses the widget
in the setup pre-hook, and calls its reflected `Close()` method in the
post-hook. This keeps the authoritative reward path while preventing the UI
from rendering or retaining input focus.

Dev.4 runtime logs showed the Blueprint hook's single supported callback ran
and collapsed the widget, but the supplied second callback was ignored for a
Blueprint function, so `Close()` never ran. Dev.5 removes that hook and uses
the native `UPalHUDService::Push` post-hook. It identifies only salvage dispatch
parameters and closes the exact returned widget ID before `Push` returns to the
game loop.

Dev.5 runtime logs proved that reward success still ran but the salvage screen
did not pass through `UPalHUDService::Push`. Dev.6 instead post-hooks the exact
native `UPalMapObjectTreasureBoxModel::OpenPickingGame_ClientInternal` call.
That model owns the reflected `SalvageGameUIWidgetId`; after Palworld creates
the overlay, the hook closes that exact ID through `UPalHUDService`.

Dev.6 registered that reflected function but runtime evidence showed it was
not the route used by the fishing-junk Blueprint. Dev.7 returns to the proven
`WBP_SalvageGame:OnSetup` hook and performs both collapse and `Close()` in its
single Blueprint callback (UE4SS ignores a third callback for Blueprint
functions). Runtime evidence confirmed one vanilla success signal and one
successful widget close per tested salvage attempt, with no close failures.

The attempted exact `BP_OnSetConcreteModel` hooks could not resolve a
UFunction and retried unnecessarily for each constructed spot. Dev.8 removes
that dead diagnostic path. The proven actor-field mutations are sufficient to
remove the hold and animations in live testing.

## Fast-entry edge case

Dev.9 runtime evidence showed six normal success/UI-close pairs, followed by
newly streamed salvage actors with no corresponding gauge-model event when the
player sprinted into range and pressed interact immediately. A literal zero
hold threshold could therefore enter Palworld's action before the concrete
salvage model finished initializing. Dev.10's 50 ms guard reduced the window
but could not prove readiness and was rejected as a timing heuristic.

Dev.11 hooks the inherited native
`APalMapObject::BP_OnSetConcreteModel` pre-event and filters it to the exact
rank-1 and rank-2 fishing-junk actor classes. Palworld's vanilla interaction
gate remains unchanged until a valid concrete model is supplied. The hook then
sets the hold and animation fields before Palworld processes the model-ready
event. This eliminates elapsed-time assumptions without Tick, timers, polling,
or object scans.

Dev.12 removes the instant-interaction experiment entirely. Palworld retains
its native hold threshold, animation, streaming readiness, and interaction
state machine. The mod now intervenes only after the salvage UI model exists:
it submits the vanilla success result and closes the minigame widget. This is
the smallest reliable design and cannot introduce an interaction-readiness
race.

Dev.13/14 tested `ReceiveOpenFailed_ClientInternal` as the recovery boundary,
but the live fast-mount reproduction emitted no such callback. That hypothesis
was disproven and the dead hook was removed.

Dev.15 instead post-hooks `UPalInteractComponent::TerminateInteract`, the
local forced-interaction-end boundary that runs when movement loses the target.
After vanilla termination has run, the callback checks the owning character's
action component. It intervenes only when action type 98 (`FishingSalvage`)
is still active, then cancels that exact orphaned action. Normal successful
salvage never reaches this repair branch, and normal termination that already
ended the action is a no-op. The recovery uses no timeout, Tick, polling,
distance guess, or global object search.

Dev.16 addresses the repeated-success failure shown by live logs: six attempts
sent success and then force-closed the widget before a later attempt entered a
stuck action without creating UI. `WBP_SalvageGame::OnClose` invokes
`RequestCancelSalvageAction`, so the forced close made every successful result
race a cancellation request. The widget setup callback now only hides the
minigame. It never calls `Close()`; Palworld's existing successful-result
lifecycle owns final closure and action cleanup. This removes the conflicting
state transition rather than adding another recovery timer.

Dev.17 proved that the embedded minigame's lifecycle must remain active. It
collapsed `WBP_Fishing_SalvageGame`, which hid the UI and granted the reward,
but suspended the completion animation that releases the fishing action.
Dev.18 leaves the widget visible to Slate and sets only the containing
`Overlay_0` render opacity to zero. The minigame can continue ticking and
complete Palworld's normal success cleanup without drawing on screen.

### Rejected: call the treasure model directly on the server

Calling `OnReceiveSalvageResult(true)` from `RequestOpen_ServerInternal` could
preserve rewards, but it does not reliably prevent an unmodded remote client
from opening the minigame and risks racing the client UI/RPC lifecycle.

### Rejected: cooked Blueprint or native replacement

A Blueprint override could auto-complete during setup, while a native hook
could suppress more of the UI path. Both add cooking or binary dependencies,
larger update surfaces, and packaging complexity without improving the
reward-preservation path selected here.

## Authority and performance

The mod changes only the local UI's result signal and minigame visibility.
The server remains the authority for reward generation,
passive-skill bonuses, inventory mutation, and salvage-spot state. The
implementation is event-driven and performs a constant amount of work once
per salvage UI model and widget setup. Weak-key deduplication prevents a model
from sending duplicate success results.

Development counters record range calculations, setup events, duplicate
models, success signals, orphan-action recovery, and failures. There is no
recurring logging or polling hot path.
