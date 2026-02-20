%% @doc EUnit tests for B06 counter and CRDT dispatch.

-module(riak_admin_api_crdt_counter_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

counter_and_crdt_route_translation_to_bucket_backend_action_test_() ->
    Cases = [
        {<<"GET">>, <<"/buckets/users/counters/visits">>, #{<<"r">> => <<"quorum">>},
            counter, buckets, counter_get, <<"default">>, <<"users">>, <<"visits">>, undefined,
            fun(Query) ->
                ?assertEqual(quorum, maps:get(<<"r">>, Query))
            end},
        {<<"POST">>, <<"/buckets/users/counters/visits">>, #{<<"returnvalue">> => <<"true">>},
            counter, buckets, counter_update, <<"default">>, <<"users">>, <<"visits">>, <<"5">>,
            fun(Query) ->
                ?assertEqual(true, maps:get(<<"returnvalue">>, Query))
            end},
        {<<"GET">>, <<"/types/maps/buckets/users/datatypes/alice">>,
            #{<<"include_context">> => <<"false">>},
            crdt_item, types, crdt_fetch, <<"maps">>, <<"users">>, <<"alice">>, undefined,
            fun(Query) ->
                ?assertEqual(false, maps:get(<<"include_context">>, Query))
            end},
        {<<"POST">>, <<"/types/maps/buckets/users/datatypes/alice">>,
            #{<<"returnbody">> => <<"true">>},
            crdt_item, types, crdt_update, <<"maps">>, <<"users">>, <<"alice">>,
            <<"{\"add\":\"one\"}">>,
            fun(Query) ->
                ?assertEqual(true, maps:get(<<"returnbody">>, Query))
            end},
        {<<"POST">>, <<"/types/maps/buckets/users/datatypes">>, #{},
            crdt_collection, types, crdt_create, <<"maps">>, <<"users">>, undefined,
            <<"{\"add\":\"one\"}">>,
            fun(Query) ->
                ?assertEqual(none, maps:get(stream_mode, Query))
            end}
    ],
    [?_test(assert_bucket_backend_case(Case)) || Case <- Cases].

counter_method_not_allowed_allow_header_contract_test() ->
    StreamID = counter_405_stream,
    Req0 = #{
        method => <<"PATCH">>,
        path => <<"/buckets/users/counters/visits">>,
        headers => #{<<"x-request-id">> => <<"rid-b06-counter-405">>},
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
    ?assertEqual(<<"GET, POST">>, maps:get(<<"allow">>, Headers)),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Decoded)).

crdt_collection_method_not_allowed_allow_header_contract_test() ->
    StreamID = crdt_collection_405_stream,
    Req0 = #{
        method => <<"GET">>,
        path => <<"/types/maps/buckets/users/datatypes">>,
        headers => #{<<"x-request-id">> => <<"rid-b06-crdt-collection-405">>},
        pid => self(),
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => types,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => fun assert_no_bucket_backend/3
        })),

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(405, Status),
    ?assertEqual(<<"POST">>, maps:get(<<"allow">>, Headers)),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Decoded)).

assert_bucket_backend_case(
        {Method, Path, Query0, ExpectedOp, ExpectedAlias, ExpectedAction, ExpectedBucketType,
         ExpectedBucket, ExpectedKey, ReqBody, QueryAssertFun}) ->
    StreamID = {b06_route_translate, Method, Path},
    Parent = self(),
    BucketBackend = fun(Action, Context, Input) ->
        Parent ! {bucket_backend_call, Action, Context, Input},
        {ok, backend_reply(Action)}
    end,
    Req0 = #{
        method => Method,
        path => Path,
        query => Query0,
        headers => #{<<"x-request-id">> => <<"rid-b06-route">>},
        pid => Parent,
        streamid => StreamID
    },
    Req = case ReqBody of
        undefined ->
            Req0;
        _ ->
            Req0#{body => ReqBody}
    end,
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req,
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
            ?assertEqual(ExpectedKey, maps:get(key, Context)),
            ?assertEqual(Path, maps:get(route, Context)),
            ?assertEqual(maps:get(query, Context), maps:get(query, Input)),
            case ReqBody of
                undefined ->
                    ok;
                _ ->
                    ?assertEqual(ReqBody, maps:get(body, Input))
            end,
            QueryAssertFun(maps:get(query, Context))
    after 500 ->
        ?assert(false)
    end,

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(200, Status),
    ?assertNotEqual(<<>>, Body),
    ?assert(maps:is_key(<<"content-type">>, Headers)).

backend_reply(counter_get) ->
    #{
        status => 200,
        body => <<"7">>,
        content_type => <<"text/plain; charset=utf-8">>
    };
backend_reply(counter_update) ->
    #{
        status => 200,
        body => <<"8">>,
        content_type => <<"text/plain; charset=utf-8">>
    };
backend_reply(crdt_fetch) ->
    #{
        status => 200,
        body => <<"{\"type\":\"set\",\"value\":[\"one\"]}">>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(crdt_update) ->
    #{
        status => 200,
        body => <<"{\"type\":\"set\",\"value\":[\"one\",\"two\"]}">>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(crdt_create) ->
    #{
        status => 200,
        body => <<"{\"type\":\"set\",\"value\":[\"one\"]}">>,
        content_type => <<"application/json; charset=utf-8">>
    }.

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
