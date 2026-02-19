# B00 - Baseline and Contracts

Batch ID: B00
Branch: `feature/cowboy-b00-baseline-contracts`
Depends on: none

## Objective

Create the authoritative compatibility contract for migrating from Webmachine HTTP resources to Cowboy handlers.

## Scope

- Build endpoint inventory from `riak_kv_web:dispatch_table/0` and mapped `riak_kv_wm_*` modules.
- Classify endpoints: core required, required streaming, deferred legacy.
- Define route alias mapping (`/riak`, `/buckets`, `/types`) to a single internal model.
- Define response parity matrix (status codes, required headers, response body shape, query param semantics).
- Define performance SLO targets per endpoint class (p50/p95/p99 + error budget).

## Out of scope

- No functional endpoint migration code in this batch.
- No behavior changes to existing admin API handlers.

## Inputs

- `docs/plans/2026-02-19-cowboy-interface-design.md`
- `openriak-3.4/src/riak_kv_web.erl`
- `openriak-3.4/src/riak_kv_wm_object.erl`
- `openriak-3.4/src/riak_kv_wm_utils.erl`

## Deliverables

1. Endpoint inventory document (new file):
   - `docs/plans/artifacts/cowboy-endpoint-inventory.md`
2. Compatibility matrix document (new file):
   - `docs/plans/artifacts/cowboy-compat-matrix.md`
3. Route alias normalization spec (new file):
   - `docs/plans/artifacts/cowboy-route-normalization.md`
4. Update context chain status for B00.

## Exit criteria

- Every Webmachine route is classified with migration priority and target Cowboy module.
- Compatibility matrix covers at least: methods, status codes, mandatory headers, query parameters, error mappings.
- B01 can start without reopening legacy contract questions.

## Verification evidence

- Inventory reviewed against dispatch table entries.
- Matrix references source modules for each behavior decision.
- Verification command `./rebar3 eunit apps=riak_admin_api`:
  - pre-artifact run failed at `cowboy_contract_inventory_test` with `{error, enoent}` for missing matrix file,
  - post-artifact run passed (`All 101 tests passed`).

## Context Capsule (update at completion)

```yaml
batch: B00
status: in_progress
branch: feature/cowboy-b00-baseline-contracts
base_commit: 88a1df3f
end_commit: TBD
artifacts:
  - docs/plans/artifacts/cowboy-endpoint-inventory.md
  - docs/plans/artifacts/cowboy-compat-matrix.md
  - docs/plans/artifacts/cowboy-route-normalization.md
decisions:
  - Route and behavior baseline sourced from upstream `basho/riak_kv` Webmachine modules because local `openriak-3.4` branch in this repo does not currently contain `riak_kv_web.erl` and `riak_kv_wm_*` inputs.
  - Dispatch inventory is canonicalized (deduplicated) across `/riak`, `/buckets`, and `/types` alias expansion.
  - Link walker, AAE fold, and queue/membership endpoints are retained in the contract inventory but marked deferred legacy for cutover-stage decisioning.
open_risks:
  - Local-vs-upstream legacy source mismatch may require reconciliation against the exact production baseline before final cutover.
  - Deferred legacy endpoint policy (`501` vs full parity) needs explicit approval in B07/B08.
handoff_notes:
  - B01 should implement normalization substrate directly from `docs/plans/artifacts/cowboy-route-normalization.md`.
  - If B00 artifacts are approved, record end commit and status `done` in this capsule and the context chain.
```

## Sync-Back Command (required)

After committing B00 in the worktree branch, run this to keep `feature/cowboy-client` in sync:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <B00_COMMIT_SHA>`
