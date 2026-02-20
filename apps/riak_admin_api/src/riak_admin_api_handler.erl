%% @doc Cowboy HTTP handler for the Riak Admin API.
%%
%% Implements the cowboy_handler behaviour. Incoming requests pass through
%% riak_admin_api_request for normalization and security enforcement, then
%% dispatch to operation-specific handlers based on the `op' field of the
%% normalized context. Each handler validates the HTTP method and delegates
%% to the appropriate backend (object or bucket) for execution.
%%
%% Related modules:
%%   riak_admin_api_request  — request normalization and security
%%   riak_admin_api_response — response formatting and CORS
%%   riak_admin_api_riak     — default backend implementations

-module(riak_admin_api_handler).
-behaviour(cowboy_handler).

-export([init/2, json_reply/3, error_reply/4, ensure_get/1, ensure_admin_get/1,
         normalize_request/2]).

%% @doc Cowboy handler entry point. Normalizes the request, checks security,
%% and dispatches to the appropriate operation handler.
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, RouteOpts) ->
    case cowboy_req:method(Req0) of
        <<"OPTIONS">> ->
            Opts = request_opts(RouteOpts),
            ReplyOpts0 = req_response_opts(Req0),
            Headers = case Req0 of
                #{headers := H} when is_map(H) -> H;
                _ -> #{}
            end,
            ReplyOpts = ReplyOpts0#{
                trusted_origins => maps:get(trusted_origins, Opts, []),
                request_origin => maps:get(<<"origin">>, Headers, undefined)
            },
            Req1 = riak_admin_api_response:raw_reply(204, <<>>, Req0, ReplyOpts, #{}),
            {ok, Req1, RouteOpts};
        _ ->
            Opts = request_opts(RouteOpts),
            case normalize_request(Req0, Opts) of
                {ok, Context, Req1} ->
                    %% S5 (M-4): Thread trusted_origins into reply opts for CORS
                    CorsExtra = #{trusted_origins =>
                        maps:get(trusted_origins, Opts, [])},
                    ReplyOpts = response_opts(Context, CorsExtra),
                    Req2 = dispatch(Context, Req1, Opts, ReplyOpts),
                    {ok, Req2, RouteOpts};
                {error, Error, Req1} ->
                    Req2 = riak_admin_api_response:reply_error_map(Error, Req1),
                    {ok, Req2, RouteOpts}
            end
    end.

%% @doc Send a JSON response with standard headers and CORS.
-spec json_reply(non_neg_integer(), jsx:json_term(), cowboy_req:req()) ->
    cowboy_req:req().
json_reply(StatusCode, Data, Req) ->
    riak_admin_api_response:json_reply(StatusCode, Data, Req, req_response_opts(Req)).

%% @doc Send an error response with standard headers and CORS.
-spec error_reply(non_neg_integer(), binary(), term(), cowboy_req:req()) ->
    cowboy_req:req().
error_reply(StatusCode, Error, Reason, Req) ->
    riak_admin_api_response:error_reply(
        StatusCode, Error, Reason, Req, req_response_opts(Req)).

%% @doc Ensure the request uses GET; returns 405 otherwise.
-spec ensure_get(cowboy_req:req()) ->
    {ok, cowboy_req:req()} | {error, cowboy_req:req()}.
ensure_get(Req) ->
    case request_method(Req) of
        <<"GET">> ->
            {ok, Req};
        Method ->
            Opts = (req_response_opts(Req))#{allow => [<<"GET">>]},
            Req1 = riak_admin_api_response:error_reply(
                405,
                <<"method_not_allowed">>,
                <<"Unsupported HTTP method: ", Method/binary>>,
                Req,
                Opts),
            {error, Req1}
    end.

%% @doc Method + security check for admin handlers (rah_* modules).
%% Enforces GET-only, then runs the same TLS/authn/authz pipeline as the
%% main handler so that admin endpoints respect security configuration.
%%
%% The security Context includes `route' and `op => admin' so that auth
%% hooks can make endpoint-level authorization decisions (e.g., allow
%% /api/ping but deny /api/cluster/status).
-spec ensure_admin_get(cowboy_req:req()) ->
    {ok, cowboy_req:req()} | {error, cowboy_req:req()}.
