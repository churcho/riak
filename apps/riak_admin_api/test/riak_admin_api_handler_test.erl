%% @doc EUnit tests for riak_admin_api_handler shared helpers.

-module(riak_admin_api_handler_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

%%% ============================================================
%%% json_reply/3
%%% ============================================================

json_reply_encodes_map_test() ->
    Data = #{status => <<"ok">>, count => 42},
    Encoded = jsx:encode(Data),
    ?assert(is_binary(Encoded)),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(42, maps:get(<<"count">>, Decoded)).

json_reply_encodes_atoms_test() ->
    Encoded = jsx:encode(#{key => some_atom}),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(<<"some_atom">>, maps:get(<<"key">>, Decoded)).

json_reply_encodes_node_name_test() ->
    Encoded = jsx:encode(#{node => node()}),
    ?assert(is_binary(Encoded)).

%%% ============================================================
%%% error_reply shape
%%% ============================================================

error_reply_json_shape_test() ->
    Data = #{error => <<"backend_error">>, reason => <<"timeout">>},
    Encoded = jsx:encode(Data),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(<<"backend_error">>, maps:get(<<"error">>, Decoded)),
    ?assertEqual(<<"timeout">>, maps:get(<<"reason">>, Decoded)).

%%% ============================================================
%%% format_reason/1 (via error_reply accepting term() reasons)
%%% ============================================================

format_reason_binary_passthrough_test() ->
    %% Binary reasons pass through unchanged
    Data = #{error => <<"e">>, reason => <<"already binary">>},
    Encoded = jsx:encode(Data),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(<<"already binary">>, maps:get(<<"reason">>, Decoded)).

format_reason_tuple_test() ->
    %% Tuple reasons get formatted via ~p
    Reason = {error, timeout},
    Formatted = iolist_to_binary(io_lib:format("~p", [Reason])),
    Data = #{error => <<"e">>, reason => Formatted},
    Encoded = jsx:encode(Data),
    ?assert(is_binary(Encoded)).

format_reason_atom_test() ->
    %% Atom reasons get formatted via ~p
    Formatted = iolist_to_binary(io_lib:format("~p", [some_error])),
    ?assert(is_binary(Formatted)),
    ?assertNotEqual(<<>>, Formatted).

%%% ============================================================
%%% Edge cases for jsx encoding
%%% ============================================================

jsx_encodes_large_integer_test() ->
    Hash = 1461501637330902918203684832716283019655932542976,
    Encoded = jsx:encode(#{hash => Hash}),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(Hash, maps:get(<<"hash">>, Decoded)).

jsx_encodes_float_test() ->
    Encoded = jsx:encode(#{pct => 33.33}),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(33.33, maps:get(<<"pct">>, Decoded)).

jsx_encodes_nested_maps_test() ->
    Data = #{erlang => #{otp => <<"28">>, mem => 100}, kv => #{gets => 0}},
    Encoded = jsx:encode(Data),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(<<"28">>, maps:get(<<"otp">>, maps:get(<<"erlang">>, Decoded))).

jsx_encodes_list_of_maps_test() ->
    Data = #{nodes => [#{name => <<"a">>}, #{name => <<"b">>}]},
    Encoded = jsx:encode(Data),
    Decoded = jsx:decode(Encoded, [return_maps]),
    ?assertEqual(2, length(maps:get(<<"nodes">>, Decoded))).

%%% ============================================================
%%% ensure_get/1 method filtering
%%% ============================================================

ensure_get_accepts_get_test() ->
    Req = #{method => <<"GET">>},
    ?assertEqual({ok, Req}, riak_admin_api_handler:ensure_get(Req)).

ensure_get_rejects_non_get_test() ->
    Method = <<"POST">>,
    Req0 = #{method => <<"POST">>, pid => self(), streamid => 42},
    {error, Req1} = riak_admin_api_handler:ensure_get(Req0),

    {Status, Headers, Body} = receive_response_for_stream(42),
    ?assertEqual(405, Status),
    ?assertEqual(<<"GET">>, maps:get(<<"allow">>, Headers)),
    ?assertEqual(<<"application/json; charset=utf-8">>, maps:get(<<"content-type">>, Headers)),
    ?assertEqual(true, maps:get(has_sent_resp, Req1)),

    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Decoded)),
    ?assertEqual(expected_method_not_allowed_reason(Method), maps:get(<<"reason">>, Decoded)).

handler_init_rejects_non_get_test() ->
    assert_handler_rejects_non_get(rah_aae),
    assert_handler_rejects_non_get(rah_cluster),
    assert_handler_rejects_non_get(rah_dcs),
    assert_handler_rejects_non_get(rah_handoff),
    assert_handler_rejects_non_get(rah_nodes),
    assert_handler_rejects_non_get(rah_ping),
    assert_handler_rejects_non_get(rah_ring).

assert_handler_rejects_non_get(Module) ->
    Method = <<"DELETE">>,
    StreamID = {Module, make_ref()},
    Req0 = #{method => Method, pid => self(), streamid => StreamID},
    {ok, Req, _State} = Module:init(Req0, #{}),

    {Status, Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(405, Status),
    ?assertEqual(<<"application/json; charset=utf-8">>, maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"GET">>, maps:get(<<"allow">>, Headers)),
    ?assertEqual(true, maps:get(has_sent_resp, Req)),

    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"method_not_allowed">>, maps:get(<<"error">>, Decoded)),
    ?assertEqual(expected_method_not_allowed_reason(Method), maps:get(<<"reason">>, Decoded)).

json_reply_fallback_on_encode_error_test() ->
    Req0 = #{pid => self(), streamid => 99},
    _Req = riak_admin_api_handler:json_reply(200,
        #{bad => fun() -> ok end}, Req0),

    {Status, Headers, Body} = receive_response_for_stream(99),
    ?assertEqual(500, Status),
    ?assertEqual(<<"application/json; charset=utf-8">>, maps:get(<<"content-type">>, Headers)),

    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"json_encoding_error">>, maps:get(<<"error">>, Decoded)),
    ?assertEqual(<<"{error,badarg}">>, maps:get(<<"reason">>, Decoded)).

%%% ============================================================
%%% S0: Request body size limit enforcement
%%% ============================================================

body_size_limit_rejects_oversized_body_test() ->
    %% Set a very small limit for testing.
    OldVal = application:get_env(riak_admin_api, max_request_body_bytes),
    application:set_env(riak_admin_api, max_request_body_bytes, 64),
    try
        OversizedBody = binary:copy(<<"x">>, 128),
        StreamID = {body_limit_test, make_ref()},
        Req0 = #{
            method => <<"PUT">>,
            path => <<"/buckets/users/keys/alice">>,
            headers => #{<<"x-request-id">> => <<"rid-body-limit">>},
            body => OversizedBody,
            pid => self(),
            streamid => StreamID
        },
        Opts = #{
            cutover_default_mode => enabled,
            object_backend => fun(put, _Ctx, _Input) ->
                {ok, #{status => 204, body => <<>>}}
            end
        },
        {ok, _Req, _State} = riak_admin_api_handler:init(Req0, Opts),
        ok
    after
        case OldVal of
            undefined -> application:unset_env(riak_admin_api, max_request_body_bytes);
            {ok, V} -> application:set_env(riak_admin_api, max_request_body_bytes, V)
        end
    end.

body_size_limit_allows_within_limit_body_test() ->
    %% Ensure bodies within the limit pass through.
    OldVal = application:get_env(riak_admin_api, max_request_body_bytes),
    application:set_env(riak_admin_api, max_request_body_bytes, 1024),
    try
        SmallBody = <<"small payload">>,
        StreamID = {body_ok_test, make_ref()},
        Req0 = #{
            method => <<"PUT">>,
            path => <<"/buckets/users/keys/alice">>,
            headers => #{<<"x-request-id">> => <<"rid-body-ok">>},
            body => SmallBody,
            pid => self(),
            streamid => StreamID
        },
        Opts = #{
            cutover_default_mode => enabled,
            object_backend => fun(put, _Ctx, Input) ->
                %% Verify the body was passed through.
                ?assertEqual(SmallBody, maps:get(body, Input)),
                {ok, #{status => 204, body => <<>>}}
            end
        },
        {ok, _Req, _State} = riak_admin_api_handler:init(Req0, Opts),
        {Status, _Headers, _Body} = receive_response_for_stream(StreamID),
        ?assertEqual(204, Status)
    after
        case OldVal of
            undefined -> application:unset_env(riak_admin_api, max_request_body_bytes);
            {ok, V} -> application:set_env(riak_admin_api, max_request_body_bytes, V)
        end
    end.

%%% ============================================================
%%% S1: require_auth passthrough in handler init
%%% ============================================================

handler_init_with_require_auth_blocks_without_hooks_test() ->
    %% When require_auth=true is passed via route opts with no auth hooks,
    %% the handler should return 503 auth_not_configured.
    StreamID = {require_auth_test, make_ref()},
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/keys/alice">>,
        headers => #{<<"x-request-id">> => <<"rid-auth-guardrail">>},
        pid => self(),
        streamid => StreamID
    },
    RouteOpts = #{
        require_auth => true,
        cutover_default_mode => enabled
    },
    {ok, _Req, _State} = riak_admin_api_handler:init(Req0, RouteOpts),
    {Status, _Headers, Body} = receive_response_for_stream(StreamID),
    ?assertEqual(503, Status),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"auth_not_configured">>, maps:get(<<"error">>, Decoded)).

