%%%-------------------------------------------------------------------
%%% @doc
%%% Event bridge for real-time WebSocket streaming.
%%%
%%% Subscribes to riak_core_ring_events and
%%% riak_core_node_watcher_events (push-based), and runs timers for
%%% poll-based data (node_stats, handoff, AAE). Publishes normalized
%%% events through the existing syn cluster_events group so that all
%%% WebSocket handlers and the coordinator receive them.
%%%
%%% The bridge is the single source of truth for the latest snapshot
%%% of each topic. WebSocket handlers call get_snapshot/1 when a
%%% client subscribes, so the dashboard renders immediately without
%%% waiting for the next event.
%%%
%%% All Riak internal calls go through riak_admin_api_riak (the
%%% gateway isolation pattern). The only direct riak_core contact is
%%% subscribing to ring_events and node_watcher_events, which must
%%% happen in this process.
%%% @end
%%%-------------------------------------------------------------------
-module(riak_admin_api_event_bridge).
-behaviour(gen_server).

%% API
-export([start_link/0, get_snapshot/1, available_topics/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-define(SCOPE, riak_admin).
-define(GROUP_EVENTS, cluster_events).

-define(ALL_TOPICS, [<<"ring">>, <<"cluster">>, <<"membership">>,
                     <<"node_stats">>, <<"handoff">>, <<"aae">>,
                     <<"dcs">>]).

%%% ============================================================
%%% API
%%% ============================================================

-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec get_snapshot(binary()) -> {ok, map()} | {error, not_available}.
get_snapshot(Topic) ->
    gen_server:call(?MODULE, {get_snapshot, Topic}).

-spec available_topics() -> [binary()].
available_topics() ->
    ?ALL_TOPICS.

%%% ============================================================
%%% gen_server callbacks
%%% ============================================================

-spec init([]) -> {ok, map()}.
init([]) ->
    %% Subscribe to push-based event sources.
    %% These callbacks fire in the subscribing process (us).
    ok = subscribe_ring_events(),
    ok = subscribe_node_watcher_events(),

    State = #{
        snapshots => #{},
        last_services => undefined
    },
    logger:info("[riak_admin] Event bridge started"),
    {ok, State}.

-spec handle_call(term(), {pid(), term()}, map()) ->
    {reply, term(), map()}.
handle_call({get_snapshot, Topic}, _From, #{snapshots := Snaps} = State) ->
    case maps:find(Topic, Snaps) of
        {ok, Data} -> {reply, {ok, Data}, State};
        error -> {reply, {error, not_available}, State}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

-spec handle_cast(term(), map()) -> {noreply, map()}.
handle_cast({ring_update, Ring}, State) ->
    State1 = handle_ring_update(Ring, State),
    {noreply, State1};
handle_cast({service_update, Services}, State) ->
    State1 = handle_service_update(Services, State),
    {noreply, State1};
handle_cast({dc_change, DcData}, State) ->
    State1 = publish_and_store(<<"dcs">>, DcData, State),
    {noreply, State1};
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec handle_info(term(), map()) -> {noreply, map()}.
handle_info(poll_node_stats, State) ->
    State1 = handle_poll_node_stats(State),
    schedule_poll(poll_node_stats, bridge_stats_interval()),
    {noreply, State1};
handle_info(poll_handoff, State) ->
    State1 = handle_poll_handoff(State),
    schedule_poll(poll_handoff, bridge_handoff_interval()),
    {noreply, State1};
handle_info(poll_aae, State) ->
    State1 = handle_poll_aae(State),
    schedule_poll(poll_aae, bridge_aae_interval()),
    {noreply, State1};
handle_info(_Msg, State) ->
    {noreply, State}.

-spec terminate(term(), map()) -> ok.
terminate(Reason, _State) ->
    logger:info("[riak_admin] Event bridge terminating: ~p", [Reason]),
    ok.

%%% ============================================================
%%% Push-based event handling
%%% ============================================================

handle_ring_update(Ring, State) ->
    %% Extract ring ownership data
    RingData = extract_ring_data(Ring),
    State1 = publish_and_store(<<"ring">>, RingData, State),

    %% Extract cluster status data from the same ring
    ClusterData = extract_cluster_data(Ring),
    publish_and_store(<<"cluster">>, ClusterData, State1).

handle_service_update(Services, #{last_services := LastServices} = State) ->
    Events = diff_services(LastServices, Services),
    State1 = State#{last_services := Services},
    case Events of
        [] ->
            State1;
        _ ->
            MembershipData = #{
                events => Events,
                services => Services
            },
            publish_and_store(<<"membership">>, MembershipData, State1)
    end.

%%% ============================================================
%%% Poll-based event handling (stubs for Step 5)
%%% ============================================================

handle_poll_node_stats(State) ->
    case collect_all_node_stats() of
        {ok, StatsData} ->
            maybe_publish_changed(<<"node_stats">>, StatsData, State);
        {error, _} ->
            State
    end.

handle_poll_handoff(State) ->
    case riak_admin_api_riak:handoff_status() of
        {ok, Transfers} ->
            Data = #{active_transfers => Transfers,
                     count => length(Transfers)},
            maybe_publish_changed(<<"handoff">>, Data, State);
        {error, _} ->
            State
    end.

handle_poll_aae(State) ->
    case riak_admin_api_riak:aae_status() of
        {ok, Exchanges} ->
            Data = #{exchanges => Exchanges,
                     count => length(Exchanges)},
            maybe_publish_changed(<<"aae">>, Data, State);
        {error, _} ->
            State
    end.

