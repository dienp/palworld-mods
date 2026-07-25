# Base operations dashboard: feasibility research

Research date: 2026-07-25

## Question and conclusion

Can a mod give an expert player a fast, consolidated view of base health,
including production, unhealthy workers, power, and completed expeditions?

**Yes, with qualifications.** Palworld modding can inspect live Unreal objects,
add UI, and read or derive some of the requested signals. The product should aim
to run entirely on the player's client, with no required server-side component.
Version 0 must therefore establish which operational values already replicate
to an ordinary client and how trustworthy they remain when a base is streamed
out. It is not currently a small data-only pak, and Palworld's documented
dedicated-server REST API is not a base-management API. A useful client-only
version is feasible if enough state is replicated; otherwise the product must
narrow its claims instead of introducing a mandatory server component.

No source found establishes a supported public API for every requested metric.
Accordingly, this note separates directly observable values from derived
analytics and treats exact reflected names as an item for a current-build SDK
probe rather than guessing them.

## Capability matrix

| Feature | Feasibility | Likely observation | Important qualification |
| --- | --- | --- | --- |
| Base identity, level, worker count | High | Live base/camp model and replicated state | Confirm ownership/guild filtering on the server. |
| Worker identity and assignment | High | Base worker roster plus each worker's current work state | Never infer membership only from nearby actors; unloaded workers may not have actors. |
| Injured, sick, hungry, low-SAN, incapacitated workers | High | Persistent Pal parameters/status effects, with live actor data when loaded | Thresholds should be configurable and labels should distinguish injury, ailment, hunger, and SAN. |
| Current task, idle, sleeping, stuck | Medium-high | Worker state/AI task and sampled position/progress | “Stuck” is an inference over time, not a trustworthy single flag. |
| Electricity level and generation/consumption | High for current state; medium for forecasts | Power storage/network objects and connected consumers/producers | Forecast time-to-empty needs sampled rates and must account for intermittent generators. |
| Queued production and completion | High | Production facility queues, required work, accumulated work, and output state | Include blocked-output and missing-input conditions separately. |
| Production rate and utilization | Medium | Delta sampling of accumulated work/output, correlated with assigned workers and uptime | A displayed rate should say whether it is instantaneous, rolling observed throughput, or a theoretical estimate. |
| Resource inventory and shortages | Medium-high | Base storage/container inventories and recipe requirements | Scanning every container every frame is too expensive; cache and refresh slowly or on relevant events. |
| Expedition running/completed/claimable | Medium-high | Expedition facility or subsystem state and reward/claim state | Exact model, authority, and persistence behavior must be confirmed on the current game build. |
| Cross-base overview from anywhere | Unknown until Version 0 | Client-visible persistent models or already-replicated summaries | No custom server bridge is allowed in the baseline; remote values may be stale or unavailable. |
| Historical trends and alerts | High once collection works | Mod-owned time-series samples and rules | Keep history out of the game save unless persistence compatibility is proven. |

## What the available mod surfaces mean

### Official dedicated-server REST API

Pocketpair's documented REST endpoints cover server information and
administration such as player listing, settings, metrics, announcements,
moderation, save, shutdown, and stop. They do not document base rosters,
production queues, Pal health, electricity, or expeditions. REST is therefore
useful for a separate server administrator panel but is not sufficient for this
player dashboard.

### UE4SS runtime mod

UE4SS exposes Lua facilities for locating Unreal objects/classes, iterating
objects and properties, registering hooks, and scheduling work on the game
thread. That is enough to make a read-only discovery probe and, after current
SDK validation, collect base state. Existing work in this repository also
shows why reflection presence is not proof that every hook is safe: interface
hooks and temporary output parameters can crash even when registration
succeeds. Prefer polling stable model objects at a low rate and known lifecycle
events over hot-path UI or AI hooks.

