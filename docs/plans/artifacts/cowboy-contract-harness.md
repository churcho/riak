# Cowboy Contract Harness (B07)

Date: 2026-02-19  
Batch: B07  
Branch: `feature/cowboy-b07-verification-perf`

## Objective

Provide a repeatable contract harness that verifies migrated Cowboy behavior against the B00 compatibility contract for every migrated endpoint family (B02-B06 scope).

## Harness Entry Point

- Script: `apps/riak_admin_api/test/cowboy_contract_harness.sh`
- Behavior:
  - Runs endpoint-family module suites independently.
  - Produces family-level pass/fail summary.
  - Exits non-zero if any family fails.

## Scope Matrix by Endpoint Family

| Endpoint family | Contract source artifact | Harness module | Route/parser/internal translation evidence |
|---|---|---|---|
| Contract inventory and aliases | `docs/plans/artifacts/cowboy-compat-matrix.md` | `cowboy_contract_inventory_test` | Core alias matrix checks for `/riak`, `/buckets`, `/types` |
| Route inventory | `docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md` | `riak_admin_api_app_test` | Route declaration coverage for all active substrate paths |
| Request normalization and method/query contracts | `docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md` | `riak_admin_api_request_test` | External path -> normalized `op` -> allow/query validation behavior |
| Object CRUD | `docs/plans/artifacts/cowboy-object-parity-notes.md` | `riak_admin_api_object_crud_test` | Alias route translation to `object_operation(...)` + method `Allow` contract |
| Bucket + bucket-type | `docs/plans/artifacts/cowboy-bucket-type-parity-notes.md` | `riak_admin_api_bucket_type_test` | Route-family translation to `bucket_operation(get/set/delete/list...)` |
| Key listing + 2i | `docs/plans/artifacts/cowboy-keylist-2i-parity-notes.md` | `riak_admin_api_keylist_index_test` | `/riak|/buckets|/types` alias normalization to `keys`/`index_query` |
| Query + mapreduce | `docs/plans/artifacts/cowboy-query-mapred-parity-notes.md` | `riak_admin_api_query_mapred_test` | `/query` + `/mapred` normalization and backend action mapping |
| CRDT + counter | `docs/plans/artifacts/cowboy-crdt-counter-parity-notes.md` | `riak_admin_api_crdt_counter_test` | Counter/CRDT route normalization to `counter|crdt_*` backend actions |

## Exact Commands Run

1. `./apps/riak_admin_api/test/cowboy_contract_harness.sh`
2. `./rebar3 eunit apps=riak_admin_api`

## Result Summary

- Command `./apps/riak_admin_api/test/cowboy_contract_harness.sh` exited `0`.
- Harness family summary: `pass=8 fail=0 total=8`.
- Family-level module outcomes:
  - `inventory` (`cowboy_contract_inventory_test`): pass.
  - `routing` (`riak_admin_api_app_test`): all 22 tests passed.
  - `request_normalization` (`riak_admin_api_request_test`): all 34 tests passed.
  - `object_crud` (`riak_admin_api_object_crud_test`): all 13 tests passed.
  - `bucket_type` (`riak_admin_api_bucket_type_test`): all 13 tests passed.
  - `keylist_2i` (`riak_admin_api_keylist_index_test`): all 6 tests passed.
  - `query_mapred` (`riak_admin_api_query_mapred_test`): all 9 tests passed.
  - `crdt_counter` (`riak_admin_api_crdt_counter_test`): all 7 tests passed.
- Required global verification:
  - `./rebar3 eunit apps=riak_admin_api` exited `0` with `All 200 tests passed`.

## Known Gaps

- Harness validates parity contracts via deterministic unit/contract modules, not mixed-version dual-stack live replay against a running Webmachine node.
- Historical B07 note: stream-mode behavior was aggregated-body at that point. Current baseline (S2+) uses incremental chunked streaming by default, with compatibility rollback toggle `stream_incremental_enabled=false`.