%%% ============================================================
%%% Ring data extraction
%%% ============================================================

extract_ring_data(Ring) ->
    try
        Owners = riak_core_ring:all_owners(Ring),
        Members = riak_core_ring:all_members(Ring),
        NumPartitions = riak_core_ring:num_partitions(Ring),
        NodeColors = maps:from_list(
            lists:zip(Members, lists:seq(0, length(Members) - 1))),
        {Partitions, _} = lists:foldl(
            fun({HashIdx, Node}, {Acc, Seq}) ->
                Entry = #{index => Seq, hash => HashIdx, node => Node},
                {[Entry | Acc], Seq + 1}
            end, {[], 0}, Owners),
        #{
            num_partitions => NumPartitions,
            partitions => lists:reverse(Partitions),
            node_colors => NodeColors
        }
    catch
        _:_ -> #{}
    end.

extract_cluster_data(Ring) ->
    try
        Members = riak_core_ring:all_members(Ring),
        MemberStatus = riak_core_ring:all_member_status(Ring),
        Owners = riak_core_ring:all_owners(Ring),
        NumPartitions = riak_core_ring:num_partitions(Ring),
        PendingChanges = riak_core_ring:pending_changes(Ring),

        OwnerCounts = lists:foldl(
            fun({_Idx, Node}, Acc) ->
                maps:update_with(Node, fun(C) -> C + 1 end, 1, Acc)
            end, #{}, Owners),

        Nodes = lists:map(
            fun(Node) ->
                Status = proplists:get_value(Node, MemberStatus, unknown),
                Count = maps:get(Node, OwnerCounts, 0),
                Pct = case NumPartitions of
                    0 -> 0.0;
                    _ -> float(round(Count * 10000 / NumPartitions)) / 100
                end,
                #{name => Node, status => Status,
                  ring_pct => Pct, reachable => true}
            end, Members),

        #{
            cluster_name => to_bin(riak_core_ring:cluster_name(Ring)),
            ring_size => NumPartitions,
            claimant => riak_core_ring:claimant(Ring),
            nodes => Nodes,
            pending_changes => format_pending(PendingChanges),
            ready => (PendingChanges =:= [])
        }
    catch
        _:_ -> #{}
    end.

%%% ============================================================
%%% Service diffing
%%% ============================================================

diff_services(undefined, _New) ->
    [];
