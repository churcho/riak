# B08 - Cutover and Webmachine Deprecation

Batch ID: B08
Branch: `feature/cowboy-b08-cutover`
Depends on: B07

## Objective

Execute controlled cutover to Cowboy-first HTTP handling with clear rollback options and deprecation documentation.

## Scope

- Introduce cutover switches/flags at route level.
- Stage rollout plan (dev -> staging -> production cohorts).
- Define rollback runbook per endpoint group.
- Finalize docs for operators and integrators.
- Mark legacy Webmachine paths as deprecated according to release policy.

## Out of scope

- New feature development unrelated to migration.
- Multi-DC data distribution/routing features and expanded syn behavior (tracked in D01).

## Inputs

- B07 performance and contract verification artifacts.
- Security and observability decisions from prior batches.

## Deliverables

1. Cutover runbook:
   - `docs/plans/artifacts/cowboy-cutover-runbook.md`
2. Rollback runbook:
   - `docs/plans/artifacts/cowboy-rollback-runbook.md`
3. Public-facing migration notes:
   - `docs/plans/artifacts/cowboy-client-migration-notes.md`
4. Final update to context chain with completed migration state.

## Exit criteria

- Cutover flags and rollback switches are tested.
- Operational docs are complete and reviewed.
- Legacy route status is explicit (supported/deprecated/removed timeline).

## Verification evidence

- Dry-run cutover and rollback execution notes.
- Final checklist signoff in artifact docs.

## Context Capsule (update at completion)

```yaml
batch: B08
status: planned
branch: feature/cowboy-b08-cutover
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-cutover-runbook.md
  - docs/plans/artifacts/cowboy-rollback-runbook.md
  - docs/plans/artifacts/cowboy-client-migration-notes.md
decisions:
  - TBD
open_risks:
  - TBD
handoff_notes:
  - migration complete
  - next optional track: D01 multi-DC distribution follow-up
```

## Route Matching and Parser Discipline (required)

For any route additions/changes during cutover hardening, follow:

`docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

B08 artifact notes must include Route Matching Evidence for any path moved, disabled, or remapped.

## Sync-Back Command (required)

After committing B08 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B08_COMMIT_SHA>`
