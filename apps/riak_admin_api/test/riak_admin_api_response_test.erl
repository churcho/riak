%% @doc EUnit tests for riak_admin_api_response serialization helpers.

-module(riak_admin_api_response_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

compat_headers_include_riak_contract_headers_test() ->
    Headers = riak_admin_api_response:compat_headers(
        #{request_id => <<"req-1">>,
          vclock => <<"a85hYGBgzGDKBVIsL0">>,
          etag => <<"\"etag-1\"">>,
          last_modified => <<"Wed, 19 Feb 2026 13:00:00 GMT">>,
          link => <<"</buckets/users>; riaktag=up">>}),
    ?assertEqual(<<"req-1">>, maps:get(<<"x-request-id">>, Headers)),
    ?assertEqual(<<"a85hYGBgzGDKBVIsL0">>, maps:get(<<"x-riak-vclock">>, Headers)),
    ?assertEqual(<<"\"etag-1\"">>, maps:get(<<"etag">>, Headers)),
    ?assertEqual(<<"Wed, 19 Feb 2026 13:00:00 GMT">>, maps:get(<<"last-modified">>, Headers)),
    ?assertEqual(<<"</buckets/users>; riaktag=up">>, maps:get(<<"link">>, Headers)).

error_payload_has_stable_shape_test() ->
    Payload = riak_admin_api_response:error_payload(
        400, <<"invalid_query">>, <<"bad timeout">>, <<"req-2">>),
    ?assertEqual(400, maps:get(status, Payload)),
    ?assertEqual(<<"invalid_query">>, maps:get(error, Payload)),
    ?assertEqual(<<"bad timeout">>, maps:get(reason, Payload)),
    ?assertEqual(<<"req-2">>, maps:get(request_id, Payload)).

error_reply_emits_json_and_status_test() ->
    Req0 = #{pid => self(), streamid => 1001},
    _Req1 = riak_admin_api_response:error_reply(
        403, <<"forbidden">>, <<"origin not allowed">>, Req0,
        #{request_id => <<"req-3">>}),

    {Status, Headers, Body} = receive_response_for_stream(1001),
    ?assertEqual(403, Status),
    ?assertEqual(<<"application/json; charset=utf-8">>,
        maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"req-3">>, maps:get(<<"x-request-id">>, Headers)),

    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"forbidden">>, maps:get(<<"error">>, Decoded)),
    ?assertEqual(<<"origin not allowed">>, maps:get(<<"reason">>, Decoded)).

json_reply_emits_compatibility_headers_test() ->
    Req0 = #{pid => self(), streamid => 1002},
    _Req1 = riak_admin_api_response:json_reply(
        200,
        #{ok => true},
        Req0,
        #{request_id => <<"req-4">>, vclock => <<"clock-1">>}),

    {Status, Headers, Body} = receive_response_for_stream(1002),
    ?assertEqual(200, Status),
    ?assertEqual(<<"application/json; charset=utf-8">>,
        maps:get(<<"content-type">>, Headers)),
    ?assertEqual(<<"req-4">>, maps:get(<<"x-request-id">>, Headers)),
    ?assertEqual(<<"clock-1">>, maps:get(<<"x-riak-vclock">>, Headers)),

    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(true, maps:get(<<"ok">>, Decoded)).

telemetry_tags_include_route_and_status_test() ->
    Context = #{route => <<"/buckets/users/keys/alice">>, op => object_item},
    Tags = riak_admin_api_response:telemetry_tags(Context, 503, 1142),
    ?assertEqual(<<"/buckets/users/keys/alice">>, maps:get(route, Tags)),
    ?assertEqual(object_item, maps:get(op, Tags)),
    ?assertEqual(503, maps:get(status, Tags)),
    ?assertEqual(1142, maps:get(duration_us, Tags)).

telemetry_tags_include_error_code_dimension_test() ->
    Context = #{
        route => <<"/mapred">>,
        op => mapred,
        error_code => <<"timeout">>
    },
    Tags = riak_admin_api_response:telemetry_tags(Context, 500, 77),
    ?assertEqual(<<"timeout">>, maps:get(error_code, Tags)).

%%% ============================================================
%%% S5 (M-2): to_binary/1 shared export
%%% ============================================================

to_binary_binary_test() ->
    ?assertEqual(<<"hello">>, riak_admin_api_response:to_binary(<<"hello">>)).

to_binary_atom_test() ->
    ?assertEqual(<<"ok">>, riak_admin_api_response:to_binary(ok)).

to_binary_integer_test() ->
    ?assertEqual(<<"42">>, riak_admin_api_response:to_binary(42)).

to_binary_list_test() ->
    ?assertEqual(<<"hello">>, riak_admin_api_response:to_binary("hello")).

to_binary_fallback_test() ->
    Result = riak_admin_api_response:to_binary({error, oops}),
    ?assert(is_binary(Result)),
    ?assert(byte_size(Result) > 0).

%%% ============================================================
%%% S5 (M-4): cors_headers/2
%%% ============================================================

