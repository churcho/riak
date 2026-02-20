%%%-------------------------------------------------------------------
%%% @doc
%%% WebSocket handler for real-time event streaming.
%%%
%%% One connection per browser tab. Clients subscribe to topics and
%%% receive server-pushed events as they happen. Uses the syn
%%% cluster_events group to receive events from the event bridge.
%%%
%%% Protocol:
%%% - Connect: GET /api/stream/events (WebSocket upgrade)
%%% - Subscribe: {"action": "subscribe", "topics": ["ring", ...]}
%%% - Unsubscribe: {"action": "unsubscribe", "topics": ["ring"]}
%%% - Ping: {"action": "ping"}
%%% - Events arrive as pre-encoded JSON: {"type":"event","topic":...,"data":...}
%%% @end
%%%-------------------------------------------------------------------
-module(rah_events_ws).
-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2,
         websocket_info/2, terminate/3]).

-define(SCOPE, riak_admin).
-define(GROUP_EVENTS, cluster_events).

%%% ============================================================
%%% Cowboy callbacks
%%% ============================================================

%% @doc HTTP upgrade to WebSocket.
%% Runs the same security pipeline as admin handlers before upgrading.
%% Failed auth returns a normal HTTP error (no upgrade).
-spec init(cowboy_req:req(), term()) ->
    {cowboy_websocket, cowboy_req:req(), map()} |
    {ok, cowboy_req:req(), term()}.
init(Req, Opts) ->
    case check_security(Req) of
        ok ->
            IdleTimeout = application:get_env(
                riak_admin_api, ws_idle_timeout, 300000),
            MaxFrameSize = application:get_env(
                riak_admin_api, ws_max_frame_size, 65536),
            WsOpts = #{
                idle_timeout => IdleTimeout,
                max_frame_size => MaxFrameSize
            },
            {cowboy_websocket, Req,
             #{subscriptions => [], last_subscribe_ts => undefined}, WsOpts};
        {error, ErrorMap} ->
            Req1 = riak_admin_api_response:reply_error_map(ErrorMap, Req),
            {ok, Req1, Opts}
    end.

%% @doc Called after the WebSocket handshake completes.
%% Join the syn cluster_events group and send the connected frame.
-spec websocket_init(map()) ->
    {[{text, binary()}], map()}.
websocket_init(State) ->
    Live = join_events_group(),
    ConnectedFrame = jsx:encode(#{
        type => <<"connected">>,
        node => node(),
        topics => riak_admin_api_event_bridge:available_topics(),
        live => Live,
        timestamp => erlang:system_time(second)
    }),
    {[{text, ConnectedFrame}], State}.

%% @doc Handle incoming text frames from the client.
-spec websocket_handle({text, binary()} | term(), map()) ->
    {[{text, binary()}], map()} | {ok, map()}.
websocket_handle({text, Raw}, State) ->
    case parse_message(Raw) of
        {ok, Parsed} ->
            try dispatch_action(Parsed, State)
            catch Class:Err:Stack ->
                logger:warning("[riak_admin] WS dispatch crashed: ~p:~p",
                               [Class, Err]),
                logger:debug("[riak_admin] WS dispatch stacktrace: ~p",
                             [Stack]),
                Frame = error_frame(<<"internal_error">>,
                                    <<"Server error processing message">>),
                {[{text, Frame}], State}
            end;
        {error, Reason} ->
            Frame = error_frame(<<"invalid_message">>, Reason),
            {[{text, Frame}], State}
    end;
websocket_handle(_Other, State) ->
    {ok, State}.

%% @doc Handle Erlang messages (syn events, etc).
%%
%% Events arrive as pre-encoded JSON binaries from the local bridge
%% via syn:local_publish. The handler only needs to check the topic
%% against its subscription list and forward the binary — no JSON
%% encoding per subscriber.
%%
%% Includes backpressure: if the message queue exceeds the configured
%% limit, the event is dropped and a warning frame is sent instead.
-spec websocket_info(term(), map()) ->
    {[{text, binary()}], map()} | {ok, map()}.
