# B06 - CRDT and Counter Endpoints

Batch ID: B06
Branch: `feature/cowboy-b06-crdt-counter`
Depends on: B05

## Objective

Migrate CRDT and counter APIs to Cowboy, including datatype-specific payload parsing and compatibility responses.

## Scope

- Implement legacy counter endpoint behavior (GET/POST counter semantics).
- Implement CRDT endpoint behavior for supported datatypes and operations.
- Preserve include_context and returnbody semantics.
- Preserve compatibility error handling for datatype, quorum, and notfound/deleted states.

## Out of scope

- Full end-to-end performance and contract burn-in (B07).
- Production cutover and deprecation actions (B08).

## Inputs

- B05 shared parser/error primitives
- `openriak-3.4/src/riak_kv_wm_counter.erl`
- `openriak-3.4/src/riak_kv_wm_crdt.erl`

## Deliverables

1. Cowboy counter and CRDT handlers.
2. Datatype operation parser + validation helpers.
3. Artifact doc:
   - `docs/plans/artifacts/cowboy-crdt-counter-parity-notes.md`

## Exit criteria

- Compatibility corpus passes for counter and CRDT paths.
- Datatype validation errors map to stable API responses.

## Verification evidence

- Handler tests for operation parsing and malformed payloads.
- Integration tests for counter increment/decrement and CRDT updates.

## Context Capsule (update at completion)

```yaml
batch: B06
status: planned
branch: feature/cowboy-b06-crdt-counter
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-crdt-counter-parity-notes.md
decisions:
  - TBD
open_risks:
  - datatype edge-case parity
handoff_notes:
  - B07 should include these endpoints in perf suite
```

## Route Matching and Parser Discipline (required)

For any route additions/changes, follow:

`docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

B06 artifact notes must include Route Matching Evidence:
- external path template,
- normalized operation id,
- internal gateway call/action,
- tests that prove mapping.

## Sync-Back Command (required)

After committing B06 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B06_COMMIT_SHA>`
