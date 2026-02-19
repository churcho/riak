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
