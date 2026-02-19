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
status: done
branch: feature/cowboy-b04-keylist-2i
base_commit: 3860928b
end_commit: see_report_back_output
artifacts:
  - docs/plans/artifacts/cowboy-keylist-2i-parity-notes.md
decisions:
  - Added Cowboy route declarations for `/buckets/.../index/...` and `/types/.../index/...` so route matching and parser normalization stay in lockstep for B04.
  - Replaced deferred handler branches with concrete dispatch for `keys` and `index_query`, mapped to `riak_admin_api_riak:bucket_operation(list_keys|index_query, ...)`.
  - Added B04-specific query allowlist and coercion (`max_results`, key/index parameter families) to enforce method/query validation parity.
  - Implemented key-list and 2i stream compatibility as aggregated envelope responses (JSON key chunks and multipart index parts) consistent with current migration-stage transport behavior.
open_risks:
  - Stream responses remain aggregated in-memory payloads; true backpressure-aware chunk flushing is deferred.
  - 2i continuation semantics rely on existing `riak_index` continuation behavior and should be load-validated under large result sets in B07.
handoff_notes:
  - B05 should reuse the B04 query validation/allowlist discipline and stream-envelope helper patterns for query/mapreduce endpoints.
  - B05 should not alter B04 route normalization contracts for `/riak`, `/buckets`, and `/types` alias families.
```

## Route Matching and Parser Discipline (required)

For any route additions/changes, follow:

`docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

B04 artifact notes must include Route Matching Evidence:
- external path template,
- normalized operation id,
- internal gateway call/action,
- tests that prove mapping.

## Sync-Back Command (required)

After committing B04 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B04_COMMIT_SHA>`
