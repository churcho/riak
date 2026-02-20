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
-export([routes/0, listener_child_spec/2, protocol_opts/0]).
-endif.

%% @doc Start the admin API HTTP server and supervisor tree.
%%
%% Startup sequence (S1 revised):
%% 1. Configure syn event handler (must happen before scope init)
%% 2. Initialize syn scope (creates local ETS tables)
%% 3. Resolve HTTP port and build listener child spec
%% 4. Start supervisor tree (listener + coordinator under supervision)
%%
%% S1 change: The Cowboy listener is now started under the supervisor
%% tree via cowboy:start_clear/3 in the supervisor init, rather than
%% outside the tree. If the listener crashes, the supervisor restarts
%% it automatically — previously a listener crash left the admin API
%% silently unavailable (CG-017).
-spec start(term(), term()) ->
    {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    %% Configure syn event handler before initializing scope.
    %% Must happen before syn:add_node_to_scopes/1.
    application:set_env(syn, event_handler, riak_admin_event_handler),

    %% Initialize syn scope. Creates local ETS tables for the
    %% riak_admin scope. Must complete before coordinator starts.
    syn:add_node_to_scopes([riak_admin]),

    Port = resolve_port(),
    RiakHttpPort = resolve_riak_http_port(),

    %% Write the resolved ports back to application env so that
    %% riak_admin_api_coordinator reads the actual listener ports
    %% (not the defaults) in devrel. Without this, syn metadata
    %% advertises the wrong ports.
    application:set_env(riak_admin_api, http_port, Port),
    application:set_env(riak_admin_api, riak_http_port, RiakHttpPort),

    Dispatch = cowboy_router:compile([
        {'_', routes()}
    ]),

    %% S1: Build listener child spec for supervised startup.
    ListenerSpec = listener_child_spec(Port, Dispatch),

    case riak_admin_api_sup:start_link(ListenerSpec) of
        {ok, SupPid} ->
            logger:info("[riak_admin] API started on port ~B (supervised)", [Port]),
            audit_security_posture(),
            {ok, SupPid};
        {error, Reason} ->
            logger:error(
                "[riak_admin] API failed to start on port ~B: ~p",
                [Port, Reason]),
            {error, Reason}
    end.

%% @doc Stop the admin API HTTP server.
%%
%% S1: The listener is now supervised, so stopping the supervisor
%% tree will stop it. We call cowboy:stop_listener as a safety net.
-spec stop(term()) -> ok.
stop(_State) ->
    cowboy:stop_listener(riak_admin_http),
    ok.

%% @doc Build a Cowboy listener child spec for supervised startup.
%%
%% S1 (CG-017): Uses ranch:child_spec/5 to produce a spec suitable
%% for inclusion in the supervisor tree. Protocol options include
%% explicit timeouts and limits to prevent resource exhaustion.
-spec listener_child_spec(pos_integer(), cowboy_router:dispatch_rules()) ->
    supervisor:child_spec().
listener_child_spec(Port, Dispatch) ->
    ProtocolOpts = protocol_opts(),
    Env = #{env => #{dispatch => Dispatch}},
    ProtoOptsWithEnv = maps:merge(ProtocolOpts, Env),
    MaxConns = application:get_env(
        riak_admin_api, cowboy_max_connections, 1024),
    ranch:child_spec(
        riak_admin_http,
        ranch_tcp,
        [{port, Port}, {max_connections, MaxConns}],
        cowboy_clear,
        ProtoOptsWithEnv).

%% @doc Protocol options for the Cowboy listener.
%%
%% S1: Explicit timeouts and limits prevent resource exhaustion from
%% slow/malicious clients. All values are configurable via application
%% env with safe defaults.
%%
%% | Key | Default | Description |
%% |-----|---------|-------------|
%% | idle_timeout | 60000 ms | Close idle keep-alive connections after 60s |
%% | request_timeout | 30000 ms | Max time to receive a complete request |
%% | max_keepalive | 100 | Max requests per connection |
%% | max_header_name_length | 64 | Reject headers with names > 64 bytes |
%% | max_header_value_length | 4096 | Reject headers with values > 4096 bytes |
%% | max_headers | 100 | Max number of headers per request |
-spec protocol_opts() -> map().
protocol_opts() ->
    #{
        idle_timeout => application:get_env(
            riak_admin_api, cowboy_idle_timeout, 60000),
        request_timeout => application:get_env(
            riak_admin_api, cowboy_request_timeout, 30000),
        max_keepalive => application:get_env(
            riak_admin_api, cowboy_max_keepalive, 100),
        max_header_name_length => application:get_env(
            riak_admin_api, cowboy_max_header_name_length, 64),
        max_header_value_length => application:get_env(
            riak_admin_api, cowboy_max_header_value_length, 4096),
        max_headers => application:get_env(
            riak_admin_api, cowboy_max_headers, 100)
    }.

