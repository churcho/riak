# Cowboy Interface Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Deliver a fully performant Cowboy-based HTTP interface for Riak with compatibility for legacy `/riak/...` clients and parity for required data-path/admin-path behaviors.

**Architecture:** Keep handlers thin and move logic into shared request/response/gateway modules. Normalize route aliases (`/riak`, `/buckets`, `/types`) into one internal request contract, then enforce compatibility headers/status/error mapping through a single serializer. Migrate endpoint groups in sequential batches, with contract tests and performance gates before cutover.

**Tech Stack:** Erlang/OTP, Cowboy 2.x, jsx/riak_kv_wm_json, EUnit, existing `riak_admin_api` application.

**Worktree Sync Rule (mandatory):** After each batch commit on a worktree branch, sync that commit into `feature/cowboy-client` immediately:

`git -C "/Users/abogec/open-riak/riak" checkout feature/cowboy-client && git -C "/Users/abogec/open-riak/riak" cherry-pick <BATCH_COMMIT_SHA>`

---

### Task 1: Create branch/worktree chain and baseline artifacts (B00)

**Files:**
- Create: `docs/plans/artifacts/cowboy-endpoint-inventory.md`
- Create: `docs/plans/artifacts/cowboy-compat-matrix.md`
- Create: `docs/plans/artifacts/cowboy-route-normalization.md`
- Modify: `docs/plans/2026-02-19-cowboy-interface-context-chain.md`
- Modify: `docs/plans/2026-02-19-cowboy-interface-b00-baseline-and-contracts.md`

**Step 1: Write the failing validation test for contract completeness**

```erlang
%% apps/riak_admin_api/test/cowboy_contract_inventory_test.erl
route_inventory_has_core_paths_test() ->
    {ok, Bin} = file:read_file("docs/plans/artifacts/cowboy-compat-matrix.md"),
    ?assert(binary:match(Bin, <<"/riak/">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"/buckets/">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"/types/">>) =/= nomatch).
```

**Step 2: Run test to verify it fails**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: FAIL because test/artifact file does not exist yet.

**Step 3: Create inventory/matrix/normalization docs**

Document all dispatch routes from `openriak-3.4/src/riak_kv_web.erl` and classify:
- required now,
- required with streaming,
- deferred legacy.

**Step 4: Run tests to verify pass**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS for contract completeness test.

**Step 5: Commit**

```bash
git add docs/plans/artifacts/cowboy-endpoint-inventory.md docs/plans/artifacts/cowboy-compat-matrix.md docs/plans/artifacts/cowboy-route-normalization.md docs/plans/2026-02-19-cowboy-interface-context-chain.md docs/plans/2026-02-19-cowboy-interface-b00-baseline-and-contracts.md apps/riak_admin_api/test/cowboy_contract_inventory_test.erl
git commit -m "plan: establish cowboy migration contract baseline"
```

### Task 2: Build shared request/response substrate (B01)

**Files:**
- Create: `apps/riak_admin_api/src/riak_admin_api_request.erl`
- Create: `apps/riak_admin_api/src/riak_admin_api_response.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_app.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_handler.erl`
- Test: `apps/riak_admin_api/test/riak_admin_api_request_test.erl`
- Test: `apps/riak_admin_api/test/riak_admin_api_response_test.erl`

**Step 1: Write failing tests for alias normalization and error taxonomy**

```erlang
normalize_alias_path_test() ->
    ?assertEqual({ok, object_get},
        riak_admin_api_request:normalize(<<"GET">>, <<"/riak/b/k">>, #{})).

error_payload_stable_test() ->
    Body = riak_admin_api_response:error_body(backend_timeout, timeout),
    ?assertMatch(#{error := <<"backend_timeout">>, reason := _}, Body).
```

**Step 2: Run focused tests and verify they fail**

Run: `./rebar3 eunit --module=riak_admin_api_request_test,riak_admin_api_response_test`  
Expected: FAIL with undefined module/function errors.

**Step 3: Implement minimal request and response modules**

```erlang
%% riak_admin_api_request.erl
normalize(Method, Path, Req) ->
    %% map /riak|/buckets|/types into canonical op
    ...

%% riak_admin_api_response.erl
error_body(Code, Reason) ->
    #{error => atom_to_binary(Code, utf8), reason => format_reason(Reason)}.
```

