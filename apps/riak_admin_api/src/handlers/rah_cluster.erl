%% @doc Cluster status handler. GET /api/cluster/status
-module(rah_cluster).
-behaviour(cowboy_handler).
-export([init/2]).

%% @doc Returns cluster membership and status information.
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_handler:ensure_admin_get(Req0) of
        {ok, Req1} ->
            case riak_admin_api_riak:cluster_status() of
                {ok, Data} ->
                    Req = riak_admin_api_handler:json_reply(200, Data, Req1),
                    {ok, Req, State};
                {error, Reason} ->
                    logger:warning("[riak_admin] cluster_status error: ~p",
                                   [Reason]),
                    Req = riak_admin_api_handler:error_reply(500,
                        <<"backend_error">>,
                        <<"Failed to retrieve cluster status">>, Req1),
                    {ok, Req, State}
            end;
        {error, Req} ->
            {ok, Req, State}
    end.
