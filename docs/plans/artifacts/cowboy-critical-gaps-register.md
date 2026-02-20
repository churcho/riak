# Cowboy Critical Gaps Register (D01 + S0 + S1 + S2 + S5)

Date: 2026-02-20
Status: Active

## Severity Legend

- `P0`: high probability/high impact correctness or safety risk.
- `P1`: meaningful contract/operational risk, not immediate catastrophic failure.
- `P2`: important parity/design debt; acceptable with explicit plan.

## Gaps

| Gap ID | Severity | Gap | Current status | Fixed now? | Evidence / notes | Deferred acceptance criteria |
|---|---|---|---|---|---|---|
| CG-001 | P1 | Stream-mode uses aggregated response bodies instead of true incremental Cowboy streaming/backpressure | Closed (S2) | Yes | Gateway now returns `{stream, StreamInit, ChunkFun}` for key/bucket/index/mapred paths; handler uses `cowboy_req:stream_reply/3` + `stream_body/3`; toggle `stream_incremental_enabled` (default `true`) preserves compat path | N/A |
| CG-002 | P1 | Telemetry lacked explicit `error_code` dimension | Closed (D01) | Yes | Added `error_code` telemetry tag dimension and error telemetry context propagation | N/A |
| CG-003 | P0 | Cutover misconfiguration risk: invalid `cowboy_cutover_op_modes` values silently enabled routes | Closed (D01) | Yes | Invalid per-op mode now fails closed with `503 route_cutover_misconfigured` | N/A |
| CG-004 | P0 | Conditional write enforcement gaps for `If-Match` and `If-Unmodified-Since` | Closed (S2) | Yes | Added `check_write_preconditions/3` with read-before-write pattern; If-Match checks vtags, If-Unmodified-Since checks last-modified; returns 412 on failure; `filter_riak_cond_opts/1` strips HTTP conditionals before Riak put | N/A |
| CG-005 | P1 | Query vs mapreduce timeout semantics inconsistent | Closed (S1) | Yes | MapReduce timeout unified to 503; list_keys error mode toggle added (compat/strict) | N/A |
| CG-006 | P1 | MapReduce backend unavailable path (`501 not_implemented`) may surprise clients in stripped builds | Closed (S2) | Yes | Added `mapred_backend_enabled/0` operator toggle (default `true`); disabled returns 503 `service_unavailable`; absent modules still return 501 `not_implemented`; two-level availability with clear error semantics | N/A |
| CG-007 | P2 | CRDT default redirect parity scope is partial | Closed (S2) | Yes | Added `maybe_crdt_collection_redirect/1` for collection/create path with default bucket type; returns 301 to `/buckets/.../counters`; keyed and collection redirects now symmetric | N/A |
| CG-008 | P2 | `/riak` counters alias parity decision unresolved | Closed (S2) | Yes | Decision: explicit rejection (no alias). `/riak` normalizer catch-all returns 404 `unknown_route` for any path beyond 2 segments. Test evidence confirms `/riak/b/counters/k` returns 404 | N/A |
| CG-009 | P0 | Unsafe `binary_to_term/1` without `[safe]` in x-erlang-binary accept path | Closed (S0) | Yes | Replaced with `binary_to_term(Body, [safe])` + atom injection test | N/A |
| CG-010 | P0 | TLS check bypassed by spoofing `X-Forwarded-Proto` header | Closed (S0) | Yes | Proxy trust now requires explicit `security_trust_proxy_headers => true` + header spoofing regression tests | N/A |
| CG-011 | P0 | No request body size limit — unbounded memory consumption | Closed (S0) | Yes | Added `max_request_body_bytes` (default 5 MiB) with 413 on breach + size limit tests | N/A |
| CG-012 | P0 | Substrate/data-path routes open by default on admin port | Closed (S0) | Yes | `cowboy_cutover_default_mode` changed to `disabled` + default-disabled tests | N/A |
| CG-013 | P1 | Origin check allows missing Origin on unsafe methods when trusted_origins configured | Closed (S0) | Yes | Missing Origin now denied for unsafe methods when origin policy active + regression tests | N/A |
| CG-014 | P0 | Docs claim compile-time isolation but `-include_lib` creates hard riak_kv compile dep | Closed (S0) | Yes | Corrected module docs and .app.src to accurately document compile-time dependency | N/A |
| CG-015 | P1 | `net_adm:ping` sequential latency blocks cluster_status for unreachable nodes | Closed (S1) | Yes | Replaced with `parallel_ping_nodes/2` with configurable timeout (default 3s) | N/A |
| CG-016 | P1 | Synchronous stream collection blocks Cowboy handler processes | Closed (S1) | Yes | Added `stream_collection_ceiling/0` (default 5 min) as safety cap on all stream loops | N/A |
| CG-017 | P1 | Cowboy listener started outside supervision tree | Closed (S1) | Yes | Listener now under supervisor via `ranch:child_spec/5` + protocol limits + `rest_for_one` strategy | N/A |
| CG-018 | P1 | MapReduce/query timeout semantics inconsistent (503 vs 500) | Closed (S1) | Yes | MapReduce timeout unified to 503 via `mapred_timeout_error_map/0` | N/A |