websocket_info({event_frame, Topic, Frame},
               #{subscriptions := Subs} = State) ->
    case lists:member(Topic, Subs) of
        true ->
            case check_backpressure() of
                ok ->
                    {[{text, Frame}], State};
                {backpressure, QueueLen} ->
                    BpFrame = jsx:encode(#{
                        type => <<"backpressure">>,
                        message_queue_len => QueueLen,
                        dropped_topic => Topic,
                        timestamp => erlang:system_time(second)
                    }),
                    {[{text, BpFrame}], State}
            end;
        false ->
            {ok, State}
    end;
websocket_info(_Info, State) ->
    {ok, State}.

%% @doc Clean up on disconnect. syn removes us from groups automatically.
-spec terminate(term(), cowboy_req:req(), map()) -> ok.
terminate(_Reason, _Req, _State) ->
    ok.

%%% ============================================================
%%% Action dispatch
%%% ============================================================

dispatch_action(#{<<"action">> := <<"subscribe">>,
                  <<"topics">> := Topics}, State)
  when is_list(Topics) ->
    Now = erlang:monotonic_time(millisecond),
    MinInterval = application:get_env(
        riak_admin_api, ws_subscribe_min_interval, 1000),
    LastTs = maps:get(last_subscribe_ts, State, undefined),
    case LastTs =:= undefined orelse Now - LastTs >= MinInterval of
        false ->
            Frame = error_frame(<<"rate_limited">>,
                                <<"Subscribe too frequent, try again shortly">>),
            {[{text, Frame}], State};
        true ->
            ValidTopics = riak_admin_api_event_bridge:available_topics(),
            Requested = [T || T <- Topics, is_binary(T),
                              lists:member(T, ValidTopics)],
            #{subscriptions := Current} = State,
            NewSubs = lists:usort(Current ++ Requested),
            State1 = State#{subscriptions := NewSubs,
                            last_subscribe_ts => Now},
            AckFrame = jsx:encode(#{type => <<"subscribed">>,
                                    topics => Requested}),
            %% Only send snapshots for topics that are genuinely new.
            %% Re-subscribing to an already-active topic is idempotent
            %% but should not trigger a redundant snapshot delivery.
            NewTopics = Requested -- Current,
            SnapshotFrames = snapshot_frames(NewTopics),
            {[{text, AckFrame} | SnapshotFrames], State1}
    end;

dispatch_action(#{<<"action">> := <<"unsubscribe">>,
                  <<"topics">> := Topics}, State)
  when is_list(Topics) ->
    #{subscriptions := Current} = State,
    NewSubs = Current -- Topics,
    State1 = State#{subscriptions := NewSubs},
    AckFrame = jsx:encode(#{type => <<"unsubscribed">>,
                            topics => Topics}),
    {[{text, AckFrame}], State1};

dispatch_action(#{<<"action">> := <<"ping">>}, State) ->
    Frame = jsx:encode(#{type => <<"pong">>,
                         timestamp => erlang:system_time(second)}),
    {[{text, Frame}], State};

dispatch_action(#{<<"action">> := Action}, State)
  when is_binary(Action) ->
    Frame = error_frame(<<"unknown_action">>,
                        <<"Unknown action: ", Action/binary>>),
    {[{text, Frame}], State};

dispatch_action(_, State) ->
    Frame = error_frame(<<"invalid_message">>,
                        <<"Message must have an 'action' field">>),
    {[{text, Frame}], State}.

%%% ============================================================
%%% Internal helpers
%%% ============================================================

snapshot_frames(Topics) ->
    lists:filtermap(
        fun(Topic) ->
            try riak_admin_api_event_bridge:get_snapshot(Topic) of
                {ok, Data} ->
                    Frame = jsx:encode(#{
                        type => <<"snapshot">>,
                        topic => Topic,
                        node => node(),
                        data => Data,
                        timestamp => erlang:system_time(second)
                    }),
                    {true, {text, Frame}};
                {error, _} ->
                    false
            catch
                exit:{noproc, _} -> false;
                _:_ -> false
            end
        end, Topics).

