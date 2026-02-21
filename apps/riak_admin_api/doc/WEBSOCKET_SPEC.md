# WebSocket Event Streaming (M8)

Implementation documentation for real-time event streaming over WebSocket.
This document describes the completed M8 implementation as built.

## The problem

Every dashboard endpoint (cluster status, ring ownership, node stats,
handoff, AAE) requires HTTP polling. A Phoenix LiveView app running
`Process.send_after` at 5-10 second intervals wastes bandwidth, adds
latency, and cannot react to events between polls. Ring ownership changes,
node departures, and handoff completions all happen at unpredictable times.

The goal: one WebSocket connection per browser tab, topic-based
subscriptions, server-push on state changes. The ring visualization updates
the moment a partition moves. Node stats stream as they're sampled. Handoff
progress ticks forward without refreshing.

## Architecture overview

See [diagrams/websocket-event-flow.excalidraw](diagrams/websocket-event-flow.excalidraw) for a visual overview of the event flow from sources through the bridge to WebSocket clients.

```
Browser
  |
  | WebSocket (ws://riak1:8099/api/stream/events)
  |
  v
rah_events_ws (cowboy_websocket handler)
  |  joins syn cluster_events group on connect
  |  receives {event_frame, Topic, PreEncodedJSON}
  |  forwards matching frames as binary (no re-encoding)
  |
  v
riak_admin_api_event_bridge (gen_server)
  |
  |-- subscribes to riak_core_ring_events (push)
  |-- subscribes to riak_core_node_watcher_events (push)
  |-- runs timers for poll-based data (stats, handoff, AAE)
  |-- encodes each event once as JSON
  |-- publishes pre-encoded frames via syn:local_publish/3
  |   to cluster_events group (local node only)
```

Two modules:

1. **rah_events_ws** -- cowboy_websocket handler, one per client connection.
   Joins the `cluster_events` syn group on connect. Forwards pre-encoded
   event frames to the client without re-encoding.
2. **riak_admin_api_event_bridge** -- gen_server. Single source of truth
   for event data. Subscribes to riak_core events, polls timer-based data,
   encodes JSON once, and publishes to `cluster_events` via
   `syn:local_publish/3`. `local_publish` only reaches processes on the
   same Erlang node, so there is no cross-node fan-out of raw frames.

The coordinator is not involved in event streaming. It handles node
discovery only (registry + `api_nodes` group).

## Event sources

### Push-based (event-driven, zero-latency)

| Source | Subscribe API | Event shape | WebSocket topic |
|--------|--------------|-------------|-----------------|
| riak_core_ring_events | `add_sup_callback(fun(Ring) -> ... end)` | Full Ring object on any ring change | `ring`, `cluster` |
| riak_core_node_watcher_events | `add_sup_callback(fun(Services) -> ... end)` | List of available services when nodes join/leave | `membership` |
| syn api_nodes group | `on_process_joined/5`, `on_process_left/5` in event handler | Join/leave with coordinator metadata | `dcs`, `membership` |

### Poll-based (timer-sampled)

| Source | Call | Default interval | WebSocket topic |
|--------|------|-----------------|-----------------|
| `riak_kv_status:statistics()` | Per-node stats | 10s | `node_stats` |
| `riak_core_handoff_manager:status/0` | Transfer list | 15s | `handoff` |
| `riak_kv_entropy_info:compute_exchange_info/0` | Exchange list | 30s | `aae` |

Poll intervals are configurable via application env. The bridge only
publishes when data has changed (diff detection), so quiet clusters don't
generate noise.

## WebSocket topics

### `ring` -- partition ownership

Fires on ring changes. The ring_events callback casts a lightweight
`ring_changed` atom to the bridge (not the full Ring term). The bridge
then fetches the ring from `riak_core_ring_manager:get_my_ring/0`.

```json
{
  "type": "event",
  "topic": "ring",
  "node": "dev1@127.0.0.1",
  "data": {
    "num_partitions": 64,
    "partitions": [
      {"index": 0, "hash": 0, "node": "dev1@127.0.0.1"},
      {"index": 1, "hash": "22835963083295358096932575511191922182123945984", "node": "dev2@127.0.0.1"}
    ],
    "node_colors": {"dev1@127.0.0.1": 0, "dev2@127.0.0.1": 1}
  },
  "timestamp": 1700000000
}
```