## Fixed-Now Summary

- `CG-001` (`P1`): true incremental streaming via chunked Cowboy transfer with toggle (S2).
- `CG-002` (`P1`): telemetry error code dimension implemented (D01).
- `CG-003` (`P0`): cutover misconfiguration now fails closed for invalid per-op modes (D01).
- `CG-004` (`P0`): conditional-write enforcement for If-Match and If-Unmodified-Since via read-before-write (S2).
- `CG-005` (`P1`): mapred timeout unified to 503 + list_keys error mode toggle (S1).
- `CG-006` (`P1`): MapReduce backend operator toggle with two-level availability (503 disabled / 501 absent) (S2).
- `CG-007` (`P2`): CRDT collection redirect parity for default bucket type create path (S2).
- `CG-008` (`P2`): /riak counters alias explicitly rejected with 404 test evidence (S2).
- `CG-009` (`P0`): unsafe `binary_to_term` replaced with safe variant (S0).
- `CG-010` (`P0`): TLS header spoofing closed via proxy trust gate (S0).
- `CG-011` (`P0`): request body size limit added (S0).
- `CG-012` (`P0`): substrate routes disabled by default (S0).
- `CG-013` (`P1`): origin policy hardened for unsafe methods (S0).
- `CG-014` (`P0`): compile-time isolation docs corrected (S0).
- `CG-015` (`P1`): sequential pings replaced with parallel + bounded timeout (S1).
- `CG-016` (`P1`): stream collection ceiling added to prevent unbounded blocking (S1).
- `CG-017` (`P1`): Cowboy listener moved under supervisor with protocol limits (S1).
- `CG-018` (`P1`): mapred timeout unified to 503 (S1).

## Medium/Low Quality Items (S5)

| Item ID | Severity | Item | Status | Evidence |
|---|---|---|---|---|
| M-4 | Medium | No CORS response headers emitted despite origin validation | Closed (S5) | `cors_headers/2` emits CORS headers when origin matches trusted_origins; 8 tests |
| M-7 | Medium | Stream error framing inconsistent across bucket/key/index/mapred | Closed (S5) | Unified `encode_stream_error/1` used by all stream paths; 3 tests |
| M-6 | Medium | Body-size limit bypassed via #{body := Body} fast path | Closed (S5) | `read_request_body/1` enforces limit on pre-populated bodies; 2 tests |
| M-2 | Medium | `to_bin`/`to_binary` duplicated across 3 modules | Closed (S5) | `riak_admin_api_response:to_binary/1` exported as canonical; request module delegates; gateway documents relationship; 5 tests |
| M-1 | Medium | JSON library (mochijson2 vs jsx) usage undocumented | Closed (S5) | Documented approved encode/decode paths per context; migration deferred with rationale |
| L-1 | Low | Minor boilerplate in stream error encoding | Closed (S5) | `encode_index_error` consolidated to delegate through `encode_stream_error/1` |

## Deferred-Now Summary

All 18 critical gaps closed. 6 medium/low quality items closed in S5. No remaining deferred items.
