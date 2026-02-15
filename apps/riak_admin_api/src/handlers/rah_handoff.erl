%% @doc Handoff status handler for the Riak Admin API.
%%
%% Serves GET /api/handoff/status and returns the list of active
%% handoff transfers in the cluster:
%% - active_transfers: list of transfer entries
%% - count: number of active transfers
%%
%% ```
%% $ curl http://127.0.0.1:8099/api/handoff/status
%% {"active_transfers":[],"count":0}
%% '''
%%
%% During normal operation with a stable ring, this will usually
%% return an empty list. Active transfers appear when nodes are
%% joining, leaving, or recovering.
%%
%% == Isolation ==
%%
%% Calls riak_admin_api_riak:handoff_status/0 exclusively.

-module(rah_handoff).
-export([init/2]).

%% @doc Cowboy handler callback — returns active handoff transfers.
init(Req0, State) ->
    case riak_admin_api_riak:handoff_status() of
        {ok, Transfers} ->
            Req = riak_admin_api_handler:json_reply(200,
                #{active_transfers => Transfers,
                  count => length(Transfers)}, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = riak_admin_api_handler:error_reply(500,
                <<"backend_error">>,
                iolist_to_binary(io_lib:format("~p", [Reason])),
                Req0),
            {ok, Req, State}
    end.
