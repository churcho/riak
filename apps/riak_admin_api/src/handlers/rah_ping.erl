%% @doc Health-check handler. GET /api/ping
-module(rah_ping).
-behaviour(cowboy_handler).
-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_handler:ensure_admin_get(Req0) of
        {ok, Req1} ->
            Req = riak_admin_api_handler:json_reply(200,
                #{status => <<"ok">>, node => node()}, Req1),
            {ok, Req, State};
        {error, Req} ->
            {ok, Req, State}
    end.
