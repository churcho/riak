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

## Context Capsule (update at completion)

```yaml
batch: B07
status: planned
branch: feature/cowboy-b07-verification-perf
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-contract-harness.md
  - docs/plans/artifacts/cowboy-performance-report.md
  - docs/plans/artifacts/cowboy-observability-map.md
decisions:
  - TBD
open_risks:
  - residual performance gaps
handoff_notes:
  - B08 should only proceed if release gates are met
```

## Sync-Back Command (required)

After committing B07 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B07_COMMIT_SHA>`