**Step 4: Run tests and full app eunit**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS; no regressions in existing admin tests.

**Step 5: Commit**

```bash
git add apps/riak_admin_api/src/riak_admin_api_request.erl apps/riak_admin_api/src/riak_admin_api_response.erl apps/riak_admin_api/src/riak_admin_api_app.erl apps/riak_admin_api/src/riak_admin_api_handler.erl apps/riak_admin_api/test/riak_admin_api_request_test.erl apps/riak_admin_api/test/riak_admin_api_response_test.erl
git commit -m "feat: add shared cowboy request and response substrate"
```

### Task 3: Implement object CRUD handlers with parity checks (B02)

**Files:**
- Create: `apps/riak_admin_api/src/handlers/rah_object.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_app.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- Test: `apps/riak_admin_api/test/rah_object_test.erl`
- Test: `apps/riak_admin_api/test/cowboy_object_contract_test.erl`

**Step 1: Write failing tests for GET/PUT/DELETE + compatibility headers**

```erlang
get_object_returns_vclock_header_test() ->
    {Status, Headers, _Body} = call_object_get(...),
    ?assertEqual(200, Status),
    ?assert(maps:is_key(<<"x-riak-vclock">>, Headers)).
```

**Step 2: Run tests to verify fail**

Run: `./rebar3 eunit --module=rah_object_test,cowboy_object_contract_test`  
Expected: FAIL because route/handler not implemented.

**Step 3: Implement minimal object handler + gateway calls**

```erlang
init(Req0, State) ->
    case riak_admin_api_request:normalize(... ) of
        {ok, object_get} -> ...;
        {ok, object_put} -> ...;
        {ok, object_delete} -> ...
    end.
```

**Step 4: Run tests and full suite**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS for new and existing tests.

**Step 5: Commit**

```bash
git add apps/riak_admin_api/src/handlers/rah_object.erl apps/riak_admin_api/src/riak_admin_api_app.erl apps/riak_admin_api/src/riak_admin_api_riak.erl apps/riak_admin_api/test/rah_object_test.erl apps/riak_admin_api/test/cowboy_object_contract_test.erl
git commit -m "feat: add cowboy object CRUD compatibility handlers"
```

### Task 4: Migrate bucket and bucket-type endpoints (B03)

**Files:**
- Create: `apps/riak_admin_api/src/handlers/rah_bucket_props.erl`
- Create: `apps/riak_admin_api/src/handlers/rah_bucket_type.erl`
- Create: `apps/riak_admin_api/src/handlers/rah_buckets.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_app.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- Test: `apps/riak_admin_api/test/rah_bucket_props_test.erl`
- Test: `apps/riak_admin_api/test/rah_bucket_type_test.erl`

**Step 1: Write failing tests for GET/PUT/DELETE bucket props and type props**

```erlang
bucket_props_put_rejects_bad_json_test() ->
    ?assertEqual(400, call_bucket_props_put(<<"{bad">>)).
```

**Step 2: Run tests to verify fail**

Run: `./rebar3 eunit --module=rah_bucket_props_test,rah_bucket_type_test`  
Expected: FAIL with undefined handlers.

**Step 3: Implement handlers and gateway wrappers**

```erlang
case riak_admin_api_riak:set_bucket_props(Type, Bucket, Props) of
    ok -> ...;
    {error, Reason} -> ...
end.
```

**Step 4: Run full tests**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS.

**Step 5: Commit**

```bash
git add apps/riak_admin_api/src/handlers/rah_bucket_props.erl apps/riak_admin_api/src/handlers/rah_bucket_type.erl apps/riak_admin_api/src/handlers/rah_buckets.erl apps/riak_admin_api/src/riak_admin_api_app.erl apps/riak_admin_api/src/riak_admin_api_riak.erl apps/riak_admin_api/test/rah_bucket_props_test.erl apps/riak_admin_api/test/rah_bucket_type_test.erl
git commit -m "feat: migrate bucket and bucket-type compatibility endpoints"
```

### Task 5: Migrate key listing and 2i endpoints (B04)

