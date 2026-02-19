%% @doc EUnit tests for B02 object CRUD handler dispatch.

-module(riak_admin_api_object_crud_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

object_get_uses_backend_and_compat_headers_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/keys/alice">>,
        headers => #{<<"x-request-id">> => <<"rid-get">>},
        pid => self(),
        streamid => get_stream
    },
    Backend = fun(get, Context, _Input) ->
        ?assertEqual(object_item, maps:get(op, Context)),
        {ok, #{
            status => 200,
            body => <<"value-1">>,
            content_type => <<"text/plain">>,
            reply_opts => #{
                vclock => <<"clock-1">>,
                etag => <<"\"etag-1\"">>,
                last_modified => <<"Wed, 19 Feb 2026 13:00:00 GMT">>,
                link => <<"</buckets/users>; riaktag=up">>
            },
            headers => #{<<"x-riak-meta-color">> => <<"blue">>}
        }}
    end,

    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        #{route_family => buckets, object_backend => Backend}),

    {Status, Headers, Body} = receive_response_for_stream(get_stream),
    ?assertEqual(200, Status),
    ?assertEqual(<<"text/plain">>, maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"clock-1">>, maps:get(<<"x-riak-vclock">>, Headers)),
    ?assertEqual(<<"\"etag-1\"">>, maps:get(<<"etag">>, Headers)),
    ?assertEqual(<<"Wed, 19 Feb 2026 13:00:00 GMT">>, maps:get(<<"last-modified">>, Headers)),
    ?assertEqual(<<"</buckets/users>; riaktag=up">>, maps:get(<<"link">>, Headers)),
    ?assertEqual(<<"blue">>, maps:get(<<"x-riak-meta-color">>, Headers)),
    ?assertEqual(<<"value-1">>, Body).

object_head_omits_body_test() ->
    Req0 = #{
        method => <<"HEAD">>,
        path => <<"/buckets/users/keys/alice">>,
        headers => #{<<"x-request-id">> => <<"rid-head">>},
        pid => self(),
        streamid => head_stream
    },
    Backend = fun(get, _Context, _Input) ->
        {ok, #{
            status => 200,
            body => <<"should-not-be-returned">>,
            content_type => <<"application/octet-stream">>,
            reply_opts => #{vclock => <<"clock-head">>}
        }}
    end,

    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        #{route_family => buckets, object_backend => Backend}),

    {Status, Headers, Body} = receive_response_for_stream(head_stream),
    ?assertEqual(200, Status),
    ?assertEqual(<<"application/octet-stream">>, maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"clock-head">>, maps:get(<<"x-riak-vclock">>, Headers)),
    ?assertEqual(<<>>, Body).

object_create_post_sets_location_header_test() ->
    Req0 = #{
        method => <<"POST">>,
        path => <<"/buckets/users/keys">>,
        headers => #{
            <<"x-request-id">> => <<"rid-create">>,
            <<"content-type">> => <<"application/octet-stream">>
        },
        body => <<"new-object">>,
        pid => self(),
        streamid => create_stream
    },
    Backend = fun(create, _Context, Input) ->
        ?assertEqual(<<"new-object">>, maps:get(body, Input)),
        {ok, #{
            status => 201,
            body => <<>>,
            content_type => <<"application/json; charset=utf-8">>,
            headers => #{<<"location">> => <<"/buckets/users/keys/generated-1">>}
        }}
    end,

    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        #{route_family => buckets, object_backend => Backend}),

    {Status, Headers, _Body} = receive_response_for_stream(create_stream),
    ?assertEqual(201, Status),
    ?assertEqual(<<"/buckets/users/keys/generated-1">>, maps:get(<<"location">>, Headers)).

object_put_forwards_conditional_headers_test() ->
    Req0 = #{
        method => <<"PUT">>,
        path => <<"/buckets/users/keys/alice">>,
        headers => #{
            <<"content-type">> => <<"application/octet-stream">>,
            <<"if-none-match">> => <<"*">>,
            <<"if-unmodified-since">> => <<"Wed, 19 Feb 2026 13:00:00 GMT">>,
            <<"x-riak-if-not-modified">> => <<"a85hYGBgzGDK">>
        },
        body => <<"new-value">>,
        pid => self(),
        streamid => put_stream
    },
    Parent = self(),
    Backend = fun(put, _Context, Input) ->
        Parent ! {object_put_input, Input},
        {ok, #{status => 204, body => <<>>, content_type => <<"application/json; charset=utf-8">>}}
    end,

    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        #{route_family => buckets, object_backend => Backend}),

    receive
        {object_put_input, Input} ->
            Headers = maps:get(headers, Input),
            ?assertEqual(<<"*">>, maps:get(<<"if-none-match">>, Headers)),
            ?assertEqual(<<"Wed, 19 Feb 2026 13:00:00 GMT">>,
                maps:get(<<"if-unmodified-since">>, Headers)),
            ?assertEqual(<<"a85hYGBgzGDK">>, maps:get(<<"x-riak-if-not-modified">>, Headers)),
            ?assertEqual(<<"new-value">>, maps:get(body, Input))
    after 500 ->
        ?assert(false)
    end,

    {Status, _Headers, _Body} = receive_response_for_stream(put_stream),
    ?assertEqual(204, Status).

object_get_supports_sibling_response_form_test() ->
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/keys/alice">>,
        headers => #{<<"accept">> => <<"text/plain">>},
        pid => self(),
        streamid => siblings_stream
    },
    Backend = fun(get, _Context, _Input) ->
        {ok, #{
            status => 300,
            body => <<"Siblings:\nabc\ndef\n">>,
            content_type => <<"text/plain">>,
            reply_opts => #{vclock => <<"clock-siblings">>}
        }}
    end,

    {ok, _Req1, _State} = riak_admin_api_handler:init(
        Req0,
        #{route_family => buckets, object_backend => Backend}),

    {Status, Headers, Body} = receive_response_for_stream(siblings_stream),
    ?assertEqual(300, Status),
    ?assertEqual(<<"text/plain">>, maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"clock-siblings">>, maps:get(<<"x-riak-vclock">>, Headers)),
    ?assertEqual(<<"Siblings:\nabc\ndef\n">>, Body).

receive_response_for_stream(StreamID) ->
    Pid = self(),
    receive
        {{Pid, StreamID}, {response, Status, Headers, Body}} ->
            {Status, Headers, Body}
    after 500 ->
        ?assert(false)
    end.
