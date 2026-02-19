# B01 - HTTP Substrate and Security Envelope

Batch ID: B01
Branch: `feature/cowboy-b01-http-substrate`
Depends on: B00

## Objective

Implement the shared Cowboy request/response substrate that all data-path handlers will use, including route aliases, authn/authz hooks, and standardized error contracts.

## Scope

- Introduce versioned and alias routes (`/riak`, `/buckets`, `/types`) mapped to canonical internal request shape.
- Implement shared middleware/helpers for:
  - method checks,
  - query/header normalization,
  - authn/authz enforcement hooks,
  - request ID propagation,
  - standardized error serialization.
- Define and wire compatibility header helpers (`X-Riak-Vclock`, content-type behavior, conditional headers scaffold).
- Add baseline endpoint telemetry tags (route, status, duration).

## Out of scope

- No full object CRUD logic yet (that starts in B02).
- No 2i/query/CRDT implementation.

## Inputs

- B00 artifacts in `docs/plans/artifacts/`
- Existing helper patterns in `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- Security semantics reference from `openriak-3.4/src/riak_kv_wm_utils.erl`

## Deliverables

1. Shared substrate module(s) for request parsing and response writing.
2. Route alias wiring in Cowboy dispatch.
3. Error taxonomy doc:
   - `docs/plans/artifacts/cowboy-error-taxonomy.md`
4. Security policy doc:
   - `docs/plans/artifacts/cowboy-security-policy.md`

## Exit criteria

- Alias paths resolve to canonical internal route representation.
- Shared serializer can emit compatibility headers and stable error payloads.
- Authentication/authorization checks are enforceable through one path.
- B02 can focus only on data operations, not plumbing.

## Verification evidence

- Unit tests for normalization and serializer behavior.
- Route tests proving alias equivalence.

## Context Capsule (update at completion)

```yaml
batch: B01
status: planned
branch: feature/cowboy-b01-http-substrate
base_commit: TBD
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-error-taxonomy.md
  - docs/plans/artifacts/cowboy-security-policy.md
decisions:
  - TBD
open_risks:
  - TBD
handoff_notes:
  - Ensure B02 uses substrate helpers only
```

## Sync-Back Command (required)

After committing B01 in the worktree branch:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B01_COMMIT_SHA>`
