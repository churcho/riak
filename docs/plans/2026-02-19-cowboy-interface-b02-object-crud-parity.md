# B02 - Object CRUD Parity

Batch ID: B02
Branch: `feature/cowboy-b02-object-crud`
Depends on: B01

## Objective

Migrate core object-level operations to Cowboy with compatibility parity against legacy Webmachine behavior.

## Scope

- Implement GET/HEAD/PUT/POST/DELETE key endpoints for:
  - `/riak/:bucket/:key`
  - `/buckets/:bucket/keys/:key`
  - `/types/:type/buckets/:bucket/keys/:key`
- Implement create-on-POST where key is absent (Location header behavior parity).
- Implement conditional write and conflict handling behaviors.
- Preserve sibling handling and response content negotiation semantics.
- Preserve core compatibility headers and key status mapping.

## Out of scope

- Bucket and bucket-type props endpoints (B03).
- Listing, index, query, and mapreduce endpoints (B04/B05).

## Inputs

- B01 substrate modules
- `openriak-3.4/src/riak_kv_wm_object.erl`
- `openriak-3.4/src/riak_kv_wm_utils.erl`

## Deliverables

1. Cowboy object handlers and gateway operations.
2. Parity tests for:
   - methods and status codes,
   - mandatory headers,
   - conditional request paths,
   - sibling response forms.
3. Artifact doc:
   - `docs/plans/artifacts/cowboy-object-parity-notes.md`

## Exit criteria

- Legacy and Cowboy results match for the agreed contract matrix across object CRUD test corpus.
- No regression in existing admin endpoints.

## Verification evidence

- Contract tests with side-by-side expectations.
- EUnit coverage for handler branches and gateway error mapping.

## Context Capsule (update at completion)

```yaml
batch: B02
status: planned
branch: feature/cowboy-b02-object-crud
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-object-parity-notes.md
decisions:
  - TBD
open_risks:
  - sibling edge cases
  - conditional write semantics under load
handoff_notes:
  - B03 should reuse object error/header helpers
```

## Sync-Back Command (required)

After committing B02 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B02_COMMIT_SHA>`
