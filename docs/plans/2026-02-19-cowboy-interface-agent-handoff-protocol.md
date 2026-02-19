# Agent Handoff Protocol (New Context Windows)

This protocol is mandatory for every batch branch in the Cowboy migration program.

## Read order for a new agent

1. `docs/plans/2026-02-19-cowboy-interface-design.md`
2. `docs/plans/2026-02-19-cowboy-interface-context-chain.md`
3. Current batch doc (`docs/plans/2026-02-19-cowboy-interface-bXX-...md`)
4. Previous batch doc `Context Capsule`

If working deferred multi-DC track:
5. `docs/plans/2026-02-19-cowboy-interface-d01-multidc-distribution-followup.md`

## Branch boot checklist

- Confirm previous batch status is `Done` in context chain.
- Confirm base commit from context chain before creating branch.
- Confirm expected artifact inputs from previous batch exist.

## End-of-batch closeout checklist

1. Update current batch `Context Capsule` fields:
   - `status`, `base_commit`, `end_commit`, `decisions`, `open_risks`, `handoff_notes`.
2. Update context chain row for this batch.
3. Add/refresh artifact docs referenced by batch deliverables.
4. Sync batch commit into `feature/cowboy-client` immediately:
   - `git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <BATCH_COMMIT_SHA>`
5. Add "Known deviations" section if any parity/perf target is not met.

## Standard context capsule schema

```yaml
batch: BXX
status: planned|in_progress|done
branch: feature/cowboy-bXX-...
base_commit: <sha>
end_commit: <sha>
artifacts:
  - docs/plans/artifacts/<file>.md
decisions:
  - <decision with rationale>
open_risks:
  - <risk and impact>
handoff_notes:
  - <what next batch must know>
```

## Agent startup prompt template

Use this prompt when opening a new context window:

```text
Continue Cowboy migration batch BXX.

Read, in order:
1) docs/plans/2026-02-19-cowboy-interface-design.md
2) docs/plans/2026-02-19-cowboy-interface-context-chain.md
3) docs/plans/2026-02-19-cowboy-interface-bXX-<name>.md
4) previous batch B(X-1) context capsule

Operate only within BXX scope. Reuse prior batch artifacts. Update BXX context capsule and context-chain at completion.
```