**Files:**
- Create: `apps/riak_admin_api/src/handlers/rah_keys.erl`
- Create: `apps/riak_admin_api/src/handlers/rah_index.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_app.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- Test: `apps/riak_admin_api/test/rah_keys_test.erl`
- Test: `apps/riak_admin_api/test/rah_index_test.erl`

**Step 1: Write failing tests for non-stream and stream cases**

```erlang
index_stream_returns_multipart_boundary_test() ->
    {Status, Headers, _} = call_index_stream(...),
    ?assertEqual(200, Status),
    ?assertMatch(<<"multipart/mixed", _/binary>>, maps:get(<<"content-type">>, Headers)).
```

**Step 2: Run tests to verify fail**

Run: `./rebar3 eunit --module=rah_keys_test,rah_index_test`  
Expected: FAIL until handlers are implemented.

**Step 3: Implement handlers and bounded stream support**

```erlang
%% stream via cowboy loop/chunk API with timeout and cleanup
```

**Step 4: Run tests including timeout and continuation paths**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS.

**Step 5: Commit**

```bash
git add apps/riak_admin_api/src/handlers/rah_keys.erl apps/riak_admin_api/src/handlers/rah_index.erl apps/riak_admin_api/src/riak_admin_api_app.erl apps/riak_admin_api/src/riak_admin_api_riak.erl apps/riak_admin_api/test/rah_keys_test.erl apps/riak_admin_api/test/rah_index_test.erl
git commit -m "feat: add cowboy key listing and secondary index endpoints"
```

### Task 6: Migrate query and mapreduce endpoints (B05)

**Files:**
- Create: `apps/riak_admin_api/src/handlers/rah_query.erl`
- Create: `apps/riak_admin_api/src/handlers/rah_mapred.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_app.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- Test: `apps/riak_admin_api/test/rah_query_test.erl`
- Test: `apps/riak_admin_api/test/rah_mapred_test.erl`

**Step 1: Write failing tests for valid/invalid JSON payload and timeout mapping**

```erlang
query_bad_json_returns_400_test() ->
    ?assertEqual(400, call_query_post(<<"{bad">>)).
```

**Step 2: Run tests to verify fail**

Run: `./rebar3 eunit --module=rah_query_test,rah_mapred_test`  
Expected: FAIL with missing route/handler behavior.

**Step 3: Implement parser/validator and gateway integration**

```erlang
case riak_admin_api_riak:run_query(Payload, Opts) of
    {ok, Result} -> ...;
    {error, timeout} -> ...
end.
```

**Step 4: Run full tests**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS.

**Step 5: Commit**

```bash
git add apps/riak_admin_api/src/handlers/rah_query.erl apps/riak_admin_api/src/handlers/rah_mapred.erl apps/riak_admin_api/src/riak_admin_api_app.erl apps/riak_admin_api/src/riak_admin_api_riak.erl apps/riak_admin_api/test/rah_query_test.erl apps/riak_admin_api/test/rah_mapred_test.erl
git commit -m "feat: migrate query and mapreduce compatibility endpoints"
```

### Task 7: Migrate CRDT and counter endpoints (B06)

**Files:**
- Create: `apps/riak_admin_api/src/handlers/rah_crdt.erl`
- Create: `apps/riak_admin_api/src/handlers/rah_counter.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_app.erl`
- Modify: `apps/riak_admin_api/src/riak_admin_api_riak.erl`
- Test: `apps/riak_admin_api/test/rah_crdt_test.erl`
- Test: `apps/riak_admin_api/test/rah_counter_test.erl`

**Step 1: Write failing tests for operation parsing and include_context behavior**

```erlang
crdt_get_with_context_test() ->
    {Status, _Headers, Body} = call_crdt_get(...),
    ?assertEqual(200, Status),
    ?assert(maps:is_key(<<"context">>, decode_json(Body))).
```

**Step 2: Run tests to verify fail**

Run: `./rebar3 eunit --module=rah_crdt_test,rah_counter_test`  
Expected: FAIL until handlers exist.

**Step 3: Implement handlers with datatype-safe validation**

```erlang
case riak_admin_api_riak:apply_crdt_op(Type, Bucket, Key, Op, Opts) of
    {ok, Value} -> ...;
    {error, Reason} -> ...
end.
```

**Step 4: Run full tests**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS.

**Step 5: Commit**