%% @doc Log security posture warnings on startup.
%%
%% Checks authentication, authorization, and TLS configuration and
%% emits appropriate log warnings when the API is running in an
%% insecure configuration. Does not block startup — provides
%% operational visibility into the security posture.
-spec audit_security_posture() -> ok.
audit_security_posture() ->
    RequireAuth = application:get_env(
        riak_admin_api, security_require_auth, false),
    AuthnHook = application:get_env(
        riak_admin_api, authn_hook, undefined),
    AuthzHook = application:get_env(
        riak_admin_api, authz_hook, undefined),
    RequireTls = application:get_env(
        riak_admin_api, security_require_tls, false),

    HasAuthn = AuthnHook =/= undefined,
    HasAuthz = AuthzHook =/= undefined,

    case {RequireAuth, HasAuthn, HasAuthz} of
        {false, false, false} ->
            logger:warning("[riak_admin] SECURITY: API started with NO "
                           "authentication or authorization. All endpoints "
                           "are publicly accessible. Set "
                           "security_require_auth=true and configure "
                           "authn_hook/authz_hook for production.");
        {false, true, false} ->
            logger:warning("[riak_admin] SECURITY: authn_hook is configured "
                           "but authz_hook is not. All authenticated users "
                           "will have unrestricted access. Configure "
                           "authz_hook for authorization enforcement.");
        {false, false, true} ->
            logger:warning("[riak_admin] SECURITY: authz_hook is configured "
                           "but authn_hook is not. Authorization will run "
                           "without an authenticated identity. Configure "
                           "authn_hook for proper authentication.");
        _ ->
            ok
    end,

    case RequireTls of
        false ->
            logger:info("[riak_admin] TLS is not required. Set "
                        "security_require_tls=true for encrypted transport.");
        _ ->
            ok
    end,
    ok.

%% @doc Resolve the admin API HTTP port for this node.
%% Admin API uses 100N5 (dev1=10015, dev2=10025, ...).
-spec resolve_port() -> pos_integer().
resolve_port() ->
    resolve_devrel_port(http_port, 8099, 5).

%% @doc Resolve the Riak HTTP port for this node.
%% Riak HTTP uses 100N8 (dev1=10018, dev2=10028, ...).
%% Stored in syn metadata so dashboards know how to reach each node.
-spec resolve_riak_http_port() -> pos_integer().
resolve_riak_http_port() ->
    resolve_devrel_port(riak_http_port, 8098, 8).

%% @private Resolve a port with devrel auto-assignment.
%%
%% In a devrel, each node is named devN@127.0.0.1 (N = 1..8).
%% Riak listeners follow the 100N_ pattern:
%%   100N5 = admin API (Cowboy)
%%   100N6 = cluster_manager
%%   100N7 = protobuf
%%   100N8 = HTTP (webmachine)
%%   100N9 = handoff
%%
%% In production (single node, non-devN name), the configured
%% default from application env is used.
-spec resolve_devrel_port(atom(), pos_integer(), 0..9) -> pos_integer().
resolve_devrel_port(EnvKey, Default, Offset) ->
    Configured = application:get_env(riak_admin_api, EnvKey, Default),
    case node() of
        nonode@nohost ->
            Configured;
        Node ->
            NodeStr = atom_to_list(Node),
            case re:run(NodeStr, "^dev([0-9]+)@", [{capture, [1], list}]) of
                {match, [NStr]} ->
                    N = list_to_integer(NStr),
                    10000 + N * 10 + Offset;
                nomatch ->
                    Configured
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
-spec routes() -> [cowboy_router:route_path()].
routes() ->
    admin_routes() ++ substrate_routes().

-spec admin_routes() -> [cowboy_router:route_path()].
admin_routes() ->
    [
        {"/api/ping",              rah_ping, []},
        {"/api/cluster/status",    rah_cluster, []},
        {"/api/dcs",               rah_dcs, []},
        {"/api/ring/ownership",    rah_ring, []},
        {"/api/nodes/:node/stats", rah_nodes, []},
        {"/api/handoff/status",    rah_handoff, []},
        {"/api/aae/status",        rah_aae, []}
        %% M7: {"/api/kv/:type/:bucket/:key",     rah_kv, []}
        %% M7: {"/api/bucket-types",              rah_bucket_types, []}
        %% M8: {"/api/stream/events",             rah_events_ws, []}
    ].

-spec substrate_routes() -> [cowboy_router:route_path()].
substrate_routes() ->
    [
        %% MapReduce compatibility endpoint (legacy singleton path)
        {"/mapred", riak_admin_api_handler, #{route_family => mapred}},

        %% Legacy alias family
        {"/riak", riak_admin_api_handler, #{route_family => riak}},
        {"/riak/:bucket", riak_admin_api_handler, #{route_family => riak}},
        {"/riak/:bucket/:key", riak_admin_api_handler, #{route_family => riak}},

        %% Default-type modern alias family
        {"/buckets", riak_admin_api_handler, #{route_family => buckets}},
        {"/buckets/:bucket/props", riak_admin_api_handler, #{route_family => buckets}},
        {"/buckets/:bucket/keys", riak_admin_api_handler, #{route_family => buckets}},
        {"/buckets/:bucket/counters/:key", riak_admin_api_handler,
            #{route_family => buckets}},
        {"/buckets/:bucket/query", riak_admin_api_handler, #{route_family => buckets}},
        {"/buckets/:bucket/index/:field/:term", riak_admin_api_handler,
            #{route_family => buckets}},
        {"/buckets/:bucket/index/:field/:start/:end", riak_admin_api_handler,
            #{route_family => buckets}},
        {"/buckets/:bucket/keys/:key", riak_admin_api_handler,
            #{route_family => buckets}},

        %% Typed modern alias family
        {"/types/:bucket_type/props", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/props", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/keys", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/datatypes", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/datatypes/:key", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/query", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/index/:field/:term", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/index/:field/:start/:end", riak_admin_api_handler,
            #{route_family => types}},
        {"/types/:bucket_type/buckets/:bucket/keys/:key", riak_admin_api_handler,
            #{route_family => types}}
    ].
