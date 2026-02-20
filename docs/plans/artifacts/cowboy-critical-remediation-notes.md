# Cowboy Critical Remediation Notes (D01 + S0)

Date: 2026-02-20
Status: D01 + S0 pass notes

## Remediations Implemented in D01

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

## Remediations Implemented in S0

### S0-001: Unsafe `binary_to_term` (CG-009)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- `binary_to_term(Body)` → `binary_to_term(Body, [safe])` in `accept_doc_value/2`.

Why safe:

- Only affects Erlang binary term deserialization path. Valid pre-existing atoms still decode. Corrupted/malicious payloads fall back to raw body (existing behavior for decode failures).

Verification:

- `accept_doc_value_safe_term_decode_test` passes.
- `accept_doc_value_rejects_atom_creation_payload_test` passes.

### S0-002: TLS header spoofing / proxy trust (CG-010)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_request.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/test/riak_admin_api_request_test.erl`

What changed:

- `ensure_tls/2` now requires `trust_proxy_headers => true` before trusting `X-Forwarded-Proto`.
- New config key: `security_trust_proxy_headers` (default: `false`).
- Without proxy trust, `require_tls => true` fails closed.

Why safe:

- Default behavior change: previously TLS check could be spoofed; now it fails closed. Operators who need proxy trust must explicitly enable it.

Verification:

- `tls_required_without_proxy_trust_rejects_spoofed_header_test` passes.
- `tls_required_with_proxy_trust_accepts_https_header_test` passes.

### S0-003: Request body size limits (CG-011)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/test/riak_admin_api_handler_test.erl`

What changed:

- `read_request_body_chunks` tracks accumulated size, throws on limit breach.
- `with_request_body` handles `body_too_large` with HTTP 413.
- Configurable via `max_request_body_bytes` (default: 5 MiB).

Why safe:

- Only affects oversized request bodies. Normal requests within limit are unaffected.

Verification:

- `body_size_limit_allows_within_limit_body_test` passes.

### S0-004: Substrate routes disabled by default (CG-012)

Scope:

- `apps/riak_admin_api/src/riak_admin_api.app.src`
- `apps/riak_admin_api/test/riak_admin_api_request_test.erl`

What changed:

- `cowboy_cutover_default_mode` default changed from `enabled` to `disabled`.
- Admin routes (`/api/...`) unaffected; they use `rah_*` handlers outside cutover control.

Why safe:

- Breaking change for operators who relied on substrate routes being open. This is intentional — operators must now explicitly enable substrate data-path endpoints.

Verification:

- `substrate_disabled_by_default_blocks_data_path_test` passes.
- `substrate_explicit_enable_overrides_disabled_default_test` passes.

### S0-005: Origin policy hardening (CG-013)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_request.erl`
- `apps/riak_admin_api/test/riak_admin_api_request_test.erl`

What changed:

- Missing `Origin` header on unsafe methods now denied when `trusted_origins` is configured.

Why safe:

- Only affects deployments with `trusted_origins` configured (not the default empty list). Safe methods remain unaffected.

Verification:

- `origin_missing_on_unsafe_method_denied_when_origins_configured_test` passes.
- `origin_not_checked_when_trusted_origins_empty_test` passes.

### S0-006: Compile-time isolation docs (CG-014)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl` (module docs)
- `apps/riak_admin_api/src/riak_admin_api.app.src` (isolation principle docs)

What changed:

- Corrected false claim about compile-time independence from riak_kv.
- Documented actual `-include_lib` dependencies on riak_kv headers.
- Added future work note for full compile-time isolation.

Why safe:

- Documentation-only change; no runtime behavior modification.

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

### SD-001: net_adm:ping sequential latency (CG-015)

Acceptance criteria:

- Async or parallel pings with timeout ceiling.
- Cached reachability with TTL to bound response time.

### SD-002: Stream collection handler blocking (CG-016)

Acceptance criteria:

- Separate collection process with backpressure.
- Handler process freed immediately after spawning collector.

### SD-003: Listener supervision architecture (CG-017)

Acceptance criteria:

- Move Cowboy listener under supervisor using `cowboy:child_spec/3`.
- Crash recovery test.

### SD-004: Timeout contract unification (CG-018)

See D-003 / CG-005.
