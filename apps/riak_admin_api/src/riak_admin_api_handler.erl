%% @doc Shared Cowboy substrate handler and response helpers.

-module(riak_admin_api_handler).
-behaviour(cowboy_handler).

-export([init/2, json_reply/3, error_reply/4, ensure_get/1, normalize_request/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, RouteOpts) ->
    Opts = request_opts(RouteOpts),
    case normalize_request(Req0, Opts) of
        {ok, Context, Req1} ->
            ReplyOpts = response_opts(Context, #{}),
            Req2 = dispatch(Context, Req1, Opts, ReplyOpts),
            {ok, Req2, RouteOpts};
        {error, Error, Req1} ->
            Req2 = riak_admin_api_response:reply_error_map(Error, Req1),
            {ok, Req2, RouteOpts}
    end.

-spec json_reply(non_neg_integer(), jsx:json_term(), cowboy_req:req()) ->
    cowboy_req:req().
json_reply(StatusCode, Data, Req) ->
    riak_admin_api_response:json_reply(StatusCode, Data, Req, req_response_opts(Req)).

-spec error_reply(non_neg_integer(), binary(), term(), cowboy_req:req()) ->
    cowboy_req:req().
error_reply(StatusCode, Error, Reason, Req) ->
    riak_admin_api_response:error_reply(
        StatusCode,
        Error,
        Reason,
        Req,
        req_response_opts(Req)).

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
                iolist_to_binary(io_lib:format("Unsupported HTTP method: ~p", [Method])),
                Req,
                Opts),
            {error, Req1}
    end.

-spec normalize_request(cowboy_req:req(), map()) ->
    {ok, map(), cowboy_req:req()} | {error, map(), cowboy_req:req()}.
normalize_request(Req, Opts) ->
    riak_admin_api_request:normalize(Req, Opts).

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

handle_bucket_props(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    Input0 = base_backend_input(Context),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(get_bucket_props, Context, Input0, Req, Opts, ReplyOpts);
        <<"HEAD">> ->
            execute_bucket_backend(get_bucket_props, Context, Input0, Req, Opts, ReplyOpts);
        <<"PUT">> ->
            with_props_body(
                Req,
                fun(Body, Props, Req1) ->
                    execute_bucket_backend(
                        set_bucket_props,
                        Context,
                        Input0#{
                            body => Body,
                            props => Props
                        },
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        <<"DELETE">> ->
            execute_bucket_backend(delete_bucket_props, Context, Input0, Req, Opts, ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"DELETE">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_bucket_type_props(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    Input0 = base_backend_input(Context),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(get_bucket_type_props, Context, Input0, Req, Opts, ReplyOpts);
        <<"HEAD">> ->
            execute_bucket_backend(get_bucket_type_props, Context, Input0, Req, Opts, ReplyOpts);
        <<"PUT">> ->
            with_props_body(
                Req,
                fun(Body, Props, Req1) ->
                    execute_bucket_backend(
                        set_bucket_type_props,
                        Context,
                        Input0#{
                            body => Body,
                            props => Props
                        },
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>, <<"PUT">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_bucket_listing(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(
                list_buckets,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        <<"HEAD">> ->
            execute_bucket_backend(
                list_buckets,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_keys(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(
                list_keys,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        <<"HEAD">> ->
            execute_bucket_backend(
                list_keys,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_counter(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(
                counter_get,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_bucket_backend(
                        counter_update,
                        Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"POST">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_crdt_item(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(
                crdt_fetch,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        <<"HEAD">> ->
            execute_bucket_backend(
                crdt_fetch,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_bucket_backend(
                        crdt_update,
                        Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>, <<"POST">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_crdt_collection(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_bucket_backend(
                        crdt_create,
                        Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"POST">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_index_query(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"GET">> ->
            execute_bucket_backend(
                index_query,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        <<"HEAD">> ->
            execute_bucket_backend(
                index_query,
                Context,
                base_backend_input(Context),
                Req,
                Opts,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_query(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"POST">> ->
            with_json_body(
                Req,
                fun(Body, JsonBody, Req1) ->
                    execute_bucket_backend(
                        query,
                        Context,
                        (base_backend_input(Context))#{
                            body => Body,
                            json => JsonBody
                        },
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"POST">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_mapred(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"GET">> ->
            reply_object(
                Context,
                Req,
                #{
                    status => 200,
                    body => mapred_usage(),
                    content_type => <<"text/plain; charset=utf-8">>
                },
                ReplyOpts);
        <<"HEAD">> ->
            reply_object(
                Context,
                Req,
                #{
                    status => 200,
                    body => mapred_usage(),
                    content_type => <<"text/plain; charset=utf-8">>
                },
                ReplyOpts);
        <<"POST">> ->
            with_json_body(
                Req,
                fun(Body, JsonBody, Req1) ->
                    execute_bucket_backend(
                        mapred,
                        Context,
                        (base_backend_input(Context))#{
                            body => Body,
                            json => JsonBody
                        },
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>, <<"POST">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_object_item(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    Input0 = base_backend_input(Context),
    case Method of
        <<"GET">> ->
            execute_backend(get, Context, Input0, Req, Opts, ReplyOpts);
        <<"HEAD">> ->
            execute_backend(get, Context, Input0, Req, Opts, ReplyOpts);
        <<"DELETE">> ->
            execute_backend(delete, Context, Input0, Req, Opts, ReplyOpts);
        <<"PUT">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_backend(
                        put,
                        Context,
                        Input0#{body => Body},
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_backend(
                        post,
                        Context,
                        Input0#{body => Body},
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"POST">>, <<"DELETE">>]
                    },
                    ReplyOpts),
                Req)
    end.

handle_object_collection(Context, Req, Opts, ReplyOpts) ->
    Method = maps:get(method, Context, <<"GET">>),
    case Method of
        <<"POST">> ->
            with_request_body(
                Req,
                fun(Body, Req1) ->
                    execute_backend(
                        create,
                        Context,
                        (base_backend_input(Context))#{body => Body},
                        Req1,
                        Opts,
                        ReplyOpts)
                end,
                ReplyOpts);
        _ ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 405,
                        code => <<"method_not_allowed">>,
                        reason => iolist_to_binary(
                            io_lib:format("Unsupported HTTP method: ~p", [Method])),
                        allow => [<<"POST">>]
                    },
                    ReplyOpts),
                Req)
    end.

execute_backend(Action, Context, Input, Req, Opts, ReplyOpts) ->
    Backend = object_backend(Opts),
    case run_backend(Backend, Action, Context, Input) of
        {ok, Reply} when is_map(Reply) ->
            reply_object(Context, Req, Reply, ReplyOpts);
        {error, Error} when is_map(Error) ->
            riak_admin_api_response:reply_error_map(
                with_error_context(Error, Context, ReplyOpts),
                Req);
        {error, Reason} ->
            riak_admin_api_response:reply_error_map(
                with_error_context(
                    #{
                        status => 500,
                        code => <<"backend_error">>,
                        reason => iolist_to_binary(io_lib:format("~p", [Reason]))
                    },
                    Context,
                    ReplyOpts),
                Req);
        Other ->
            riak_admin_api_response:reply_error_map(
                with_error_context(
                    #{
                        status => 500,
                        code => <<"backend_error">>,
                        reason => iolist_to_binary(io_lib:format(
                            "Unexpected backend reply: ~p", [Other]))
                    },
                    Context,
                    ReplyOpts),
                Req)
    end.

execute_bucket_backend(Action, Context, Input, Req, Opts, ReplyOpts) ->
    Backend = bucket_backend(Opts),
    case run_bucket_backend(Backend, Action, Context, Input) of
        {ok, Reply} when is_map(Reply) ->
            reply_object(Context, Req, Reply, ReplyOpts);
        {error, Error} when is_map(Error) ->
            riak_admin_api_response:reply_error_map(
                with_error_context(Error, Context, ReplyOpts),
                Req);
        {error, Reason} ->
            riak_admin_api_response:reply_error_map(
                with_error_context(
                    #{
                        status => 500,
                        code => <<"backend_error">>,
                        reason => iolist_to_binary(io_lib:format("~p", [Reason]))
                    },
                    Context,
                    ReplyOpts),
                Req);
        Other ->
            riak_admin_api_response:reply_error_map(
                with_error_context(
                    #{
                        status => 500,
                        code => <<"backend_error">>,
                        reason => iolist_to_binary(io_lib:format(
                            "Unexpected backend reply: ~p", [Other]))
                    },
                    Context,
                    ReplyOpts),
                Req)
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

with_request_body(Req, HandlerFun, ReplyOpts) ->
    case read_request_body(Req) of
        {ok, Body, Req1} ->
            HandlerFun(Body, Req1);
        {error, body_too_large, Req1} ->
            MaxBody = application:get_env(riak_admin_api,
                                           max_request_body_bytes,
                                           5 * 1024 * 1024),
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 413,
                        code => <<"payload_too_large">>,
                        reason => iolist_to_binary(io_lib:format(
                            "Request body exceeds maximum allowed size (~B bytes)",
                            [MaxBody]))
                    },
                    ReplyOpts),
                Req1);
        {error, Reason, Req1} ->
            riak_admin_api_response:reply_error_map(
                with_request_id(
                    #{
                        status => 400,
                        code => <<"invalid_body">>,
                        reason => iolist_to_binary(io_lib:format("~p", [Reason]))
                    },
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
                            #{
                                status => 400,
                                code => <<"invalid_body">>,
                                reason => Reason
                            },
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
                            #{
                                status => 400,
                                code => <<"invalid_body">>,
                                reason => Reason
                            },
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

read_request_body(Req = #{body := Body}) when is_binary(Body) ->
    {ok, Body, Req};
read_request_body(Req = #{body := Body}) when is_list(Body) ->
    {ok, iolist_to_binary(Body), Req};
read_request_body(Req = #{body := undefined}) ->
    {ok, <<>>, Req};
read_request_body(Req0) ->
    MaxBody = application:get_env(riak_admin_api, max_request_body_bytes,
                                   5 * 1024 * 1024), %% 5 MiB default
    try read_request_body_chunks(Req0, [], 0, MaxBody)
    catch
        throw:body_too_large ->
            {error, body_too_large, Req0};
        Class:Reason ->
            {error, {Class, Reason}, Req0}
    end.

read_request_body_chunks(Req0, Acc, AccSize, MaxBody) ->
    case cowboy_req:read_body(Req0) of
        {ok, Body, Req1} ->
            NewSize = AccSize + byte_size(Body),
            case NewSize > MaxBody of
                true -> throw(body_too_large);
                false -> {ok, iolist_to_binary(lists:reverse([Body | Acc])), Req1}
            end;
        {more, Body, Req1} ->
            NewSize = AccSize + byte_size(Body),
            case NewSize > MaxBody of
                true -> throw(body_too_large);
                false -> read_request_body_chunks(Req1, [Body | Acc], NewSize, MaxBody)
            end
    end.

base_backend_input(Context) ->
    #{
        method => maps:get(method, Context, <<"GET">>),
        query => maps:get(query, Context, #{}),
        headers => maps:get(headers, Context, #{}),
        route => maps:get(route, Context, <<"">>)
    }.

object_backend(Opts) ->
    case maps:get(object_backend, Opts, undefined) of
        Backend when is_function(Backend, 3) ->
            Backend;
        _ ->
            fun riak_admin_api_riak:object_operation/3
    end.

bucket_backend(Opts) ->
    case maps:get(bucket_backend, Opts, undefined) of
        Backend when is_function(Backend, 3) ->
            Backend;
        _ ->
            fun riak_admin_api_riak:bucket_operation/3
    end.

run_backend(Backend, Action, Context, Input) ->
    try Backend(Action, Context, Input)
    catch
        Class:Reason:Stack ->
            logger:error(
                "[riak_admin] object backend crashed (~p): ~p:~p~n~p",
                [Action, Class, Reason, Stack]),
            {error, #{
                status => 500,
                code => <<"backend_error">>,
                reason => iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))
            }}
    end.

run_bucket_backend(Backend, Action, Context, Input) ->
    try Backend(Action, Context, Input)
    catch
        Class:Reason:Stack ->
            logger:error(
                "[riak_admin] bucket backend crashed (~p): ~p:~p~n~p",
                [Action, Class, Reason, Stack]),
            {error, #{
                status => 500,
                code => <<"backend_error">>,
                reason => iolist_to_binary(io_lib:format("~p:~p", [Class, Reason]))
            }}
    end.

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
    DefaultRequireTLS = application:get_env(riak_admin_api, security_require_tls, false),
    DefaultTrustProxyHeaders = application:get_env(
        riak_admin_api,
        security_trust_proxy_headers,
        false),
    DefaultTrustedOrigins = application:get_env(
        riak_admin_api,
        security_trusted_origins,
        []),
    DefaultCutoverMode = application:get_env(
        riak_admin_api,
        cowboy_cutover_default_mode,
        enabled),
    DefaultCutoverOpModes = application:get_env(
        riak_admin_api,
        cowboy_cutover_op_modes,
        []),
    RouteMap#{
        require_tls => maps:get(require_tls, RouteMap, DefaultRequireTLS),
        trust_proxy_headers => maps:get(trust_proxy_headers, RouteMap, DefaultTrustProxyHeaders),
        trusted_origins => maps:get(trusted_origins, RouteMap, DefaultTrustedOrigins),
        cutover_default_mode => maps:get(
            cutover_default_mode,
            RouteMap,
            DefaultCutoverMode),
        cutover_op_modes => maps:get(
            cutover_op_modes,
            RouteMap,
            DefaultCutoverOpModes)
    }.

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
    maps:merge(
        #{
            request_id => maps:get(request_id, Context, <<"unknown">>),
            telemetry_context => Context
        },
        Extra).

request_method(#{method := Method}) when is_binary(Method) -> Method;
request_method(Req) -> cowboy_req:method(Req).

mapred_usage() ->
    <<"This resource accepts POSTs with bodies containing JSON of the form:\n"
      "{\n"
      " \"inputs\":[...list of inputs...],\n"
      " \"query\":[...list of map/reduce phases...]\n"
      "}\n">>.
