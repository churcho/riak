# B03 - Bucket and Bucket-Type Endpoints

Batch ID: B03
Branch: `feature/cowboy-b03-bucket-type`
Depends on: B02

## Objective

Migrate bucket-level and bucket-type configuration endpoints with compatibility behavior and permission checks.

## Scope

- Implement bucket property endpoints parity:
  - GET/PUT/DELETE for bucket props paths.
- Implement bucket-type props parity:
  - GET/PUT for type props paths.
- Implement list-buckets endpoint behavior and query semantics (`buckets=true|stream`).
- Preserve permission model hooks and expected error mappings.

## Out of scope

- Key listing and 2i queries (B04).
- Complex query/mapreduce (B05).

## Inputs

- B02 shared compatibility helpers
- `openriak-3.4/src/riak_kv_wm_props.erl`
- `openriak-3.4/src/riak_kv_wm_bucket_type.erl`
- `openriak-3.4/src/riak_kv_wm_buckets.erl`

## Deliverables

1. Cowboy handlers for bucket props and type props.
2. Bucket listing endpoint implementation including stream mode behavior.
3. Artifact doc:
   - `docs/plans/artifacts/cowboy-bucket-type-parity-notes.md`

## Exit criteria

- Contract tests pass for bucket/type config APIs.
- Legacy path aliases return equivalent results.
- Stream behavior has documented chunk format compatibility.

## Verification evidence

- Handler tests for malformed payloads and permission denials.
- Contract tests for GET/PUT/DELETE bucket props and type props.

## Context Capsule (update at completion)

```yaml
batch: B03
status: planned
branch: feature/cowboy-b03-bucket-type
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-bucket-type-parity-notes.md
decisions:
  - TBD
open_risks:
  - streaming bucket list parity format
handoff_notes:
  - B04 must follow same streaming envelope decisions
```

## Route Matching and Parser Discipline (required)

For any route additions/changes, follow:

`docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

B03 artifact notes must include Route Matching Evidence:
- external path template,
- normalized operation id,
- internal gateway call/action,
- tests that prove mapping.

## Sync-Back Command (required)

After committing B03 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B03_COMMIT_SHA>`