ensure_admin_get(Req) ->
    case ensure_get(Req) of
        {ok, Req1} ->
            Opts = request_opts(#{}),
            Headers = case Req1 of
                #{headers := H} when is_map(H) -> H;
                _ -> #{}
            end,
            Route = admin_route(Req1),
            {ok, HeaderMeta} = riak_admin_api_request:normalize_headers(Headers),
            RequestId = maps:get(request_id, HeaderMeta),
            NormHeaders = maps:remove(request_id, HeaderMeta),
            Context = #{
                method => <<"GET">>,
                headers => NormHeaders,
                route => Route,
                op => admin
            },
            case riak_admin_api_request:ensure_security(Context, Opts) of
                ok ->
                    {ok, Req1};
                {error, Error} ->
                    Req2 = riak_admin_api_response:reply_error_map(
                        Error#{request_id => RequestId}, Req1),
                    {error, Req2}
            end;
        Error ->
            Error
    end.

%% @doc Delegate to riak_admin_api_request:normalize/2.
-spec normalize_request(cowboy_req:req(), map()) ->
    {ok, map(), cowboy_req:req()} | {error, map(), cowboy_req:req()}.
normalize_request(Req, Opts) ->
    riak_admin_api_request:normalize(Req, Opts).

%%====================================================================
%% Dispatch
%%====================================================================

dispatch(Context, Req, Opts, ReplyOpts) ->
    case maps:get(op, Context, undefined) of
        bucket_props ->
            handle_bucket_props(Context, Req, Opts, ReplyOpts);
        bucket_type_props ->
            handle_bucket_type_props(Context, Req, Opts, ReplyOpts);
        buckets ->
            handle_bucket_listing(Context, Req, Opts, ReplyOpts);
        keys ->
            handle_keys(Context, Req, Opts, ReplyOpts);
        counter ->
            handle_counter(Context, Req, Opts, ReplyOpts);
        crdt_item ->
            handle_crdt_item(Context, Req, Opts, ReplyOpts);
        crdt_collection ->
            handle_crdt_collection(Context, Req, Opts, ReplyOpts);
        query ->
            handle_query(Context, Req, Opts, ReplyOpts);
        index_query ->
            handle_index_query(Context, Req, Opts, ReplyOpts);
        mapred ->
            handle_mapred(Context, Req, Opts, ReplyOpts);
        object_item ->
            handle_object_item(Context, Req, Opts, ReplyOpts);
        object_collection ->
            handle_object_collection(Context, Req, Opts, ReplyOpts);
        _ ->
            riak_admin_api_response:error_reply(
                501,
                <<"not_implemented">>,
                <<"Cowboy substrate route is wired; operation is deferred to a later batch">>,
                Req,
                ReplyOpts)
    end.

%%====================================================================
%% Operation handlers
%%====================================================================

handle_bucket_props(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    Input0 = base_backend_input(Context),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            execute_bucket_backend(get_bucket_props, Context, Input0, Req, Opts, ReplyOpts);
        <<"PUT">> ->
            with_props_body(
                Req,
                fun(Body, Props, Req1) ->
                    execute_bucket_backend(
                        set_bucket_props, Context,
                        Input0#{body => Body, props => Props},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        <<"DELETE">> ->
            execute_bucket_backend(delete_bucket_props, Context, Input0, Req, Opts, ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"DELETE">>], Req, ReplyOpts)
    end.

handle_bucket_type_props(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    Input0 = base_backend_input(Context),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            execute_bucket_backend(get_bucket_type_props, Context, Input0, Req, Opts, ReplyOpts);
        <<"PUT">> ->
            with_props_body(
                Req,
                fun(Body, Props, Req1) ->
                    execute_bucket_backend(
                        set_bucket_type_props, Context,
                        Input0#{body => Body, props => Props},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>, <<"PUT">>], Req, ReplyOpts)
    end.

handle_bucket_listing(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            execute_bucket_backend(
                list_buckets, Context, base_backend_input(Context),
                Req, Opts, ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>], Req, ReplyOpts)
    end.

handle_keys(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            execute_bucket_backend(
                list_keys, Context, base_backend_input(Context),
                Req, Opts, ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>], Req, ReplyOpts)
    end.

handle_counter(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(
                counter_get, Context, base_backend_input(Context),
                Req, Opts, ReplyOpts);
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_bucket_backend(
                        counter_update, Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"POST">>], Req, ReplyOpts)
    end.

handle_crdt_item(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            execute_bucket_backend(
                crdt_fetch, Context, base_backend_input(Context),
                Req, Opts, ReplyOpts);
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_bucket_backend(
                        crdt_update, Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>, <<"POST">>], Req, ReplyOpts)
    end.

handle_crdt_collection(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_bucket_backend(
                        crdt_create, Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method, [<<"POST">>], Req, ReplyOpts)
    end.

handle_index_query(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            execute_bucket_backend(
                index_query, Context, base_backend_input(Context),
                Req, Opts, ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>], Req, ReplyOpts)
    end.

handle_query(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"POST">> ->
            with_json_body(
                Req,
                fun(Body, JsonBody, Req1) ->
                    execute_bucket_backend(
                        query, Context,
                        (base_backend_input(Context))#{
                            body => Body, json => JsonBody},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method, [<<"POST">>], Req, ReplyOpts)
    end.

handle_mapred(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            reply_object(
                Context, Req,
                #{status => 200,
                  body => mapred_usage(),
                  content_type => <<"text/plain; charset=utf-8">>},
                ReplyOpts);
        <<"POST">> ->
            with_json_body(
                Req,
                fun(Body, JsonBody, Req1) ->
                    execute_bucket_backend(
                        mapred, Context,
                        (base_backend_input(Context))#{
                            body => Body, json => JsonBody},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>, <<"POST">>], Req, ReplyOpts)
    end.

handle_object_item(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    Input0 = base_backend_input(Context),
    case Method of
        M when M =:= <<"GET">>; M =:= <<"HEAD">> ->
            execute_backend(get, Context, Input0, Req, Opts, ReplyOpts);
        <<"DELETE">> ->
            execute_backend(delete, Context, Input0, Req, Opts, ReplyOpts);
        <<"PUT">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_backend(
                        put, Context, Input0#{body => Body},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_backend(
                        post, Context, Input0#{body => Body},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method,
                [<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"POST">>, <<"DELETE">>],
                Req, ReplyOpts)
    end.

handle_object_collection(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_backend(
                        create, Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1, Opts, ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            reply_method_not_allowed(Method, [<<"POST">>], Req, ReplyOpts)
    end.

%%====================================================================
%% Backend execution
%%====================================================================

execute_backend(Action, Context, Input, Req, Opts, ReplyOpts) ->
    Backend = resolve_backend(object_backend,
        fun riak_admin_api_riak:object_operation/3, Opts),
    case run_backend(object, Backend, Action, Context, Input) of
        {ok, Reply} when is_map(Reply) ->
            reply_object(Context, Req, Reply, ReplyOpts);
        Result ->
            reply_backend_error(Result, Context, Req, ReplyOpts)
    end.

execute_bucket_backend(Action, Context, Input, Req, Opts, ReplyOpts) ->
    Backend = resolve_backend(bucket_backend,
        fun riak_admin_api_riak:bucket_operation/3, Opts),
    case run_backend(bucket, Backend, Action, Context, Input) of
        {ok, Reply} when is_map(Reply) ->
            reply_object(Context, Req, Reply, ReplyOpts);
        {stream, StreamInit, ChunkFun} ->
            case maps:get(method, Context) of
                <<"HEAD">> ->
                    reply_object(Context, Req, #{
                        status => maps:get(status, StreamInit, 200),
                        body => <<>>,
                        content_type => maps:get(content_type, StreamInit, undefined),
                        headers => maps:get(headers, StreamInit, #{})
                    }, ReplyOpts);
                _ ->
                    reply_stream(Context, Req, StreamInit, ChunkFun, ReplyOpts)
            end;
        Result ->
            reply_backend_error(Result, Context, Req, ReplyOpts)
    end.

resolve_backend(Key, Default, Opts) ->
    case maps:get(Key, Opts, undefined) of
        Backend when is_function(Backend, 3) -> Backend;
        _ -> Default
    end.

run_backend(Label, Backend, Action, Context, Input) ->
    try Backend(Action, Context, Input)
    catch
        Class:Reason:Stack ->
            logger:error(
                "[riak_admin] ~s backend crashed (~p): ~p:~p~n~p",
                [Label, Action, Class, Reason, Stack]),
            {error, #{
                status => 500,
                code => <<"backend_error">>,
                reason => <<"Internal server error">>
            }}
    end.

reply_backend_error({error, Error}, Context, Req, ReplyOpts) when is_map(Error) ->
    riak_admin_api_response:reply_error_map(
        with_error_context(Error, Context, ReplyOpts), Req);
reply_backend_error({error, Reason}, Context, Req, ReplyOpts) ->
    logger:warning("[riak_admin] non-map backend error: ~p", [Reason]),
    riak_admin_api_response:reply_error_map(
        with_error_context(
            #{status => 500,
              code => <<"backend_error">>,
              reason => <<"Internal server error">>},
            Context, ReplyOpts), Req);
reply_backend_error(Other, Context, Req, ReplyOpts) ->
    logger:warning("[riak_admin] unexpected backend reply: ~p", [Other]),
    riak_admin_api_response:reply_error_map(
        with_error_context(
            #{status => 500,
              code => <<"backend_error">>,
              reason => <<"Internal server error">>},
            Context, ReplyOpts), Req).

%%====================================================================
%% Response helpers
%%====================================================================

%% S2 (CG-001): Handle streaming responses from the backend.
%% The backend returns {stream, StreamInit, ChunkFun} where:
%%   - StreamInit is a map with status, content_type, and optional headers
%%   - ChunkFun is fun(EmitFun) -> ok, where EmitFun is fun(Data, fin|nofin)
reply_stream(_Context, Req, StreamInit, ChunkFun, BaseReplyOpts) ->
    Status = maps:get(status, StreamInit, 200),
    ReplyOpts = maps:merge(BaseReplyOpts, maps:get(reply_opts, StreamInit, #{})),
    Headers0 = maybe_put_content_type(
        maps:get(content_type, StreamInit, undefined),
        maps:get(headers, StreamInit, #{})),
    Req1 = riak_admin_api_response:stream_reply_init(
        Status, Req, ReplyOpts, Headers0),
    Emit = fun(Data, IsFin) ->
        riak_admin_api_response:stream_reply_body(Data, IsFin, Req1)
    end,
    try
        ChunkFun(Emit),
        Req1
    catch
        Class:Reason:Stack ->
            logger:error(
                "[riak_admin] stream emission failed: ~p:~p~n~p",
                [Class, Reason, Stack]),
            ErrorJson = jsx:encode(#{
                error => <<"stream_error">>,
                reason => <<"Internal server error">>
            }),
            catch riak_admin_api_response:stream_reply_body(
                ErrorJson, fin, Req1),
            Req1
    end.

reply_object(Context, Req, Reply, BaseReplyOpts) ->
    Status = maps:get(status, Reply, 200),
    Method = maps:get(method, Context, <<"GET">>),
    Body0 = maps:get(body, Reply, <<>>),
    Body = case Method of
        <<"HEAD">> -> <<>>;
        _ -> Body0
    end,
    ReplyOpts = maps:merge(BaseReplyOpts, maps:get(reply_opts, Reply, #{})),
    Headers0 = maybe_put_content_type(maps:get(content_type, Reply, undefined),
        maps:get(headers, Reply, #{})),
    riak_admin_api_response:raw_reply(Status, Body, Req, ReplyOpts, Headers0).

reply_method_not_allowed(Method, Allowed, Req, ReplyOpts) ->
    riak_admin_api_response:reply_error_map(
        with_request_id(
            #{status => 405,
              code => <<"method_not_allowed">>,
              reason => <<"Unsupported HTTP method: ", Method/binary>>,
              allow => Allowed},
            ReplyOpts),
        Req).

%%====================================================================
%% Request body reading
%%====================================================================

with_request_body(Req, HandlerFun, ReplyOpts) ->
    case read_request_body(Req) of
        {ok, Body, Req1} ->
            HandlerFun(Body, Req1);
        {error, body_too_large, Req1} ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{status => 413,
                      code => <<"payload_too_large">>,
                      reason => iolist_to_binary(io_lib:format(
                          "Request body exceeds maximum allowed size (~B bytes)",
                          [max_body_bytes()]))},
                    ReplyOpts),
                Req1);
        {error, Reason, Req1} ->
            logger:warning("[riak_admin] body read error: ~p", [Reason]),
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{status => 400,
                      code => <<"invalid_body">>,
                      reason => <<"Failed to read request body">>},
                    ReplyOpts),
                Req1)
    end.

with_props_body(Req, HandlerFun, ReplyOpts) ->
    with_request_body(
        Req,
        fun(Body, Req1) ->
            case decode_props_body(Body) of
                {ok, Props} ->
                    HandlerFun(Body, Props, Req1);
                {error, Reason} ->
                    riak_admin_api_response:reply_error_map(
                        with_request_id(
                            #{status => 400,
                              code => <<"invalid_body">>,
                              reason => Reason},
                            ReplyOpts),
                        Req1)
            end
        end,
        ReplyOpts).

with_json_body(Req, HandlerFun, ReplyOpts) ->
    with_request_body(
        Req,
        fun(Body, Req1) ->
            case decode_json_object(Body) of
                {ok, JsonBody} ->
                    HandlerFun(Body, JsonBody, Req1);
                {error, Reason} ->
                    riak_admin_api_response:reply_error_map(
                        with_request_id(
                            #{status => 400,
                              code => <<"invalid_body">>,
                              reason => Reason},
                            ReplyOpts),
                        Req1)
            end
        end,
        ReplyOpts).

decode_props_body(Body) ->
    case catch mochijson2:decode(Body) of
        {struct, Fields} ->
            case proplists:get_value(<<"props">>, Fields) of
                {struct, Props} when is_list(Props) ->
                    {ok, Props};
                _ ->
                    {error, <<"Body must be JSON: {\"props\": {...}}">>}
            end;
        _ ->
            {error, <<"Body must be JSON: {\"props\": {...}}">>}
    end.

decode_json_object(Body) ->
    try jsx:decode(Body, [return_maps]) of
        Json when is_map(Json) ->
            {ok, Json};
        _ ->
            {error, <<"Body must be a JSON object">>}
    catch
        _:_ ->
            {error, <<"Body must be a JSON object">>}
    end.

%% Body size enforcement: the #{body := Body} fast path (used in tests and
%% for pre-read bodies) enforces the same max_request_body_bytes limit as
%% the chunked Cowboy read path.
read_request_body(Req = #{body := undefined}) ->
    {ok, <<>>, Req};
read_request_body(Req = #{body := Body}) when is_binary(Body) ->
    check_body_size(Body, Req);
read_request_body(Req = #{body := Body}) when is_list(Body) ->
    check_body_size(iolist_to_binary(Body), Req);
read_request_body(Req0) ->
    try read_request_body_chunks(Req0, [], 0, max_body_bytes())
    catch
        throw:{body_too_large, ReqFinal} ->
            {error, body_too_large, ReqFinal};
        Class:Reason ->
            {error, {Class, Reason}, Req0}
    end.

check_body_size(Body, Req) ->
    case byte_size(Body) > max_body_bytes() of
        true -> {error, body_too_large, Req};
        false -> {ok, Body, Req}
    end.

max_body_bytes() ->
    application:get_env(riak_admin_api, max_request_body_bytes, 5 * 1024 * 1024).

read_request_body_chunks(Req0, Acc, AccSize, MaxBody) ->
    case cowboy_req:read_body(Req0) of
        {ok, Body, Req1} ->
            NewSize = AccSize + byte_size(Body),
            case NewSize > MaxBody of
                true -> throw({body_too_large, Req1});
                false -> {ok, iolist_to_binary(lists:reverse([Body | Acc])), Req1}
            end;
        {more, Body, Req1} ->
            NewSize = AccSize + byte_size(Body),
            case NewSize > MaxBody of
                true -> throw({body_too_large, Req1});
                false -> read_request_body_chunks(Req1, [Body | Acc], NewSize, MaxBody)
            end
    end.

%%====================================================================
%% Internal helpers
%%====================================================================

base_backend_input(Context) ->
    #{
        method => maps:get(method, Context, <<"GET">>),
        query => maps:get(query, Context, #{}),
        headers => maps:get(headers, Context, #{}),
        route => maps:get(route, Context, <<"">>)
    }.

maybe_put_content_type(undefined, Headers) ->
    Headers;
maybe_put_content_type(<<>>, Headers) ->
    Headers;
maybe_put_content_type(ContentType, Headers) ->
    case maps:is_key(<<"content-type">>, Headers) of
        true -> Headers;
        false -> Headers#{<<"content-type">> => ContentType}
    end.

with_request_id(Error, ReplyOpts) ->
    case maps:is_key(request_id, Error) of
        true -> Error;
        false -> Error#{request_id => maps:get(request_id, ReplyOpts, <<"unknown">>)}
    end.

with_error_context(Error0, Context, ReplyOpts) ->
    Error1 = with_request_id(Error0, ReplyOpts),
    case maps:is_key(telemetry_context, Error1) of
        true ->
            Error1;
        false ->
            Error1#{
                telemetry_context => #{
                    route => maps:get(route, Context, <<"unknown">>),
                    op => maps:get(op, Context, undefined),
                    alias => maps:get(alias, Context, undefined),
                    error_code => maps:get(code, Error1, <<"internal_error">>)
                }
            }
    end.

request_opts(RouteOpts) ->
    RouteMap = case RouteOpts of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    %% S1: require_auth passthrough for auth guardrails
    Defaults = #{
        require_tls => application:get_env(riak_admin_api, security_require_tls, false),
        trust_proxy_headers => application:get_env(riak_admin_api, security_trust_proxy_headers, false),
        trusted_origins => application:get_env(riak_admin_api, security_trusted_origins, []),
        require_auth => application:get_env(riak_admin_api, security_require_auth, false),
        authn_fun => application:get_env(riak_admin_api, authn_hook, undefined),
        authz_fun => application:get_env(riak_admin_api, authz_hook, undefined),
        cutover_default_mode => application:get_env(riak_admin_api, cowboy_cutover_default_mode, disabled),
        cutover_op_modes => application:get_env(riak_admin_api, cowboy_cutover_op_modes, [])
    },
    maps:merge(Defaults, RouteMap).

req_response_opts(Req) ->
    Headers = case Req of
        #{headers := H} when is_map(H) -> H;
        _ -> #{}
    end,
    case riak_admin_api_request:normalize_headers(Headers) of
        {ok, HeaderInfo} ->
            #{request_id => maps:get(request_id, HeaderInfo)};
        {error, _} ->
            #{request_id => <<"unknown">>}
    end.

response_opts(Context, Extra) ->
    Headers = maps:get(headers, Context, #{}),
    maps:merge(
        #{
            request_id => maps:get(request_id, Context, <<"unknown">>),
            telemetry_context => Context,
            %% S5 (M-4): Pass origin through for CORS response headers
            request_origin => maps:get(<<"origin">>, Headers, undefined)
        },
        Extra).

request_method(#{method := Method}) when is_binary(Method) -> Method;
request_method(Req) -> cowboy_req:method(Req).

%% @doc Extract the request path from a Cowboy request for admin handlers.
%% Used by ensure_admin_get to include route information in the security
%% context so auth hooks can make endpoint-level decisions.
admin_route(#{path := Path}) when is_binary(Path) -> Path;
admin_route(Req) ->
    try cowboy_req:path(Req)
    catch _:_ -> <<"unknown">>
    end.

mapred_usage() ->
    <<"This resource accepts POSTs with bodies containing JSON of the form:\n"
      "{\n"
      " \"inputs\":[...list of inputs...],\n"
      " \"query\":[...list of map/reduce phases...]\n"
      "}\n">>.
