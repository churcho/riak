# Riak Admin API Reference

The Riak Admin API runs on Cowboy (default port **8099**) alongside the legacy Webmachine data-path API (port 10018). It serves two classes of endpoints:

- **Admin endpoints** (`/api/...`) -- cluster observability and management
- **Substrate endpoints** -- compatibility layer that translates legacy Riak HTTP paths through the Cowboy stack

All responses include an `X-Request-Id` header (client-supplied via the same header, or auto-generated).

---

## Table of Contents

- [Admin Endpoints](#admin-endpoints)
  - [Ping](#ping)
  - [Cluster Status](#cluster-status)
  - [Datacenter Discovery](#datacenter-discovery)
  - [Ring Ownership](#ring-ownership)
  - [Node Stats](#node-stats)
  - [Handoff Status](#handoff-status)
  - [AAE Status](#aae-status)
  - [WebSocket Event Stream](#websocket-event-stream)
- [Substrate Endpoints](#substrate-endpoints)
  - [MapReduce](#mapreduce)
  - [Object CRUD](#object-crud)
  - [Bucket Properties](#bucket-properties)
  - [Bucket Type Properties](#bucket-type-properties)
  - [Key Listing](#key-listing)
  - [Bucket Listing](#bucket-listing)
  - [Counters](#counters)
  - [CRDTs (Datatypes)](#crdts-datatypes)
  - [Secondary Index (2i)](#secondary-index-2i)
  - [Query](#query)
- [Common Response Patterns](#common-response-patterns)
  - [Error Response Format](#error-response-format)
  - [Streaming Responses](#streaming-responses)
  - [CORS Headers](#cors-headers)
  - [Compatibility Headers](#compatibility-headers)
- [Authentication and Security Headers](#authentication-and-security-headers)
- [Configuration Reference](#configuration-reference)

---

## Admin Endpoints

All admin endpoints accept only **GET** requests and go through the `ensure_admin_get` security pipeline (TLS check, authn/authz hooks). Non-GET methods return `405 Method Not Allowed`.

### Ping

Health-check endpoint for liveness probes.

| Property | Value |
|----------|-------|
| **Path** | `/api/ping` |
| **Method** | `GET` |
| **Handler** | `rah_ping` |

**Response (200 OK):**

```json
{
  "status": "ok",
  "node": "riak@127.0.0.1"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | string | Always `"ok"` when the node is running |
| `node` | string | Erlang node name |

**Example:**

```bash
curl -s http://localhost:8099/api/ping | jq .
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 405 | `method_not_allowed` | Non-GET method used |
| 500 | `backend_error` | Internal server error |

---

### Cluster Status

Returns cluster membership, ring distribution, node reachability, and remote datacenter information.

| Property | Value |
|----------|-------|
| **Path** | `/api/cluster/status` |
| **Method** | `GET` |
| **Handler** | `rah_cluster` |

**Response (200 OK):**

```json
{
  "cluster_name": "default",
  "ring_size": 64,
  "claimant": "riak@127.0.0.1",
  "ready": true,
  "nodes": [
    {
      "name": "riak@127.0.0.1",
      "status": "valid",
      "ring_pct": 100.0,
      "reachable": true
    }
  ],
  "pending_changes": [],
  "remote_dcs": [],
  "total_dcs": 1
}
```

| Field | Type | Description |
|-------|------|-------------|
| `cluster_name` | string | Ring cluster name |
| `ring_size` | integer | Total number of partitions |
| `claimant` | string | Node responsible for ring changes |
| `ready` | boolean | `true` when no pending changes exist |
| `nodes` | array | Per-node membership information |
| `nodes[].name` | string | Erlang node name |
| `nodes[].status` | string | Membership status: `valid`, `leaving`, `exiting`, `joining`, `down` |
| `nodes[].ring_pct` | float | Percentage of ring owned (2 decimal places) |
| `nodes[].reachable` | boolean | Whether the node responded to ping within timeout |
| `pending_changes` | array | Stringified pending ring changes |
| `remote_dcs` | array | List of remote datacenters (see [DC Discovery](#datacenter-discovery) for shape) |
| `total_dcs` | integer | Count of all DCs (local + remote) |

**Example:**

```bash
curl -s http://localhost:8099/api/cluster/status | jq .
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 405 | `method_not_allowed` | Non-GET method |
| 500 | `backend_error` | Ring manager or internal failure |

---

### Datacenter Discovery

Returns all known datacenters discovered via syn group membership.

| Property | Value |
|----------|-------|
| **Path** | `/api/dcs` |
| **Method** | `GET` |
| **Handler** | `rah_dcs` |

**Response (200 OK):**

```json
{
  "dcs": [
    {
      "name": "dc1",
      "local": true,
      "admin_url": "http://10.0.1.10:8099",
      "riak_url": "http://10.0.1.10:8098",
      "riak_version": "3.4.0",
      "node": "riak@10.0.1.10",
      "reachable": true,
      "started_at": 1708000000
    }
  ],
  "count": 1
}
```

| Field | Type | Description |
|-------|------|-------------|
| `dcs` | array | List of datacenter entries |
| `dcs[].name` | string | DC name from coordinator metadata |
| `dcs[].local` | boolean | `true` if this DC matches the local node's DC |
| `dcs[].admin_url` | string | Admin API base URL (`http://host:port`) |
| `dcs[].riak_url` | string | Riak HTTP API base URL |
| `dcs[].riak_version` | string | Riak KV version on the representative node |
| `dcs[].node` | string | Erlang node atom of the representative node |
| `dcs[].reachable` | boolean | Always `true` (syn members are reachable by definition) |
| `dcs[].started_at` | integer | Coordinator start timestamp |
| `count` | integer | Number of DCs returned |

**Example:**

```bash
curl -s http://localhost:8099/api/dcs | jq .
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 405 | `method_not_allowed` | Non-GET method |
| 500 | `dc_discovery_error` | syn group or coordinator failure |

---

### Ring Ownership

Returns the full partition-to-node mapping of the ring.

| Property | Value |
|----------|-------|
| **Path** | `/api/ring/ownership` |
| **Method** | `GET` |
| **Handler** | `rah_ring` |

**Response (200 OK):**

```json
{
  "num_partitions": 64,
  "partitions": [
    {
      "index": 0,
      "hash": 0,
      "node": "riak@127.0.0.1"
    }
  ],
  "node_colors": {
    "riak@127.0.0.1": 0
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `num_partitions` | integer | Total ring size |
| `partitions` | array | Ordered list of partition entries |
| `partitions[].index` | integer | Sequential index (0-based) |
| `partitions[].hash` | integer | Position on the 2^160 hash ring |
| `partitions[].node` | string | Owning node |
| `node_colors` | object | Map of node name to sequential color index (for visualization) |

**Example:**

```bash
curl -s http://localhost:8099/api/ring/ownership | jq '.num_partitions'
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 405 | `method_not_allowed` | Non-GET method |
| 500 | `backend_error` | Ring manager failure |

---

### Node Stats

Returns Erlang VM and Riak KV statistics for a specific node.

| Property | Value |
|----------|-------|
| **Path** | `/api/nodes/:node/stats` |
| **Method** | `GET` |
| **Handler** | `rah_nodes` |

**Path Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `node` | string | Erlang node name (e.g., `riak@127.0.0.1`) |

**Response (200 OK):**

```json
{
  "node": "riak@127.0.0.1",
  "erlang": {
    "otp_release": "25",
    "process_count": 1234,
    "memory_total_mb": 256,
    "memory_processes_mb": 128,
    "memory_ets_mb": 64,
    "run_queue": 0
  },
  "kv": {
    "vnode_gets": 1000,
    "vnode_puts": 500,
    "node_gets": 800,
    "node_puts": 400,
    "read_repairs": 10,
    "node_get_fsm_time_mean": 1500,
    "node_put_fsm_time_mean": 2000
  }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `node` | string | The queried node name |
| `erlang.otp_release` | string | OTP version |
| `erlang.process_count` | integer | Number of Erlang processes |
| `erlang.memory_total_mb` | integer | Total VM memory in MB |
| `erlang.memory_processes_mb` | integer | Process heap memory in MB |
| `erlang.memory_ets_mb` | integer | ETS table memory in MB |
| `erlang.run_queue` | integer | Scheduler run queue length |
| `kv.vnode_gets` | integer | Total vnode GET operations |
| `kv.vnode_puts` | integer | Total vnode PUT operations |
| `kv.node_gets` | integer | Total coordinated GET operations |
| `kv.node_puts` | integer | Total coordinated PUT operations |
| `kv.read_repairs` | integer | Total read repair operations |
| `kv.node_get_fsm_time_mean` | integer | Mean GET FSM latency (microseconds) |
| `kv.node_put_fsm_time_mean` | integer | Mean PUT FSM latency (microseconds) |

**Example:**

```bash
curl -s http://localhost:8099/api/nodes/riak@127.0.0.1/stats | jq .
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `missing_parameter` | `:node` path parameter missing |
| 404 | `unknown_node` | Node name not recognized (not a known Erlang atom) |
| 405 | `method_not_allowed` | Non-GET method |
| 500 | `backend_error` | Internal failure |
| 503 | `node_unreachable` | Remote node did not respond (5s RPC timeout) |

---

### Handoff Status

Returns active handoff transfers with a count.

| Property | Value |
|----------|-------|
| **Path** | `/api/handoff/status` |
| **Method** | `GET` |
| **Handler** | `rah_handoff` |

**Response (200 OK):**

```json
{
  "active_transfers": [
    {
      "raw": "{status_v2,...}"
    }
  ],
  "count": 1
}
```

| Field | Type | Description |
|-------|------|-------------|
| `active_transfers` | array | List of transfer entries (stringified tuple or map, depending on Riak version) |
| `count` | integer | Number of active transfers |

**Example:**

```bash
curl -s http://localhost:8099/api/handoff/status | jq .count
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 405 | `method_not_allowed` | Non-GET method |
| 500 | `backend_error` | Handoff manager failure |

---

### AAE Status

Returns active anti-entropy exchange information.

| Property | Value |
|----------|-------|
| **Path** | `/api/aae/status` |
| **Method** | `GET` |
| **Handler** | `rah_aae` |

**Response (200 OK):**

```json
{
  "exchanges": [
    {
      "raw": "{exchange_info,...}"
    }
  ],
  "count": 0
}
```

| Field | Type | Description |
|-------|------|-------------|
| `exchanges` | array | List of exchange entries (stringified tuple or map, depending on Riak version) |
| `count` | integer | Number of exchanges |

**Example:**

```bash
curl -s http://localhost:8099/api/aae/status | jq .count
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 405 | `method_not_allowed` | Non-GET method |
| 500 | `backend_error` | Entropy info computation failure |

---

### WebSocket Event Stream

Push-based event stream over WebSocket. Replaces polling for dashboards that need near-instant updates on ring changes, cluster membership, node stats, handoff progress, and AAE status.

| Property | Value |
|----------|-------|
| **Path** | `/api/stream/events` |
| **Protocol** | WebSocket (upgrade from GET) |
| **Handler** | `rah_events_ws` |

The endpoint runs through the same security pipeline as other admin endpoints (TLS check, authn/authz hooks) before upgrading the connection. Failed auth returns a standard HTTP error; no WebSocket handshake occurs.

#### Connection frame

On successful upgrade, the server sends a `connected` frame listing the topics the client can subscribe to:

```json
{
  "type": "connected",
  "node": "riak@127.0.0.1",
  "topics": ["ring", "cluster", "membership", "node_stats", "handoff", "aae", "dcs"],
  "live": true,
  "timestamp": 1700000000
}
```

| Field | Type | Description |
|-------|------|-------------|
| `type` | string | Always `"connected"` |
| `node` | string | Erlang node name the client connected to |
| `topics` | array | Available topic names |
| `live` | boolean | `true` if the handler joined the syn event group; `false` if syn was unavailable (events will not arrive) |
| `timestamp` | integer | Unix epoch seconds |

#### Client commands

All client messages are JSON text frames with an `action` field.

**Subscribe:**

```json
{"action": "subscribe", "topics": ["ring", "cluster", "node_stats"]}
```

The server responds with a `subscribed` acknowledgment, then sends a `snapshot` frame for each newly subscribed topic containing the current state. Re-subscribing to an already-active topic is idempotent and does not trigger a redundant snapshot.

Subscribe requests are rate-limited: at most one per `ws_subscribe_min_interval` (default 1000 ms). Faster requests receive a `rate_limited` error.

**Unsubscribe:**

```json
{"action": "unsubscribe", "topics": ["node_stats"]}
```

Returns an `unsubscribed` acknowledgment. Events for the removed topics stop arriving.

**Ping:**

```json
{"action": "ping"}
```

Returns a `pong` frame with a `timestamp` field. Useful for latency measurement.

#### Server frames

**Event frame** -- pushed when data changes for a subscribed topic:

```json
{
  "type": "event",
  "topic": "ring",
  "node": "riak@127.0.0.1",
  "data": {"num_partitions": 64, "partitions": [...], "node_colors": {...}},
  "timestamp": 1700000000
}
```

**Snapshot frame** -- pushed once per topic on subscribe:

```json
{
  "type": "snapshot",
  "topic": "ring",
  "node": "riak@127.0.0.1",
  "data": {"num_partitions": 64, "partitions": [...], "node_colors": {...}},
  "timestamp": 1700000000
}
```

Snapshots and events have the same shape. The client can treat them identically.

**Backpressure frame** -- pushed when the client falls behind:

```json
{
  "type": "backpressure",
  "message_queue_len": 142,
  "dropped_topic": "node_stats",
  "timestamp": 1700000000
}
```

If the server-side message queue exceeds `ws_backpressure_limit` (default 100), the event is dropped and this warning is sent instead. The next event for each topic carries the full current state, so no data is permanently lost.

#### Topics

| Topic | Source | Default interval | Data shape |
|-------|--------|-----------------|------------|
| `ring` | Push (ring events) | -- | Same as `GET /api/ring/ownership` |
| `cluster` | Push (ring events) | -- | Same as `GET /api/cluster/status` (without `remote_dcs`) |
| `membership` | Push (node watcher) | -- | `{"events": [...], "services": [...]}` |
| `node_stats` | Poll | 10s | Map of node name to `{"erlang": {...}, "kv": {...}}` |
| `handoff` | Poll | 15s | Same as `GET /api/handoff/status` |
| `aae` | Poll | 30s | Same as `GET /api/aae/status` |
| `dcs` | Push (syn group) | -- | Same as `GET /api/dcs` |

Push-based topics publish immediately when the underlying event fires. Poll-based topics publish only when the data has changed from the previous poll (controlled by `bridge_diff_detection`).

#### Errors

| Code | When |
|------|------|
| `invalid_message` | Frame is not valid JSON or not a JSON object |
| `invalid_topics` | `topics` field is not an array of strings |
| `unknown_action` | `action` value not recognized |
| `rate_limited` | Subscribe sent too soon after the previous one |
| `internal_error` | Server-side dispatch crash (logged, connection stays open) |

Error frames have the shape `{"type": "error", "code": "<code>", "reason": "<message>"}`.

**Example (websocat):**

```bash
websocat ws://localhost:8099/api/stream/events
> {"action": "subscribe", "topics": ["ring", "cluster"]}
```

---

## Substrate Endpoints

Substrate endpoints provide Cowboy-backed compatibility for Riak's legacy HTTP API paths. Requests are normalized through the `riak_admin_api_request` pipeline and dispatched by `riak_admin_api_handler`.

Three URL alias families are supported:

| Alias | Prefix | API Version | Description |
|-------|--------|-------------|-------------|
| `riak` | `/riak/...` | 1 | Legacy path style |
| `buckets` | `/buckets/...` | 2 | Default-type modern style |
| `types` | `/types/:type/...` | 3 | Typed modern style |

### Cutover Control

Substrate endpoints are governed by a **cutover system** that controls which operation groups are active. The cutover mode for each operation can be:

| Mode | Behavior |
|------|----------|
| `enabled` | Normal operation |
| `disabled` | Returns `503 Service Unavailable` |
| `deprecated` | Normal operation (allows deprecation logging) |
| `shadow` | Normal operation (allows shadow traffic) |
| `removed` | Returns `410 Gone` |

Configure via `cowboy_cutover_default_mode` (global default) and `cowboy_cutover_op_modes` (per-operation overrides).

---

### MapReduce

Execute MapReduce jobs or retrieve usage information.

| Property | Value |
|----------|-------|
| **Paths** | `/mapred` |
| **Methods** | `GET`, `HEAD`, `POST` |
| **Operation** | `mapred` |

#### GET /mapred

Returns a plain-text usage description.

**Response (200 OK):**

```
Content-Type: text/plain; charset=utf-8

This resource accepts POSTs with bodies containing JSON of the form:
{
 "inputs":[...list of inputs...],
 "query":[...list of map/reduce phases...]
}
```

#### POST /mapred

Execute a MapReduce job.

**Query Parameters:**

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `chunked` | boolean | `true`, `false` | Stream results as multipart chunks |

**Request Body (application/json):**

```json
{
  "inputs": ["bucket_name"],
  "query": [
    {"map": {"language": "javascript", "source": "function(v) { return [v]; }"}}
  ]
}
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `inputs` | array/string | Yes | Input specification (bucket name, list of `[bucket, key]` pairs, etc.) |
| `query` | array | Yes | List of map/reduce phase specifications |

**Response (200 OK) -- Non-chunked:**

```
Content-Type: application/json; charset=utf-8

[[...results...]]
```

**Response (200 OK) -- Chunked (`?chunked=true`):**

```
Content-Type: multipart/mixed;boundary=<boundary>

--<boundary>
Content-Type: application/json

{"phase": 0, "data": [...]}
--<boundary>--
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `invalid_body` | Missing `inputs`/`query`, invalid JSON, malformed phases |
| 400 | `invalid_query` | Phase configuration error |
| 405 | `method_not_allowed` | Non-GET/HEAD/POST method |
| 501 | `not_implemented` | MapReduce backend modules not available |
| 503 | `service_unavailable` | MapReduce disabled by operator (`mapred_backend_enabled = false`) |
| 503 | `timeout` | Execution timed out |

---

### Object CRUD

Create, read, update, and delete Riak objects.

| Property | Value |
|----------|-------|
| **Paths** | `/riak/:bucket/:key` |
| | `/buckets/:bucket/keys/:key` |
| | `/types/:type/buckets/:bucket/keys/:key` |
| **Methods** | `GET`, `HEAD`, `PUT`, `POST`, `DELETE` |
| **Operation** | `object_item` |

**Path Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `type` | string | Bucket type (defaults to `"default"` for `/riak` and `/buckets` paths) |
| `bucket` | string | Bucket name |
| `key` | string | Object key |

#### GET / HEAD

Retrieve an object.

**Query Parameters:**

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `r` | quorum | `default`, `one`, `quorum`, `all`, integer | Read quorum |
| `pr` | quorum | (same) | Primary read quorum |
| `basic_quorum` | boolean | `true`, `false` | Return early on quorum failure |
| `notfound_ok` | boolean | `true`, `false` | Treat not-found as success for quorum |
| `timeout` | integer | 0..4294967295 | Request timeout in ms (capped to `max_server_timeout_ms`) |
| `vtag` | string | | Select a specific sibling by vtag |

**Response (200 OK):**

Headers:
```
Content-Type: <stored content type>
X-Request-Id: <request-id>
X-Riak-Vclock: <base64-encoded vector clock>
ETag: <vtag>
Last-Modified: <RFC 1123 date>
Link: </buckets/mybucket>; rel="up"
X-Riak-Meta-*: <user metadata>
X-Riak-Index-*: <secondary index values>
Content-Encoding: <if stored>
```

Body: The stored object value in its original content type.

**Response (300 Multiple Choices) -- Siblings:**

When `allow_mult=true` and siblings exist:

- **Accept: text/plain** (default): Text listing of vtags
- **Accept: multipart/mixed**: Full multipart body with each sibling as a part

**Response (404 Not Found):**

```json
{
  "status": 404,
  "error": "not_found",
  "reason": "not found",
  "request_id": "<id>"
}
```

#### PUT

Update an existing object.

**Required Headers:**

| Header | Description |
|--------|-------------|
| `Content-Type` | Media type of the body (required) |
| `X-Riak-Vclock` | Base64 vector clock for conflict resolution (recommended for updates) |

**Optional Headers:**

| Header | Description |
|--------|-------------|
| `X-Riak-Meta-*` | User metadata (prefix stripped and stored) |
| `X-Riak-Index-*` | Secondary index entries (comma-separated for multi-value) |
| `Content-Encoding` | Stored alongside the object |
| `If-None-Match` | Conditional: fail if object exists |
| `If-Match` | Conditional: fail if ETag does not match current vtag |
| `If-Unmodified-Since` | Conditional: fail if modified after given date |
| `X-Riak-If-Not-Modified` | Conditional: base64 vclock, fail if modified |

**Query Parameters:**

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `w` | quorum | `default`, `one`, `quorum`, `all`, integer | Write quorum |
| `pw` | quorum | (same) | Primary write quorum |
| `dw` | quorum | (same) | Durable write quorum |
| `node_confirms` | quorum | (same) | Node confirmation quorum |
| `returnbody` | boolean | `true`, `false` | Return the stored object in the response |
| `timeout` | integer | 0..4294967295 | Request timeout in ms |
| `asis` | boolean | `true`, `false` | Store object as-is (no coordination) |

**Response (204 No Content):** Object stored (no `returnbody`).

**Response (200 OK):** Object stored with body (when `returnbody=true`), same shape as GET.

#### POST (to key path)

Same semantics as PUT.

#### POST (to collection path)

Create a new object with a server-generated key.

| Property | Value |
|----------|-------|
| **Paths** | `/riak/:bucket` (POST) |
| | `/buckets/:bucket/keys` (POST) |
| | `/types/:type/buckets/:bucket/keys` (POST) |
| **Operation** | `object_collection` |

**Response (201 Created):**

```
Location: /buckets/<bucket>/keys/<generated-key>
```

#### DELETE

Delete an object.

**Optional Headers:**

| Header | Description |
|--------|-------------|
| `X-Riak-Vclock` | Base64 vector clock for causal delete |

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `rw` | quorum | Read-write quorum for delete |
| `r` | quorum | Read quorum |
| `w` | quorum | Write quorum |
| `pr` | quorum | Primary read quorum |
| `pw` | quorum | Primary write quorum |
| `timeout` | integer | Request timeout in ms |

**Response (204 No Content):** Object deleted.

**Common Object Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `missing_content_type` | PUT/POST without Content-Type header |
| 400 | `invalid_vclock` | Malformed X-Riak-Vclock or X-Riak-If-Not-Modified |
| 400 | `invalid_quorum` | Quorum value exceeds bucket n_val |
| 403 | `forbidden` | Pre-commit hook rejection |
| 404 | `not_found` | Object does not exist |
| 404 | `bucket_type_unknown` | Bucket type does not exist |
| 405 | `method_not_allowed` | Unsupported method for this path |
| 409 | `conflict` | Object was modified (If-Not-Modified check) |
| 412 | `precondition_failed` | If-Match or If-Unmodified-Since check failed |
| 413 | `payload_too_large` | Body exceeds `max_request_body_bytes` (default 5 MB) |
| 503 | `quorum_unsatisfied` | R/W/DW/PR/PW/node_confirms value not met |
| 503 | `timeout` | Request timed out |
| 503 | `backend_unavailable` | Riak client unavailable |

---

### Bucket Properties

Read, set, or reset bucket properties.

| Property | Value |
|----------|-------|
| **Paths** | `/buckets/:bucket/props` |
| | `/types/:type/buckets/:bucket/props` |
| | `/riak/:bucket` (when `?props` is enabled and `?keys` is not) |
| **Methods** | `GET`, `HEAD`, `PUT`, `DELETE` (DELETE not available on `/riak` alias) |
| **Operation** | `bucket_props` |

#### GET / HEAD

**Response (200 OK):**

```json
{
  "props": {
    "n_val": 3,
    "allow_mult": false,
    "last_write_wins": false,
    ...
  }
}
```

The `props` object contains all Riak bucket properties in their JSON-encoded form.

#### PUT

Set bucket properties.

**Request Body:**

```json
{
  "props": {
    "n_val": 5,
    "allow_mult": true
  }
}
```

**Response (204 No Content):** Properties updated.

#### DELETE

Reset bucket properties to defaults. Only available on `/buckets` and `/types` aliases.

**Response (204 No Content):** Properties reset.

**Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `invalid_body` | Body is not `{"props": {...}}` |
| 400 | `invalid_props` | Invalid property values |
| 405 | `method_not_allowed` | Unsupported method |

**Example:**

```bash
# Read
curl -s http://localhost:8099/buckets/mybucket/props | jq .

# Set
curl -X PUT http://localhost:8099/buckets/mybucket/props \
  -H "Content-Type: application/json" \
  -d '{"props": {"n_val": 5}}'

# Reset
curl -X DELETE http://localhost:8099/buckets/mybucket/props
```

---

### Bucket Type Properties

Read or set bucket type properties.

| Property | Value |
|----------|-------|
| **Path** | `/types/:type/props` |
| **Methods** | `GET`, `HEAD`, `PUT` |
| **Operation** | `bucket_type_props` |

Same request/response format as [Bucket Properties](#bucket-properties), but operates on the bucket type level. DELETE is not supported.

**Errors:**

| Status | Code | When |
|--------|------|------|
| 404 | `bucket_type_unknown` | Bucket type does not exist |

---

### Key Listing

List keys in a bucket.

| Property | Value |
|----------|-------|
| **Paths** | `/buckets/:bucket/keys?keys=true\|stream` |
| | `/types/:type/buckets/:bucket/keys?keys=true\|stream` |
| | `/riak/:bucket?keys=true\|stream` |
| **Methods** | `GET`, `HEAD` |
| **Operation** | `keys` |

**Query Parameters:**

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `keys` | string | `true`, `false`, `stream` | Enable key listing; `stream` uses chunked transfer |
| `props` | boolean | `true`, `false` | Include bucket properties (only on `/riak` alias, default `true`) |
| `timeout` | integer | | Timeout in ms (capped to `stream_collection_ceiling_ms`) |

**Response (200 OK) -- Non-streaming (`keys=true`):**

```json
{
  "keys": ["key1", "key2", "key3"]
}
```

On the `/riak` alias with `props=true` (default), the response also includes `"props": {...}`.

**Response (200 OK) -- Streaming (`keys=stream`):**

Chunked transfer encoding. Each chunk is a JSON object:

```json
{"keys": ["key1", "key2"]}
{"keys": ["key3"]}
{"keys": []}
```

The final chunk has an empty keys array. On timeout, the final chunk is:

```json
{"error": "timeout"}
```

**Error modes:**

The `list_keys_error_mode` configuration controls error handling:

| Mode | Behavior |
|------|----------|
| `compat` (default) | Returns 200 with `{"error": <reason>}` embedded |
| `strict` | Returns proper HTTP error status codes |

**Example:**

```bash
curl -s 'http://localhost:8099/buckets/mybucket/keys?keys=true' | jq .
curl -s 'http://localhost:8099/buckets/mybucket/keys?keys=stream'
```

---

### Bucket Listing

List all buckets.

| Property | Value |
|----------|-------|
| **Paths** | `/buckets?buckets=true\|stream` |
| | `/types/:type/buckets?buckets=true\|stream` |
| | `/riak` |
| **Methods** | `GET`, `HEAD` |
| **Operation** | `buckets` |

Without `?buckets=true` or `?buckets=stream`, returns an empty list.

**Response (200 OK):**

```json
{
  "buckets": ["bucket1", "bucket2"]
}
```

**Streaming (`buckets=stream`):**

Chunked transfer encoding with the same pattern as key listing:

```json
{"buckets": ["bucket1"]}
{"buckets": []}
```

**Example:**

```bash
curl -s 'http://localhost:8099/buckets?buckets=true' | jq .
```

---

### Counters

Read and update legacy counters (PN-counters in the `counters` bucket type).

| Property | Value |
|----------|-------|
| **Path** | `/buckets/:bucket/counters/:key` |
| **Methods** | `GET`, `POST` |
| **Operation** | `counter` |

**Query Parameters:**

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `r` | quorum | `default`, `one`, `quorum`, `all`, integer | Read quorum |
| `pr` | quorum | (same) | Primary read quorum |
| `w` | quorum | (same) | Write quorum |
| `pw` | quorum | (same) | Primary write quorum |
| `dw` | quorum | (same) | Durable write quorum |
| `basic_quorum` | boolean | `true`, `false` | Return early on quorum failure |
| `notfound_ok` | boolean | `true`, `false` | Treat not-found as quorum success |
| `node_confirms` | quorum | (same) | Node confirmation quorum |
| `timeout` | integer | | Timeout in ms |
| `returnvalue` | boolean | `true`, `false` | Return updated counter value on POST |

#### GET

Returns the counter value as plain text.

**Response (200 OK):**

```
Content-Type: text/plain; charset=utf-8

42
```

#### POST

Increment or decrement the counter. The request body is a plain integer.

**Request Body:**

```
5
```

Positive integers increment; negative integers decrement.

**Response (204 No Content):** Counter updated (no `returnvalue`).

**Response (200 OK):** Updated counter value as plain text (when `returnvalue=true`).

**Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `invalid_body` | Body is not an integer |
| 405 | `method_not_allowed` | Non-GET/POST method |

**Example:**

```bash
# Read
curl -s http://localhost:8099/buckets/scores/counters/player1

# Increment by 10
curl -X POST http://localhost:8099/buckets/scores/counters/player1 \
  -d '10'

# Decrement by 3
curl -X POST http://localhost:8099/buckets/scores/counters/player1 \
  -d '-3'
```

---

### CRDTs (Datatypes)

Operate on Riak Data Types (counters, sets, maps, flags, registers) through typed buckets.

#### Fetch a CRDT

| Property | Value |
|----------|-------|
| **Path** | `/types/:type/buckets/:bucket/datatypes/:key` |
| **Methods** | `GET`, `HEAD`, `POST` |
| **Operation** | `crdt_item` |

**Query Parameters:**

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `r` | quorum | `default`, `one`, `quorum`, `all`, integer | Read quorum |
| `pr` | quorum | (same) | Primary read quorum |
| `w` | quorum | (same) | Write quorum |
| `pw` | quorum | (same) | Primary write quorum |
| `dw` | quorum | (same) | Durable write quorum |
| `rw` | quorum | (same) | Read-write quorum |
| `basic_quorum` | boolean | `true`, `false` | |
| `notfound_ok` | boolean | `true`, `false` | |
| `node_confirms` | quorum | (same) | |
| `timeout` | integer | | Timeout in ms |
| `include_context` | boolean | `true` (default), `false` | Include opaque context for subsequent updates |
| `returnbody` | boolean | `true`, `false` | Return updated value after POST |

**GET Response (200 OK):**

The JSON structure depends on the datatype. Examples:

Counter:
```json
{
  "type": "counter",
  "value": 42
}
```

Set:
```json
{
  "type": "set",
  "value": ["a", "b", "c"],
  "context": "<base64>"
}
```

Map:
```json
{
  "type": "map",
  "value": {
    "name_register": "Alice",
    "age_counter": 30,
    "tags_set": ["admin"]
  },
  "context": "<base64>"
}
```

**Not Found (404):**

```json
{
  "type": "counter",
  "error": "notfound"
}
```

If the object was deleted (tombstone), the response includes `X-Riak-Deleted: true` header.

#### POST -- Update a CRDT

**Request Body:** JSON update operation as defined by Riak's CRDT JSON protocol. The body structure depends on the datatype.

Counter update:
```json
{
  "increment": 5
}
```

Set update:
```json
{
  "add_all": ["x", "y"],
  "remove_all": ["z"],
  "context": "<base64>"
}
```

**Response (204 No Content):** Updated (no `returnbody`).

**Response (200 OK):** Updated value (when `returnbody=true`), same JSON shape as GET.

#### POST -- Create a CRDT (collection path)

| Property | Value |
|----------|-------|
| **Path** | `/types/:type/buckets/:bucket/datatypes` |
| **Methods** | `POST` |
| **Operation** | `crdt_collection` |

Creates a new CRDT with a server-generated key.

**Response (201 Created):**

```
Location: /types/<type>/buckets/<bucket>/datatypes/<generated-key>
```

**Default bucket type redirect:**

When operating on the `default` bucket type, CRDT paths return `301 Moved Permanently` with a `Location` header pointing to the legacy `/buckets/:bucket/counters/:key` path.

**Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `invalid_datatype` | Bucket not `allow_mult=true` or unsupported datatype |
| 400 | `invalid_body` | Malformed CRDT update JSON |
| 404 | `bucket_type_unknown` | Bucket type does not exist |
| 405 | `method_not_allowed` | Unsupported method |

**Example:**

```bash
# Fetch a counter
curl -s http://localhost:8099/types/counters/buckets/visits/datatypes/page1 | jq .

# Update a set
curl -X POST http://localhost:8099/types/sets/buckets/tags/datatypes/user1 \
  -H "Content-Type: application/json" \
  -d '{"add_all": ["admin", "user"]}'
```

---

### Secondary Index (2i)

Query secondary indexes.

| Property | Value |
|----------|-------|
| **Paths** | `/buckets/:bucket/index/:field/:term` (exact match) |
| | `/buckets/:bucket/index/:field/:start/:end` (range) |
| | `/types/:type/buckets/:bucket/index/:field/:term` |
| | `/types/:type/buckets/:bucket/index/:field/:start/:end` |
| **Methods** | `GET`, `HEAD` |
| **Operation** | `index_query` |

**Path Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `bucket` | string | Bucket name |
| `field` | string | Index field name (e.g., `email_bin`, `age_int`, `$key`, `$bucket`) |
| `term` | string | Exact match term |
| `start` | string | Range start (inclusive) |
| `end` | string | Range end (inclusive) |

**Query Parameters:**

| Parameter | Type | Values | Description |
|-----------|------|--------|-------------|
| `stream` | boolean | `true`, `false` | Stream results as multipart |
| `max_results` | integer | > 0 | Maximum number of results (enables pagination) |
| `continuation` | string | | Continuation token from previous paginated response |
| `return_terms` | boolean | `true`, `false` | Include index terms in results |
| `pagination_sort` | boolean | `true`, `false` | Sort results for pagination (auto-enabled with continuation) |
| `timeout` | integer | | Timeout in ms |
| `term_regex` | string | | Filter results by term regex (binary indexes only) |

**Response (200 OK) -- Non-streaming:**

```json
{
  "keys": ["key1", "key2"],
  "continuation": "<token>"
}
```

With `return_terms=true`:

```json
{
  "results": [
    {"key1": "term_value"},
    {"key2": "term_value"}
  ],
  "continuation": "<token>"
}
```

The `continuation` field is present only when `max_results` was specified and the result count equals `max_results`.

**Response (200 OK) -- Streaming (`stream=true`):**

```
Content-Type: multipart/mixed;boundary=<boundary>

--<boundary>
Content-Type: application/json

{"keys": ["key1", "key2"]}
--<boundary>
Content-Type: application/json

{"continuation": "<token>"}
--<boundary>--
```

**Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `invalid_query` | Invalid index field, bad term_regex, regex on integer index |
| 405 | `method_not_allowed` | Non-GET/HEAD method |
| 503 | `timeout` | Query timed out |

**Example:**

```bash
# Exact match
curl -s 'http://localhost:8099/buckets/users/index/email_bin/alice@example.com' | jq .

# Range query with pagination
curl -s 'http://localhost:8099/buckets/events/index/timestamp_int/1000/2000?max_results=10' | jq .

# Streaming
curl -s 'http://localhost:8099/buckets/users/index/age_int/18/65?stream=true'
```

---

### Query

Execute complex multi-index queries with aggregation support.

| Property | Value |
|----------|-------|
| **Paths** | `/buckets/:bucket/query` |
| | `/types/:type/buckets/:bucket/query` |
| **Methods** | `POST` |
| **Operation** | `query` |

**Request Body (application/json):**

```json
{
  "query_list": [
    {
      "index_name": "age_int",
      "start_term": "18",
      "end_term": "65",
      "aggregation_tag": "adults",
      "regular_expression": ".*",
      "evaluation_expression": null,
      "filter_expression": null
    }
  ],
  "aggregation_expression": null,
  "accumulation_option": "keys",
  "accumulation_term": null,
  "substitutions": {},
  "timeout": 60,
  "max_results": 1000,
  "continuation": null
}
```

**Top-level fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `query_list` | array | Yes | List of index query definitions (at least one required) |
| `aggregation_expression` | string | No | Expression for aggregating across queries |
| `accumulation_option` | string | No | Result accumulation mode: `keys`, `terms`, `count`, `raw_keys`, `raw_terms`, `raw_count`, `term_with_count`, `term_with_rawcount` |
| `accumulation_term` | string | No | Term for accumulation |
| `substitutions` | object | No | Variable substitutions for expressions |
| `timeout` | integer | No | Timeout in seconds (default 60) |
| `max_results` | integer | No | Maximum result count |
| `continuation` | string | No | Continuation from previous response |

**Query list entry fields:**

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `index_name` | string | Yes | Secondary index field name |
| `start_term` | string | Yes | Range start |
| `end_term` | string | Yes | Range end |
| `aggregation_tag` | string | No | Tag for grouping in aggregation |
| `regular_expression` | string | No | Filter by regex |
| `evaluation_expression` | string | No | Evaluation expression |
| `filter_expression` | string | No | Filter expression |

**Response (200 OK):**

The response shape depends on `accumulation_option`:

| Option | Response Shape |
|--------|----------------|
| `keys` | `{"keys": [...]}` |
| `terms` | `{"terms": [...]}` |
| `count` | `{"count": N}` |
| `raw_keys` | `{"raw_keys": [...]}` |
| `raw_terms` | `{"raw_terms": [...]}` |
| `raw_count` | `{"raw_count": N}` |
| `term_with_count` | `{"term_with_count": {...}}` |
| `term_with_rawcount` | `{"term_with_rawcount": {...}}` |

When paginated, the response includes an `X-Riak-Continuation` header with the continuation token.

**Errors:**

| Status | Code | When |
|--------|------|------|
| 400 | `invalid_body` | Invalid JSON or missing required fields |
| 400 | `invalid_query` | Query validation failure |
| 405 | `method_not_allowed` | Non-POST method |
| 503 | `timeout` | Query timed out |

---

## Common Response Patterns

### Error Response Format

All error responses follow a consistent JSON structure:

```json
{
  "status": 404,
  "error": "not_found",
  "reason": "not found",
  "request_id": "riak-admin-42"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `status` | integer | HTTP status code (mirrored in body for client convenience) |
| `error` | string | Machine-readable error code |
| `reason` | string | Human-readable description |
| `request_id` | string | Request identifier for correlation |

Some errors include additional fields:

- `details` -- extra context when available
- `allow` header -- comma-separated allowed methods on 405 responses

### Streaming Responses

Streaming endpoints use **chunked transfer encoding** via Cowboy's `stream_reply` facility. Three streaming patterns are used:

1. **JSON line streaming** (keys, buckets) -- Each chunk is a complete JSON object:
   ```
   {"keys": ["k1", "k2"]}
   {"keys": []}
   ```
   The empty array signals completion. On error:
   ```
   {"error": "timeout"}
   ```

2. **Multipart streaming** (index queries, chunked MapReduce) -- Standard multipart/mixed with boundary:
   ```
   --<boundary>
   Content-Type: application/json

   <json-payload>
   --<boundary>--
   ```

3. **Incremental vs. collected** -- Controlled by `stream_incremental_enabled` (default `true`). When disabled, streaming endpoints buffer the full response before sending. All streaming operations are capped by `stream_collection_ceiling_ms` (default 300,000 ms).

### CORS Headers

CORS headers are emitted only when `security_trusted_origins` is configured and the request `Origin` header matches a trusted origin.

When active, responses include:

| Header | Value |
|--------|-------|
| `Access-Control-Allow-Origin` | The matching origin |
| `Access-Control-Allow-Methods` | `GET, HEAD, PUT, POST, DELETE, OPTIONS` |
| `Access-Control-Allow-Headers` | `Content-Type, X-Request-Id, X-Riak-Vclock, X-Riak-ClientId, If-Match, If-None-Match, If-Unmodified-Since, If-Modified-Since, Origin` |
| `Access-Control-Expose-Headers` | `X-Request-Id, X-Riak-Vclock, ETag, Last-Modified, Link, Location` |
| `Access-Control-Max-Age` | `3600` |

When `trusted_origins` is configured but the request uses an unsafe method without an `Origin` header, the request is rejected with `403 Forbidden`.

### Compatibility Headers

All responses may include the following headers:

| Header | Description |
|--------|-------------|
| `X-Request-Id` | Client-supplied or auto-generated request identifier |
| `X-Riak-Vclock` | Base64-encoded vector clock (object operations) |
| `ETag` | Object vtag (object operations) |
| `Last-Modified` | RFC 1123 timestamp of last modification (object operations) |
| `Link` | RFC 5988 link relations (up-link to bucket, object links) |
| `Allow` | Permitted methods (on 405 responses) |
| `Location` | URI of created resource (on 201 responses) |

All header values are sanitized: control characters (0x00-0x1F, 0x7F) are stripped to prevent HTTP response splitting and log injection.

---

## Authentication and Security Headers

### Request Headers

| Header | Description |
|--------|-------------|
| `X-Request-Id` | Client-supplied request ID (max 200 bytes, control chars stripped). Auto-generated as `riak-admin-<monotonic>` if absent. |
| `X-Forwarded-Proto` | Trusted only when `security_trust_proxy_headers = true`. Must be `https` when `security_require_tls = true`. |
| `Origin` | Required for unsafe methods (POST/PUT/DELETE) when `security_trusted_origins` is configured. Must match a trusted origin. |

### Security Pipeline

Requests pass through the following security checks in order:

1. **TLS enforcement** -- When `security_require_tls = true`, requires `X-Forwarded-Proto: https` (with `trust_proxy_headers = true`) or rejects with `426 Upgrade Required`.
2. **Origin validation** -- When `security_trusted_origins` is configured, validates the `Origin` header for unsafe methods. Rejects with `403 Forbidden` on mismatch or missing header.
3. **Auth guardrails** -- When `security_require_auth = true`, verifies that both `authn_hook` and `authz_hook` are configured. Returns `503 Service Unavailable` if hooks are missing (prevents accidental unprotected operation).
4. **Authentication hook** -- Calls the configured `authn_fun` (function or `{Module, Function}` tuple). Can return `ok`, `allow`, `unauthorized`, `forbidden`, or `{deny, Status, Code, Reason}`.
5. **Authorization hook** -- Same interface as authentication, called after successful authn.

---

## Configuration Reference

All settings are read from `riak_admin_api` application environment.

### Server Settings

| Key | Default | Description |
|-----|---------|-------------|
| `http_port` | `8099` | Admin API listen port |
| `riak_http_port` | `8098` | Riak HTTP port (stored in syn metadata) |
| `cowboy_max_connections` | `1024` | Maximum concurrent connections |
| `cowboy_idle_timeout` | `60000` | Idle keep-alive timeout (ms) |
| `cowboy_request_timeout` | `30000` | Max time to receive complete request (ms) |
| `cowboy_max_keepalive` | `100` | Max requests per connection |
| `cowboy_max_header_name_length` | `64` | Max header name length (bytes) |
| `cowboy_max_header_value_length` | `4096` | Max header value length (bytes) |
| `cowboy_max_headers` | `100` | Max headers per request |
| `max_request_body_bytes` | `5242880` | Max request body size (5 MB) |
| `max_server_timeout_ms` | `300000` | Cap on client-requested timeouts (5 min) |

### Streaming Settings

| Key | Default | Description |
|-----|---------|-------------|
| `stream_incremental_enabled` | `true` | Use chunked transfer for streaming ops |
| `stream_collection_ceiling_ms` | `300000` | Max blocking time for any stream (5 min) |

### Feature Toggles

| Key | Default | Description |
|-----|---------|-------------|
| `mapred_backend_enabled` | `true` | Enable/disable MapReduce backend |
| `list_keys_error_mode` | `compat` | `compat` (200 + embedded error) or `strict` (proper HTTP status) |
| `cowboy_cutover_default_mode` | `disabled` | Default cutover mode for substrate endpoints |
| `cowboy_cutover_op_modes` | `[]` | Per-operation cutover overrides (proplist or map) |

### Security Settings

| Key | Default | Description |
|-----|---------|-------------|
| `security_require_tls` | `false` | Reject non-TLS requests |
| `security_trust_proxy_headers` | `false` | Trust X-Forwarded-Proto |
| `security_trusted_origins` | `[]` | Allowed CORS origins (list of binaries) |
| `security_require_auth` | `false` | Require auth hooks to be configured |
| `authn_hook` | `undefined` | Authentication callback |
| `authz_hook` | `undefined` | Authorization callback |

### WebSocket Settings

| Key | Default | Description |
|-----|---------|-------------|
| `ws_idle_timeout` | `300000` | Close connection after this many ms of inactivity (5 min) |
| `ws_max_frame_size` | `65536` | Maximum incoming frame size in bytes (64 KB) |
| `ws_subscribe_min_interval` | `1000` | Minimum ms between subscribe requests per connection |
| `ws_backpressure_limit` | `100` | Message queue length before dropping events and sending a backpressure warning |

### Event Bridge Settings

| Key | Default | Description |
|-----|---------|-------------|
| `bridge_stats_interval` | `10000` | Node stats polling interval (ms) |
| `bridge_handoff_interval` | `15000` | Handoff status polling interval (ms) |
| `bridge_aae_interval` | `30000` | AAE status polling interval (ms) |
| `bridge_diff_detection` | `true` | Only publish poll-based events when data changes from previous poll |

### Cluster Status Settings

| Key | Default | Description |
|-----|---------|-------------|
| `cluster_status_ping_timeout` | `3000` | Parallel ping timeout per node (ms) |
