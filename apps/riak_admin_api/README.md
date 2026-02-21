# riak_admin_api -- Architecture Reference

## 1. Overview

`riak_admin_api` is an OTP application that provides a REST API for Riak cluster
administration. It runs on Cowboy 2.x alongside Riak's existing Webmachine/Mochiweb
HTTP stack. The two servers coexist during a migration period:

- **Webmachine** serves the data-path API (bucket/key CRUD) on port 10018 (default).
- **Cowboy** serves admin endpoints and, optionally, substrate data-path routes on a
  separate port (default 8099).

The reasons for a parallel stack:

1. New endpoints are built on Cowboy from the start; existing Webmachine routes
   continue to work unchanged.
2. Admin traffic is isolated from data traffic -- a slow admin query cannot starve
   KV read/write operations.
3. Operators can apply separate firewall rules to the admin port (e.g. restrict to
   management networks).
4. Cowboy provides a modern HTTP/1.1 and HTTP/2 stack with native WebSocket
   support and active upstream maintenance.

The long-term goal is full migration of all Riak HTTP handling from Webmachine to
Cowboy. Substrate routes (see Section 8) expose the same data-path operations on the
Cowboy listener, gated by cutover controls (see Section 7) so that operators can
migrate at their own pace.

---

## 2. Module Map

See [`doc/diagrams/module-architecture.excalidraw`](doc/diagrams/module-architecture.excalidraw)
for a visual layout. 15 modules organized by layer.

### Application layer

| Module | Description |
|--------|-------------|
| `riak_admin_api_app` | OTP application callback; starts Cowboy listener, compiles routes, initializes syn |
| `riak_admin_api_sup` | Top-level supervisor (rest_for_one: listener + coordinator) |
| `riak_admin_api_coordinator` | gen_server owning the syn registration for this node |

### Admin handlers (`rah_*`)

| Module | Route | Description |
|--------|-------|-------------|
| `rah_ping` | `GET /api/ping` | Liveness probe returning node name and status |
| `rah_cluster` | `GET /api/cluster/status` | Cluster membership, ring percentage, reachability, remote DCs |
| `rah_dcs` | `GET /api/dcs` | Datacenter discovery via syn group membership |
| `rah_ring` | `GET /api/ring/ownership` | Full partition-to-node mapping of the hash ring |
| `rah_nodes` | `GET /api/nodes/:node/stats` | Per-node VM and riak_kv statistics (local or RPC) |
| `rah_handoff` | `GET /api/handoff/status` | Active handoff transfers with count |
| `rah_aae` | `GET /api/aae/status` | Active anti-entropy exchanges with count |
| `rah_events_ws` | `WS /api/stream/events` | WebSocket event streaming with topic subscriptions |

See [`doc/diagrams/websocket-event-flow.excalidraw`](doc/diagrams/websocket-event-flow.excalidraw) for the event flow from sources through the bridge to WebSocket clients.

### Pipeline (request/response)

| Module | Description |
|--------|-------------|
| `riak_admin_api_handler` | Cowboy handler for substrate routes; normalizes, dispatches, formats replies |
| `riak_admin_api_request` | Request normalization: headers, query params, path routing, cutover, security |
| `riak_admin_api_response` | Response serialization: JSON, raw, streaming, CORS, compat headers, telemetry |

### Backend (Riak gateway)

| Module | Description |
|--------|-------------|
| `riak_admin_api_riak` | Sole gateway to riak_core, riak_kv, and riak_object internals |

### Infrastructure

| Module | Description |
|--------|-------------|
| `riak_admin_event_handler` | syn event handler: node discovery, departure logging, conflict resolution |

---

## 3. Request Lifecycle

See [`doc/diagrams/request-lifecycle.excalidraw`](doc/diagrams/request-lifecycle.excalidraw)
for a visual overview.

### Admin endpoints (`rah_*`)