cors_headers_match_emits_headers_test() ->
    Opts = #{
        trusted_origins => [<<"https://admin.example.com">>],
        request_origin => <<"https://admin.example.com">>
    },
    CorsH = riak_admin_api_response:cors_headers(Opts, #{}),
    ?assertEqual(<<"https://admin.example.com">>,
        maps:get(<<"access-control-allow-origin">>, CorsH)),
    ?assert(maps:is_key(<<"access-control-allow-methods">>, CorsH)),
    ?assert(maps:is_key(<<"access-control-allow-headers">>, CorsH)),
    ?assert(maps:is_key(<<"access-control-expose-headers">>, CorsH)),
    ?assertEqual(<<"3600">>,
        maps:get(<<"access-control-max-age">>, CorsH)).

cors_headers_mismatch_emits_nothing_test() ->
    Opts = #{
        trusted_origins => [<<"https://admin.example.com">>],
        request_origin => <<"https://evil.example.com">>
    },
    CorsH = riak_admin_api_response:cors_headers(Opts, #{}),
    ?assertEqual(#{}, CorsH).

cors_headers_no_trusted_origins_emits_nothing_test() ->
    Opts = #{
        trusted_origins => [],
        request_origin => <<"https://admin.example.com">>
    },
    CorsH = riak_admin_api_response:cors_headers(Opts, #{}),
    ?assertEqual(#{}, CorsH).

cors_headers_no_origin_emits_nothing_test() ->
    Opts = #{
        trusted_origins => [<<"https://admin.example.com">>],
        request_origin => undefined
    },
    CorsH = riak_admin_api_response:cors_headers(Opts, #{}),
    ?assertEqual(#{}, CorsH).

cors_headers_merged_into_compat_headers_test() ->
    %% Verify compat_headers merges CORS when origin matches
    Opts = #{
        request_id => <<"rid-cors">>,
        trusted_origins => [<<"https://admin.example.com">>],
        request_origin => <<"https://admin.example.com">>
    },
    Headers = riak_admin_api_response:compat_headers(Opts),
    %% Should have both compat headers and CORS headers
    ?assertEqual(<<"rid-cors">>,
        maps:get(<<"x-request-id">>, Headers)),
    ?assertEqual(<<"https://admin.example.com">>,
        maps:get(<<"access-control-allow-origin">>, Headers)).

%%% ============================================================
%%% S6: Header injection defense — sanitize_header_value/1
%%% ============================================================

sanitize_header_value_strips_crlf_test() ->
    ?assertEqual(<<"foobar">>,
        riak_admin_api_response:sanitize_header_value(<<"foo\r\nbar">>)).

sanitize_header_value_strips_null_byte_test() ->
    ?assertEqual(<<"foobar">>,
        riak_admin_api_response:sanitize_header_value(<<"foo\0bar">>)).

sanitize_header_value_strips_esc_sequence_test() ->
    %% ESC (0x1B) used in terminal escape sequences
    ?assertEqual(<<"foo[31mbar">>,
        riak_admin_api_response:sanitize_header_value(<<"foo\e[31mbar">>)).

sanitize_header_value_strips_vertical_tab_and_form_feed_test() ->
    ?assertEqual(<<"foobar">>,
        riak_admin_api_response:sanitize_header_value(<<"foo\x0B\x0Cbar">>)).

sanitize_header_value_strips_del_test() ->
    ?assertEqual(<<"foobar">>,
        riak_admin_api_response:sanitize_header_value(<<"foo\x7Fbar">>)).

sanitize_header_value_preserves_printable_ascii_test() ->
    Printable = <<"abcABC 012!@#$%^&*()~`[]{}<>:;'/?,.-_+=|\\\"">>,
    ?assertEqual(Printable,
        riak_admin_api_response:sanitize_header_value(Printable)).

sanitize_header_value_strips_tab_preserves_space_test() ->
    %% Tab (0x09) is stripped — it's below 0x20.
    ?assertEqual(<<"foobar">>,
        riak_admin_api_response:sanitize_header_value(<<"foo\tbar">>)),
    %% Space (0x20) is preserved.
    ?assertEqual(<<"foo bar">>,
        riak_admin_api_response:sanitize_header_value(<<"foo bar">>)).

sanitize_header_value_passthrough_non_binary_test() ->
    ?assertEqual(42, riak_admin_api_response:sanitize_header_value(42)),
    ?assertEqual(ok, riak_admin_api_response:sanitize_header_value(ok)).

sanitize_header_value_strips_full_http_response_splitting_payload_test() ->
    %% Classic HTTP response splitting: inject CRLF + second response
    Payload = <<"valid-id\r\nHTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<h1>evil</h1>">>,
    Sanitized = riak_admin_api_response:sanitize_header_value(Payload),
    ?assertEqual(nomatch, binary:match(Sanitized, <<"\r">>)),
    ?assertEqual(nomatch, binary:match(Sanitized, <<"\n">>)),
    %% The printable parts are preserved
    ?assert(binary:match(Sanitized, <<"valid-id">>) =/= nomatch).

sanitize_headers_applied_to_json_reply_test() ->
    %% Verify that json_reply sanitizes header values containing CRLF
    Req0 = #{pid => self(), streamid => 2001},
    _Req1 = riak_admin_api_response:json_reply(
        200, #{ok => true}, Req0,
        #{request_id => <<"rid-\r\n-injected">>}),
    {_Status, Headers, _Body} = receive_response_for_stream(2001),
    ReqId = maps:get(<<"x-request-id">>, Headers),
    ?assertEqual(nomatch, binary:match(ReqId, <<"\r">>)),
    ?assertEqual(nomatch, binary:match(ReqId, <<"\n">>)).

sanitize_headers_applied_to_raw_reply_test() ->
    %% Verify that raw_reply sanitizes extra headers containing CRLF
    Req0 = #{pid => self(), streamid => 2002},
    _Req1 = riak_admin_api_response:raw_reply(
        200, <<"body">>, Req0,
        #{request_id => <<"rid-ok">>},
        #{<<"location">> => <<"/buckets/evil\r\nX-Injected: yes/keys/k">>}),
    {_Status, Headers, _Body} = receive_response_for_stream(2002),
    Location = maps:get(<<"location">>, Headers),
    ?assertEqual(nomatch, binary:match(Location, <<"\r">>)),
    ?assertEqual(nomatch, binary:match(Location, <<"\n">>)).

receive_response_for_stream(StreamID) ->
    riak_admin_api_test_helpers:receive_response_for_stream(StreamID).
