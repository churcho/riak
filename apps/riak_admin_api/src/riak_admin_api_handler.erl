%% @doc Shared HTTP response helpers for all admin API handlers.
%%
%% Centralises Content-Type headers, JSON encoding, and error
%% response shape so handlers stay thin.

-module(riak_admin_api_handler).
-export([json_reply/3, error_reply/4]).

%% @doc Send a JSON response with the given status code.
-spec json_reply(non_neg_integer(), jsx:json_term(), cowboy_req:req()) ->
    cowboy_req:req().
json_reply(StatusCode, Data, Req) ->
    Body = jsx:encode(Data),
    cowboy_req:reply(StatusCode,
        #{<<"content-type">> => <<"application/json">>},
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
