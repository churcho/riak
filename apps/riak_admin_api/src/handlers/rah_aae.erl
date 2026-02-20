%% @doc AAE status handler. GET /api/aae/status
-module(rah_aae).
-behaviour(cowboy_handler).
-export([init/2]).

%% @doc Returns active anti-entropy exchange list with count.
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_handler:ensure_admin_get(Req0) of
        {ok, Req1} ->
            case riak_admin_api_riak:aae_status() of
                {ok, Exchanges} ->
                    Req = riak_admin_api_handler:json_reply(200,
                        #{exchanges => Exchanges, count => length(Exchanges)}, Req1),
                    {ok, Req, State};
                {error, Reason} ->
                    logger:warning("[riak_admin] aae_status error: ~p",
                                   [Reason]),
                    Req = riak_admin_api_handler:error_reply(500,
                        <<"backend_error">>,
                        <<"Failed to retrieve AAE status">>, Req1),
                    {ok, Req, State}
            end;
        {error, Req} ->
            {ok, Req, State}
    end.
