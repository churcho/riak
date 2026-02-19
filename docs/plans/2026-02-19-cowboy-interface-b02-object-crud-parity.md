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
status: done
branch: feature/cowboy-b02-object-crud
base_commit: d4a71fbe
end_commit: see_report_back_output
artifacts:
  - docs/plans/artifacts/cowboy-object-parity-notes.md
decisions:
  - Replaced substrate `501` stubs with object operation dispatch for `object_item` and `object_collection` while keeping non-object operations explicitly deferred.
  - Added `riak_admin_api_riak:object_operation/3` as the gateway contract for object CRUD and create-on-POST, including status/error translation and compatibility header mapping.
  - Added raw response support in `riak_admin_api_response:raw_reply/5` so object reads can return native content types and bodies without losing compatibility headers/telemetry context.
open_risks:
  - Conditional handling still depends primarily on `If-None-Match` and `X-Riak-If-Not-Modified`; broader conditional-header parity needs additional hardening.
  - Sibling multipart edge cases and large sibling payload behavior need load-path validation in B07.
handoff_notes:
  - B03 should reuse `riak_admin_api_handler` dispatch pattern and `riak_admin_api_response:raw_reply/5` for non-JSON compatibility flows.
  - B03 can reuse quorum/error mapping helpers in `riak_admin_api_riak` to keep status behavior consistent across endpoint families.
```

## Known deviations

- `If-Match` and `If-Unmodified-Since` are carried through request input but are not yet enforced as explicit gateway-side condition checks in this batch.
- Full legacy write-time Link-header validation/parsing is intentionally deferred; read-side compatibility link emission is implemented.

## Sync-Back Command (required)

After committing B02 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B02_COMMIT_SHA>`
