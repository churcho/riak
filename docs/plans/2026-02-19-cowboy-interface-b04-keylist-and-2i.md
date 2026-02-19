# B04 - Key Listing and Secondary Index

Batch ID: B04
Branch: `feature/cowboy-b04-keylist-2i`
Depends on: B03

## Objective

Migrate key listing and 2i endpoints with correct streaming, continuation, and timeout/backpressure behavior.

## Scope

- Implement key listing endpoints (`keys=true|stream`) with compatibility JSON output.
- Implement secondary index endpoints:
  - exact and range lookups,
  - `max_results`, `continuation`, `return_terms`, `pagination_sort`, `timeout`.
- Implement stream mode for index responses with compatibility chunk boundaries/body format.
- Ensure request class and permission handling parity.

## Out of scope

- Complex query endpoint and mapreduce (B05).
- CRDT and counters (B06).

## Inputs

- B03 route + serializer substrate
- `openriak-3.4/src/riak_kv_wm_keylist.erl`
- `openriak-3.4/src/riak_kv_wm_index.erl`

## Deliverables

1. Cowboy key listing handlers and stream responders.
2. Cowboy 2i handlers with continuation support.
3. Artifact doc:
   - `docs/plans/artifacts/cowboy-keylist-2i-parity-notes.md`

## Exit criteria

- Compatibility test corpus passes for non-stream and stream modes.
- Continuation token behavior is stable and documented.
- Large result sets do not cause unbounded memory growth.

## Verification evidence

- Stream soak tests and timeout tests.
- Benchmarks for large key/index responses with p95 latency evidence.

## Context Capsule (update at completion)

```yaml
batch: B04
status: planned
branch: feature/cowboy-b04-keylist-2i
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-keylist-2i-parity-notes.md
decisions:
  - TBD
open_risks:
  - multipart stream compatibility for old clients
  - continuation token stability
handoff_notes:
  - B05 should reuse 2i timeout and stream helpers
```

## Sync-Back Command (required)

After committing B04 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B04_COMMIT_SHA>`
