# Phoenix LiveView Integration Guide

Consuming the Riak Admin API from a Phoenix LiveView application.

## Overview

The `riak_admin_api` exposes a JSON-over-HTTP interface for cluster
administration, monitoring, and data operations. It runs on Cowboy (default
port 8099), separate from Riak's data-path HTTP interface (port 8098).

A Phoenix LiveView application consumes this API over standard HTTP. The
architecture looks like this:

```
Browser  <--WebSocket-->  Phoenix LiveView  <--HTTP/JSON-->  Cowboy (8099)  -->  Riak
                          (your app)                         (riak_admin_api)
```

Direct Erlang calls into Riak internals are not recommended. The admin API
enforces an isolation boundary: all access flows through
`riak_admin_api_riak.erl`, the single gateway module that touches
`riak_core` and `riak_kv`. This boundary exists so that:

- Admin traffic is isolated from KV data operations.
- The admin API can be firewalled independently.
- Handlers are testable without a running Riak node.
- The Cowboy stack can evolve without coupling to Riak internals.

Your LiveView app should treat the admin API as an external HTTP service.

## CORS Configuration

### When CORS is needed

CORS headers are required when your Phoenix app is served from a different
origin than the Riak admin API. For example, if Phoenix runs at
`http://dashboard.internal:4000` and the admin API runs at
`http://riak1.internal:8099`, the browser will enforce same-origin policy
on fetch requests from LiveView hooks.

### Configuring trusted_origins

Set `security_trusted_origins` in the Riak admin API application environment.
In `riak.conf` or the `riak_admin_api` app config:

```erlang
[
  {riak_admin_api, [
    {security_trusted_origins, [
      <<"http://dashboard.internal:4000">>,
      <<"https://admin.example.com">>
    ]}
  ]}
].
```

When a request arrives with an `Origin` header matching one of these values,
the response includes:

```
Access-Control-Allow-Origin: <matched origin>
Access-Control-Allow-Methods: GET, HEAD, PUT, POST, DELETE, OPTIONS
Access-Control-Allow-Headers: Content-Type, X-Request-Id, X-Riak-Vclock, ...
Access-Control-Expose-Headers: X-Request-Id, X-Riak-Vclock, ETag, ...
Access-Control-Max-Age: 3600
```

If `security_trusted_origins` is empty (the default), no CORS headers are
emitted and the existing security model is preserved.

### When CORS is not needed

If your Phoenix app proxies requests to the admin API (same origin), CORS
is unnecessary. A typical setup uses a Phoenix plug or a reverse proxy
(nginx, Caddy) to forward `/api/*` to the Cowboy listener:

```elixir
# In your Phoenix router
forward "/riak-admin", RiakAdminProxy
```

This avoids CORS entirely and keeps the admin API behind your Phoenix
authentication layer.

## Endpoint Consumption Guide

### HTTP Client Setup

Use `Req` or `Finch` as your HTTP client. Here is a reusable client module:

```elixir
defmodule MyApp.RiakAdmin do
  @moduledoc """
  HTTP client for the Riak Admin API.
  """

  @base_url Application.compile_env(:my_app, :riak_admin_url, "http://localhost:8099")

  def get(path, opts \\ []) do
    url = @base_url <> path
    timeout = Keyword.get(opts, :timeout, 5_000)

    case Req.get(url, receive_timeout: timeout) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, %{status: nil, reason: reason}}
    end
  end

  def post(path, body, opts \\ []) do
    url = @base_url <> path
    timeout = Keyword.get(opts, :timeout, 10_000)

    case Req.post(url,
           json: body,
           receive_timeout: timeout,
           headers: [{"content-type", "application/json"}]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, %{status: nil, reason: reason}}
    end
  end

  def put(path, body, opts \\ []) do
    url = @base_url <> path
    timeout = Keyword.get(opts, :timeout, 10_000)

    case Req.put(url,
           body: body,
           receive_timeout: timeout,
           headers: [{"content-type", "application/json"}]
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, %{status: nil, reason: reason}}
    end
  end

  def delete(path, opts \\ []) do
    url = @base_url <> path
    timeout = Keyword.get(opts, :timeout, 5_000)

    case Req.delete(url, receive_timeout: timeout) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, reason} ->
        {:error, %{status: nil, reason: reason}}
    end
  end
end
```

### Cluster Dashboard

#### GET /api/ping -- Health Indicator

Returns the health status of the node the request hits.

**Response shape:**

```json
{
  "status": "ok",
  "node": "dev1@127.0.0.1"
}
```

