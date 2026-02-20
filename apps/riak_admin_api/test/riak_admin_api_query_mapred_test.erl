%% @doc EUnit tests for B05 query and mapreduce dispatch.

-module(riak_admin_api_query_mapred_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

query_and_mapred_route_translation_to_bucket_backend_action_test_() ->
    Cases = [
        {<<"POST">>, <<"/buckets/users/query">>, #{},
            query, buckets, query, <<"default">>, <<"users">>,
            valid_query_body(),
            fun(Query) ->
                ?assertEqual(none, maps:get(stream_mode, Query))
            end},
        {<<"POST">>, <<"/types/maps/buckets/users/query">>, #{},
            query, types, query, <<"maps">>, <<"users">>,
            valid_query_body(),
            fun(Query) ->
                ?assertEqual(none, maps:get(stream_mode, Query))
            end},
        {<<"POST">>, <<"/mapred">>, #{<<"chunked">> => <<"true">>},
            mapred, mapred, mapred, <<"default">>, undefined,
            valid_mapred_body(),
            fun(Query) ->
                ?assertEqual(true, maps:get(<<"chunked">>, Query)),
                ?assertEqual(mapred, maps:get(stream_mode, Query))
            end}
    ],
    [?_test(assert_bucket_backend_case(Case)) || Case <- Cases].

query_method_not_allowed_allow_header_contract_test() ->
    StreamID = query_405_stream,
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/query">>,
        headers => #{<<"x-request-id">> => <<"rid-b05-query-405">>},
        pid => self(),
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => buckets,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => fun assert_no_bucket_backend/3
        })),

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(405, Status),
    ?assertEqual(<<"POST">>, maps:get(<<"allow">>, Headers)),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Decoded)).

mapred_get_and_head_usage_contract_test_() ->
    Methods = [<<"GET">>, <<"HEAD">>],
    [?_test(assert_mapred_usage_method(Method)) || Method <- Methods].

query_invalid_json_payload_returns_400_test() ->
    StreamID = invalid_query_body_stream,
    Parent = self(),
    BucketBackend = fun(_Action, _Context, _Input) ->
        Parent ! unexpected_bucket_backend_call,
        {ok, #{
            status => 200,
            body => <<"{\"keys\":[]}">>,
            content_type => <<"application/json; charset=utf-8">>
        }}
    end,
    Req0 = #{
        method => <<"POST">>,
        path => <<"/buckets/users/query">>,
        headers => #{<<"content-type">> => <<"application/json">>},
        body => <<"not-json">>,
        pid => Parent,
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => buckets,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => BucketBackend
        })),

    receive
        unexpected_bucket_backend_call ->
            ?assert(false)
    after 50 ->
        ok
    end,

    {Status, _Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(400, Status),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"invalid_body">>, maps:get(<<"error">>, Decoded)).

mapred_invalid_json_payload_returns_400_test() ->
    StreamID = invalid_mapred_body_stream,
    Parent = self(),
    BucketBackend = fun(_Action, _Context, _Input) ->
        Parent ! unexpected_bucket_backend_call,
        {ok, #{
            status => 200,
            body => <<"{\"ok\":true}">>,
            content_type => <<"application/json; charset=utf-8">>
        }}
    end,
    Req0 = #{
        method => <<"POST">>,
        path => <<"/mapred">>,
        headers => #{<<"content-type">> => <<"application/json">>},
        body => <<"not-json">>,
        pid => Parent,
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => mapred,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => BucketBackend
        })),

    receive
        unexpected_bucket_backend_call ->
            ?assert(false)
    after 50 ->
        ok
    end,

    {Status, _Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(400, Status),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"invalid_body">>, maps:get(<<"error">>, Decoded)).

mapred_timeout_error_uses_cowboy_error_envelope_test() ->
    StreamID = mapred_timeout_stream,
    Req0 = #{
        method => <<"POST">>,
        path => <<"/mapred">>,
        headers => #{<<"x-request-id">> => <<"rid-b05-mapred-timeout">>},
        body => valid_mapred_body(),
        pid => self(),
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => mapred,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => fun(_Action, _Context, _Input) ->
                {error, #{
                    status => 500,
                    code => <<"timeout">>,
                    reason => <<"timeout">>
                }}
            end
        })),

    {Status, _Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(500, Status),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"timeout">>, maps:get(<<"error">>, Decoded)).

