%%%-------------------------------------------------------------------
%%% @doc
%%% Coordinator process for the admin API's syn presence.
%%%
%%% Owns the syn registration for this node. On startup, registers
%%% in the `riak_admin' scope with metadata (DC name, ports, version).
%%% Joins the `api_nodes' group for discovery and `cluster_events'
%%% group for push notifications.
%%%
%%% If this process crashes, syn automatically unregisters it.
%%% The supervisor restarts it and it re-registers with a
%%% stale-key retry (see register_with_syn/1).
%%%
%%% Syn lifecycle calls (register, join, unregister) live here.
%%% Syn query calls (syn:members) live in the gateway module
%%% (riak_admin_api_riak) alongside other data-access functions.
%%% @end
%%%-------------------------------------------------------------------
-module(riak_admin_api_coordinator).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([get_dc_name/0, get_admin_port/0, get_metadata/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

%% Types
-export_type([coordinator_meta/0]).

%% Metadata advertised via syn to all nodes in the riak_admin scope.
%% Other nodes read these fields to build the DC discovery response.
-type coordinator_meta() :: #{
    dc        := binary(),         %% Datacenter name (from app env dc_name)
    node      := node(),           %% Erlang node atom (e.g., 'dev1@127.0.0.1')
    http_port := pos_integer(),    %% Admin API port (Cowboy listener)
    riak_http := pos_integer(),    %% Riak HTTP port (Webmachine, for proxying)
    riak_vsn  := binary(),         %% Riak version string (from riak_kv app key)
    started_at := non_neg_integer() %% erlang:system_time(second) at registration
}.

-define(SCOPE, riak_admin).
-define(REGISTRY_KEY(Node), {api_node, Node}).
-define(GROUP_NODES, api_nodes).
-define(GROUP_EVENTS, cluster_events).

%%% ============================================================
%%% API
%%% ============================================================

%% @doc Starts the coordinator and registers with syn.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Returns the configured DC name for this node.
%% Reads from application env, defaults to <<"default">>.
-spec get_dc_name() -> binary().
get_dc_name() ->
    application:get_env(riak_admin_api, dc_name, <<"default">>).

%% @doc Returns the configured admin HTTP port for this node.
-spec get_admin_port() -> pos_integer().
get_admin_port() ->
    application:get_env(riak_admin_api, http_port, 8099).

%% @doc Returns the full metadata map for this coordinator.
%% Useful for tests and diagnostics.
-spec get_metadata() -> coordinator_meta().
get_metadata() ->
    gen_server:call(?MODULE, get_metadata).

%%% ============================================================
%%% gen_server callbacks
%%% ============================================================

-spec init([]) -> {ok, #{meta := coordinator_meta()}}.
init([]) ->
    Meta = build_metadata(),
    ok = register_with_syn(Meta),
    logger:info("[riak_admin] Coordinator registered "
                "(dc=~s, port=~B, node=~p)",
                [maps:get(dc, Meta), maps:get(http_port, Meta), node()]),
    {ok, #{meta => Meta}}.

-spec handle_call(term(), {pid(), term()}, map()) ->
    {reply, term(), map()}.
handle_call(get_metadata, _From, #{meta := Meta} = State) ->
    {reply, Meta, State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info({cluster_event, Event}, State) ->
    %% Forward cluster events to all group subscribers.
    %% Failures here must not crash the coordinator.
    try
        {ok, _Count} = syn:publish(?SCOPE, ?GROUP_EVENTS, {event, node(), Event})
    catch
        _:PublishErr ->
            logger:warning("[riak_admin] Failed to publish event: ~p",
                           [PublishErr])
    end,
    {noreply, State};
handle_info(Msg, State) ->
    logger:debug("[riak_admin] Coordinator got unexpected message: ~p",
                 [Msg]),
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(Reason, _State) ->
    logger:info("[riak_admin] Coordinator terminating: ~p", [Reason]),
    ok.

%%% ============================================================
%%% Internal
%%% ============================================================

%% @private Register this coordinator with syn's registry and groups.
%%
%% After a crash+restart, the previous process's registry entry may
%% still exist briefly (syn hasn't processed the DOWN signal yet).
%% In that case syn:register/4 returns {error, taken}. We handle
%% this by unregistering the stale entry and retrying once, which
%% avoids a restart loop that would exhaust the supervisor's max
%% intensity.
%%
%% syn:unregister/2 can return {error, undefined} if syn already
%% processed the DOWN between our check and the unregister call,
%% or {error, race_condition} during cluster sync. Both are
%% recoverable — a short sleep lets syn converge, then retry.
-spec register_with_syn(coordinator_meta()) -> ok.
register_with_syn(Meta) ->
    Key = ?REGISTRY_KEY(node()),
    case syn:register(?SCOPE, Key, self(), Meta) of
        ok ->
            ok;
        {error, taken} ->
            logger:warning("[riak_admin] Registry key ~p taken "
                           "(stale entry from previous incarnation), "
                           "unregistering and retrying", [Key]),
            case syn:unregister(?SCOPE, Key) of
                ok ->
                    ok;
                {error, UnregReason} ->
                    %% syn already cleaned up, or cluster is syncing.
                    %% Brief pause lets syn finish processing the DOWN.
                    logger:warning("[riak_admin] Unregister returned ~p, "
                                   "pausing before retry", [UnregReason]),
                    timer:sleep(100)
            end,
            ok = syn:register(?SCOPE, Key, self(), Meta)
    end,
    ok = syn:join(?SCOPE, ?GROUP_NODES, self(), Meta),
    ok = syn:join(?SCOPE, ?GROUP_EVENTS, self()),
    ok.

%% @private Build metadata map from application config and runtime info.
-spec build_metadata() -> coordinator_meta().
build_metadata() ->
    #{
        dc        => get_dc_name(),
        node      => node(),
        http_port => get_admin_port(),
        riak_http => application:get_env(riak_admin_api, riak_http_port, 8098),
        riak_vsn  => riak_admin_api_riak:get_riak_version(),
        started_at => erlang:system_time(second)
    }.

%%% ============================================================
%%% Tests
%%% ============================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

build_metadata_test_() ->
    {"build_metadata returns map with all required keys",
     fun() ->
         Meta = build_metadata(),
         ?assert(is_map(Meta)),
         ?assert(is_binary(maps:get(dc, Meta))),
         ?assert(is_atom(maps:get(node, Meta))),
         ?assert(is_integer(maps:get(http_port, Meta))),
         ?assert(is_integer(maps:get(riak_http, Meta))),
         ?assert(is_binary(maps:get(riak_vsn, Meta))),
         ?assert(is_integer(maps:get(started_at, Meta))),
         ?assert(maps:get(started_at, Meta) > 0)
     end}.

get_dc_name_test_() ->
    {"get_dc_name returns binary",
     fun() ->
         DC = get_dc_name(),
         ?assert(is_binary(DC))
     end}.

get_admin_port_test_() ->
    {"get_admin_port returns positive integer",
     fun() ->
         Port = get_admin_port(),
         ?assert(is_integer(Port)),
         ?assert(Port > 0)
     end}.

get_riak_version_test_() ->
    {"get_riak_version returns binary even when riak_kv not loaded",
     fun() ->
         Vsn = riak_admin_api_riak:get_riak_version(),
         ?assert(is_binary(Vsn))
     end}.

-endif.
