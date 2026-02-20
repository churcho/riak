%% @doc EUnit tests for B03 bucket and bucket-type handler dispatch.

-module(riak_admin_api_bucket_type_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

bucket_route_translation_to_backend_action_test_() ->
    Cases = [
        {<<"GET">>, <<"/riak/users">>, #{},
            bucket_props, riak, get_bucket_props, undefined, 200},
        {<<"PUT">>, <<"/riak/users">>, #{},
            bucket_props, riak, set_bucket_props,
            <<"{\"props\":{\"allow_mult\":true}}">>, 204},
        {<<"GET">>, <<"/buckets/users/props">>, #{},
            bucket_props, buckets, get_bucket_props, undefined, 200},
        {<<"DELETE">>, <<"/buckets/users/props">>, #{},
            bucket_props, buckets, delete_bucket_props, undefined, 204},
        {<<"GET">>, <<"/types/maps/props">>, #{},
            bucket_type_props, types, get_bucket_type_props, undefined, 200},
        {<<"PUT">>, <<"/types/maps/props">>, #{},
            bucket_type_props, types, set_bucket_type_props,
            <<"{\"props\":{\"n_val\":3}}">>, 204},
        {<<"GET">>, <<"/riak">>, #{<<"buckets">> => <<"true">>},
            buckets, riak, list_buckets, undefined, 200},
        {<<"GET">>, <<"/buckets">>, #{<<"buckets">> => <<"stream">>},
            buckets, buckets, list_buckets, undefined, 200},
        {<<"HEAD">>, <<"/types/maps/buckets">>, #{<<"buckets">> => <<"true">>},
            buckets, types, list_buckets, undefined, 200}
    ],
    [?_test(assert_bucket_backend_case(Case)) || Case <- Cases].

bucket_props_invalid_json_payload_returns_400_test() ->
    StreamID = invalid_bucket_props_stream,
    Parent = self(),
    BucketBackend = fun(_Action, _Context, _Input) ->
        Parent ! unexpected_bucket_backend_call,
        {ok, #{
            status => 204,
            body => <<>>,
            content_type => <<"application/json; charset=utf-8">>
        }}
    end,
    Req0 = #{
        method => <<"PUT">>,
        path => <<"/buckets/users/props">>,
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

bucket_type_props_invalid_json_payload_returns_400_test() ->
    StreamID = invalid_bucket_type_props_stream,
    Parent = self(),
    BucketBackend = fun(_Action, _Context, _Input) ->
        Parent ! unexpected_bucket_backend_call,
        {ok, #{
            status => 204,
            body => <<>>,
            content_type => <<"application/json; charset=utf-8">>
        }}
    end,
    Req0 = #{
        method => <<"PUT">>,
        path => <<"/types/maps/props">>,
        headers => #{<<"content-type">> => <<"application/json">>},
        body => <<"not-json">>,
        pid => Parent,
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => types,
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

bucket_props_permission_denied_returns_403_test() ->
    StreamID = denied_bucket_props_stream,
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/props">>,
        headers => #{<<"x-request-id">> => <<"rid-b03-denied">>},
        pid => self(),
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => buckets,
            authz_fun => fun(_Ctx) -> {deny, 403, <<"forbidden">>, <<"blocked">>} end,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => fun assert_no_bucket_backend/3
        })),

    {Status, _Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(403, Status),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"forbidden">>, maps:get(<<"error">>, Decoded)).

riak_bucket_props_method_not_allowed_contract_test() ->
    StreamID = riak_bucket_props_405_stream,
    Req0 = #{
        method => <<"DELETE">>,
        path => <<"/riak/users">>,
        headers => #{<<"x-request-id">> => <<"rid-b03-405">>},
        pid => self(),
        streamid => StreamID
    },
    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        route_opts(#{
            route_family => riak,
            object_backend => fun assert_no_object_backend/3,
            bucket_backend => fun assert_no_bucket_backend/3
        })),

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(405, Status),
    ?assertEqual(<<"GET, HEAD, PUT">>, maps:get(<<"allow">>, Headers)),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Decoded)).

assert_bucket_backend_case(
        {Method, Path, Query, ExpectedOp, ExpectedAlias, ExpectedAction, ReqBody, ExpectedStatus}) ->
    StreamID = {bucket_route_translate, Method, Path},
    Parent = self(),
    BucketBackend = fun(Action, Context, Input) ->
        Parent ! {bucket_backend_call, Action, Context, Input},
        {ok, backend_reply(Action)}
    end,
    Req0 = #{
        method => Method,
        path => Path,
        query => Query,
        headers => #{<<"x-request-id">> => <<"rid-b03-route">>},
        pid => Parent,
        streamid => StreamID
    },
    Req = case ReqBody of
        undefined ->
            Req0;
        _ ->
            Req0#{
                headers => (maps:get(headers, Req0))#{<<"content-type">> => <<"application/json">>},
                body => ReqBody
            }
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
            ?assertEqual(Path, maps:get(route, Context)),
            assert_query_translation(Query, Context),
            case ReqBody of
                undefined -> ok;
                _ -> ?assertEqual(ReqBody, maps:get(body, Input))
            end
    after 500 ->
        ?assert(false)
    end,

    {Status, _Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(ExpectedStatus, Status),
    case Method of
        <<"HEAD">> -> ?assertEqual(<<>>, Body);
        _ -> ok
    end.

assert_query_translation(#{<<"buckets">> := <<"stream">>}, Context) ->
    Query = maps:get(query, Context),
    ?assertEqual(buckets, maps:get(stream_mode, Query));
assert_query_translation(_, _Context) ->
    ok.

backend_reply(get_bucket_props) ->
    #{
        status => 200,
        body => <<"{\"props\":{}}">>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(set_bucket_props) ->
    #{
        status => 204,
        body => <<>>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(delete_bucket_props) ->
    #{
        status => 204,
        body => <<>>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(get_bucket_type_props) ->
    #{
        status => 200,
        body => <<"{\"props\":{}}">>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(set_bucket_type_props) ->
    #{
        status => 204,
        body => <<>>,
        content_type => <<"application/json; charset=utf-8">>
    };
backend_reply(list_buckets) ->
    #{
        status => 200,
        body => <<"{\"buckets\":[]}">>,
        content_type => <<"application/json; charset=utf-8">>
    }.

assert_no_object_backend(_Action, _Context, _Input) ->
    ?assert(false).

assert_no_bucket_backend(_Action, _Context, _Input) ->
    ?assert(false).

route_family(<<"/riak", _/binary>>) -> riak;
route_family(<<"/buckets", _/binary>>) -> buckets;
route_family(<<"/types", _/binary>>) -> types.

route_opts(Opts) ->
    Opts#{cutover_default_mode => enabled}.

receive_response_for_stream(StreamID) ->
    riak_admin_api_test_helpers:receive_response_for_stream(StreamID).
