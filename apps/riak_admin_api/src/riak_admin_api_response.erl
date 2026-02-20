%% @doc Shared response serializer with compatibility headers.

-module(riak_admin_api_response).

-export([
    json_reply/4,
    raw_reply/5,
    error_reply/5,
    reply_error_map/2,
    error_payload/4,
    compat_headers/1,
    telemetry_tags/3,
    %% S2 (CG-001): Incremental streaming helpers
    stream_reply_init/4,
    stream_reply_body/3
]).

-define(JSON_CONTENT_TYPE, <<"application/json; charset=utf-8">>).

-spec json_reply(non_neg_integer(), jsx:json_term(), cowboy_req:req(), map()) ->
    cowboy_req:req().
json_reply(StatusCode, Data, Req, Opts) ->
    Headers0 = compat_headers(Opts),
    Headers = Headers0#{<<"content-type">> => ?JSON_CONTENT_TYPE},
    StartUs = maps:get(start_time_us, Opts, erlang:monotonic_time(microsecond)),
    try
        Body = jsx:encode(Data),
        Req1 = cowboy_req:reply(StatusCode, Headers, Body, Req),
        maybe_log_telemetry(Opts, StatusCode, StartUs),
        Req1
    catch
        Class:Reason:Stack ->
            logger:error("[riak_admin] response encode failed: ~p:~p~n~p",
                         [Class, Reason, Stack]),
            RequestId = maps:get(request_id, Opts, <<"unknown">>),
            Fallback = error_payload(500, <<"json_encoding_error">>,
                format_reason({Class, Reason}), RequestId),
            cowboy_req:reply(500, Headers, jsx:encode(Fallback), Req)
    end.

-spec raw_reply(non_neg_integer(), iodata(), cowboy_req:req(), map(), map()) ->
    cowboy_req:req().
raw_reply(StatusCode, Body, Req, Opts, ExtraHeaders) ->
    StartUs = maps:get(start_time_us, Opts, erlang:monotonic_time(microsecond)),
    Headers = maps:merge(compat_headers(Opts), ExtraHeaders),
    Req1 = cowboy_req:reply(StatusCode, Headers, Body, Req),
    maybe_log_telemetry(Opts, StatusCode, StartUs),
    Req1.

-spec error_reply(non_neg_integer(), binary(), term(), cowboy_req:req(), map()) ->
    cowboy_req:req().
error_reply(StatusCode, ErrorCode, Reason, Req, Opts) ->
    RequestId = maps:get(request_id, Opts, <<"unknown">>),
    Payload = case maps:find(details, Opts) of
        {ok, Details} ->
            (error_payload(StatusCode, ErrorCode, Reason, RequestId))#{
                details => Details
            };
        error ->
            error_payload(StatusCode, ErrorCode, Reason, RequestId)
    end,
    json_reply(StatusCode, Payload, Req, Opts).

-spec reply_error_map(map(), cowboy_req:req()) -> cowboy_req:req().
reply_error_map(Error, Req) ->
    Status = maps:get(status, Error, 500),
    Code = maps:get(code, Error, <<"internal_error">>),
    Reason = maps:get(reason, Error, <<"Internal server error">>),
    TelemetryContext = maps:get(telemetry_context, Error, #{
        route => maps:get(route, Error, <<"unknown">>),
        op => maps:get(op, Error, undefined),
        alias => maps:get(alias, Error, undefined),
        error_code => Code
    }),
    Opts0 = #{
        request_id => maps:get(request_id, Error, <<"unknown">>),
        telemetry_context => TelemetryContext
    },
    Opts1 = case maps:find(allow, Error) of
        {ok, Allow} -> Opts0#{allow => Allow};
        error -> Opts0
    end,
    Opts2 = maybe_put_opt(vclock, Error, Opts1),
    Opts3 = maybe_put_opt(etag, Error, Opts2),
    Opts4 = maybe_put_opt(last_modified, Error, Opts3),
    Opts = maybe_put_opt(link, Error, Opts4),
    error_reply(Status, Code, Reason, Req, Opts).

