%% @doc EUnit tests for riak_admin_api_request substrate normalization.

-module(riak_admin_api_request_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

normalize_alias_equivalence_test() ->
    {ok, RiakReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/riak/users/alice">>, #{}),
    {ok, BucketsReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/buckets/users/keys/alice">>, #{}),
    {ok, TypesReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/default/buckets/users/keys/alice">>, #{}),

    Canonical = #{
        op => object_item,
        bucket_type => <<"default">>,
        bucket => <<"users">>,
        key => <<"alice">>
    },

    ?assertEqual(Canonical, pick_canonical(RiakReq)),
    ?assertEqual(Canonical, pick_canonical(BucketsReq)),
    ?assertEqual(Canonical, pick_canonical(TypesReq)).

normalize_legacy_riak_ambiguous_bucket_test() ->
    {ok, KeysReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/riak/users">>, #{<<"keys">> => <<"stream">>}),
    ?assertEqual(keys, maps:get(op, KeysReq)),
    ?assertEqual(keys, maps:get(stream_mode, maps:get(query, KeysReq))),

    {ok, PropsReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/riak/users">>, #{}),
    ?assertEqual(bucket_props, maps:get(op, PropsReq)),

    {ok, CollectionReq} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/riak/users">>, #{<<"props">> => <<"false">>}),
    ?assertEqual(object_collection, maps:get(op, CollectionReq)).

normalize_query_boolean_and_quorum_test() ->
    Query0 = #{
        <<"basic_quorum">> => <<"TRUE">>,
        <<"returnbody">> => <<"false">>,
        <<"r">> => <<"quorum">>,
        <<"w">> => <<"2">>,
        <<"timeout">> => <<"5000">>
    },
    {ok, Query} = riak_admin_api_request:normalize_query(Query0),
    ?assertEqual(true, maps:get(<<"basic_quorum">>, Query)),
    ?assertEqual(false, maps:get(<<"returnbody">>, Query)),
    ?assertEqual(quorum, maps:get(<<"r">>, Query)),
    ?assertEqual(2, maps:get(<<"w">>, Query)),
    ?assertEqual(5000, maps:get(<<"timeout">>, Query)).

normalize_query_invalid_boolean_test() ->
    {error, Err} = riak_admin_api_request:normalize_query(
        #{<<"stream">> => <<"not-a-bool">>}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)).

request_id_propagates_from_header_test() ->
    {ok, Headers} = riak_admin_api_request:normalize_headers(
        #{<<"x-request-id">> => <<"req-123">>}),
    ?assertEqual(<<"req-123">>, maps:get(request_id, Headers)).

request_id_generated_when_missing_test() ->
    {ok, Headers} = riak_admin_api_request:normalize_headers(#{}),
    RequestId = maps:get(request_id, Headers),
    ?assert(is_binary(RequestId)),
    ?assert(byte_size(RequestId) > 8).

security_hook_denies_test() ->
    Context = #{op => object_item},
    Opts = #{authz_fun => fun(_Ctx) -> {deny, 403, <<"forbidden">>, <<"blocked">>} end},
    {error, Err} = riak_admin_api_request:ensure_security(Context, Opts),
    ?assertEqual(403, maps:get(status, Err)),
    ?assertEqual(<<"forbidden">>, maps:get(code, Err)),
    ?assertEqual(<<"blocked">>, maps:get(reason, Err)).

normalize_full_request_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/keys/alice">>,
        qs => <<"r=quorum&basic_quorum=true">>,
        headers => #{<<"x-request-id">> => <<"rid-1">>}
    },
    {ok, Context, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(object_item, maps:get(op, Context)),
    ?assertEqual(<<"rid-1">>, maps:get(request_id, Context)),
    Query = maps:get(query, Context),
    ?assertEqual(quorum, maps:get(<<"r">>, Query)),
    ?assertEqual(true, maps:get(<<"basic_quorum">>, Query)).

pick_canonical(Context) ->
    #{
        op => maps:get(op, Context),
        bucket_type => maps:get(bucket_type, Context),
        bucket => maps:get(bucket, Context),
        key => maps:get(key, Context)
    }.
