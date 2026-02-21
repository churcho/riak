%% @doc EUnit tests for riak_admin_api_riak internal helpers.
%%
%% These tests exercise the pure helper functions that don't
%% require a running Riak cluster: to_bin/1, pv/2, round_pct/2,
%% format_pending/1, format_transfers/1, format_exchanges/1.
%%
%% Gateway functions (cluster_status/0, etc.) call Riak internals
%% at runtime and are tested via integration tests against a live
%% devrel cluster.

-module(riak_admin_api_riak_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

%%% ============================================================
%%% to_bin/1
%%% ============================================================

to_bin_binary_test() ->
    ?assertEqual(<<"hello">>, riak_admin_api_riak:to_bin(<<"hello">>)).

to_bin_atom_test() ->
    ?assertEqual(<<"ok">>, riak_admin_api_riak:to_bin(ok)),
    ?assertEqual(<<"dev1@127.0.0.1">>,
                 riak_admin_api_riak:to_bin('dev1@127.0.0.1')).

to_bin_list_test() ->
    ?assertEqual(<<"hello">>, riak_admin_api_riak:to_bin("hello")).

to_bin_tuple_test() ->
    %% Tuples get stringified via io_lib:format
    Result = riak_admin_api_riak:to_bin({some, tuple}),
    ?assert(is_binary(Result)),
    ?assertNotEqual(<<>>, Result).

to_bin_integer_test() ->
    Result = riak_admin_api_riak:to_bin(42),
    ?assert(is_binary(Result)).

%%% ============================================================
%%% round_pct/2
%%% ============================================================

round_pct_zero_total_test() ->
    ?assertEqual(0.0, riak_admin_api_riak:round_pct(10, 0)).

round_pct_full_ownership_test() ->
    ?assertEqual(100.0, riak_admin_api_riak:round_pct(64, 64)).

round_pct_even_split_test() ->
    ?assertEqual(50.0, riak_admin_api_riak:round_pct(32, 64)).

round_pct_thirds_test() ->
    %% 1/3 of 64 is ~33.33, should round to 2 decimal places
    Result = riak_admin_api_riak:round_pct(21, 64),
    ?assertEqual(32.81, Result).

round_pct_small_fraction_test() ->
    Result = riak_admin_api_riak:round_pct(1, 64),
    ?assertEqual(1.56, Result).

%%% ============================================================
%%% format_pending/1
%%% ============================================================

format_pending_empty_test() ->
    ?assertEqual([], riak_admin_api_riak:format_pending([])).

format_pending_non_list_test() ->
    ?assertEqual([], riak_admin_api_riak:format_pending(undefined)).

format_pending_tuples_test() ->
    Input = [{join, 'dev2@127.0.0.1', 'dev1@127.0.0.1'}],
    [Result] = riak_admin_api_riak:format_pending(Input),
    ?assert(is_binary(Result)),
    ?assertNotEqual(<<>>, Result).

%%% ============================================================
%%% format_transfers/1 (via handoff_status return shapes)
%%% ============================================================

format_transfers_empty_test() ->
    ?assertEqual([], riak_admin_api_riak:format_transfers([])).

format_transfers_non_list_test() ->
    ?assertEqual([], riak_admin_api_riak:format_transfers(undefined)).

format_transfers_tuple_test() ->
    Input = [{status_v2, [{mod_src_tgt, {riak_kv_vnode, node(), node()}}]}],
    [#{raw := Raw}] = riak_admin_api_riak:format_transfers(Input),
    ?assert(is_binary(Raw)).

format_transfers_map_test() ->
    Input = [#{type => ownership, source => node()}],
    ?assertEqual(Input, riak_admin_api_riak:format_transfers(Input)).

format_transfers_filters_non_tuple_non_map_test() ->
    Input = [some_atom, {a, tuple}, <<"binary">>],
    Result = riak_admin_api_riak:format_transfers(Input),
    %% Only the tuple should pass through
    ?assertEqual(1, length(Result)).

%%% ============================================================
%%% format_exchanges/1 (via aae_status return shapes)
%%% ============================================================

format_exchanges_empty_test() ->
    ?assertEqual([], riak_admin_api_riak:format_exchanges([])).

format_exchanges_non_list_test() ->
    ?assertEqual([], riak_admin_api_riak:format_exchanges(undefined)).

format_exchanges_tuple_test() ->
    Input = [{exchange, 0, 1234567890}],
    [#{raw := Raw}] = riak_admin_api_riak:format_exchanges(Input),
    ?assert(is_binary(Raw)).

format_exchanges_map_test() ->
    Input = [#{index => 0, last_ts => 1234}],
    ?assertEqual(Input, riak_admin_api_riak:format_exchanges(Input)).

%%% ============================================================
%%% collect_local_stats/0 (runs without riak_kv)
%%% ============================================================

collect_local_stats_shape_test() ->
    %% This can run without riak_kv — the try/catch returns []
    %% and all KV stats default to 0 via pv/2.
    Stats = riak_admin_api_riak:collect_local_stats(),
    ?assert(is_map(Stats)),
    ?assert(is_map(maps:get(erlang, Stats))),
    ?assert(is_map(maps:get(kv, Stats))),
    ?assertEqual(node(), maps:get(node, Stats)),
    %% Erlang stats are always available
    Erlang = maps:get(erlang, Stats),
    ?assert(is_binary(maps:get(otp_release, Erlang))),
    ?assert(is_integer(maps:get(process_count, Erlang))),
    ?assert(is_integer(maps:get(memory_total_mb, Erlang))),
    ?assert(is_integer(maps:get(run_queue, Erlang))),
    %% KV stats default to 0 when riak_kv is not running
    KV = maps:get(kv, Stats),
    ?assertEqual(0, maps:get(vnode_gets, KV)),
    ?assertEqual(0, maps:get(vnode_puts, KV)).

%%% ============================================================
%%% JSON encoding safety
%%% ============================================================

collect_local_stats_json_encodable_test() ->
    Stats = riak_admin_api_riak:collect_local_stats(),
    %% Must not crash — if jsx can't encode, it throws badarg
    Encoded = jsx:encode(Stats),
    ?assert(is_binary(Encoded)),
    ?assert(byte_size(Encoded) > 0).

%%% ============================================================
%%% object_error_map/1 and option helpers
%%% ============================================================

object_error_map_timeout_test() ->
    Error = riak_admin_api_riak:object_error_map(timeout),
    ?assertEqual(503, maps:get(status, Error)),
    ?assertEqual(<<"timeout">>, maps:get(code, Error)).

object_error_map_conflict_test() ->
    Error = riak_admin_api_riak:object_error_map("modified"),
    ?assertEqual(409, maps:get(status, Error)),
    ?assertEqual(<<"conflict">>, maps:get(code, Error)).

object_error_map_deleted_includes_vclock_test() ->
    Error = riak_admin_api_riak:object_error_map({deleted, vclock:fresh()}),
    ?assertEqual(404, maps:get(status, Error)),
    ?assert(is_binary(maps:get(vclock, Error))).

build_object_options_includes_quorum_and_flags_test() ->
    Query = #{
        <<"r">> => quorum,
        <<"w">> => 2,
        <<"dw">> => all,
        <<"timeout">> => 5000,
        <<"basic_quorum">> => true,
        <<"notfound_ok">> => false,
        <<"asis">> => true,
        <<"sync_on_write">> => <<"backend">>
    },
    Options = riak_admin_api_riak:build_object_options(write, Query, []),
    ?assert(lists:member({r, quorum}, Options)),
    ?assert(lists:member({w, 2}, Options)),
    ?assert(lists:member({dw, all}, Options)),
    ?assert(lists:member({timeout, 5000}, Options)),
    ?assert(lists:member({basic_quorum, true}, Options)),
    ?assert(lists:member({notfound_ok, false}, Options)),
    ?assert(lists:member({asis, true}, Options)),
    ?assert(lists:member({sync_on_write, backend}, Options)).

build_location_respects_alias_families_test() ->
    Key = <<"alice">>,
    ?assertEqual(
        <<"/riak/users/alice">>,
        riak_admin_api_riak:build_location(
            #{alias => riak, bucket => <<"users">>, bucket_type => <<"default">>},
            Key)),
    ?assertEqual(
        <<"/buckets/users/keys/alice">>,
        riak_admin_api_riak:build_location(
            #{alias => buckets, bucket => <<"users">>, bucket_type => <<"default">>},
            Key)),
    ?assertEqual(
        <<"/types/maps/buckets/users/keys/alice">>,
        riak_admin_api_riak:build_location(
            #{alias => types, bucket_type => <<"maps">>, bucket => <<"users">>},
            Key)).

conditional_put_options_accepts_supported_headers_test() ->
    VClock = base64:encode(riak_object:encode_vclock(vclock:fresh())),
    Headers = #{
        <<"if-none-match">> => <<"*">>,
        <<"x-riak-if-not-modified">> => VClock
    },
    {ok, Options} = riak_admin_api_riak:conditional_put_options(Headers),
    ?assert(lists:member({if_none_match, true}, Options)),
    ?assert(lists:keymember(if_not_modified, 1, Options)).

conditional_put_options_rejects_non_wildcard_if_none_match_test() ->
    Headers = #{<<"if-none-match">> => <<"\"etag-1\"">>},
    {error, Error} = riak_admin_api_riak:conditional_put_options(Headers),
    ?assertEqual(400, maps:get(status, Error)),
    ?assertEqual(<<"invalid_if_none_match">>, maps:get(code, Error)).

conditional_put_options_accepts_if_match_test() ->
    Headers = #{<<"if-match">> => <<"\"etag-1\"">>},
    {ok, Options} = riak_admin_api_riak:conditional_put_options(Headers),
    ?assert(lists:keymember(if_match, 1, Options)).

conditional_put_options_accepts_if_unmodified_since_test() ->
    Headers = #{<<"if-unmodified-since">> => <<"Wed, 19 Feb 2026 13:00:00 GMT">>},
    {ok, Options} = riak_admin_api_riak:conditional_put_options(Headers),
    ?assert(lists:keymember(if_unmodified_since, 1, Options)).

counter_delta_from_body_accepts_signed_integer_test() ->
    ?assertEqual({ok, 5}, riak_admin_api_riak:counter_delta_from_body(<<"5">>)),
    ?assertEqual({ok, -7}, riak_admin_api_riak:counter_delta_from_body(<<"-7">>)),
    ?assertEqual({ok, 12}, riak_admin_api_riak:counter_delta_from_body(<<" 12 ">>)).

counter_delta_from_body_rejects_non_integer_test() ->
    {error, Error} = riak_admin_api_riak:counter_delta_from_body(<<"not-an-int">>),
    ?assertEqual(400, maps:get(status, Error)),
    ?assertEqual(<<"invalid_body">>, maps:get(code, Error)).

crdt_decode_update_body_counter_and_set_test() ->
    ?assertEqual(
        {ok, {increment, 3}, undefined},
        riak_admin_api_riak:crdt_decode_update_body(counter, <<"3">>)),
    ?assertEqual(
        {ok, {update, [{add, <<"one">>}]}, undefined},
        riak_admin_api_riak:crdt_decode_update_body(set, <<"{\"add\":\"one\"}">>)).

crdt_decode_update_body_rejects_invalid_payload_test() ->
    {error, Error} = riak_admin_api_riak:crdt_decode_update_body(
        set, <<"{\"increment\":1}">>),
    ?assertEqual(400, maps:get(status, Error)),
    ?assertEqual(<<"invalid_body">>, maps:get(code, Error)).

%%% ============================================================
%%% accept_doc_value/2 safe term decoding (S0 security)
%%% ============================================================

accept_doc_value_safe_term_decode_test() ->
    %% A valid Erlang binary term should decode correctly.
    Term = {hello, [1, 2, 3]},
    Encoded = term_to_binary(Term),
    ?assertEqual(Term,
        riak_admin_api_riak:accept_doc_value(
            <<"application/x-erlang-binary">>, Encoded)).

accept_doc_value_corrupted_binary_returns_raw_body_test() ->
    %% Corrupted/invalid binary should return the raw body, not crash.
    Body = <<"not-valid-erlang-binary">>,
    ?assertEqual(Body,
        riak_admin_api_riak:accept_doc_value(
            <<"application/x-erlang-binary">>, Body)).

accept_doc_value_rejects_atom_creation_payload_test() ->
    %% Craft a raw ETF payload containing an atom name that does NOT exist
    %% in the atom table. With [safe], binary_to_term refuses to create
    %% new atoms, so accept_doc_value should fall back to returning the
    %% raw body instead of creating the atom.
    %%
    %% ETF format: <<131, 100, Len:16, AtomName/binary>>
    %% (ATOM_EXT = 100, followed by 2-byte big-endian length + name)
    FakeAtomName = <<"__s0_exploit_atom_injection_test_unique_42__">>,
    Len = byte_size(FakeAtomName),
    CraftedPayload = <<131, 100, Len:16, FakeAtomName/binary>>,
    %% With [safe], this must fail since the atom doesn't exist.
    %% accept_doc_value should catch the error and return raw body.
    Result = riak_admin_api_riak:accept_doc_value(
        <<"application/x-erlang-binary">>, CraftedPayload),
    ?assertEqual(CraftedPayload, Result).

accept_doc_value_non_erlang_passthrough_test() ->
    %% Non-erlang-binary content types should pass through unchanged.
    Body = <<"{\"key\":\"value\"}">>,
    ?assertEqual(Body,
        riak_admin_api_riak:accept_doc_value(
            <<"application/json">>, Body)).

%%% ============================================================
%%% S1: parallel_ping_nodes/2 (CG-015)
%%% ============================================================

parallel_ping_nodes_empty_list_test() ->
    %% No nodes => empty results map
    ?assertEqual(#{}, riak_admin_api_riak:parallel_ping_nodes([], 1000)).

parallel_ping_nodes_unreachable_returns_false_test() ->
    %% A nonexistent node should be unreachable (pang).
    FakeNode = 'fake_node_s1_test@127.0.0.1',
    Result = riak_admin_api_riak:parallel_ping_nodes([FakeNode], 2000),
    ?assertEqual(#{FakeNode => false}, Result).

parallel_ping_nodes_multiple_unreachable_test() ->
    %% Multiple fake nodes should all be false.
    FakeA = 'fake_a_s1_test@127.0.0.1',
    FakeB = 'fake_b_s1_test@127.0.0.1',
    Result = riak_admin_api_riak:parallel_ping_nodes([FakeA, FakeB], 2000),
    ?assertEqual(false, maps:get(FakeA, Result)),
    ?assertEqual(false, maps:get(FakeB, Result)).

parallel_ping_nodes_returns_map_with_correct_keys_test() ->
    %% Verify the returned map has entries for all requested nodes.
    FakeA = 'fake_keys_a@127.0.0.1',
    FakeB = 'fake_keys_b@127.0.0.1',
    Result = riak_admin_api_riak:parallel_ping_nodes([FakeA, FakeB], 2000),
    ?assert(maps:is_key(FakeA, Result)),
    ?assert(maps:is_key(FakeB, Result)).

%%% ============================================================
%%% S1: mapred_timeout_error_map/0 (CG-005/CG-018)
%%% ============================================================

mapred_timeout_error_map_returns_503_test() ->
    Error = riak_admin_api_riak:mapred_timeout_error_map(),
    ?assertEqual(503, maps:get(status, Error)),
    ?assertEqual(<<"timeout">>, maps:get(code, Error)),
    ?assertEqual(<<"timeout">>, maps:get(reason, Error)).

%%% ============================================================
%%% S1: list_keys_error_mode/0 (CG-005)
%%% ============================================================

list_keys_error_mode_default_compat_test() ->
    riak_admin_api_test_helpers:with_app_env(list_keys_error_mode, unset, fun() ->
        ?assertEqual(compat, riak_admin_api_riak:list_keys_error_mode())
    end).

list_keys_error_mode_strict_test() ->
    riak_admin_api_test_helpers:with_app_env(list_keys_error_mode, strict, fun() ->
        ?assertEqual(strict, riak_admin_api_riak:list_keys_error_mode())
    end).

list_keys_error_mode_invalid_falls_back_to_compat_test() ->
    riak_admin_api_test_helpers:with_app_env(list_keys_error_mode, <<"invalid">>, fun() ->
        ?assertEqual(compat, riak_admin_api_riak:list_keys_error_mode())
    end).

%%% ============================================================
%%% S1: stream_collection_ceiling/0 (CG-016)
%%% ============================================================

stream_collection_ceiling_default_test() ->
    riak_admin_api_test_helpers:with_app_env(stream_collection_ceiling_ms, unset, fun() ->
        ?assertEqual(300000, riak_admin_api_riak:stream_collection_ceiling())
    end).

stream_collection_ceiling_override_test() ->
    riak_admin_api_test_helpers:with_app_env(stream_collection_ceiling_ms, 60000, fun() ->
        ?assertEqual(60000, riak_admin_api_riak:stream_collection_ceiling())
    end).

%%% ============================================================
%%% S2 (CG-001): stream_incremental_enabled/0
%%% ============================================================

stream_incremental_enabled_default_true_test() ->
    riak_admin_api_test_helpers:with_app_env(stream_incremental_enabled, unset, fun() ->
        ?assertEqual(true, riak_admin_api_riak:stream_incremental_enabled())
    end).

stream_incremental_enabled_override_false_test() ->
    riak_admin_api_test_helpers:with_app_env(stream_incremental_enabled, false, fun() ->
        ?assertEqual(false, riak_admin_api_riak:stream_incremental_enabled())
    end).

%%% ============================================================
%%% S2 (CG-004): check_write_preconditions/3
%%% ============================================================

check_write_preconditions_no_conditions_passes_test() ->
    %% No If-Match or If-Unmodified-Since => ok immediately (no read needed)
    Context = #{bucket_type => <<"default">>, bucket => <<"b">>, key => <<"k">>},
    CondOpts = [{w, 2}],
    %% Client is unused when no conditionals are present
    ?assertEqual(ok, riak_admin_api_riak:check_write_preconditions(
        Context, CondOpts, unused_client)).

%%% ============================================================
%%% S2 (CG-006): mapred_backend_enabled/0
%%% ============================================================

mapred_backend_enabled_default_true_test() ->
    riak_admin_api_test_helpers:with_app_env(mapred_backend_enabled, unset, fun() ->
        ?assertEqual(true, riak_admin_api_riak:mapred_backend_enabled())
    end).

mapred_backend_enabled_override_false_test() ->
    riak_admin_api_test_helpers:with_app_env(mapred_backend_enabled, false, fun() ->
        ?assertEqual(false, riak_admin_api_riak:mapred_backend_enabled())
    end).

%%% ============================================================
%%% S2 (CG-007): maybe_crdt_collection_redirect/1
%%% ============================================================

crdt_collection_redirect_default_type_no_key_test() ->
    %% Default bucket type with no key => redirect to /buckets/.../counters
    Context = #{bucket_type => <<"default">>, bucket => <<"scores">>, key => undefined},
    ?assertMatch({redirect, <<"/buckets/scores/counters">>},
                 riak_admin_api_riak:maybe_crdt_collection_redirect(Context)).

crdt_collection_redirect_default_type_empty_key_test() ->
    %% Default bucket type with empty key => redirect
    Context = #{bucket_type => <<"default">>, bucket => <<"scores">>, key => <<>>},
    ?assertMatch({redirect, <<"/buckets/scores/counters">>},
                 riak_admin_api_riak:maybe_crdt_collection_redirect(Context)).

crdt_collection_redirect_non_default_type_no_redirect_test() ->
    %% Non-default bucket type => no redirect
    Context = #{bucket_type => <<"maps">>, bucket => <<"data">>, key => undefined},
    ?assertEqual(no_redirect,
                 riak_admin_api_riak:maybe_crdt_collection_redirect(Context)).

crdt_collection_redirect_default_with_key_no_redirect_test() ->
    %% Default bucket type WITH a key => no redirect (keyed path handled elsewhere)
    Context = #{bucket_type => <<"default">>, bucket => <<"scores">>, key => <<"k1">>},
    ?assertEqual(no_redirect,
                 riak_admin_api_riak:maybe_crdt_collection_redirect(Context)).

%%% ============================================================
%%% S5 (M-7): encode_stream_error/1 consistency
%%% ============================================================

encode_stream_error_atom_test() ->
    Result = iolist_to_binary(riak_admin_api_riak:encode_stream_error(timeout)),
    Decoded = mochijson2:decode(Result),
    ?assertEqual({struct, [{<<"error">>, <<"timeout">>}]}, Decoded).

encode_stream_error_binary_test() ->
    Result = iolist_to_binary(riak_admin_api_riak:encode_stream_error(<<"custom_err">>)),
    Decoded = mochijson2:decode(Result),
    ?assertEqual({struct, [{<<"error">>, <<"custom_err">>}]}, Decoded).

encode_stream_error_tuple_test() ->
    Result = iolist_to_binary(riak_admin_api_riak:encode_stream_error({badarg, oops})),
    Decoded = mochijson2:decode(Result),
    {struct, [{<<"error">>, ErrorBin}]} = Decoded,
    ?assert(is_binary(ErrorBin)),
    ?assert(byte_size(ErrorBin) > 0).