-spec error_payload(non_neg_integer(), binary(), term(), binary()) -> map().
error_payload(StatusCode, ErrorCode, Reason, RequestId) ->
    #{
        status => StatusCode,
        error => ErrorCode,
        reason => format_reason(Reason),
        request_id => RequestId
    }.

-spec compat_headers(map()) -> map().
compat_headers(Opts) ->
    Headers0 = maybe_put(<<"x-request-id">>, maps:get(request_id, Opts, undefined), #{}),
    Headers1 = maybe_put(<<"x-riak-vclock">>, maps:get(vclock, Opts, undefined), Headers0),
    Headers2 = maybe_put(<<"etag">>, maps:get(etag, Opts, undefined), Headers1),
    Headers3 = maybe_put(<<"last-modified">>, maps:get(last_modified, Opts, undefined), Headers2),
    Headers4 = maybe_put(<<"link">>, maps:get(link, Opts, undefined), Headers3),
    maybe_put_allow(maps:get(allow, Opts, undefined), Headers4).

-spec telemetry_tags(map(), non_neg_integer(), non_neg_integer()) -> map().
telemetry_tags(Context, Status, DurationUs) ->
    #{
        route => maps:get(route, Context, <<"unknown">>),
        op => maps:get(op, Context, undefined),
        alias => maps:get(alias, Context, undefined),
        error_code => maps:get(error_code, Context, undefined),
        status => Status,
        duration_us => DurationUs
    }.

%% @doc Start a chunked/streaming HTTP response.
%%
%% S2 (CG-001): Wraps cowboy_req:stream_reply/3 for incremental
%% streaming of large response bodies (key lists, index results,
%% mapreduce chunks). The caller must follow up with stream_reply_body/3
%% calls and a final `fin' chunk.
-spec stream_reply_init(non_neg_integer(), cowboy_req:req(), map(), map()) ->
    cowboy_req:req().
stream_reply_init(StatusCode, Req, Opts, ExtraHeaders) ->
    Headers = maps:merge(compat_headers(Opts), ExtraHeaders),
    cowboy_req:stream_reply(StatusCode, Headers, Req).

%% @doc Send a chunk of data in an active streaming response.
%%
%% S2 (CG-001): Wraps cowboy_req:stream_body/3. IsFin must be
%% `fin' for the last chunk and `nofin' for intermediate chunks.
-spec stream_reply_body(iodata(), fin | nofin, cowboy_req:req()) -> ok.
stream_reply_body(Data, IsFin, Req) ->
    cowboy_req:stream_body(Data, IsFin, Req).

maybe_log_telemetry(Opts, StatusCode, StartUs) ->
    case maps:get(telemetry_context, Opts, undefined) of
        undefined ->
            ok;
        Context ->
            DurationUs = erlang:monotonic_time(microsecond) - StartUs,
            Tags = telemetry_tags(Context, StatusCode, DurationUs),
            logger:debug("[riak_admin] substrate_telemetry=~p", [Tags])
    end.

maybe_put(_Key, undefined, Headers) -> Headers;
maybe_put(_Key, <<>>, Headers) -> Headers;
maybe_put(Key, Value, Headers) -> Headers#{Key => to_binary(Value)}.

maybe_put_allow(undefined, Headers) -> Headers;
maybe_put_allow([], Headers) -> Headers;
maybe_put_allow(Allow, Headers) when is_list(Allow) ->
    AllowBin = iolist_to_binary(lists:join(<<", ">>, [to_binary(M) || M <- Allow])),
    Headers#{<<"allow">> => AllowBin};
maybe_put_allow(Allow, Headers) ->
    Headers#{<<"allow">> => to_binary(Allow)}.

maybe_put_opt(Key, Source, Target) ->
    case maps:find(Key, Source) of
        {ok, Value} -> Target#{Key => Value};
        error -> Target
    end.

format_reason(Bin) when is_binary(Bin) -> Bin;
format_reason(Term) -> iolist_to_binary(io_lib:format("~p", [Term])).

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) when is_list(Value) -> list_to_binary(Value);
to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
