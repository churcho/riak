%% @doc DC discovery handler. GET /api/dcs
-module(rah_dcs).
-behaviour(cowboy_handler).
-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_handler:ensure_admin_get(Req0) of
        {ok, Req1} ->
            case riak_admin_api_riak:list_dcs() of
                {ok, DCs} ->
                    Req = riak_admin_api_handler:json_reply(200,
                        #{dcs => DCs, count => length(DCs)}, Req1),
                    {ok, Req, State};
                {error, Reason} ->
                    Req = riak_admin_api_handler:error_reply(500,
                        <<"dc_discovery_error">>, Reason, Req1),
                    {ok, Req, State}
            end;
        {error, Req} ->
            {ok, Req, State}
    end.