**Recommended polling interval:** 5 seconds.

**LiveView pattern:**

```elixir
defmodule MyAppWeb.ClusterLive do
  use MyAppWeb, :live_view

  @ping_interval :timer.seconds(5)

  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_ping()

    {:ok,
     assign(socket,
       ping_status: :unknown,
       ping_node: nil
     )}
  end

  def handle_info(:ping, socket) do
    schedule_ping()

    case MyApp.RiakAdmin.get("/api/ping") do
      {:ok, %{"status" => "ok", "node" => node}} ->
        {:noreply, assign(socket, ping_status: :ok, ping_node: node)}

      _ ->
        {:noreply, assign(socket, ping_status: :error)}
    end
  end

  defp schedule_ping, do: Process.send_after(self(), :ping, @ping_interval)
end
```

**Rendering:**

```heex
<div class={[
  "inline-flex items-center gap-2 px-3 py-1 rounded-full text-sm",
  @ping_status == :ok && "bg-green-100 text-green-800",
  @ping_status == :error && "bg-red-100 text-red-800",
  @ping_status == :unknown && "bg-gray-100 text-gray-800"
]}>
  <span class={[
    "w-2 h-2 rounded-full",
    @ping_status == :ok && "bg-green-500",
    @ping_status == :error && "bg-red-500",
    @ping_status == :unknown && "bg-gray-400"
  ]} />
  <%= case @ping_status do %>
    <% :ok -> %>Connected to <%= @ping_node %>
    <% :error -> %>Unreachable
    <% :unknown -> %>Checking...
  <% end %>
</div>
```

#### GET /api/cluster/status -- Membership Ring

Returns full cluster membership, node reachability, ring distribution, and
pending changes.

**Response shape:**

```json
{
  "cluster_name": "default",
  "ring_size": 64,
  "claimant": "dev1@127.0.0.1",
  "ready": true,
  "nodes": [
    {
      "name": "dev1@127.0.0.1",
      "status": "valid",
      "ring_pct": 33.33,
      "reachable": true
    },
    {
      "name": "dev2@127.0.0.1",
      "status": "valid",
      "ring_pct": 33.33,
      "reachable": true
    }
  ],
  "pending_changes": [],
  "remote_dcs": [
    {
      "name": "us-west",
      "local": false,
      "admin_url": "http://10.0.2.10:8099",
      "riak_url": "http://10.0.2.10:8098",
      "riak_version": "3.4.0",
      "node": "riak1@10.0.2.10",
      "reachable": true,
      "started_at": 1700000000
    }
  ],
  "total_dcs": 2
}
```

Node `status` values: `valid`, `leaving`, `exiting`, `joining`, `down`.

**Recommended polling interval:** 10 seconds.

**LiveView pattern:**

```elixir
def handle_info(:refresh_cluster, socket) do
  schedule_refresh()

  case MyApp.RiakAdmin.get("/api/cluster/status") do
    {:ok, data} ->
      {:noreply,
       assign(socket,
         cluster_name: data["cluster_name"],
         ring_size: data["ring_size"],
         claimant: data["claimant"],
         ready: data["ready"],
         nodes: data["nodes"],
         pending_changes: data["pending_changes"],
         remote_dcs: data["remote_dcs"]
       )}

    {:error, _} ->
      {:noreply, assign(socket, cluster_error: true)}
  end
end
```

**Rendering recommendation:** Use a table for node membership. Show a green
check or red X for reachability. Display `ring_pct` as a horizontal bar or
in a donut chart. Show a warning banner when `ready` is `false`.

#### GET /api/ring/ownership -- Partition Distribution

Returns the full partition-to-node mapping for ring visualizations.

**Response shape:**

```json
{
  "num_partitions": 64,
  "partitions": [
    {"index": 0, "hash": 0, "node": "dev1@127.0.0.1"},
    {"index": 1, "hash": 22835963083295358096932575511191922182123945984, "node": "dev2@127.0.0.1"}
  ],
  "node_colors": {
    "dev1@127.0.0.1": 0,
    "dev2@127.0.0.1": 1,
    "dev3@127.0.0.1": 2
  }
}
```

`node_colors` maps each node to a sequential integer for use as a color
index in visualizations.

**Recommended polling interval:** 30 seconds (ring changes are infrequent).

**Rendering recommendation:** Render as a circular ring chart where each
partition is a colored segment. Use `node_colors` to assign consistent
colors. The `hash` field is the position on the 2^160 ring and can be used
for key-to-partition mapping in tooltips.

