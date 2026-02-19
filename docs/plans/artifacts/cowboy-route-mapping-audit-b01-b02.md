# Cowboy Route Mapping Audit (B01/B02)

Date: 2026-02-19
Batch: B02A retro cleanup
Branch: `feature/cowboy-b02a-route-audit`

## Scope

Audit alignment between:

- `riak_admin_api_app:substrate_routes/0`
- `riak_admin_api_request:normalize_path/3` and `allowed_methods/2`
- `riak_admin_api_handler:dispatch/4`
- `riak_admin_api_riak:object_operation/3`

## Findings

- All active B01/B02 Cowboy substrate route templates are declared in `substrate_routes/0` and normalized by `normalize_path/3`.
- Object routes (`object_item`, `object_collection`) dispatch to `riak_admin_api_riak:object_operation/3` with expected action translation.
- Non-object routes normalize and enforce allowlists but intentionally dispatch to `501 not_implemented` in B02.
- Added parser guard for malformed double-slash path shapes so unsupported shapes return `404 unknown_route` instead of accidental normalization.

## Route Mapping Evidence

| External path | Normalized op | Internal call/action | Test reference |
|---|---|---|---|
| `/riak` | `buckets` (`GET`,`HEAD`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_app_test.erl` `routes_include_all_active_b01_b02_substrate_paths_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/riak/:bucket` | `bucket_props` (`GET`,`HEAD`,`PUT`) when `keys` not requested and `props` enabled | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/riak/:bucket` | `keys` (`GET`,`HEAD`) when query `keys=true|stream` | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_legacy_riak_ambiguous_bucket_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/riak/:bucket` | `object_collection` (`POST`) when query `props=false` | `riak_admin_api_riak:object_operation(create, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_collection_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `object_route_translation_to_backend_action_test_/0` |
| `/riak/:bucket/:key` | `object_item` (`GET`,`HEAD`,`PUT`,`POST`,`DELETE`) | `riak_admin_api_riak:object_operation(Action, Context, Input)` where `GET|HEAD->get`, `PUT->put`, `POST->post`, `DELETE->delete` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `object_route_translation_to_backend_action_test_/0` |
| `/buckets` | `buckets` (`GET`,`HEAD`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_alias_roots_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/buckets/:bucket/props` | `bucket_props` (`GET`,`HEAD`,`PUT`,`DELETE`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/buckets/:bucket/keys` | `keys` (`GET`,`HEAD`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `keys_method_not_allowed_allow_header_contract_test/0` |
| `/buckets/:bucket/keys` | `object_collection` (`POST`) | `riak_admin_api_riak:object_operation(create, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_collection_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `object_route_translation_to_backend_action_test_/0` |
| `/buckets/:bucket/keys/:key` | `object_item` (`GET`,`HEAD`,`PUT`,`POST`,`DELETE`) | `riak_admin_api_riak:object_operation(Action, Context, Input)` where `GET|HEAD->get`, `PUT->put`, `POST->post`, `DELETE->delete` | `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `object_route_translation_to_backend_action_test_/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `object_item_method_not_allowed_allow_header_contract_test/0` |
| `/types/:bucket_type/props` | `bucket_type_props` (`GET`,`HEAD`,`PUT`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/types/:bucket_type/buckets` | `buckets` (`GET`,`HEAD`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_alias_roots_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/types/:bucket_type/buckets/:bucket/props` | `bucket_props` (`GET`,`HEAD`,`PUT`,`DELETE`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/types/:bucket_type/buckets/:bucket/keys` | `keys` (`GET`,`HEAD`) | none (`dispatch/4` deferred `501`) | `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `deferred_non_object_routes_return_not_implemented_test_/0` |
| `/types/:bucket_type/buckets/:bucket/keys` | `object_collection` (`POST`) | `riak_admin_api_riak:object_operation(create, Context, Input)` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_collection_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `object_route_translation_to_backend_action_test_/0` |
| `/types/:bucket_type/buckets/:bucket/keys/:key` | `object_item` (`GET`,`HEAD`,`PUT`,`POST`,`DELETE`) | `riak_admin_api_riak:object_operation(Action, Context, Input)` where `GET|HEAD->get`, `PUT->put`, `POST->post`, `DELETE->delete` | `apps/riak_admin_api/test/riak_admin_api_request_test.erl` `normalize_alias_equivalence_test/0`; `apps/riak_admin_api/test/riak_admin_api_object_crud_test.erl` `object_route_translation_to_backend_action_test_/0` |

## Route Edge-Case Test Additions (B02A)

- Alias equivalence:
  - `normalize_alias_roots_equivalence_test/0`
  - `normalize_collection_alias_equivalence_test/0`
- Unsupported malformed path shapes (`//`) return `404`:
  - `normalize_unsupported_path_shapes_test_/0`
- Method allowlist and `allow` header contract:
  - `normalize_method_not_allowed_includes_allow_contract_test/0`
  - `object_item_method_not_allowed_allow_header_contract_test/0`
  - `keys_method_not_allowed_allow_header_contract_test/0`
- Translation to normalized operation and gateway action:
  - `object_route_translation_to_backend_action_test_/0`
  - `deferred_non_object_routes_return_not_implemented_test_/0`

## Remaining Risks

- `normalize_path/3` still contains forward-looking `index_query` normalization branches (`/buckets/.../index/...`, `/types/.../index/...`) that are not yet exposed in `substrate_routes/0`; B04 must keep route/parser rollout synchronized.
- Non-object operations intentionally remain deferred behind `501` in B02; parity for those route families depends on B03/B04 execution without relaxing current allowlist/error contracts.
