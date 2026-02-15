%% @doc Health-check handler for the Riak Admin API.
%%
%% Serves GET /api/ping and returns a JSON response indicating
%% that the admin API is running and identifying which Erlang node
%% is handling the request:
%%
%% ```
%% $ curl http://127.0.0.1:8099/api/ping
%% {"status":"ok","node":"dev1@127.0.0.1"}
%% '''
%%
%% This is the simplest handler — it doesn't go through the
%% gateway module because it doesn't need Riak data. It only
%% reports that Cowboy is alive and which node is responding.
%%
%% == Handler naming convention ==
%%
%% All admin API handler modules use the `rah_' prefix (Riak
%% Admin Handler). This keeps handler names short in dispatch
%% rules while avoiding collisions with Riak's existing modules.

-module(rah_ping).
-export([init/2]).

%% @doc Cowboy handler callback.
%%
%% Returns a 200 JSON response with the node name and status.
%% Uses riak_admin_api_handler:json_reply/3 for consistent
%% response formatting across all endpoints.
-spec init(cowboy_req:req(), term()) -> {ok, cowboy_req:req(), term()}.
init(Req0, State) ->
    Req = riak_admin_api_handler:json_reply(200,
        #{status => <<"ok">>, node => node()}, Req0),
    {ok, Req, State}.
