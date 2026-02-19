# Cowboy Migration Context Chain

This file is the cross-branch handoff ledger for new context windows/agents.

## How to use

1. Read this file first to find the latest completed batch.
2. Read that batch's `Context Capsule` and artifacts.
3. Start next batch branch from recorded base commit.
4. Update this file at the end of your batch.

## Batch ledger

| Batch | Branch | Base Commit | End Commit | PR | Status | Notes |
|---|---|---|---|---|---|---|
| B00 | `feature/cowboy-b00-baseline-contracts` | 88a1df3f | TBD | TBD | In Progress | Artifacts drafted, contract test added, `./rebar3 eunit apps=riak_admin_api` passing |
| B01 | `feature/cowboy-b01-http-substrate` | f241db0a | see_report_back_output | N/A (report-back) | Done | Added shared request/response substrate, alias routing, security/error policy artifacts, and passing eunit verification |
| B02 | `feature/cowboy-b02-object-crud` | d4a71fbe | see_report_back_output | N/A (report-back) | Done | Implemented object CRUD dispatch/gateway parity path, added object parity artifact; B02A route audit added `docs/plans/artifacts/cowboy-route-mapping-audit-b01-b02.md`, strengthened alias/allowlist/translation tests, and flagged deferred index-route parser branches for B04 |
| B03 | `feature/cowboy-b03-bucket-type` | 69b3d6bd | see_report_back_output | N/A (report-back) | Done | Implemented bucket props/type props/list handlers with alias-normalized gateway actions, added B03 parity artifact with route matching evidence, and verified via `./rebar3 eunit apps=riak_admin_api`; stream mode remains aggregated-body compatibility envelope |
| B04 | `feature/cowboy-b04-keylist-2i` | 3860928b | see_report_back_output | N/A (report-back) | Done | Implemented key-list and 2i route/parser/dispatch/gateway parity with query allowlists, added B04 parity artifact + route matching evidence, verified via `./rebar3 eunit apps=riak_admin_api` |
| B05 | `feature/cowboy-b05-query-mapred` | 70b1f2f9 | see_report_back_output | N/A (report-back) | Done | Implemented query + mapreduce route/parser/dispatch/gateway parity, added B05 parity artifact with route matching evidence, and verified via `./rebar3 eunit apps=riak_admin_api`; mapreduce chunked transport remains aggregated-body compatibility mode |
| B06 | `feature/cowboy-b06-crdt-counter` | fc1758db | see_report_back_output | N/A (report-back) | Done | Implemented counter + CRDT route/parser/dispatch/gateway parity, added B06 parity artifact with route matching evidence, and verified via `./rebar3 eunit apps=riak_admin_api` |
| B07 | `feature/cowboy-b07-verification-perf` | TBD | TBD | TBD | Planned | Contract/perf/observability hardening |
| B08 | `feature/cowboy-b08-cutover` | TBD | TBD | TBD | Planned | Cutover and deprecation |

## Deferred roadmap ledger (post-B08)

| Track | Branch | Base Commit | End Commit | PR | Status | Notes |
|---|---|---|---|---|---|---|
| D01 | `feature/cowboy-d01-multidc-distribution` | TBD | TBD | TBD | Deferred | Multi-DC data distribution/routing and syn evolution after Cowboy parity cutover |

Reference doc:
- `docs/plans/2026-02-19-cowboy-interface-d01-multidc-distribution-followup.md`

## Agent startup checklist

- Confirm current branch and HEAD commit.
- Confirm previous batch is `Done`.
- Read previous batch `Context Capsule`.
- Read current batch doc and execute only that scope.
- Do not skip artifact updates and ledger update.

## Required sync-back command (every worktree batch)

After committing a batch in its worktree branch, sync it into `feature/cowboy-client` immediately:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <BATCH_COMMIT_SHA>`

## Required route-matching instruction (every route-affecting batch)

For any batch that introduces or changes public paths, apply:

`docs/plans/artifacts/cowboy-route-matching-and-parser-discipline.md`

Batch artifact notes must include Route Matching Evidence (external path -> normalized op -> internal gateway call + test references).
