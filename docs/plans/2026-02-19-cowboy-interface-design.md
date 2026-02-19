# Cowboy Interface Migration Design

Date: 2026-02-19
Owner: riak_admin_api migration program
Status: Draft for execution

## 1) What exists today

### New Cowboy code already in this repo
- `apps/riak_admin_api` is running Cowboy for admin endpoints only.
- Request flow is currently thin-handler -> gateway (`riak_admin_api_riak`) -> JSON response helper.
- syn-based coordinator/event handling is in place for DC discovery and metadata propagation.
- Method guard and shared JSON formatting are centralized in `riak_admin_api_handler`.

### Legacy request processing reference (`riak_kv` openriak-3.4)
- Route registration happens in `riak_kv_app` via `webmachine_router:add_route(R)` from `riak_kv_web:dispatch_table/0`.
- Legacy/modern paths are both served (`/riak`, `/buckets`, `/types`) with many `riak_kv_wm_*` resources.
- Each resource follows Webmachine callback lifecycle and implements detailed status/header semantics.

## 2) Branch audit (local repo)

Checked local and remote refs in this checkout before planning.

- Current branch: `feature/cowboy-client` at `88a1df3f`.
- Local branches not contained in current HEAD: `openriak-3.4` only.
- `feature/syn-integration` and `feature/build-errors` are already contained in current branch history.
- No branch with a commit newer than `feature/cowboy-client` appears to contain unincorporated migration work.

Conclusion: there is no newer local branch work to pull into this migration baseline.

## 3) Migration goal

Build a production-grade, performant Cowboy interface for Riak data-path and admin-path operations while preserving compatibility with existing HTTP clients.

## 4) Compatibility and performance principles

1. Compatibility-first:
   - Support legacy `/riak/...` paths from day one.
   - Support `/buckets/...` and `/types/...` paths as first-class aliases.
2. Single internal contract:
   - Normalize all path variants into one internal request model.
3. Thin handlers, shared services:
   - Keep endpoint modules minimal; push logic into shared gateway/service modules.
4. Strict parity where required:
   - Preserve status codes, key headers, and query param behavior expected by existing clients.
5. Instrument before cutover:
   - Add metrics and latency/error budgets before Webmachine retirement.
6. Safe rollout:
   - Feature flags and endpoint-level fallback during migration.
7. Route/parser lockstep:
   - Every external route change must include Cowboy route wiring, parser normalization, method/query validation, and internal gateway mapping with tests proving end-to-end translation.

## 5) What is missing

- Cowboy data-path endpoints are not implemented yet (object CRUD, bucket/type props, key listing, 2i, query, CRDT, etc.).
- No compatibility harness comparing old Webmachine responses to new Cowboy responses.
- No full streaming/backpressure model yet for large key/index responses.
- Security hardening for exposed interface still needs a clear baseline (TLS/mTLS, authn/authz policy).
- No completed performance verification stage for parity under load.

## 6) Program structure (batched execution)

This plan is intentionally sequential so each branch builds on previous outcomes.

| Batch | Focus | Branch | Depends On |
|---|---|---|---|
| B00 | Baseline and contract inventory | `feature/cowboy-b00-baseline-contracts` | none |
| B01 | HTTP substrate, routing aliases, security envelope | `feature/cowboy-b01-http-substrate` | B00 |
| B02 | Object CRUD compatibility | `feature/cowboy-b02-object-crud` | B01 |
| B03 | Bucket and bucket-type endpoints | `feature/cowboy-b03-bucket-type` | B02 |
| B04 | Key listing and secondary index endpoints | `feature/cowboy-b04-keylist-2i` | B03 |
| B05 | Advanced query and mapreduce paths | `feature/cowboy-b05-query-mapred` | B04 |
| B06 | CRDT/counter and remaining data-type paths | `feature/cowboy-b06-crdt-counter` | B05 |
| B07 | Contract tests, performance hardening, observability | `feature/cowboy-b07-verification-perf` | B06 |
| B08 | Cutover, docs, and deprecation guardrails | `feature/cowboy-b08-cutover` | B07 |

## 7) Cross-batch standards

- Maintain a migration ledger in `docs/plans/2026-02-19-cowboy-interface-context-chain.md`.
- Each batch must update its own "Context Capsule" section before handoff.
- Every batch must include:
  - parity acceptance criteria,
  - rollback/fallback plan,
  - verification commands and expected evidence.
- For route-affecting work, follow:
  - `docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

## 8) Handoff mechanism for new context windows

To safely continue across new agents/windows:

1. Read in this order:
   - this master design doc,
   - context chain doc,
   - current batch doc,
   - previous batch doc capsule.
2. Continue only if prior batch is marked `Done` in context chain.
3. Start branch from the exact recorded base commit.
4. Update context chain + current batch capsule at end.

This creates a deterministic transfer protocol without relying on chat memory.

## 9) Immediate next execution step

Start with B00 and produce the canonical route/behavior matrix from Webmachine resources and current Cowboy admin app conventions. That matrix is the contract that all following batches implement against.

## 10) Deferred track: multi-DC distribution and syn evolution

This migration intentionally separates two concerns:

- **In scope now (B00-B08):** Cowboy HTTP compatibility and performance parity.
- **Deferred after cutover:** multi-DC data distribution/routing behavior and deeper syn-driven coordination beyond admin discovery.

Current syn work is already present in this branch baseline and remains required for admin DC discovery (`riak_admin_api_app`, coordinator, and event handler). Additional syn/distribution work is deferred to a dedicated post-cutover track to avoid coupling parity migration with distributed behavior changes.

Deferred track reference:
- `docs/plans/2026-02-19-cowboy-interface-d01-multidc-distribution-followup.md`