This is the full ownership snapshot. State diffing happens client-side --
the server sends the complete partition map because ring changes are
infrequent (seconds to minutes apart) and the payload is small relative
to WebSocket capacity.

### `cluster` -- membership and readiness

Also fires on `{ring_update, Ring}`. Extracted from the same Ring object
but delivered as a separate topic so clients can subscribe to membership
without receiving the full partition list.

```json
{
  "type": "event",
  "topic": "cluster",
  "node": "dev1@127.0.0.1",
  "data": {
    "cluster_name": "default",
    "ring_size": 64,
    "claimant": "dev1@127.0.0.1",
    "ready": true,
    "nodes": [
      {"name": "dev1@127.0.0.1", "status": "valid", "ring_pct": 33.33, "reachable": true},
      {"name": "dev2@127.0.0.1", "status": "valid", "ring_pct": 33.33, "reachable": true}
    ],
    "pending_changes": []
  },
  "timestamp": 1700000000
}
```

### `membership` -- node join/leave events

Fires on `riak_core_node_watcher_events` service updates and syn
api_nodes group changes. Lightweight event for connection status
indicators.

```json
{
  "type": "event",
  "topic": "membership",
  "node": "dev1@127.0.0.1",
  "data": {
    "event": "node_up",
    "target_node": "dev3@127.0.0.1",
    "services": ["riak_kv", "riak_pipe"]
  },
  "timestamp": 1700000000
}
```

Event types: `node_up`, `node_down`, `service_up`, `service_down`.

### `node_stats` -- per-node metrics

Timer-polled. The bridge collects stats from all cluster members via the
same `rpc:call` path as `riak_admin_api_riak:node_stats/1`.

```json
{
  "type": "event",
  "topic": "node_stats",
  "node": "dev1@127.0.0.1",
  "data": {
    "dev1@127.0.0.1": {
      "erlang": {
        "otp_release": "26",
        "process_count": 2048,
        "memory_total_mb": 512,
        "memory_ets_mb": 64,
        "run_queue": 0
      },
      "kv": {
        "vnode_gets": 15000,
        "vnode_puts": 8000,
        "node_gets": 12000,
        "node_puts": 7000,
        "read_repairs": 42,
        "node_get_fsm_time_mean": 1500,
        "node_put_fsm_time_mean": 2000
      }
    }
  },
  "timestamp": 1700000000
}
```

When multiple nodes are in the cluster, each poll cycle publishes one
event containing stats for all nodes. This lets the client update the
entire dashboard in a single frame rather than N separate events.

### `handoff` -- transfer progress

Timer-polled from `riak_core_handoff_manager:status/0`.

```json
{
  "type": "event",
  "topic": "handoff",
  "node": "dev1@127.0.0.1",
  "data": {
    "active_transfers": [
      {"raw": "{status_v2, ...}"}
    ],
    "count": 1
  },
  "timestamp": 1700000000
}
```

### `aae` -- anti-entropy exchange status

Timer-polled from `riak_kv_entropy_info:compute_exchange_info/0`.

```json
{
  "type": "event",
  "topic": "aae",
  "node": "dev1@127.0.0.1",
  "data": {
    "exchanges": [
      {"raw": "{exchange_info, ...}"}
    ],
    "count": 0
  },
  "timestamp": 1700000000
}
```

### `dcs` -- datacenter discovery

Fires on syn api_nodes group join/leave events.

```json
{
  "type": "event",
  "topic": "dcs",
  "node": "dev1@127.0.0.1",
  "data": {
    "dcs": [
      {
        "name": "us-east",
        "local": true,
        "admin_url": "http://10.0.1.10:8099",
        "riak_url": "http://10.0.1.10:8098",
        "riak_version": "3.4.0",
        "node": "riak1@10.0.1.10"
      }
    ],
    "count": 1
  },
  "timestamp": 1700000000
}
```

## Client protocol

### Connection

```
GET /api/stream/events HTTP/1.1
Upgrade: websocket
Connection: Upgrade
```

On successful upgrade, the server sends a `connected` frame:

