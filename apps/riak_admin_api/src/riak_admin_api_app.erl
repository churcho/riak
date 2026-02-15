%% @doc OTP application callback module for riak_admin_api.
%%
%% This module bootstraps the Cowboy HTTP server that powers the Riak
%% Admin REST API. It is called automatically by OTP when the
%% riak_admin_api application starts (as declared by the `mod' key in
%% riak_admin_api.app.src).
%%
%% == Why a new HTTP server? ==
%%
%% Riak's existing HTTP interface runs on Webmachine/Mochiweb and
%% serves the data-path API (bucket/key operations) on port 10018.
%% The admin API uses Cowboy on a dedicated port (default 8099) as
%% the foundation for eventually replacing the legacy Webmachine
%% stack. In the interim, Cowboy runs alongside Webmachine so that:
%%
%% <ul>
%%   <li>New endpoints are built on Cowboy from the start; existing
%%       Webmachine endpoints continue to work unchanged.</li>
%%   <li>Admin traffic is isolated from data traffic — a misbehaving
%%       admin query cannot starve KV read/write operations.</li>
%%   <li>Operators can apply different firewall rules to the admin
%%       port (e.g., restrict to internal networks only).</li>
%%   <li>Cowboy provides a modern, well-maintained HTTP/1.1 and
%%       HTTP/2 stack with native WebSocket support.</li>
%% </ul>
%%
%% == Startup sequence ==
%%
%% 1. Read the configured HTTP port from application env
%%    (default 8099).
%% 2. Compile Cowboy dispatch rules from routes/0.
%% 3. Start a Cowboy "clear" (non-TLS) listener named
%%    `riak_admin_http'.
%% 4. Start the application's supervisor tree.
%%
%% == Route organisation ==
%%
%% All routes are defined in routes/0 in one place. Handlers are
%% added as milestones progress. Each handler calls the gateway
%% module (riak_admin_api_riak) rather than Riak internals directly.

-module(riak_admin_api_app).
-behaviour(application).

-export([start/2, stop/1]).

-ifdef(TEST).
-export([routes/0]).
-endif.

%% @doc Start the admin API HTTP server and supervisor tree.
start(_StartType, _StartArgs) ->
    Port = resolve_port(),

    Dispatch = cowboy_router:compile([
        {'_', routes()}
    ]),

    case cowboy:start_clear(
            riak_admin_http,
            [{port, Port}],
            #{env => #{dispatch => Dispatch}}) of
        {ok, _Pid} ->
            logger:info("riak_admin_api started on port ~B", [Port]),
            riak_admin_api_sup:start_link();
        {error, Reason} ->
            logger:error(
                "riak_admin_api failed to start on port ~B: ~p",
                [Port, Reason]),
            {error, Reason}
    end.

%% @doc Stop the admin API HTTP server.
stop(_State) ->
    cowboy:stop_listener(riak_admin_http),
    ok.

%% @doc Resolve the HTTP port for this node.
%%
%% In a devrel, each node is named devN@127.0.0.1 (N = 1..8).
%% Other Riak listeners follow the 100N_ pattern:
%%   - HTTP:     100N8 (dev1=10018, dev2=10028, ...)
%%   - Protobuf: 100N7 (dev1=10017, dev2=10027, ...)
%%
%% The admin API uses 100N5 to avoid collisions:
%%   - dev1=10015, dev2=10025, dev3=10035, ...
%%
%% Existing devrel port assignments per node (N = 1..8):
%%   100N6 = cluster_manager
%%   100N7 = protobuf
%%   100N8 = HTTP (webmachine)
%%   100N9 = handoff
%%
%% In production (single node, non-devN name), the configured
%% default (8099) is used.
resolve_port() ->
    Default = application:get_env(riak_admin_api, http_port, 8099),
    case node() of
        nonode@nohost ->
            Default;
        Node ->
            NodeStr = atom_to_list(Node),
            case re:run(NodeStr, "^dev([0-9]+)@", [{capture, [1], list}]) of
                {match, [NStr]} ->
                    N = list_to_integer(NStr),
                    10000 + N * 10 + 5;
                nomatch ->
                    Default
            end
    end.

%% @doc All API routes in one place.
%%
%% Each route maps a URL path to a handler module. Handlers are
%% added as milestones progress. Path segments prefixed with `:'
%% become bindings accessible via cowboy_req:binding/2.
%%
%% Handler naming: all handlers use the `rah_' prefix (Riak Admin
%% Handler) to keep dispatch rules concise and avoid collisions
%% with Riak's existing modules.
routes() ->
    [
        {"/api/ping",              rah_ping, []},
        {"/api/cluster/status",    rah_cluster, []},
        {"/api/ring/ownership",    rah_ring, []},
        {"/api/nodes/:node/stats", rah_nodes, []},
        {"/api/handoff/status",    rah_handoff, []},
        {"/api/aae/status",        rah_aae, []}
        %% M3: {"/api/dcs",                       rah_dcs, []}
        %% M7: {"/api/kv/:type/:bucket/:key",     rah_kv, []}
        %% M7: {"/api/bucket-types",              rah_bucket_types, []}
        %% M8: {"/api/stream/events",             rah_events_ws, []}
    ].
