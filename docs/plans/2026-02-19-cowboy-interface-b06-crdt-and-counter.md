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
status: done
branch: feature/cowboy-b06-crdt-counter
base_commit: fc1758db
end_commit: see_report_back_output
artifacts:
  - docs/plans/artifacts/cowboy-crdt-counter-parity-notes.md
decisions:
  - Added explicit Cowboy route coverage for `/buckets/:bucket/counters/:key` and typed CRDT datatype paths to keep route declaration, parser normalization, and dispatch/gateway mapping in lockstep.
  - Normalized counter and CRDT request parsing with operation-specific query allowlists and method contracts (`counter` GET/POST, `crdt_item` GET/HEAD/POST, `crdt_collection` POST).
  - Implemented counter parity semantics in gateway with signed integer POST deltas and `returnvalue` handling (`204` vs `200` body).
  - Implemented CRDT datatype operation decoding via `riak_kv_crdt_json:update_request_from_json/3`, with compatibility-focused error handling for datatype/quorum/notfound/deleted states.
  - Preserved CRDT `include_context` default behavior and write-time `returnbody` semantics, including CRDT create location headers on typed datatype paths.
open_risks:
  - CRDT default-bucket-type redirect parity is limited to keyed datatype paths; collection create on default bucket type follows datatype validation flow.
  - Some legacy Webmachine CRDT error responses were plain-text halt bodies; Cowboy keeps compatibility messages but returns them in JSON error envelopes for consistency.
  - Full cluster-level behavior for all datatype edge combinations still depends on runtime Riak bucket prop configuration and should be revalidated in B07 contract/perf hardening.
handoff_notes:
  - B07 should include counter and CRDT endpoints in contract/performance suites, including default-bucket redirect parity and quorum/deleted-state cases.
  - Preserve B06 route->parser->internal mapping discipline when extending datatype behavior; any new public path must update artifact route evidence.
  - Revisit whether CRDT default-bucket collection create should hard-redirect or hard-fail for stricter Webmachine parity before cutover.
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