#### GET /api/dcs -- Datacenter Topology

Returns all known datacenters discovered via syn group membership.

**Response shape:**

```json
{
  "dcs": [
    {
      "name": "us-east",
      "local": true,
      "admin_url": "http://10.0.1.10:8099",
      "riak_url": "http://10.0.1.10:8098",
      "riak_version": "3.4.0",
      "node": "riak1@10.0.1.10",
      "reachable": true,
      "started_at": 1700000000
    },
    {
      "name": "us-west",
      "local": false,
      "admin_url": "http://10.0.2.10:8099",
      "riak_url": "http://10.0.2.10:8098",
      "riak_version": "3.4.0",
      "node": "riak1@10.0.2.10",
      "reachable": true,
      "started_at": 1700000000
    }
  ],
  "count": 2
}
```

**Recommended polling interval:** 60 seconds.

**Rendering recommendation:** Display as a topology map or card layout.
Highlight the local DC. Show `admin_url` as clickable links when running
a multi-DC dashboard. The `riak_version` field is useful for detecting
version drift across DCs.

### Node Monitoring

#### GET /api/nodes/:node/stats -- Per-Node Metrics

Returns Erlang VM stats and riak_kv operational metrics for a specific node.

**Response shape:**

```json
{
  "node": "dev1@127.0.0.1",
  "erlang": {
    "otp_release": "26",
    "process_count": 2048,
    "memory_total_mb": 512,
    "memory_processes_mb": 256,
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
```

**Error responses:**
- 404 `unknown_node` -- node name not recognised (atom does not exist)
- 503 `node_unreachable` -- node exists but RPC timed out (5s)

**Recommended polling interval:** 10 seconds.

**Parallel fetching of multiple node stats:**

Fetch stats for all nodes concurrently using `Task.async_stream`:

```elixir
def fetch_all_node_stats(nodes) do
  nodes
  |> Task.async_stream(
    fn node -> {node, MyApp.RiakAdmin.get("/api/nodes/#{node}/stats")} end,
    max_concurrency: 10,
    timeout: 10_000,
    on_timeout: :kill_task
  )
  |> Enum.reduce(%{}, fn
    {:ok, {node, {:ok, stats}}}, acc -> Map.put(acc, node, stats)
    {:ok, {node, {:error, _}}}, acc -> Map.put(acc, node, :error)
    {:exit, _}, acc -> acc
  end)
end
```

In the LiveView:

```elixir
def handle_info(:refresh_node_stats, socket) do
  schedule_refresh()
  nodes = Enum.map(socket.assigns.nodes, & &1["name"])
  all_stats = fetch_all_node_stats(nodes)
  {:noreply, assign(socket, node_stats: all_stats)}
end
```

**Rendering recommendation:** Show each node as a card with gauges for
memory usage, process count, and run queue. Display KV throughput
(gets/puts) as spark lines or counters. Flag nodes with `run_queue > 0`
or high FSM latencies.

#### GET /api/handoff/status -- Transfer Progress

Returns active handoff transfers (ownership, hinted, repair).

**Response shape:**

```json
{
  "active_transfers": [
    {"raw": "{status_v2, ...}"}
  ],
  "count": 0
}
```

Note: Transfer entries are currently stringified from Erlang tuples (the
`raw` field). As the API matures, these will be structured into typed maps
with fields like `type`, `source_node`, `target_node`, `partition`,
`progress_pct`. For now, parse the `raw` string or display it as-is.

**Recommended polling interval:** 15 seconds (more frequently during
cluster changes).

**Rendering recommendation:** Show a transfer progress table. When `count`
is 0, display "No active transfers" with a green indicator.

#### GET /api/aae/status -- Anti-Entropy Repair Status

Returns active anti-entropy (AAE) hash tree exchanges.

**Response shape:**

```json
{
  "exchanges": [
    {"raw": "{exchange_info, ...}"}
  ],
  "count": 0
}
```

Like handoff, exchange entries use the `raw` stringified format for now.

**Recommended polling interval:** 30 seconds.

**Rendering recommendation:** Show as a table of exchange activities.
AAE status is most useful during diagnostics; consider placing it in an
expandable section rather than the main dashboard.

### Data Operations

The admin API includes a substrate route layer that proxies the full Riak
HTTP API through Cowboy. These routes support bucket operations, key-value
CRUD, counters, CRDTs, MapReduce, and secondary index queries.

#### Object CRUD

**Endpoints:**

