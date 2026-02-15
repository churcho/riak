%% @doc Gateway module: ALL calls to riak_core, riak_kv, and
%% riak_object go through this module exclusively.
%%
%% No other module in riak_admin_api may call Riak internals
%% directly. This is the cornerstone of the isolation pattern
%% that makes the admin API extractable to its own repository.
%%
%% == Why this matters ==
%%
%% <ul>
%%   <li>The .app.src never lists riak_core or riak_kv as
%%       dependencies — they are resolved at runtime only.</li>
%%   <li>`rebar3 compile' works without Riak source present
%%       (Erlang resolves module calls at runtime, not compile
%%       time).</li>
%%   <li>Every handler is testable in isolation — swap this
%%       gateway for a mock and Cowboy still works.</li>
%%   <li>Extraction to a standalone repo is mechanical: copy
%%       the directory, change path to git in Riak's
%%       rebar.config, done.</li>
%% </ul>
%%
%% == Isolation check ==
%%
%% Run this before every commit to verify no leaks:
%% ```
%% grep -rn "riak_core\|riak_kv\|riak_object\|riak:local" src/ \
%%   | grep -v riak_admin_api_riak.erl
%% '''
%% Should return zero results.
%%
%% == Error handling ==
%%
%% Every public function returns {ok, Data} | {error, Reason}.
%% Exceptions from Riak internals are caught and wrapped so that
%% handlers never see raw crashes — they get a clean error tuple
%% to format into an HTTP 500 response.

-module(riak_admin_api_riak).

-export([
    cluster_status/0,
    ring_ownership/0,
    node_stats/1,
    handoff_status/0,
    aae_status/0,
    %% syn-powered DC discovery
    list_dcs/0,
    remote_dcs/0,
    %% Riak version query (isolation: keeps riak_kv atom in gateway)
    get_riak_version/0
]).

%% Exported so remote nodes can call it via rpc:call/4.
%% When a handler requests stats for a remote node, node_stats/1
%% does rpc:call(RemoteNode, ?MODULE, collect_local_stats, []).
%% This function must be exported for that to work.
-export([collect_local_stats/0]).

-ifdef(TEST).
-export([
    to_bin/1,
    round_pct/2,
    format_pending/1,
    format_transfers/1,
    format_exchanges/1,
    node_host/1,
    dedup_by_dc/1
]).
-endif.

%% Types
-export_type([dc_info/0]).

%% External representation of a datacenter, returned by /api/dcs.
%% Built from coordinator_meta() with added computed fields.
-type dc_info() :: #{
    name := binary(),          %% DC name (maps from coordinator_meta().dc)
    local := boolean(),        %% true if this DC matches the local node's DC
    admin_url := binary(),     %% Full URL to the admin API (http://host:port)
    riak_url := binary(),      %% Full URL to Riak HTTP API (http://host:port)
    riak_version := binary(),  %% Riak version running on the representative node
    node := node(),            %% Erlang node atom of the representative node
    reachable := boolean(),    %% Always true (syn members are reachable by definition)
    started_at := non_neg_integer() %% Coordinator start time (for diagnostics)
}.

%%% ============================================================
%%% Cluster Status
%%% ============================================================

%% @doc Return cluster membership, ring size, and node health.
%%
%% Calls riak_core_ring_manager to get the current ring, then
%% extracts membership, partition ownership counts, and node
%% reachability. The returned map matches the JSON contract that
%% the rah_cluster handler sends to clients.
%%
%% For each node, ring_pct is calculated as the percentage of
%% partitions owned by that node. Reachable is determined by
%% net_adm:ping/1 (fine for small clusters; consider caching
%% for large ones).
-spec cluster_status() -> {ok, map()} | {error, term()}.
cluster_status() ->
    try
        {ok, Ring} = riak_core_ring_manager:get_my_ring(),
        Members = riak_core_ring:all_members(Ring),
        MemberStatus = riak_core_ring:all_member_status(Ring),
        Owners = riak_core_ring:all_owners(Ring),
        NumPartitions = riak_core_ring:num_partitions(Ring),

        %% Count partitions per node for ring_pct calculation
        OwnerCounts = lists:foldl(
            fun({_Idx, Node}, Acc) ->
                maps:update_with(Node, fun(C) -> C + 1 end, 1, Acc)
            end, #{}, Owners),

        Nodes = lists:map(
            fun(Node) ->
                Status = proplists:get_value(Node, MemberStatus, unknown),
                Count = maps:get(Node, OwnerCounts, 0),
                Pct = round_pct(Count, NumPartitions),
                Reachable = net_adm:ping(Node) =:= pong,
                #{name => Node, status => Status,
                  ring_pct => Pct, reachable => Reachable}
            end, Members),

        RemoteDCs = remote_dcs(),
        PendingChanges = riak_core_ring:pending_changes(Ring),
        {ok, #{
            cluster_name => to_bin(riak_core_ring:cluster_name(Ring)),
            ring_size => NumPartitions,
            claimant => riak_core_ring:claimant(Ring),
            nodes => Nodes,
            pending_changes => format_pending(PendingChanges),
            ready => (PendingChanges =:= []),
            remote_dcs => RemoteDCs,
            total_dcs => length(RemoteDCs) + 1
        }}
    catch
        Class:Reason:Stack ->
            logger:error("[riak_admin] cluster_status failed: ~p:~p~n~p",
                         [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

%%% ============================================================
%%% Ring Ownership
%%% ============================================================

%% @doc Return the full partition-to-node mapping of the ring.
%%
%% Calls riak_core_ring:all_owners/1 to get the list of
%% {HashIndex, Node} tuples. Each partition gets a sequential
%% index (for TUI rendering) and retains the raw hash (the
%% position on the 2^160 ring) for potential key-to-partition
%% mapping later.
%%
%% node_colors assigns each member a sequential integer for use
%% as a colour index in visualisations.
-spec ring_ownership() -> {ok, map()} | {error, term()}.
ring_ownership() ->
    try
        {ok, Ring} = riak_core_ring_manager:get_my_ring(),
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

        {ok, #{
            num_partitions => NumPartitions,
            partitions => lists:reverse(Partitions),
            node_colors => NodeColors
        }}
    catch
        Class:Reason:Stack ->
            logger:error("[riak_admin] ring_ownership failed: ~p:~p~n~p",
                         [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

%%% ============================================================
%%% Node Stats
%%% ============================================================

%% @doc Return stats for a specific node.
%%
%% For the local node, calls collect_local_stats/0 directly.
%% For remote nodes, uses rpc:call/4 with a 5-second timeout.
%% The remote node must have riak_admin_api loaded (which it
%% will, since all nodes run the same release).
-spec node_stats(node()) -> {ok, map()} | {error, term()}.
node_stats(Node) when Node =:= node() ->
    {ok, collect_local_stats()};
node_stats(Node) ->
    case rpc:call(Node, ?MODULE, collect_local_stats, [], 5000) of
        {badrpc, Reason} -> {error, {unreachable, Reason}};
        Stats when is_map(Stats) -> {ok, Stats};
        Other -> {error, {unexpected, Other}}
    end.

%% @doc Collect stats from the local node.
%%
%% Returns a map with two sections:
%% - erlang: OTP version, process count, memory breakdown, run queue
%%   (always available — these are pure Erlang/OTP calls)
%% - kv: vnode gets/puts, node gets/puts, read repairs, FSM latencies
%%   (sourced from riak_kv_status; wrapped in try/catch so the API
%%   still works even if riak_kv hasn't fully started)
%%
%% Exported because remote nodes call this via rpc:call/4 from
%% node_stats/1.
-spec collect_local_stats() -> map().
collect_local_stats() ->
    Mem = erlang:memory(),
    KV = try riak_kv_status:statistics() catch _:_ -> [] end,
    #{
        node => node(),
        erlang => #{
            otp_release => list_to_binary(erlang:system_info(otp_release)),
            process_count => erlang:system_info(process_count),
            memory_total_mb => pv(total, Mem) div (1024 * 1024),
            memory_processes_mb => pv(processes, Mem) div (1024 * 1024),
            memory_ets_mb => pv(ets, Mem) div (1024 * 1024),
            run_queue => erlang:statistics(run_queue)
        },
        kv => #{
            vnode_gets => pv(vnode_gets, KV),
            vnode_puts => pv(vnode_puts, KV),
            node_gets => pv(node_gets_total, KV),
            node_puts => pv(node_puts_total, KV),
            read_repairs => pv(read_repairs_total, KV),
            node_get_fsm_time_mean => pv(node_get_fsm_time_mean, KV),
            node_put_fsm_time_mean => pv(node_put_fsm_time_mean, KV)
        }
    }.

%%% ============================================================
%%% Handoff Status
%%% ============================================================

%% @doc Return active handoff transfers.
%%
%% Calls riak_core_handoff_manager:status/0. The return type
%% varies between Riak versions, so format_transfers/1 uses a
%% defensive approach: known tuple shapes are destructured into
%% clean maps; unknown shapes are stringified as a safe fallback.
-spec handoff_status() -> {ok, [map()]} | {error, term()}.
handoff_status() ->
    try
        Raw = riak_core_handoff_manager:status(),
        {ok, format_transfers(Raw)}
    catch
        Class:Reason:Stack ->
            logger:error("[riak_admin] handoff_status failed: ~p:~p~n~p",
                         [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

%%% ============================================================
%%% AAE (Active Anti-Entropy) Status
%%% ============================================================

%% @doc Return AAE exchange information.
%%
%% Calls riak_kv_entropy_info:compute_exchange_info/0. Like
%% handoff, the return structure varies between versions, so
%% format_exchanges/1 uses the same defensive pattern: known
%% shapes get proper maps, unknown shapes get stringified.
-spec aae_status() -> {ok, [map()]} | {error, term()}.
aae_status() ->
    try
        Raw = riak_kv_entropy_info:compute_exchange_info(),
        {ok, format_exchanges(Raw)}
    catch
        Class:Reason:Stack ->
            logger:error("[riak_admin] aae_status failed: ~p:~p~n~p",
                         [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

%%% ============================================================
%%% Riak version
%%% ============================================================

%% @doc Returns the riak_kv version as a binary.
%% Returns <<"unknown">> if riak_kv is not loaded (e.g., standalone
%% testing). This function lives in the gateway module because it
%% references riak_kv by name, maintaining the isolation contract.
-spec get_riak_version() -> binary().
get_riak_version() ->
    case application:get_key(riak_kv, vsn) of
        {ok, Vsn} -> list_to_binary(Vsn);
        _ -> <<"unknown">>
    end.

%%% ============================================================
%%% Internal helpers
%%% ============================================================

%% @private Proplists:get_value shorthand, defaults to 0.
pv(K, PL) -> proplists:get_value(K, PL, 0).

%% @private Calculate ring percentage, rounded to 2 decimal places.
%% Avoids long floating-point representations like 33.33333333333333
%% in JSON output.
-spec round_pct(non_neg_integer(), non_neg_integer()) -> float().
round_pct(_Count, 0) -> 0.0;
round_pct(Count, Total) ->
    erlang:round((Count / Total) * 10000) / 100.

%% @private Convert any Erlang term to a binary safe for jsx.
%% Riak internals often return charlists (e.g., cluster_name)
%% which jsx cannot encode. This helper normalises them.
-spec to_bin(term()) -> binary().
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_list(V) -> list_to_binary(V);
to_bin(V) -> iolist_to_binary(io_lib:format("~p", [V])).

%% @private Simplify pending_changes tuples for JSON encoding.
%% pending_changes returns complex tuples that jsx cannot encode
%% directly, so we stringify them as a safe fallback.
-spec format_pending(term()) -> [binary()].
format_pending([]) -> [];
format_pending(Changes) when is_list(Changes) ->
    lists:map(fun(Change) ->
        iolist_to_binary(io_lib:format("~p", [Change]))
    end, Changes);
format_pending(_) -> [].

%% @private Format handoff transfer status for JSON.
-spec format_transfers(term()) -> [map()].
format_transfers(Status) when is_list(Status) ->
    lists:filtermap(fun format_one_transfer/1, Status);
format_transfers(_) ->
    [].

%% @private Destructure a single transfer entry.
%% The exact tuple shape depends on the Riak build. Start with
%% a safe string fallback, then refine as real shapes are observed.
format_one_transfer(T) when is_tuple(T) ->
    {true, #{raw => iolist_to_binary(io_lib:format("~p", [T]))}};
format_one_transfer(T) when is_map(T) ->
    {true, T};
format_one_transfer(_) ->
    false.

%% @private Format AAE exchange entries for JSON.
-spec format_exchanges(term()) -> [map()].
format_exchanges(Exchanges) when is_list(Exchanges) ->
    lists:filtermap(fun format_one_exchange/1, Exchanges);
format_exchanges(_) -> [].

%% @private Destructure a single AAE exchange entry.
%% Same defensive pattern as handoff — stringify unknown shapes.
format_one_exchange(Ex) when is_tuple(Ex) ->
    {true, #{raw => iolist_to_binary(io_lib:format("~p", [Ex]))}};
format_one_exchange(Ex) when is_map(Ex) ->
    {true, Ex};
format_one_exchange(_) ->
    false.

%%% ============================================================
%%% DC Discovery (syn-powered)
%%% ============================================================

%% @doc Returns all known DCs from syn group membership.
%% Deduplicates by DC name (keeps first seen for each DC).
-spec list_dcs() -> {ok, [dc_info()]} | {error, term()}.
list_dcs() ->
    try
        LocalDC = riak_admin_api_coordinator:get_dc_name(),
        AllMembers = syn:members(riak_admin, api_nodes),
        DCs = lists:map(fun(Member) -> format_dc_member(Member, LocalDC) end,
                        AllMembers),
        {ok, dedup_by_dc(DCs)}
    catch
        Class:Reason:Stack ->
            logger:error("[riak_admin] list_dcs failed: ~p:~p~n~p",
                         [Class, Reason, Stack]),
            {error, {Class, Reason}}
    end.

%% @doc Returns only remote DCs (different dc_name than local).
%% Used by cluster_status/0 to append remote DC info.
%% Gracefully returns [] on any failure so that cluster_status
%% never breaks due to syn issues.
%%
%% Reuses format_dc_member/2 so the return shape matches dc_info()
%% exactly (same as list_dcs/0).
-spec remote_dcs() -> [dc_info()].
remote_dcs() ->
    try
        LocalDC = riak_admin_api_coordinator:get_dc_name(),
        AllMembers = syn:members(riak_admin, api_nodes),
        AllDCs = lists:map(
            fun(Member) -> format_dc_member(Member, LocalDC) end,
            AllMembers),
        [DC || DC <- dedup_by_dc(AllDCs),
               maps:get(local, DC) =:= false]
    catch
        _:_ -> []   %% Graceful degradation — no remote DCs on failure
    end.

%%% ============================================================
%%% Internal helpers (syn)
%%% ============================================================

%% @private Format a syn group member into a dc_info map.
-spec format_dc_member({pid(), term()}, binary()) -> dc_info().
format_dc_member({_Pid, Meta}, LocalDC) ->
    DC = maps:get(dc, Meta, <<"unknown">>),
    Node = maps:get(node, Meta, unknown),
    Port = maps:get(http_port, Meta, 8099),
    RiakPort = maps:get(riak_http, Meta, 8098),
    Host = node_host(Node),
    #{
        name => DC,
        local => (DC =:= LocalDC),
        admin_url => iolist_to_binary(
            io_lib:format("http://~s:~B", [Host, Port])),
        riak_url => iolist_to_binary(
            io_lib:format("http://~s:~B", [Host, RiakPort])),
        riak_version => maps:get(riak_vsn, Meta, <<"unknown">>),
        node => Node,
        reachable => true,
        started_at => maps:get(started_at, Meta, 0)
    }.

%% @private Extract hostname from node atom.
%% 'riak1@10.0.1.10' -> "10.0.1.10"
-spec node_host(node() | term()) -> string().
node_host(Node) when is_atom(Node) ->
    case string:split(atom_to_list(Node), "@") of
        [_Name, Host] -> Host;
        _ -> "127.0.0.1"
    end;
node_host(_) -> "127.0.0.1".

%% @private Deduplicate DC list by name. Keeps first seen for each DC.
-spec dedup_by_dc([dc_info()]) -> [dc_info()].
dedup_by_dc(DCs) ->
    maps:values(lists:foldl(
        fun(DC, Acc) ->
            Name = maps:get(name, DC),
            case maps:is_key(Name, Acc) of
                true -> Acc;
                false -> maps:put(Name, DC, Acc)
            end
        end, #{}, DCs)).

%%% ============================================================
%%% Tests
%%% ============================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

node_host_test_() ->
    {"node_host extracts hostname from node atoms", [
        {"standard node@host format",
         fun() ->
             ?assertEqual("10.0.1.10", node_host('riak1@10.0.1.10'))
         end},
        {"localhost",
         fun() ->
             ?assertEqual("127.0.0.1", node_host('dev1@127.0.0.1'))
         end},
        {"node without @ falls back to 127.0.0.1",
         fun() ->
             ?assertEqual("127.0.0.1", node_host(nohost))
         end},
        {"non-atom falls back to 127.0.0.1",
         fun() ->
             ?assertEqual("127.0.0.1", node_host("not_an_atom"))
         end}
    ]}.

dedup_by_dc_test_() ->
    {"dedup_by_dc keeps one entry per DC name", [
        {"empty list",
         fun() -> ?assertEqual([], dedup_by_dc([])) end},
        {"single entry",
         fun() ->
             DC = #{name => <<"east">>, node => 'n1@host'},
             ?assertEqual([DC], dedup_by_dc([DC]))
         end},
        {"duplicate names — deduplicates to one entry",
         fun() ->
             DC1 = #{name => <<"east">>, node => 'n1@host'},
             DC2 = #{name => <<"east">>, node => 'n2@host'},
             Result = dedup_by_dc([DC1, DC2]),
             ?assertEqual(1, length(Result)),
             %% First seen wins, but maps:values/1 order is
             %% unspecified — just verify the surviving entry
             %% has the correct DC name.
             ?assertEqual(<<"east">>, maps:get(name, hd(Result)))
         end},
        {"different names — keeps all",
         fun() ->
             DC1 = #{name => <<"east">>, node => 'n1@host'},
             DC2 = #{name => <<"west">>, node => 'n2@host'},
             ?assertEqual(2, length(dedup_by_dc([DC1, DC2])))
         end}
    ]}.

to_bin_test_() ->
    {"to_bin converts various types to binary", [
        {"binary passthrough",
         fun() -> ?assertEqual(<<"hello">>, to_bin(<<"hello">>)) end},
        {"atom conversion",
         fun() -> ?assertEqual(<<"ok">>, to_bin(ok)) end},
        {"list conversion",
         fun() -> ?assertEqual(<<"hello">>, to_bin("hello")) end}
    ]}.

round_pct_test_() ->
    {"round_pct calculates percentages correctly", [
        {"zero total returns 0.0",
         fun() -> ?assertEqual(0.0, round_pct(5, 0)) end},
        {"full ownership",
         fun() -> ?assertEqual(100.0, round_pct(64, 64)) end},
        {"half ownership",
         fun() -> ?assertEqual(50.0, round_pct(32, 64)) end}
    ]}.

format_pending_test_() ->
    {"format_pending handles all input shapes", [
        {"empty list",
         fun() -> ?assertEqual([], format_pending([])) end},
        {"non-list returns empty",
         fun() -> ?assertEqual([], format_pending(not_a_list)) end}
    ]}.

format_transfers_test_() ->
    {"format_transfers handles all input shapes", [
        {"list input",
         fun() -> ?assert(is_list(format_transfers([]))) end},
        {"non-list returns empty",
         fun() -> ?assertEqual([], format_transfers(not_a_list)) end}
    ]}.

format_exchanges_test_() ->
    {"format_exchanges handles all input shapes", [
        {"list input",
         fun() -> ?assert(is_list(format_exchanges([]))) end},
        {"non-list returns empty",
         fun() -> ?assertEqual([], format_exchanges(not_a_list)) end}
    ]}.

-endif.
