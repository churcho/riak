# Cowboy Key Listing and 2i Parity Notes (B04)

Date: 2026-02-19
Batch: B04
Branch: `feature/cowboy-b04-keylist-2i`

## Implemented in B04

- Added Cowboy substrate route declarations for 2i paths:
  - `/buckets/:bucket/index/:field/:term`
  - `/buckets/:bucket/index/:field/:start/:end`
  - `/types/:bucket_type/buckets/:bucket/index/:field/:term`
  - `/types/:bucket_type/buckets/:bucket/index/:field/:start/:end`
- Enabled handler dispatch for normalized operations:
  - `op=keys` -> `riak_admin_api_riak:bucket_operation(list_keys, Context, Input)`
  - `op=index_query` -> `riak_admin_api_riak:bucket_operation(index_query, Context, Input)`
- Added key listing gateway behavior with legacy-compatible JSON envelopes for:
  - `keys=true` (single JSON response),
  - `keys=stream` (aggregated stream chunks),
  - legacy `/riak/:bucket` optional `props` inclusion semantics.
- Added 2i gateway behavior for exact/range lookups with:
  - `max_results`, `continuation`, `return_terms`, `pagination_sort`, `timeout`, `term_regex`,
  - non-stream JSON responses with continuation support,
  - historical B04 stream mode multipart envelope compatibility (`multipart/mixed;boundary=...`) in aggregated-body form.
- Added query allowlist + validation for B04 operations:
  - `keys` op query allowlist: `keys`, `props`, `timeout`
  - `index_query` op query allowlist: `stream`, `max_results`, `continuation`, `return_terms`, `pagination_sort`, `timeout`, `term_regex`
  - invalid/unknown query params return `400 invalid_query`.

## Query and Method Parity

- `keys` endpoints allow `GET|HEAD`; method violations return `405` with `Allow: GET, HEAD`.
- `index_query` endpoints allow `GET|HEAD`; method violations return `405` with `Allow: GET, HEAD`.
- `max_results` is normalized as a positive integer (`>0`) and rejected otherwise.
- `continuation` implies `pagination_sort=true` in gateway option mapping for 2i requests.
- `stream_mode` normalization remains canonical (`none|keys|index`) and is propagated through request context.

## Route Matching Evidence

| External path | Normalized operation id | Internal gateway call/action | Test references |
|---|---|---|---|
| `/riak/:bucket` with `?keys=true|stream` | `keys` | `riak_admin_api_riak:bucket_operation(list_keys, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_legacy_riak_ambiguous_bucket_test/0`; `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `keylist_and_index_route_translation_to_bucket_backend_action_test_/0` |
| `/buckets/:bucket/keys` | `keys` | `riak_admin_api_riak:bucket_operation(list_keys, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `keylist_and_index_route_translation_to_bucket_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `keys_method_not_allowed_allow_header_contract_test/0` |
| `/types/:bucket_type/buckets/:bucket/keys` | `keys` | `riak_admin_api_riak:bucket_operation(list_keys, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `keylist_and_index_route_translation_to_bucket_backend_action_test_/0` |
| `/buckets/:bucket/index/:field/:term` | `index_query` (exact) | `riak_admin_api_riak:bucket_operation(index_query, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_index_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `keylist_and_index_route_translation_to_bucket_backend_action_test_/0` |
| `/buckets/:bucket/index/:field/:start/:end` | `index_query` (range) | `riak_admin_api_riak:bucket_operation(index_query, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_index_range_path_test/0`; `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `keylist_and_index_route_translation_to_bucket_backend_action_test_/0` |
| `/types/:bucket_type/buckets/:bucket/index/:field/:term` | `index_query` (exact) | `riak_admin_api_riak:bucket_operation(index_query, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_index_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `keylist_and_index_route_translation_to_bucket_backend_action_test_/0` |
| `/types/:bucket_type/buckets/:bucket/index/:field/:start/:end` | `index_query` (range) | `riak_admin_api_riak:bucket_operation(index_query, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_index_range_path_test/0`; `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `keylist_and_index_route_translation_to_bucket_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_keylist_index_test.erl` `index_method_not_allowed_allow_header_contract_test/0` |

## Additional Evidence

- Route declarations include all active B04 substrate templates:
  - `apps/riak_admin_api/test/riak_admin_api_app_test.erl`
  - `routes_include_all_active_substrate_paths_test/0`
- Query allowlist and coercion validation:
  - `apps/riak_admin_api/test/riak_admin_api_request_test.erl`
  - `normalize_query_index_flags_and_max_results_test/0`
  - `normalize_query_invalid_max_results_test/0`
  - `normalize_keys_query_allowlist_rejects_unknown_test/0`
  - `normalize_index_query_allowlist_rejects_unknown_test/0`
  - `normalize_keys_query_invalid_mode_test/0`

## Known Deviations

- Historical B04 state: stream implementations returned aggregated response bodies. Current baseline (S2+) uses incremental chunked streaming by default (`stream_incremental_enabled=true`) with rollback toggle support.
- 2i validation and timeout errors are normalized to Cowboy error payload shape (`400 invalid_query`, `503 timeout`) instead of byte-for-byte legacy text body variants.
