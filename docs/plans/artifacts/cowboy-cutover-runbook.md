# Cowboy Cutover Runbook (B08)

Date: 2026-02-19  
Batch: B08  
Branch: `feature/cowboy-b08-cutover`

## Objective

Perform a controlled Cowboy-first cutover with route-level switches, staged rollout checkpoints, and explicit rollback triggers.

## Scope Guardrails

- In scope: Cowboy route-level cutover controls, rollout checkpoints, and endpoint-group fallback controls.
- Out of scope: multi-DC distribution/routing evolution (tracked in D01 only).

## Route-Level Cutover Control Surface

B08 adds route-level gating through request normalization options driven by app env:

- `cowboy_cutover_default_mode` (atom/string): `enabled|deprecated|shadow|disabled|removed`
- `cowboy_cutover_op_modes` (map/proplist): per-normalized-op override

Default app env in `riak_admin_api.app.src`:

```erlang
{cowboy_cutover_default_mode, enabled},
{cowboy_cutover_op_modes, []}
```

Mode semantics:

- `enabled`: endpoint group serves normally.
- `deprecated`: endpoint group serves normally; deprecation communicated by release docs.
- `shadow`: endpoint group serves normally; reserved for dual-observe operations.
- `disabled`: endpoint group returns `503` with code `route_cutover_disabled`.
- `removed`: endpoint group returns `410` with code `route_removed`.

## Staged Rollout Plan

### Stage 0: Preflight (2026-02-19)

- Confirm B07 gates are still green.
- Confirm cutover defaults are non-breaking (`enabled` + empty op overrides).
- Dry-run operation-level disable/enable behavior before any production cohort.

Checkpoint:

- `./rebar3 eunit apps=riak_admin_api`
- `./rebar3 eunit apps=riak_admin_api --test riak_admin_api_request_test:normalize_cutover_default_disabled_blocks_unmapped_ops_test`

Expected:

- EUnit passes.
- Targeted dry-run test passes (proves `disabled` mode yields deterministic `503 route_cutover_disabled`).

### Stage 1: Dev cohort (2026-02-20 to 2026-02-23)

- Deploy with default `enabled`.
- Exercise each endpoint family with contract harness.
- Toggle one non-critical endpoint group (`mapred`) to `disabled` for 15-30 minutes in dev, validate controlled rejection, then restore `enabled`.

Checkpoint:

- `./apps/riak_admin_api/test/cowboy_contract_harness.sh`
- target logs include `route_cutover_disabled` only for intentionally disabled group

### Stage 2: Staging cohort (2026-02-24 to 2026-03-02)

- Keep critical data-path groups (`object_item`, `object_collection`, `keys`, `index_query`, `counter`, `crdt_item`) in `enabled`.
- Validate latency/error budgets from B07 in staging traffic profile.

Checkpoint:

- p95/p99 remains within B07 release gates
- no unplanned `503/410` from cutover controls

### Stage 3: Production cohort wave 1 (2026-03-03 to 2026-03-09)

- Start with all groups `enabled`.
- Begin documentation-level deprecation notice for legacy aliases only (no removal switches yet).

Checkpoint:

- 5xx < 1% and timeout-class errors < 0.5% for target operations for 24h

### Stage 4: Production cohort wave 2 (2026-03-10 onward)

- Keep endpoint groups available; enforce migration schedule through operator/client communication and optional per-group throttling/disable only when rollback criteria are met.

Checkpoint:

- no SLO breach during peak windows
- rollback controls tested and validated (see rollback runbook)

## Operational Checkpoints (Go/No-Go)

Go if all true:

- Contract harness remains green.
- `./rebar3 eunit apps=riak_admin_api` remains green.
- No unplanned cutover-mode errors for enabled groups.
- Request-id propagation remains intact (`x-request-id` on error and success paths).

No-Go if any true:

- Any critical endpoint group exceeds error budget for 5 minutes.
- Cutover controls produce wrong status or code (`disabled` not returning `503`, `removed` not returning `410`).
- Contract harness regression in any endpoint family.

## Route Matching Evidence

B08 does not change parser shapes or gateway mappings. It adds operation-level gating after normalization. The mapping evidence for gated groups is:

| External route template(s) | Normalized op (cutover key) | Internal gateway mapping | Gating proof |
|---|---|---|---|
| `/riak/:bucket/:key`, `/buckets/:bucket/keys/:key`, `/types/:bucket_type/buckets/:bucket/keys/:key` | `object_item` | `object_operation(get|put|post|delete, ...)` | `riak_admin_api_request_test:normalize_cutover_disabled_mode_blocks_endpoint_group_test` + existing object parity tests |
| `/buckets/:bucket/keys`, `/types/:bucket_type/buckets/:bucket/keys`, `POST /riak/:bucket?props=false` | `object_collection` | `object_operation(create, ...)` | existing object parity tests + cutover op-mode wiring in request normalize |
| `/buckets/:bucket/query`, `/types/:bucket_type/buckets/:bucket/query` | `query` | `bucket_operation(query, ...)` | existing B05 query mapping tests |
| `/mapred` | `mapred` | `bucket_operation(mapred, ...)` | `riak_admin_api_request_test:normalize_cutover_default_disabled_blocks_unmapped_ops_test` and `...explicit_enabled_overrides...` |
| `/types/:bucket_type/buckets/:bucket/datatypes`, `/types/:bucket_type/buckets/:bucket/datatypes/:key` | `crdt_collection`, `crdt_item` | `bucket_operation(crdt_create|crdt_fetch|crdt_update, ...)` | `riak_admin_api_request_test:normalize_cutover_removed_mode_returns_gone_test` + existing B06 CRDT tests |

## Deferred Work (Not B08)

- Multi-DC distribution and syn behavior evolution remain deferred to D01.
