# Cowboy Bucket and Bucket-Type Parity Notes (B03)

Date: 2026-02-19
Batch: B03
Branch: `feature/cowboy-b03-bucket-type`

## Implemented in B03

- Added bucket-family dispatch branches in `riak_admin_api_handler` for:
  - `op=bucket_props`
  - `op=bucket_type_props`
  - `op=buckets`
- Added default gateway path `riak_admin_api_riak:bucket_operation/3` with action mapping for:
  - `get_bucket_props`
  - `set_bucket_props`
  - `delete_bucket_props`
  - `get_bucket_type_props`
  - `set_bucket_type_props`
  - `list_buckets`
- Added PUT body validation for props routes (`{"props": {...}}`) before backend execution.
- Preserved B02 ambiguity discipline for `/riak/:bucket`:
  - `POST` with `props=false` still normalizes to `object_collection` (B02 behavior).
  - `keys=true|stream` still normalizes to `keys` and remains deferred to B04.

## Query and Method Parity

- Bucket props:
  - `/riak/:bucket` allows `GET|HEAD|PUT`
  - `/buckets/:bucket/props` and `/types/:type/buckets/:bucket/props` allow `GET|HEAD|PUT|DELETE`
- Bucket-type props:
  - `/types/:type/props` allows `GET|HEAD|PUT`
- Bucket listing:
  - `/riak`, `/buckets`, `/types/:type/buckets` allow `GET|HEAD`
  - `buckets=true` returns listed buckets
  - `buckets=stream` returns legacy-style bucket stream envelopes (aggregated payload in this batch)
  - missing/other `buckets` query returns `{"buckets":[]}`

## Route Matching Evidence

| External path | Normalized op | Internal gateway call | Test references |
|---|---|---|---|
| `/riak/:bucket` (`GET`,`HEAD`) | `bucket_props` | `riak_admin_api_riak:bucket_operation(get_bucket_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_bucket_props_alias_equivalence_test/0` |
| `/riak/:bucket` (`PUT`) | `bucket_props` | `riak_admin_api_riak:bucket_operation(set_bucket_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `riak_bucket_props_method_not_allowed_contract_test/0` |
| `/buckets/:bucket/props` (`GET`,`HEAD`) | `bucket_props` | `riak_admin_api_riak:bucket_operation(get_bucket_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_bucket_props_alias_equivalence_test/0` |
| `/buckets/:bucket/props` (`PUT`) | `bucket_props` | `riak_admin_api_riak:bucket_operation(set_bucket_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_props_invalid_json_payload_returns_400_test/0` |
| `/buckets/:bucket/props` (`DELETE`) | `bucket_props` | `riak_admin_api_riak:bucket_operation(delete_bucket_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0` |
| `/types/:bucket_type/buckets/:bucket/props` (`GET`,`HEAD`,`PUT`,`DELETE`) | `bucket_props` | `riak_admin_api_riak:bucket_operation(get/set/delete_bucket_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_bucket_props_alias_equivalence_test/0` |
| `/types/:bucket_type/props` (`GET`,`HEAD`) | `bucket_type_props` | `riak_admin_api_riak:bucket_operation(get_bucket_type_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_bucket_type_props_path_test/0` |
| `/types/:bucket_type/props` (`PUT`) | `bucket_type_props` | `riak_admin_api_riak:bucket_operation(set_bucket_type_props, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_type_props_invalid_json_payload_returns_400_test/0` |
| `/riak` (`GET`,`HEAD`) | `buckets` | `riak_admin_api_riak:bucket_operation(list_buckets, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_bucket_list_alias_and_stream_mode_test/0` |
| `/buckets` (`GET`,`HEAD`) | `buckets` | `riak_admin_api_riak:bucket_operation(list_buckets, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_bucket_list_alias_and_stream_mode_test/0` |
| `/types/:bucket_type/buckets` (`GET`,`HEAD`) | `buckets` | `riak_admin_api_riak:bucket_operation(list_buckets, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl` `bucket_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_bucket_list_alias_and_stream_mode_test/0` |

## Additional Evidence

- Permission denial behavior:
  - `apps/riak_admin_api/test/riak_admin_api_bucket_type_test.erl`
  - `bucket_props_permission_denied_returns_403_test/0`
- B04 routes remain deferred (`501 not_implemented`):
  - `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl`
  - `deferred_b04_routes_return_not_implemented_test_/0`

## Known Deviations

- Historical B03 state: `buckets=stream` used concatenated aggregated envelopes. Current baseline (S2+) uses incremental chunked streaming by default, with rollback toggle `stream_incremental_enabled=false`.
- Bucket-prop validation errors are normalized to the Cowboy substrate error shape (`invalid_body` / `invalid_props`) instead of mirroring every legacy text-body variant byte-for-byte.