```json
{
  "type": "connected",
  "node": "dev1@127.0.0.1",
  "topics": ["ring", "cluster", "membership", "node_stats", "handoff", "aae", "dcs"],
  "live": true,
  "timestamp": 1700000000
}
```

The `live` field indicates whether the handler successfully joined
the syn `cluster_events` group. If `true`, the handler receives
real-time events from the bridge. If `false` (syn not initialized or
join failed), the connection is open but no events will arrive. The
client can still request snapshots via subscribe.

New connections start with no subscriptions. Clients must explicitly
subscribe to the topics they need. A dashboard that only shows the
ring chart should not receive node stats traffic.

### Subscribe

```json
{"action": "subscribe", "topics": ["ring", "cluster", "node_stats"]}
```

Response:

```json
{"type": "subscribed", "topics": ["ring", "cluster", "node_stats"]}
```

Duplicate topics in the `topics` array are deduplicated before
processing. Sending `["ring", "ring", "ring"]` is equivalent to
`["ring"]`. This prevents redundant snapshot delivery.

On subscribe, the server pushes the current snapshot for each genuinely
new topic. Re-subscribing to an already-active topic is idempotent and
does not trigger a redundant snapshot. Snapshot frames use a different
type:

```json
{
  "type": "snapshot",
  "topic": "ring",
  "node": "dev1@127.0.0.1",
  "data": { ... },
  "timestamp": 1700000000
}
```

Invalid topics (not in the `available_topics` list) are silently
filtered out. Only valid topics appear in the ack and trigger
snapshots.

**Rate limiting:** If a client sends subscribe faster than
`ws_subscribe_min_interval` (default 1000ms), the server returns a
`rate_limited` error and the subscription list is unchanged.

### Unsubscribe

```json
{"action": "unsubscribe", "topics": ["node_stats"]}
```

Response:

```json
{"type": "unsubscribed", "topics": ["node_stats"]}
```

### Ping/keepalive

The server sends a WebSocket ping frame every 30 seconds. Cowboy handles
pong responses automatically. If no pong arrives within `idle_timeout`
(default 300s), the connection closes.

Clients can also send:

```json
{"action": "ping"}
```

Response:

```json
{"type": "pong", "timestamp": 1700000000}
```

### Backpressure frames

When the handler's Erlang message queue exceeds `ws_backpressure_limit`
(default 100), incoming events are dropped and replaced with:

```json
{
  "type": "backpressure",
  "message_queue_len": 142,
  "dropped_topic": "node_stats",
  "timestamp": 1700000000
}
```

This prevents memory exhaustion from slow clients. The client should
treat this as a signal to reduce its subscription scope or reconnect.

### Error frames

```json
{
  "type": "error",
  "code": "invalid_message",
  "reason": "Message must be a JSON object with an 'action' field"
}
```

Error reasons that include client-supplied values are sanitized: truncated
to 64 bytes and stripped of non-alphanumeric characters (only `a-z`,
`A-Z`, `0-9`, `_`, `-` survive). This prevents XSS if a dashboard
renders error reasons as HTML.

Error codes:

| Code | When |
|------|------|
| `invalid_message` | Unparseable JSON, not a JSON object, or `subscribe`/`unsubscribe` sent without a `topics` field |
| `unknown_action` | Action field is not a recognized verb |
| `invalid_topics` | `topics` field is present but is not a JSON array of strings |
| `rate_limited` | Subscribe sent too soon after the previous one (see `ws_subscribe_min_interval`) |
| `internal_error` | Dispatch crashed (try/catch caught it, connection stays open) |

## Module specifications

### rah_events_ws.erl

```erlang
-module(rah_events_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

%% State: #{subscriptions => [binary()],
%%          last_subscribe_ts => integer() | undefined}
```

**init/2** -- Run security checks via a local `check_security/1` helper.
This calls `riak_admin_api_request:normalize_headers/1` and then
`riak_admin_api_request:ensure_security/2` directly. It does not go
through the full `normalize_request` pipeline, which means cutover
keys (used for rolling deploys of request normalization) do not apply
to WebSocket connections.

