%% @doc Shared test helpers for riak_admin_api EUnit suites.
%%
%% Extracted patterns:
%% - receive_response_for_stream/1: cowboy_req-style response receive
%% - with_app_env/3, with_app_envs/2: temporary application env overrides

-module(riak_admin_api_test_helpers).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

%% @doc Receive a cowboy_req response for the given stream ID.
%% Waits up to 500ms for a {response, Status, Headers, Body} message.
receive_response_for_stream(StreamID) ->
    Pid = self(),
    receive
        {{Pid, StreamID}, {response, Status, Headers, Body}} ->
            {Status, Headers, Body}
    after 500 ->
        error({timeout_waiting_for_stream_response, StreamID})
    end.

%% @doc Temporarily set a single application env key for the duration of Fun.
%% Use `unset' as Value to remove the key during the test.
%% All keys are under the riak_admin_api application.
%% Original values are restored in the after clause, even on test failure.
with_app_env(Key, Value, Fun) ->
    with_app_envs([{Key, Value}], Fun).

%% @doc Temporarily override multiple application env keys for the duration of Fun.
%% Each override is {Key, Value} or {Key, unset}.
%% All keys are under the riak_admin_api application.
%% Original values are restored in the after clause, even on test failure.
with_app_envs(Overrides, Fun) ->
    OldVals = [{Key, application:get_env(riak_admin_api, Key)} || {Key, _} <- Overrides],
    lists:foreach(fun
        ({Key, unset}) -> application:unset_env(riak_admin_api, Key);
        ({Key, Val}) -> application:set_env(riak_admin_api, Key, Val)
    end, Overrides),
    try
        Fun()
    after
        lists:foreach(fun
            ({Key, undefined}) -> application:unset_env(riak_admin_api, Key);
            ({Key, {ok, V}}) -> application:set_env(riak_admin_api, Key, V)
        end, OldVals)
    end.