| Operation | Method | Path |
|-----------|--------|------|
| Get object | GET | `/buckets/:bucket/keys/:key` or `/types/:type/buckets/:bucket/keys/:key` |
| Put object | PUT | `/buckets/:bucket/keys/:key` or `/types/:type/buckets/:bucket/keys/:key` |
| Create (server-generated key) | POST | `/buckets/:bucket/keys` or `/types/:type/buckets/:bucket/keys` |
| Delete object | DELETE | `/buckets/:bucket/keys/:key` or `/types/:type/buckets/:bucket/keys/:key` |

**Response headers of interest:**
- `X-Riak-Vclock` -- vector clock (pass back on PUT/DELETE for conflict resolution)
- `ETag` -- entity tag for conditional requests
- `Last-Modified` -- last modification timestamp
- `Link` -- Riak link headers
- `Location` -- URI of newly created object (POST)

**LiveView pattern for object editing:**

```elixir
def handle_event("save_object", %{"value" => value}, socket) do
  path = "/types/#{socket.assigns.type}/buckets/#{socket.assigns.bucket}/keys/#{socket.assigns.key}"

  case MyApp.RiakAdmin.put(path, value) do
    {:ok, _} ->
      {:noreply, put_flash(socket, :info, "Object saved")}

    {:error, %{status: 409}} ->
      {:noreply, put_flash(socket, :error, "Conflict -- reload and retry")}

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Save failed")}
  end
end
```

#### Bucket Listing and Key Browsing

**List buckets:**

```
GET /buckets
GET /types/:type/buckets
```

**List keys:**

```
GET /buckets/:bucket/keys?keys=true
GET /buckets/:bucket/keys?keys=stream  (streaming)
GET /types/:type/buckets/:bucket/keys?keys=true
```

**Bucket properties:**

```
GET  /buckets/:bucket/props
PUT  /buckets/:bucket/props    body: {"props": {...}}
DELETE /buckets/:bucket/props  (reset to defaults)
```

**Type properties:**

```
GET /types/:type/props
PUT /types/:type/props    body: {"props": {...}}
```

These are expensive operations in production. Key listing in particular
requires a full scan. In a LiveView admin tool, gate these behind explicit
user action rather than automatic polling.

#### Counter Operations

```
GET  /buckets/:bucket/counters/:key
POST /buckets/:bucket/counters/:key    body: integer delta
```

Query parameters: `r`, `pr`, `w`, `pw`, `dw`, `basic_quorum`,
`notfound_ok`, `node_confirms`, `timeout`, `returnvalue`.

#### CRDT Operations

```
GET  /types/:type/buckets/:bucket/datatypes/:key
POST /types/:type/buckets/:bucket/datatypes/:key     (update)
POST /types/:type/buckets/:bucket/datatypes           (create)
```

Query parameters: `r`, `pr`, `w`, `pw`, `dw`, `rw`, `basic_quorum`,
`notfound_ok`, `node_confirms`, `timeout`, `include_context`, `returnbody`.

#### MapReduce

```
POST /mapred
```

**Request body:**

```json
{
  "inputs": [["bucket", "key1"], ["bucket", "key2"]],
  "query": [
    {"map": {"language": "erlang", "module": "riak_kv_mapreduce", "function": "map_object_value"}},
    {"reduce": {"language": "erlang", "module": "riak_kv_mapreduce", "function": "reduce_count_inputs"}}
  ]
}
```

**Streaming:** Add `?chunked=true` to receive results as chunked
transfer-encoding. The response is a stream of JSON arrays, one per
MapReduce phase result.

**LiveView pattern for MapReduce submission:**

```elixir
def handle_event("run_mapred", %{"query" => query_json}, socket) do
  case Jason.decode(query_json) do
    {:ok, query} ->
      case MyApp.RiakAdmin.post("/mapred", query, timeout: 60_000) do
        {:ok, results} ->
          {:noreply, assign(socket, mapred_results: results)}

        {:error, err} ->
          {:noreply, put_flash(socket, :error, "MapReduce failed: #{inspect(err)}")}
      end

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Invalid JSON")}
  end
end
```

#### Secondary Index Queries

```
GET /buckets/:bucket/index/:field/:term                (exact match)
GET /buckets/:bucket/index/:field/:start/:end          (range)
GET /types/:type/buckets/:bucket/index/:field/:term
GET /types/:type/buckets/:bucket/index/:field/:start/:end
```

Query parameters: `stream`, `max_results`, `continuation`, `return_terms`,
`pagination_sort`, `timeout`, `term_regex`.

Use `max_results` and `continuation` for paginated browsing in a LiveView
table component.

## WebSocket / Live Stats

