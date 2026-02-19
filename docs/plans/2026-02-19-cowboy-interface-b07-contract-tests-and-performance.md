# B07 - Contract Tests, Performance, and Observability

Batch ID: B07
Branch: `feature/cowboy-b07-verification-perf`
Depends on: B06

## Objective

Prove functional parity and performance readiness for Cowboy endpoints before cutover.

## Scope

- Build/extend contract test harness that can compare legacy and Cowboy outputs.
- Add endpoint-level observability:
  - latency metrics,
  - status/error counters,
  - request ID tracing links.
- Run load/performance tests and document baseline vs target.
- Define pass/fail release gates for cutover.

## Out of scope

- Final production cutover and deprecation steps (B08).

## Inputs

- Completed endpoint implementations from B02-B06.
- B00 contract matrix.

## Deliverables

1. Contract harness docs and scripts:
   - `docs/plans/artifacts/cowboy-contract-harness.md`
2. Performance report:
   - `docs/plans/artifacts/cowboy-performance-report.md`
3. Observability mapping:
   - `docs/plans/artifacts/cowboy-observability-map.md`

## Exit criteria

- Contract tests cover all migrated endpoint groups.
- Measured p95/p99 latency meets documented target bands.
- Error rates and timeout rates are within budget under load.
- Clear list of known deviations (if any) with explicit risk acceptance.

## Verification evidence

- Test command outputs stored in artifact docs.
- Benchmark runs with configuration details and repeatability notes.

## Known deviations and risk acceptance

- Streaming compatibility modes (`keys=stream`, 2i `stream=true`, mapreduce `chunked=true`) remain aggregated-body compatibility responses.
  - Risk acceptance: accepted for B07 because this matches B03-B06 documented behavior and contract tests.
  - Mitigation: B08 cutover gate requires explicit production-like stream load verification.
- Performance probe is synthetic/in-process and does not represent full network + cluster contention behavior.
  - Risk acceptance: accepted as baseline-only evidence for B07.
  - Mitigation: run staged cluster load validation before/at B08 cutover.
- Telemetry tags do not currently include explicit `error_code` dimension in the emitted tag map.
  - Risk acceptance: accepted for B07 because request-id + status + route/op correlation exists.
  - Mitigation: add structured error-code dimension before full cutover observability SLO enforcement.

## Context Capsule (update at completion)

```yaml
batch: B07
status: done
branch: feature/cowboy-b07-verification-perf
base_commit: 80d4f625
end_commit: see_report_back_output
artifacts:
  - docs/plans/artifacts/cowboy-contract-harness.md
  - docs/plans/artifacts/cowboy-performance-report.md
  - docs/plans/artifacts/cowboy-observability-map.md
decisions:
  - Added a script-based contract harness (`apps/riak_admin_api/test/cowboy_contract_harness.sh`) that validates all migrated endpoint families with independent module gates and non-zero-on-failure behavior.
  - Added a repeatable performance probe (`apps/riak_admin_api/test/cowboy_perf_probe.escript`) with scenario-level latency/error baselines for request normalization and telemetry tagging.
  - Defined B08 release gates in `docs/plans/artifacts/cowboy-performance-report.md` and validated them with recorded command evidence.
  - Documented endpoint observability mapping and request-id trace points in `docs/plans/artifacts/cowboy-observability-map.md`.
open_risks:
  - Benchmark evidence is synthetic and does not yet cover cluster-level network/replica contention under production-like concurrency.
  - Stream-mode compatibility remains aggregated response emission and needs explicit staged-load validation before irreversible cutover.
  - Telemetry dimensions still lack explicit `error_code` tags in logger-emitted telemetry maps.
handoff_notes:
  - B08 should only proceed if the B07 release gates remain green in the target deployment profile.
  - B08 should prioritize structured telemetry/error dimensions and non-synthetic load verification.
  - Keep existing endpoint contracts unchanged; any cutover-time deviations must be documented with rollback criteria.
```

## Route Matching and Parser Discipline (required)

For any route additions/changes, follow:

`docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

B07 artifact notes must include Route Matching Evidence:
- external path template,
- normalized operation id,
- internal gateway call/action,
- tests that prove mapping.

## Sync-Back Command (required)

After committing B07 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B07_COMMIT_SHA>`
