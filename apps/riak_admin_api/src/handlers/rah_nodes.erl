%% @doc Per-node stats handler for the Riak Admin API.
%%
%% Serves GET /api/nodes/:node/stats where :node is an Erlang
%% node name like "dev1@127.0.0.1". Returns Erlang VM stats
%% (memory, process count, run queue) and riak_kv stats (vnode
%% gets/puts, FSM latencies, read repairs).
%%
%% ```
%% $ curl http://127.0.0.1:8099/api/nodes/dev1@127.0.0.1/stats
%% {"node":"dev1@127.0.0.1","erlang":{...},"kv":{...}}
%% '''
%%
%% For the local node, stats are collected directly. For remote
%% nodes, the gateway uses rpc:call/4 to invoke
%% collect_local_stats/0 on the target node.
%%
%% == Error codes ==
%%
%% - 200: stats returned successfully
%% - 503: target node is unreachable (rpc:call returned badrpc)
%% - 500: unexpected error
%%
%% == Isolation ==
%%
%% Calls riak_admin_api_riak:node_stats/1 exclusively.

-module(rah_nodes).
-export([init/2]).

%% @doc Cowboy handler callback — returns stats for the requested node.
init(Req0, State) ->
    NodeBin = cowboy_req:binding(node, Req0),
    try binary_to_existing_atom(NodeBin, utf8) of
        Node ->
            case riak_admin_api_riak:node_stats(Node) of
                {ok, Data} ->
                    Req = riak_admin_api_handler:json_reply(200, Data, Req0),
                    {ok, Req, State};
                {error, {unreachable, _} = Reason} ->
                    Req = riak_admin_api_handler:error_reply(503,
                        <<"node_unreachable">>,
                        iolist_to_binary(io_lib:format("~p", [Reason])),
                        Req0),
                    {ok, Req, State};
                {error, Reason} ->
                    Req = riak_admin_api_handler:error_reply(500,
                        <<"backend_error">>,
                        iolist_to_binary(io_lib:format("~p", [Reason])),
                        Req0),
                    {ok, Req, State}
            end
    catch
        error:badarg ->
            Req = riak_admin_api_handler:error_reply(404,
                <<"unknown_node">>,
                <<"Node name not recognised: ", NodeBin/binary>>,
                Req0),
            {ok, Req, State}
    end.
