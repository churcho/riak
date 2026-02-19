# Cowboy Query and MapReduce Parity Notes (B05)

Date: 2026-02-19
Batch: B05
Branch: `feature/cowboy-b05-query-mapred`

## Implemented in B05

- Added Cowboy substrate route declarations for query/mapreduce paths:
  - `/mapred`
  - `/buckets/:bucket/query`
  - `/types/:bucket_type/buckets/:bucket/query`
- Added parser normalization for query and mapreduce paths with alias-family preservation:
  - `/buckets/.../query` and `/types/.../query` normalize to `op=query`.
  - `/mapred` normalizes to `op=mapred`.
- Added B05 query allowlist and coercion/validation:
  - `query` op query allowlist: none (`[]`)
  - `mapred` op query allowlist: `chunked`
  - `chunked` validation: `true|false`
- Added dispatch wiring in handler:
  - `query` -> `riak_admin_api_riak:bucket_operation(query, Context, Input)`
  - `mapred` -> `riak_admin_api_riak:bucket_operation(mapred, Context, Input)`
- Added JSON object body validation guard for query/mapred POSTs; invalid payloads return Cowboy error envelope (`400 invalid_body`).
- Implemented query gateway parity behavior:
  - legacy-compatible posted JSON query request validation and key discipline,
  - query execution through `riak_client:query/2`,
  - query continuation header support via `x-riak-continuation`.
- Implemented mapreduce gateway parity behavior:
  - validates required `inputs` + `query` body fields,
  - supports nonchunked and chunked mapreduce response shapes,
  - chunked mode returns compatibility multipart envelope payloads.

## Query and Method Parity

- `query` endpoint allows `POST` only; violations return `405` with `Allow: POST`.
- `mapred` endpoint allows `GET|HEAD|POST`.
  - `GET|HEAD` return legacy usage text body contract (`text/plain`).
  - `POST` requires JSON object body and executes mapreduce.
- Query and mapreduce body failures return Cowboy JSON envelope fields (`error`, `message`, `request_id`) with status `400`.

## Route Matching Evidence

| External path | Normalized operation id | Internal gateway call/action | Test reference(s) |
|---|---|---|---|
| `/buckets/:bucket/query` | `query` | `riak_admin_api_riak:bucket_operation(query, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_query_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_query_mapred_test.erl` `query_and_mapred_route_translation_to_bucket_backend_action_test_/0` |
| `/types/:bucket_type/buckets/:bucket/query` | `query` | `riak_admin_api_riak:bucket_operation(query, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_query_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_query_mapred_test.erl` `query_and_mapred_route_translation_to_bucket_backend_action_test_/0` |
| `/mapred` | `mapred` | `riak_admin_api_riak:bucket_operation(mapred, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_mapred_path_and_stream_mode_test/0`; `apps/riak_admin_api/test/riak_admin_api_query_mapred_test.erl` `query_and_mapred_route_translation_to_bucket_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_query_mapred_test.erl` `mapred_get_and_head_usage_contract_test_/0` |

## Additional Evidence

- Route inventory and route-family metadata include B05 paths:
  - `apps/riak_admin_api/test/riak_admin_api_app_test.erl`
  - `routes_include_all_active_substrate_paths_test/0`
- Query/mapreduce query param allowlist and validation:
  - `apps/riak_admin_api/test/riak_admin_api_request_test.erl`
  - `normalize_query_operation_allowlist_rejects_unknown_test/0`
  - `normalize_mapred_query_allowlist_rejects_unknown_test/0`
  - `normalize_mapred_query_invalid_chunked_test/0`
- Body and error envelope behavior:
  - `apps/riak_admin_api/test/riak_admin_api_query_mapred_test.erl`
  - `query_invalid_json_payload_returns_400_test/0`
  - `mapred_invalid_json_payload_returns_400_test/0`
  - `mapred_timeout_error_uses_cowboy_error_envelope_test/0`

## Known Deviations

- MapReduce chunked behavior preserves compatibility multipart payload format, but response emission is currently aggregated-body output rather than incremental Cowboy chunk flushing/backpressure streaming.
- If legacy mapreduce backend modules are absent in a build, Cowboy returns `501 not_implemented` with reason `MapReduce backend unavailable in this build`.
- Timeout response contracts are preserved in Cowboy envelope shape, but mapreduce timeout status/code remains backend-specific (`500 timeout`) rather than normalized to a single cross-endpoint timeout status.
