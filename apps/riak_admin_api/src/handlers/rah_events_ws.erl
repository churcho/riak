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
%%% - Events arrive as: {"type": "event", "topic": ..., "data": ...}
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
%% Security is wired in Step 4; this skeleton accepts all upgrades.
-spec init(cowboy_req:req(), term()) ->
    {cowboy_websocket, cowboy_req:req(), map()}.
init(Req, _Opts) ->
    IdleTimeout = application:get_env(
        riak_admin_api, ws_idle_timeout, 300000),
    MaxFrameSize = application:get_env(
        riak_admin_api, ws_max_frame_size, 65536),
    WsOpts = #{
        idle_timeout => IdleTimeout,
        max_frame_size => MaxFrameSize
    },
    {cowboy_websocket, Req, #{subscriptions => []}, WsOpts}.

%% @doc Called after the WebSocket handshake completes.
%% Join the syn cluster_events group and send the connected frame.
-spec websocket_init(map()) ->
    {[{text, binary()}], map()}.
websocket_init(State) ->
    join_events_group(),
    ConnectedFrame = jsx:encode(#{
        type => <<"connected">>,
        node => node(),
        topics => riak_admin_api_event_bridge:available_topics(),
        timestamp => erlang:system_time(second)
    }),
    {[{text, ConnectedFrame}], State}.

%% @doc Handle incoming text frames from the client.
-spec websocket_handle({text, binary()} | term(), map()) ->
    {[{text, binary()}], map()} | {ok, map()}.
websocket_handle({text, Raw}, State) ->
    case parse_message(Raw) of
        {ok, Parsed} ->
            dispatch_action(Parsed, State);
        {error, Reason} ->
            Frame = error_frame(<<"invalid_message">>, Reason),
            {[{text, Frame}], State}
    end;
websocket_handle(_Other, State) ->
    {ok, State}.

%% @doc Handle Erlang messages (syn events, etc).
-spec websocket_info(term(), map()) ->
    {[{text, binary()}], map()} | {ok, map()}.
websocket_info({event, Node, {Topic, Data}},
               #{subscriptions := Subs} = State) ->
    case lists:member(Topic, Subs) of
        true ->
            Frame = jsx:encode(#{
                type => <<"event">>,
                topic => Topic,
                node => Node,
                data => Data,
                timestamp => erlang:system_time(second)
            }),
            {[{text, Frame}], State};
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
    ValidTopics = riak_admin_api_event_bridge:available_topics(),
    Requested = [T || T <- Topics, is_binary(T),
                      lists:member(T, ValidTopics)],
    #{subscriptions := Current} = State,
    NewSubs = lists:usort(Current ++ Requested),
    State1 = State#{subscriptions := NewSubs},
    AckFrame = jsx:encode(#{type => <<"subscribed">>,
                            topics => Requested}),
    {[{text, AckFrame}], State1};

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

join_events_group() ->
    try
        syn:join(?SCOPE, ?GROUP_EVENTS, self())
    catch
        _:Err ->
            logger:warning("[riak_admin] WS handler could not join "
                           "cluster_events: ~p", [Err])
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
             State = #{subscriptions => []},
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
             State = #{subscriptions => []},
             Msg = #{<<"action">> => <<"subscribe">>,
                     <<"topics">> => [<<"ring">>, <<"bogus">>]},
             {_Frames, State1} = dispatch_action(Msg, State),
             ?assertEqual([<<"ring">>], maps:get(subscriptions, State1))
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
    {"websocket_info only sends subscribed topics", [
        {"subscribed topic generates frame",
         fun() ->
             State = #{subscriptions => [<<"ring">>]},
             Event = {event, node(), {<<"ring">>, #{test => true}}},
             {Frames, _} = websocket_info(Event, State),
             ?assertEqual(1, length(Frames))
         end},
        {"unsubscribed topic is dropped",
         fun() ->
             State = #{subscriptions => [<<"ring">>]},
             Event = {event, node(), {<<"cluster">>, #{test => true}}},
             Result = websocket_info(Event, State),
             ?assertEqual({ok, State}, Result)
         end}
    ]}.

-endif.
