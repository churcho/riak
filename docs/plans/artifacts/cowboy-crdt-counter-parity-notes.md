# Cowboy CRDT and Counter Parity Notes (B06)

Date: 2026-02-19
Batch: B06
Branch: `feature/cowboy-b06-crdt-counter`

## Implemented in B06

- Added Cowboy substrate route declarations for counter and CRDT paths:
  - `/buckets/:bucket/counters/:key`
  - `/types/:bucket_type/buckets/:bucket/datatypes`
  - `/types/:bucket_type/buckets/:bucket/datatypes/:key`
- Added parser normalization for counter and CRDT paths:
  - `/buckets/.../counters/...` normalizes to `op=counter`.
  - `/types/.../datatypes` normalizes to `op=crdt_collection`.
  - `/types/.../datatypes/...` normalizes to `op=crdt_item`.
- Added B06 query allowlists and method contracts:
  - `counter` allows counter parity query params (`r/pr/w/pw/dw/basic_quorum/notfound_ok/node_confirms/timeout/returnvalue`) and methods `GET|POST`.
  - `crdt_item` and `crdt_collection` allow CRDT parity query params (`r/pr/w/pw/dw/rw/basic_quorum/notfound_ok/node_confirms/timeout/include_context/returnbody`) with methods `GET|HEAD|POST` and `POST`.
- Added dispatch wiring in handler:
  - `counter` -> `riak_admin_api_riak:bucket_operation(counter_get|counter_update, Context, Input)`
  - `crdt_item` -> `riak_admin_api_riak:bucket_operation(crdt_fetch|crdt_update, Context, Input)`
  - `crdt_collection` -> `riak_admin_api_riak:bucket_operation(crdt_create, Context, Input)`
- Implemented counter gateway semantics:
  - `GET` returns plain integer body (`text/plain`) from counter value.
  - `POST` accepts signed integer body and maps to increment/decrement CRDT ops.
  - `returnvalue=true` returns updated integer body (`200`); otherwise `204`.
- Implemented CRDT gateway semantics:
  - Datatype discovery/validation from bucket props (`datatype`, `allow_mult`).
  - Update payload parsing via `riak_kv_crdt_json:update_request_from_json/3` for supported operations.
  - `include_context` default `true` on CRDT reads/returned bodies.
  - `returnbody` default `false` on CRDT writes; body returned when enabled.
  - `notfound` and `deleted` CRDT read states return compatibility JSON body (`{"type":...,"error":"notfound"}`), with deleted state adding `x-riak-deleted: true`.

## Counter and CRDT Parity Notes

- Counter endpoint keeps legacy compatibility path and body contract:
  - `GET /buckets/:bucket/counters/:key` returns integer response body.
  - `POST /buckets/:bucket/counters/:key` accepts integer delta body.
- CRDT endpoint supports typed datatype operations on:
  - `POST /types/:bucket_type/buckets/:bucket/datatypes`
  - `GET|HEAD|POST /types/:bucket_type/buckets/:bucket/datatypes/:key`
- Compatibility error mapping preserved for:
  - datatype validation failures (`invalid_datatype`),
  - quorum and timeout errors (mapped through existing compatibility error mapper),
  - notfound/deleted CRDT fetch states.

## Route Matching Evidence

| External path | Normalized operation id | Internal gateway call/action | Test reference(s) |
|---|---|---|---|
| `/buckets/:bucket/counters/:key` | `counter` | `riak_admin_api_riak:bucket_operation(counter_get|counter_update, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_counter_path_test/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_counter_method_not_allowed_includes_allow_contract_test/0`; `apps/riak_admin_api/test/riak_admin_api_crdt_counter_test.erl` `counter_and_crdt_route_translation_to_bucket_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_crdt_counter_test.erl` `counter_method_not_allowed_allow_header_contract_test/0` |
| `/types/:bucket_type/buckets/:bucket/datatypes` | `crdt_collection` | `riak_admin_api_riak:bucket_operation(crdt_create, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_crdt_paths_test/0`; `apps/riak_admin_api/test/riak_admin_api_crdt_counter_test.erl` `counter_and_crdt_route_translation_to_bucket_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_crdt_counter_test.erl` `crdt_collection_method_not_allowed_allow_header_contract_test/0` |
| `/types/:bucket_type/buckets/:bucket/datatypes/:key` | `crdt_item` | `riak_admin_api_riak:bucket_operation(crdt_fetch|crdt_update, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_crdt_paths_test/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_crdt_query_allowlist_rejects_unknown_test/0`; `apps/riak_admin_api/test/riak_admin_api_crdt_counter_test.erl` `counter_and_crdt_route_translation_to_bucket_backend_action_test_/0` |

## Additional Evidence

- App route inventory includes all new B06 public paths:
  - `apps/riak_admin_api/test/riak_admin_api_app_test.erl`
  - `routes_include_all_active_substrate_paths_test/0`
- Counter/CRDT parser and validation behavior:
  - `apps/riak_admin_api/test/riak_admin_api_request_test.erl`
  - `normalize_counter_query_allowlist_rejects_unknown_test/0`
  - `normalize_crdt_query_allowlist_rejects_unknown_test/0`
- Counter/CRDT operation decoding helpers:
  - `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`
  - `counter_delta_from_body_accepts_signed_integer_test/0`
  - `counter_delta_from_body_rejects_non_integer_test/0`
  - `crdt_decode_update_body_counter_and_set_test/0`
  - `crdt_decode_update_body_rejects_invalid_payload_test/0`

## Known Deviations

- CRDT default-bucket-type redirect parity is implemented for keyed datatype paths (`/types/default/buckets/:bucket/datatypes/:key`) only; collection create path does not redirect and will follow datatype validation flow.
- CRDT datatype validation errors are returned through the Cowboy JSON error envelope with compatibility messages, rather than legacy plain-text Webmachine halt bodies.
- Counter path parity is implemented at `/buckets/:bucket/counters/:key`; no additional `/riak/.../counters/...` alias was introduced in B06.
