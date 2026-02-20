%% @doc Per-node stats handler. GET /api/nodes/:node/stats
-module(rah_nodes).
-behaviour(cowboy_handler).
-export([init/2]).

%% @doc Fetch VM and riak_kv stats for `:node`.
%% Returns 404 if the node name is unknown, 503 if unreachable.
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    case riak_admin_api_handler:ensure_admin_get(Req0) of
        {ok, Req1} ->
            Req = handle_request(Req1),
            {ok, Req, State};
        {error, Req} ->
            {ok, Req, State}
    end.

%% -- private ----------------------------------------------------------------

handle_request(Req) ->
    case cowboy_req:binding(node, Req) of
        undefined ->
            riak_admin_api_handler:error_reply(400,
                <<"missing_parameter">>,
                <<"Missing required path parameter: node">>, Req);
        NodeBin ->
            fetch_stats(NodeBin, Req)
    end.

fetch_stats(NodeBin, Req) ->
    try binary_to_existing_atom(NodeBin, utf8) of
        Node ->
            case riak_admin_api_riak:node_stats(Node) of
                {ok, Data} ->
                    riak_admin_api_handler:json_reply(200, Data, Req);
                {error, {unreachable, _}} ->
                    riak_admin_api_handler:error_reply(503,
                        <<"node_unreachable">>,
                        <<"Node is unreachable">>, Req);
                {error, Reason} ->
                    logger:warning("[riak_admin] node_stats error: ~p",
                                   [Reason]),
                    riak_admin_api_handler:error_reply(500,
                        <<"backend_error">>,
                        <<"Failed to retrieve node stats">>, Req)
            end
    catch
        error:badarg ->
            riak_admin_api_handler:error_reply(404,
                <<"unknown_node">>,
                <<"Node name not recognised: ", NodeBin/binary>>, Req)
    end.