```
HTTP request
  -> Cowboy dispatch (route matched to rah_* module)
  -> rah_*:init/2
  -> ensure_admin_get(Req)
       |-> ensure_get: reject non-GET with 405
       |-> normalize_headers: lowercase keys, extract/generate X-Request-Id
       |-> ensure_security: TLS -> origin -> auth guardrails -> authn -> authz
  -> gateway call: riak_admin_api_riak:<function>/0..1
  -> json_reply or error_reply
  -> HTTP response
```

**Cluster status ping collection** uses deadline-based timeouts. `collect_ping_results/4`
computes an absolute deadline at the start and uses the remaining time for each
`receive`, preventing timeout drift when responses arrive at staggered intervals.

### Substrate endpoints (`riak_admin_api_handler`)

```
HTTP request
  -> Cowboy dispatch (route matched to riak_admin_api_handler, with route_family in opts)
  -> init/2
  -> normalize_request(Req, Opts)
       |-> normalize_headers: lowercase, extract/generate request ID, sanitize
       |-> normalize_query: parse query string, validate booleans/quorums/timeouts
       |-> normalize_path: map URL segments to {op, alias, bucket_type, bucket, key, ...}
       |-> ensure_allowed_query: reject unknown query params per operation
       |-> ensure_allowed_method: reject disallowed HTTP methods per operation+alias
       |-> ensure_cutover: check operation against cutover mode (fail-closed default)
       |-> ensure_security: TLS -> origin -> auth guardrails -> authn hook -> authz hook
  -> dispatch(Context)
       |-> route to operation handler by Context.op
       |-> validate HTTP method
       |-> read request body (if needed), enforce max_request_body_bytes
       |-> resolve backend (configurable or default riak_admin_api_riak)
       |-> execute backend function
  -> reply
       |-> reply_object: standard response with compat headers
       |-> reply_stream: chunked streaming (key lists, mapreduce, index results)
       |-> reply_error_map: structured error JSON
  -> HTTP response
```

The pipeline short-circuits on the first error at any stage, returning a structured
JSON error with status code, error code, reason, and request ID.

---

## 4. Supervision Tree

See [`doc/diagrams/supervision-tree.excalidraw`](doc/diagrams/supervision-tree.excalidraw).

```
riak_admin_api_sup (rest_for_one, intensity=5, period=10)
  |
  +-- riak_admin_http          (ranch/cowboy listener, child spec from ranch:child_spec/5)
  |
  +-- riak_admin_api_coordinator  (gen_server, permanent, shutdown=5000)
```

**Strategy: `rest_for_one`**

If the listener crashes, the coordinator is also restarted because it depends on
the listener being available. The coordinator re-registers with syn on restart
(with stale-key retry to handle the brief window where the previous registration
may still exist).

**Listener child spec** is built by `riak_admin_api_app:listener_child_spec/2` using
`ranch:child_spec/5` and passed into the supervisor. This ensures the Cowboy listener
is supervised -- a listener crash triggers automatic restart rather than silent
unavailability.

---

## 5. syn Integration

See [`doc/diagrams/syn-discovery.excalidraw`](doc/diagrams/syn-discovery.excalidraw)
for the discovery flow.

