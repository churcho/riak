%% @doc EUnit tests for B04 key listing and index dispatch.

-module(riak_admin_api_keylist_index_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

keylist_and_index_route_translation_to_bucket_backend_action_test_() ->
    Cases = [
        {<<"GET">>, <<"/riak/users">>, #{<<"keys">> => <<"true">>},
            keys, riak, list_keys, <<"default">>, <<"users">>,
            undefined, undefined, undefined,
            fun(Query) ->
                ?assertEqual(none, maps:get(stream_mode, Query))
            end},
        {<<"GET">>, <<"/riak/users">>, #{<<"keys">> => <<"stream">>},
            keys, riak, list_keys, <<"default">>, <<"users">>,
            undefined, undefined, undefined,
            fun(Query) ->
                ?assertEqual(keys, maps:get(stream_mode, Query))
            end},
        {<<"HEAD">>, <<"/types/maps/buckets/users/keys">>, #{<<"keys">> => <<"true">>},
            keys, types, list_keys, <<"maps">>, <<"users">>,
            undefined, undefined, undefined,
            fun(Query) ->
                ?assertEqual(none, maps:get(stream_mode, Query))
            end},
        {<<"GET">>, <<"/buckets/users/index/email_bin/alice">>, #{},
            index_query, buckets, index_query, <<"default">>, <<"users">>,
            <<"email_bin">>, undefined, <<"alice">>,
            fun(Query) ->
                ?assertEqual(none, maps:get(stream_mode, Query))
            end},
        {<<"GET">>, <<"/types/maps/buckets/users/index/age_int/10/20">>,
            #{
                <<"max_results">> => <<"10">>,
                <<"continuation">> => <<"abc">>,
                <<"return_terms">> => <<"true">>,
                <<"pagination_sort">> => <<"false">>,
                <<"stream">> => <<"true">>,
                <<"timeout">> => <<"5000">>
            },
            index_query, types, index_query, <<"maps">>, <<"users">>,
            <<"age_int">>, {<<"10">>, <<"20">>}, undefined,
            fun(Query) ->
                ?assertEqual(10, maps:get(<<"max_results">>, Query)),
                ?assertEqual(<<"abc">>, maps:get(<<"continuation">>, Query)),
                ?assertEqual(true, maps:get(<<"return_terms">>, Query)),
                ?assertEqual(false, maps:get(<<"pagination_sort">>, Query)),
                ?assertEqual(true, maps:get(<<"stream">>, Query)),
                ?assertEqual(5000, maps:get(<<"timeout">>, Query)),
                ?assertEqual(index, maps:get(stream_mode, Query))
            end}
    ],
    [?_test(assert_bucket_backend_case(Case)) || Case <- Cases].

index_method_not_allowed_allow_header_contract_test() ->
    StreamID = index_405_stream,
    Req0 = #{
        method => <<"PATCH">>,
        path => <<"/buckets/users/index/email_bin/alice">>,
        headers => #{<<"x-request-id">> => <<"rid-b04-index-405">>},
        pid => self(),
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        #{
            route_family => buckets,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => fun assert_no_bucket_backend/3
        }),

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(405, Status),
    ?assertEqual(<<"GET, HEAD">>, maps:get(<<"allow">>, Headers)),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Decoded)).

assert_bucket_backend_case(
        {Method, Path, Query0, ExpectedOp, ExpectedAlias, ExpectedAction, ExpectedBucketType,
         ExpectedBucket, ExpectedField, ExpectedRange, ExpectedTerm, QueryAssertFun}) ->
    StreamID = {b04_route_translate, Method, Path},
    Parent = self(),
    BucketBackend = fun(Action, Context, Input) ->
        Parent ! {bucket_backend_call, Action, Context, Input},
        {ok, backend_reply(Action, Context)}
    end,
    Req0 = #{
        method => Method,
        path => Path,
        query => Query0,
        headers => #{<<"x-request-id">> => <<"rid-b04-route">>},
        pid => Parent,
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        #{
            route_family => route_family(Path),
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => BucketBackend
        }),

    receive
        {bucket_backend_call, Action, Context, Input} ->
            ?assertEqual(ExpectedAction, Action),
            ?assertEqual(ExpectedOp, maps:get(op, Context)),
            ?assertEqual(ExpectedAlias, maps:get(alias, Context)),
            ?assertEqual(ExpectedBucketType, maps:get(bucket_type, Context)),
            ?assertEqual(ExpectedBucket, maps:get(bucket, Context)),
            ?assertEqual(Path, maps:get(route, Context)),
            ?assertEqual(maps:get(query, Context), maps:get(query, Input)),
            assert_optional_equal(ExpectedField, maps:get(field, Context)),
            assert_optional_equal(ExpectedRange, maps:get(range, Context)),
            assert_optional_term(ExpectedTerm, maps:get(extras, Context, #{})),
            QueryAssertFun(maps:get(query, Context))
    after 500 ->
        ?assert(false)
    end,

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(200, Status),
    case Method of
        <<"HEAD">> ->
            ?assertEqual(<<>>, Body);
        _ ->
            ?assertNotEqual(<<>>, Body)
    end,
    assert_content_type_for_case(ExpectedAction, Query0, Headers).

assert_optional_equal(undefined, _Actual) ->
    ok;
assert_optional_equal(Expected, Actual) ->
    ?assertEqual(Expected, Actual).

assert_optional_term(undefined, _Extras) ->
    ok;
assert_optional_term(Term, Extras) ->
    ?assertEqual(Term, maps:get(term, Extras)).

assert_content_type_for_case(list_keys, _Query, Headers) ->
    ?assertEqual(<<"application/json; charset=utf-8">>, maps:get(<<"content-type">>, Headers));
assert_content_type_for_case(index_query, Query, Headers) ->
    case maps:get(<<"stream">>, Query, undefined) of
        <<"true">> ->
            ?assertMatch(<<"multipart/mixed;boundary=", _/binary>>,
                maps:get(<<"content-type">>, Headers));
        _ ->
            ?assertEqual(<<"application/json; charset=utf-8">>,
                maps:get(<<"content-type">>, Headers))
    end.

backend_reply(list_keys, _Context) ->
    #{
        status => 200,
        body => <<"{\"keys\":[]}">>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(index_query, Context) ->
    Query = maps:get(query, Context, #{}),
    case maps:get(<<"stream">>, Query, false) of
        true ->
            #{
                status => 200,
                body => <<"\r\n--b04\r\nContent-Type: application/json\r\n\r\n{\"keys\":[]}\r\n--b04--\r\n">>,
                content_type => <<"multipart/mixed;boundary=b04">>
            };
        _ ->
            #{
                status => 200,
                body => <<"{\"keys\":[]}">>,
                content_type => <<"application/json; charset=utf-8">>
            }
    end.

assert_no_object_backend(_Action, _Context, _Input) ->
    ?assert(false).

assert_no_bucket_backend(_Action, _Context, _Input) ->
    ?assert(false).

route_family(<<"/riak", _/binary>>) -> riak;
route_family(<<"/buckets", _/binary>>) -> buckets;
route_family(<<"/types", _/binary>>) -> types.

receive_response_for_stream(StreamID) ->
    Pid = self(),
    receive
        {{Pid, StreamID}, {response, Status, Headers, Body}} ->
            {Status, Headers, Body}
    after 500 ->
        ?assert(false)
    end.
