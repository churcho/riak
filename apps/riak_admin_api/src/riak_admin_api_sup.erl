%%%-------------------------------------------------------------------
%%% @doc
%%% Top-level supervisor for riak_admin_api.
%%%
%%% Children:
%%% - riak_admin_api_coordinator: syn registration lifecycle
%%%
%%% Restart strategy: one_for_one — each child is restarted
%%% independently. The intensity (5 restarts in 10 seconds) provides
%%% reasonable fault tolerance without masking persistent failures.
%%% @end
%%%-------------------------------------------------------------------

-module(riak_admin_api_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%% @doc Start the supervisor and register it locally as
%% `riak_admin_api_sup'.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Supervisor init callback.
%%
%% Children:
%% - riak_admin_api_coordinator: syn registration lifecycle
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    Coordinator = #{
        id => riak_admin_api_coordinator,
        start => {riak_admin_api_coordinator, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker
    },
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10},
          [Coordinator]}}.
