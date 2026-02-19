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

normalize_alias_roots_equivalence_test() ->
    {ok, RiakReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/riak">>, #{}),
    {ok, BucketsReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/buckets">>, #{}),
    {ok, TypesReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/default/buckets">>, #{}),

    Canonical = #{
        op => buckets,
        bucket_type => <<"default">>,
        bucket => undefined,
        key => undefined
    },

    ?assertEqual(Canonical, pick_canonical(RiakReq)),
    ?assertEqual(Canonical, pick_canonical(BucketsReq)),
    ?assertEqual(Canonical, pick_canonical(TypesReq)).

normalize_collection_alias_equivalence_test() ->
    {ok, RiakReq} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/riak/users">>, #{<<"props">> => <<"false">>}),
    {ok, BucketsReq} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/buckets/users/keys">>, #{}),
    {ok, TypesReq} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/types/default/buckets/users/keys">>, #{}),

    Canonical = #{
        op => object_collection,
        bucket_type => <<"default">>,
        bucket => <<"users">>,
        key => undefined
    },

    ?assertEqual(Canonical, pick_canonical(RiakReq)),
    ?assertEqual(Canonical, pick_canonical(BucketsReq)),
    ?assertEqual(Canonical, pick_canonical(TypesReq)).

normalize_bucket_props_alias_equivalence_test() ->
    {ok, RiakReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/riak/users">>, #{}),
    {ok, BucketsReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/buckets/users/props">>, #{}),
    {ok, TypesReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/default/buckets/users/props">>, #{}),

    Canonical = #{
        op => bucket_props,
        bucket_type => <<"default">>,
        bucket => <<"users">>,
        key => undefined
    },

    ?assertEqual(Canonical, pick_canonical(RiakReq)),
    ?assertEqual(Canonical, pick_canonical(BucketsReq)),
    ?assertEqual(Canonical, pick_canonical(TypesReq)).

normalize_bucket_type_props_path_test() ->
    {ok, Req} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/maps/props">>, #{}),
    ?assertEqual(bucket_type_props, maps:get(op, Req)),
    ?assertEqual(types, maps:get(alias, Req)),
    ?assertEqual(<<"maps">>, maps:get(bucket_type, Req)),
    ?assertEqual(undefined, maps:get(bucket, Req)).

normalize_bucket_list_alias_and_stream_mode_test() ->
    {ok, RiakReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/riak">>, #{<<"buckets">> => <<"stream">>}),
    {ok, BucketsReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/buckets">>, #{<<"buckets">> => <<"true">>}),
    {ok, TypesReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/maps/buckets">>, #{<<"buckets">> => <<"true">>}),

    ?assertEqual(buckets, maps:get(op, RiakReq)),
    ?assertEqual(buckets, maps:get(op, BucketsReq)),
    ?assertEqual(buckets, maps:get(op, TypesReq)),
    ?assertEqual(buckets, maps:get(stream_mode, maps:get(query, RiakReq))),
    ?assertEqual(none, maps:get(stream_mode, maps:get(query, BucketsReq))),
    ?assertEqual(<<"maps">>, maps:get(bucket_type, TypesReq)).

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

normalize_index_alias_equivalence_test() ->
    {ok, BucketsReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/buckets/users/index/email_bin/alice">>, #{}),
    {ok, TypesReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/maps/buckets/users/index/email_bin/alice">>, #{}),

    Canonical = #{
        op => index_query,
        bucket_type => <<"maps">>,
        bucket => <<"users">>,
        field => <<"email_bin">>,
        range => undefined,
        extras => #{term => <<"alice">>}
    },

    ?assertEqual(Canonical#{bucket_type => <<"default">>}, pick_index_canonical(BucketsReq)),
    ?assertEqual(Canonical, pick_index_canonical(TypesReq)).

normalize_index_range_path_test() ->
    {ok, Req} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/maps/buckets/users/index/age_int/10/20">>, #{}),
    ?assertEqual(index_query, maps:get(op, Req)),
    ?assertEqual(<<"maps">>, maps:get(bucket_type, Req)),
    ?assertEqual(<<"users">>, maps:get(bucket, Req)),
    ?assertEqual(<<"age_int">>, maps:get(field, Req)),
    ?assertEqual({<<"10">>, <<"20">>}, maps:get(range, Req)).

normalize_query_alias_equivalence_test() ->
    {ok, BucketsReq} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/buckets/users/query">>, #{}),
    {ok, TypesReq} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/types/maps/buckets/users/query">>, #{}),

    Canonical = #{
        op => query,
        bucket_type => <<"maps">>,
        bucket => <<"users">>,
        key => undefined
    },

    ?assertEqual(Canonical#{bucket_type => <<"default">>}, pick_query_canonical(BucketsReq)),
    ?assertEqual(Canonical, pick_query_canonical(TypesReq)).

normalize_mapred_path_and_stream_mode_test() ->
    {ok, Req} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/mapred">>, #{<<"chunked">> => <<"true">>}),
    ?assertEqual(mapred, maps:get(op, Req)),
    ?assertEqual(mapred, maps:get(alias, Req)),
    ?assertEqual(mapred, maps:get(stream_mode, maps:get(query, Req))),
    ?assertEqual(<<"true">>, maps:get(<<"chunked">>, maps:get(query, Req))).

normalize_counter_path_test() ->
    {ok, Req} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/buckets/users/counters/visits">>, #{}),
    ?assertEqual(counter, maps:get(op, Req)),
    ?assertEqual(buckets, maps:get(alias, Req)),
    ?assertEqual(<<"default">>, maps:get(bucket_type, Req)),
    ?assertEqual(<<"users">>, maps:get(bucket, Req)),
    ?assertEqual(<<"visits">>, maps:get(key, Req)).

normalize_crdt_paths_test() ->
    {ok, CollectionReq} = riak_admin_api_request:normalize_path(
        <<"POST">>, <<"/types/maps/buckets/users/datatypes">>, #{}),
    ?assertEqual(crdt_collection, maps:get(op, CollectionReq)),
    ?assertEqual(types, maps:get(alias, CollectionReq)),
    ?assertEqual(<<"maps">>, maps:get(bucket_type, CollectionReq)),
    ?assertEqual(<<"users">>, maps:get(bucket, CollectionReq)),

    {ok, ItemReq} = riak_admin_api_request:normalize_path(
        <<"GET">>, <<"/types/maps/buckets/users/datatypes/alice">>, #{}),
    ?assertEqual(crdt_item, maps:get(op, ItemReq)),
    ?assertEqual(types, maps:get(alias, ItemReq)),
    ?assertEqual(<<"maps">>, maps:get(bucket_type, ItemReq)),
    ?assertEqual(<<"users">>, maps:get(bucket, ItemReq)),
    ?assertEqual(<<"alice">>, maps:get(key, ItemReq)).

normalize_unsupported_path_shapes_test_() ->
    [
        ?_assertMatch(
            {error, #{status := 404, code := <<"unknown_route">>}},
            riak_admin_api_request:normalize_path(
                <<"GET">>, <<"/buckets//users/keys/alice">>, #{})),
        ?_assertMatch(
            {error, #{status := 404, code := <<"unknown_route">>}},
            riak_admin_api_request:normalize_path(
                <<"GET">>, <<"/types/default//buckets/users/keys/alice">>, #{})),
        ?_assertMatch(
            {error, #{status := 404, code := <<"unknown_route">>}},
            riak_admin_api_request:normalize_path(
                <<"GET">>, <<"/riak//users/alice">>, #{}))
    ].

normalize_method_not_allowed_includes_allow_contract_test() ->
    Req0 = #{
        method => <<"PATCH">>,
        path => <<"/buckets/users/keys/alice">>,
        headers => #{<<"x-request-id">> => <<"rid-405">>}
    },
    {error, Error, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(405, maps:get(status, Error)),
    ?assertEqual(<<"method_not_allowed">>, maps:get(code, Error)),
    ?assertEqual(
        [<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"POST">>, <<"DELETE">>],
        maps:get(allow, Error)).

normalize_query_boolean_and_quorum_test() ->
    Query0 = #{
        <<"basic_quorum">> => <<"TRUE">>,
        <<"returnbody">> => <<"false">>,
        <<"asis">> => <<"true">>,
        <<"r">> => <<"quorum">>,
        <<"w">> => <<"2">>,
        <<"timeout">> => <<"5000">>
    },
    {ok, Query} = riak_admin_api_request:normalize_query(Query0),
    ?assertEqual(true, maps:get(<<"basic_quorum">>, Query)),
    ?assertEqual(false, maps:get(<<"returnbody">>, Query)),
    ?assertEqual(true, maps:get(<<"asis">>, Query)),
    ?assertEqual(quorum, maps:get(<<"r">>, Query)),
    ?assertEqual(2, maps:get(<<"w">>, Query)),
    ?assertEqual(5000, maps:get(<<"timeout">>, Query)).

normalize_query_index_flags_and_max_results_test() ->
    Query0 = #{
        <<"max_results">> => <<"50">>,
        <<"return_terms">> => <<"true">>,
        <<"pagination_sort">> => <<"false">>,
        <<"stream">> => <<"true">>,
        <<"timeout">> => <<"2500">>
    },
    {ok, Query} = riak_admin_api_request:normalize_query(Query0),
    ?assertEqual(50, maps:get(<<"max_results">>, Query)),
    ?assertEqual(true, maps:get(<<"return_terms">>, Query)),
    ?assertEqual(false, maps:get(<<"pagination_sort">>, Query)),
    ?assertEqual(true, maps:get(<<"stream">>, Query)),
    ?assertEqual(index, maps:get(stream_mode, Query)),
    ?assertEqual(2500, maps:get(<<"timeout">>, Query)).

normalize_query_invalid_max_results_test() ->
    {error, Err} = riak_admin_api_request:normalize_query(
        #{<<"max_results">> => <<"0">>}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)).

normalize_query_invalid_boolean_test() ->
    {error, Err} = riak_admin_api_request:normalize_query(
        #{<<"stream">> => <<"not-a-bool">>}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)).

normalize_keys_query_allowlist_rejects_unknown_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/keys">>,
        query => #{<<"unexpected">> => <<"1">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)),
    ?assertMatch(<<"Unsupported query parameter:", _/binary>>, maps:get(reason, Err)).

normalize_keys_query_invalid_mode_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/keys">>,
        query => #{<<"keys">> => <<"invalid">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)).

normalize_index_query_allowlist_rejects_unknown_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/index/email_bin/alice">>,
        query => #{<<"unexpected">> => <<"1">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)),
    ?assertMatch(<<"Unsupported query parameter:", _/binary>>, maps:get(reason, Err)).

normalize_query_operation_allowlist_rejects_unknown_test() ->
    Req0 = #{
        method => <<"POST">>,
        path => <<"/buckets/users/query">>,
        query => #{<<"unexpected">> => <<"1">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)),
    ?assertMatch(<<"Unsupported query parameter:", _/binary>>, maps:get(reason, Err)).

normalize_mapred_query_allowlist_rejects_unknown_test() ->
    Req0 = #{
        method => <<"POST">>,
        path => <<"/mapred">>,
        query => #{<<"unexpected">> => <<"1">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)),
    ?assertMatch(<<"Unsupported query parameter:", _/binary>>, maps:get(reason, Err)).

normalize_mapred_query_invalid_chunked_test() ->
    Req0 = #{
        method => <<"POST">>,
        path => <<"/mapred">>,
        query => #{<<"chunked">> => <<"invalid">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)).

normalize_counter_query_allowlist_rejects_unknown_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/counters/visits">>,
        query => #{<<"unexpected">> => <<"1">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)),
    ?assertMatch(<<"Unsupported query parameter:", _/binary>>, maps:get(reason, Err)).

normalize_crdt_query_allowlist_rejects_unknown_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/types/maps/buckets/users/datatypes/alice">>,
        query => #{<<"unexpected">> => <<"1">>}
    },
    {error, Err, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(400, maps:get(status, Err)),
    ?assertEqual(<<"invalid_query">>, maps:get(code, Err)),
    ?assertMatch(<<"Unsupported query parameter:", _/binary>>, maps:get(reason, Err)).

normalize_counter_method_not_allowed_includes_allow_contract_test() ->
    Req0 = #{
        method => <<"HEAD">>,
        path => <<"/buckets/users/counters/visits">>,
        headers => #{<<"x-request-id">> => <<"rid-counter-405">>}
    },
    {error, Error, _Req1} = riak_admin_api_request:normalize(Req0, #{}),
    ?assertEqual(405, maps:get(status, Error)),
    ?assertEqual(<<"method_not_allowed">>, maps:get(code, Error)),
    ?assertEqual(
        [<<"GET">>, <<"POST">>],
        maps:get(allow, Error)).

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

pick_index_canonical(Context) ->
    #{
        op => maps:get(op, Context),
        bucket_type => maps:get(bucket_type, Context),
        bucket => maps:get(bucket, Context),
        field => maps:get(field, Context),
        range => maps:get(range, Context),
        extras => maps:get(extras, Context)
    }.

pick_query_canonical(Context) ->
    #{
        op => maps:get(op, Context),
        bucket_type => maps:get(bucket_type, Context),
        bucket => maps:get(bucket, Context),
        key => maps:get(key, Context)
    }.
