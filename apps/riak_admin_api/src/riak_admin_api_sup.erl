%%%-------------------------------------------------------------------
%%% @doc
%%% Top-level supervisor for riak_admin_api.
%%%
%%% Children (S1 revised, M8 updated):
%%% - riak_admin_http: Cowboy listener (ranch child spec)
%%% - riak_admin_api_event_bridge: event bridge for WS streaming
%%% - riak_admin_api_coordinator: syn registration lifecycle
%%%
%%% Restart strategy: rest_for_one — if the listener crashes, the
%%% coordinator is also restarted (it depends on the listener being
%%% available). The intensity (5 restarts in 10 seconds) provides
%%% reasonable fault tolerance without masking persistent failures.
%%%
%%% S1 change (CG-017): The Cowboy listener is now supervised here
%%% instead of being started outside the supervision tree. A listener
%%% crash triggers automatic restart rather than silent unavailability.
%%% @end
%%%-------------------------------------------------------------------

-module(riak_admin_api_sup).
-behaviour(supervisor).

-export([start_link/1, init/1]).

%% @doc Start the supervisor with the listener child spec.
%%
%% The listener spec is built by riak_admin_api_app and passed here
%% so that the supervisor owns the Cowboy listener process.
-spec start_link(supervisor:child_spec()) -> {ok, pid()} | {error, term()}.
start_link(ListenerSpec) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [ListenerSpec]).

%% @doc Supervisor init callback.
%%
%% Children (in start order):
%% 1. riak_admin_http: Cowboy listener (must start first)
%% 2. riak_admin_api_event_bridge: event bridge (before coordinator)
%% 3. riak_admin_api_coordinator: syn registration lifecycle
-spec init([supervisor:child_spec()]) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([ListenerSpec]) ->
    EventBridge = #{
        id => riak_admin_api_event_bridge,
        start => {riak_admin_api_event_bridge, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    Coordinator = #{
        id => riak_admin_api_coordinator,
        start => {riak_admin_api_coordinator, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10},
          [ListenerSpec, EventBridge, Coordinator]}}.
