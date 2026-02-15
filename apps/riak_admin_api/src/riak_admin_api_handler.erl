%% @doc Shared HTTP response helpers for all admin API handlers.
%%
%% Every handler in riak_admin_api uses this module instead of
%% calling cowboy_req:reply/4 and jsx:encode/1 directly. This
%% centralises:
%%
%% <ul>
%%   <li>Content-Type headers (always application/json)</li>
%%   <li>JSON encoding (jsx:encode/1)</li>
%%   <li>Error response shape (consistent {error, reason} JSON)</li>
%% </ul>
%%
%% == Usage in handlers ==
%%
%% ```
%% init(Req0, State) ->
%%     case riak_admin_api_riak:some_call() of
%%         {ok, Data} ->
%%             Req = riak_admin_api_handler:json_reply(200, Data, Req0),
%%             {ok, Req, State};
%%         {error, Reason} ->
%%             Req = riak_admin_api_handler:error_reply(500,
%%                 <<"backend_error">>, format(Reason), Req0),
%%             {ok, Req, State}
%%     end.
%% '''

-module(riak_admin_api_handler).
-export([json_reply/3, error_reply/4]).

%% @doc Send a JSON success response.
%%
%% Encodes `Data' (an Erlang map or list) as JSON and replies with
%% the given HTTP status code and application/json content type.
json_reply(StatusCode, Data, Req) ->
    Body = jsx:encode(Data),
    cowboy_req:reply(StatusCode,
        #{<<"content-type">> => <<"application/json">>},
        Body, Req).

%% @doc Send a JSON error response with a consistent shape.
%%
%% Always returns `{"error": "...", "reason": "..."}` so clients
%% can reliably parse error responses regardless of which endpoint
%% produced them.
error_reply(StatusCode, Error, Reason, Req) ->
    json_reply(StatusCode,
        #{error => Error, reason => Reason}, Req).
