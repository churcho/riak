# Cowboy Performance Report (B07)

Date: 2026-02-19  
Batch: B07  
Branch: `feature/cowboy-b07-verification-perf`

## Test Setup

- Environment: local development worktree benchmark (single node process, synthetic request maps).
- Scope:
  - Request normalization hot-path microbench (`riak_admin_api_request:normalize/2`).
  - Telemetry tag construction microbench (`riak_admin_api_response:telemetry_tags/3`).
  - Full endpoint regression via `./rebar3 eunit apps=riak_admin_api`.
- Runner:
  - `apps/riak_admin_api/test/cowboy_perf_probe.escript` (5000 iterations per scenario).

## Performance Targets (B07 Release Gates)

- Contract harness: all endpoint families pass (`0` failures).
- Full EUnit (`apps=riak_admin_api`): pass with `0` failures.
- Perf probe correctness: `errors=0` in all scenarios.
- Latency thresholds (microbench):
  - Request normalization p95: <= 200 us per scenario.
  - Request normalization p99: <= 500 us per scenario.
  - Telemetry tag generation p95: <= 50 us.

## Exact Commands Run

1. `./apps/riak_admin_api/test/cowboy_perf_probe.escript`
2. `./apps/riak_admin_api/test/cowboy_contract_harness.sh`
3. `./rebar3 eunit apps=riak_admin_api`

## Measurements

Command: `./apps/riak_admin_api/test/cowboy_perf_probe.escript`

| Scenario | Errors | Mean (us) | p50 (us) | p95 (us) | p99 (us) | Max (us) |
|---|---:|---:|---:|---:|---:|---:|
| `request.normalize.object_get` | 0 | 1.39 | 1 | 1 | 2 | 1745 |
| `request.normalize.bucket_props_get` | 0 | 1.01 | 1 | 1 | 2 | 25 |
| `request.normalize.keys_list` | 0 | 1.40 | 1 | 2 | 2 | 30 |
| `request.normalize.index_range` | 0 | 1.63 | 2 | 2 | 3 | 76 |
| `request.normalize.query_post` | 0 | 1.01 | 1 | 1 | 2 | 67 |
| `request.normalize.mapred_post_chunked` | 0 | 1.22 | 1 | 2 | 2 | 73 |
| `request.normalize.counter_post_returnvalue` | 0 | 1.28 | 1 | 2 | 2 | 39 |
| `request.normalize.crdt_get` | 0 | 1.71 | 2 | 2 | 3 | 176 |
| `request.normalize.error_invalid_query` | 0 | 0.59 | 0 | 1 | 2 | 86 |
| `response.telemetry_tags` | 0 | 0.25 | 0 | 0 | 1 | 1000 |

Perf probe summary: `scenarios=10 errors=0`.

Command: `./apps/riak_admin_api/test/cowboy_contract_harness.sh`  
Contract harness summary: `pass=8 fail=0 total=8`.

Command: `./rebar3 eunit apps=riak_admin_api`  
Global verification: `All 200 tests passed`.

## Interpretation vs Targets

- Pass: all B07 release gates met in this environment.
  - Contract harness gate: pass (`0` family failures).
  - EUnit gate: pass (`200` tests, `0` failures).
  - Perf correctness gate: pass (`0` scenario errors).
  - p95/p99 latency gates: pass for all measured scenarios.
- Notes on maxima:
  - Single-iteration spikes (`max_us`) are present in two scenarios (`object_get`, `telemetry_tags`) and are treated as local scheduler/runtime jitter because p95/p99 stayed within target.
- B08 cutover implication:
  - Synthetic probe does not replace cluster-load testing; it is accepted as B07 baseline evidence and should be complemented by staged production-like load in B08.

## Known Performance Risks

- Benchmarks are micro-level and in-process; they do not include socket I/O, network latency, real Riak cluster contention, or multi-node fanout.
- Stream-mode endpoints still use aggregated-body compatibility responses, so chunk/backpressure behavior remains a known gap for production-scale traffic.

---

## S1 Resilience Hardening Addendum

Date: 2026-02-20
Branch: `feature/cowboy-s1-resilience-perf`

### S1 Performance Impact Assessment

| Change | Expected Impact | Risk |
|---|---|---|
| Listener under supervisor | Negligible — adds one supervisor level; ranch already manages acceptor pools | Low |
| Protocol limits (idle_timeout, request_timeout, etc.) | Positive — bounds resource consumption from slow/abandoned connections | Low |
| Parallel pings (CG-015) | Positive — cluster_status latency bounded to max 3s instead of N * TCP timeout for N unreachable nodes | Low |
| Stream collection ceiling (CG-016) | Positive — prevents unbounded handler blocking; normal operations unaffected since ceiling (5 min) >> typical stream time | Low |
| MapReduce timeout 503 (CG-018) | Negligible — status code change only, no latency impact | Low |
| list_keys error mode toggle | Negligible — single branch in error path | Low |
| Auth guardrails | Negligible — single map lookup added to ensure_security chain (default: disabled) | Low |

### S1 Verification

Command: `./rebar3 eunit --module=riak_admin_api_app_test,riak_admin_api_riak_test,riak_admin_api_request_test,riak_admin_api_handler_test`
Result: All 151 tests passed.