The application uses [syn](https://github.com/ostinelli/syn) 3.3.0 for distributed
process registration and group-based node discovery.

### Scope

All syn operations use the `riak_admin` scope. The scope is initialized in
`riak_admin_api_app:start/2` via `syn:add_node_to_scopes([riak_admin])` before
the supervisor tree starts.

### Registry

Each node registers under key `{api_node, Node}` with metadata:

| Field | Type | Description |
|-------|------|-------------|
| `dc` | binary | Datacenter name (from app env `dc_name`) |
| `node` | node() | Erlang node atom |
| `http_port` | pos_integer | Admin API port (Cowboy) |
| `riak_http` | pos_integer | Riak HTTP port (Webmachine, for proxying) |
| `riak_vsn` | binary | Riak version string |
| `started_at` | non_neg_integer | erlang:system_time(second) at registration |

### Groups

| Group | Purpose |
|-------|---------|
| `api_nodes` | Discovery -- `syn:members/2` returns all admin API nodes |
| `cluster_events` | Push notifications -- `syn:publish/3` broadcasts events |

### Conflict resolution

`riak_admin_event_handler:resolve_registry_conflict/4` picks the oldest process
(lowest `started_at`). This is deterministic: both sides of a netsplit converge
to the same winner.

### Crash recovery (stale-key retry)

After a crash and restart, the previous process's registry entry may still exist
briefly while syn processes the DOWN signal. `register_with_syn/1` handles
`{error, taken}` by unregistering the stale entry and retrying once. If
`syn:unregister/2` returns `{error, undefined}` or `{error, race_condition}`
(syn already cleaned up or cluster is syncing), a 100ms pause lets syn converge
before the final retry.

---

## 6. Security Model

The security pipeline runs in `riak_admin_api_request:ensure_security/2`, applied
to both admin and substrate endpoints.

### Pipeline order

1. **TLS enforcement** (`ensure_tls`) -- When `security_require_tls` is true, the
   request must arrive over TLS. If `trust_proxy_headers` is true, the
   `X-Forwarded-Proto: https` header is accepted. Otherwise, the check fails
   closed (426 Upgrade Required).

2. **Origin validation** (`ensure_origin`) -- When `security_trusted_origins` is
   configured (non-empty list) and the HTTP method is unsafe (not GET/HEAD/OPTIONS),
   the `Origin` header must be present and match one of the trusted origins.
   Missing origin on unsafe methods is denied (403).

3. **Auth guardrails** (`ensure_auth_guardrails`) -- When `security_require_auth`
   is true but no `authn_hook` or `authz_hook` is configured, requests are
   rejected with 503. This prevents accidental unprotected operation in
   production deployments.

4. **Authentication hook** (`authn_fun`) -- If configured, called with the
   request context. Must return `ok`, `allow`, `unauthorized`, `forbidden`, or
   `{deny, Status, Code, Reason}`.

5. **Authorization hook** (`authz_fun`) -- Same interface as authn. The context
   includes `route` and `op` so hooks can make endpoint-level decisions.

Hook formats: `fun/1`, `fun/2`, `{Module, Function}`, or `{Module, Function, 2}`.
All hooks are wrapped in try/catch -- a crashing hook returns 500 rather than
taking down the handler.

### Header sanitization

- All response header values are stripped of control characters (0x00-0x1F, 0x7F)
  at every Cowboy response exit point to prevent HTTP response splitting and CRLF
  injection.
- Client-supplied `X-Request-Id` is sanitized: truncated to 200 bytes, control
  characters removed.

### Request ID

Every request gets a unique ID. If `X-Request-Id` is provided, it is sanitized
and used. Otherwise, one is generated as `riak-admin-<monotonic_integer>`. The ID
is included in all responses as the `X-Request-Id` header and in error payloads.

### Timeout caps

All client-controlled timeouts are capped via `cap_timeout/2` to prevent indefinite
resource holds:

- **Query-string `timeout` params** — capped at `max_server_timeout_ms` (default
  300000ms / 5 minutes).
- **POST body timeouts** — complex query requests (`make_complex_query/2`) cap the
  timeout embedded in the JSON body at `stream_collection_ceiling()`.
- **MapReduce timeouts** — `mapred_operation_legacy/2` caps the timeout parsed by
  `riak_kv_mapred_json:parse_request/1` via `cap_timeout/2`.

See [`doc/diagrams/security-pipeline.excalidraw`](doc/diagrams/security-pipeline.excalidraw)
for a visual overview of the security pipeline, including timeout enforcement points.

### Startup audit

`audit_security_posture/0` logs warnings on startup when auth or TLS is not
configured, providing operational visibility without blocking startup.

---

## 7. Cutover Control

Substrate routes (data-path operations exposed on the Cowboy listener) are gated
by a cutover system that controls which operations are active.

### Modes

| Mode | HTTP behavior |
|------|---------------|
| `enabled` | Request proceeds normally |
| `disabled` | 503 Service Unavailable (`route_cutover_disabled`) |
| `deprecated` | Request proceeds (functionally equivalent to enabled) |
| `shadow` | Request proceeds (functionally equivalent to enabled) |
| `removed` | 410 Gone (`route_removed`) |

### Resolution order

1. Look up the operation (`op` atom) in `cowboy_cutover_op_modes` (per-operation overrides).
2. If not found, fall back to `cowboy_cutover_default_mode`.
3. If the default mode is invalid, log an error and default to `disabled`.
4. If a per-operation mode is invalid, return 503 (`route_cutover_misconfigured`).

### Fail-closed default

The `.app.src` sets `cowboy_cutover_default_mode` to `disabled`. Operators must
explicitly enable substrate routes by setting the default mode to `enabled` or by
adding per-operation overrides. This prevents accidental exposure of data-path
operations on the admin port.

### Mode normalization

Modes can be specified as atoms, binaries, or strings (for config file flexibility).
All are normalized to atoms internally.

---

## 8. Route Families

Routes are defined in `riak_admin_api_app:routes/0`, split into two groups.

### Admin routes

Dedicated Cowboy handlers with the `rah_` prefix. GET-only. Each handler calls
`ensure_admin_get/1` for method + security enforcement.

| Path | Handler |
|------|---------|
| `/api/ping` | `rah_ping` |
| `/api/cluster/status` | `rah_cluster` |
| `/api/dcs` | `rah_dcs` |
| `/api/ring/ownership` | `rah_ring` |
| `/api/nodes/:node/stats` | `rah_nodes` |
| `/api/handoff/status` | `rah_handoff` |
| `/api/aae/status` | `rah_aae` |

### Substrate routes

All handled by `riak_admin_api_handler` with a `route_family` in the route opts.
Path routing in `normalize_path/3` maps URL segments to operations.

| Family | Prefix | Alias version | Description |
|--------|--------|---------------|-------------|
| `mapred` | `/mapred` | 2 | MapReduce compatibility endpoint |
| `riak` | `/riak[/:bucket[/:key]]` | 1 | Legacy alias family (v1 API) |
| `buckets` | `/buckets/...` | 2 | Default-type modern alias family |
| `types` | `/types/:bucket_type/...` | 3 | Typed modern alias family |

### Operations

Each substrate path resolves to an operation atom that drives dispatch:

| Operation | Description |
|-----------|-------------|
| `bucket_props` | Get/set/delete bucket properties |
| `bucket_type_props` | Get/set bucket type properties |
| `buckets` | List buckets |
| `keys` | List keys in a bucket |
| `counter` | Get/update legacy counters |
| `crdt_item` | Fetch/update a CRDT by key |
| `crdt_collection` | Create a new CRDT (POST) |
| `query` | Riak query (POST with JSON body) |
| `index_query` | Secondary index query (exact match or range) |
| `mapred` | MapReduce job submission (phase types validated: map, reduce, link) |
| `object_item` | Get/put/post/delete a single object |
| `object_collection` | Create an object with server-generated key |

**MapReduce validation.** `validate_mapred_body/1` checks that each query phase
uses an allowed type (`map`, `reduce`, `link`) before delegating to
`riak_kv_mapred_json`. Invalid phase types are rejected with a 400 before
execution begins.

---

## 9. Response Formatting

All HTTP responses flow through `riak_admin_api_response`.

### JSON replies

`json_reply/4` encodes data with `jsx:encode/1`, sets `Content-Type:
application/json; charset=utf-8`, attaches compatibility headers, and logs
telemetry. If encoding fails, a fallback 500 error is returned.

### Raw replies

`raw_reply/5` sends pre-encoded bodies with caller-specified content types and
extra headers. Used for object GET responses where content type comes from the
stored object metadata.

### Streaming (chunked)

For large result sets (key lists, index results, mapreduce chunks):

1. `stream_reply_init/4` starts the chunked response via `cowboy_req:stream_reply/3`.
2. `stream_reply_body/3` sends each chunk via `cowboy_req:stream_body/3`.
3. The final chunk uses `fin` to signal completion.

The handler wraps streaming in try/catch. On emission failure, a JSON error chunk
is sent as the final frame.

Bucket stream collectors (`collect_stream_buckets_loop/3`, `stream_buckets_chunked_loop/3`)
handle generic backend errors via `{ReqId, {error, Reason}}` — not just timeouts. This
matches the error pattern already used in key stream collection.

### Error payloads

All errors are JSON objects with a consistent shape:

```json
{
  "status": 404,
  "error": "not_found",
  "reason": "not found",
  "request_id": "riak-admin-123"
}
```

Non-binary internal error reasons are sanitized to `"Internal server error"` with
a warning log, preventing internal term leakage to clients.

### CORS

When `security_trusted_origins` is configured and the request `Origin` matches,
the response includes:

- `Access-Control-Allow-Origin: <origin>`
- `Access-Control-Allow-Methods: GET, HEAD, PUT, POST, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type, X-Request-Id, X-Riak-Vclock, Authorization, ...`
- `Access-Control-Expose-Headers: X-Request-Id, X-Riak-Vclock, ETag, ...`
- `Access-Control-Max-Age: 3600`

When no origin policy is configured, no CORS headers are emitted.

### Compatibility headers

Responses include Riak-specific headers when present in the backend reply:

- `X-Request-Id` -- always present
- `X-Riak-Vclock` -- vector clock (base64)
- `ETag` -- vtag from object metadata
- `Last-Modified` -- from object metadata
- `Link` -- Riak link header
- `Allow` -- on 405 responses

### Telemetry

Every response logs a debug-level telemetry event with: route, operation, alias,
error code (if any), HTTP status, and duration in microseconds.

---

## 10. Configuration Reference

All keys live under the `riak_admin_api` application environment.

### Core

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `http_port` | pos_integer | 8099 | Admin API listener port |
| `riak_http_port` | pos_integer | 8098 | Local Riak HTTP port (stored in syn metadata) |
| `dc_name` | binary | `<<"default">>` | Datacenter name for multi-DC identification |

### Cutover

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cowboy_cutover_default_mode` | atom/binary/string | `disabled` | Default cutover mode for substrate routes |
| `cowboy_cutover_op_modes` | proplist or map | `[]` | Per-operation cutover overrides: `[{op_atom, mode}, ...]` |

### Security

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `security_require_tls` | boolean | false | Reject requests not arriving over TLS |
| `security_trust_proxy_headers` | boolean | false | Trust X-Forwarded-Proto for TLS detection |
| `security_trusted_origins` | [binary()] | [] | Allowed Origin headers for CORS and unsafe methods |
| `security_require_auth` | boolean | false | Reject requests when auth hooks are not configured |
| `authn_hook` | fun/1 \| fun/2 \| {M,F} \| undefined | undefined | Authentication callback |
| `authz_hook` | fun/1 \| fun/2 \| {M,F} \| undefined | undefined | Authorization callback |

### Cowboy listener

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cowboy_max_connections` | pos_integer | 1024 | Maximum concurrent connections |
| `cowboy_idle_timeout` | pos_integer (ms) | 60000 | Close idle keep-alive connections after this duration |
| `cowboy_request_timeout` | pos_integer (ms) | 30000 | Maximum time to receive a complete request |
| `cowboy_max_keepalive` | pos_integer | 100 | Maximum requests per keep-alive connection |
| `cowboy_max_header_name_length` | pos_integer | 64 | Reject headers with names exceeding this byte count |
| `cowboy_max_header_value_length` | pos_integer | 4096 | Reject headers with values exceeding this byte count |
| `cowboy_max_headers` | pos_integer | 100 | Maximum number of headers per request |

### Request limits

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `max_request_body_bytes` | pos_integer | 5242880 (5 MB) | Maximum request body size |
| `max_server_timeout_ms` | pos_integer | 300000 (5 min) | Cap on client-requested timeout values |

### Cluster status

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `cluster_status_ping_timeout` | pos_integer (ms) | 3000 | Timeout for parallel node pings in cluster_status |

---

## 11. Dependencies

Declared in `riak_admin_api.app.src` under `applications`:

| Dependency | Version | Purpose |
|-----------|---------|---------|
| cowboy | 2.12.0 | HTTP/1.1 and HTTP/2 server |
| jsx | 3.1.0 | JSON encoding/decoding |
| syn | 3.3.0 | Distributed process registry and groups for DC discovery |

**Not listed:** `riak_core` and `riak_kv` are resolved at runtime only. They are
not OTP application dependencies. The gateway module (`riak_admin_api_riak`) has
compile-time dependencies on riak_kv headers (`-include_lib` directives) but no
other module references Riak internals.

---

## 12. Port Map

### Devrel assignment pattern

In a devrel cluster, each node is named `devN@127.0.0.1`. Ports follow the `100N_`
pattern:

| Offset | Service | Example (dev1) |
|--------|---------|----------------|
| 100N5 | Admin API (Cowboy) | 10015 |
| 100N6 | Cluster manager | 10016 |
| 100N7 | Protocol Buffers | 10017 |
| 100N8 | HTTP (Webmachine) | 10018 |
| 100N9 | Handoff | 10019 |

Port resolution logic is in `riak_admin_api_app:resolve_devrel_port/3`. It
parses the node name against `^dev([0-9]+)@` and computes `10000 + N*10 + Offset`.
Non-devrel nodes (including production single-node) use the configured `http_port`
default.

### Production

Use the `http_port` application env key (default 8099). Override via
`etc/advanced.config`:

```erlang
[{riak_admin_api, [{http_port, 9099}]}].
```

---

## 13. Isolation Pattern

A single module -- `riak_admin_api_riak` -- is the sole gateway to Riak internals
(`riak_core`, `riak_kv`, `riak_object`, `riak_client`). No other module in
`riak_admin_api` may call these modules directly.

### Why this matters

- The `.app.src` deliberately excludes `riak_core` and `riak_kv` from the
  `applications` list. They are runtime hosts, not OTP dependencies.
- Every handler is testable in isolation. Swap the gateway for a mock and Cowboy
  still works.
- Extraction to a standalone repository requires copying the `riak_admin_api`
  directory and providing riak_kv headers at compile time.

### Compile-time dependencies

The gateway module uses `-include_lib` for:
- `riak_kv/src/riak_kv_wm_raw.hrl` (JSON field macros)
- `riak_kv/include/riak_kv_index.hrl` (index query macros)
- `riak_kv/include/riak_kv_types.hrl` (CRDT record definitions)

These require riak_kv source on the code path at compile time. The runtime
isolation principle still holds.

### Verification

Run before every commit to check for leaks:

```bash
grep -rn "riak_core\|riak_kv\|riak_object\|riak:local" \
  apps/riak_admin_api/src/ \
  | grep -v riak_admin_api_riak.erl
```

Should return zero results.

### Error handling

Every public function in the gateway returns `{ok, Data}` or `{error, Reason}`.
Exceptions from Riak internals are caught and wrapped so that handlers never see
raw crashes -- they get a clean error tuple to format into an appropriate HTTP
response.