### Current State

There are currently **no WebSocket endpoints** in the admin API. The
infrastructure for push-based events exists but is not wired to an HTTP
handler:

- The `cluster_events` syn group exists. The coordinator
  (`riak_admin_api_coordinator`) joins it on startup.
- Events are published via `syn:publish(riak_admin, cluster_events,
  {event, Node, Event})`.
- The coordinator forwards `{cluster_event, Event}` messages it receives
  to the group.

What is missing: a Cowboy WebSocket handler that subscribes to the group
and pushes events to connected clients.

### M8 WebSocket Implementation Plan

The following steps are needed to add real-time event streaming:

#### 1. Create rah_events_ws.erl

```erlang
-module(rah_events_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

%% Upgrade HTTP to WebSocket
init(Req, State) ->
    {cowboy_websocket, Req, State, #{idle_timeout => 300000}}.

%% Join the cluster_events group on connection
websocket_init(State) ->
    ok = syn:join(riak_admin, cluster_events, self()),
    Frame = jsx:encode(#{type => <<"connected">>,
                         node => node(),
                         timestamp => erlang:system_time(second)}),
    {[{text, Frame}], State#{subscriptions => [<<"*">>]}}.

%% Handle client messages (subscribe/unsubscribe)
websocket_handle({text, Msg}, State) ->
    case jsx:decode(Msg, [return_maps]) of
        #{<<"action">> := <<"subscribe">>, <<"topic">> := Topic} ->
            Subs = maps:get(subscriptions, State, []),
            {[], State#{subscriptions => [Topic | Subs]}};
        #{<<"action">> := <<"unsubscribe">>, <<"topic">> := Topic} ->
            Subs = maps:get(subscriptions, State, []),
            {[], State#{subscriptions => lists:delete(Topic, Subs)}};
        _ ->
            {[], State}
    end;
websocket_handle(_Frame, State) ->
    {[], State}.

%% Receive events from syn group, encode as JSON, send to client
websocket_info({event, Node, Event}, State) ->
    Subs = maps:get(subscriptions, State, []),
    Topic = event_topic(Event),
    case lists:member(<<"*">>, Subs) orelse lists:member(Topic, Subs) of
        true ->
            Frame = jsx:encode(#{
                type => <<"event">>,
                topic => Topic,
                node => Node,
                data => format_event(Event),
                timestamp => erlang:system_time(second)
            }),
            {[{text, Frame}], State};
        false ->
            {[], State}
    end;
websocket_info(_Info, State) ->
    {[], State}.

terminate(_Reason, _Req, _State) ->
    ok.

%% Internal
event_topic({ring_changed, _}) -> <<"ring">>;
event_topic({node_up, _}) -> <<"membership">>;
event_topic({node_down, _}) -> <<"membership">>;
event_topic({handoff_started, _}) -> <<"handoff">>;
event_topic({handoff_completed, _}) -> <<"handoff">>;
event_topic(_) -> <<"unknown">>.

format_event(Event) when is_map(Event) -> Event;
format_event(Event) -> #{raw => iolist_to_binary(io_lib:format("~p", [Event]))}.
```

#### 2. Add the route

In `riak_admin_api_app:admin_routes/0`:

```erlang
{"/api/stream/events", rah_events_ws, []}
```

#### 3. Recommended frame format

All frames are JSON text frames:

```json
{
  "type": "event",
  "topic": "ring",
  "node": "dev1@127.0.0.1",
  "data": { ... event-specific payload ... },
  "timestamp": 1700000000
}
```

Control frames from client:

```json
{"action": "subscribe", "topic": "membership"}
{"action": "unsubscribe", "topic": "ring"}
```

Topics: `ring`, `membership`, `handoff`, `*` (all).

#### 4. Phoenix LiveView Socket connection

Use a client-side JavaScript hook to manage the WebSocket:

```javascript
// assets/js/hooks/riak_events.js
const RiakEvents = {
  mounted() {
    const url = this.el.dataset.wsUrl || "ws://localhost:8099/api/stream/events";
    this.connect(url);
  },

  connect(url) {
    this.ws = new WebSocket(url);
    this.reconnectAttempts = 0;

    this.ws.onopen = () => {
      this.reconnectAttempts = 0;
      this.pushEvent("ws_connected", {});
    };

    this.ws.onmessage = (event) => {
      const data = JSON.parse(event.data);
      this.pushEvent("riak_event", data);
    };

    this.ws.onclose = () => {
      this.pushEvent("ws_disconnected", {});
      this.scheduleReconnect(url);
    };

    this.ws.onerror = () => {
      this.ws.close();
    };
  },

  scheduleReconnect(url) {
    const delay = Math.min(1000 * Math.pow(2, this.reconnectAttempts), 30000);
    this.reconnectAttempts++;
    setTimeout(() => this.connect(url), delay);
  },

  destroyed() {
    if (this.ws) this.ws.close();
  }
};

export default RiakEvents;
```

