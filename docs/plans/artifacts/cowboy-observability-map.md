# Cowboy Observability Map (B07)

Date: 2026-02-19  
Batch: B07  
Branch: `feature/cowboy-b07-verification-perf`

## Goals

- Define endpoint-level observability coverage for Cowboy substrate routes.
- Make route/op/status/latency/error dimensions explicit.
- Document request-id propagation trace points for end-to-end correlation.

## Existing Instrumentation Anchors

- `riak_admin_api_request:normalize/2`
  - Ingests or generates `request_id`.
  - Attaches normalized `op`, `alias`, `route`, and query context.
- `riak_admin_api_handler:response_opts/2`
  - Passes `request_id` and `telemetry_context` to response layer.
- `riak_admin_api_response:telemetry_tags/3`
  - Emits telemetry tag map with `route`, `op`, `alias`, `error_code`, `status`, `duration_us`.
- `riak_admin_api_response:compat_headers/1`
  - Returns `x-request-id` on all successful/error responses.
- `riak_admin_api_response:error_payload/4`
  - Includes `request_id` in JSON error body.

## Route and Operation Mapping

| Endpoint family | External route template(s) | Normalized operation(s) | Backend action(s) | Current telemetry dimensions |
|---|---|---|---|---|
| Object CRUD | `/riak/:bucket/:key`, `/buckets/:bucket/keys/:key`, `/types/:bucket_type/buckets/:bucket/keys/:key`, create aliases (`/riak/:bucket`, `/buckets/:bucket/keys`, `/types/:bucket_type/buckets/:bucket/keys`) | `object_item`, `object_collection` | `object_operation(get|put|post|delete|create, ...)` | `route`, `op`, `alias`, `status`, `duration_us` |
| Bucket listing/props | `/riak`, `/buckets`, `/types/:bucket_type/buckets`, `/riak/:bucket`, `/buckets/:bucket/props`, `/types/:bucket_type/buckets/:bucket/props`, `/types/:bucket_type/props` | `buckets`, `bucket_props`, `bucket_type_props` | `bucket_operation(list_buckets|get_bucket_props|set_bucket_props|delete_bucket_props|get_bucket_type_props|set_bucket_type_props, ...)` | same |
| Keys + 2i | `/riak/:bucket?keys=...`, `/buckets/:bucket/keys`, `/types/:bucket_type/buckets/:bucket/keys`, `/buckets/:bucket/index/:field/:term_or_range`, `/types/:bucket_type/buckets/:bucket/index/:field/:term_or_range` | `keys`, `index_query` | `bucket_operation(list_keys|index_query, ...)` | same |
| Query + mapreduce | `/buckets/:bucket/query`, `/types/:bucket_type/buckets/:bucket/query`, `/mapred` | `query`, `mapred` | `bucket_operation(query|mapred, ...)` | same |
| Counter + CRDT | `/buckets/:bucket/counters/:key`, `/types/:bucket_type/buckets/:bucket/datatypes`, `/types/:bucket_type/buckets/:bucket/datatypes/:key` | `counter`, `crdt_collection`, `crdt_item` | `bucket_operation(counter_get|counter_update|crdt_create|crdt_fetch|crdt_update, ...)` | same |

## Request-ID Propagation Trace Points

1. Client inbound:
   - Header `x-request-id` read in `normalize_headers/1`.
   - Missing/empty value replaced by generated ID (`riak-admin-<unique>`).
2. Normalized context:
   - `request_id` stored in request context in `normalize/2`.
3. Handler response pipeline:
   - `response_opts/2` passes `request_id` into all reply paths.
4. Outbound response:
   - Header `x-request-id` attached by `compat_headers/1`.
   - Error JSON includes `request_id` via `error_payload/4`.
5. Telemetry/log:
   - `maybe_log_telemetry/3` logs `substrate_telemetry` tags with per-request context.

## Required Metrics and Log Tags (B08 Gate Input)

Required dimensions to collect and retain:

- `route` (external matched path)
- `op` (normalized operation)
- `alias` (`riak|buckets|types|mapred`)
- `error_code` (when request ends in a classified error path)
- `status` (HTTP status)
- `duration_us` (per-request latency)
- `request_id` (log/header/error correlation key)

Recommended extensions for post-cutover hardening:

- `method` and `stream_mode` for hotspot diagnosis.
- `backend_action` for operation-to-gateway cardinality checks.

## Alert Suggestions

`Warning` thresholds:

- p95 `duration_us` exceeds baseline by >50% for 10 minutes.
- 4xx rate above 5% per operation family (excluding expected auth/security endpoints).

`Critical` thresholds:

- 5xx rate above 1% for 5 minutes on any of: `object_item`, `keys`, `index_query`, `counter`, `crdt_item`, `query`, `mapred`.
- Timeout-class errors (`timeout`, quorum timeout variants) above 0.5% for 5 minutes.
- Missing `x-request-id` in response headers above 0.1% sampled requests.

## Known Observability Gaps

- Structured metrics sink is not wired in this batch; telemetry output is logger-based and must be scraped/forwarded by deployment tooling.
- Streaming is incremental by default; chunk-level telemetry spans are still not emitted (request-level telemetry only).
