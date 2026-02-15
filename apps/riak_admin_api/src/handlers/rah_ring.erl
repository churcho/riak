%% @doc Ring ownership handler for the Riak Admin API.
%%
%% Serves GET /api/ring/ownership and returns the full
%% partition-to-node mapping of the consistent hash ring:
%% - num_partitions: total partition count (e.g., 64)
%% - partitions: list of {index, hash, node} entries
%% - node_colors: map of node -> integer for visualisation
%%
%% ```
%% $ curl http://127.0.0.1:8099/api/ring/ownership
%% {"num_partitions":64,"partitions":[{"index":0,"hash":0,"node":"dev1@127.0.0.1"},...]}
%% '''
%%
%% == Isolation ==
%%
%% Calls riak_admin_api_riak:ring_ownership/0 exclusively.
%% No direct references to riak_core modules.

-module(rah_ring).
-export([init/2]).

%% @doc Cowboy handler callback — returns partition-to-node mapping.
init(Req0, State) ->
    case riak_admin_api_riak:ring_ownership() of
        {ok, Data} ->
            Req = riak_admin_api_handler:json_reply(200, Data, Req0),
            {ok, Req, State};
        {error, Reason} ->
            Req = riak_admin_api_handler:error_reply(500,
                <<"backend_error">>,
                iolist_to_binary(io_lib:format("~p", [Reason])),
                Req0),
            {ok, Req, State}
    end.
