%% @doc Health-check handler. GET /api/ping
-module(rah_ping).
-behaviour(cowboy_handler).
-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req = riak_admin_api_handler:json_reply(200,
        #{status => <<"ok">>, node => node()}, Req0),
    {ok, Req, State}.
