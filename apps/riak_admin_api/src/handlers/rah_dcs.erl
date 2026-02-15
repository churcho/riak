%%%-------------------------------------------------------------------
%%% @doc
%%% Handler for GET /api/dcs.
%%%
%%% Returns all known datacenters discovered via syn.
%%% Each DC entry includes admin API URL, Riak URL, and
%%% whether it's the local DC.
%%%
%%% ```
%%% $ curl http://127.0.0.1:8099/api/dcs
%%% {"dcs":[{"name":"default","local":true,...}],"count":1}
%%% '''
%%%
%%% == Isolation ==
%%%
%%% Calls riak_admin_api_riak:list_dcs/0 exclusively.
%%% @end
%%%-------------------------------------------------------------------
-module(rah_dcs).

-export([init/2]).

%% @doc Handles GET /api/dcs requests.
-spec init(cowboy_req:req(), term()) ->
    {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_riak:list_dcs() of
        {ok, DCs} ->
            Req = riak_admin_api_handler:json_reply(200,
                #{dcs => DCs, count => length(DCs)}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = riak_admin_api_handler:error_reply(500,
                <<"dc_discovery_error">>,
                iolist_to_binary(io_lib:format("~p", [Reason])),
                Req0),
            {ok, Req, State}
    end.
