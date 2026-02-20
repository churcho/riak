# D01 Multi-DC Routing ADR

Date: 2026-02-20
Status: Accepted for D01 design baseline
Scope: Cowboy substrate + admin API multi-DC distribution behavior (post-B08)

## Context

B00-B08 delivered Cowboy compatibility/cutover controls for a single serving DC per request path. D01 must define deterministic multi-DC routing behavior without breaking route/parser/internal mapping discipline or legacy HTTP contracts.

## Decision Summary

### 1) Endpoint-level routing policies

| Policy | Contract | Endpoint groups |
|---|---|---|
| `local_only` | Always execute in local DC. Never forward. | `object_item` write verbs (`PUT/POST/DELETE`), `object_collection`, `bucket_props` mutating verbs, `bucket_type_props` mutating verbs, `counter` POST, `crdt_item` POST, `crdt_collection`, `mapred` POST |
| `local_first` | Execute locally first; optional remote fallback by policy if local result is retryable and endpoint is read-only. | `object_item` read verbs (`GET/HEAD`), `bucket_props` read verbs, `bucket_type_props` read verbs, `keys`, `index_query`, `query` |
| `remote_forward` | Explicit single-target forward to one remote DC only (no fanout write). | Read-only operations with explicit target selector (`x-riak-target-dc`); mutating operations only by explicit allowlist and kill-switch |
| `aggregate_read` | Fanout read to multiple DCs and merge deterministic envelope. | `/api/dcs`, `/api/cluster/status`, future opt-in read endpoints only |

### 2) Write routing and consistency semantics

- Default write contract remains local DC execution with existing Riak quorum semantics (`w/pw/dw/rw` etc.) in that DC.
- D01 does not introduce transparent multi-DC write fanout.
- Remote write forwarding is an explicit operator-controlled mode and must remain single-target.
- Write responses preserve existing status/header contracts; add `x-riak-served-by-dc` and `x-riak-target-dc` metadata when forwarding is used.

### 3) Partial-DC failure behavior and client contracts

- `local_only` and `local_first` local success path: unchanged existing response contract.
- `remote_forward` target unreachable/timeout:
  - `503` with `error="dc_unreachable"` or `error="dc_timeout"`.
  - JSON includes `target_dc` and `request_id`.
- `aggregate_read` partial failures:
  - Return `200` with `partial=true` when at least one DC succeeded.
  - Include `unavailable_dcs` list and per-DC error summaries.
  - Return `503` only when zero DCs return usable data.

### 4) Route/parser/internal mapping discipline for D01

- No new public route was introduced in this pass.
- For future D01 route additions, enforce strict chain:
  - Cowboy route declaration (`riak_admin_api_app:substrate_routes/0`)
  - parser normalization (`riak_admin_api_request:normalize_path/3`)
  - method/query allowlist (`allowed_methods/2`, `allowed_query_keys/1`)
  - gateway/internal action mapping (`riak_admin_api_handler` -> `riak_admin_api_riak`)
  - tests proving external path -> normalized op -> backend action

### 5) Syn metadata evolution and versioning direction

- Introduce metadata schema versioning (`syn_meta_vsn`) and capability advertisement.
- Preserve backward compatibility with existing v1 metadata keys.
- Detailed schema and rollout are specified in:
  - `docs/plans/artifacts/d01-syn-metadata-evolution.md`

### 6) Rollout and rollback strategy

- Use staged rollout with per-policy kill switches, canary DC, and aggregate-read guards.
- Rollback is fail-closed for forwarding/aggregation; local-only path remains available.
- Detailed matrix and acceptance gates are specified in:
  - `docs/plans/artifacts/d01-multidc-test-and-rollout.md`

## Consequences

- D01 keeps compatibility-safe default behavior (`local_only`/`local_first`) while enabling explicit distribution controls.
- Risk is shifted from implicit forwarding to explicit policy+metadata contracts.
- Observability must include DC dimension and error code dimension for route policy outcomes.