check_security(Req) ->
    Opts = #{
        require_tls => application:get_env(
            riak_admin_api, security_require_tls, false),
        trust_proxy_headers => application:get_env(
            riak_admin_api, security_trust_proxy_headers, false),
        trusted_origins => application:get_env(
            riak_admin_api, security_trusted_origins, []),
        require_auth => application:get_env(
            riak_admin_api, security_require_auth, false),
        authn_fun => application:get_env(
            riak_admin_api, authn_hook, undefined),
        authz_fun => application:get_env(
            riak_admin_api, authz_hook, undefined)
    },
    Headers = case Req of
        #{headers := H} when is_map(H) -> H;
        _ -> #{}
    end,
    {ok, HeaderMeta} = riak_admin_api_request:normalize_headers(Headers),
    RequestId = maps:get(request_id, HeaderMeta),
    NormHeaders = maps:remove(request_id, HeaderMeta),
    Context = #{
        method => <<"GET">>,
        headers => NormHeaders,
        route => <<"/api/stream/events">>,
        op => admin
    },
    case riak_admin_api_request:ensure_security(Context, Opts) of
        ok -> ok;
        {error, Error} -> {error, Error#{request_id => RequestId}}
    end.

check_backpressure() ->
    Limit = application:get_env(
        riak_admin_api, ws_backpressure_limit, 100),
    case process_info(self(), message_queue_len) of
        {message_queue_len, Len} when Len > Limit ->
            {backpressure, Len};
        _ ->
            ok
    end.

join_events_group() ->
    try
        case syn:join(?SCOPE, ?GROUP_EVENTS, self()) of
            ok ->
                true;
            {error, JoinErr} ->
                logger:warning("[riak_admin] WS handler failed to join "
                               "cluster_events: ~p", [JoinErr]),
                false
        end
    catch
        _:Err ->
            logger:warning("[riak_admin] WS handler could not join "
                           "cluster_events: ~p", [Err]),
            false
    end.

parse_message(Raw) ->
    try
        case jsx:decode(Raw, [return_maps]) of
            Map when is_map(Map) -> {ok, Map};
            _ -> {error, <<"Message must be a JSON object">>}
        end
    catch
        _:_ -> {error, <<"Invalid JSON">>}
    end.

error_frame(Code, Reason) ->
    jsx:encode(#{type => <<"error">>, code => Code, reason => Reason}).

%%% ============================================================
%%% Tests
%%% ============================================================

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

parse_message_test_() ->
    {"parse_message handles valid and invalid JSON", [
        {"valid object",
         fun() ->
             {ok, Map} = parse_message(<<"{\"action\":\"ping\"}">>),
             ?assertEqual(<<"ping">>, maps:get(<<"action">>, Map))
         end},
        {"invalid JSON returns error",
         fun() ->
             {error, _} = parse_message(<<"not json">>)
         end},
        {"JSON array returns error",
         fun() ->
             {error, _} = parse_message(<<"[1,2,3]">>)
         end}
    ]}.

error_frame_test_() ->
    {"error_frame produces valid JSON",
     fun() ->
         Frame = error_frame(<<"test_code">>, <<"test reason">>),
         Decoded = jsx:decode(Frame, [return_maps]),
         ?assertEqual(<<"error">>, maps:get(<<"type">>, Decoded)),
         ?assertEqual(<<"test_code">>, maps:get(<<"code">>, Decoded)),
         ?assertEqual(<<"test reason">>, maps:get(<<"reason">>, Decoded))
     end}.

dispatch_subscribe_test_() ->
    {"subscribe adds valid topics to state", [
        {"valid topics get added",
         fun() ->
             State = #{subscriptions => [], last_subscribe_ts => undefined},
             Msg = #{<<"action">> => <<"subscribe">>,
                     <<"topics">> => [<<"ring">>, <<"cluster">>]},
             {Frames, State1} = dispatch_action(Msg, State),
             ?assertEqual([<<"cluster">>, <<"ring">>],
                          maps:get(subscriptions, State1)),
             ?assertEqual(1, length(Frames)),
             {text, Json} = hd(Frames),
             Decoded = jsx:decode(Json, [return_maps]),
             ?assertEqual(<<"subscribed">>, maps:get(<<"type">>, Decoded))
         end},
        {"invalid topics are filtered out",
         fun() ->
             State = #{subscriptions => [], last_subscribe_ts => undefined},
             Msg = #{<<"action">> => <<"subscribe">>,
                     <<"topics">> => [<<"ring">>, <<"bogus">>]},
             {_Frames, State1} = dispatch_action(Msg, State),
             ?assertEqual([<<"ring">>], maps:get(subscriptions, State1))
         end},
        {"re-subscribing to already subscribed topic is idempotent",
         fun() ->
             State = #{subscriptions => [<<"ring">>], last_subscribe_ts => undefined},
             Msg = #{<<"action">> => <<"subscribe">>,
                     <<"topics">> => [<<"ring">>, <<"cluster">>]},
             {Frames, State1} = dispatch_action(Msg, State),
             ?assertEqual([<<"cluster">>, <<"ring">>],
                          maps:get(subscriptions, State1)),
             {text, AckJson} = hd(Frames),
             AckDecoded = jsx:decode(AckJson, [return_maps]),
             ?assertEqual(<<"subscribed">>, maps:get(<<"type">>, AckDecoded)),
             AckTopics = maps:get(<<"topics">>, AckDecoded),
             ?assert(lists:member(<<"ring">>, AckTopics)),
             ?assert(lists:member(<<"cluster">>, AckTopics))
         end},
        {"rapid subscribe is rate limited",
         fun() ->
             application:set_env(riak_admin_api, ws_subscribe_min_interval, 5000),
             %% First subscribe succeeds
             State0 = #{subscriptions => [], last_subscribe_ts => undefined},
             Msg = #{<<"action">> => <<"subscribe">>,
                     <<"topics">> => [<<"ring">>]},
             {_, State1} = dispatch_action(Msg, State0),
             ?assertEqual([<<"ring">>], maps:get(subscriptions, State1)),
             %% Immediate second subscribe is rejected
             Msg2 = #{<<"action">> => <<"subscribe">>,
                      <<"topics">> => [<<"cluster">>]},
             {Frames2, State2} = dispatch_action(Msg2, State1),
             %% Subscriptions unchanged
             ?assertEqual([<<"ring">>], maps:get(subscriptions, State2)),
             {text, Json} = hd(Frames2),
             Decoded = jsx:decode(Json, [return_maps]),
             ?assertEqual(<<"error">>, maps:get(<<"type">>, Decoded)),
             ?assertEqual(<<"rate_limited">>, maps:get(<<"code">>, Decoded)),
             application:unset_env(riak_admin_api, ws_subscribe_min_interval)
         end}
    ]}.

