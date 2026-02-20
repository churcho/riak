# Cowboy Admin API Reference

Complete API reference for the `riak_admin_api` Cowboy application -- the modern HTTP interface for Riak KV cluster administration and data operations.

**Version:** 0.1.0
**Default Port:** 8099
**Source:** `apps/riak_admin_api/`

---

## Table of Contents

1. [Overview](#1-overview)
2. [Getting Started](#2-getting-started)
3. [Architecture](#3-architecture)
4. [API Reference -- Admin Endpoints](#4-api-reference--admin-endpoints)
5. [API Reference -- Object Operations](#5-api-reference--object-operations)
6. [API Reference -- Bucket Operations](#6-api-reference--bucket-operations)
7. [API Reference -- Secondary Index (2i) Queries](#7-api-reference--secondary-index-2i-queries)
8. [API Reference -- MapReduce](#8-api-reference--mapreduce)
9. [API Reference -- CRDT/Datatypes](#9-api-reference--crdtdatatypes)
10. [API Reference -- Query Language](#10-api-reference--query-language)
11. [Security Model](#11-security-model)
12. [Migration & Cutover Controls](#12-migration--cutover-controls)
13. [Multi-DC Discovery](#13-multi-dc-discovery)
14. [Endpoint Map](#14-endpoint-map)
15. [Configuration Reference](#15-configuration-reference)
16. [Error Response Format](#16-error-response-format)
17. [Route Compatibility](#17-route-compatibility)

---

## 1. Overview

### What This Is

`riak_admin_api` is a Cowboy 2.x-based HTTP application that provides a REST API for Riak KV. It runs alongside Riak's existing Webmachine/Mochiweb HTTP interface on a **dedicated port** (default 8099) as the foundation for eventually replacing the legacy stack.

The application serves two families of endpoints:

- **Admin endpoints** (`/api/*`) -- cluster status, ring ownership, node stats, DC discovery, handoff and AAE monitoring. These are handled by dedicated `rah_*` handler modules.
- **Substrate endpoints** (`/riak/*`, `/buckets/*`, `/types/*`, `/mapred`) -- full data-path parity with the legacy Webmachine API, including object CRUD, bucket/key listing, secondary index queries, MapReduce, and CRDT operations. These are handled by the unified `riak_admin_api_handler` module.

### Why It Exists

| Concern | Legacy (Webmachine/Mochiweb) | Cowboy |
|---------|------------------------------|--------|
| HTTP stack | Webmachine on Mochiweb, end-of-life | Cowboy 2.x, actively maintained |
| Protocol | HTTP/1.1 only | HTTP/1.1 + HTTP/2 + WebSocket |
| Traffic isolation | Shared port 10018 for admin + data | Dedicated port 8099 for admin |
| Testability | Deep coupling to Riak internals | Single gateway module; mock and test in isolation |
| Extractability | Embedded in riak_kv | Can be extracted to its own repo mechanically |

### Architecture Summary

![Architecture Overview](architecture/cowboy-architecture-overview.svg)

The application follows a strict **isolation principle**: only one module (`riak_admin_api_riak.erl`) is permitted to call Riak internals (`riak_core`, `riak_kv`, `riak_object`). Every other module communicates with Riak exclusively through this gateway. The `.app.src` deliberately omits `riak_core` and `riak_kv` from its dependency list -- they are resolved at runtime only.

---

## 2. Getting Started

### Default Port

The admin API listens on port **8099** in production. In a devrel cluster, each node uses a computed port based on the node number:

| Node | Admin API Port | Pattern |
|------|---------------|---------|
| dev1@127.0.0.1 | 10015 | 100N5 |
| dev2@127.0.0.1 | 10025 | 100N5 |
| dev3@127.0.0.1 | 10035 | 100N5 |
| Production | 8099 | Configured default |

### Quick Health Check

```bash
curl http://localhost:8099/api/ping
```

Response:

```json
{"status": "ok", "node": "dev1@127.0.0.1"}
```

### Port Configuration

Set the port in `advanced.config` or `sys.config`:

```erlang
{riak_admin_api, [
    {http_port, 8099}
]}
```

In a devrel the port is auto-resolved from the node name and written back to application env at startup.

---

## 3. Architecture

### Module Overview

| Module | Role |
|--------|------|
| `riak_admin_api_app` | OTP application callback. Starts Cowboy listener, compiles routes, starts supervisor tree. |
| `riak_admin_api_sup` | Top-level supervisor. `one_for_one` strategy, intensity 5/10s. Single child: coordinator. |
| `riak_admin_api_coordinator` | `gen_server` that owns the syn registration for this node. Publishes DC metadata. |
| `riak_admin_api_handler` | Unified Cowboy handler for all substrate routes. Dispatches to operation-specific clauses based on the normalized request context. |
| `riak_admin_api_request` | Request normalization: path parsing, query validation, header extraction, security enforcement, cutover checks. |
| `riak_admin_api_response` | Response serialization: JSON encoding, compatibility headers (`X-Riak-Vclock`, `ETag`, `Link`), error formatting, telemetry. |
| `riak_admin_api_riak` | **Gateway module.** ALL calls to `riak_core`, `riak_kv`, and `riak_object` go through this module exclusively. |
| `riak_admin_event_handler` | syn event handler for the `riak_admin` scope. Handles node discovery/departure and netsplit conflict resolution. |
| `rah_ping` | Handler: `GET /api/ping` |
| `rah_cluster` | Handler: `GET /api/cluster/status` |
| `rah_dcs` | Handler: `GET /api/dcs` |
| `rah_ring` | Handler: `GET /api/ring/ownership` |
| `rah_nodes` | Handler: `GET /api/nodes/:node/stats` |
| `rah_handoff` | Handler: `GET /api/handoff/status` |
| `rah_aae` | Handler: `GET /api/aae/status` |

### Isolation Principle

**Only `riak_admin_api_riak.erl` touches Riak internals.** No other module in the application may call `riak_core`, `riak_kv`, or `riak_object` directly.

To verify the isolation contract:

```bash
grep -rn "riak_core\|riak_kv\|riak_object\|riak:local" \
  apps/riak_admin_api/src/ \
  | grep -v riak_admin_api_riak.erl
```

This should return zero results.

Benefits:
- `rebar3 compile` works without Riak source present (modules resolve at runtime)
- Every handler is testable in isolation -- swap the gateway for a mock
- Extraction to a standalone repo is mechanical: copy the directory, change path to git

### Request Lifecycle

![Request Lifecycle](architecture/cowboy-request-lifecycle.svg)

1. **Cowboy receives HTTP request** on the configured port.
2. **Router dispatches** to the appropriate handler module based on compiled route rules.
3. For admin routes (`/api/*`), the dedicated `rah_*` handler calls `ensure_get` then invokes the gateway.
4. For substrate routes (`/riak/*`, `/buckets/*`, `/types/*`, `/mapred`), `riak_admin_api_handler:init/2` is called:
   a. **Normalize request** via `riak_admin_api_request:normalize/2`:
      - Extract method, path, headers, query params
      - Generate or extract `X-Request-Id`
      - Parse path into operation context (`op`, `bucket`, `key`, `field`, `range`, etc.)
      - Validate query parameters against allowed set per operation
      - Validate HTTP method against allowed set per operation
      - Check cutover mode (enabled/deprecated/shadow/disabled/removed)
      - Run security pipeline (TLS, CORS origin, authn hook, authz hook)
   b. **Dispatch** to operation handler (e.g., `handle_object_item`, `handle_bucket_props`)
   c. **Execute backend** via `riak_admin_api_riak` gateway
   d. **Format response** via `riak_admin_api_response` with compatibility headers

---

## 4. API Reference -- Admin Endpoints

All admin endpoints are GET-only. Non-GET methods return `405 Method Not Allowed`.

### GET /api/ping

Health check. Returns immediately without touching Riak internals.

```bash
curl http://localhost:8099/api/ping
```

```json
{
  "status": "ok",
  "node": "dev1@127.0.0.1"
}
```

**Status Codes:** 200 OK, 405 Method Not Allowed

---

### GET /api/cluster/status

Returns cluster membership, ring size, node health, pending changes, and remote DC information.

```bash
curl http://localhost:8099/api/cluster/status
```

```json
{
  "cluster_name": "default",
  "ring_size": 64,
  "claimant": "dev1@127.0.0.1",
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
  "ready": true,
  "remote_dcs": [],
  "total_dcs": 1
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `cluster_name` | string | Ring cluster name |
| `ring_size` | integer | Total number of partitions |
| `claimant` | string | Node that coordinates ring changes |
| `nodes` | array | Per-node status objects |
| `nodes[].name` | string | Erlang node name |
| `nodes[].status` | string | Membership status: `valid`, `joining`, `leaving`, `exiting`, `down` |
| `nodes[].ring_pct` | float | Percentage of ring owned (0.00-100.00) |
| `nodes[].reachable` | boolean | Whether the node responds to `net_adm:ping` |
| `pending_changes` | array | Stringified pending ring changes (empty when cluster is stable) |
| `ready` | boolean | `true` when no pending changes exist |
| `remote_dcs` | array | Remote datacenter info from syn discovery |
| `total_dcs` | integer | Count of all DCs (local + remote) |

**Status Codes:** 200 OK, 405 Method Not Allowed, 500 Internal Server Error

---

### GET /api/dcs

Returns all known datacenters discovered via syn group membership.

```bash
curl http://localhost:8099/api/dcs
```

```json
{
  "dcs": [
    {
      "name": "default",
      "local": true,
      "admin_url": "http://127.0.0.1:10015",
      "riak_url": "http://127.0.0.1:10018",
      "riak_version": "3.4.0",
      "node": "dev1@127.0.0.1",
      "reachable": true,
      "started_at": 1708444800
    }
  ],
  "count": 1
}
```

**Response Fields (per DC):**

| Field | Type | Description |
|-------|------|-------------|
| `name` | string | DC name (from `dc_name` config) |
| `local` | boolean | `true` if this DC matches the local node's DC |
| `admin_url` | string | Full URL to the admin API (Cowboy port) |
| `riak_url` | string | Full URL to the Riak HTTP API (Webmachine port) |
| `riak_version` | string | Riak version on the representative node |
| `node` | string | Erlang node atom of the representative |
| `reachable` | boolean | Always `true` (syn members are reachable by definition) |
| `started_at` | integer | Unix timestamp (seconds) when coordinator registered |

**Status Codes:** 200 OK, 405 Method Not Allowed, 500 Internal Server Error

---

### GET /api/ring/ownership

Returns the full partition-to-node mapping of the ring.

```bash
curl http://localhost:8099/api/ring/ownership
```

```json
{
  "num_partitions": 64,
  "partitions": [
    {"index": 0, "hash": 0, "node": "dev1@127.0.0.1"},
    {"index": 1, "hash": 22835963083295358096932575511191922182123945984, "node": "dev2@127.0.0.1"}
  ],
  "node_colors": {
    "dev1@127.0.0.1": 0,
    "dev2@127.0.0.1": 1
  }
}
```

**Response Fields:**

| Field | Type | Description |
|-------|------|-------------|
| `num_partitions` | integer | Total ring size |
| `partitions` | array | Ordered partition list |
| `partitions[].index` | integer | Sequential index (0-based) |
| `partitions[].hash` | integer | Raw hash position on the 2^160 ring |
| `partitions[].node` | string | Owning node |
| `node_colors` | object | Node-to-color-index mapping for visualizations |

**Status Codes:** 200 OK, 405 Method Not Allowed, 500 Internal Server Error

---

### GET /api/nodes/:node/stats

Returns Erlang VM and riak_kv statistics for a specific node. For remote nodes, the gateway uses `rpc:call/4` with a 5-second timeout.

```bash
curl http://localhost:8099/api/nodes/dev1@127.0.0.1/stats
```

```json
{
  "node": "dev1@127.0.0.1",
  "erlang": {
    "otp_release": "26",
    "process_count": 1523,
    "memory_total_mb": 256,
    "memory_processes_mb": 85,
    "memory_ets_mb": 42,
    "run_queue": 0
  },
  "kv": {
    "vnode_gets": 15234,
    "vnode_puts": 8921,
    "node_gets": 12000,
    "node_puts": 7500,
    "read_repairs": 42,
    "node_get_fsm_time_mean": 1234,
    "node_put_fsm_time_mean": 2345
  }
}
```

**Error Cases:**
- Unknown node name: `404` with error code `unknown_node`
- Unreachable node: `503` with error code `node_unreachable`

**Status Codes:** 200 OK, 404 Not Found, 405 Method Not Allowed, 500 Internal Server Error, 503 Service Unavailable

---

### GET /api/handoff/status

Returns active handoff transfers across the cluster.

```bash
curl http://localhost:8099/api/handoff/status
```

```json
{
  "active_transfers": [
    {"raw": "{status_v2, ...}"}
  ],
  "count": 1
}
```

Transfers are returned as their Erlang term representation stringified to JSON. Known tuple shapes are destructured into clean maps; unknown shapes use a `raw` string fallback.

**Status Codes:** 200 OK, 405 Method Not Allowed, 500 Internal Server Error

---

### GET /api/aae/status

Returns Active Anti-Entropy exchange information.

```bash
curl http://localhost:8099/api/aae/status
```

```json
{
  "exchanges": [
    {"raw": "{1, ...}"}
  ],
  "count": 0
}
```

Like handoff, exchange entries use a defensive formatting pattern: known shapes get proper maps, unknown shapes get stringified.

**Status Codes:** 200 OK, 405 Method Not Allowed, 500 Internal Server Error

---

## 5. API Reference -- Object Operations

![Data Operations](architecture/cowboy-data-operations.svg)

Object operations provide full CRUD for Riak KV objects. Three path families are supported, all routed through the unified `riak_admin_api_handler`.

### Path Patterns

| Family | Pattern | API Version | Bucket Type |
|--------|---------|-------------|-------------|
| Legacy | `/riak/:bucket/:key` | v1 | `default` |
| Modern | `/buckets/:bucket/keys/:key` | v2 | `default` |
| Typed | `/types/:type/buckets/:bucket/keys/:key` | v3 | Specified |

### Allowed Methods

`GET`, `HEAD`, `PUT`, `POST`, `DELETE`

### GET / HEAD -- Fetch Object

Retrieves an object by bucket and key.

```bash
# Legacy path
curl http://localhost:8099/riak/mybucket/mykey

# Modern path
curl http://localhost:8099/buckets/mybucket/keys/mykey

# Typed path
curl http://localhost:8099/types/mytype/buckets/mybucket/keys/mykey
```

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `r` | quorum | Read quorum. Values: integer, `default`, `one`, `quorum`, `all` |
| `pr` | quorum | Primary read quorum |
| `basic_quorum` | boolean | Whether to use basic quorum semantics |
| `notfound_ok` | boolean | Whether notfound counts toward read quorum |
| `node_confirms` | integer | Minimum node confirmations |
| `timeout` | integer | Request timeout in milliseconds |
| `vtag` | string | Select a specific sibling by vtag |

**Response Headers:**

| Header | Description |
|--------|-------------|
| `X-Riak-Vclock` | Base64-encoded vector clock |
| `ETag` | Object vtag |
| `Last-Modified` | RFC 1123 timestamp |
| `Link` | Riak link header (up-link to bucket, plus any object links) |
| `Content-Type` | Object media type (as stored) |
| `Content-Encoding` | If the object has an encoding set |
| `X-Riak-Meta-*` | User-defined metadata |
| `X-Riak-Index-*` | Secondary index values |
| `X-Request-Id` | Request tracking identifier |

**Sibling Handling:**

When an object has multiple siblings (HTTP 300):

- **Default** (no `Accept: multipart/mixed`): Returns `text/plain` listing of vtags
- **`Accept: multipart/mixed`**: Returns full sibling bodies in a multipart response with each part containing Content-Type and ETag headers

```bash
# Fetch a specific sibling
curl http://localhost:8099/buckets/mybucket/keys/mykey?vtag=abc123
```

**Status Codes:** 200 OK, 300 Multiple Choices (siblings), 404 Not Found

---

### PUT / POST -- Store Object

Stores an object. `PUT` requires a key in the path. `POST` to a collection path generates a key server-side.

```bash
# PUT with explicit key
curl -X PUT \
  -H "Content-Type: application/json" \
  -H "X-Riak-Vclock: <base64-vclock>" \
  -d '{"name": "example"}' \
  'http://localhost:8099/buckets/mybucket/keys/mykey?returnbody=true'

# POST to create with auto-generated key
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"name": "example"}' \
  http://localhost:8099/buckets/mybucket/keys
```

**Request Headers:**

| Header | Required | Description |
|--------|----------|-------------|
| `Content-Type` | Yes | Media type of the object body |
| `X-Riak-Vclock` | No | Vector clock for conflict resolution (required for updates) |
| `X-Riak-Meta-*` | No | User-defined metadata (prefix stripped and stored) |
| `X-Riak-Index-*` | No | Secondary index entries (comma-separated for multiple values) |
| `Content-Encoding` | No | Content encoding (stored as metadata) |
| `If-None-Match` | No | Conditional: only store if key does not exist |
| `X-Riak-If-Not-Modified` | No | Conditional: base64-encoded vclock; store only if object has not been modified |

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `w` | quorum | Write quorum |
| `pw` | quorum | Primary write quorum |
| `dw` | quorum | Durable write quorum |
| `node_confirms` | integer | Minimum node confirmations |
| `timeout` | integer | Timeout in milliseconds |
| `returnbody` | boolean | Return the stored object in the response |
| `asis` | boolean | Store object as-is (for replication) |
| `sync_on_write` | string | Sync-on-write mode: `backend`, `one`, `all`, `default` |

**POST Response (auto-generated key):**

Returns `201 Created` with a `Location` header pointing to the new object:

```
HTTP/1.1 201 Created
Location: /buckets/mybucket/keys/3kf9d2...
```

**Status Codes:** 200 OK (with returnbody), 201 Created (POST), 204 No Content (PUT without returnbody), 400 Bad Request, 403 Forbidden (pre-commit hook), 409 Conflict (modified), 412 Precondition Failed

---

### DELETE -- Delete Object

```bash
# Delete without vclock (tombstone)
curl -X DELETE http://localhost:8099/buckets/mybucket/keys/mykey

# Delete with vclock (causal delete)
curl -X DELETE \
  -H "X-Riak-Vclock: <base64-vclock>" \
  http://localhost:8099/buckets/mybucket/keys/mykey
```

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `r` | quorum | Read quorum (for fetching vclock) |
| `w` | quorum | Write quorum |
| `pr` | quorum | Primary read quorum |
| `pw` | quorum | Primary write quorum |
| `dw` | quorum | Durable write quorum |
| `rw` | quorum | Read-write delete quorum |
| `node_confirms` | integer | Minimum node confirmations |
| `timeout` | integer | Timeout in milliseconds |

**Status Codes:** 204 No Content, 400 Bad Request (invalid vclock), 404 Not Found

---

## 6. API Reference -- Bucket Operations

### GET Bucket Properties

```bash
# Modern path
curl http://localhost:8099/buckets/mybucket/props

# Typed path
curl http://localhost:8099/types/mytype/buckets/mybucket/props
```

Response:

```json
{
  "props": {
    "n_val": 3,
    "allow_mult": false,
    "last_write_wins": false,
    "r": "quorum",
    "w": "quorum",
    "dw": "quorum",
    "rw": "quorum"
  }
}
```

**Allowed Methods:** GET, HEAD, PUT, DELETE (DELETE not available for `/riak` alias or bucket type props)

---

### PUT Bucket Properties

```bash
curl -X PUT \
  -H "Content-Type: application/json" \
  -d '{"props": {"n_val": 5, "allow_mult": true}}' \
  http://localhost:8099/buckets/mybucket/props
```

**Status Codes:** 204 No Content (success), 400 Bad Request (invalid props or body format)

The request body must be a JSON object with a `"props"` key:

```json
{"props": {"n_val": 5}}
```

---

### DELETE Bucket Properties

Resets bucket properties to defaults. Not available on the `/riak` path family or for bucket type properties.

```bash
curl -X DELETE http://localhost:8099/buckets/mybucket/props
```

**Status Codes:** 204 No Content

---

### GET / PUT Bucket Type Properties

```bash
# GET type properties
curl http://localhost:8099/types/mytype/props

# PUT type properties
curl -X PUT \
  -H "Content-Type: application/json" \
  -d '{"props": {"allow_mult": true}}' \
  http://localhost:8099/types/mytype/props
```

**Allowed Methods:** GET, HEAD, PUT (no DELETE)

**Status Codes:** 200 OK, 204 No Content (PUT success), 400 Bad Request, 404 Not Found (unknown type)

---

### List Buckets

**Warning:** Listing buckets is an expensive operation. It should not be used in production workloads.

```bash
# Full listing
curl 'http://localhost:8099/buckets?buckets=true'

# Streaming
curl 'http://localhost:8099/buckets?buckets=stream'

# With typed path
curl 'http://localhost:8099/types/mytype/buckets?buckets=true'

# Legacy path
curl 'http://localhost:8099/riak?buckets=true'
```

**Query Parameters:**

| Parameter | Values | Description |
|-----------|--------|-------------|
| `buckets` | `true`, `stream` | Required. `true` for full listing, `stream` for streaming |
| `timeout` | integer | Timeout in milliseconds (default: 300000 / 5 minutes) |

Response:

```json
{"buckets": ["bucket1", "bucket2", "bucket3"]}
```

**Allowed Methods:** GET, HEAD

---

### List Keys

**Warning:** Listing keys is an expensive operation. It should not be used in production workloads.

```bash
# Full listing
curl 'http://localhost:8099/buckets/mybucket/keys?keys=true'

# Streaming (with backpressure via riak_kv_keys_fsm:ack_keys/1)
curl 'http://localhost:8099/buckets/mybucket/keys?keys=stream'

# Legacy path (includes bucket props by default)
curl 'http://localhost:8099/riak/mybucket?keys=true'

# Legacy path without props
curl 'http://localhost:8099/riak/mybucket?keys=true&props=false'
```

**Query Parameters:**

| Parameter | Values | Description |
|-----------|--------|-------------|
| `keys` | `true`, `false`, `stream` | Required. `true` for full listing, `stream` for streaming |
| `props` | `true`, `false` | Include bucket properties (only on `/riak` path, default `true`) |
| `timeout` | integer | Timeout in milliseconds (stream default: 5000ms) |

Response:

```json
{"keys": ["key1", "key2", "key3"]}
```

Streaming responses emit multiple JSON chunks, each containing a `keys` array. The stream terminates with an empty keys array `{"keys": []}` or a timeout error `{"error": "timeout"}`.

**Stream Error Framing (S5):** All stream error paths (bucket listing, key listing, index queries, and MapReduce) use a consistent JSON error shape: `{"error": "<reason>"}`. This is emitted as the final chunk in the stream. For multipart responses (index and MapReduce), the error is wrapped in a multipart boundary part with `Content-Type: application/json`.

**Allowed Methods:** GET, HEAD

---

## 7. API Reference -- Secondary Index (2i) Queries

Secondary index queries find objects by indexed fields. Two query types are supported: exact term match and range queries.

### Term Query (Exact Match)

```bash
# Default type
curl http://localhost:8099/buckets/mybucket/index/email_bin/user@example.com

# Typed
curl http://localhost:8099/types/mytype/buckets/mybucket/index/email_bin/user@example.com
```

### Range Query

```bash
# String range
curl 'http://localhost:8099/buckets/mybucket/index/name_bin/a/z'

# Integer range
curl 'http://localhost:8099/buckets/mybucket/index/age_int/18/65'
```

### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `return_terms` | boolean | `false` | Include matched index terms in the response |
| `max_results` | integer | all | Maximum number of results (enables pagination) |
| `continuation` | string | -- | Continuation token from a previous paginated response |
| `stream` | boolean | `false` | Stream results as multipart/mixed |
| `timeout` | integer | -- | Timeout in milliseconds |
| `pagination_sort` | boolean | -- | Force sorted pagination (automatically `true` when `continuation` is present) |
| `term_regex` | string | -- | Regex filter on index terms (string indexes only, not integer) |

### Non-Streaming Response

```json
{
  "keys": ["key1", "key2"],
  "continuation": "g2gCZAAEb..."
}
```

With `return_terms=true`:

```json
{
  "results": [
    {"user@example.com": "key1"},
    {"admin@example.com": "key2"}
  ],
  "continuation": "g2gCZAAEb..."
}
```

### Streaming Response

When `stream=true`, results are returned as `multipart/mixed` with a unique boundary. Each part is a JSON chunk:

```
--<boundary>
Content-Type: application/json

{"keys": ["key1", "key2"]}
--<boundary>
Content-Type: application/json

{"continuation": "g2gCZAAEb..."}
--<boundary>--
```

### Pagination

```bash
# First page
curl 'http://localhost:8099/buckets/mybucket/index/name_bin/a/z?max_results=10'

# Next page
curl 'http://localhost:8099/buckets/mybucket/index/name_bin/a/z?max_results=10&continuation=g2gCZAAEb...'
```

A `continuation` token is returned only when the number of results equals `max_results`, indicating more results may be available.

**Allowed Methods:** GET, HEAD

**Status Codes:** 200 OK, 400 Bad Request (invalid query/regex), 503 Service Unavailable (timeout)

---

## 8. API Reference -- MapReduce

### POST /mapred

Execute a MapReduce job.

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "inputs": "mybucket",
    "query": [
      {"map": {"language": "erlang", "module": "riak_kv_mapreduce", "function": "map_object_value"}},
      {"reduce": {"language": "erlang", "module": "riak_kv_mapreduce", "function": "reduce_count_inputs"}}
    ]
  }' \
  http://localhost:8099/mapred
```

### GET /mapred

Returns a usage hint:

```
This resource accepts POSTs with bodies containing JSON of the form:
{
 "inputs":[...list of inputs...],
 "query":[...list of map/reduce phases...]
}
```

### Request Body Format

```json
{
  "inputs": "mybucket",
  "query": [
    {
      "map": {
        "language": "erlang",
        "module": "riak_kv_mapreduce",
        "function": "map_object_value"
      }
    },
    {
      "reduce": {
        "language": "erlang",
        "module": "riak_kv_mapreduce",
        "function": "reduce_count_inputs"
      }
    }
  ]
}
```

The `inputs` field can be:
- A bucket name (string) -- all keys in the bucket
- A list of `[bucket, key]` pairs
- A list of `[bucket, key, keydata]` triples

The `query` field is a list of map and/or reduce phase specifications.

### Query Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `chunked` | boolean | `false` | Return results as chunked multipart/mixed |

### Non-Chunked Response

Returns a single JSON array of results:

```json
[
  [{"key1": "value1"}, {"key2": "value2"}]
]
```

### Chunked Response

When `chunked=true`, results stream as `multipart/mixed` with each phase result as a separate part:

```
--<boundary>
Content-Type: application/json

{"phase": 0, "data": [...]}
--<boundary>
Content-Type: application/json

{"phase": 1, "data": [...]}
--<boundary>--
```

**Allowed Methods:** GET, HEAD, POST

**Status Codes:** 200 OK, 400 Bad Request (invalid body/query), 500 Internal Server Error (phase/runtime error), 503 Service Unavailable (timeout or operator-disabled backend), 501 Not Implemented (MapReduce backend unavailable in build)

---

## 9. API Reference -- CRDT/Datatypes

Riak datatypes (CRDTs) provide conflict-free replicated data structures. The Cowboy API supports counters, sets, maps, flags, and registers.

### Counter Shortcuts (Legacy, Default Bucket Type)

Counters in the default bucket type use the `counters` bucket type internally and have a simplified API.

#### GET Counter

```bash
curl http://localhost:8099/buckets/mybucket/counters/mykey
```

Response (plain text):

```
42
```

**Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `r` | quorum | Read quorum |
| `pr` | quorum | Primary read quorum |
| `basic_quorum` | boolean | Basic quorum semantics |
| `notfound_ok` | boolean | Notfound counts toward quorum |
| `node_confirms` | integer | Minimum node confirmations |
| `timeout` | integer | Timeout in milliseconds |

#### POST Counter Update

```bash
# Increment by 5
curl -X POST -d '5' http://localhost:8099/buckets/mybucket/counters/mykey

# Decrement by 3
curl -X POST -d '-3' http://localhost:8099/buckets/mybucket/counters/mykey

# With return value
curl -X POST -d '1' 'http://localhost:8099/buckets/mybucket/counters/mykey?returnvalue=true'
```

The request body must be a plain integer (positive for increment, negative for decrement).

**Additional Query Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `w` | quorum | Write quorum |
| `pw` | quorum | Primary write quorum |
| `dw` | quorum | Durable write quorum |
| `returnvalue` | boolean | Return the counter value after update |

**Allowed Methods:** GET, POST

**Status Codes:** 200 OK (with returnvalue), 204 No Content, 400 Bad Request, 404 Not Found

---

### Datatypes (Typed Bucket Types)

For typed bucket types, datatypes are accessed through the `/types` path. The bucket type must have `allow_mult=true` and a valid `datatype` property.

**Important:** If you attempt to use the datatypes endpoint with the default bucket type, the API returns a `301 Redirect` to the counter shortcut URL.

#### GET Datatype

```bash
curl http://localhost:8099/types/maps/buckets/mybucket/datatypes/mykey
```

Response (example for a map):

```json
{
  "type": "map",
  "value": {
    "name_register": "Alice",
    "age_register": "30",
    "tags_set": ["admin", "user"],
    "visits_counter": 42
  },
  "context": "g2wAAAAB..."
}
```

**Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `r` | quorum | -- | Read quorum |
| `pr` | quorum | -- | Primary read quorum |
| `basic_quorum` | boolean | -- | Basic quorum semantics |
| `notfound_ok` | boolean | -- | Notfound counts toward quorum |
| `node_confirms` | integer | -- | Minimum node confirmations |
| `timeout` | integer | -- | Timeout in milliseconds |
| `include_context` | boolean | `true` | Include the opaque context for subsequent updates |

#### POST Datatype Update

```bash
# Update a counter
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"increment": 5}' \
  http://localhost:8099/types/counters/buckets/mybucket/datatypes/mykey

# Update a set
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"add_all": ["tag1", "tag2"], "remove_all": ["old_tag"], "context": "g2wAAAAB..."}' \
  http://localhost:8099/types/sets/buckets/mybucket/datatypes/mykey

# Update a map
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "update": {
      "name_register": "Bob",
      "visits_counter": {"increment": 1},
      "tags_set": {"add_all": ["new_tag"]}
    },
    "context": "g2wAAAAB..."
  }' \
  http://localhost:8099/types/maps/buckets/mybucket/datatypes/mykey
```

**Additional Query Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `w` | quorum | -- | Write quorum |
| `pw` | quorum | -- | Primary write quorum |
| `dw` | quorum | -- | Durable write quorum |
| `rw` | quorum | -- | Read-write quorum |
| `returnbody` | boolean | `false` | Return the updated value |
| `include_context` | boolean | `true` | Include context in returnbody response |

#### POST Datatype Create (Collection)

Create a new datatype with a server-generated key:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{"increment": 1}' \
  http://localhost:8099/types/counters/buckets/mybucket/datatypes
```

Response: `201 Created` with `Location` header:

```
HTTP/1.1 201 Created
Location: /types/counters/buckets/mybucket/datatypes/3kf9d2...
```

**Allowed Methods:** GET, HEAD, POST (item); POST only (collection)

**Status Codes:** 200 OK, 201 Created (collection POST), 204 No Content, 301 Redirect (default type to counter shortcut), 400 Bad Request (invalid datatype/operation), 404 Not Found

---

## 10. API Reference -- Query Language

The query endpoint supports Riak KV's advanced index query language for multi-index queries with aggregation.

### POST /buckets/:bucket/query

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '{
    "query_list": [
      {
        "index_name": "email_bin",
        "start_term": "a",
        "end_term": "z"
      }
    ],
    "accumulation_option": "keys",
    "timeout": 60
  }' \
  http://localhost:8099/buckets/mybucket/query
```

Also available on typed path:

```bash
curl -X POST \
  -H "Content-Type: application/json" \
  -d '...' \
  http://localhost:8099/types/mytype/buckets/mybucket/query
```

### Request Body Format

```json
{
  "query_list": [
    {
      "index_name": "field_bin",
      "start_term": "start",
      "end_term": "end",
      "aggregation_tag": "optional_tag",
      "regular_expression": "optional_regex",
      "evaluation_expression": "optional_eval",
      "filter_expression": "optional_filter"
    }
  ],
  "aggregation_expression": "optional",
  "accumulation_option": "keys|terms|count|raw_keys|raw_terms|raw_count|term_with_count|term_with_rawcount",
  "accumulation_term": "optional",
  "substitutions": {},
  "timeout": 60,
  "max_results": 100,
  "continuation": "optional_token"
}
```

**Required Fields:**

| Field | Description |
|-------|-------------|
| `query_list` | Array of query objects (at least one required) |
| `query_list[].index_name` | Index field name |
| `query_list[].start_term` | Range start term |
| `query_list[].end_term` | Range end term |

**Optional Fields:**

| Field | Description |
|-------|-------------|
| `query_list[].aggregation_tag` | Tag for aggregation |
| `query_list[].regular_expression` | Regex filter on terms |
| `query_list[].evaluation_expression` | Evaluation expression |
| `query_list[].filter_expression` | Filter expression |
| `aggregation_expression` | Expression for combining multi-query results |
| `accumulation_option` | Result format (see below) |
| `accumulation_term` | Term for accumulation |
| `substitutions` | Variable substitutions map |
| `timeout` | Timeout in seconds (default: 60) |
| `max_results` | Limit result count |
| `continuation` | Pagination continuation token |

**Accumulation Options:**

| Option | Response Key | Description |
|--------|-------------|-------------|
| `keys` | `keys` | List of matching keys |
| `raw_keys` | `raw_keys` | Raw key list |
| `terms` | `terms` | Key-term pairs |
| `raw_terms` | `raw_terms` | Raw key-term pairs |
| `count` | `count` | Count of matches |
| `raw_count` | `raw_count` | Raw count |
| `term_with_count` | `term_with_count` | Per-term count map |
| `term_with_rawcount` | `term_with_rawcount` | Per-term raw count map |

**Response:** JSON object with the result key matching the `accumulation_option`. If `max_results` is set and more results exist, the response includes an `X-Riak-Continuation` header.

**Allowed Methods:** POST only

**Status Codes:** 200 OK, 400 Bad Request (invalid body/query), 500 Internal Server Error, 503 Service Unavailable (timeout)

---

## 11. Security Model

![Security & Cutover](architecture/cowboy-security-cutover.svg)

The security pipeline runs as part of request normalization, before any operation is dispatched. The checks execute in order; the first failure short-circuits the pipeline.

### Pipeline Order

1. **TLS Enforcement**
2. **CORS Origin Validation**
3. **Authentication Hook**
4. **Authorization Hook**

### TLS Enforcement

When `security_require_tls` is `true`, requests must arrive via HTTPS. Proxy headers are trusted only when `security_trust_proxy_headers=true`; otherwise TLS enforcement fails closed.

```erlang
{riak_admin_api, [
    {security_require_tls, true},
    {security_trust_proxy_headers, true}
]}
```

Non-HTTPS requests receive:

```json
{"status": 426, "error": "tls_required", "reason": "TLS is required for this endpoint"}
```

### CORS Origin Validation

When `security_trusted_origins` is a non-empty list, mutating requests (`POST`, `PUT`, `DELETE`) must include an `Origin` header that matches the allowlist. Safe methods (`GET`, `HEAD`, `OPTIONS`) are exempt.

```erlang
{riak_admin_api, [
    {security_trusted_origins, [<<"https://admin.example.com">>, <<"https://dashboard.internal">>]}
]}
```

Untrusted origins receive:

```json
{"status": 403, "error": "forbidden", "reason": "Origin is not allowed"}
```

#### CORS Response Headers (S5)

When `security_trusted_origins` is configured and the request `Origin` matches an entry, the response includes standard CORS headers:

- `Access-Control-Allow-Origin`: the matched origin value
- `Access-Control-Allow-Methods`: `GET, HEAD, PUT, POST, DELETE, OPTIONS`
- `Access-Control-Allow-Headers`: `Content-Type, X-Request-Id, X-Riak-Vclock, X-Riak-ClientId, If-Match, If-None-Match, If-Unmodified-Since, If-Modified-Since, Origin`
- `Access-Control-Expose-Headers`: `X-Request-Id, X-Riak-Vclock, ETag, Last-Modified, Link, Location`
- `Access-Control-Max-Age`: `3600`

When `security_trusted_origins` is empty (the default), no CORS headers are emitted. When the origin does not match, no CORS headers are emitted (the 403 rejection from origin validation takes precedence for unsafe methods; safe methods pass through without CORS headers).

### Custom Authentication Hook

Register a function to run authentication. The function receives the request context and must return one of: `ok`, `allow`, `unauthorized`, `forbidden`, or `{deny, Status, Code, Reason}`.

```erlang
{riak_admin_api, [
    {authn_hook, fun myapp_auth:check_token/1}
]}
```

The function signature can be arity-1 (receives context) or arity-2 (receives context and opts).

### Custom Authorization Hook

Same interface as `authn_hook`, but runs after authentication succeeds:

```erlang
{riak_admin_api, [
    {authz_hook, fun myapp_auth:check_permission/1}
]}
```

### Hook Return Values

| Return | HTTP Status | Error Code |
|--------|-------------|------------|
| `ok` / `allow` | -- (passes) | -- |
| `unauthorized` | 401 | `unauthorized` |
| `forbidden` | 403 | `forbidden` |
| `{deny, Status, Code, Reason}` | Custom | Custom |

---

## 12. Migration & Cutover Controls

Cutover controls allow operators to gradually migrate traffic from the legacy Webmachine API to the Cowboy API on a per-operation basis.

### Cutover Modes

| Mode | Behavior | HTTP Status |
|------|----------|-------------|
| `enabled` | Request is processed normally | -- |
| `deprecated` | Request is processed (may log deprecation warning) | -- |
| `shadow` | Request is processed (used for shadow traffic testing) | -- |
| `disabled` | Request is rejected | 503 Service Unavailable |
| `removed` | Request is rejected | 410 Gone |

### Configuration

#### Default Mode

Sets the baseline mode for all operations:

```erlang
{riak_admin_api, [
    {cowboy_cutover_default_mode, disabled}
]}
```

#### Per-Operation Overrides

Override specific operation groups independently:

```erlang
{riak_admin_api, [
    {cowboy_cutover_default_mode, disabled},
    {cowboy_cutover_op_modes, [
        {object_item, deprecated},
        {bucket_props, enabled},
        {keys, disabled},
        {mapred, shadow}
    ]}
]}
```

Operation names correspond to the `op` field in the request context:

| Operation | Description |
|-----------|-------------|
| `object_item` | Single object CRUD (`GET/PUT/POST/DELETE .../:key`) |
| `object_collection` | POST to key collection (auto-generated keys) |
| `bucket_props` | Bucket property operations |
| `bucket_type_props` | Bucket type property operations |
| `buckets` | Bucket listing |
| `keys` | Key listing |
| `counter` | Counter operations |
| `crdt_item` | Single CRDT operations |
| `crdt_collection` | CRDT collection POST |
| `index_query` | Secondary index queries |
| `query` | Advanced query language |
| `mapred` | MapReduce |

### Mode Values

Modes can be specified as atoms, binaries, or strings:

```erlang
%% All equivalent:
enabled     <<"enabled">>     "enabled"
disabled    <<"disabled">>    "disabled"
removed     <<"removed">>    "removed"
deprecated  <<"deprecated">>  "deprecated"
shadow      <<"shadow">>      "shadow"
```

### Migration Strategy

1. Start with `cowboy_cutover_default_mode = disabled` (safe default)
2. Enable specific operation groups via `cowboy_cutover_op_modes` for canary rollout
3. Use `shadow` mode on operations you want to observe without changing client behavior
4. Use `deprecated` mode to log warnings for operations being migrated
5. Use `disabled` to temporarily block operations if issues arise
6. Use `removed` for operations permanently retired from the Cowboy path

### Error Responses

**Disabled:**

```json
{"status": 503, "error": "route_cutover_disabled", "reason": "Endpoint group object_item is disabled by cutover controls"}
```

**Removed:**

```json
{"status": 410, "error": "route_removed", "reason": "Endpoint group mapred has been removed"}
```

---

## 13. Multi-DC Discovery

The Cowboy admin API includes syn-powered datacenter discovery, allowing nodes to discover each other across a distributed Riak cluster.

### How It Works

1. **Scope initialization:** On application start, `syn:add_node_to_scopes([riak_admin])` creates local ETS tables for the `riak_admin` scope.
2. **Coordinator registration:** `riak_admin_api_coordinator` (a `gen_server`) registers with syn under the key `{api_node, Node}` with metadata including DC name, ports, and version.
3. **Group membership:** The coordinator joins two syn groups:
   - `api_nodes` -- for DC discovery queries
   - `cluster_events` -- for push event notifications
4. **Event handler:** `riak_admin_event_handler` logs node discovery/departure and resolves conflicts.

### Coordinator Metadata

Each node advertises the following metadata via syn:

```erlang
#{
    dc        => <<"us-east-1">>,       %% From dc_name config
    node      => 'riak1@10.0.1.10',    %% Erlang node atom
    http_port => 8099,                   %% Cowboy listener port
    riak_http => 8098,                   %% Riak HTTP port (for proxying)
    riak_vsn  => <<"3.4.0">>,           %% Riak version
    started_at => 1708444800            %% Unix timestamp (seconds)
}
```

### Conflict Resolution

During netsplit recovery, both sides of a partition may have registered the same key. The event handler uses **oldest-process-wins** resolution:

- The process with the lowest `started_at` value is kept
- This is deterministic -- both sides converge to the same winner
- On ties, the first entry (Pid1) wins

### Stale Key Handling

After a crash+restart, the previous process's registry entry may still exist briefly. The coordinator handles this by:

1. Attempting `syn:register/4`
2. If `{error, taken}`, unregistering the stale entry
3. Sleeping 100ms if unregister returns an error (syn is still converging)
4. Retrying the registration

### Event Logging

| Event | Log Level | Message |
|-------|-----------|---------|
| Node registered | `info` | `Discovered admin API on <node> (dc=<name>)` |
| Clean shutdown | `info` | `Admin API on <node> stopped cleanly` |
| Network partition | `warning` | `DC <name> node <node> unreachable` |
| Other unregister | `notice` | `Admin API on <node> unregistered: <reason>` |

---

## 14. Endpoint Map

![Endpoint Map](architecture/cowboy-endpoint-map.svg)

### Complete Route Table

#### Admin Routes (dedicated handlers)

| Method | Path | Handler | Description |
|--------|------|---------|-------------|
| GET | `/api/ping` | `rah_ping` | Health check |
| GET | `/api/cluster/status` | `rah_cluster` | Cluster membership and status |
| GET | `/api/dcs` | `rah_dcs` | Datacenter discovery |
| GET | `/api/ring/ownership` | `rah_ring` | Ring partition-to-node mapping |
| GET | `/api/nodes/:node/stats` | `rah_nodes` | Per-node statistics |
| GET | `/api/handoff/status` | `rah_handoff` | Active handoff transfers |
| GET | `/api/aae/status` | `rah_aae` | AAE exchange status |

#### Substrate Routes -- MapReduce

| Method | Path | Route Family | Operation |
|--------|------|-------------|-----------|
| GET/HEAD | `/mapred` | `mapred` | Usage hint |
| POST | `/mapred` | `mapred` | Execute MapReduce |

#### Substrate Routes -- Legacy (`/riak`)

| Method | Path | Route Family | Operation |
|--------|------|-------------|-----------|
| GET/HEAD | `/riak` | `riak` | List buckets |
| GET/HEAD/PUT | `/riak/:bucket` | `riak` | Bucket props / key listing |
| GET/HEAD/PUT/POST/DELETE | `/riak/:bucket/:key` | `riak` | Object CRUD |

#### Substrate Routes -- Modern (`/buckets`)

| Method | Path | Route Family | Operation |
|--------|------|-------------|-----------|
| GET/HEAD | `/buckets` | `buckets` | List buckets |
| GET/HEAD/PUT/DELETE | `/buckets/:bucket/props` | `buckets` | Bucket properties |
| GET/HEAD | `/buckets/:bucket/keys` | `buckets` | List keys |
| POST | `/buckets/:bucket/keys` | `buckets` | Create object (auto key) |
| GET/HEAD/PUT/POST/DELETE | `/buckets/:bucket/keys/:key` | `buckets` | Object CRUD |
| GET/POST | `/buckets/:bucket/counters/:key` | `buckets` | Counter operations |
| POST | `/buckets/:bucket/query` | `buckets` | Query language |
| GET/HEAD | `/buckets/:bucket/index/:field/:term` | `buckets` | 2i exact query |
| GET/HEAD | `/buckets/:bucket/index/:field/:start/:end` | `buckets` | 2i range query |

#### Substrate Routes -- Typed (`/types`)

| Method | Path | Route Family | Operation |
|--------|------|-------------|-----------|
| GET/HEAD/PUT | `/types/:type/props` | `types` | Bucket type properties |
| GET/HEAD | `/types/:type/buckets` | `types` | List buckets in type |
| GET/HEAD/PUT/DELETE | `/types/:type/buckets/:bucket/props` | `types` | Bucket properties (typed) |
| GET/HEAD | `/types/:type/buckets/:bucket/keys` | `types` | List keys |
| POST | `/types/:type/buckets/:bucket/keys` | `types` | Create object (auto key) |
| GET/HEAD/PUT/POST/DELETE | `/types/:type/buckets/:bucket/keys/:key` | `types` | Object CRUD |
| POST | `/types/:type/buckets/:bucket/datatypes` | `types` | Create CRDT (auto key) |
| GET/HEAD/POST | `/types/:type/buckets/:bucket/datatypes/:key` | `types` | CRDT operations |
| POST | `/types/:type/buckets/:bucket/query` | `types` | Query language |
| GET/HEAD | `/types/:type/buckets/:bucket/index/:field/:term` | `types` | 2i exact query |
| GET/HEAD | `/types/:type/buckets/:bucket/index/:field/:start/:end` | `types` | 2i range query |

---

## 15. Configuration Reference

All configuration is under the `riak_admin_api` application key. Set values in `advanced.config` or `sys.config`.

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `http_port` | `pos_integer()` | `8099` | Port for the Cowboy HTTP listener. Auto-computed as `100N5` in devrel. |
| `dc_name` | `binary()` | `<<"default">>` | Datacenter name advertised via syn for multi-DC discovery. |
| `riak_http_port` | `pos_integer()` | `8098` | Local Riak HTTP port stored in syn metadata. Auto-computed as `100N8` in devrel. |
| `cowboy_cutover_default_mode` | `atom()` | `disabled` | Default cutover mode for all operations. Values: `enabled`, `deprecated`, `shadow`, `disabled`, `removed`. |
| `cowboy_cutover_op_modes` | `list() \| map()` | `[]` | Per-operation cutover overrides. Proplist of `{OpAtom, Mode}` or equivalent map. |
| `security_require_tls` | `boolean()` | `false` | Require HTTPS semantics for requests to proceed. |
| `security_trust_proxy_headers` | `boolean()` | `false` | Trust `X-Forwarded-Proto`; must be `true` when TLS terminates at a trusted proxy. |
| `security_trusted_origins` | `[binary()]` | `[]` | List of allowed `Origin` header values for mutating requests. Empty list disables check. |
| `security_require_auth` | `boolean()` | `false` | Fail closed with `503 auth_not_configured` when auth is required but hooks are not configured. |
| `authn_hook` | `fun/1\|fun/2\|{M,F}\|{M,F,2}` | `undefined` | Authentication hook used by request normalization. |
| `authz_hook` | `fun/1\|fun/2\|{M,F}\|{M,F,2}` | `undefined` | Authorization hook used by request normalization. |
| `max_request_body_bytes` | `integer()` | `5242880` | Request body size limit; larger payloads return `413 payload_too_large`. Enforced on both chunked reads and pre-populated body paths (S5). |
| `list_keys_error_mode` | `compat\|strict` | `compat` | `compat` returns `200` with embedded error for list-keys failures; `strict` returns HTTP error status. |
| `stream_incremental_enabled` | `boolean()` | `true` | Enable incremental chunked streaming for stream-mode keys/index/mapred/buckets responses. |
| `mapred_backend_enabled` | `boolean()` | `true` | Operator toggle for mapreduce execution (`false` returns `503 service_unavailable`). |

### Full Example Configuration

```erlang
{riak_admin_api, [
    {http_port, 8099},
    {dc_name, <<"us-east-1">>},
    {riak_http_port, 8098},
    {cowboy_cutover_default_mode, disabled},
    {cowboy_cutover_op_modes, [
        {mapred, deprecated},
        {keys, enabled},
        {object_item, enabled}
    ]},
    {security_require_tls, true},
    {security_trust_proxy_headers, true},
    {security_require_auth, true},
    {authn_hook, fun myapp_auth:check_token/1},
    {authz_hook, fun myapp_auth:check_permission/1},
    {security_trusted_origins, [
        <<"https://admin.example.com">>
    ]},
    {stream_incremental_enabled, true},
    {mapred_backend_enabled, true}
]}
```

---

## 16. Error Response Format

All errors follow a consistent JSON structure:

```json
{
  "status": 404,
  "error": "not_found",
  "reason": "not found",
  "request_id": "riak-admin-42"
}
```

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `status` | integer | HTTP status code |
| `error` | string | Machine-readable error code |
| `reason` | string | Human-readable description |
| `request_id` | string | Request tracking ID (from `X-Request-Id` header or auto-generated) |
| `details` | any | Optional additional details (present when available) |

### Error Code Reference

| Error Code | HTTP Status | Description |
|------------|-------------|-------------|
| `not_found` | 404 | Object or resource not found |
| `bucket_type_unknown` | 404 | Bucket type does not exist |
| `unknown_node` | 404 | Node name not recognized |
| `unknown_route` | 404 | Path does not match any route |
| `method_not_allowed` | 405 | HTTP method not supported for this endpoint |
| `missing_content_type` | 400 | PUT/POST missing Content-Type header |
| `invalid_body` | 400 | Request body is malformed or missing |
| `invalid_props` | 400 | Invalid bucket properties |
| `invalid_query` | 400 | Invalid query parameters or query body |
| `invalid_vclock` | 400 | Invalid vector clock in header |
| `invalid_quorum` | 400 | Quorum values exceed n_val |
| `invalid_operation` | 400 | Unsupported operation |
| `invalid_datatype` | 400 | Bucket is not configured for CRDTs |
| `forbidden` | 403 | Access denied (pre-commit hook or authz) |
| `unauthorized` | 401 | Authentication required |
| `tls_required` | 426 | TLS is required but request is not HTTPS |
| `conflict` | 409 | Object was modified (conditional put) |
| `precondition_failed` | 412 | Conditional operation failed |
| `timeout` | 503 | Request timed out |
| `quorum_unsatisfied` | 503 | Read/write quorum could not be met |
| `node_unreachable` | 503 | Remote node did not respond |
| `backend_unavailable` | 503 | Riak client unavailable |
| `backend_error` | 500 | Internal error in Riak backend |
| `json_encoding_error` | 500 | Response JSON encoding failed |
| `security_hook_error` | 500 | Security hook returned invalid value |
| `not_implemented` | 501 | Operation deferred to a later batch / backend unavailable |
| `route_cutover_disabled` | 503 | Endpoint disabled by cutover controls |
| `route_removed` | 410 | Endpoint removed by cutover controls |
| `dc_discovery_error` | 500 | syn DC discovery failed |

### Response Headers on Errors

Error responses include a standard set of compatibility headers:

| Header | Condition |
|--------|-----------|
| `X-Request-Id` | Always present |
| `Allow` | Present on 405 responses, comma-separated list of valid methods |
| `X-Riak-Vclock` | Present when a deleted object's vclock is available |
| `Content-Type` | Always `application/json; charset=utf-8` |

---

## 17. Route Compatibility

The Cowboy API provides three path families that correspond to the evolution of Riak's HTTP API:

### Path Family Mapping

| API Version | Prefix | Bucket Type | Notes |
|-------------|--------|-------------|-------|
| v1 (legacy) | `/riak` | Always `default` | Original Riak API path |
| v2 (modern) | `/buckets` | Always `default` | Introduced with bucket types |
| v3 (typed) | `/types/:type/buckets` | Explicit | Full bucket type support |

### Equivalent Operations Across Families

| Operation | v1 (`/riak`) | v2 (`/buckets`) | v3 (`/types`) |
|-----------|-------------|----------------|---------------|
| Get object | `GET /riak/B/K` | `GET /buckets/B/keys/K` | `GET /types/T/buckets/B/keys/K` |
| Put object | `PUT /riak/B/K` | `PUT /buckets/B/keys/K` | `PUT /types/T/buckets/B/keys/K` |
| Delete object | `DELETE /riak/B/K` | `DELETE /buckets/B/keys/K` | `DELETE /types/T/buckets/B/keys/K` |
| Create object | `POST /riak/B` | `POST /buckets/B/keys` | `POST /types/T/buckets/B/keys` |
| Bucket props | `GET /riak/B` | `GET /buckets/B/props` | `GET /types/T/buckets/B/props` |
| Set props | `PUT /riak/B` | `PUT /buckets/B/props` | `PUT /types/T/buckets/B/props` |
| Delete props | n/a | `DELETE /buckets/B/props` | `DELETE /types/T/buckets/B/props` |
| List keys | `GET /riak/B?keys=true` | `GET /buckets/B/keys?keys=true` | `GET /types/T/buckets/B/keys?keys=true` |
| List buckets | `GET /riak?buckets=true` | `GET /buckets?buckets=true` | `GET /types/T/buckets?buckets=true` |

### Key Differences from Webmachine

| Aspect | Webmachine | Cowboy |
|--------|-----------|--------|
| Default port | 10018 | 8099 |
| Admin endpoints | Same port, various paths | Dedicated `/api/*` paths |
| Error format | Varies (text, HTML, JSON) | Always structured JSON with `request_id` |
| Request tracking | None | Auto-generated `X-Request-Id` (or client-provided) |
| DC discovery | Not available | Built-in via `/api/dcs` |
| Cutover controls | Not available | Per-operation mode switching |
| Security hooks | Riak security module | Pluggable `authn_hook`/`authz_hook` functions |
| CORS validation | Not available | `security_trusted_origins` allowlist |
| TLS enforcement | Separate listener | `security_require_tls` + optional trusted proxy headers (`security_trust_proxy_headers`) |

### Behavioral Differences

1. **`/riak/:bucket` path resolution:** The `/riak/:bucket` path serves dual purpose depending on query parameters:
   - `?keys=true` or `?keys=stream` -- key listing
   - `?props=true` (default) -- bucket properties
   - `POST` without keys param -- create object (collection mode)

2. **Key listing on `/riak` includes bucket props by default.** The v2/v3 paths do not include props in key listings.

3. **Link headers** use path-family-appropriate URIs. A link returned via `/riak/B/K` uses `/riak/B2/K2` format; the same link via `/types/T/buckets/B/keys/K` uses `/types/T/buckets/B2/keys/K2` format.

4. **Bucket property deletion** is not available on the `/riak` path family (methods limited to GET, HEAD, PUT).

5. **The `asis` and `sync_on_write` query parameters** are accepted on all object operations but are not in the restricted query key lists -- they pass through unrestricted (the `allowed_query_keys` for `object_item` returns `all`).
