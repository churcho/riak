# Cowboy Critical Gaps Register (D01)

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
| CG-002 | P1 | Telemetry lacked explicit `error_code` dimension | Closed | Yes | Added `error_code` telemetry tag dimension and error telemetry context propagation | N/A |
| CG-003 | P0 | Cutover misconfiguration risk: invalid `cowboy_cutover_op_modes` values silently enabled routes | Closed | Yes | Invalid per-op mode now fails closed with `503 route_cutover_misconfigured` | N/A |
| CG-004 | P0 | Conditional write enforcement gaps for `If-Match` and `If-Unmodified-Since` | Open | No | Headers are forwarded but gateway enforcement is incomplete; `x-riak-if-not-modified` is only enforced conditional primitive | Add explicit conditional semantics tests + gateway enforcement mapping + no-regression compatibility evidence |
| CG-005 | P1 | Query vs mapreduce timeout semantics inconsistent | Open | No | Query timeout maps to `503 timeout`; mapred timeout remains `500 timeout` backend-specific | Finalize unified timeout policy or explicitly codify intentional divergence; add client contract tests |
| CG-006 | P1 | MapReduce backend unavailable path (`501 not_implemented`) may surprise clients in stripped builds | Open | No | Backend capability check exists; response contract is stable but requires rollout guardrails | Add startup capability check endpoint/metric + deployment gate that blocks enabling mapred routes when backend absent |
| CG-007 | P2 | CRDT default redirect parity scope is partial | Open | No | Redirect applies to keyed datatype path only; collection path behavior differs | Define explicit parity policy per path and prove expected redirects/non-redirects with tests |
| CG-008 | P2 | `/riak` counters alias parity decision unresolved | Open | No | No `/riak/:bucket/counters/:key` alias route; only `/buckets/:bucket/counters/:key` | ADR decision: either keep no-alias (explicitly documented) or add alias with full route/parser/internal tests |

## Fixed-Now Summary

- `CG-002` (`P1`): telemetry error code dimension implemented.
- `CG-003` (`P0`): cutover misconfiguration now fails closed for invalid per-op modes.

## Deferred-Now Summary

- `CG-001`, `CG-004`, `CG-005`, `CG-006`, `CG-007`, `CG-008` remain deferred with concrete acceptance criteria and test expectations.
