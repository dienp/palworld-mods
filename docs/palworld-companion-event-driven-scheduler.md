# Palworld Companion event-driven scheduler

Status: implemented in Companion Bridge `0.1.0-dev.88`, except native IPC
(step 5, deferred) and fallback removal (step 6, gated on the telemetry added
in `0.1.0-dev.113`)

## Goal

Reduce idle filesystem work and Unreal object scans without sacrificing command
responsiveness, PalCom replies, or Raid Manager safety.

## Target architecture

Keep one generation-guarded UE4SS scheduler. Do not create independent repeating
Lua timers during hot reload.

| Job | Target behavior |
| --- | --- |
| MCP commands | Prefer named-pipe or socket notification. Until native IPC exists, poll only the command file every 500 ms. |
| PalCom responses | Deliver through the same inbound IPC channel. Until then, poll only while a response is pending. |
| Discovery | Make it an explicit diagnostic command; remove permanent discovery-file polling. |
| Base roster changes | Hook worker-container changes to request an immediate reinforcement pass. Retain a one-minute integrity reconciliation initially. |
| Incapacitation | Hook an authoritative faint/downed transition to request an immediate reinforcement pass. Retain a one-minute integrity reconciliation initially. |
| Heartbeat | Write a cheap cached liveness record every two seconds. Do not call `player_context` from the heartbeat writer. |
| Readiness | Refresh cached controller, player-state, and inventory availability every 5–10 seconds and on relevant commands or world changes. |
| Reserve queue | Rebuild every 60 seconds or once when exhausted. Treat Palbox/health events as cache invalidations, not as an exclusive correctness mechanism. |
| Watchdog | Check its timestamp cheaply on scheduler wakes; it performs no roster scan. |

## Implementation sequence

1. Add per-job deadlines to the single scheduler and move command polling to
   500 ms.
2. Split heartbeat liveness from expensive readiness discovery. Increase MCP
   heartbeat freshness from three seconds to approximately seven seconds.
3. Convert discovery into an explicit bridge command.
4. Add worker-roster and downed-state hooks that set a boolean
   `reinforcement_pass_requested`; consume that flag on the game thread.
5. Prototype a native named-pipe transport for commands and PalCom responses.
6. Keep periodic fallbacks until missed-event telemetry demonstrates that the
   hooks are reliable across loading, replication, and hot reload.

## Implemented behavior

- One generation-guarded scheduler wakes every 500 ms.
- The command mailbox is probed once per scheduler wake.
- PalCom response polling occurs only while a request is pending.
- The liveness heartbeat is written from cached readiness every two seconds.
- The cheap readiness probe refreshes every 10 seconds.
- Heartbeat freshness on the MCP side is seven seconds.
- PalCom discovery is the explicit read-only
  `discover_palcom_functions` bridge/MCP command.
- Character-container swap, worker-roster creation, and supported authoritative
  death-transition hooks request a coalesced reinforcement pass.
- Reinforcement is event-first. Queue refresh and integrity reconciliation share
  one pass every 60 seconds; there is no five-second roster scan.
- Heartbeats expose scheduler wakeups, probes, event/coalescing counts, scans,
  and last reinforcement-pass CPU duration.

## Native IPC decision

Native named-pipe/socket notification remains deferred. Stock UE4SS Lua does
not expose a non-blocking named-pipe primitive, and using `io.open` against a
Windows named pipe can block the game thread. A future native bridge must
enqueue notifications for consumption on the game thread; it must not execute
Unreal reads or writes from its I/O thread.

This is step 5 of the implementation sequence and it cannot be done in Lua. It
needs a native Windows component built and tested against the target UE4SS
release, so it stays deferred rather than partially attempted.

## Removing the periodic fallbacks (step 6)

Step 6 is gated on evidence, not on more code: the fallbacks stay until missed
event telemetry shows the hooks are reliable across loading, replication, and
hot reload. The measurement that was missing is now collected.

`scheduler_reinforcement_integrity_effective` counts periodic passes that
actually had reinforcement work to do. Every one of those is work the event
hooks did not request, so it is the direct miss count for the hooks:

- `scheduler_reinforcement_integrity_passes` — periodic passes that ran.
- `scheduler_reinforcement_integrity_effective` — of those, how many found
  work. A sustained zero across raids, base loads, and hot reloads is the
  evidence that the one-minute reconciliation can go.
- `scheduler_reinforcement_event_requests` / `_coalesced` / `_passes` — what
  the hooks did request in the same window.
- `scheduler_last_queue_build_ms` and `scheduler_last_reinforcement_pass_ms` —
  the cost of each, so the fallback's price is visible alongside its value.

Do not remove the fallback on a single session's numbers. It needs several
raids, at least one hot reload, and at least one base stream-out and back.

## PalCom broker implementation

Companion Bridge `0.1.0-dev.88` and the matching MCP server remove the PalCom
broker's 250 ms request loop:

- A bounded single-reader channel coalesces `FileSystemWatcher` events for the
  atomic request mailbox.
- An existing request is claimed once at startup.
- Watcher errors recreate the watcher and recheck the mailbox.
- The readiness lease is 15 seconds and renews every five seconds.
- Lua adds no response timer. Its existing scheduler uses a 500 ms response
  deadline initially, one second after three seconds, and two seconds after
  30 seconds, stopping immediately on response or at the 90-second deadline.
- Broker status and bridge heartbeat fields expose event, lease, probe,
  recovery, timeout, and latency telemetry.

## Safety and performance constraints

- Unreal reads and writes remain on the game thread.
- Event callbacks only invalidate caches or request work; they do not perform a
  full Palbox scan inline.
- Coalesce repeated events into one pending pass.
- Preserve the stale-loop generation guard.
- Never retry an unchanged reserve candidate rejected by a verified swap.
- Measure scheduler wakeups, file probes, roster scans, Palbox scans, and pass
  duration before removing fallbacks.
