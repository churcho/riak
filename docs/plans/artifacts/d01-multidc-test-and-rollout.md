# D01 Multi-DC Test and Rollout Plan

Date: 2026-02-20
Status: Execution plan

## Objectives

- Validate D01 routing/failure contracts without breaking existing Cowboy parity behavior.
- Roll out distribution controls in staged, reversible increments.

## Test Strategy

### 1) Contract Tests (route/parser/internal discipline)

Required for any D01 route-affecting or policy-affecting changes:

- Path -> normalized operation test coverage (`riak_admin_api_request_test`).
- Operation -> backend action mapping coverage (`riak_admin_api_handler` family tests).
- Error envelope coverage for distribution failures (`dc_unreachable`, `dc_timeout`, `partial`).
- Cutover/distribution mode precedence tests.

### 2) Failure Injection Tests

- Remote DC unreachable (network partition simulation).
- Remote DC slow responses (timeout budget exceed).
- Mixed metadata versions (v1 + v2 syn entries).
- Partial aggregate-read fanout success.

Expected outcomes:

- No crash loops.
- Deterministic status/error envelopes.
- `request_id` + telemetry correlation retained.

### 3) Performance/Capacity Checks

- Local-first p95/p99 unchanged for local-success path.
- Remote-forward tail-latency monitored separately.
- Aggregate-read fanout bounded by concurrency guardrails.

### 4) Regression Suite

Mandatory command before each rollout gate:

- `./rebar3 eunit apps=riak_admin_api`

Add focused module runs for D01 behavior as they are introduced.

## Rollout Phases

1. **Phase 0: Dark-launch controls only**
   - Ship policy resolver and metadata reader changes with forwarding/aggregation disabled.
2. **Phase 1: Canary DC (read-only remote-forward)**
   - Enable explicit remote-forward for a narrow read-only endpoint set.
3. **Phase 2: Aggregate-read admin endpoints**
   - Enable partial aggregate contract for `/api/dcs` and `/api/cluster/status`.
4. **Phase 3: Expanded read coverage**
   - Add approved read endpoints (`keys`, `index_query`, `query`) under local-first with controlled remote fallback.
5. **Phase 4: General availability**
   - Keep writes local-only by default; remote write forwarding remains explicit opt-in.

## Rollback Plan

- Immediate: disable D01 distribution modes via kill-switch configuration.
- Fallback behavior: all endpoints return to local-only/local-first local path.
- Preserve compatibility: no route removals required; existing cutover controls remain active.

## Acceptance Gates

- Zero P0 open for D01 policy execution path.
- No increase in parity regression failures.
- Observability includes route/op/alias/status/error_code/request_id and DC target fields.
- Partial-failure contracts validated in automated tests and canary logs.
