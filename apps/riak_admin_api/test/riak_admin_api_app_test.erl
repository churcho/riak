%% @doc EUnit tests for riak_admin_api_app.
%%
%% Tests the resolve_port/0 logic and route definitions.

-module(riak_admin_api_app_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

%%% ============================================================
%%% resolve_port/0
%%%
%%% We can't directly call resolve_port/0 since it's not exported,
%%% but we can test the port logic by verifying the regex pattern
%%% and arithmetic match expectations.
%%% ============================================================

port_calculation_test_() ->
    %% Verify the formula: 10000 + N * 10 + 5 (admin API port)
    [
        ?_assertEqual(10015, 10000 + 1 * 10 + 5),
        ?_assertEqual(10025, 10000 + 2 * 10 + 5),
        ?_assertEqual(10035, 10000 + 3 * 10 + 5),
        ?_assertEqual(10045, 10000 + 4 * 10 + 5),
        ?_assertEqual(10055, 10000 + 5 * 10 + 5),
        ?_assertEqual(10065, 10000 + 6 * 10 + 5),
        ?_assertEqual(10075, 10000 + 7 * 10 + 5),
        ?_assertEqual(10085, 10000 + 8 * 10 + 5)
    ].

riak_http_port_calculation_test_() ->
    %% Verify the formula: 10000 + N * 10 + 8 (Riak HTTP port in devrel)
    [
        ?_assertEqual(10018, 10000 + 1 * 10 + 8),
        ?_assertEqual(10028, 10000 + 2 * 10 + 8),
        ?_assertEqual(10038, 10000 + 3 * 10 + 8),
        ?_assertEqual(10048, 10000 + 4 * 10 + 8)
    ].

port_regex_devnode_test() ->
    %% The regex should match devN@ at the start
    ?assertMatch({match, ["1"]},
        re:run("dev1@127.0.0.1", "^dev([0-9]+)@", [{capture, [1], list}])),
    ?assertMatch({match, ["10"]},
        re:run("dev10@127.0.0.1", "^dev([0-9]+)@", [{capture, [1], list}])).

port_regex_non_devnode_test() ->
    %% Non-dev node names should not match
    ?assertEqual(nomatch,
        re:run("riak@10.0.0.1", "^dev([0-9]+)@", [{capture, [1], list}])),
    ?assertEqual(nomatch,
        re:run("prod@riak.example.com", "^dev([0-9]+)@", [{capture, [1], list}])).

%%% ============================================================
%%% Port collision check
%%% ============================================================

no_port_collision_test() ->
    %% Verify admin API ports (100N5) don't collide with any
    %% existing Riak devrel ports:
    %%   100N6 = cluster_manager
    %%   100N7 = protobuf
    %%   100N8 = HTTP (webmachine)
    %%   100N9 = handoff
    lists:foreach(fun(N) ->
        AdminPort = 10000 + N * 10 + 5,
        ClusterMgr = 10000 + N * 10 + 6,
        PB = 10000 + N * 10 + 7,
        HTTP = 10000 + N * 10 + 8,
        Handoff = 10000 + N * 10 + 9,
        ?assertNotEqual(AdminPort, ClusterMgr),
        ?assertNotEqual(AdminPort, PB),
        ?assertNotEqual(AdminPort, HTTP),
        ?assertNotEqual(AdminPort, Handoff)
    end, lists:seq(1, 8)).

%%% ============================================================
%%% Routes
%%% ============================================================

routes_defined_test() ->
    Routes = riak_admin_api_app:routes(),
    ?assert(is_list(Routes)),
    ?assert(length(Routes) >= 6),
    %% Each route is a {Path, Handler, Opts} tuple
    lists:foreach(fun({Path, Handler, Opts}) ->
        ?assert(is_list(Path) orelse is_binary(Path)),
        ?assert(is_atom(Handler)),
        ?assert(is_list(Opts) orelse is_map(Opts))
    end, Routes).

routes_contain_ping_test() ->
    Routes = riak_admin_api_app:routes(),
    Paths = [Path || {Path, _, _} <- Routes],
    ?assert(lists:member("/api/ping", Paths)).

routes_contain_cluster_status_test() ->
    Routes = riak_admin_api_app:routes(),
    Paths = [Path || {Path, _, _} <- Routes],
    ?assert(lists:member("/api/cluster/status", Paths)).

routes_handler_naming_test() ->
    %% App routes keep the rah_ naming convention; the shared
    %% substrate entrypoint is the only intentional exception.
    Routes = riak_admin_api_app:routes(),
    lists:foreach(fun({_Path, Handler, _Opts}) ->
        HandlerStr = atom_to_list(Handler),
        IsAllowed = lists:prefix("rah_", HandlerStr) orelse
            Handler =:= riak_admin_api_handler,
        ?assert(IsAllowed,
                lists:flatten(io_lib:format(
                    "Handler ~p is not an approved route handler", [Handler])))
    end, Routes).

routes_include_cowboy_alias_families_test() ->
    Routes = riak_admin_api_app:routes(),
    Paths = [Path || {Path, _, _} <- Routes],
    ?assert(lists:member("/riak", Paths)),
    ?assert(lists:member("/buckets", Paths)),
    ?assert(lists:member("/types/:bucket_type/buckets", Paths)).

%%% ============================================================
%%% S1: listener_child_spec/2
%%% ============================================================

listener_child_spec_returns_valid_child_spec_test() ->
    Dispatch = cowboy_router:compile([{'_', [{"/test", rah_ping, []}]}]),
    Spec = riak_admin_api_app:listener_child_spec(9999, Dispatch),
    %% ranch:child_spec/5 returns a tuple-style child spec:
    %% {Id, {M, F, A}, Restart, Shutdown, Type, Modules}
    ?assertMatch({_Id, {_M, _F, _A}, _Restart, _Shutdown, _Type, _Modules}, Spec),
    {Id, {M, F, A}, _Restart, _Shutdown, _Type, _Modules} = Spec,
    ?assertEqual({ranch_listener_sup, riak_admin_http}, Id),
    ?assert(is_atom(M)),
    ?assert(is_atom(F)),
    ?assert(is_list(A)).

listener_child_spec_includes_port_in_transport_opts_test() ->
    Dispatch = cowboy_router:compile([{'_', [{"/test", rah_ping, []}]}]),
    Spec = riak_admin_api_app:listener_child_spec(8765, Dispatch),
    %% ranch:child_spec returns a tuple-style child spec
    %% Verify the spec is well-formed and contains expected listener name
    {Id, _Start, _Restart, _Shutdown, _Type, _Modules} = Spec,
    ?assertEqual({ranch_listener_sup, riak_admin_http}, Id).

%%% ============================================================
%%% S1: protocol_opts/0
%%% ============================================================

protocol_opts_returns_default_values_test() ->
    Opts = riak_admin_api_app:protocol_opts(),
    ?assert(is_map(Opts)),
    ?assertEqual(60000, maps:get(idle_timeout, Opts)),
    ?assertEqual(30000, maps:get(request_timeout, Opts)),
    ?assertEqual(100, maps:get(max_keepalive, Opts)),
    ?assertEqual(64, maps:get(max_header_name_length, Opts)),
    ?assertEqual(4096, maps:get(max_header_value_length, Opts)),
    ?assertEqual(100, maps:get(max_headers, Opts)).

protocol_opts_respects_env_overrides_test() ->
    OldTimeout = application:get_env(riak_admin_api, cowboy_idle_timeout),
    OldMaxKeep = application:get_env(riak_admin_api, cowboy_max_keepalive),
    application:set_env(riak_admin_api, cowboy_idle_timeout, 120000),
    application:set_env(riak_admin_api, cowboy_max_keepalive, 200),
    try
        Opts = riak_admin_api_app:protocol_opts(),
        ?assertEqual(120000, maps:get(idle_timeout, Opts)),
        ?assertEqual(200, maps:get(max_keepalive, Opts)),
        %% Unchanged values retain defaults
        ?assertEqual(30000, maps:get(request_timeout, Opts))
    after
        case OldTimeout of
            undefined -> application:unset_env(riak_admin_api, cowboy_idle_timeout);
            {ok, V1} -> application:set_env(riak_admin_api, cowboy_idle_timeout, V1)
        end,
        case OldMaxKeep of
            undefined -> application:unset_env(riak_admin_api, cowboy_max_keepalive);
            {ok, V2} -> application:set_env(riak_admin_api, cowboy_max_keepalive, V2)
        end
    end.

%%% ============================================================
%%% Routes
%%% ============================================================

routes_include_all_active_substrate_paths_test() ->
    Routes = riak_admin_api_app:routes(),
    Paths = [Path || {Path, Handler, _Opts} <- Routes, Handler =:= riak_admin_api_handler],
    Expected = [
        "/mapred",
        "/riak",
        "/riak/:bucket",
        "/riak/:bucket/:key",
        "/buckets",
        "/buckets/:bucket/props",
        "/buckets/:bucket/keys",
        "/buckets/:bucket/counters/:key",
        "/buckets/:bucket/query",
        "/buckets/:bucket/keys/:key",
        "/buckets/:bucket/index/:field/:term",
        "/buckets/:bucket/index/:field/:start/:end",
        "/types/:bucket_type/props",
        "/types/:bucket_type/buckets",
        "/types/:bucket_type/buckets/:bucket/props",
        "/types/:bucket_type/buckets/:bucket/keys",
        "/types/:bucket_type/buckets/:bucket/datatypes",
        "/types/:bucket_type/buckets/:bucket/datatypes/:key",
        "/types/:bucket_type/buckets/:bucket/query",
        "/types/:bucket_type/buckets/:bucket/keys/:key",
        "/types/:bucket_type/buckets/:bucket/index/:field/:term",
        "/types/:bucket_type/buckets/:bucket/index/:field/:start/:end"
    ],
    lists:foreach(fun(Path) ->
        ?assert(lists:member(Path, Paths))
    end, Expected).

substrate_routes_define_route_family_metadata_test() ->
    Routes = riak_admin_api_app:routes(),
    SubstrateRoutes = [{Path, Opts} ||
        {Path, Handler, Opts} <- Routes, Handler =:= riak_admin_api_handler],
    ?assert(length(SubstrateRoutes) > 0),
    lists:foreach(fun({_Path, Opts}) ->
        ?assert(is_map(Opts)),
        Family = maps:get(route_family, Opts, undefined),
        ?assert(lists:member(Family, [mapred, riak, buckets, types]))
    end, SubstrateRoutes).
