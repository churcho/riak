# Cowboy Rollback Runbook (B08)

Date: 2026-02-19  
Batch: B08  
Branch: `feature/cowboy-b08-cutover`

## Objective

Define endpoint-group rollback actions using B08 route-level cutover controls.

## Rollback Triggers

Start rollback if any of the following persists for 5 minutes in the active cohort:

- 5xx > 1% for any critical endpoint group (`object_item`, `keys`, `index_query`, `counter`, `crdt_item`, `query`, `mapred`).
- timeout-class errors > 0.5% for any critical endpoint group.
- contract-harness failure in staging/prod-like verification.

## Rollback Levers

Use `cowboy_cutover_op_modes` for targeted rollback.

- `disabled` returns `503 route_cutover_disabled` for that endpoint group.
- `removed` returns `410 route_removed` for that endpoint group.
- `enabled` restores normal behavior.

Keep `cowboy_cutover_default_mode=enabled` during normal operations; do not use global disable in production except full emergency stop.

## Endpoint-Group Rollback Matrix

| Endpoint group (`op`) | Primary routes | Failure signal | Immediate rollback action | Exit criteria to re-enable |
|---|---|---|---|---|
| `object_item`, `object_collection` | `/riak/:bucket/:key`, `/buckets/:bucket/keys/:key`, `/types/:bucket_type/buckets/:bucket/keys/:key` | 5xx spike, high write/read timeout | set affected op(s) to `disabled` | 24h stable canary with error budget green |
| `bucket_props`, `bucket_type_props`, `buckets` | `/riak`, `/buckets`, `/types/:bucket_type/props` | malformed props responses, elevated 4xx/5xx | set impacted op to `disabled` | contract tests + manual props validation pass |
| `keys`, `index_query` | `/buckets/:bucket/keys`, `/.../index/...` | query timeout and continuation errors | set op to `disabled` | staged load test green |
| `query`, `mapred` | `/buckets/:bucket/query`, `/mapred` | backend query/mapred errors | set op to `disabled` | 24h stable staging replay |
| `counter`, `crdt_item`, `crdt_collection` | `/buckets/:bucket/counters/:key`, `/types/.../datatypes...` | consistency timeout / invalid mutation responses | set affected op(s) to `disabled` | consistency checks green and contract tests pass |

## Rollback Procedure

1. Identify the failing endpoint group(s) by `op`/`route`/`status` telemetry dimensions.
2. Apply targeted mode update in runtime config (`cowboy_cutover_op_modes`).
3. Verify returned status and error code are deterministic (`503 route_cutover_disabled` or `410 route_removed`).
4. Re-run contract harness for unaffected endpoint groups.
5. Communicate client impact window and mitigation.
6. After stabilization, re-enable incrementally by endpoint group.

## Dry-Run Verification Commands

Targeted disable dry-run:

```bash
./rebar3 eunit apps=riak_admin_api --test riak_admin_api_request_test:normalize_cutover_default_disabled_blocks_unmapped_ops_test
```

Targeted re-enable dry-run:

```bash
./rebar3 eunit apps=riak_admin_api --test riak_admin_api_request_test:normalize_cutover_explicit_enabled_overrides_default_disabled_test
```

Expected:

- Disable dry-run test passes (asserts deterministic `503 route_cutover_disabled` behavior).
- Re-enable dry-run test passes (asserts explicit enable override behavior).

## Route Matching Evidence

Rollback controls do not alter route parsing or backend mapping. They gate by already-normalized `op`:

| External route template(s) | Normalized op | Backend action(s) | Rollback evidence |
|---|---|---|---|
| `/mapred` | `mapred` | `bucket_operation(mapred, ...)` | rollback dry-run commands above + `normalize_cutover_default_disabled_blocks_unmapped_ops_test` |
| `/buckets/:bucket/keys/:key` and aliases | `object_item` | `object_operation(get|put|post|delete, ...)` | `normalize_cutover_disabled_mode_blocks_endpoint_group_test` + object parity tests |
| `/types/:bucket_type/buckets/:bucket/datatypes` | `crdt_collection` | `bucket_operation(crdt_create, ...)` | `normalize_cutover_removed_mode_returns_gone_test` + CRDT parity tests |

## Known Constraints

- B08 rollback is endpoint-group scoped; it does not perform multi-DC traffic steering.
- Multi-DC rollback orchestration remains D01 scope.