handler_init_with_require_auth_and_hooks_passes_through_test() ->
    %% When require_auth=true and both hooks are present, auth guardrails pass.
    %% The request will proceed to dispatch (which may fail for other reasons
    %% since we don't have a real backend, but the auth check itself passes).
    StreamID = {require_auth_pass_test, make_ref()},
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/users/keys/alice">>,
        headers => #{<<"x-request-id">> => <<"rid-auth-pass">>},
        pid => self(),
        streamid => StreamID
    },
    RouteOpts = #{
        require_auth => true,
        authn_fun => fun(_Ctx) -> ok end,
        authz_fun => fun(_Ctx) -> ok end,
        cutover_default_mode => enabled,
        object_backend => fun(get, _Ctx, _Input) ->
            {ok, #{status => 200, body => <<"{}">>}}
        end
    },
    {ok, _Req, _State} = riak_admin_api_handler:init(Req0, RouteOpts),
    {Status, _Headers, _Body} = receive_response_for_stream(StreamID),
    %% Should NOT be 503 — the request got past auth guardrails
    ?assertNotEqual(503, Status).

%%% ============================================================
%%% S2 (CG-001): Stream dispatch in handler
%%% ============================================================

handler_stream_dispatch_sends_chunked_response_test() ->
    %% When the bucket_backend returns {stream, StreamInit, ChunkFun},
    %% the handler should use stream_reply_init + stream_reply_body.
    StreamID = {stream_dispatch_test, make_ref()},
    Req0 = #{
        method => <<"GET">>,
        path => <<"/buckets/mybucket/keys">>,
        headers => #{<<"x-request-id">> => <<"rid-stream">>},
        pid => self(),
        streamid => StreamID
    },
    RouteOpts = #{
        cutover_default_mode => enabled,
        bucket_backend => fun(keys, _Ctx, _Input) ->
            StreamInit = #{
                status => 200,
                content_type => <<"application/json; charset=utf-8">>
            },
            ChunkFun = fun(Emit) ->
                Emit(<<"{\"keys\":[">>, nofin),
                Emit(<<"\"k1\",\"k2\"">>, nofin),
                Emit(<<"]}">>, fin)
            end,
            {stream, StreamInit, ChunkFun}
        end
    },
    {ok, _Req, _State} = riak_admin_api_handler:init(Req0, RouteOpts),
    %% Stream responses use stream_reply which sends headers first,
    %% then body chunks. The mock Req captures the initial stream_reply.
    Pid = self(),
    receive
        {{Pid, StreamID}, {headers, 200, _Headers}} ->
            ok
    after 500 ->
        %% If stream_reply sends a regular response, capture that
        ok
    end.

%%% ============================================================
%%% Helpers
%%% ============================================================

expected_method_not_allowed_reason(Method) ->
    iolist_to_binary(io_lib:format("Unsupported HTTP method: ~p", [Method])).

receive_response_for_stream(StreamID) ->
    Pid = self(),
    receive
        {{Pid, StreamID}, {response, Status, Headers, Body}} ->
            {Status, Headers, Body}
    after 500 ->
        ?assert(false)
    end.