assert_bucket_backend_case(
        {Method, Path, Query0, ExpectedOp, ExpectedAlias, ExpectedAction, ExpectedBucketType,
         ExpectedBucket, ReqBody, QueryAssertFun}) ->
    StreamID = {b05_route_translate, Method, Path},
    Parent = self(),
    BucketBackend = fun(Action, Context, Input) ->
        Parent ! {bucket_backend_call, Action, Context, Input},
        {ok, backend_reply(Action, Context)}
    end,
    Req0 = #{
        method => Method,
        path => Path,
        query => Query0,
        headers => #{<<"x-request-id">> => <<"rid-b05-route">>},
        body => ReqBody,
        pid => Parent,
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => route_family(Path),
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => BucketBackend
        })),

    receive
        {bucket_backend_call, Action, Context, Input} ->
            ?assertEqual(ExpectedAction, Action),
            ?assertEqual(ExpectedOp, maps:get(op, Context)),
            ?assertEqual(ExpectedAlias, maps:get(alias, Context)),
            ?assertEqual(ExpectedBucketType, maps:get(bucket_type, Context)),
            ?assertEqual(ExpectedBucket, maps:get(bucket, Context)),
            ?assertEqual(Path, maps:get(route, Context)),
            ?assertEqual(maps:get(query, Context), maps:get(query, Input)),
            ?assertEqual(ReqBody, maps:get(body, Input)),
            QueryAssertFun(maps:get(query, Context))
    after 500 ->
        ?assert(false)
    end,

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(200, Status),
    ?assertNotEqual(<<>>, Body),
    assert_content_type_for_case(ExpectedAction, Query0, Headers).

assert_mapred_usage_method(Method) ->
    StreamID = {mapred_usage_stream, Method},
    Parent = self(),
    Req0 = #{
        method => Method,
        path => <<"/mapred">>,
        headers => #{<<"x-request-id">> => <<"rid-b05-mapred-usage">>},
        pid => Parent,
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => mapred,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => fun(_Action, _Context, _Input) ->
                Parent ! unexpected_bucket_backend_call
            end
        })),

    receive
        unexpected_bucket_backend_call ->
            ?assert(false)
    after 50 ->
        ok
    end,

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(200, Status),
    ?assertMatch(<<"text/plain", _/binary>>, maps:get(<<"content-type">>, Headers)),
    case Method of
        <<"HEAD">> ->
            ?assertEqual(<<>>, Body);
        _ ->
            ?assertMatch(<<"This resource accepts POSTs", _/binary>>, Body)
    end.

assert_content_type_for_case(query, _Query, Headers) ->
    ?assertEqual(<<"application/json; charset=utf-8">>, maps:get(<<"content-type">>, Headers));
assert_content_type_for_case(mapred, Query, Headers) ->
    case maps:get(<<"chunked">>, Query, undefined) of
        <<"true">> ->
            ?assertMatch(<<"multipart/mixed;boundary=", _/binary>>,
                maps:get(<<"content-type">>, Headers));
        _ ->
            ?assertEqual(<<"application/json; charset=utf-8">>,
                maps:get(<<"content-type">>, Headers))
    end.

backend_reply(query, _Context) ->
    #{
        status => 200,
        body => <<"{\"keys\":[]}">>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(mapred, Context) ->
    Query = maps:get(query, Context, #{}),
    case maps:get(<<"chunked">>, Query, false) of
        true ->
            #{
                status => 200,
                body => <<"\r\n--b05\r\nContent-Type: application/json\r\n\r\n{\"phase\":0,\"data\":[]}\r\n--b05--\r\n">>,
                content_type => <<"multipart/mixed;boundary=b05">>
            };
        _ ->
            #{
                status => 200,
                body => <<"[]">>,
                content_type => <<"application/json; charset=utf-8">>
            }
    end.

assert_no_object_backend(_Action, _Context, _Input) ->
    ?assert(false).

assert_no_bucket_backend(_Action, _Context, _Input) ->
    ?assert(false).

route_family(<<"/mapred", _/binary>>) -> mapred;
route_family(<<"/riak", _/binary>>) -> riak;
route_family(<<"/buckets", _/binary>>) -> buckets;
route_family(<<"/types", _/binary>>) -> types.

route_opts(Opts) ->
    Opts#{cutover_default_mode => enabled}.

receive_response_for_stream(StreamID) ->
    riak_admin_api_test_helpers:receive_response_for_stream(StreamID).

valid_query_body() ->
    <<"{\"query_list\":[{\"index_name\":\"email_bin\",\"start_term\":\"a\",\"end_term\":\"z\"}]}">>.

valid_mapred_body() ->
    <<"{\"inputs\":[[\"users\",\"alice\"]],\"query\":[{\"map\":{\"language\":\"javascript\",\"name\":\"Riak.mapValuesJson\"}}]}">>.