LiveView module:

```elixir
def mount(_params, _session, socket) do
  {:ok, assign(socket, events: [], ws_connected: false)}
end

def handle_event("riak_event", event, socket) do
  events = [event | Enum.take(socket.assigns.events, 99)]
  {:noreply, assign(socket, events: events)}
end

def handle_event("ws_connected", _, socket) do
  {:noreply, assign(socket, ws_connected: true)}
end

def handle_event("ws_disconnected", _, socket) do
  {:noreply, assign(socket, ws_connected: false)}
end
```

Template:

```heex
<div id="riak-events"
     phx-hook="RiakEvents"
     data-ws-url={"ws://#{@riak_admin_host}/api/stream/events"}>
</div>
```

#### 5. Reconnection and backpressure

**Reconnection:** The JavaScript hook uses exponential backoff (1s, 2s, 4s,
..., max 30s). The server-side `idle_timeout` is set to 300s (5 minutes).
The client should send periodic ping frames or subscribe/unsubscribe
messages to keep the connection alive.

**Backpressure:** If the client cannot keep up with events, Cowboy will
buffer WebSocket frames in the handler process mailbox. To prevent memory
exhaustion:

- Set a mailbox high-water mark in `websocket_info` and drop events when
  exceeded.
- Use topic-based filtering so clients only receive events they need.
- Consider rate-limiting event emission in the coordinator (e.g., at most
  one ring_changed event per second).

#### 6. Alternative: Server-Sent Events (SSE)

If WebSocket support is not available or desired, Cowboy's `stream_reply`
can serve Server-Sent Events:

```erlang
init(Req0, State) ->
    Req = cowboy_req:stream_reply(200,
        #{<<"content-type">> => <<"text/event-stream">>,
          <<"cache-control">> => <<"no-cache">>},
        Req0),
    ok = syn:join(riak_admin, cluster_events, self()),
    loop(Req, State).

loop(Req, State) ->
    receive
        {event, Node, Event} ->
            Data = jsx:encode(#{node => Node, event => Event}),
            cowboy_req:stream_body(
                <<"data: ", Data/binary, "\n\n">>, nofin, Req),
            loop(Req, State)
    after 30000 ->
        cowboy_req:stream_body(<<": keepalive\n\n">>, nofin, Req),
        loop(Req, State)
    end.
```

On the Phoenix side, use `EventSource` in JavaScript or a LiveView hook
with `fetch` and `ReadableStream`.

SSE is simpler (unidirectional, auto-reconnect built into the browser API)
but does not support client-to-server messages for subscribe/unsubscribe.

## Authentication Integration

### Security hooks

The admin API supports pluggable authentication and authorization via
callback functions configured in application environment:

```erlang
[
  {riak_admin_api, [
    {security_require_auth, true},
    {authn_hook, {my_auth_module, authenticate}},
    {authz_hook, {my_auth_module, authorize}}
  ]}
].
```

Hook signatures:

```erlang
%% Authentication hook
%% Receives the normalized request context.
%% Return: ok | allow | unauthorized | forbidden |
%%         {deny, Status, Code, Reason} | {error, ErrorMap}
-spec authenticate(Context :: map()) -> ok | unauthorized | {deny, integer(), binary(), binary()}.

%% Authorization hook (2-arity form)
%% Receives context and options (includes route, op, headers).
-spec authorize(Context :: map(), Opts :: map()) -> ok | forbidden.
```

When `security_require_auth` is `true` but no hooks are configured, all
requests receive a 503 `auth_not_configured` response. This fail-closed
behavior prevents accidentally running without auth in production.

### Passing auth tokens from LiveView

**Token-based pattern (recommended):**

Store an API token in the LiveView session and pass it as a header:

```elixir
defmodule MyApp.RiakAdmin do
  def get(path, opts \\ []) do
    token = Keyword.get(opts, :token)
    headers = if token, do: [{"authorization", "Bearer #{token}"}], else: []

    Req.get(@base_url <> path,
      headers: headers,
      receive_timeout: Keyword.get(opts, :timeout, 5_000)
    )
  end
end
```

In the LiveView:

