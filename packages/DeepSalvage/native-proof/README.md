# Native Interact2 proof

This is a deliberately narrow UE4SS C++ proof. It tests whether native
callbacks can mutate the reflected `GetIndicatorInfo` out-struct without the
Lua marshalling crash seen on revision 82182.

It does only two things:

1. For fishing-salvage components, copy the complete vanilla `Interact1`
   metadata into `Interact2`, then change the indicator to
   `CommonInteract04`.
2. Observe `StartTriggerInteract(Interact2, ...)` and write
   `event=interact2_callback_ok` to the UE4SS log.

The proof resolves both enum values by reflected name, validates reflected
property types before access, refuses to replace an existing valid
`Interact2`, and accepts the callback only when the player's
`TargetInteractiveObject` belongs to the Rank 1 or Rank 2 fishing-junk salvage
class.

It does not modify inventory, rewards, difficulty, networking, saves, or Lua
state. It performs no scans, ticks, timers, or asynchronous access to temporary
function parameters.

## Build

Use the exact RE-UE4SS source revision backing the installed
`experimental-palworld` build. From a Visual Studio 2022 developer shell:

```powershell
cmake -S . -B build `
  -G "Visual Studio 17 2022" `
  -DUE4SS_ROOT="C:\path\to\RE-UE4SS"
cmake --build build --config Game__Shipping__Win64
```

The output is named `main.dll`. Install it for a local test as:

```text
Palworld\Mods\NativeMods\UE4SS\Mods\DeepSalvageNativeProof\dlls\main.dll
```

Enable the mod using the same mechanism as other C++ mods in the installed
UE4SS build. Do not put this proof DLL in the Workshop payload yet.

## Pass criteria

Back up the save and test with the Lua interaction hooks still disabled.

1. Start Palworld and confirm `event=init_ok`.
2. Approach a Rank 1 and Rank 2 fishing salvage point.
3. Confirm two action slots appear and vanilla Salvage still works.
4. Press the second action.
5. Confirm exactly one `event=interact2_callback_ok` line for the press.
6. Leave and re-approach repeatedly; confirm no crash and no per-refresh log
   spam.

`event=indicator_conflict` means another system already owns `Interact2`; the
proof intentionally leaves that action untouched. `event=interact2_ignored`
means the button press did not correlate to an allowed salvage target and is
not a successful proof.

Stop immediately if approaching the salvage point crashes. In that case the
C++ UFunction hook still shares the unsafe detour path and the next proof must
be a revision-pinned inline/vtable detour.

The label intentionally remains Palworld's `CommonInteract04` text during this
first gate. A text override is a separate proof after the action and callback
chain succeeds.