On success, upgrades to WebSocket with configurable options:
`#{idle_timeout => ws_idle_timeout (default 300000), max_frame_size => ws_max_frame_size (default 65536)}`.
On failure, returns an HTTP error (no upgrade).

**websocket_init/1** -- Joins the syn `cluster_events` group via
`join_events_group/0`. Returns `true` on success, `false` on failure
(e.g. syn not initialized). The boolean is included as the `live` field
in the `connected` frame sent to the client.

**websocket_handle/2** -- Parses JSON text frames. Dispatches on
`action` inside a try/catch wrapper. If `dispatch_action` crashes, the
handler returns an `internal_error` frame and keeps the connection open.

Actions:
- `subscribe` -- validates topics against `available_topics/0`, filters
  out unknowns, adds to subscription list, pushes snapshot for each
  genuinely new topic (re-subscribing is idempotent and skips the
  snapshot). Rate-limited: if called within `ws_subscribe_min_interval`
  (default 1000ms) of the last subscribe, returns a `rate_limited` error.
  If the `topics` field is missing entirely, returns `invalid_message`.
- `unsubscribe` -- removes topics from state. If the `topics` field is
  missing entirely, returns `invalid_message`.
- `ping` -- responds with `pong` + timestamp.
- Non-array `topics` -- returns `invalid_topics` error.
- Unknown action -- returns `unknown_action` error (the reflected
  action value is sanitized to alphanumeric characters only).
- Missing action -- returns `invalid_message` error.

**websocket_info/2** -- Receives `{event_frame, Topic, Frame}` from the
bridge via syn. `Frame` is a pre-encoded JSON binary. If `Topic` is in
the client's subscription list, the binary is forwarded directly as a
text frame — no JSON decoding or re-encoding. If the topic is not
subscribed, the message is dropped silently.

Backpressure: before forwarding, checks `process_info(self(),
message_queue_len)`. If the queue exceeds `ws_backpressure_limit`
(default 100), the event is dropped and a `backpressure` warning frame
is sent instead, including the queue length and the dropped topic.

**terminate/3** -- No-op. syn automatically removes the process from the
group on exit.

### riak_admin_api_event_bridge.erl

```erlang
-module(riak_admin_api_event_bridge).
-behaviour(gen_server).

-export([start_link/0, get_snapshot/1, available_topics/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).
```

**Available topics:** `ring`, `cluster`, `membership`, `node_stats`,
`handoff`, `aae`, `dcs`. Returned by `available_topics/0` as a list
of binaries.

**init/1** -- Subscribes to push-based event sources. The ring_events
callback casts a lightweight `ring_changed` atom (not the full Ring
term) to avoid copying a multi-megabyte Ring record into the gen_server
mailbox on every ring event:

```erlang
riak_core_ring_events:add_sup_callback(fun(_Ring) ->
    gen_server:cast(?MODULE, ring_changed)
end),
riak_core_node_watcher_events:add_sup_callback(fun(Services) ->
    gen_server:cast(?MODULE, {service_update, Services})
end),
```

Starts poll timers for timer-based data sources.

State: `#{snapshots => map(), last_services => list() | undefined, stats_collecting => boolean(), stats_gen => non_neg_integer()}`.

**handle_cast(ring_changed)** -- Fetches the ring from
`riak_core_ring_manager:get_my_ring/0` (inside the gen_server, not the
callback). Extracts ring data and cluster data. Publishes both `ring`
and `cluster` topics.

**handle_cast({service_update, Services})** -- Diffs the new service
list against the previous one. Produces `service_up`/`service_down`
events. Publishes the `membership` topic only when the diff is non-empty.

**handle_cast({dc_change, DcData})** -- Publishes the `dcs` topic.
Triggered by the syn event handler on api_nodes group join/leave.

**handle_info(poll_node_stats)** -- Starts async stats collection in
a spawned process (using `spawn`, not `spawn_link`, so a crash in
the collector does not take down the bridge). Each node_stats RPC has
a 5s timeout; doing N calls sequentially in the gen_server would block
snapshot reads and event processing. A `stats_collecting` flag prevents
overlapping collections. When the spawned process finishes, it sends
`{stats_collected, Gen, Result}` back, tagged with a generation
counter.

