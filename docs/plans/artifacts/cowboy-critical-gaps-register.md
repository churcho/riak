# Cowboy Critical Gaps Register (D01 + S0)

Date: 2026-02-20
Status: Active

## Severity Legend

- `P0`: high probability/high impact correctness or safety risk.
- `P1`: meaningful contract/operational risk, not immediate catastrophic failure.
- `P2`: important parity/design debt; acceptable with explicit plan.

## Gaps

| Gap ID | Severity | Gap | Current status | Fixed now? | Evidence / notes | Deferred acceptance criteria |
|---|---|---|---|---|---|---|
| CG-001 | P1 | Stream-mode uses aggregated response bodies instead of true incremental Cowboy streaming/backpressure | Open | No | Key/bucket/index/mapred stream paths collect then emit aggregated payloads in gateway | Introduce chunked send path + backpressure tests + memory ceiling test under sustained stream load |
| CG-002 | P1 | Telemetry lacked explicit `error_code` dimension | Closed (D01) | Yes | Added `error_code` telemetry tag dimension and error telemetry context propagation | N/A |
| CG-003 | P0 | Cutover misconfiguration risk: invalid `cowboy_cutover_op_modes` values silently enabled routes | Closed (D01) | Yes | Invalid per-op mode now fails closed with `503 route_cutover_misconfigured` | N/A |
| CG-004 | P0 | Conditional write enforcement gaps for `If-Match` and `If-Unmodified-Since` | Open | No | Headers are forwarded but gateway enforcement is incomplete; `x-riak-if-not-modified` is only enforced conditional primitive | Add explicit conditional semantics tests + gateway enforcement mapping + no-regression compatibility evidence |
| CG-005 | P1 | Query vs mapreduce timeout semantics inconsistent | Open | No | Query timeout maps to `503 timeout`; mapred timeout remains `500 timeout` backend-specific | Finalize unified timeout policy or explicitly codify intentional divergence; add client contract tests |
| CG-006 | P1 | MapReduce backend unavailable path (`501 not_implemented`) may surprise clients in stripped builds | Open | No | Backend capability check exists; response contract is stable but requires rollout guardrails | Add startup capability check endpoint/metric + deployment gate that blocks enabling mapred routes when backend absent |
| CG-007 | P2 | CRDT default redirect parity scope is partial | Open | No | Redirect applies to keyed datatype path only; collection path behavior differs | Define explicit parity policy per path and prove expected redirects/non-redirects with tests |
| CG-008 | P2 | `/riak` counters alias parity decision unresolved | Open | No | No `/riak/:bucket/counters/:key` alias route; only `/buckets/:bucket/counters/:key` | ADR decision: either keep no-alias (explicitly documented) or add alias with full route/parser/internal tests |
| CG-009 | P0 | Unsafe `binary_to_term/1` without `[safe]` in x-erlang-binary accept path | Closed (S0) | Yes | Replaced with `binary_to_term(Body, [safe])` + atom injection test | N/A |
| CG-010 | P0 | TLS check bypassed by spoofing `X-Forwarded-Proto` header | Closed (S0) | Yes | Proxy trust now requires explicit `security_trust_proxy_headers => true` + header spoofing regression tests | N/A |
| CG-011 | P0 | No request body size limit — unbounded memory consumption | Closed (S0) | Yes | Added `max_request_body_bytes` (default 5 MiB) with 413 on breach + size limit tests | N/A |
| CG-012 | P0 | Substrate/data-path routes open by default on admin port | Closed (S0) | Yes | `cowboy_cutover_default_mode` changed to `disabled` + default-disabled tests | N/A |
| CG-013 | P1 | Origin check allows missing Origin on unsafe methods when trusted_origins configured | Closed (S0) | Yes | Missing Origin now denied for unsafe methods when origin policy active + regression tests | N/A |
| CG-014 | P0 | Docs claim compile-time isolation but `-include_lib` creates hard riak_kv compile dep | Closed (S0) | Yes | Corrected module docs and .app.src to accurately document compile-time dependency | N/A |
| CG-015 | P1 | `net_adm:ping` sequential latency blocks cluster_status for unreachable nodes | Open | No | Code comment acknowledges issue | Consider async pings with timeout ceiling or cached reachability |
| CG-016 | P1 | Synchronous stream collection blocks Cowboy handler processes | Open | No | collect_stream_buckets/keys/index use blocking receive | Spawn collection in separate process with backpressure |
| CG-017 | P1 | Cowboy listener started outside supervision tree | Open | No | Listener crash = silent admin API unavailability | Use `cowboy:child_spec/3` under supervisor |
| CG-018 | P1 | MapReduce/query timeout semantics inconsistent (503 vs 500) | Open | No | Same as CG-005, tracked separately for timeout contract | Unify to 503 or codify intentional divergence |

## Fixed-Now Summary

- `CG-002` (`P1`): telemetry error code dimension implemented (D01).
- `CG-003` (`P0`): cutover misconfiguration now fails closed for invalid per-op modes (D01).
- `CG-009` (`P0`): unsafe `binary_to_term` replaced with safe variant (S0).
- `CG-010` (`P0`): TLS header spoofing closed via proxy trust gate (S0).
- `CG-011` (`P0`): request body size limit added (S0).
- `CG-012` (`P0`): substrate routes disabled by default (S0).
- `CG-013` (`P1`): origin policy hardened for unsafe methods (S0).
- `CG-014` (`P0`): compile-time isolation docs corrected (S0).

## Deferred-Now Summary

- `CG-001`, `CG-004`, `CG-005`, `CG-006`, `CG-007`, `CG-008` remain deferred with concrete acceptance criteria (D01).
- `CG-015`, `CG-016`, `CG-017`, `CG-018` newly tracked from S0 review, deferred with mitigation notes.
