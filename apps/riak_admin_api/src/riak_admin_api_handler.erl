%% @doc Shared HTTP response helpers for all admin API handlers.
%%
%% Centralises Content-Type headers, JSON encoding, and error
%% response shape so handlers stay thin.

-module(riak_admin_api_handler).
-export([json_reply/3, error_reply/4, ensure_get/1]).

-define(JSON_CONTENT_TYPE, <<"application/json; charset=utf-8">>).

%% @doc Send a JSON response with the given status code.
-spec json_reply(non_neg_integer(), jsx:json_term(), cowboy_req:req()) ->
     cowboy_req:req().
json_reply(StatusCode, Data, Req) ->
    try
        Body = jsx:encode(Data),
        cowboy_req:reply(StatusCode,
            #{<<"content-type">> => ?JSON_CONTENT_TYPE},
            Body, Req)
    catch
        Class:Reason:Stack ->
            logger:error(
                "[riak_admin] Failed to encode JSON response: ~p:~p ~n~p",
                [Class, Reason, Stack]),
            FallbackBody = jsx:encode(#{
                error => <<"json_encoding_error">>,
                reason => format_reason({Class, Reason})
            }),
            cowboy_req:reply(500,
                #{<<"content-type">> => ?JSON_CONTENT_TYPE},
                FallbackBody, Req)
    end.

%% @doc Ensure handler requests are GET.
-spec ensure_get(cowboy_req:req()) ->
    {ok, cowboy_req:req()} | {error, cowboy_req:req()}.
ensure_get(Req) ->
    case cowboy_req:method(Req) of
        <<"GET">> -> {ok, Req};
        Method -> {error, method_not_allowed_reply(Method, Req)}
    end.

%% @private Return a 405 response and advertise allowed methods.
-spec method_not_allowed_reply(binary(), cowboy_req:req()) -> cowboy_req:req().
method_not_allowed_reply(Method, Req) ->
    Body = jsx:encode(#{
        error => <<"method_not_allowed">>,
        reason => iolist_to_binary(io_lib:format("Unsupported HTTP method: ~p", [Method]))
    }),
    cowboy_req:reply(405,
        #{<<"content-type">> => ?JSON_CONTENT_TYPE,
          <<"allow">> => <<"GET">>},
        Body, Req).

%% @doc Send a JSON error response: `{"error": "...", "reason": "..."}'.
%% Reason can be a binary or any term (terms are formatted via ~p).
-spec error_reply(non_neg_integer(), binary(), term(), cowboy_req:req()) ->
     cowboy_req:req().
error_reply(StatusCode, Error, Reason, Req) ->
    json_reply(StatusCode,
        #{error => Error, reason => format_reason(Reason)}, Req).

%% @private
-spec format_reason(term()) -> binary().
format_reason(Bin) when is_binary(Bin) -> Bin;
format_reason(Term) -> iolist_to_binary(io_lib:format("~p", [Term])).