UE4SS is the fastest research path, not necessarily the final UI path. Lua can
prove which values exist and how authority behaves. A polished dashboard may
then use a cooked UMG widget/LogicMod for presentation, with a narrow runtime
bridge providing data. If Blueprint cannot access the required internals, a
native component is the higher-cost fallback.

### Data-only pak or LogicMod alone

A data-only pak can replace or configure cooked assets but cannot by itself
invent a comprehensive base telemetry API. A LogicMod can provide Blueprint
logic and UI where the relevant functions/properties are Blueprint-visible,
but it should not be assumed to see non-exposed native state or authoritative
state for streamed-out bases. Treat a pure LogicMod implementation as an
experiment, not the baseline architecture.

### Offline save parsing

Community save parsers demonstrate that persistent Pal, guild, and base data
can be decoded outside the running game. This is useful for discovery and
offline reports, but it cannot give trustworthy live queues, worker AI state,
power flow, or immediate completion alerts. Reading a save while the server is
writing it also introduces consistency and operational risks. It should be an
optional companion, not the live dashboard's core.

## Recommended product scope

### Version 0: client-only read-only telemetry probe

#### Goal

Do not begin with a full widget. Build a development-only UE4SS Lua probe that
runs on an ordinary player's client and answers one product-defining question:

> What trustworthy base-operation data is already available to a client without
> installing code on the host or dedicated server?

The probe must not depend on a custom server-to-client bridge. A listen-server
host can be used as a comparison environment, but host-only access does not
count as proof that the client-only product works.

#### Probe behavior

The probe should:

1. Resolve the local player's guild and enumerate only client-visible base
   models belonging to that guild.
2. Dump reflected class names and a strict allowlist of candidate properties
   once per game build.
3. Join persistent IDs where available; never use display names, proximity, or
   raw object addresses as durable identity.
4. Sample candidate counters every 5 seconds and write structured JSON Lines
   with a session ID, game build, timestamp, network role, base-loaded state,
   source object, and observation age.
5. Compare observations while inside the base, outside render distance, after
   fast travel, after dungeon entry/exit, and after reconnect.
6. Mark each value as reliable, loaded-only, cached, derivable, or unavailable.
7. Perform no state mutation, no save writes, no network commands, and no
   per-frame world scan.

#### Expected diagnostic output

Each sample should contain enough provenance to distinguish live replicated
truth from an old client observation:

```json
{
  "schemaVersion": 1,
  "sessionId": "20260726-001",
  "gameBuild": "current-build-id",
  "timestamp": "2026-07-26T01:30:05+07:00",
  "networkRole": "dedicated-client",
  "guildId": "stable-guild-id",
  "base": {
    "id": "stable-base-id",
    "loaded": false,
    "lastLoadedAt": "2026-07-26T01:26:10+07:00"
  },
  "observations": [
    {
      "metric": "worker.rosterCount",
      "value": 28,
      "sourceClass": "ReflectedClassName",
      "sourceProperty": "ReflectedPropertyName",
      "classification": "cached",
      "observedAt": "2026-07-26T01:26:10+07:00",
      "ageSeconds": 235,
      "matchesVanillaUi": true
    }
  ]
}
```

The repository output for Version 0 should include:

- the reproducible UE4SS probe source;
- timestamped JSONL samples for each supported test mode, kept out of Git when
  they contain machine- or session-specific data;
- a sanitized capability matrix mapping every requested metric to its source,
  authority, streaming behavior, confidence, and classification;
- evidence notes comparing samples with vanilla UI and direct observation;
- sampling cost measurements with several full bases; and
- a go/no-go recommendation for the client-only Version 1 dashboard.

#### Classification rules

| Classification | Required evidence | Product treatment |
| --- | --- | --- |
| Reliable | Accurate on an ordinary client while loaded and streamed out, including after reconnect | May be shown as current with observation time. |
| Loaded-only | Accurate only while the base or relevant actor is streamed in | Show only as live for loaded bases. |
| Cached | Remains visible after streaming but does not reliably refresh | Show last-observed value, timestamp, and age. |
| Derivable | Can be calculated from repeated trustworthy client observations | Label the sampling window and derivation. |
| Unavailable | Not exposed or not trustworthy on an ordinary client | Exclude from the client-only product. |