dispatch_unsubscribe_test_() ->
    {"unsubscribe removes topics from state",
     fun() ->
         State = #{subscriptions => [<<"ring">>, <<"cluster">>]},
         Msg = #{<<"action">> => <<"unsubscribe">>,
                 <<"topics">> => [<<"ring">>]},
         {Frames, State1} = dispatch_action(Msg, State),
         ?assertEqual([<<"cluster">>], maps:get(subscriptions, State1)),
         ?assertEqual(1, length(Frames)),
         {text, Json} = hd(Frames),
         Decoded = jsx:decode(Json, [return_maps]),
         ?assertEqual(<<"unsubscribed">>, maps:get(<<"type">>, Decoded))
     end}.

dispatch_ping_test_() ->
    {"ping returns pong",
     fun() ->
         State = #{subscriptions => []},
         Msg = #{<<"action">> => <<"ping">>},
         {Frames, _State1} = dispatch_action(Msg, State),
         {text, Json} = hd(Frames),
         Decoded = jsx:decode(Json, [return_maps]),
         ?assertEqual(<<"pong">>, maps:get(<<"type">>, Decoded)),
         ?assert(is_integer(maps:get(<<"timestamp">>, Decoded)))
     end}.

dispatch_unknown_action_test_() ->
    {"unknown action returns error frame",
     fun() ->
         State = #{subscriptions => []},
         Msg = #{<<"action">> => <<"explode">>},
         {Frames, _} = dispatch_action(Msg, State),
         {text, Json} = hd(Frames),
         Decoded = jsx:decode(Json, [return_maps]),
         ?assertEqual(<<"error">>, maps:get(<<"type">>, Decoded)),
         ?assertEqual(<<"unknown_action">>, maps:get(<<"code">>, Decoded))
     end}.