```elixir
def mount(_params, session, socket) do
  token = session["riak_admin_token"]
  {:ok, assign(socket, riak_token: token)}
end

def handle_info(:refresh, socket) do
  case MyApp.RiakAdmin.get("/api/cluster/status", token: socket.assigns.riak_token) do
    {:ok, data} -> {:noreply, assign(socket, cluster: data)}
    {:error, _} -> {:noreply, socket}
  end
end
```

The auth hook on the Riak side extracts the token from the `authorization`
header (available in `Context.headers`) and validates it.

**Session-based pattern:**

If your Phoenix app proxies requests to the admin API, you can handle
authentication entirely in Phoenix and forward only authorized requests.
The admin API sees these as trusted internal requests (no auth hooks needed,
but restrict the admin port to internal networks).

### TLS enforcement

When `security_require_tls` is `true`, the API rejects all non-TLS
requests with 426. If a reverse proxy terminates TLS, set
`security_trust_proxy_headers` to `true` so the API trusts the
`X-Forwarded-Proto: https` header.

```erlang
[
  {riak_admin_api, [
    {security_require_tls, true},
    {security_trust_proxy_headers, true}
  ]}
].
```

## Example: Complete Cluster Dashboard LiveView

A working LiveView module that combines health, cluster status, and node
stats into a single dashboard:

```elixir
defmodule MyAppWeb.ClusterDashboardLive do
  use MyAppWeb, :live_view

  alias MyApp.RiakAdmin

  @ping_interval :timer.seconds(5)
  @cluster_interval :timer.seconds(10)
  @stats_interval :timer.seconds(10)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      send(self(), :ping)
      send(self(), :refresh_cluster)
      send(self(), :refresh_stats)
    end

    {:ok,
     assign(socket,
       ping_status: :unknown,
       ping_node: nil,
       cluster: nil,
       cluster_error: false,
       node_stats: %{},
       loading: true
     )}
  end

  @impl true
  def handle_info(:ping, socket) do
    Process.send_after(self(), :ping, @ping_interval)

    case RiakAdmin.get("/api/ping") do
      {:ok, %{"status" => "ok", "node" => node}} ->
        {:noreply, assign(socket, ping_status: :ok, ping_node: node)}

      _ ->
        {:noreply, assign(socket, ping_status: :error)}
    end
  end

  def handle_info(:refresh_cluster, socket) do
    Process.send_after(self(), :refresh_cluster, @cluster_interval)

    case RiakAdmin.get("/api/cluster/status") do
      {:ok, data} ->
        {:noreply,
         assign(socket,
           cluster: data,
           cluster_error: false,
           loading: false
         )}

      {:error, _} ->
        {:noreply, assign(socket, cluster_error: true, loading: false)}
    end
  end

  def handle_info(:refresh_stats, socket) do
    Process.send_after(self(), :refresh_stats, @stats_interval)

    nodes =
      case socket.assigns.cluster do
        %{"nodes" => nodes} -> Enum.map(nodes, & &1["name"])
        _ -> []
      end

    stats = fetch_all_stats(nodes)
    {:noreply, assign(socket, node_stats: stats)}
  end

  defp fetch_all_stats([]), do: %{}

  defp fetch_all_stats(nodes) do
    nodes
    |> Task.async_stream(
      fn node -> {node, RiakAdmin.get("/api/nodes/#{node}/stats")} end,
      max_concurrency: 10,
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce(%{}, fn
      {:ok, {node, {:ok, stats}}}, acc -> Map.put(acc, node, stats)
      {:ok, {node, _}}, acc -> Map.put(acc, node, nil)
      _, acc -> acc
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.health_indicator status={@ping_status} node={@ping_node} />

      <%= if @loading do %>
        <p class="text-gray-500">Loading cluster data...</p>
      <% end %>

      <%= if @cluster_error do %>
        <div class="p-4 bg-red-50 border border-red-200 rounded">
          Failed to reach the Riak admin API. Check connectivity.
        </div>
      <% end %>

      <%= if @cluster do %>
        <.cluster_summary cluster={@cluster} />
        <.node_table nodes={@cluster["nodes"]} stats={@node_stats} />
      <% end %>
    </div>
    """
  end

  defp health_indicator(assigns) do
    ~H"""
    <div class={[
      "inline-flex items-center gap-2 px-3 py-1 rounded-full text-sm font-medium",
      @status == :ok && "bg-green-100 text-green-800",
      @status == :error && "bg-red-100 text-red-800",
      @status == :unknown && "bg-gray-100 text-gray-600"
    ]}>
      <span class={[
        "w-2 h-2 rounded-full",
        @status == :ok && "bg-green-500",
        @status == :error && "bg-red-500",
        @status == :unknown && "bg-gray-400"
      ]} />
      <%= case @status do %>
        <% :ok -> %>Connected to <%= @node %>
        <% :error -> %>Unreachable
        <% :unknown -> %>Connecting...
      <% end %>
    </div>
    """
  end

  defp cluster_summary(assigns) do
    ~H"""
    <div class="grid grid-cols-4 gap-4">
      <div class="p-4 bg-white rounded shadow">
        <dt class="text-sm text-gray-500">Cluster</dt>
        <dd class="text-lg font-semibold"><%= @cluster["cluster_name"] %></dd>
      </div>
      <div class="p-4 bg-white rounded shadow">
        <dt class="text-sm text-gray-500">Ring Size</dt>
        <dd class="text-lg font-semibold"><%= @cluster["ring_size"] %></dd>
      </div>
      <div class="p-4 bg-white rounded shadow">
        <dt class="text-sm text-gray-500">Nodes</dt>
        <dd class="text-lg font-semibold"><%= length(@cluster["nodes"]) %></dd>
      </div>
      <div class="p-4 bg-white rounded shadow">
        <dt class="text-sm text-gray-500">Status</dt>
        <dd class={[
          "text-lg font-semibold",
          @cluster["ready"] && "text-green-600",
          !@cluster["ready"] && "text-amber-600"
        ]}>
          <%= if @cluster["ready"], do: "Ready", else: "Changes Pending" %>
        </dd>
      </div>
    </div>
    """
  end

  defp node_table(assigns) do
    ~H"""
    <table class="w-full bg-white rounded shadow">
      <thead class="bg-gray-50">
        <tr>
          <th class="px-4 py-2 text-left text-sm text-gray-600">Node</th>
          <th class="px-4 py-2 text-left text-sm text-gray-600">Status</th>
          <th class="px-4 py-2 text-right text-sm text-gray-600">Ring %</th>
          <th class="px-4 py-2 text-right text-sm text-gray-600">Memory (MB)</th>
          <th class="px-4 py-2 text-right text-sm text-gray-600">Processes</th>
          <th class="px-4 py-2 text-right text-sm text-gray-600">Gets</th>
          <th class="px-4 py-2 text-right text-sm text-gray-600">Puts</th>
        </tr>
      </thead>
      <tbody>
        <%= for node <- @nodes do %>
          <% stats = Map.get(@stats, node["name"]) %>
          <tr class="border-t">
            <td class="px-4 py-2 font-mono text-sm">
              <span class={[
                "inline-block w-2 h-2 rounded-full mr-2",
                node["reachable"] && "bg-green-500",
                !node["reachable"] && "bg-red-500"
              ]} />
              <%= node["name"] %>
            </td>
            <td class="px-4 py-2 text-sm"><%= node["status"] %></td>
            <td class="px-4 py-2 text-sm text-right"><%= node["ring_pct"] %>%</td>
            <%= if stats do %>
              <td class="px-4 py-2 text-sm text-right">
                <%= stats["erlang"]["memory_total_mb"] %>
              </td>
              <td class="px-4 py-2 text-sm text-right">
                <%= stats["erlang"]["process_count"] %>
              </td>
              <td class="px-4 py-2 text-sm text-right">
                <%= stats["kv"]["node_gets"] %>
              </td>
              <td class="px-4 py-2 text-sm text-right">
                <%= stats["kv"]["node_puts"] %>
              </td>
            <% else %>
              <td colspan="4" class="px-4 py-2 text-sm text-gray-400 text-center">
                --
              </td>
            <% end %>
          </tr>
        <% end %>
      </tbody>
    </table>
    """
  end
end
```

### Router setup

```elixir
# lib/my_app_web/router.ex
scope "/", MyAppWeb do
  pipe_through :browser

  live "/dashboard", ClusterDashboardLive
end
```

### Application config

```elixir
# config/config.exs
config :my_app, :riak_admin_url, "http://localhost:8099"

# config/prod.exs
config :my_app, :riak_admin_url, "http://riak-admin.internal:8099"
```

### Error response format

All error responses from the admin API follow a consistent shape:

```json
{
  "status": 500,
  "error": "backend_error",
  "reason": "Failed to retrieve cluster status",
  "request_id": "riak-admin-42"
}
```

The `request_id` is useful for correlating errors across the Phoenix app
and Riak server logs. Pass it through to your error reporting.