#### Research questions

The first proof should answer these questions on the current Palworld build:

- Can an ordinary remote client enumerate all of its guild's bases when their
  areas are streamed out?
- Does a persistent client-visible roster expose worker condition and assigned
  task, or must live worker actors be joined to persistent Pal records?
- Which production queue fields replicate, and do they continue updating while
  the facility is streamed out?
- Are electricity storage, generation, and consumption available per base,
  network, or facility on the client?
- Does expedition state replicate, including the distinction between running,
  completed, claimable, and claimed?
- Which client values survive fast travel, dungeon transitions, reconnects,
  and server restarts, and which are merely stale cached observations?
- Can guild ownership be verified from replicated IDs without proximity-based
  guesses or disclosure of another guild's state?

### Version 1: minimum useful dashboard

Ship a read-only, on-demand panel with one card per base:

- worker capacity and active/idle/sleeping/problem counts;
- named critical alerts for injury, ailment, hunger, low SAN, incapacity, and
  prolonged lack of progress;
- electricity current/capacity plus a clearly labelled observed net trend;
- production facilities grouped into active, complete, input-blocked,
  output-blocked, and unstaffed;
- expedition state grouped into available, running with remaining time,
  complete/claimable, and blocked;
- “data age” and “base loaded” indicators so stale values are never presented
  as live truth.

Open the dashboard by a configurable key and refresh its lightweight summary
every 2–5 seconds while visible. Expensive inventory aggregation can refresh
every 15–30 seconds or on container events. Stop or sharply reduce sampling
when the panel is closed.

### Version 2: expert analytics

Add analytics only after raw fields are validated:

- rolling 1/5/15-minute observed throughput;
- facility utilization and downtime reason percentages;
- input runway and output-storage saturation estimates;
- electricity time-to-empty based on an explicitly shown observation window;
- worker suitability mismatch and alternative-assignment suggestions;
- configurable thresholds, sorting, alert acknowledgement, and base-to-base
  comparison;
- optional local CSV/JSON export.

Avoid claiming an “optimal” assignment until the formula has been validated
against traits, passives, food buffs, work suitability, facility modifiers,
night behavior, transport delays, and game difficulty settings.

## Proposed architecture

```text
client-side collector
  -> normalized observations with freshness/classification
  -> local client cache
  -> cooked UMG dashboard
  -> optional local-only history/export
```

Use stable IDs for guild, base, Pal, facility, queue item, and expedition where
the game exposes them. Never use display names or raw object addresses as
persistent identity. Each snapshot should carry the game build, schema version,
collection time, authority source, and loaded/stale flags.

For single player, collector and UI coexist in one process. On a listen or
dedicated server, the baseline product remains client-only and is limited to
state already replicated to the participating client. Clearly document
missing, loaded-only, and cached values. A server-side collector or custom
network bridge is outside the product target and must not become an implicit
installation requirement.

## Performance and safety constraints

- Keep the first implementation strictly read-only.
- Never modify the main pak or write into Palworld saves.
- Do not retain Unreal temporary/out-parameter wrappers after a callback.
- Avoid `NotifyOnNewObject`-style global work without exact class filters.
- Avoid iterating all world objects, all Pals, or all containers per frame.
- Copy needed primitive values on the game thread, then aggregate plain data
  away from engine object access where safe.
- Invalidate cached Unreal objects on world teardown, travel, disconnect, base
  destruction, and server shutdown.
- Preserve diagnostic switches and disable verbose diagnostics by production
  configuration rather than deleting them.
- Back up saves before any multiplayer test even though the design is
  read-only.

## Feasibility gates and stop conditions

Proceed to a client-only UI prototype only when an ordinary remote client
demonstrates all of the following:

