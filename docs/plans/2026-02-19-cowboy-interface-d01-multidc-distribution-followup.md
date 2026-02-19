# D01 - Multi-DC Distribution and syn Evolution (Post-Cutover)

Track ID: D01
Branch: `feature/cowboy-d01-multidc-distribution`
Status: Deferred (start only after B08)
Depends on: B08 completion and stable Cowboy parity rollout

## Why this is deferred

The current migration priority is compatibility and performance parity for Cowboy HTTP endpoints. Adding multi-DC distribution behavior during parity work would mix two high-risk changes and slow cutover.

Decision:
- Keep existing syn integration as the control-plane discovery baseline now.
- Defer data-plane multi-DC distribution/routing behavior to D01.

## Baseline already present

- syn-based admin discovery and metadata propagation are already in branch history.
- Startup wiring exists in `apps/riak_admin_api/src/riak_admin_api_app.erl`.
- Coordinator and event handling exist in:
  - `apps/riak_admin_api/src/riak_admin_api_coordinator.erl`
  - `apps/riak_admin_api/src/riak_admin_event_handler.erl`
- Existing design notes live in `apps/riak_admin_api/doc/SYN_INTEGRATION.md`.

## D01 scope

1. Multi-DC request routing strategy for Cowboy APIs:
   - local-first,
   - remote forwarding policy,
   - failure behavior and timeout budgets.
2. Distribution-aware endpoint behavior:
   - read aggregation strategy,
   - write routing constraints,
   - consistency and conflict expectations.
3. syn model evolution (if needed):
   - metadata schema versioning,
   - health signal enrichment,
   - stale membership handling.
4. Operational controls:
   - kill switches,
   - per-DC allow/deny controls,
   - observability and alerting for cross-DC behavior.

## Out of scope for D01

- Rewriting the already completed Cowboy compatibility substrate.
- Changing endpoint contracts unless explicitly versioned.

## Entry criteria (must be true before starting D01)

- B08 marked complete in context chain.
- Cowboy cutover running stably for at least one validation window.
- No open P0/P1 parity regressions from B00-B08.
- Contract and performance artifacts from B07 available and accepted.

## Expected deliverables

1. D01 architecture decision record:
   - `docs/plans/artifacts/d01-multidc-routing-adr.md`
2. Distribution behavior matrix:
   - `docs/plans/artifacts/d01-distribution-behavior-matrix.md`
3. syn metadata evolution spec:
   - `docs/plans/artifacts/d01-syn-metadata-evolution.md`
4. Test and rollout plan:
   - `docs/plans/artifacts/d01-multidc-test-and-rollout.md`

## Key risks to manage

- Cross-DC latency amplification and tail latency spikes.
- Inconsistent read behavior across partially reachable DCs.
- Over-coupling data-plane behavior to syn membership events.
- Operator confusion if route/consistency policy is not explicit per endpoint.

## Open questions to answer at D01 kickoff

1. Which endpoints are eligible for remote forwarding vs local-only?
2. How should partial DC failure be represented to clients?
3. What are the required consistency guarantees per endpoint class?
4. Should forwarding be transparent or explicit via new API options/headers?
5. Do we need separate syn scopes for different subsystem concerns?

## New-agent restart protocol for D01

When D01 starts in a fresh context window, read in order:

1. `docs/plans/2026-02-19-cowboy-interface-design.md`
2. `docs/plans/2026-02-19-cowboy-interface-context-chain.md`
3. `docs/plans/2026-02-19-cowboy-interface-d01-multidc-distribution-followup.md`
4. `apps/riak_admin_api/doc/SYN_INTEGRATION.md`
5. B07/B08 artifact docs (performance + cutover + rollback)

Then create a dedicated D01 plan before coding.

## Sync-Back Command (required)

After committing D01 work in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <D01_COMMIT_SHA>`