```bash
git add apps/riak_admin_api/src/handlers/rah_crdt.erl apps/riak_admin_api/src/handlers/rah_counter.erl apps/riak_admin_api/src/riak_admin_api_app.erl apps/riak_admin_api/src/riak_admin_api_riak.erl apps/riak_admin_api/test/rah_crdt_test.erl apps/riak_admin_api/test/rah_counter_test.erl
git commit -m "feat: migrate crdt and counter compatibility endpoints"
```

### Task 8: Add contract harness, performance tests, and cutover gates (B07)

**Files:**
- Create: `apps/riak_admin_api/test/cowboy_contract_suite_test.erl`
- Create: `apps/riak_admin_api/test/cowboy_perf_smoke_test.erl`
- Create: `docs/plans/artifacts/cowboy-contract-harness.md`
- Create: `docs/plans/artifacts/cowboy-performance-report.md`
- Create: `docs/plans/artifacts/cowboy-observability-map.md`

**Step 1: Write failing contract harness test for one endpoint pair**

```erlang
object_get_legacy_vs_cowboy_contract_test() ->
    ?assertEqual(legacy_response(...), cowboy_response(...)).
```

**Step 2: Run test to verify fail**

Run: `./rebar3 eunit --module=cowboy_contract_suite_test`  
Expected: FAIL until harness adapters are built.

**Step 3: Implement harness adapter and perf smoke checks**

```erlang
%% adapter executes same request against both route stacks and compares
```

**Step 4: Run full tests + capture benchmark evidence**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS with benchmark notes stored in artifact doc.

**Step 5: Commit**

```bash
git add apps/riak_admin_api/test/cowboy_contract_suite_test.erl apps/riak_admin_api/test/cowboy_perf_smoke_test.erl docs/plans/artifacts/cowboy-contract-harness.md docs/plans/artifacts/cowboy-performance-report.md docs/plans/artifacts/cowboy-observability-map.md
git commit -m "test: add cowboy contract and performance verification harness"
```

### Task 9: Cutover and deprecation runbooks (B08)

**Files:**
- Create: `docs/plans/artifacts/cowboy-cutover-runbook.md`
- Create: `docs/plans/artifacts/cowboy-rollback-runbook.md`
- Create: `docs/plans/artifacts/cowboy-client-migration-notes.md`
- Modify: `docs/plans/2026-02-19-cowboy-interface-context-chain.md`

**Step 1: Write failing operational checklist test (doc existence + sections)**

```erlang
runbook_docs_exist_test() ->
    ?assert(filelib:is_file("docs/plans/artifacts/cowboy-cutover-runbook.md")).
```

**Step 2: Run test to verify fail**

Run: `./rebar3 eunit --module=cowboy_contract_inventory_test`  
Expected: FAIL until runbook docs are created.

**Step 3: Draft cutover and rollback runbooks with flag strategy**

Include:
- staged rollout checkpoints,
- stop/rollback thresholds,
- verification commands,
- communication plan.

**Step 4: Run tests and final suite**

Run: `./rebar3 eunit apps=riak_admin_api`  
Expected: PASS.

**Step 5: Commit**

```bash
git add docs/plans/artifacts/cowboy-cutover-runbook.md docs/plans/artifacts/cowboy-rollback-runbook.md docs/plans/artifacts/cowboy-client-migration-notes.md docs/plans/2026-02-19-cowboy-interface-context-chain.md
git commit -m "docs: add cowboy cutover, rollback, and client migration runbooks"
```

### Deferred Track D01: Multi-DC distribution and syn evolution (post-B08)

This is intentionally **not** part of B00-B08 execution.

Execute only after B08 exit criteria are met and Cowboy parity is stable in production.

- Follow-up spec: `docs/plans/2026-02-19-cowboy-interface-d01-multidc-distribution-followup.md`
- Context tracking: `docs/plans/2026-02-19-cowboy-interface-context-chain.md` (Deferred roadmap ledger)
- Baseline assumption: existing syn integration remains for admin discovery; D01 extends from that baseline.

---

Plan complete and saved to `docs/plans/2026-02-19-cowboy-interface-implementation.md`. Two execution options:

1. Subagent-Driven (this session) - I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. Parallel Session (separate) - Open a new session with executing-plans for batch execution with checkpoints.