websocket_info_filters_by_subscription_test_() ->
    {"websocket_info forwards pre-encoded frames for subscribed topics", [
        {"subscribed topic forwards the pre-encoded frame",
         fun() ->
             State = #{subscriptions => [<<"ring">>]},
             Frame = jsx:encode(#{type => <<"event">>, topic => <<"ring">>,
                                  data => #{test => true}}),
             Event = {event_frame, <<"ring">>, Frame},
             {Frames, _} = websocket_info(Event, State),
             ?assertEqual(1, length(Frames)),
             %% The frame is forwarded as-is, no re-encoding
             {text, Received} = hd(Frames),
             ?assertEqual(Frame, Received)
         end},
        {"unsubscribed topic is dropped",
         fun() ->
             State = #{subscriptions => [<<"ring">>]},
             Frame = jsx:encode(#{type => <<"event">>, topic => <<"cluster">>}),
             Event = {event_frame, <<"cluster">>, Frame},
             Result = websocket_info(Event, State),
             ?assertEqual({ok, State}, Result)
         end}
    ]}.

check_backpressure_test_() ->
    {"backpressure check works under normal conditions",
     fun() ->
         %% Under normal test conditions, queue is short
         ?assertEqual(ok, check_backpressure())
     end}.

check_backpressure_with_low_limit_test_() ->
    {"backpressure triggers when limit is very low",
     fun() ->
         %% Set limit to 0 so any queue triggers backpressure
         application:set_env(riak_admin_api, ws_backpressure_limit, 0),
         %% Send ourselves a message to ensure queue > 0
         self() ! test_message,
         Result = check_backpressure(),
         %% Clean up
         receive test_message -> ok after 0 -> ok end,
         application:unset_env(riak_admin_api, ws_backpressure_limit),
         ?assertMatch({backpressure, _}, Result)
     end}.

check_security_no_auth_required_test_() ->
    {"security check passes when auth is not required",
     fun() ->
         application:set_env(riak_admin_api, security_require_auth, false),
         application:set_env(riak_admin_api, security_require_tls, false),
         Req = #{headers => #{}},
         ?assertEqual(ok, check_security(Req)),
         application:unset_env(riak_admin_api, security_require_auth),
         application:unset_env(riak_admin_api, security_require_tls)
     end}.

check_security_rejects_when_auth_required_no_hooks_test_() ->
    {"security check rejects when auth is required but no hooks configured",
     fun() ->
         application:set_env(riak_admin_api, security_require_auth, true),
         application:unset_env(riak_admin_api, authn_hook),
         application:unset_env(riak_admin_api, authz_hook),
         Req = #{headers => #{}},
         Result = check_security(Req),
         application:set_env(riak_admin_api, security_require_auth, false),
         ?assertMatch({error, _}, Result)
     end}.

websocket_handle_catches_dispatch_crash_test_() ->
    {"websocket_handle returns error frame instead of crashing on dispatch failure",
     fun() ->
         %% Force a crash by passing a state that's missing the
         %% 'subscriptions' key — dispatch_action will crash on
         %% pattern match #{subscriptions := Current}.
         Raw = <<"{\"action\":\"subscribe\",\"topics\":[\"ring\"]}">>,
         BadState = #{last_subscribe_ts => undefined},
         {Frames, State1} = websocket_handle({text, Raw}, BadState),
         %% State unchanged — crash was caught
         ?assertEqual(BadState, State1),
         {text, Json} = hd(Frames),
         Decoded = jsx:decode(Json, [return_maps]),
         ?assertEqual(<<"error">>, maps:get(<<"type">>, Decoded)),
         ?assertEqual(<<"internal_error">>, maps:get(<<"code">>, Decoded))
     end}.

join_events_group_returns_boolean_test_() ->
    {"join_events_group returns false when syn is not running",
     fun() ->
         %% syn is not initialized in eunit, so join should fail gracefully
         Result = join_events_group(),
         ?assertEqual(false, Result)
     end}.

-endif.
