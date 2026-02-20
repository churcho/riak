%% @doc Ring ownership handler. GET /api/ring/ownership
-module(rah_ring).
-behaviour(cowboy_handler).
-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_handler:ensure_admin_get(Req0) of
        {ok, Req1} ->
            case riak_admin_api_riak:ring_ownership() of
                {ok, Data} ->
                    Req = riak_admin_api_handler:json_reply(200, Data, Req1),
                    {ok, Req, State};
                {error, Reason} ->
                    Req = riak_admin_api_handler:error_reply(500,
                        <<"backend_error">>, Reason, Req1),
                    {ok, Req, State}
            end;
        {error, Req} ->
            {ok, Req, State}
    end.
