# Cowboy Critical Remediation Notes (D01)

Date: 2026-02-20
Status: D01 pass notes

## Remediations Implemented in This Pass

### R-001: Telemetry `error_code` dimension

Scope:

- `apps/riak_admin_api/src/riak_admin_api_response.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/test/riak_admin_api_response_test.erl`

What changed:

- `telemetry_tags/3` now emits `error_code` in tag map.
- Error reply path now carries telemetry context for error responses.
- Handler error paths now attach route/op/alias/error_code context before calling error serializer.

Why safe:

- Additive observability change only; no HTTP response body/status compatibility change.

Verification:

- `telemetry_tags_include_error_code_dimension_test` passes.

### R-002: Cutover misconfiguration fail-closed behavior

Scope:

- `apps/riak_admin_api/src/riak_admin_api_request.erl`
- `apps/riak_admin_api/test/riak_admin_api_request_test.erl`

What changed:

- Invalid per-operation mode values in `cowboy_cutover_op_modes` now return:
  - `503`
  - `error = route_cutover_misconfigured`
- Invalid default mode still falls back to `enabled` for backward-compatible startup behavior.

Why safe:

- Only affects invalid configuration values; valid deployments keep existing behavior.
- Prevents accidental route enablement due to typos.

Verification:

- `normalize_cutover_invalid_op_mode_blocks_with_config_error_test` passes.
- `normalize_cutover_invalid_default_mode_falls_back_to_enabled_test` passes.

## Deferred Remediation Plans

### D-001: True incremental streaming/backpressure (CG-001)

Acceptance criteria:

- Replace aggregated-body stream collection with incremental chunk emission.
- Add memory/backpressure tests for long key/index/mapred streams.
- Preserve existing compatibility payload envelopes.

### D-002: Conditional-write completeness (CG-004)

Acceptance criteria:

- Define explicit mapping for `If-Match` and `If-Unmodified-Since` to Riak conditional primitives.
- Add red/green tests for stale-match and stale-time precondition failure behavior.
- Confirm parity against legacy path expectations.

### D-003: Timeout semantics alignment (CG-005)

Acceptance criteria:

- Choose one policy:
  - normalize mapred timeout to `503 timeout`, or
  - codify intentional divergence with explicit docs and client guidance.
- Add endpoint-level timeout contract tests.

### D-004: MapReduce backend availability control (CG-006)

Acceptance criteria:

- Expose backend capability signal in diagnostics/metrics.
- Block mapred enablement during rollout when backend modules are missing.

### D-005: CRDT redirect parity scope (CG-007)

Acceptance criteria:

- ADR with explicit keyed vs collection path behavior.
- Tests proving chosen behavior and ensuring no ambiguous redirects.

### D-006: `/riak` counters alias parity decision (CG-008)

Acceptance criteria:

- Publish explicit parity decision.
- If alias is added: route/parser/internal mapping evidence and compatibility tests.
- If alias is rejected: document rationale and migration guidance.
