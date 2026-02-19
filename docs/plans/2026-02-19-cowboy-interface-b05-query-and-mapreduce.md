# B05 - Advanced Query and MapReduce

Batch ID: B05
Branch: `feature/cowboy-b05-query-mapred`
Depends on: B04

## Objective

Migrate advanced query and mapreduce HTTP paths to Cowboy while preserving payload shape and failure semantics.

## Scope

- Implement query endpoint parity for posted JSON query definitions.
- Implement mapreduce request path parity including chunked/streaming mode behavior.
- Preserve timeout handling and JSON error envelope compatibility.
- Preserve permission checks and request class handling.

## Out of scope

- CRDT/counter paths (B06).
- Final performance hardening and cutover (B07/B08).

## Inputs

- B04 streaming utilities
- `openriak-3.4/src/riak_kv_wm_query.erl`
- `openriak-3.4/src/riak_kv_wm_mapred.erl`

## Deliverables

1. Cowboy query and mapreduce handlers.
2. Structured parser/validator for query payloads mirroring accepted field set.
3. Artifact doc:
   - `docs/plans/artifacts/cowboy-query-mapred-parity-notes.md`

## Exit criteria

- Legacy test payloads produce equivalent success/error status and body semantics.
- Streamed mapreduce output format documented and validated.

## Verification evidence

- Contract tests for known query payload variants.
- Stream tests for mapreduce chunk boundaries and completion behavior.

## Context Capsule (update at completion)

```yaml
batch: B05
status: planned
branch: feature/cowboy-b05-query-mapred
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-query-mapred-parity-notes.md
decisions:
  - TBD
open_risks:
  - long-running query cancellation behavior
handoff_notes:
  - B06 should retain error taxonomy used here
```

## Sync-Back Command (required)

After committing B05 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B05_COMMIT_SHA>`
