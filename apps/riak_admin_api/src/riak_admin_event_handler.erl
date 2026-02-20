%%%-------------------------------------------------------------------
%%% @doc
%%% syn event handler for the `riak_admin' scope.
%%%
%%% Handles process registration/unregistration events (node
%%% discovery and departure) and resolves registry conflicts
%%% during netsplit recovery.
%%%
%%% Conflict resolution strategy: oldest process wins. This is
%%% deterministic and stable — both sides of a partition will
%%% converge to the same winner.
%%%
%%% Note on syn 3.3.0 API: resolve_registry_conflict/4 receives
%%% 3-tuples {Pid, Meta, Time} and must return the PID to keep.
%%% This differs from older syn versions that used 2-tuples and
%%% returned 1 or 2.
%%% @end
%%%-------------------------------------------------------------------
-module(riak_admin_event_handler).
-behaviour(syn_event_handler).

-export([
    on_process_registered/5,
    on_process_unregistered/5,
    on_process_joined/5,
    on_process_left/5,
    resolve_registry_conflict/4
]).

%%% ============================================================
%%% Callbacks
%%% ============================================================

%% @doc Called when a new admin API node registers with syn.
%% Logs the discovery for operational visibility.
-spec on_process_registered(atom(), term(), pid(), term(), term()) -> any().
on_process_registered(riak_admin, {api_node, Node}, _Pid, Meta, _Reason) ->
    logger:info("[riak_admin] Discovered admin API on ~p (dc=~s)",
                [Node, safe_dc(Meta)]),
    ok;
on_process_registered(_Scope, _Key, _Pid, _Meta, _Reason) ->
    ok.

%% @doc Called when an admin API node's process is unregistered.
%% This happens on clean shutdown, crash, or network partition.
%% Log level varies by cause for appropriate alerting.
%%
%% Note: syn's callback spec declares Reason as atom(), but syn
%% actually sends tuples like {syn_remote_scope_node_down, Scope,
%% Node}. We use term() to match the real-world values.
-spec on_process_unregistered(atom(), term(), pid(), term(), term()) -> any().
on_process_unregistered(riak_admin, {api_node, Node}, _Pid, Meta, Reason) ->
    DC = safe_dc(Meta),
    case Reason of
        {syn_remote_scope_node_down, _Scope, _RemoteNode} ->
            logger:warning("[riak_admin] DC ~s node ~p unreachable "
                           "(network partition or node down)", [DC, Node]);
        normal ->
            logger:info("[riak_admin] Admin API on ~p stopped cleanly",
                        [Node]);
        _ ->
            logger:notice("[riak_admin] Admin API on ~p unregistered: ~p",
                          [Node, Reason])
    end,
    ok;
on_process_unregistered(_Scope, _Key, _Pid, _Meta, _Reason) ->
    ok.

%% @doc Resolves conflicting registrations after a netsplit heals.
%%
%% Both sides of a partition may have registered the same key.
%% We pick the process that started earliest (lowest `started_at').
%% This is deterministic — both sides converge to the same winner.
%%
%% syn 3.3.0 API: entries are {Pid, Meta, Time} 3-tuples.
%% Returns the PID to keep.
-spec resolve_registry_conflict(atom(), term(),
    {pid(), term(), non_neg_integer()},
    {pid(), term(), non_neg_integer()}) -> pid().
resolve_registry_conflict(riak_admin, Key,
                          {Pid1, Meta1, _Time1}, {Pid2, Meta2, _Time2}) ->
    Started1 = safe_started_at(Meta1),
    Started2 = safe_started_at(Meta2),
    {Winner, WinnerNum} = case Started1 =< Started2 of
        true  -> {Pid1, 1};
        false -> {Pid2, 2}
    end,
    logger:notice("[riak_admin] Registry conflict on ~p resolved: "
                  "winner=~B (started_at: ~B vs ~B)",
                  [Key, WinnerNum, Started1, Started2]),
    Winner;
resolve_registry_conflict(_Scope, _Key, {Pid1, _Meta1, _Time1}, _Entry2) ->
    Pid1.

%% @doc Called when a process joins a syn group.
-spec on_process_joined(atom(), term(), pid(), term(), term()) -> any().
on_process_joined(riak_admin, Group, _Pid, _Meta, _Reason) ->
    logger:debug("[riak_admin] Process joined group ~p", [Group]),
    ok;
on_process_joined(_Scope, _Group, _Pid, _Meta, _Reason) ->
    ok.

%% @doc Called when a process leaves a syn group.
-spec on_process_left(atom(), term(), pid(), term(), term()) -> any().
on_process_left(riak_admin, Group, _Pid, _Meta, _Reason) ->
    logger:debug("[riak_admin] Process left group ~p", [Group]),
    ok;
on_process_left(_Scope, _Group, _Pid, _Meta, _Reason) ->
    ok.

%%% ============================================================
%%% Internal
%%% ============================================================

%% @private Safely extract dc name from metadata.
%% Meta is term() per syn's callback spec; may not be a map.
-spec safe_dc(term()) -> binary().
safe_dc(Meta) when is_map(Meta) ->
    maps:get(dc, Meta, <<"unknown">>);
safe_dc(_) ->
    <<"unknown">>.

