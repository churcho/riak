%% @doc Cluster status handler for the Riak Admin API.
%%
%% Serves GET /api/cluster/status and returns a JSON object with:
%% - cluster_name: the ring's cluster name
%% - ring_size: number of partitions (e.g., 64)
%% - claimant: the node responsible for ring changes
%% - nodes: list of members with status, ring_pct, reachability
%% - pending_changes: any queued ring transitions
%% - ready: boolean indicating whether the ring is stable
%%
%% ```
%% $ curl http://127.0.0.1:8099/api/cluster/status
%% {"cluster_name":"default","ring_size":64,"claimant":"dev1@127.0.0.1",...}
%% '''
%%
%% == Isolation ==
%%
%% This handler does NOT call riak_core directly. It calls
%% riak_admin_api_riak:cluster_status/0 (the gateway module)
%% which is the only module allowed to touch Riak internals.

-module(rah_cluster).
-export([init/2]).

%% @doc Cowboy handler callback — returns cluster membership and health.
init(Req0, State) ->
    case riak_admin_api_riak:cluster_status() of
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
