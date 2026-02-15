%% @doc Active Anti-Entropy (AAE) status handler for the Riak Admin API.
%%
%% Serves GET /api/aae/status and returns information about AAE
%% exchanges — the background process that detects and repairs
%% data inconsistencies between replicas:
%% - exchanges: list of exchange entries
%% - count: number of exchange entries
%%
%% ```
%% $ curl http://127.0.0.1:8099/api/aae/status
%% {"exchanges":[...],"count":42}
%% '''
%%
%% == Isolation ==
%%
%% Calls riak_admin_api_riak:aae_status/0 exclusively.

-module(rah_aae).
-export([init/2]).

%% @doc Cowboy handler callback — returns AAE exchange information.
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_riak:aae_status() of
        {ok, Exchanges} ->
            Req = riak_admin_api_handler:json_reply(200,
                #{exchanges => Exchanges,
                  count => length(Exchanges)}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = riak_admin_api_handler:error_reply(500,
                <<"backend_error">>,
                iolist_to_binary(io_lib:format("~p", [Reason])),
                Req0),
            {ok, Req, State}
    end.
