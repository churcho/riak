%% @doc Top-level supervisor for the riak_admin_api application.
%%
%% This supervisor currently has no child processes. Cowboy manages
%% its own process tree under the listener started in
%% riak_admin_api_app:start/2, so the supervisor exists primarily
%% as the required OTP application supervisor and as a future
%% attachment point for child workers (e.g., a coordinator process
%% for streaming cluster operations).
%%
%% == Restart strategy ==
%%
%% `one_for_one' — each child is restarted independently. The
%% intensity (5 restarts in 10 seconds) provides reasonable fault
%% tolerance without masking persistent failures.

-module(riak_admin_api_sup).
-behaviour(supervisor).

-export([start_link/0, init/1]).

%% @doc Start the supervisor and register it locally as
%% `riak_admin_api_sup'.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Supervisor init callback.
%%
%% Returns an empty child list. Children will be added in later
%% milestones as the admin API grows (e.g., a coordinator for
%% multi-node cluster operations).
init([]) ->
    {ok, {#{strategy => one_for_one, intensity => 5, period => 10}, []}}.
