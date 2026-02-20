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
status: done
branch: feature/cowboy-b05-query-mapred
base_commit: 70b1f2f9
end_commit: see_report_back_output
artifacts:
  - docs/plans/artifacts/cowboy-query-mapred-parity-notes.md
decisions:
  - Added explicit Cowboy route coverage for `/mapred`, `/buckets/:bucket/query`, and `/types/:bucket_type/buckets/:bucket/query` to keep route declaration and parser normalization in lockstep.
  - Normalized query and mapreduce request parsing with per-operation query allowlists (`query` none, `mapred` only `chunked`) and method contracts (`query` POST-only; `mapred` GET/HEAD/POST).
  - Implemented handler dispatch and gateway action wiring for `query` and `mapred` while preserving alias-family mapping discipline into `riak_admin_api_riak:bucket_operation/3`.
  - Historical B05 behavior: mapreduce chunked transport used aggregated multipart output in this migration stage.
  - Added explicit fallback contract when legacy mapreduce backend modules are unavailable (`501 not_implemented`) instead of silent crashes.
open_risks:
  - Historical B05 risk (superseded in S2): mapreduce chunked responses were aggregated before reply.
  - Historical B05 risk (superseded in S1): timeout signaling differed by path before mapreduce timeout was normalized to `503`.
  - Query cancellation and long-running operation interruption semantics remain dependent on underlying Riak client behavior and are not newly instrumented in B05.
handoff_notes:
  - B06 should preserve B05 alias-family normalization, route->parser->internal mapping discipline, and Cowboy error envelope taxonomy.
  - B06 should not alter B05 query/mapreduce allowlist and method contracts unless contract evidence and parity notes are updated together.
  - B07 should evaluate true streaming/backpressure requirements for mapreduce chunked flows and confirm timeout contract convergence targets.
```

## Route Matching and Parser Discipline (required)

For any route additions/changes, follow:

`docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

B05 artifact notes must include Route Matching Evidence:
- external path template,
- normalized operation id,
- internal gateway call/action,
- tests that prove mapping.

## Sync-Back Command (required)

After committing B05 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B05_COMMIT_SHA>`