A safety timeout (`stats_collection_timeout`) fires at `2 * bridge_stats_interval`
to reset the collecting flag if the worker dies without sending a result.
The timeout message includes the same generation counter, so stale
timeouts from previous cycles are ignored. Stats results from
timed-out generations are also discarded to prevent overwriting
fresher data from the current generation.

**handle_info(poll_handoff)** / **handle_info(poll_aae)** -- Polls
handoff and AAE status via the gateway module. Same diff-then-publish
pattern.

**Diff detection:** `maybe_publish_changed/3` compares the new data
against the stored snapshot. If identical, the publish is skipped.
Controlled by `bridge_diff_detection` (default `true`).

**Encode-once publishing:** `publish_event/2` encodes the event frame
once as JSON, then publishes the pre-encoded binary:

```erlang
Frame = jsx:encode(#{type => <<"event">>, topic => Topic,
                     node => node(), data => Data,
                     timestamp => erlang:system_time(second)}),
{ok, _Count} = syn:local_publish(?SCOPE, ?GROUP_EVENTS,
                                  {event_frame, Topic, Frame})
```

`syn:local_publish/3` reaches only processes on the local node.
Every WS handler in the `cluster_events` group receives the tuple
`{event_frame, Topic, Frame}` where `Frame` is a ready-to-send
binary. No per-subscriber JSON encoding.

**Snapshot API:**

```erlang
-spec get_snapshot(binary()) -> {ok, map()} | {error, not_available}.
get_snapshot(Topic) ->
    gen_server:call(?MODULE, {get_snapshot, Topic}).
```

Called by `rah_events_ws` when a client subscribes. Returns the latest
stored data for the topic, allowing the dashboard to render immediately
without waiting for the next event cycle. The snapshot frame is encoded
by the WS handler (not the bridge) since it uses a different frame type
(`snapshot` vs `event`).

### Supervisor tree

`riak_admin_api_sup` uses `rest_for_one` strategy with three children
in this order:

1. **riak_admin_http** -- Cowboy listener (ranch child spec)
2. **riak_admin_api_event_bridge** -- event bridge
3. **riak_admin_api_coordinator** -- syn registration

`rest_for_one` means a bridge crash also restarts the coordinator.
The listener is independent.

### Route

```erlang
{"/api/stream/events", rah_events_ws, []}
```

Defined in `riak_admin_api_app:admin_routes/0`.

## Configuration

All tunables in application env (`riak_admin_api`):

| Key | Default | Description |
|-----|---------|-------------|
| `ws_idle_timeout` | 300000 | WebSocket idle timeout (ms). Connection closes if no activity. |
| `ws_max_frame_size` | 65536 | Max incoming frame size (bytes) |
| `ws_backpressure_limit` | 100 | Message queue length before dropping events |
| `ws_subscribe_min_interval` | 1000 | Minimum time (ms) between subscribe actions per connection |
| `bridge_stats_interval` | 10000 | Node stats poll interval (ms) |
| `bridge_handoff_interval` | 15000 | Handoff status poll interval (ms) |
| `bridge_aae_interval` | 30000 | AAE status poll interval (ms) |
| `bridge_diff_detection` | true | Only publish when data changes |

## Security

The WebSocket handler runs its own `check_security/1` in `init/2`
before the protocol upgrade. It calls
`riak_admin_api_request:normalize_headers/1` to extract standard
header metadata, then calls `riak_admin_api_request:ensure_security/2`
with a fixed context (`method => <<"UPGRADE">>`, `route => <<"/api/stream/events">>`,
`op => admin`).

Because the method is `UPGRADE` (not `GET`), origin validation treats
WebSocket upgrades as unsafe methods -- if `security_trusted_origins`
is configured, the `Origin` header must be present and match a trusted
origin.

Checks enforced:

1. TLS enforcement (`security_require_tls`)
2. Origin validation (`security_trusted_origins`) -- uses method `UPGRADE` for the origin check, so Origin header is required when trusted_origins is configured
3. Authentication (`authn_hook`)
4. Authorization (`authz_hook`)

Failed auth returns a normal HTTP error response (no upgrade).

