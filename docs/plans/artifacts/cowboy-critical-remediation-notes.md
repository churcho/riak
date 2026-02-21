# Cowboy Critical Remediation Notes (D01 + S0 + S1 + S2 + S5)

Date: 2026-02-20
Status: D01 + S0 + S1 + S2 + S5 pass notes

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
- Current behavior (S3): invalid default mode now falls back to `disabled` with explicit error logging.

Why safe:

- Only affects invalid configuration values; valid deployments keep existing behavior.
- Prevents accidental route enablement due to typos.

Verification:

- `normalize_cutover_invalid_op_mode_blocks_with_config_error_test` passes.
- `normalize_cutover_invalid_default_mode_falls_back_to_enabled_test` is historical naming; expected behavior is now fail-closed to disabled.

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

## Remediations Implemented in S1

### S1-001: Listener supervision + protocol limits (CG-017)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_app.erl`
- `apps/riak_admin_api/src/riak_admin_api_sup.erl`
- `apps/riak_admin_api/test/riak_admin_api_app_test.erl`

What changed:

- Cowboy listener moved under supervisor via `ranch:child_spec/5`.
- Supervisor strategy changed to `rest_for_one` (listener crash restarts coordinator).
- Added configurable protocol limits (idle_timeout, request_timeout, max_keepalive, max_header_name_length, max_header_value_length, max_headers).

Why safe:

- Listener crash now auto-restarts instead of silent unavailability. Protocol limits have safe defaults.

Verification:

- `listener_child_spec_returns_valid_child_spec_test` passes.
- `protocol_opts_returns_default_values_test` passes.
- `protocol_opts_respects_env_overrides_test` passes.

### S1-002: Parallel pings with bounded timeout (CG-015)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- `cluster_status/0` now uses `parallel_ping_nodes/2` instead of sequential `net_adm:ping/1`.
- Configurable via `cluster_status_ping_timeout` (default: 3000 ms).

Why safe:

- Total cluster_status latency bounded to timeout regardless of unreachable node count.

Verification:

- `parallel_ping_nodes_empty_list_test` passes.
- `parallel_ping_nodes_unreachable_returns_false_test` passes.

### S1-003: Stream collection ceiling (CG-016)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- Added `stream_collection_ceiling/0` (default: 300000 ms) as safety cap on `collect_stream_buckets` and `collect_stream_keys` loops.
- Warning logged when ceiling fires.

Why safe:

- Does not replace per-stream timeouts — applied as `min(stream_timeout, ceiling)`.

Verification:

- `stream_collection_ceiling_default_test` passes.
- `stream_collection_ceiling_override_test` passes.

### S1-004: MapReduce timeout unified to 503 (CG-005/CG-018)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/test/riak_admin_api_riak_test.erl`

What changed:

- MapReduce timeout errors return `503 timeout` (was `500 timeout`) in both chunked and nonchunked paths.
- Added `list_keys_error_mode/0` toggle: `compat` (default, 200 with embedded error) or `strict` (proper HTTP error).

Why safe:

- 503 is correct HTTP semantics for retryable timeout. `compat` mode preserves backward compatibility.

Verification:

- `mapred_timeout_error_map_returns_503_test` passes.
- `list_keys_error_mode_default_compat_test` passes.
- `list_keys_error_mode_strict_test` passes.

### S1-005: Auth guardrails fail-fast (new)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_request.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/test/riak_admin_api_request_test.erl`
- `apps/riak_admin_api/test/riak_admin_api_handler_test.erl`

What changed:

- Added `ensure_auth_guardrails/1` in `ensure_security` chain.
- When `security_require_auth` is `true` and no auth hooks configured, returns `503 auth_not_configured`.

Why safe:

- Default is `false` — no behavior change for existing deployments.

Verification:

- `auth_guardrail_true_no_hooks_returns_503_test` passes.
- `auth_guardrail_true_both_hooks_passes_test` passes.
- `handler_init_with_require_auth_blocks_without_hooks_test` passes.

## Remediations Implemented in S2

### S2-001: True incremental streaming (CG-001)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- `apps/riak_admin_api/src/riak_admin_api_response.erl`

What changed:

- Gateway returns `{stream, StreamInit, ChunkFun}` for key/bucket/index/mapred stream paths.
- Handler uses `cowboy_req:stream_reply/3` + `stream_body/3` for chunked transfer encoding.
- Toggle: `stream_incremental_enabled` (default `true`); `false` preserves aggregated-body compat.

Why safe:

- JSON payload structure preserved. Toggle-controlled. Stream ceiling (S1) still applies.

### S2-002: Conditional-write enforcement (CG-004)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`

What changed:

- `check_write_preconditions/3` implements HTTP-layer If-Match and If-Unmodified-Since via read-before-write.
- Returns 412 on precondition failure. `filter_riak_cond_opts/1` strips HTTP conditionals before Riak put.
- `if_none_match_option/1` (D01) validates that `If-None-Match` only accepts `*`; entity-tag values return 400 `invalid_if_none_match`.

