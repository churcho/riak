# syn Integration: Maintainer Knowledge Base

This document explains the design, concepts, and operational details of
the syn integration in the `riak_admin_api` application. It is written
for Riak maintainers who need to understand, debug, or extend the
distributed discovery subsystem.

---

## Table of Contents

1. [Why syn?](#why-syn)
2. [What syn Gives Us](#what-syn-gives-us)
3. [Architecture Overview](#architecture-overview)
4. [Module Reference](#module-reference)
5. [Startup Sequence](#startup-sequence)
6. [syn Scope and Groups](#syn-scope-and-groups)
7. [Registry Metadata](#registry-metadata)
8. [Conflict Resolution](#conflict-resolution)
9. [Crash Recovery](#crash-recovery)
10. [DC Discovery Flow](#dc-discovery-flow)
11. [Port Assignment (devrel)](#port-assignment-devrel)
12. [Isolation Pattern](#isolation-pattern)
13. [Configuration](#configuration)
14. [Operational Guide](#operational-guide)
15. [Troubleshooting](#troubleshooting)
16. [API Reference](#api-reference)
17. [Design Decisions and Tradeoffs](#design-decisions-and-tradeoffs)
18. [Future Work](#future-work)

---

## Why syn?

Riak's existing infrastructure (riak_core ring gossip) provides cluster
membership for a **single** ring. It does not answer questions about
other administrative endpoints, other datacenters, or non-ring-member
processes. We needed a mechanism for admin API instances to:

1. **Discover each other** across the entire distributed Erlang cluster.
2. **Advertise metadata** (DC name, ports, version) so dashboards can
   connect to any node without hard-coded configuration.
3. **Handle netsplits gracefully** with deterministic conflict resolution.
4. **Be zero-configuration** for operators: no extra ports, no config
   files, no external services.

### Why syn over alternatives?

| Option | Reason for/against |
|--------|--------------------|
| **syn** (chosen) | Lightweight, Erlang-native, uses distributed Erlang (already available in Riak). ETS-backed reads are microsecond-fast. Battle-tested conflict resolution. No external dependencies. |
| **pg** (OTP 23+) | OTP's built-in process groups. No registry (key-value lookup), no metadata on members, no conflict resolution callbacks. Too limited. |
| **gproc** | Feature-rich but heavier, less maintained, complex API surface. |
| **Manual rpc:call** | Requires knowing all node addresses upfront. Fragile during membership changes. No automatic discovery. |
| **External service** (etcd, Consul) | Adds operational complexity. Riak already has distributed Erlang; adding a consensus system alongside it is redundant. |

syn piggybacks on Riak's existing distributed Erlang connections. If
`net_adm:ping('dev2@127.0.0.1')` works, syn works. No additional
network configuration needed.

---

## What syn Gives Us

Before syn, the admin API could only see its local cluster:

```
Before:
  rah_cluster → gateway → riak_core_ring → local cluster only

After:
  rah_cluster → gateway → riak_core_ring → local cluster
                         → syn:members(riak_admin, api_nodes) → remote DCs appended
```

One additional function call in the gateway module. Remote DCs appear
because their coordinator processes registered with syn on startup, and
syn propagated that registration across all connected nodes.

The `/api/dcs` endpoint is entirely syn-powered -- it doesn't touch
riak_core at all. It queries syn's local ETS table for group members
and formats the results.

---

## Architecture Overview

```
                    +---------------------------+
                    |   riak_admin_api_app.erl   |
                    |  (OTP application module)  |
                    +---------------------------+
                              |
                    1. Configure syn event handler
                    2. Initialize syn scope
                    3. Start Cowboy listener
                    4. Start supervisor
                              |
                    +---------------------------+
                    |  riak_admin_api_sup.erl    |
                    |  (one_for_one supervisor)  |
                    +---------------------------+
                              |
                    +---------------------------+
                    | riak_admin_api_coordinator |
                    |    (gen_server worker)     |
                    +---------------------------+
                              |
                    syn:register (registry)
                    syn:join (api_nodes group)
                    syn:join (cluster_events group)
                              |
              +---------------+------------------+
              |                                  |
    +-------------------+            +-------------------------+
    | syn registry      |            | syn groups              |
    | {api_node, Node}  |            | api_nodes: discovery    |
    | → coordinator_meta|            | cluster_events: pubsub  |
    +-------------------+            +-------------------------+
              |                                  |
    Queried by gateway                 Queried by gateway
    (syn:lookup/2)                     (syn:members/2)
              |                                  |
    +-----------------------------------------------------+
    |            riak_admin_api_riak.erl                    |
    |  list_dcs/0, remote_dcs/0 → format into dc_info()    |
    +-----------------------------------------------------+
              |
    +-------------------+
    | rah_dcs.erl       |
    | GET /api/dcs      |
    +-------------------+
```

---

## Module Reference

| Module | Role | syn Usage |
|--------|------|-----------|
| `riak_admin_api_app` | Application callback. Configures syn event handler and initializes the `riak_admin` scope before starting Cowboy and the supervisor. | `syn:add_node_to_scopes/1`, `application:set_env(syn, ...)` |
| `riak_admin_api_coordinator` | GenServer. Owns the syn registration lifecycle. Registers in the registry and joins groups on init. Handles crash-restart with stale-key retry. | `syn:register/4`, `syn:unregister/2`, `syn:join/3,4`, `syn:publish/3` |
| `riak_admin_event_handler` | `syn_event_handler` behaviour. Logs node discovery/departure events. Resolves netsplit conflicts (oldest wins). | Callback module -- syn calls it, not the other way around. |
| `riak_admin_api_riak` | Gateway module. Reads syn group membership for DC discovery. This is where `syn:members/2` is called. | `syn:members/2` (read-only) |
| `rah_dcs` | HTTP handler for `/api/dcs`. Thin wrapper -- calls `riak_admin_api_riak:list_dcs/0`. | None (indirect via gateway) |
| `riak_admin_api_sup` | Supervisor. Manages the coordinator's lifecycle with `one_for_one` strategy. | None |
| `riak_admin_api_handler` | Shared HTTP response helpers (`json_reply/3`, `error_reply/4`). | None |

### syn Call Distribution

syn calls are intentionally distributed across two modules:

- **Lifecycle calls** (register, join, unregister, publish) live in the
  **coordinator**. These are write operations tied to the coordinator
  process's identity.
- **Query calls** (syn:members) live in the **gateway**. These are
  read operations that any handler might need.

This split keeps each module's responsibility clear: the coordinator
owns its process identity; the gateway owns data access.

---

## Startup Sequence

The startup sequence is carefully ordered. Each step has a dependency
on the previous one.

```
riak_admin_api_app:start/2
  |
  |-- 1. application:set_env(syn, event_handler, riak_admin_event_handler)
  |      Must happen BEFORE syn:add_node_to_scopes/1.
  |      If set after, syn won't call our conflict resolution callback.
  |
  |-- 2. syn:add_node_to_scopes([riak_admin])
  |      Creates local ETS tables for the riak_admin scope.
  |      Must complete BEFORE the coordinator tries to register.
  |
  |-- 3. resolve_port() / resolve_riak_http_port()
  |      Detect devrel port or use configured default.
  |      Write resolved values back to app env so the coordinator
  |      reads the actual ports (not defaults) when building metadata.
  |
  |-- 4. cowboy:start_clear(riak_admin_http, ...)
  |      Start the HTTP listener.
  |
  |-- 5. riak_admin_api_sup:start_link()
  |      Start the supervisor tree.
  |      |
  |      +-- riak_admin_api_coordinator:init/1
  |            |
  |            |-- build_metadata()
  |            |     Reads DC name, ports, version from app env.
  |            |
  |            +-- register_with_syn(Meta)
  |                  syn:register + syn:join (registry + 2 groups)
```

**Critical ordering constraint:** If step 1 and 2 are swapped (syn
scope initialized before event handler is configured), syn will not
route events to our handler. The handler must be set first because
syn reads it during scope initialization.

---

## syn Scope and Groups

### Scope: `riak_admin`

A syn scope is a namespace that partitions the registry and groups.
All admin API instances across all DCs share a single scope:
`riak_admin`.

If future features need isolated process groups (e.g., monitoring
for a different subsystem), use a different scope.

### Registry Key: `{api_node, Node}`

Each coordinator registers with a key derived from its Erlang node
name. This guarantees uniqueness per node while allowing easy lookup:

```erlang
syn:lookup(riak_admin, {api_node, 'dev1@127.0.0.1'}).
%% => {<0.1234.0>, #{dc => <<"default">>, http_port => 10015, ...}}
```

### Group: `api_nodes`

All coordinators join this group with their metadata. This is the
primary discovery mechanism -- `syn:members/2` returns all members
with their metadata in a single ETS read:

```erlang
syn:members(riak_admin, api_nodes).
%% => [{<0.1234.0>, #{dc => <<"east">>, node => 'n1@10.0.1.10', ...}},
%%     {<0.5678.0>, #{dc => <<"west">>, node => 'n2@10.0.2.10', ...}}]
```

### Group: `cluster_events`

Coordinators also join this group for pub/sub notifications. When
a coordinator receives a `{cluster_event, Event}` message, it
publishes to all group members via `syn:publish/3`. This enables
future real-time event streaming (e.g., WebSocket push in M8).

---

## Registry Metadata

Each coordinator advertises a `coordinator_meta()` map:

| Field | Type | Source | Purpose |
|-------|------|--------|---------|
| `dc` | `binary()` | App env `dc_name` | Identifies which datacenter this node belongs to |
| `node` | `node()` | `node()` | Erlang node atom for display and RPC |
| `http_port` | `pos_integer()` | App env `http_port` (resolved) | Admin API port for building URLs |
| `riak_http` | `pos_integer()` | App env `riak_http_port` (resolved) | Riak HTTP port for proxying/linking |
| `riak_vsn` | `binary()` | `application:get_key(riak_kv, vsn)` | Riak version for compatibility display |
| `started_at` | `non_neg_integer()` | `erlang:system_time(second)` | Conflict resolution tiebreaker |

The `started_at` field is critical -- it's the deterministic input
to conflict resolution. See [Conflict Resolution](#conflict-resolution).

---

## Conflict Resolution

### The Problem

During a network partition, both sides may restart their coordinator
process. When the partition heals, syn discovers two registrations
for the same key `{api_node, Node}`. It must pick one.

### The Strategy: Oldest Wins

The event handler's `resolve_registry_conflict/4` picks the process
with the lowest `started_at` timestamp. This is:

- **Deterministic:** both sides compute the same winner.
- **Stable:** the winner doesn't change on subsequent calls.
- **Safe:** the loser is the process that started during the partition
  (the "emergency replacement"), which is the right one to discard.

```erlang
resolve_registry_conflict(riak_admin, Key,
                          {Pid1, Meta1, _Time1}, {Pid2, Meta2, _Time2}) ->
    Started1 = safe_started_at(Meta1),
    Started2 = safe_started_at(Meta2),
    case Started1 =< Started2 of
        true  -> Pid1;    %% older process wins
        false -> Pid2
    end.
```

### syn 3.3.0 API Note

The syn 3.3.0 conflict resolution callback receives **3-tuples**
`{Pid, Meta, Time}` and must return the **PID to keep**. This differs
from older syn versions that used 2-tuples and returned `1 | 2`.
The `Time` field is syn's internal registration timestamp (not our
`started_at`); we ignore it in favour of our own metadata.

### Defensive Metadata Access

The `Meta` argument is typed as `term()` by syn's callback spec.
It may not be a map if, for example, a process registered with
non-map metadata (or metadata was corrupted during a netsplit).
The `safe_started_at/1` helper handles this gracefully:

```erlang
safe_started_at(Meta) when is_map(Meta) ->
    maps:get(started_at, Meta, 0);
safe_started_at(_) ->
    0.
```

A missing or non-map `started_at` defaults to 0 (epoch), meaning
a process with corrupt metadata is treated as "oldest" and wins.
This is conservative -- we prefer keeping a running process over
killing it due to metadata issues.

---

## Crash Recovery

### The Problem

When the coordinator crashes and the supervisor restarts it, the
new process tries to register with the same key. But syn may not
have processed the old process's `DOWN` signal yet, so the key
is still "taken".

### The Solution: Stale-Key Retry

```erlang
register_with_syn(Meta) ->
    Key = ?REGISTRY_KEY(node()),
    case syn:register(?SCOPE, Key, self(), Meta) of
        ok -> ok;
        {error, taken} ->
            %% Stale entry from previous incarnation
            case syn:unregister(?SCOPE, Key) of
                ok -> ok;
                {error, UnregReason} ->
                    %% syn already cleaned up, or cluster is syncing.
                    %% Brief pause lets syn finish processing the DOWN.
                    timer:sleep(100)
            end,
            ok = syn:register(?SCOPE, Key, self(), Meta)
    end,
    ok = syn:join(?SCOPE, ?GROUP_NODES, self(), Meta),
    ok = syn:join(?SCOPE, ?GROUP_EVENTS, self()),
    ok.
```

### Why not just crash?

If `register_with_syn` crashes on `{error, taken}`, the supervisor
restarts the coordinator, which tries to register again, gets
`{error, taken}` again (syn still hasn't processed the DOWN), and
crashes again. This loop exhausts the supervisor's `intensity`
(5 restarts in 10 seconds) and brings down the entire supervisor
tree -- including any future children.

The stale-key retry breaks this loop by cleaning up before retrying.

### syn:unregister Return Values

`syn:unregister/2` can return:

- `ok` -- stale entry removed, retry will succeed.
- `{error, undefined}` -- syn already processed the DOWN. Safe to
  retry immediately.
- `{error, race_condition}` -- cluster is mid-sync. A 100ms sleep
  lets syn converge, then retry.

Both error cases are recoverable. The sleep is conservative but
prevents a tight retry loop during cluster convergence.

---

## DC Discovery Flow

### /api/dcs Request Flow

```
Client → GET /api/dcs
  → rah_dcs:init/2
    → riak_admin_api_riak:list_dcs/0
      → riak_admin_api_coordinator:get_dc_name()   (local DC name)
      → syn:members(riak_admin, api_nodes)          (all members, ETS read)
      → format_dc_member/2 for each member          (coordinator_meta → dc_info)
      → dedup_by_dc/1                               (one entry per DC name)
    ← {ok, [dc_info()]}
  → json_reply(200, #{dcs => DCs, count => N})
← HTTP 200 {"dcs":[...], "count":N}
```

### Map Key Mapping

The coordinator stores metadata with internal keys. The gateway
transforms these to external-facing keys for the API response:

| coordinator_meta() | dc_info() | Reason |
|--------------------|-----------|--------|
| `dc` | `name` | API consumers expect `name`, not the internal `dc` key |
| `node` | `node` | Same |
| `http_port` | (used to build `admin_url`) | Consumers need a full URL, not just a port |
| `riak_http` | (used to build `riak_url`) | Same |
| `riak_vsn` | `riak_version` | More readable for API consumers |
| -- | `local` | Computed: `dc =:= LocalDC` |
| -- | `reachable` | Always `true` (syn members are reachable by definition) |

### Deduplication

Multiple nodes in the same DC will all have the same `dc` name.
`dedup_by_dc/1` keeps only the first-seen node for each DC name.
This means the `/api/dcs` response shows one entry per DC, not one
per node.

### remote_dcs/0

Used by `cluster_status/0` to append remote DC information. Filters
out the local DC and returns only remote DCs. Gracefully returns `[]`
on any failure so that cluster_status never breaks due to syn issues.

---

## Port Assignment (devrel)

In a devrel cluster, each node is named `devN@127.0.0.1` (N = 1..8).
Riak's existing ports follow a `100N_` pattern:

| Port Pattern | Service |
|-------------|---------|
| `100N5` | **Admin API** (this application) |
| `100N6` | Cluster manager |
| `100N7` | Protocol Buffers |
| `100N8` | HTTP (Webmachine) |
| `100N9` | Handoff |

The admin API uses digit **5** to avoid collisions with all existing
services (digits 6-9).

### How It Works

`resolve_port/0` and `resolve_riak_http_port/0` in `riak_admin_api_app`
extract `N` from the node name using a regex:

```erlang
case re:run(NodeStr, "^dev([0-9]+)@", [{capture, [1], list}]) of
    {match, [NStr]} ->
        N = list_to_integer(NStr),
        10000 + N * 10 + 5;   %% admin API: 10015, 10025, 10035, ...
    nomatch ->
        Default              %% production: use configured port
end
```

The resolved ports are written back to application env so the
coordinator reads the actual values when building metadata:

```erlang
application:set_env(riak_admin_api, http_port, Port),
application:set_env(riak_admin_api, riak_http_port, RiakHttpPort),
```

Without this writeback, syn metadata would advertise the default
ports (8099, 8098) instead of the devrel-specific ports.

### Production

In production (single-node or non-devN node names), the configured
defaults are used:

- Admin API: `http_port` (default 8099)
- Riak HTTP: `riak_http_port` (default 8098)

---

## Isolation Pattern

### The Rule

**Only `riak_admin_api_riak.erl` may reference `riak_core`, `riak_kv`,
`riak_object`, or any other Riak internal module.**

No other module in `riak_admin_api` may call Riak internals directly.

### Why This Matters

1. **Compile-time independence:** The `.app.src` does not list
   `riak_core` or `riak_kv` as dependencies. `rebar3 compile` works
   without Riak source present because Erlang resolves module calls
   at runtime, not compile time.

2. **Testability:** Every handler is testable in isolation. Swap the
   gateway module for a mock and Cowboy still works.

3. **Extractability:** Moving `riak_admin_api` to its own repository
   is mechanical: copy the directory, change `path` to `git` in Riak's
   `rebar.config`, done.

### Verification

Run this before every commit:

```bash
grep -rn "riak_core\|riak_kv\|riak_object\|riak:local" src/ \
  | grep -v riak_admin_api_riak.erl
```

Should return zero results. Any match indicates an isolation leak.

### Where syn Fits

syn itself is NOT a Riak internal -- it's an explicit dependency
listed in `.app.src`. The isolation rule applies to Riak-specific
modules only. syn calls are allowed in the coordinator (lifecycle)
and gateway (reads).

However, `get_riak_version/0` lives in the gateway because it
references `riak_kv` by name (`application:get_key(riak_kv, vsn)`).
The coordinator calls it indirectly through the gateway.

---

## Configuration

All configuration is via OTP application env, overridable in
`advanced.config` or `sys.config`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `http_port` | `pos_integer()` | `8099` | Admin API listen port |
| `dc_name` | `binary()` | `<<"default">>` | Datacenter identifier for multi-DC |
| `riak_http_port` | `pos_integer()` | `8098` | Riak HTTP port (advertised in metadata) |

### Multi-DC Setup

To enable multi-DC discovery, set `dc_name` differently on each DC:

```erlang
%% DC East (sys.config or advanced.config)
{riak_admin_api, [
    {dc_name, <<"east">>}
]}.

%% DC West
{riak_admin_api, [
    {dc_name, <<"west">>}
]}.
```

Nodes in different DCs must be connected via distributed Erlang for
syn to propagate registrations.

---

## Operational Guide

### Verifying syn State

Connect to a node via remote console:

```bash
dev/dev1/bin/riak remote_console
```

```erlang
%% Is the coordinator registered?
syn:lookup(riak_admin, {api_node, node()}).
%% => {<Pid>, #{dc => <<"default">>, http_port => 10015, ...}}

%% How many nodes are in the discovery group?
syn:members(riak_admin, api_nodes).
%% => [{<Pid1>, Meta1}, {<Pid2>, Meta2}, ...]

%% Registry count (should equal number of admin API nodes)
syn:registry_count(riak_admin).
%% => 3

%% Verify metadata completeness
{_Pid, Meta} = syn:lookup(riak_admin, {api_node, node()}).
maps:keys(Meta).
%% => [dc, http_port, node, riak_http, riak_vsn, started_at]
```

### Log Messages

All admin API log messages use the `[riak_admin]` prefix. Key
messages to watch for:

| Message | Level | Meaning |
|---------|-------|---------|
| `API started on port N` | info | Cowboy listener is up |
| `Coordinator registered (dc=..., port=..., node=...)` | info | syn registration successful |
| `Discovered admin API on Node (dc=...)` | info | Another node joined |
| `Admin API on Node stopped cleanly` | info | Clean shutdown |
| `DC X node Y unreachable` | warning | Network partition or node down |
| `Registry key taken, unregistering and retrying` | warning | Crash recovery in progress |
| `Registry conflict on Key resolved` | notice | Netsplit healed, conflict resolved |
| `Coordinator terminating` | info | Process shutting down |

### Cowboy Listener Cleanup

If the supervisor fails during startup, the Cowboy listener is
explicitly stopped to free the port:

```erlang
case riak_admin_api_sup:start_link() of
    {ok, SupPid} -> {ok, SupPid};
    {error, Reason} ->
        cowboy:stop_listener(riak_admin_http),
        {error, Reason}
end
```

This is necessary because OTP does NOT call `stop/1` when `start/2`
fails. Without this cleanup, the port would remain bound and the
next startup attempt would fail with `eaddrinuse`.

---

## Troubleshooting

### "API failed to start on port N: eaddrinuse"

The port is already in use. Check for a zombie Cowboy listener or
another process on the same port:

```bash
lsof -i :8099
```

### Coordinator not appearing in syn

1. Check that syn scope is initialized:
   ```erlang
   syn:registry_count(riak_admin).
   ```
   If this crashes with `badarg`, the scope was not initialized.
   Check that `riak_admin_api_app:start/2` calls
   `syn:add_node_to_scopes([riak_admin])`.

2. Check that the event handler is configured:
   ```erlang
   application:get_env(syn, event_handler).
   ```
   Should return `{ok, riak_admin_event_handler}`.

3. Check coordinator process status:
   ```erlang
   whereis(riak_admin_api_coordinator).
   sys:get_state(riak_admin_api_coordinator).
   ```

### Nodes not discovering each other

syn requires distributed Erlang connectivity. Verify:

```erlang
net_adm:ping('dev2@127.0.0.1').
%% => pong (connected) or pang (not connected)

nodes().
%% Should list all expected cluster nodes
```

### Wrong ports in /api/dcs response

If devrel nodes show port 8099 instead of 100N5, the port env
writeback is not happening. Check that `riak_admin_api_app:start/2`
calls `application:set_env` after resolving ports.

### Coordinator restart loop

If you see repeated "Registry key taken" warnings followed by
supervisor shutdown, the stale-key retry may be failing. This
should be rare. Check:

```erlang
syn:lookup(riak_admin, {api_node, node()}).
```

If it returns a PID that is not alive, syn has a stale entry.
Manual cleanup:

```erlang
syn:unregister(riak_admin, {api_node, node()}).
```

Then restart the coordinator:

```erlang
supervisor:restart_child(riak_admin_api_sup, riak_admin_api_coordinator).
```

---

## API Reference

### GET /api/dcs

Returns all known datacenters discovered via syn.

**Response:**

```json
{
  "dcs": [
    {
      "name": "default",
      "local": true,
      "admin_url": "http://127.0.0.1:10015",
      "riak_url": "http://127.0.0.1:10018",
      "riak_version": "3.2.0",
      "node": "dev1@127.0.0.1",
      "reachable": true,
      "started_at": 1707900000
    }
  ],
  "count": 1
}
```

**Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | Datacenter name |
| `local` | boolean | Whether this DC matches the responding node's DC |
| `admin_url` | string | Full URL to the admin API on this DC |
| `riak_url` | string | Full URL to the Riak HTTP API on this DC |
| `riak_version` | string | Riak version running on the representative node |
| `node` | string | Erlang node name of the representative node |
| `reachable` | boolean | Always `true` (syn members are reachable) |
| `started_at` | integer | Unix timestamp (seconds) when the coordinator started |

### GET /api/cluster/status (syn additions)

Two new fields are appended to the existing cluster status response:

| Field | Type | Description |
|-------|------|-------------|
| `remote_dcs` | `[dc_info]` | List of remote DC entries (same shape as `/api/dcs` entries) |
| `total_dcs` | integer | Total DC count (remote + 1 for local) |

`remote_dcs` gracefully degrades to `[]` on any syn failure, so the
cluster status endpoint never breaks due to syn issues.

---

## Design Decisions and Tradeoffs

### 1. Single scope vs. multiple scopes

**Decision:** One scope (`riak_admin`) for all admin API concerns.

**Rationale:** Multiple scopes add complexity. The admin API is a
single subsystem. If we later add monitoring for search (Yokozuna)
or strong consistency (ensemble), those would justify separate scopes.

### 2. Coordinator GenServer vs. plain registration

**Decision:** A dedicated GenServer owns the syn registration.

**Rationale:** syn automatically unregisters a process when it dies.
By tying the registration to a supervised GenServer, we get automatic
cleanup on crash and automatic re-registration on restart. If we
registered from `start/2` directly, there would be no process to
monitor and no automatic cleanup.

### 3. Oldest wins vs. newest wins

**Decision:** Oldest process (lowest `started_at`) wins conflicts.

**Rationale:** The "oldest" process is the one that was running before
the partition. The "newest" is the emergency replacement that started
during the partition. Keeping the original is safer -- it has the
longest uptime and established connections.

### 4. timer:sleep(100) in crash recovery

**Decision:** A 100ms sleep before retrying registration after a
failed unregister.

**Rationale:** This is a pragmatic choice. syn's internal state
converges asynchronously after a DOWN signal. 100ms is enough for
local ETS operations but not so long that it delays startup
noticeably. A more sophisticated approach (polling with backoff)
would add complexity for a rare edge case.

### 5. reachable field always true

**Decision:** `dc_info().reachable` is always `true` for syn members.

**Rationale:** If a node is in syn's member list, it's reachable by
definition (syn removes unreachable nodes). The field exists for
forward compatibility -- future implementations might check
additional health signals beyond syn membership.

### 6. Deduplication by DC name

**Decision:** `/api/dcs` returns one entry per DC, not one per node.

**Rationale:** For dashboard rendering, you want "how many DCs exist?"
not "how many admin API processes exist?" If a DC has 5 nodes, they
all report the same DC name, version, and URLs (behind a load
balancer). Showing 5 identical entries would confuse operators.

### 7. syn event handler term() vs map() specs

**Decision:** Event handler callbacks use `term()` for the Meta
parameter, not `map()`.

**Rationale:** syn's callback spec declares Meta as `term()`. While
our coordinator always registers with a map, conflict resolution
receives metadata from remote nodes that may have been corrupted or
registered with non-map values. Using `term()` with a `case is_map`
check is defensive and matches what syn actually sends.

---

## Future Work

### M7: KV Data Operations

The admin API will add CRUD endpoints for bucket types and KV
operations. These will go through the gateway module and won't
interact with syn.

### M8: WebSocket Event Streaming

The `cluster_events` group is already in place. M8 will add a
WebSocket handler (`rah_events_ws`) that subscribes to the group
and pushes events to connected clients in real-time.

### Multi-DC Health Monitoring

Currently, `reachable` is always `true` for syn members. Future work
could add active health checks (HTTP pings to `admin_url`) to detect
nodes that are in syn but have a degraded admin API.

### Scope Expansion

If Riak adds more subsystems that need distributed discovery (e.g.,
search cluster coordination), each should use its own syn scope to
avoid namespace collisions.
