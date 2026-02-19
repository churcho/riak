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
            Req2 = riak_admin_api_response:error_reply(
                501,
                <<"not_implemented">>,
                <<"Cowboy substrate route is wired; data-path behavior starts in B02">>,
                Req1,
                ReplyOpts),
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

request_opts(RouteOpts) ->
    RouteMap = case RouteOpts of
        M when is_map(M) -> M;
        _ -> #{}
    end,
    DefaultRequireTLS = application:get_env(riak_admin_api, security_require_tls, false),
    DefaultTrustedOrigins = application:get_env(
        riak_admin_api,
        security_trusted_origins,
        []),
    RouteMap#{
        require_tls => maps:get(require_tls, RouteMap, DefaultRequireTLS),
        trusted_origins => maps:get(trusted_origins, RouteMap, DefaultTrustedOrigins)
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