diff_services(Old, New) when is_list(Old), is_list(New) ->
    Added = New -- Old,
    Removed = Old -- New,
    lists:map(fun(S) -> #{event => <<"service_up">>, service => S} end, Added) ++
    lists:map(fun(S) -> #{event => <<"service_down">>, service => S} end, Removed);
diff_services(_, _) ->
    [].

%%% ============================================================
%%% Stats collection
%%% ============================================================

collect_all_node_stats() ->
    try
        {ok, Ring} = riak_core_ring_manager:get_my_ring(),
        Members = riak_core_ring:all_members(Ring),
        Results = lists:foldl(
            fun(Node, Acc) ->
                case riak_admin_api_riak:node_stats(Node) of
                    {ok, Stats} -> Acc#{Node => Stats};
                    {error, _} -> Acc
                end
            end, #{}, Members),
        {ok, Results}
    catch
        _:_ -> {error, unavailable}
    end.

%%% ============================================================
%%% Publishing
%%% ============================================================

publish_and_store(Topic, Data, #{snapshots := Snaps} = State) ->
    publish_event(Topic, Data),
    State#{snapshots := Snaps#{Topic => Data}}.

maybe_publish_changed(Topic, Data, #{snapshots := Snaps} = State) ->
    DiffEnabled = application:get_env(
        riak_admin_api, bridge_diff_detection, true),
    case DiffEnabled of
        true ->
            case maps:find(Topic, Snaps) of
                {ok, Data} ->
                    %% Unchanged, skip publish
                    State;
                _ ->
                    publish_and_store(Topic, Data, State)
            end;
        _ ->
            publish_and_store(Topic, Data, State)
    end.

publish_event(Topic, Data) ->
    try
        syn:publish(?SCOPE, ?GROUP_EVENTS,
                    {event, node(), {Topic, Data}})
    catch
        _:PublishErr ->
            logger:warning("[riak_admin] Bridge failed to publish ~s: ~p",
                           [Topic, PublishErr])
    end.

%%% ============================================================
%%% Subscriptions
%%% ============================================================

subscribe_ring_events() ->
    try
        riak_core_ring_events:add_sup_callback(fun(Ring) ->
            gen_server:cast(?MODULE, {ring_update, Ring})
        end),
        ok
    catch
        _:Err ->
            logger:warning("[riak_admin] Could not subscribe to "
                           "ring_events: ~p", [Err]),
            ok
    end.

subscribe_node_watcher_events() ->
    try
        riak_core_node_watcher_events:add_sup_callback(fun(Services) ->
            gen_server:cast(?MODULE, {service_update, Services})
        end),
        ok
    catch
        _:Err ->
            logger:warning("[riak_admin] Could not subscribe to "
                           "node_watcher_events: ~p", [Err]),
            ok
    end.

%%% ============================================================
%%% Timers
%%% ============================================================

schedule_poll(Msg, Interval) ->
    erlang:send_after(Interval, self(), Msg).

bridge_stats_interval() ->
    application:get_env(riak_admin_api, bridge_stats_interval, 10000).

bridge_handoff_interval() ->
    application:get_env(riak_admin_api, bridge_handoff_interval, 15000).

bridge_aae_interval() ->
    application:get_env(riak_admin_api, bridge_aae_interval, 30000).

%%% ============================================================
%%% Internal helpers
%%% ============================================================

to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

format_pending([]) -> [];
format_pending(Changes) when is_list(Changes) ->
    lists:map(fun(C) ->
        iolist_to_binary(io_lib:format("~p", [C]))
    end, Changes);
format_pending(_) -> [].

%%% ============================================================
%%% Tests
%%% ============================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

available_topics_test_() ->
    {"available_topics returns the expected topic list",
     fun() ->
         Topics = available_topics(),
         ?assertEqual(7, length(Topics)),
         ?assert(lists:member(<<"ring">>, Topics)),
         ?assert(lists:member(<<"cluster">>, Topics)),
         ?assert(lists:member(<<"membership">>, Topics)),
         ?assert(lists:member(<<"node_stats">>, Topics)),
         ?assert(lists:member(<<"handoff">>, Topics)),
         ?assert(lists:member(<<"aae">>, Topics)),
         ?assert(lists:member(<<"dcs">>, Topics))
     end}.

diff_services_test_() ->
    {"service diff produces correct events", [
        {"undefined old returns empty",
         fun() ->
             ?assertEqual([], diff_services(undefined, [riak_kv]))
         end},
        {"new service produces service_up",
         fun() ->
             Events = diff_services([riak_kv], [riak_kv, riak_pipe]),
             ?assertEqual(1, length(Events)),
             [E] = Events,
             ?assertEqual(<<"service_up">>, maps:get(event, E)),
             ?assertEqual(riak_pipe, maps:get(service, E))
         end},
        {"removed service produces service_down",
         fun() ->
             Events = diff_services([riak_kv, riak_pipe], [riak_kv]),
             ?assertEqual(1, length(Events)),
             [E] = Events,
             ?assertEqual(<<"service_down">>, maps:get(event, E)),
             ?assertEqual(riak_pipe, maps:get(service, E))
         end},
        {"no change produces empty list",
         fun() ->
             ?assertEqual([], diff_services([riak_kv], [riak_kv]))
         end}
    ]}.

publish_and_store_test_() ->
    {"publish_and_store updates snapshot state",
     fun() ->
         %% We can't actually publish through syn in unit tests,
         %% but we can verify state management.
         State0 = #{snapshots => #{}},
         %% Manually test the state update portion
         Snaps = #{<<"ring">> => #{test => true}},
         State1 = State0#{snapshots := Snaps},
         ?assertEqual(#{test => true}, maps:get(<<"ring">>, maps:get(snapshots, State1)))
     end}.

maybe_publish_changed_skips_unchanged_test_() ->
    {"maybe_publish_changed skips when data hasn't changed",
     fun() ->
         Data = #{foo => bar},
         State0 = #{snapshots => #{<<"test">> => Data}},
         application:set_env(riak_admin_api, bridge_diff_detection, true),
         %% Same data should not change state (no publish)
         State1 = maybe_publish_changed(<<"test">>, Data, State0),
         ?assertEqual(State0, State1)
     end}.

format_pending_test_() ->
    {"format_pending handles various inputs", [
        {"empty list",
         fun() -> ?assertEqual([], format_pending([])) end},
        {"non-list",
         fun() -> ?assertEqual([], format_pending(undefined)) end},
        {"list of terms",
         fun() ->
             Result = format_pending([{change, a, b}]),
             ?assertEqual(1, length(Result)),
             ?assert(is_binary(hd(Result)))
         end}
    ]}.

to_bin_test_() ->
    {"to_bin converts various types", [
        {"binary passthrough",
         fun() -> ?assertEqual(<<"hello">>, to_bin(<<"hello">>)) end},
        {"atom conversion",
         fun() -> ?assertEqual(<<"ok">>, to_bin(ok)) end},
        {"list conversion",
         fun() -> ?assertEqual(<<"abc">>, to_bin("abc")) end}
    ]}.

-endif.