1. Stable IDs join enough of the client-visible roster, facilities, power, and
   expedition state to create useful base cards without proximity-only guesses.
2. Every displayed condition agrees with vanilla UI or direct observation and
   has a documented classification.
3. Loaded-only and cached values are detected and cannot be mistaken for live
   streamed-out state.
4. The client can verify guild ownership and does not expose another guild's
   operational state.
5. Sampling with multiple max-size bases creates no visible client frame
   regression.

If streamed-out base models do not retain operational state, narrow the product
claim to “loaded base inspector with last-observed summaries.” If too few
useful metrics replicate, stop the dashboard rather than adding a required
server component. If current Workshop rules cannot carry the required runtime
component, distribute only through an explicitly documented client-side UE4SS
installation path; do not label the pak as standalone.

## Test plan

- **Modes:** single player, listen host, listen client, dedicated server, and
  dedicated client.
- **Streaming:** inside a base, outside render distance, fast travel between
  bases, dungeon entry/exit, reconnect, and server restart.
- **Worker cases:** healthy, hungry, low SAN, sick/injured, incapacitated,
  sleeping, idle, transporting, assigned to an incompatible station, and
  deliberately path-blocked.
- **Production cases:** empty input, full output, no power, no worker, multiple
  workers, queue completion while panel is closed, and cancellation.
- **Power cases:** surplus, deficit, empty battery, full battery, generator
  worker stops, and multiple power networks if supported by vanilla.
- **Expeditions:** available, dispatched, running, completes while nearby,
  completes while streamed out, claimable, claimed, and restart during run.
- **Scale:** every allowed base at worker capacity with many storages and
  production facilities.

For each scenario, compare the snapshot with vanilla UI and direct in-world
observation, record the game build and mod versions, and verify the packaged
payload and install manifest. The generic mod warning is not evidence that the
collector loaded.

## Decision

This concept is viable enough for a client-only discovery prototype. Version 0
must determine the boundary of replicated client state before any dashboard is
promised. The strongest differentiator is not merely showing existing numbers;
it is honest cross-base triage that distinguishes live, loaded-only, cached,
derived, and unavailable information. Start with the client-side telemetry
probe. Defer the dashboard, optimization recommendations, and long-term history
until the replicated fields, streaming behavior, expedition visibility, and
rate formulas are measured on the current build.

## Sources and confidence

Primary references:

- Pocketpair, **Palworld REST API**:
  <https://tech.palworldgame.com/api/rest-api/>. This defines the supported
  dedicated-server HTTP surface and is the basis for the conclusion that the
  documented API is administrative rather than base telemetry.
- UE4SS, **Lua API documentation**: <https://docs.ue4ss.com/lua-api/>. Relevant
  surfaces include object/class lookup, property access, hooks, object
  notification, and game-thread execution.
- UE4SS, **Lua types**: <https://docs.ue4ss.com/lua-api/classes.html>. This
  documents the wrappers a discovery probe would use and their validity
  constraints.
- UE4SS project source: <https://github.com/UE4SS-RE/RE-UE4SS>. Use the release
  matching the target Palworld build rather than assuming APIs from an
  arbitrary branch.
- Pocketpair, **Palworld Modding Kit**:
  <https://github.com/pocketpairjp/PalworldModdingKit>. This is the official
  starting point for cooked mod content and Blueprint/LogicMod work.

Secondary discovery reference:

- cheahjs, **palworld-save-tools**:
  <https://github.com/cheahjs/palworld-save-tools>. This supports the limited
  claim that community tooling can decode save data; it does not establish a
  supported or live base telemetry API.

The external web search service was unavailable during this research session,
so these known primary project/documentation locations could not be re-opened
and line-verified on 2026-07-25. Before implementation, re-check their current
versions and licensing and inspect a generated SDK for the exact target game
revision. Confidence is **high** in the architectural feasibility, **high**
that documented REST alone is insufficient, and **medium** in expedition and
streamed-out cross-base coverage until a live reflection probe is run.
