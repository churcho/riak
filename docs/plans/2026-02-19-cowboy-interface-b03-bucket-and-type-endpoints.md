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
status: done
branch: feature/cowboy-b03-bucket-type
base_commit: 69b3d6bd
end_commit: see_report_back_output
artifacts:
  - docs/plans/artifacts/cowboy-bucket-type-parity-notes.md
decisions:
  - Replaced the substrate `501` stubs for `bucket_props`, `bucket_type_props`, and `buckets` operations with explicit Cowboy dispatch branches in `riak_admin_api_handler`.
  - Added `riak_admin_api_riak:bucket_operation/3` as the canonical gateway for B03 routes, using legacy Riak JSON conversion helpers for props payload parity and list-buckets semantics.
  - Preserved `/riak/:bucket` ambiguity discipline by keeping `POST ?props=false` mapped to B02 `object_collection` while B04 `keys` routes remain deferred.
  - Implemented `buckets=stream` compatibility as aggregated legacy-style JSON chunk envelopes in the Cowboy response body.
open_risks:
  - Stream envelope shape is compatible, but transport remains aggregated response body instead of true incremental chunk flushing/backpressure-aware streaming.
  - Bucket prop validation errors use normalized Cowboy error payloads (`invalid_body`/`invalid_props`) instead of every legacy text-body variant.
handoff_notes:
  - B04 should replace deferred `keys` route handling without changing B03 bucket/type dispatch contracts or alias normalization.
  - B04/B07 should evaluate migrating bucket stream responses from aggregated envelopes to true incremental Cowboy streaming under load.
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