Why safe:

- No overhead when no conditional headers present. Riak native conditionals unchanged.

### S2-003: MapReduce backend operator toggle (CG-006)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`

What changed:

- `mapred_backend_enabled/0` operator toggle (default `true`).
- Disabled returns 503 `service_unavailable`; absent modules still return 501 `not_implemented`.

Why safe:

- Default `true`. Two-level availability with clear error semantics.

### S2-004: CRDT collection redirect parity (CG-007)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`

What changed:

- `maybe_crdt_collection_redirect/1` redirects collection create path (default bucket type, no key) to `/buckets/.../counters`.
- Wired into `crdt_update_operation` for create mode.

Why safe:

- Only fires for default bucket type with no key. Non-default types unaffected.

### S2-005: /riak counters alias explicit rejection (CG-008)

Scope:

- `apps/riak_admin_api/test/riak_admin_api_request_test.erl` (test evidence only)

What changed:

- Decision: no alias. `/riak` normalizer catch-all returns 404 for paths beyond 2 segments. Test evidence confirms.

Why safe:

- No behavioral change — path was always 404.

## Deferred Remediation Plans

### D-001: True incremental streaming/backpressure (CG-001)

Status: **Closed (S2)** — incremental streaming via `{stream, StreamInit, ChunkFun}` pattern.

### D-002: Conditional-write completeness (CG-004)

Status: **Closed (S2)** — read-before-write enforcement for If-Match and If-Unmodified-Since.

### D-003: Timeout semantics alignment (CG-005)

Status: **Closed (S1)** — MapReduce timeout unified to 503 via `mapred_timeout_error_map/0`.

### D-004: MapReduce backend availability control (CG-006)

Status: **Closed (S2)** — two-level operator toggle (503 disabled / 501 absent).

### D-005: CRDT redirect parity scope (CG-007)

Status: **Closed (S2)** — collection redirect added for default bucket type create path.

### D-006: `/riak` counters alias parity decision (CG-008)

Status: **Closed (S2)** — explicit rejection with 404 test evidence and rationale documented.

### SD-001: net_adm:ping sequential latency (CG-015)

Status: **Closed (S1)** — replaced with `parallel_ping_nodes/2`.

### SD-002: Stream collection handler blocking (CG-016)

Status: **Closed (S1)** — added `stream_collection_ceiling/0` safety cap. Full spawn-with-backpressure superseded by CG-001 (S2).

### SD-003: Listener supervision architecture (CG-017)

Status: **Closed (S1)** — listener under supervisor via `ranch:child_spec/5`.

### SD-004: Timeout contract unification (CG-018)

Status: **Closed (S1)** — see D-003 / S1-004.

## Remediations Implemented in S5

### S5-001: CORS response headers (M-4)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_response.erl`
- `apps/riak_admin_api/src/riak_admin_api_handler.erl`

What changed:

- Added `cors_headers/2` that emits Access-Control-Allow-Origin and related headers when trusted_origins matches the request Origin.
- `compat_headers/1` merges CORS headers into every response.
- Handler threads `request_origin` and `trusted_origins` into response opts.

Why safe:

- Default (empty trusted_origins) emits no CORS headers. Strictly additive.

### S5-002: Stream error framing consistency (M-7)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_riak.erl`

What changed:

- Introduced `encode_stream_error/1` as the single stream error JSON encoder.
- Bucket/key/index/mapred stream error paths all delegate to it.
- MapReduce stream errors changed from jsx to mochijson2 for consistency.

Why safe:

- Bucket/key/index output is byte-identical. MapReduce stream error shape simplified (minor wire-format change within multipart body).

### S5-003: Body-size enforcement consistency (M-6)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_handler.erl`

What changed:

- `read_request_body/1` now checks `max_request_body_bytes` on the `#{body := Body}` fast path.

Why safe:

- Bodies within the limit are unaffected. Only oversized pre-populated bodies now correctly trigger 413.

### S5-004: Conversion helper consolidation (M-2)

Scope:

- `apps/riak_admin_api/src/riak_admin_api_response.erl`
- `apps/riak_admin_api/src/riak_admin_api_request.erl`

What changed:

- `to_binary/1` exported from response module as canonical version.
- Request module's `to_binary/1` delegates to response module.
- Gateway's `to_bin/1` documented as local alias of the canonical version.

Why safe:

- All three implementations were functionally identical. No behavioral change.

### S5-005: JSON library consistency plan (M-1)

Documentation only. Approved encode/decode paths documented per context. Full migration deferred with rationale.

### S5-006: L-level cleanup (L-1)

- `encode_index_error` consolidated from 3 clauses to 2 via delegation to `encode_stream_error/1`.
- Documentation comments added to `to_bin/1` in gateway module.