**Note:** The WS handler does not go through the full
`normalize_request` pipeline used by REST handlers. It calls
`ensure_security` directly. This means cutover keys (used for rolling
deploys of request normalization changes) do not apply to WebSocket
connections. If you add request normalization logic that must also
cover WebSocket, update `check_security/1` in `rah_events_ws`.

## Module files

| File | Role |
|------|------|
| `src/riak_admin_api_event_bridge.erl` | Event bridge gen_server |
| `src/handlers/rah_events_ws.erl` | WebSocket handler |
| `src/riak_admin_api_sup.erl` | Supervisor (bridge added as child) |
| `src/riak_admin_api_app.erl` | Route: `/api/stream/events` |
| `src/riak_admin_event_handler.erl` | Forwards DC join/leave to bridge |

## Testing strategy

### Unit tests (eunit)

- Event bridge publishes correct topic when receiving ring_update cast
- Event bridge detects diffs and skips publish when data is unchanged
- Event bridge returns snapshot for subscribed topics
- WebSocket handler adds/removes topics on subscribe/unsubscribe
- WebSocket handler drops events for non-subscribed topics
- WebSocket handler sends backpressure warning when queue is full
- Security rejection returns HTTP 401 before upgrade

### Integration tests (common_test)

- Start a Cowboy listener with the WS route
- Connect via gun (Erlang HTTP/WS client)
- Subscribe to a topic, verify snapshot arrives
- Simulate a ring_update, verify event arrives on the WS connection
- Verify unsubscribed topics don't arrive
- Verify idle_timeout disconnects inactive clients
- Verify backpressure under load (send events faster than client reads)

### Manual verification

- Connect with websocat: `websocat ws://localhost:8099/api/stream/events`
- Send `{"action": "subscribe", "topics": ["ring", "cluster"]}`
- Join/leave a node and watch events arrive
- Use the Phoenix LiveView dashboard (see LIVEVIEW_INTEGRATION.md) to
  verify real-time updates

## Phoenix LiveView consumption

See the updated "WebSocket consumption" section in
`doc/LIVEVIEW_INTEGRATION.md` for the full pattern. The short version:

```javascript
// assets/js/hooks/riak_events.js
const RiakEvents = {
  mounted() {
    const url = this.el.dataset.wsUrl;
    const topics = JSON.parse(this.el.dataset.topics || '["cluster","ring"]');
    this.connect(url, topics);
  },

  connect(url, topics) {
    this.ws = new WebSocket(url);

    this.ws.onopen = () => {
      this.ws.send(JSON.stringify({action: "subscribe", topics: topics}));
      this.pushEvent("ws_connected", {});
    };

    this.ws.onmessage = (evt) => {
      const msg = JSON.parse(evt.data);
      if (msg.type === "event") {
        this.pushEvent("riak_" + msg.topic, msg.data);
      }
    };

    this.ws.onclose = () => {
      this.pushEvent("ws_disconnected", {});
      this.scheduleReconnect(url, topics);
    };
  },

  scheduleReconnect(url, topics) {
    const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts || 0), 30000);
    this.reconnectAttempts = (this.reconnectAttempts || 0) + 1;
    setTimeout(() => this.connect(url, topics), delay);
  },

  destroyed() { if (this.ws) this.ws.close(); }
};

export default RiakEvents;
```

```elixir
defmodule MyAppWeb.ClusterDashboardLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket,
      ws_connected: false,
      cluster: nil,
      ring: nil,
      node_stats: %{},
      handoff: nil
    )}
  end

  # Ring ownership pushed from WS
  def handle_event("riak_ring", data, socket) do
    {:noreply, assign(socket, ring: data)}
  end

  # Cluster status pushed from WS
  def handle_event("riak_cluster", data, socket) do
    {:noreply, assign(socket, cluster: data)}
  end

  # Node stats pushed from WS
  def handle_event("riak_node_stats", data, socket) do
    {:noreply, assign(socket, node_stats: data)}
  end

  def handle_event("ws_connected", _, socket) do
    {:noreply, assign(socket, ws_connected: true)}
  end

  def handle_event("ws_disconnected", _, socket) do
    {:noreply, assign(socket, ws_connected: false)}
  end
end
```

No more `Process.send_after`. No more polling. The ring chart redraws
the instant a partition moves.
