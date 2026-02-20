%% @doc Per-node stats handler. GET /api/nodes/:node/stats
%%
%% Returns Erlang VM stats and riak_kv stats for the given node.
%% For remote nodes, the gateway uses rpc:call/4.
-module(rah_nodes).
-behaviour(cowboy_handler).
-export([init/2]).

-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_handler:ensure_admin_get(Req0) of
        {ok, Req1} ->
            NodeBin = cowboy_req:binding(node, Req1),
            try binary_to_existing_atom(NodeBin, utf8) of
                Node ->
                    case riak_admin_api_riak:node_stats(Node) of
                        {ok, Data} ->
                            Req = riak_admin_api_handler:json_reply(200, Data, Req1),
                            {ok, Req, State};
                        {error, {unreachable, _} = Reason} ->
                            Req = riak_admin_api_handler:error_reply(503,
                                <<"node_unreachable">>, Reason, Req1),
                            {ok, Req, State};
                        {error, Reason} ->
                            Req = riak_admin_api_handler:error_reply(500,
                                <<"backend_error">>, Reason, Req1),
                            {ok, Req, State}
                    end
            catch
                error:badarg ->
                    Req = riak_admin_api_handler:error_reply(404,
                        <<"unknown_node">>,
                        <<"Node name not recognised: ", NodeBin/binary>>, Req1),
                    {ok, Req, State}
            end;
        {error, Req} ->
            {ok, Req, State}
    end.