%% @private Safely extract started_at from metadata.
-spec safe_started_at(term()) -> non_neg_integer().
safe_started_at(Meta) when is_map(Meta) ->
    maps:get(started_at, Meta, 0);
safe_started_at(_) ->
    0.

%%% ============================================================
%%% Tests
%%% ============================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

resolve_conflict_oldest_wins_test_() ->
    {"oldest process (lowest started_at) wins conflict resolution", [
        {"first is older — returns Pid1",
         fun() ->
             Pid1 = list_to_pid("<0.100.0>"),
             Pid2 = list_to_pid("<0.200.0>"),
             Meta1 = #{started_at => 1000},
             Meta2 = #{started_at => 2000},
             ?assertEqual(Pid1, resolve_registry_conflict(
                 riak_admin, {api_node, node()},
                 {Pid1, Meta1, 0}, {Pid2, Meta2, 0}))
         end},
        {"second is older — returns Pid2",
         fun() ->
             Pid1 = list_to_pid("<0.100.0>"),
             Pid2 = list_to_pid("<0.200.0>"),
             Meta1 = #{started_at => 3000},
             Meta2 = #{started_at => 1000},
             ?assertEqual(Pid2, resolve_registry_conflict(
                 riak_admin, {api_node, node()},
                 {Pid1, Meta1, 0}, {Pid2, Meta2, 0}))
         end},
        {"equal timestamps — returns Pid1 (tiebreaker)",
         fun() ->
             Pid1 = list_to_pid("<0.100.0>"),
             Pid2 = list_to_pid("<0.200.0>"),
             Meta = #{started_at => 1000},
             ?assertEqual(Pid1, resolve_registry_conflict(
                 riak_admin, {api_node, node()},
                 {Pid1, Meta, 0}, {Pid2, Meta, 0}))
         end},
        {"missing started_at defaults to 0",
         fun() ->
             Pid1 = list_to_pid("<0.100.0>"),
             Pid2 = list_to_pid("<0.200.0>"),
             Meta1 = #{},
             Meta2 = #{started_at => 1000},
             ?assertEqual(Pid1, resolve_registry_conflict(
                 riak_admin, {api_node, node()},
                 {Pid1, Meta1, 0}, {Pid2, Meta2, 0}))
         end},
        {"non-map metadata handled gracefully",
         fun() ->
             Pid1 = list_to_pid("<0.100.0>"),
             Pid2 = list_to_pid("<0.200.0>"),
             ?assertEqual(Pid1, resolve_registry_conflict(
                 riak_admin, {api_node, node()},
                 {Pid1, undefined, 0}, {Pid2, #{started_at => 1000}, 0}))
         end}
    ]}.

non_matching_scope_test_() ->
    {"callbacks ignore non-riak_admin scopes", [
        {"registered on other scope returns ok",
         fun() ->
             ?assertEqual(ok, on_process_registered(
                 other_scope, key, self(), #{}, normal))
         end},
        {"unregistered on other scope returns ok",
         fun() ->
             ?assertEqual(ok, on_process_unregistered(
                 other_scope, key, self(), #{}, normal))
         end},
        {"conflict on other scope returns first pid",
         fun() ->
             Pid1 = list_to_pid("<0.100.0>"),
             Pid2 = list_to_pid("<0.200.0>"),
             ?assertEqual(Pid1, resolve_registry_conflict(
                 other_scope, key,
                 {Pid1, #{}, 0}, {Pid2, #{}, 0}))
         end}
    ]}.

on_process_unregistered_reasons_test_() ->
    {"unregistered handles all reason variants without crashing", [
        {"network partition reason",
         fun() ->
             ?assertEqual(ok, on_process_unregistered(
                 riak_admin, {api_node, 'n@host'}, self(),
                 #{dc => <<"east">>},
                 {syn_remote_scope_node_down, riak_admin, 'n@host'}))
         end},
        {"normal shutdown",
         fun() ->
             ?assertEqual(ok, on_process_unregistered(
                 riak_admin, {api_node, 'n@host'}, self(),
                 #{dc => <<"east">>}, normal))
         end},
        {"unexpected reason",
         fun() ->
             ?assertEqual(ok, on_process_unregistered(
                 riak_admin, {api_node, 'n@host'}, self(),
                 #{dc => <<"east">>}, {killed, some_reason}))
         end},
        {"missing dc in metadata",
         fun() ->
             ?assertEqual(ok, on_process_unregistered(
                 riak_admin, {api_node, 'n@host'}, self(),
                 #{}, normal))
         end},
        {"non-map metadata",
         fun() ->
             ?assertEqual(ok, on_process_unregistered(
                 riak_admin, {api_node, 'n@host'}, self(),
                 undefined, normal))
         end}
    ]}.

safe_started_at_test_() ->
    {"safe_started_at extracts from various meta shapes", [
        {"map with started_at",
         fun() -> ?assertEqual(42, safe_started_at(#{started_at => 42})) end},
        {"map without started_at",
         fun() -> ?assertEqual(0, safe_started_at(#{})) end},
        {"non-map returns 0",
         fun() -> ?assertEqual(0, safe_started_at(undefined)) end}
    ]}.

-endif.
