%% @doc Gateway module: ALL calls to riak_core, riak_kv, and
%% riak_object go through this module exclusively.
%%
%% No other module in riak_admin_api may call Riak internals
%% directly. This is the cornerstone of the isolation pattern
%% that keeps the admin API's surface area contained.
%%
%% == Why this matters ==
%%
%% <ul>
%%   <li>The .app.src never lists riak_core or riak_kv as
%%       `applications' dependencies — they are resolved at
%%       runtime only.</li>
%%   <li>Every handler is testable in isolation — swap this
%%       gateway for a mock and Cowboy still works.</li>
%%   <li>Extraction to a standalone repo requires copying the
%%       directory and providing riak_kv headers at compile
%%       time (see compile-time dependency note below).</li>
%% </ul>
%%
%% == Compile-time dependency note ==
%%
%% This module has compile-time dependencies on riak_kv headers:
%%   - riak_kv/src/riak_kv_wm_raw.hrl  (JSON field macros)
%%   - riak_kv/include/riak_kv_index.hrl (index query macros)
%%   - riak_kv/include/riak_kv_types.hrl (CRDT record defs)
%%
%% These -include_lib directives mean `rebar3 compile' requires
%% riak_kv source to be present on the code path. The runtime
%% isolation principle still holds: no module other than this
%% gateway calls riak_kv functions directly.
%%
%% Future work: replace these include_lib dependencies with
%% locally defined records/macros to achieve full compile-time
%% isolation.
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
    object_operation/3,
    bucket_operation/3,
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
    dedup_by_dc/1,
    object_error_map/1,
    build_object_options/3,
    build_location/2,
    counter_delta_from_body/1,
    crdt_decode_update_body/2,
    crdt_response_body/4,
    accept_doc_value/2,
    %% S5 test exports
    encode_stream_error/1,
    %% S1 test exports
    parallel_ping_nodes/2,
    mapred_timeout_error_map/0,
    list_keys_error_mode/0,
    stream_collection_ceiling/0,
    %% S2 test exports
    stream_incremental_enabled/0,
    mapred_backend_enabled/0,
    check_write_preconditions/3,
    maybe_crdt_collection_redirect/1
]).
-endif.

-include_lib("riak_kv/src/riak_kv_wm_raw.hrl").
-include_lib("riak_kv/include/riak_kv_index.hrl").
-include_lib("riak_kv/include/riak_kv_types.hrl").

-define(USERMETA_PREFIX, <<"x-riak-meta-">>).
-define(INDEX_PREFIX, <<"x-riak-index-">>).
-define(DEFAULT_BUCKET_LIST_TIMEOUT, 5 * 60000).
-define(DEFAULT_KEY_STREAM_TIMEOUT, 5000).
-define(QUERY_DEFAULT_TIMEOUT_SECS, 60).
-define(QUERY_CONTINUATION_HEADER, <<"x-riak-continuation">>).
-define(QUERY_KEY_AGGREGATION_EXPRESSION, <<"aggregation_expression">>).
-define(QUERY_KEY_ACCUMULATION_OPTION, <<"accumulation_option">>).
-define(QUERY_KEY_ACCUMULATION_TERM, <<"accumulation_term">>).
-define(QUERY_KEY_SUBSTITUTIONS, <<"substitutions">>).
-define(QUERY_KEY_TIMEOUT, <<"timeout">>).
-define(QUERY_KEY_MAX_RESULTS, <<"max_results">>).
-define(QUERY_KEY_CONTINUATION, <<"continuation">>).
-define(QUERY_KEY_QUERY_LIST, <<"query_list">>).
-define(QUERY_KEY_QL_AGGREGATION_TAG, <<"aggregation_tag">>).
-define(QUERY_KEY_QL_INDEX_NAME, <<"index_name">>).
-define(QUERY_KEY_QL_START_TERM, <<"start_term">>).
-define(QUERY_KEY_QL_END_TERM, <<"end_term">>).
-define(QUERY_KEY_QL_REGULAR_EXPRESSION, <<"regular_expression">>).
-define(QUERY_KEY_QL_EVALUATION_EXPRESSION, <<"evaluation_expression">>).
-define(QUERY_KEY_QL_FILTER_EXPRESSION, <<"filter_expression">>).
-define(QUERY_RESULT_KEYS, <<"keys">>).
-define(QUERY_RESULT_TERMS, <<"terms">>).
-define(QUERY_RESULT_COUNT, <<"count">>).
-define(QUERY_RESULT_TERMCOUNT, <<"term_with_count">>).
-define(QUERY_RESULT_RAWKEYS, <<"raw_keys">>).
-define(QUERY_RESULT_RAWTERMS, <<"raw_terms">>).
-define(QUERY_RESULT_RAWCOUNT, <<"raw_count">>).
-define(QUERY_RESULT_TERMRAWCOUNT, <<"term_with_rawcount">>).
-define(MAPRED_KEY_INPUTS, <<"inputs">>).
-define(MAPRED_KEY_QUERY, <<"query">>).
-define(COUNTER_BUCKET_TYPE, <<"counters">>).

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
%%% Object CRUD Gateway (B02)
%%% ============================================================

-spec object_operation(get | put | post | delete | create, map(), map()) ->
    {ok, map()} | {error, map()}.
object_operation(Action, Context, Input) ->
    case ensure_bucket_type(Context) of
        ok ->
            with_object_client(
                fun(Client) -> object_operation(Action, Context, Input, Client) end);
        {error, Error} ->
            {error, Error}
    end.

object_operation(get, Context, Input, Client) ->
    object_get(Context, Input, Client);
object_operation(put, Context, Input, Client) ->
    object_store(put, Context, Input, Client);
object_operation(post, Context, Input, Client) ->
    object_store(post, Context, Input, Client);
object_operation(create, Context, Input, Client) ->
    object_store(create, Context, Input, Client);
object_operation(delete, Context, Input, Client) ->
    object_delete(Context, Input, Client);
object_operation(_, _Context, _Input, _Client) ->
    {error, #{
        status => 400,
        code => <<"invalid_operation">>,
        reason => <<"Unsupported object operation">>
    }}.

-spec bucket_operation(
    get_bucket_props |
    set_bucket_props |
    delete_bucket_props |
    get_bucket_type_props |
    set_bucket_type_props |
    list_buckets |
    list_keys |
    counter_get |
    counter_update |
    crdt_fetch |
    crdt_update |
    crdt_create |
    index_query |
    query |
    mapred,
    map(),
    map()) -> {ok, map()} | {error, map()} | {stream, map(), function()}.
bucket_operation(Action, Context, Input) ->
    case ensure_bucket_type(Context) of
        ok ->
            with_object_client(
                fun(Client) -> bucket_operation(Action, Context, Input, Client) end);
        {error, Error} ->
            {error, Error}
    end.

bucket_operation(get_bucket_props, Context, _Input, Client) ->
    BucketRef = bucket_props_ref(Context),
    Props = riak_client:get_bucket(BucketRef, Client),
    JsonProps = lists:map(fun riak_kv_wm_utils:jsonify_bucket_prop/1, Props),
    Body = mochijson2:encode({struct, [{?JSON_PROPS, {struct, JsonProps}}]}),
    {ok, json_backend_reply(200, Body)};
bucket_operation(set_bucket_props, Context, Input, Client) ->
    case extract_bucket_props(Input) of
        {ok, Props} ->
            ErlProps = lists:map(fun riak_kv_wm_utils:erlify_bucket_prop/1, Props),
            case riak_client:set_bucket(bucket_props_ref(Context), ErlProps, Client) of
                ok ->
                    {ok, json_backend_reply(204, <<>>)};
                {error, Details} ->
                    {error, bucket_error_map({invalid_props, Details})}
            end;
        {error, Error} ->
            {error, Error}
    end;
bucket_operation(delete_bucket_props, Context, _Input, Client) ->
    case riak_client:reset_bucket(bucket_props_ref(Context), Client) of
        ok ->
            {ok, json_backend_reply(204, <<>>)};
        {error, Details} ->
            {error, bucket_error_map({invalid_props, Details})}
    end;
bucket_operation(get_bucket_type_props, Context, _Input, _Client) ->
    Type = maps:get(bucket_type, Context, <<"default">>),
    case riak_core_bucket_type:get(Type) of
        undefined ->
            {error, object_error_map(bucket_type_unknown)};
        Props ->
            JsonProps = [riak_kv_wm_utils:jsonify_bucket_prop(P) || P <- Props],
            Body = mochijson2:encode({struct, [{?JSON_PROPS, {struct, JsonProps}}]}),
            {ok, json_backend_reply(200, Body)}
    end;
bucket_operation(set_bucket_type_props, Context, Input, _Client) ->
    case extract_bucket_props(Input) of
        {ok, Props} ->
            ErlProps = lists:map(fun riak_kv_wm_utils:erlify_bucket_prop/1, Props),
            Type = maps:get(bucket_type, Context, <<"default">>),
            case riak_core_bucket_type:update(Type, ErlProps) of
                ok ->
                    {ok, json_backend_reply(204, <<>>)};
                {error, Details} ->
                    {error, bucket_error_map({invalid_props, Details})}
            end;
        {error, Error} ->
            {error, Error}
    end;
bucket_operation(list_buckets, Context, _Input, Client) ->
    bucket_list_operation(Context, Client);
bucket_operation(list_keys, Context, _Input, Client) ->
    key_list_operation(Context, Client);
bucket_operation(counter_get, Context, _Input, Client) ->
    counter_get_operation(Context, Client);
bucket_operation(counter_update, Context, Input, Client) ->
    counter_update_operation(Context, Input, Client);
bucket_operation(crdt_fetch, Context, _Input, Client) ->
    crdt_fetch_operation(Context, Client);
bucket_operation(crdt_update, Context, Input, Client) ->
    crdt_update_operation(update, Context, Input, Client);
bucket_operation(crdt_create, Context, Input, Client) ->
    crdt_update_operation(create, Context, Input, Client);
bucket_operation(index_query, Context, _Input, Client) ->
    index_operation(Context, Client);
bucket_operation(query, Context, Input, Client) ->
    query_operation(Context, Input, Client);
bucket_operation(mapred, Context, Input, Client) ->
    mapred_operation(Context, Input, Client);
bucket_operation(_, _Context, _Input, _Client) ->
    {error, #{
        status => 400,
        code => <<"invalid_operation">>,
        reason => <<"Unsupported bucket operation">>
    }}.

object_get(Context, Input, Client) ->
    BucketRef = bucket_ref(Context),
    Key = maps:get(key, Context, undefined),
    Query = maps:get(query, Context, #{}),
    Options = build_object_options(read, Query, [deletedvclock, {return_body, true}]),
    case riak_client:get(BucketRef, Key, Options, Client) of
        {ok, Obj} ->
            object_read_reply(Context, Input, Obj);
        {error, Reason} ->
            {error, object_error_map(Reason)}
    end.

object_store(Mode, Context0, Input, Client) ->
    Context = case Mode of
        create ->
            Generated = list_to_binary(riak_core_util:unique_id_62()),
            Context0#{key => Generated};
        _ ->
            Context0
    end,
    case build_store_doc(Context, Input) of
        {error, Error} ->
            {error, Error};
        {ok, Doc, ReturnBody, CondOpts} ->
            %% S2 (CG-004): Check HTTP-layer conditional preconditions
            %% (If-Match, If-Unmodified-Since) before attempting write.
            case check_write_preconditions(Context, CondOpts, Client) of
                ok ->
                    RiakCondOpts = filter_riak_cond_opts(CondOpts),
                    Query = maps:get(query, Context, #{}),
                    BaseOptions = build_object_options(write, Query, []),
                    Options0 = BaseOptions ++ RiakCondOpts,
                    Options = case ReturnBody of
                        true -> [returnbody | Options0];
                        false -> Options0
                    end,
                    case riak_client:put(Doc, Options, Client) of
                        ok ->
                            {ok, write_no_body_reply(Mode, Context)};
                        {ok, Obj} ->
                            {ok, write_return_body_reply(Mode, Context, Input, Obj)};
                        {error, Reason} ->
                            {error, object_error_map(Reason)}
                    end;
                {error, PrecondError} ->
                    {error, PrecondError}
            end
    end.

object_delete(Context, Input, Client) ->
    BucketRef = bucket_ref(Context),
    Key = maps:get(key, Context, undefined),
    Query = maps:get(query, Context, #{}),
    Headers = maps:get(headers, Input, #{}),
    Options = build_object_options(delete, Query, []),
    Result = case maps:get(<<"x-riak-vclock">>, Headers, undefined) of
        undefined ->
            riak_client:delete(BucketRef, Key, Options, Client);
        VClockB64 ->
            case decode_vclock(VClockB64) of
                {ok, VClock} ->
                    riak_client:delete_vclock(BucketRef, Key, VClock, Options, Client);
                {error, _} ->
                    {error, invalid_vclock}
            end
    end,
    case Result of
        ok ->
            {ok, #{status => 204, body => <<>>}};
        {error, Reason} ->
            {error, object_error_map(Reason)}
    end.

object_read_reply(Context, Input, Obj) ->
    Query = maps:get(query, Context, #{}),
    RequestedVtag = maps:get(<<"vtag">>, Query, undefined),
    case select_doc(Obj, RequestedVtag) of
        {ok, {Metadata, Value}} ->
            {ok, #{
                status => 200,
                body => encode_doc_value(Value),
                content_type => format_content_type(Metadata, Value),
                headers => response_headers_from_metadata(Metadata),
                reply_opts => response_reply_opts(Context, Obj, Metadata)
            }};
        {siblings, Contents} ->
            {Body, ContentType} = sibling_body(Contents, Input),
            {ok, #{
                status => 300,
                body => Body,
                content_type => ContentType,
                reply_opts => #{vclock => encode_object_vclock(Obj)}
            }};
        notfound ->
            {error, #{
                status => 404,
                code => <<"not_found">>,
                reason => <<"not found">>
            }}
    end.

write_no_body_reply(create, Context) ->
    #{
        status => 201,
        body => <<>>,
        headers => #{<<"location">> => build_location(Context, maps:get(key, Context))}
    };
write_no_body_reply(_Mode, _Context) ->
    #{status => 204, body => <<>>}.

write_return_body_reply(Mode, Context, Input, Obj) ->
    case object_read_reply(Context, Input, Obj) of
        {ok, Reply0} ->
            case Mode of
                create ->
                    Headers = maps:get(headers, Reply0, #{}),
                    Reply0#{
                        status => 200,
                        headers => Headers#{<<"location">> => build_location(Context, maps:get(key, Context))}
                    };
                _ ->
                    Reply0#{status => 200}
            end;
        {error, _} ->
            %% Riak returned an object but its contents could not be read
            %% (e.g. empty contents after tombstone race). Fall back to
            %% a simple 204 so the handler doesn't crash.
            write_no_body_reply(Mode, Context)
    end.

build_store_doc(Context, Input) ->
    Headers = maps:get(headers, Input, #{}),
    Query = maps:get(query, Context, #{}),
    Body = maps:get(body, Input, <<>>),
    case parse_content_type(maps:get(<<"content-type">>, Headers, undefined)) of
        {error, Error} ->
            {error, Error};
        {ok, ContentType, Charset} ->
            BucketRef = bucket_ref(Context),
            Key = maps:get(key, Context, undefined),
            Doc0 = riak_object:new(BucketRef, Key, <<>>),
            case maybe_set_vclock(Doc0, Headers) of
                {error, Error1} ->
                    {error, Error1};
                {ok, Doc1} ->
                    Metadata0 = riak_object:metadata_new(),
                    Metadata1 = riak_object:metadata_store(?MD_CTYPE, ContentType, Metadata0),
                    Metadata2 = maybe_store_charset(Charset, Metadata1),
                    Metadata3 = maybe_store_header_meta(<<"content-encoding">>, ?MD_ENCODING,
                        Headers, Metadata2),
                    Metadata4 = maybe_store_metadata_list(?MD_USERMETA,
                        extract_prefixed_headers(?USERMETA_PREFIX, Headers), Metadata3),
                    Metadata5 = maybe_store_metadata_list(?MD_INDEX,
                        extract_index_headers(Headers), Metadata4),
                    Doc2 = riak_object:update_metadata(Doc1, Metadata5),
                    Value = accept_doc_value(ContentType, Body),
                    Doc = riak_object:update_value(Doc2, Value),
                    ReturnBody = query_truthy(<<"returnbody">>, Query),
                    case conditional_put_options(Headers) of
                        {ok, CondOpts} -> {ok, Doc, ReturnBody, CondOpts};
                        {error, Error2} -> {error, Error2}
                    end
            end
    end.

conditional_put_options(Headers) ->
    Cond0 = case maps:is_key(<<"if-none-match">>, Headers) of
        true -> [{if_none_match, true}];
        false -> []
    end,
    %% S2 (CG-004): Extract If-Match and If-Unmodified-Since for
    %% HTTP-layer conditional enforcement (checked before write).
    Cond1 = case maps:get(<<"if-match">>, Headers, undefined) of
        undefined -> Cond0;
        ETag -> [{if_match, strip_etag_quotes(ETag)} | Cond0]
    end,
    Cond2 = case maps:get(<<"if-unmodified-since">>, Headers, undefined) of
        undefined -> Cond1;
        DateStr -> [{if_unmodified_since, DateStr} | Cond1]
    end,
    case maps:get(<<"x-riak-if-not-modified">>, Headers, undefined) of
        undefined ->
            {ok, Cond2};
        VClockB64 ->
            case decode_vclock(VClockB64) of
                {ok, VClock} -> {ok, [{if_not_modified, VClock} | Cond2]};
                {error, _} ->
                    {error, #{
                        status => 400,
                        code => <<"invalid_vclock">>,
                        reason => <<"Invalid X-Riak-If-Not-Modified header">>
                    }}
            end
    end.

%% S2 (CG-004): Strip quotes from ETag values (HTTP allows "tag" or tag).
strip_etag_quotes(ETag) when is_binary(ETag) ->
    case ETag of
        <<"\"", Rest/binary>> when byte_size(Rest) > 0 ->
            case binary:last(Rest) of
                $\" -> binary:part(Rest, 0, byte_size(Rest) - 1);
                _ -> ETag
            end;
        _ -> ETag
    end.

%% S2 (CG-004): Check HTTP-layer conditional preconditions before writing.
%%
%% If-Match: succeeds only if current object's vtag matches the ETag.
%% If-Unmodified-Since: succeeds only if object was not modified after date.
%% These require a read-before-write to check the current state. If no
%% HTTP-layer conditionals are present, returns ok immediately.
-spec check_write_preconditions(map(), list(), term()) -> ok | {error, map()}.
check_write_preconditions(Context, CondOpts, Client) ->
    IfMatch = proplists:get_value(if_match, CondOpts, undefined),
    IfUnmodified = proplists:get_value(if_unmodified_since, CondOpts, undefined),
    case {IfMatch, IfUnmodified} of
        {undefined, undefined} ->
            ok;
        _ ->
            BucketRef = bucket_ref(Context),
            Key = maps:get(key, Context, undefined),
            case riak_client:get(BucketRef, Key,
                                  [deletedvclock, {return_body, true}], Client) of
                {ok, Obj} ->
                    check_if_match(IfMatch, Obj,
                        fun() -> check_if_unmodified_since(IfUnmodified, Obj) end);
                {error, notfound} ->
                    case IfMatch of
                        undefined -> ok;
                        _ ->
                            {error, precondition_error(
                                <<"If-Match failed: object does not exist">>)}
                    end;
                {error, Reason} ->
                    logger:warning("[riak_admin] precondition read failed for ~p/~p: ~p — "
                                   "failing closed (503)",
                                   [BucketRef, Key, Reason]),
                    {error, #{
                        status => 503,
                        code => <<"precondition_read_failed">>,
                        reason => <<"Cannot verify write preconditions: read unavailable">>
                    }}
            end
    end.

check_if_match(undefined, _Obj, Next) ->
    Next();
check_if_match(<<"*">>, _Obj, Next) ->
    Next();
check_if_match(ExpectedETag, Obj, Next) ->
    Contents = riak_object:get_contents(Obj),
    Vtags = [to_bin(riak_object:metadata_fetch(?MD_VTAG, MD))
             || {MD, _} <- Contents],
    case lists:member(ExpectedETag, Vtags) of
        true -> Next();
        false ->
            {error, precondition_error(
                <<"If-Match: ETag does not match current object">>)}
    end.

check_if_unmodified_since(undefined, _Obj) ->
    ok;
check_if_unmodified_since(DateStr, Obj) ->
    Contents = riak_object:get_contents(Obj),
    case Contents of
        [{MD, _} | _] ->
            LastModified = riak_object:metadata_fetch(?MD_LASTMOD, MD),
            case parse_http_date(DateStr) of
                {ok, CondTime} ->
                    ObjTime = lastmod_to_seconds(LastModified),
                    case ObjTime > CondTime of
                        true ->
                            {error, precondition_error(
                                <<"If-Unmodified-Since: object was modified">>)};
                        false ->
                            ok
                    end;
                {error, _} ->
                    {error, #{
                        status => 400,
                        code => <<"invalid_header">>,
                        reason => <<"Invalid If-Unmodified-Since date format">>
                    }}
            end;
        _ ->
            ok
    end.

parse_http_date(DateStr) when is_binary(DateStr) ->
    try
        DateTime = httpd_util:convert_request_date(binary_to_list(DateStr)),
        {ok, calendar:datetime_to_gregorian_seconds(DateTime)}
    catch
        _:_ -> {error, bad_date}
    end.

lastmod_to_seconds({MegaSecs, Secs, _MicroSecs}) ->
    Epoch = calendar:datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}}),
    Epoch + MegaSecs * 1000000 + Secs;
lastmod_to_seconds(_) ->
    0.

%% S2 (CG-004): Remove HTTP-layer conditionals before passing to Riak.
%% Riak KV only understands if_none_match and if_not_modified.
filter_riak_cond_opts(CondOpts) ->
    [{K, V} || {K, V} <- CondOpts,
               K =/= if_match,
               K =/= if_unmodified_since].

maybe_set_vclock(Doc, Headers) ->
    case maps:get(<<"x-riak-vclock">>, Headers, undefined) of
        undefined ->
            {ok, Doc};
        VClockB64 ->
            case decode_vclock(VClockB64) of
                {ok, VClock} ->
                    {ok, riak_object:set_vclock(Doc, VClock)};
                {error, _} ->
                    {error, #{
                        status => 400,
                        code => <<"invalid_vclock">>,
                        reason => <<"Invalid X-Riak-Vclock header">>
                    }}
            end
    end.

parse_content_type(CT) when CT =:= undefined; CT =:= <<>> ->
    {error, #{
        status => 400,
        code => <<"missing_content_type">>,
        reason => <<"Missing Content-Type request header">>
    }};
parse_content_type(ContentType) when is_binary(ContentType) ->
    [Media | Params] = binary:split(ContentType, <<";">>, [global]),
    Charset = parse_charset(Params),
    {ok, trim_binary(Media), Charset}.

parse_charset([]) ->
    undefined;
parse_charset([Param | Rest]) ->
    P = trim_binary(Param),
    case binary:split(P, <<"=">>) of
        [<<"charset">>, Value] -> trim_binary(Value);
        _ -> parse_charset(Rest)
    end.

trim_binary(Bin) when is_binary(Bin) ->
    iolist_to_binary(string:trim(Bin)).

accept_doc_value(<<"application/x-erlang-binary">>, Body)
  when byte_size(Body) > 1048576 ->
    %% Skip ETF deserialization for bodies > 1MB to prevent
    %% memory amplification from deeply nested terms.
    Body;
accept_doc_value(<<"application/x-erlang-binary">>, Body) ->
    try binary_to_term(Body, [safe])
    catch
        _:_ -> Body
    end;
accept_doc_value(_ContentType, Body) ->
    Body.

encode_doc_value(Value) when is_binary(Value) -> Value;
encode_doc_value(Value) -> term_to_binary(Value).

format_content_type(Metadata, Value) ->
    CType = case riak_object:metadata_find(?MD_CTYPE, Metadata) of
        {ok, Stored} -> to_bin(Stored);
        error when is_binary(Value) -> <<"application/octet-stream">>;
        error -> <<"application/x-erlang-binary">>
    end,
    case riak_object:metadata_find(?MD_CHARSET, Metadata) of
        {ok, Charset} -> <<CType/binary, "; charset=", (to_bin(Charset))/binary>>;
        error -> CType
    end.

response_reply_opts(Context, Obj, Metadata) ->
    Reply0 = #{
        vclock => encode_object_vclock(Obj),
        etag => to_bin(riak_object:metadata_fetch(?MD_VTAG, Metadata)),
        last_modified => metadata_last_modified(Metadata)
    },
    case link_header(Context, Metadata) of
        undefined -> Reply0;
        Link -> Reply0#{link => Link}
    end.

response_headers_from_metadata(Metadata) ->
    Headers0 = maybe_put_header(<<"content-encoding">>,
        riak_object:metadata_find(?MD_ENCODING, Metadata), #{}),
    Headers1 = lists:foldl(
        fun({MetaKey, MetaValue}, Acc) ->
            Header = <<?USERMETA_PREFIX/binary, (to_bin(MetaKey))/binary>>,
            Acc#{Header => to_bin(MetaValue)}
        end,
        Headers0,
        metadata_list(?MD_USERMETA, Metadata)),
    lists:foldl(
        fun({IndexKey, IndexValue}, Acc) ->
            Header = <<?INDEX_PREFIX/binary, (to_bin(IndexKey))/binary>>,
            Acc#{Header => to_bin(IndexValue)}
        end,
        Headers1,
        metadata_list(?MD_INDEX, Metadata)).

maybe_put_header(_Header, error, Headers) ->
    Headers;
maybe_put_header(Header, {ok, Value}, Headers) ->
    Headers#{Header => to_bin(Value)}.

metadata_list(Key, Metadata) ->
    case riak_object:metadata_find(Key, Metadata) of
        {ok, List} when is_list(List) -> List;
        _ -> []
    end.

link_header(Context, Metadata) ->
    Bucket = maps:get(bucket, Context, undefined),
    case Bucket of
        undefined ->
            undefined;
        _ ->
            Links = metadata_list(?MD_LINKS, Metadata),
            UpLink = build_up_link(Context),
            Extra = [build_rel_link(Context, Link) || Link <- Links],
            Joined = join_links([UpLink | [L || L <- Extra, L =/= <<>>]]),
            case Joined of
                <<>> -> undefined;
                _ -> Joined
            end
    end.

build_up_link(Context) ->
    Bucket = maps:get(bucket, Context, <<>>),
    case maps:get(alias, Context, buckets) of
        riak -> <<"</riak/", Bucket/binary, ">; rel=\"up\"">>;
        buckets -> <<"</buckets/", Bucket/binary, ">; rel=\"up\"">>;
        types ->
            Type = maps:get(bucket_type, Context, <<"default">>),
            <<"</types/", Type/binary, "/buckets/", Bucket/binary, ">; rel=\"up\"">>
    end.

build_rel_link(Context, {{LinkBucket, LinkKey}, Tag}) ->
    Uri = link_object_uri(Context, to_bin(LinkBucket), to_bin(LinkKey)),
    <<"<", Uri/binary, ">; riaktag=\"", (to_bin(Tag))/binary, "\"">>;
build_rel_link(_Context, _Other) ->
    <<>>.

link_object_uri(Context, Bucket, Key) ->
    case maps:get(alias, Context, buckets) of
        riak -> <<"/riak/", Bucket/binary, "/", Key/binary>>;
        buckets -> <<"/buckets/", Bucket/binary, "/keys/", Key/binary>>;
        types ->
            Type = maps:get(bucket_type, Context, <<"default">>),
            <<"/types/", Type/binary, "/buckets/", Bucket/binary, "/keys/", Key/binary>>
    end.

join_links([]) ->
    <<>>;
join_links([One]) ->
    One;
join_links([First | Rest]) ->
    lists:foldl(fun(Link, Acc) -> <<Acc/binary, ", ", Link/binary>> end, First, Rest).

sibling_body(Contents, Input) ->
    Accept = maps:get(<<"accept">>, maps:get(headers, Input, #{}), <<>>),
    case binary:match(Accept, <<"multipart/mixed">>) of
        nomatch -> sibling_text_body(Contents);
        _ -> sibling_multipart_body(Contents)
    end.

sibling_text_body(Contents) ->
    Vtags = [to_bin(riak_object:metadata_fetch(?MD_VTAG, MD)) || {MD, _} <- Contents],
    Lines = [<<V/binary, "\n">> || V <- Vtags],
    {iolist_to_binary([<<"Siblings:\n">> | Lines]), <<"text/plain">>}.

sibling_multipart_body(Contents) ->
    Boundary = <<"riak-siblings-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Parts = [
        [<<"--", Boundary/binary, "\r\n">>,
         <<"Content-Type: ", (format_content_type(MD, Value))/binary, "\r\n">>,
         <<"ETag: ", (to_bin(riak_object:metadata_fetch(?MD_VTAG, MD)))/binary, "\r\n\r\n">>,
         encode_doc_value(Value),
         <<"\r\n">>]
        || {MD, Value} <- Contents
    ],
    {iolist_to_binary([Parts, <<"--", Boundary/binary, "--\r\n">>]),
     <<"multipart/mixed; boundary=", Boundary/binary>>}.

select_doc(Obj, undefined) ->
    case riak_object:get_update_value(Obj) of
        undefined ->
            case riak_object:get_contents(Obj) of
                [] -> notfound;
                [Single] -> {ok, Single};
                Multi when is_list(Multi) -> {siblings, Multi}
            end;
        UpdateValue ->
            {ok, {riak_object:get_update_metadata(Obj), UpdateValue}}
    end;
select_doc(Obj, RequestedVtag) ->
    Contents = riak_object:get_contents(Obj),
    case lists:dropwhile(
        fun({Metadata, _}) ->
            to_bin(riak_object:metadata_fetch(?MD_VTAG, Metadata)) =/= RequestedVtag
        end,
        Contents) of
        [Match | _] -> {ok, Match};
        [] -> notfound
    end.

metadata_last_modified(Metadata) ->
    LastModified = riak_object:metadata_fetch(?MD_LASTMOD, Metadata),
    to_bin(
        case LastModified of
            Now = {_, _, _} ->
                httpd_util:rfc1123_date(calendar:now_to_universal_time(Now));
            RFC1123 when is_list(RFC1123) ->
                RFC1123;
            Value ->
                Value
        end).

encode_object_vclock(Obj) ->
    encode_vclock(riak_object:vclock(Obj)).

decode_vclock(VClockB64) when is_binary(VClockB64) ->
    try
        {ok, riak_object:decode_vclock(base64:decode(VClockB64))}
    catch
        _:_ -> {error, invalid_vclock}
    end;
decode_vclock(_) ->
    {error, invalid_vclock}.

encode_vclock(VClock) ->
    base64:encode(riak_object:encode_vclock(VClock)).

extract_prefixed_headers(Prefix, Headers) ->
    maps:fold(
        fun(Key, Value, Acc) ->
            case maybe_strip_prefix(Prefix, Key) of
                {ok, Stripped} -> [{Stripped, Value} | Acc];
                no_match -> Acc
            end
        end,
        [],
        Headers).

extract_index_headers(Headers) ->
    Raw = extract_prefixed_headers(?INDEX_PREFIX, Headers),
    lists:flatten([
        [
            {Field, trim_binary(Item)}
            || Item <- binary:split(to_bin(Value), <<",">>, [global])
        ]
        || {Field, Value} <- Raw
    ]).

maybe_strip_prefix(Prefix, Value) when is_binary(Value) ->
    PrefixSize = byte_size(Prefix),
    case Value of
        <<Prefix:PrefixSize/binary, Rest/binary>> -> {ok, Rest};
        _ -> no_match
    end;
maybe_strip_prefix(_Prefix, _Value) ->
    no_match.

maybe_store_charset(undefined, Metadata) ->
    Metadata;
maybe_store_charset(Charset, Metadata) ->
    riak_object:metadata_store(?MD_CHARSET, Charset, Metadata).

maybe_store_header_meta(HeaderKey, MetaKey, Headers, Metadata) ->
    case maps:get(HeaderKey, Headers, undefined) of
        undefined -> Metadata;
        Value -> riak_object:metadata_store(MetaKey, Value, Metadata)
    end.

maybe_store_metadata_list(_MetaKey, [], Metadata) ->
    Metadata;
maybe_store_metadata_list(MetaKey, Values, Metadata) ->
    riak_object:metadata_store(MetaKey, Values, Metadata).

-spec build_object_options(read | write | delete, map(), list()) -> list().
build_object_options(_Mode, Query, Base) ->
    Options0 = [
        {r, maps:get(<<"r">>, Query, undefined)},
        {pr, maps:get(<<"pr">>, Query, undefined)},
        {w, maps:get(<<"w">>, Query, undefined)},
        {pw, maps:get(<<"pw">>, Query, undefined)},
        {dw, maps:get(<<"dw">>, Query, undefined)},
        {rw, maps:get(<<"rw">>, Query, undefined)},
        {node_confirms, maps:get(<<"node_confirms">>, Query, undefined)},
        {timeout, parse_query_timeout(maps:get(<<"timeout">>, Query, undefined))},
        {basic_quorum, normalize_boolean(maps:get(<<"basic_quorum">>, Query, undefined))},
        {notfound_ok, normalize_boolean(maps:get(<<"notfound_ok">>, Query, undefined))}
    ],
    Options1 = [
        {Key, Value}
        || {Key, Value} <- Options0,
           Value =/= undefined
    ],
    Options2 = case maps:get(<<"asis">>, Query, undefined) of
        undefined -> Options1;
        AsisValue -> [{asis, normalize_boolean(AsisValue)} | Options1]
    end,
    case maps:get(<<"sync_on_write">>, Query, undefined) of
        undefined -> Base ++ Options2;
        SyncValue -> Base ++ [{sync_on_write, normalize_sync_on_write(SyncValue)} | Options2]
    end.

parse_query_timeout(undefined) -> undefined;
parse_query_timeout(Timeout) when is_integer(Timeout) -> Timeout;
parse_query_timeout(Timeout) when is_binary(Timeout) ->
    try binary_to_integer(Timeout)
    catch error:badarg -> undefined
    end;
parse_query_timeout(_) -> undefined.

normalize_boolean(true) -> true;
normalize_boolean(false) -> false;
normalize_boolean(<<"true">>) -> true;
normalize_boolean(<<"false">>) -> false;
normalize_boolean(<<"default">>) -> default;
normalize_boolean(default) -> default;
normalize_boolean(Value) -> Value.

normalize_sync_on_write(Value) when is_atom(Value) -> Value;
normalize_sync_on_write(Value) when is_binary(Value) ->
    case string:lowercase(Value) of
        <<"backend">> -> backend;
        <<"one">> -> one;
        <<"all">> -> all;
        <<"default">> -> default;
        _ -> default
    end;
normalize_sync_on_write(Value) -> Value.

query_truthy(Key, Query) ->
    case maps:get(Key, Query, false) of
        true -> true;
        <<"true">> -> true;
        _ -> false
    end.

bucket_ref(Context) ->
    maybe_bucket_type_ref(maps:get(bucket_type, Context, <<"default">>),
        maps:get(bucket, Context, undefined)).

maybe_bucket_type_ref(undefined, Bucket) -> Bucket;
maybe_bucket_type_ref(<<"default">>, Bucket) -> Bucket;
maybe_bucket_type_ref(Type, Bucket) -> {Type, Bucket}.

build_location(Context, Key) ->
    Bucket = maps:get(bucket, Context, <<>>),
    case maps:get(alias, Context, buckets) of
        riak -> <<"/riak/", Bucket/binary, "/", Key/binary>>;
        buckets -> <<"/buckets/", Bucket/binary, "/keys/", Key/binary>>;
        types ->
            Type = maps:get(bucket_type, Context, <<"default">>),
            <<"/types/", Type/binary, "/buckets/", Bucket/binary, "/keys/", Key/binary>>
    end.

ensure_bucket_type(Context) ->
    Type = maps:get(bucket_type, Context, <<"default">>),
    case Type of
        <<"default">> ->
            ok;
        _ ->
            case riak_core_bucket_type:get(Type) of
                undefined ->
                    {error, #{
                        status => 404,
                        code => <<"bucket_type_unknown">>,
                        reason => <<"Unknown bucket type">>
                    }};
                _ ->
                    ok
            end
    end.

with_object_client(Fun) ->
    case riak_kv_wm_utils:get_riak_client(local, undefined) of
        {ok, Client} ->
            try Fun(Client)
            catch
                Class:Reason:Stack ->
                    logger:error(
                        "[riak_admin] object operation failed: ~p:~p~n~p",
                        [Class, Reason, Stack]),
                    {error, object_error_map({Class, Reason})}
            end;
        {error, Reason} ->
            {error, object_error_map({client_error, Reason})}
    end.

%% @private Shared error map constructors.
%% These eliminate repetitive #{status => N, code => ..., reason => ...}
%% construction across the module.

invalid_body_error(Reason) ->
    #{status => 400, code => <<"invalid_body">>, reason => to_bin(Reason)}.

precondition_error(Reason) ->
    #{status => 412, code => <<"precondition_failed">>, reason => Reason}.

index_query_error(Reason) ->
    logger:info("[riak_admin] invalid index query: ~p", [Reason]),
    #{status => 400, code => <<"invalid_query">>,
      reason => <<"Invalid index query">>}.

-spec object_error_map(term()) -> map().
object_error_map(precommit_fail) ->
    #{status => 403, code => <<"forbidden">>, reason => <<"pre-commit hook failed">>};
object_error_map({precommit_fail, Message}) when is_binary(Message) ->
    #{status => 403, code => <<"forbidden">>, reason => Message};
object_error_map({precommit_fail, Message}) when is_list(Message) ->
    #{status => 403, code => <<"forbidden">>,
      reason => list_to_binary(Message)};
object_error_map({precommit_fail, Message}) ->
    logger:warning("[riak_admin] precommit hook returned non-binary: ~p",
                   [Message]),
    #{status => 403, code => <<"forbidden">>,
      reason => <<"pre-commit hook failed">>};
object_error_map(too_many_fails) ->
    #{status => 503, code => <<"quorum_unsatisfied">>,
      reason => <<"Too many write failures to satisfy W/DW">>};
object_error_map(timeout) ->
    #{status => 503, code => <<"timeout">>, reason => <<"request timed out">>};
object_error_map(notfound) ->
    #{status => 404, code => <<"not_found">>, reason => <<"not found">>};
object_error_map(bucket_type_unknown) ->
    #{status => 404, code => <<"bucket_type_unknown">>, reason => <<"Unknown bucket type">>};
object_error_map({deleted, VClock}) ->
    #{status => 404, code => <<"not_found">>, reason => <<"not found">>,
      vclock => encode_vclock(VClock)};
object_error_map({n_val_violation, N}) ->
    #{status => 400, code => <<"invalid_quorum">>,
      reason => iolist_to_binary(io_lib:format(
          "Specified w/dw/pw/node_confirms values invalid for bucket n value of ~p",
          [N]))};
object_error_map({r_val_unsatisfied, Requested, Returned}) ->
    #{status => 503, code => <<"quorum_unsatisfied">>,
      reason => iolist_to_binary(io_lib:format("R-value unsatisfied: ~p/~p", [Returned, Requested]))};
object_error_map({dw_val_unsatisfied, DW, NumDW}) ->
    #{status => 503, code => <<"quorum_unsatisfied">>,
      reason => iolist_to_binary(io_lib:format("DW-value unsatisfied: ~p/~p", [NumDW, DW]))};
object_error_map({pr_val_unsatisfied, Requested, Returned}) ->
    #{status => 503, code => <<"quorum_unsatisfied">>,
      reason => iolist_to_binary(io_lib:format("PR-value unsatisfied: ~p/~p", [Returned, Requested]))};
object_error_map({pw_val_unsatisfied, Requested, Returned}) ->
    #{status => 503, code => <<"quorum_unsatisfied">>,
      reason => iolist_to_binary(io_lib:format("PW-value unsatisfied: ~p/~p", [Returned, Requested]))};
object_error_map({node_confirms_val_unsatisfied, Requested, Returned}) ->
    #{status => 503, code => <<"quorum_unsatisfied">>,
      reason => iolist_to_binary(io_lib:format(
          "node_confirms-value unsatisfied: ~p/~p", [Returned, Requested]))};
object_error_map(failed) ->
    precondition_error(<<"precondition failed">>);
object_error_map("match_found") ->
    precondition_error(<<"precondition failed">>);
object_error_map("modified") ->
    #{status => 409, code => <<"conflict">>, reason => <<"object was modified">>};
object_error_map(invalid_vclock) ->
    #{status => 400, code => <<"invalid_vclock">>, reason => <<"Invalid vector clock">>};
object_error_map({client_error, Reason}) ->
    logger:warning("[riak_admin] client error: ~p", [Reason]),
    #{status => 503, code => <<"backend_unavailable">>,
      reason => <<"Backend service temporarily unavailable">>};
object_error_map({Class, Reason}) when is_atom(Class) ->
    logger:warning("[riak_admin] unhandled error: ~p:~p", [Class, Reason]),
    #{status => 500, code => <<"backend_error">>,
      reason => <<"Internal server error">>};
object_error_map(Reason) ->
    logger:warning("[riak_admin] unknown error: ~p", [Reason]),
    #{status => 500, code => <<"backend_error">>,
      reason => <<"Internal server error">>}.

bucket_props_ref(Context) ->
    maybe_bucket_type_ref(maps:get(bucket_type, Context, <<"default">>),
        maps:get(bucket, Context, undefined)).

json_backend_reply(Status, Body) ->
    #{
        status => Status,
        body => Body,
        content_type => <<"application/json; charset=utf-8">>
    }.

extract_bucket_props(Input) ->
    case maps:get(props, Input, undefined) of
        Props when is_list(Props) ->
            {ok, Props};
        _ ->
            decode_bucket_props_body(maps:get(body, Input, <<>>))
    end.

decode_bucket_props_body(Body) ->
    case catch mochijson2:decode(Body) of
        {struct, Fields} ->
            case proplists:get_value(?JSON_PROPS, Fields) of
                {struct, Props} when is_list(Props) ->
                    {ok, Props};
                _ ->
                    {error, bucket_error_map(invalid_body)}
            end;
        _ ->
            {error, bucket_error_map(invalid_body)}
    end.

bucket_error_map(invalid_body) ->
    invalid_body_error(<<"Body must be JSON: {\"props\": {...}}">>);
bucket_error_map({invalid_props, Details}) when is_binary(Details) ->
    #{
        status => 400,
        code => <<"invalid_props">>,
        reason => Details
    };
bucket_error_map({invalid_props, Details}) ->
    logger:info("[riak_admin] invalid bucket props: ~p", [Details]),
    #{
        status => 400,
        code => <<"invalid_props">>,
        reason => <<"Invalid bucket properties">>
    };
bucket_error_map(Reason) ->
    object_error_map(Reason).

bucket_list_operation(Context, Client) ->
    Query = maps:get(query, Context, #{}),
    BucketType = maps:get(bucket_type, Context, <<"default">>),
    Timeout = maps:get(<<"timeout">>, Query, ?DEFAULT_BUCKET_LIST_TIMEOUT),
    case maps:get(<<"buckets">>, Query, undefined) of
        true ->
            list_buckets_reply(BucketType, Timeout, Client);
        <<"true">> ->
            list_buckets_reply(BucketType, Timeout, Client);
        <<"stream">> ->
            stream_buckets_reply(BucketType, Timeout, Client);
        _ ->
            {ok, json_backend_reply(200, encode_bucket_list([]))}
    end.

list_buckets_reply(BucketType, Timeout0, Client) ->
    %% Cap timeout to stream_collection_ceiling to prevent unbounded
    %% handler blocking on non-streaming bucket list operations.
    Timeout = cap_timeout(Timeout0, stream_collection_ceiling()),
    case riak_client:list_buckets(none, Timeout, BucketType, Client) of
        {ok, Buckets} ->
            {ok, json_backend_reply(200, encode_bucket_list(Buckets))};
        {error, Reason} ->
            {error, bucket_error_map(Reason)}
    end.

stream_buckets_reply(BucketType, Timeout, Client) ->
    case riak_client:stream_list_buckets(none, Timeout, BucketType, Client) of
        {ok, ReqId} ->
            case stream_incremental_enabled() of
                true ->
                    %% S2 (CG-001): True incremental streaming
                    StreamInit = #{
                        status => 200,
                        content_type => <<"application/json; charset=utf-8">>
                    },
                    ChunkFun = fun(Emit) ->
                        stream_buckets_chunked(ReqId, Timeout, Emit)
                    end,
                    {stream, StreamInit, ChunkFun};
                false ->
                    Body = collect_stream_buckets(ReqId, [], Timeout),
                    {ok, json_backend_reply(200, Body)}
            end;
        {error, Reason} ->
            {error, bucket_error_map(Reason)}
    end.

collect_stream_buckets(ReqId, Acc, Timeout) ->
    %% S1 (CG-016): Apply ceiling timeout to prevent unbounded blocking.
    CeilingMs = stream_collection_ceiling(),
    EffectiveTimeout = erlang:min(Timeout, CeilingMs),
    collect_stream_buckets_loop(ReqId, Acc, EffectiveTimeout).

collect_stream_buckets_loop(ReqId, Acc, Timeout) ->
    receive
        {ReqId, done} ->
            iolist_to_binary(lists:reverse([encode_bucket_list([]) | Acc]));
        {ReqId, _From, {buckets_stream, Buckets}} ->
            collect_stream_buckets_loop(ReqId, [encode_bucket_list(Buckets) | Acc], Timeout);
        {ReqId, {buckets_stream, Buckets}} ->
            collect_stream_buckets_loop(ReqId, [encode_bucket_list(Buckets) | Acc], Timeout);
        {ReqId, {error, timeout}} ->
            logger:warning("[riak_admin] bucket stream timed out (backend timeout)"),
            iolist_to_binary(lists:reverse([encode_bucket_stream_timeout() | Acc]))
    after Timeout ->
        logger:warning("[riak_admin] bucket stream timed out after ~Bms ceiling",
                       [Timeout]),
        iolist_to_binary(lists:reverse([encode_bucket_stream_timeout() | Acc]))
    end.

%% S2 (CG-001): Incremental streaming for bucket listing.
%% Emits each chunk directly instead of accumulating in memory.
stream_buckets_chunked(ReqId, Timeout, Emit) ->
    CeilingMs = stream_collection_ceiling(),
    EffectiveTimeout = erlang:min(Timeout, CeilingMs),
    stream_buckets_chunked_loop(ReqId, EffectiveTimeout, Emit).

stream_buckets_chunked_loop(ReqId, Timeout, Emit) ->
    receive
        {ReqId, done} ->
            Emit(encode_bucket_list([]), fin);
        {ReqId, _From, {buckets_stream, Buckets}} ->
            Emit(encode_bucket_list(Buckets), nofin),
            stream_buckets_chunked_loop(ReqId, Timeout, Emit);
        {ReqId, {buckets_stream, Buckets}} ->
            Emit(encode_bucket_list(Buckets), nofin),
            stream_buckets_chunked_loop(ReqId, Timeout, Emit);
        {ReqId, {error, timeout}} ->
            logger:warning("[riak_admin] bucket stream timed out (backend timeout)"),
            Emit(encode_bucket_stream_timeout(), fin)
    after Timeout ->
        logger:warning("[riak_admin] bucket stream timed out after ~Bms ceiling",
                       [Timeout]),
        Emit(encode_bucket_stream_timeout(), fin)
    end.

encode_bucket_list(Buckets) ->
    mochijson2:encode({struct, [{?JSON_BUCKETS, Buckets}]}).

encode_bucket_stream_timeout() ->
    encode_stream_error(timeout).

%% @private Unified stream error JSON encoder.
%%
%% S5 (M-7): All stream error paths (bucket, key, index, mapred) now
%% use this single function for consistent framing. Previously bucket/key
%% streams used mochijson2 directly, index errors used a separate encoder,
%% and mapred streams used jsx. This unifies them all on mochijson2
%% (matching the dominant pattern) with consistent {error, Reason} shape.
-spec encode_stream_error(term()) -> iodata().
encode_stream_error(Reason) when is_atom(Reason); is_binary(Reason) ->
    mochijson2:encode({struct, [{error, Reason}]});
encode_stream_error(Reason) ->
    logger:warning("[riak_admin] sanitized stream error: ~p", [Reason]),
    mochijson2:encode({struct, [{error, <<"Internal server error">>}]}).

key_list_operation(Context, Client) ->
    Query = maps:get(query, Context, #{}),
    Bucket = bucket_ref(Context),
    Timeout = maps:get(<<"timeout">>, Query, undefined),
    BucketPropsJson = key_list_bucket_props(Context, Query, Bucket, Client),
    case maps:get(<<"keys">>, Query, undefined) of
        <<"stream">> ->
            stream_keys_reply(Bucket, Timeout, BucketPropsJson, Context, Client);
        true ->
            list_keys_reply(Bucket, Timeout, BucketPropsJson, Client);
        <<"true">> ->
            list_keys_reply(Bucket, Timeout, BucketPropsJson, Client);
        _ ->
            {ok, json_backend_reply(200, mochijson2:encode({struct, BucketPropsJson}))}
    end.

key_list_bucket_props(Context, Query, Bucket, Client) ->
    case key_list_include_props(Context, Query) of
        true ->
            [riak_kv_wm_props:get_bucket_props_json(Client, Bucket)];
        false ->
            []
    end.

key_list_include_props(Context, Query) ->
    maps:get(alias, Context, buckets) =:= riak andalso key_list_props_enabled(Query).

key_list_props_enabled(Query) ->
    case maps:get(<<"props">>, Query, undefined) of
        false -> false;
        <<"false">> -> false;
        _ -> true
    end.

list_keys_reply(Bucket, Timeout0, BucketPropsJson, Client) ->
    %% Cap timeout to stream_collection_ceiling to prevent unbounded
    %% handler blocking on non-streaming key list operations.
    Timeout = cap_timeout(Timeout0, stream_collection_ceiling()),
    case riak_client:list_keys(Bucket, Timeout, Client) of
        {ok, KeyList} ->
            Body = mochijson2:encode({struct, BucketPropsJson ++ [{?JSON_KEYS, KeyList}]}),
            {ok, json_backend_reply(200, Body)};
        {error, Reason} ->
            %% S1 (CG-005): Configurable error mode for list_keys failures.
            %% Default (compat): return 200 with embedded error for backward
            %% compatibility with existing clients.
            %% Strict mode: return proper HTTP error status.
            case list_keys_error_mode() of
                strict ->
                    {error, bucket_error_map(Reason)};
                compat ->
                    Body = mochijson2:encode(
                        {struct, BucketPropsJson ++ [{error, Reason}]}),
                    {ok, json_backend_reply(200, Body)}
            end
    end.

%% @doc Return the list_keys error handling mode.
%%
%% S1: Controls whether list_keys errors return proper HTTP error
%% status codes (strict) or 200 with embedded error (compat).
%% Default: compat (backward-compatible behavior).
%% Set list_keys_error_mode => strict for production deployments
%% that prefer standard HTTP error semantics.
-spec list_keys_error_mode() -> strict | compat.
list_keys_error_mode() ->
    case application:get_env(riak_admin_api, list_keys_error_mode, compat) of
        strict -> strict;
        _ -> compat
    end.

stream_keys_reply(Bucket, Timeout0, BucketPropsJson, Context, Client) ->
    case riak_client:stream_list_keys(Bucket, Timeout0, Client) of
        {ok, ReqId} ->
            FirstChunk = case maps:get(api_version, Context, 2) of
                1 -> mochijson2:encode({struct, BucketPropsJson});
                _ -> <<>>
            end,
            Timeout = key_stream_timeout(Timeout0),
            case stream_incremental_enabled() of
                true ->
                    %% S2 (CG-001): True incremental streaming
                    StreamInit = #{
                        status => 200,
                        content_type => <<"application/json; charset=utf-8">>
                    },
                    ChunkFun = fun(Emit) ->
                        case FirstChunk of
                            <<>> -> ok;
                            _ -> Emit(FirstChunk, nofin)
                        end,
                        stream_keys_chunked(ReqId, Timeout, Emit)
                    end,
                    {stream, StreamInit, ChunkFun};
                false ->
                    Body = iolist_to_binary([FirstChunk,
                        collect_stream_keys(ReqId, [], Timeout)]),
                    {ok, json_backend_reply(200, Body)}
            end;
        {error, Reason} ->
            {error, bucket_error_map(Reason)}
    end.

key_stream_timeout(undefined) ->
    ?DEFAULT_KEY_STREAM_TIMEOUT;
key_stream_timeout(infinity) ->
    %% Never pass infinity — cap to the stream collection ceiling
    %% to prevent unbounded handler blocking (DoS vector).
    stream_collection_ceiling();
key_stream_timeout(Timeout) when is_integer(Timeout), Timeout >= 0 ->
    Timeout;
key_stream_timeout(_) ->
    ?DEFAULT_KEY_STREAM_TIMEOUT.

collect_stream_keys(ReqId, Acc, Timeout) ->
    %% S1 (CG-016): Apply ceiling timeout to prevent unbounded blocking.
    CeilingMs = stream_collection_ceiling(),
    EffectiveTimeout = erlang:min(Timeout, CeilingMs),
    collect_stream_keys_loop(ReqId, Acc, EffectiveTimeout).

collect_stream_keys_loop(ReqId, Acc, Timeout) ->
    receive
        {ReqId, done} ->
            iolist_to_binary(lists:reverse([encode_key_list([]) | Acc]));
        {ReqId, From, {keys, Keys}} ->
            _ = riak_kv_keys_fsm:ack_keys(From),
            collect_stream_keys_loop(ReqId, [encode_key_list(Keys) | Acc], Timeout);
        {ReqId, {keys, Keys}} ->
            collect_stream_keys_loop(ReqId, [encode_key_list(Keys) | Acc], Timeout);
        {ReqId, {error, timeout}} ->
            logger:warning("[riak_admin] key stream timed out (backend timeout)"),
            iolist_to_binary(lists:reverse([encode_key_stream_timeout() | Acc]));
        {ReqId, {error, Reason}} ->
            logger:warning("[riak_admin] key stream error: ~p", [Reason]),
            iolist_to_binary(lists:reverse([encode_key_stream_error(Reason) | Acc]))
    after Timeout ->
        logger:warning("[riak_admin] key stream timed out after ~Bms ceiling",
                       [Timeout]),
        iolist_to_binary(lists:reverse([encode_key_stream_timeout() | Acc]))
    end.

%% S2 (CG-001): Incremental streaming for key listing.
stream_keys_chunked(ReqId, Timeout, Emit) ->
    CeilingMs = stream_collection_ceiling(),
    EffectiveTimeout = erlang:min(Timeout, CeilingMs),
    stream_keys_chunked_loop(ReqId, EffectiveTimeout, Emit).

stream_keys_chunked_loop(ReqId, Timeout, Emit) ->
    receive
        {ReqId, done} ->
            Emit(encode_key_list([]), fin);
        {ReqId, From, {keys, Keys}} ->
            _ = riak_kv_keys_fsm:ack_keys(From),
            Emit(encode_key_list(Keys), nofin),
            stream_keys_chunked_loop(ReqId, Timeout, Emit);
        {ReqId, {keys, Keys}} ->
            Emit(encode_key_list(Keys), nofin),
            stream_keys_chunked_loop(ReqId, Timeout, Emit);
        {ReqId, {error, timeout}} ->
            logger:warning("[riak_admin] key stream timed out (backend timeout)"),
            Emit(encode_key_stream_timeout(), fin);
        {ReqId, {error, Reason}} ->
            logger:warning("[riak_admin] key stream error: ~p", [Reason]),
            Emit(encode_key_stream_error(Reason), fin)
    after Timeout ->
        logger:warning("[riak_admin] key stream timed out after ~Bms ceiling",
                       [Timeout]),
        Emit(encode_key_stream_timeout(), fin)
    end.

encode_key_list(Keys) ->
    mochijson2:encode({struct, [{?JSON_KEYS, Keys}]}).

encode_key_stream_timeout() ->
    encode_stream_error(timeout).

encode_key_stream_error(Reason) ->
    encode_stream_error(Reason).

%% @doc Maximum time (ms) a stream collection loop may block the handler.
%%
%% S1 (CG-016): This is a safety ceiling that caps how long any stream
%% collection (buckets, keys, index) can block the Cowboy handler
%% process. It does NOT replace per-stream timeouts — it is applied
%% as min(stream_timeout, ceiling) to prevent unbounded blocking.
%% Default: 5 minutes (300000 ms). Configurable via application env.
-spec stream_collection_ceiling() -> pos_integer().
stream_collection_ceiling() ->
    application:get_env(riak_admin_api, stream_collection_ceiling_ms, 300000).

%% @doc Cap a timeout value to a maximum ceiling. Handles undefined and
%% infinity by returning the ceiling, and caps integer values with min/2.
-spec cap_timeout(undefined | infinity | non_neg_integer(), pos_integer()) ->
    pos_integer().
cap_timeout(undefined, Ceiling) -> Ceiling;
cap_timeout(infinity, Ceiling) -> Ceiling;
cap_timeout(Timeout, Ceiling) when is_binary(Timeout) ->
    try binary_to_integer(Timeout) of
        IntTimeout -> erlang:min(IntTimeout, Ceiling)
    catch
        error:badarg -> Ceiling
    end;
cap_timeout(Timeout, Ceiling) when is_integer(Timeout) ->
    erlang:min(Timeout, Ceiling).

%% @doc Return whether incremental streaming is enabled.
%%
%% S2 (CG-001): When true (default), stream-mode responses for
%% key listing, bucket listing, and index queries use Cowboy's
%% chunked transfer encoding for bounded memory use. When false,
%% falls back to the pre-S2 aggregated-body behavior.
%%
%% Toggle: set stream_incremental_enabled => false to rollback.
-spec stream_incremental_enabled() -> boolean().
stream_incremental_enabled() ->
    application:get_env(riak_admin_api, stream_incremental_enabled, true).

counter_get_operation(Context, Client) ->
    Query = maps:get(query, Context, #{}),
    Key = maps:get(key, Context, undefined),
    Options = build_object_options(
        read,
        Query,
        [deletedvclock, {return_body, true}, {crdt_op, riak_dt_pncounter}]),
    case riak_client:get(counter_bucket_ref(Context), Key, Options, Client) of
        {ok, Obj} ->
            {ok, #{
                status => 200,
                body => integer_to_binary(riak_kv_crdt:counter_value(Obj)),
                content_type => <<"text/plain; charset=utf-8">>
            }};
        {error, Reason} ->
            {error, object_error_map(Reason)}
    end.

counter_update_operation(Context, Input, Client) ->
    case counter_delta_from_body(maps:get(body, Input, <<>>)) of
        {ok, Amount} ->
            Query = maps:get(query, Context, #{}),
            Key = maps:get(key, Context, undefined),
            Obj = riak_kv_crdt:new(counter_bucket_ref(Context), Key, riak_dt_pncounter),
            CrdtOp = #crdt_op{
                mod = riak_dt_pncounter,
                op = counter_to_crdt_op(Amount),
                ctx = undefined
            },
            BaseOptions = build_object_options(write, Query, []),
            ReturnValue = query_truthy(<<"returnvalue">>, Query),
            Options0 = [{crdt_op, CrdtOp}, {retry_put_coordinator_failure, false} | BaseOptions],
            Options = case ReturnValue of
                true -> [returnbody | Options0];
                false -> Options0
            end,
            case riak_client:put(Obj, Options, Client) of
                ok ->
                    {ok, #{status => 204, body => <<>>}};
                {ok, UpdatedObj} ->
                    {ok, #{
                        status => 200,
                        body => integer_to_binary(riak_kv_crdt:counter_value(UpdatedObj)),
                        content_type => <<"text/plain; charset=utf-8">>
                    }};
                {error, Reason} ->
                    {error, object_error_map(Reason)}
            end;
        {error, Error} ->
            {error, Error}
    end.

crdt_fetch_operation(Context, Client) ->
    case maybe_crdt_counter_redirect(Context) of
        {redirect, Location} ->
            {ok, crdt_redirect_reply(Location)};
        no_redirect ->
            case crdt_bucket_module(Context) of
                {ok, Type, Mod} ->
                    Query = maps:get(query, Context, #{}),
                    Key = maps:get(key, Context, undefined),
                    IncludeContext = crdt_query_flag(Query, <<"include_context">>, true),
                    Options = build_object_options(
                        read,
                        Query,
                        [deletedvclock, {return_body, true}, {crdt_op, Mod}]),
                    case riak_client:get(bucket_ref(Context), Key, Options, Client) of
                        {ok, Obj} ->
                            {ok, #{
                                status => 200,
                                body => crdt_response_body(Type, Mod, Obj, IncludeContext),
                                content_type => <<"application/json; charset=utf-8">>
                            }};
                        {error, notfound} ->
                            {ok, crdt_notfound_reply(Type, false, undefined)};
                        {error, {deleted, VClock}} ->
                            {ok, crdt_notfound_reply(Type, true, VClock)};
                        {error, Reason} ->
                            {error, object_error_map(Reason)}
                    end;
                {error, Error} ->
                    {error, Error}
            end
    end.

crdt_update_operation(Mode, Context0, Input, Client) ->
    %% S2 (CG-007): For create mode (no key), also check collection redirect.
    case maybe_crdt_counter_redirect(Context0) of
        {redirect, Location} ->
            {ok, crdt_redirect_reply(Location)};
        no_redirect ->
            case {Mode, maybe_crdt_collection_redirect(Context0)} of
                {create, {redirect, CollLoc}} ->
                    {ok, crdt_redirect_reply(CollLoc)};
                _ ->
                    crdt_update_operation_inner(Mode, Context0, Input, Client)
            end
    end.

crdt_update_operation_inner(Mode, Context0, Input, Client) ->
    Context = case Mode of
        create ->
            Context0#{key => list_to_binary(riak_core_util:unique_id_62())};
        _ ->
            Context0
    end,
    case crdt_bucket_module(Context) of
        {ok, Type, Mod} ->
            Query = maps:get(query, Context, #{}),
            ReturnBody = crdt_query_flag(Query, <<"returnbody">>, false),
            IncludeContext = crdt_query_flag(Query, <<"include_context">>, true),
            case crdt_decode_update_body(Type, maps:get(body, Input, <<>>)) of
                {ok, Op, OpCtx} ->
                    Obj = riak_kv_crdt:new(
                        bucket_ref(Context),
                        maps:get(key, Context, undefined),
                        Mod),
                    CrdtOp = #crdt_op{mod = Mod, op = Op, ctx = OpCtx},
                    BaseOptions = build_object_options(write, Query, []),
                    Options0 = [
                        {crdt_op, CrdtOp},
                        {retry_put_coordinator_failure, false}
                        | BaseOptions
                    ],
                    Options = case ReturnBody of
                        true -> [returnbody | Options0];
                        false -> Options0
                    end,
                    case riak_client:put(Obj, Options, Client) of
                        ok ->
                            {ok, crdt_write_no_body_reply(Mode, Context)};
                        {ok, UpdatedObj} ->
                            {ok, crdt_write_body_reply(
                                Mode, Context, Type, Mod, UpdatedObj, IncludeContext)};
                        {error, Reason} ->
                            {error, object_error_map(Reason)}
                    end;
                {error, Error} ->
                    {error, Error}
            end;
        {error, Error} ->
            {error, Error}
    end.

crdt_write_no_body_reply(create, Context) ->
    #{
        status => 201,
        body => <<>>,
        headers => #{<<"location">> => build_crdt_location(Context, maps:get(key, Context))}
    };
crdt_write_no_body_reply(_Mode, _Context) ->
    #{status => 204, body => <<>>}.

crdt_write_body_reply(Mode, Context, Type, Mod, Obj, IncludeContext) ->
    Reply0 = #{
        status => 200,
        body => crdt_response_body(Type, Mod, Obj, IncludeContext),
        content_type => <<"application/json; charset=utf-8">>
    },
    case Mode of
        create ->
            Reply0#{
                headers => #{
                    <<"location">> => build_crdt_location(Context, maps:get(key, Context))
                }
            };
        _ ->
            Reply0
    end.

maybe_crdt_counter_redirect(Context) ->
    case {maps:get(bucket_type, Context, <<"default">>), maps:get(key, Context, undefined)} of
        {<<"default">>, Key} when is_binary(Key), Key =/= <<>> ->
            Bucket = maps:get(bucket, Context, <<>>),
            {redirect, <<"/buckets/", Bucket/binary, "/counters/", Key/binary>>};
        _ ->
            no_redirect
    end.

%% S2 (CG-007): Redirect CRDT collection (create) path for default bucket type.
%% When bucket_type is <<"default">> and no key is supplied (collection create),
%% redirect to the legacy /buckets/.../counters path. This mirrors the keyed
%% redirect in maybe_crdt_counter_redirect/1 but covers the POST-to-create case.
maybe_crdt_collection_redirect(Context) ->
    case {maps:get(bucket_type, Context, <<"default">>), maps:get(key, Context, undefined)} of
        {<<"default">>, Key} when Key =:= undefined; Key =:= <<>> ->
            Bucket = maps:get(bucket, Context, <<>>),
            {redirect, <<"/buckets/", Bucket/binary, "/counters">>};
        _ ->
            no_redirect
    end.

crdt_redirect_reply(Location) ->
    #{
        status => 301,
        body => <<"Counters in the default bucket-type should use the legacy URL\n">>,
        content_type => <<"text/plain; charset=utf-8">>,
        headers => #{<<"location">> => Location}
    }.

counter_bucket_ref(Context) ->
    {?COUNTER_BUCKET_TYPE, maps:get(bucket, Context, undefined)}.

counter_to_crdt_op(Amount) when Amount >= 0 ->
    {increment, Amount};
counter_to_crdt_op(Amount) ->
    {decrement, -Amount}.

counter_delta_from_body(Body0) ->
    Body = iolist_to_binary(string:trim(to_bin(Body0))),
    case Body of
        <<>> ->
            {error, counter_body_error()};
        _ ->
            try
                {ok, binary_to_integer(Body)}
            catch
                error:badarg ->
                    {error, counter_body_error()}
            end
    end.

counter_body_error() ->
    invalid_body_error(<<"Counter update body must be an integer">>).

crdt_bucket_module(Context) ->
    BucketType = maps:get(bucket_type, Context, <<"default">>),
    Bucket = maps:get(bucket, Context, undefined),
    case riak_core_bucket:get_bucket({BucketType, Bucket}) of
        BucketProps when is_list(BucketProps) ->
            AllowMult = proplists:get_value(allow_mult, BucketProps),
            Datatype = proplists:get_value(datatype, BucketProps),
            Mod = riak_kv_crdt:to_mod(Datatype),
            case {AllowMult, riak_kv_crdt:supported(Mod)} of
                {false, _} ->
                    {error, #{
                        status => 400,
                        code => <<"invalid_datatype">>,
                        reason => <<"Bucket must be allow_mult=true">>
                    }};
                {_, false} ->
                    {error, #{
                        status => 400,
                        code => <<"invalid_datatype">>,
                        reason => iolist_to_binary([
                            <<"Bucket datatype '">>,
                            to_bin(Datatype),
                            <<"' is not a supported type.">>
                        ])
                    }};
                _ ->
                    {ok, riak_kv_crdt:from_mod(Mod), Mod}
            end;
        {error, no_type} ->
            {error, object_error_map(bucket_type_unknown)};
        undefined ->
            {error, object_error_map(bucket_type_unknown)};
        Other ->
            {error, object_error_map(Other)}
    end.

crdt_decode_update_body(Type, Body) ->
    try
        Json = mochijson2:decode(Body),
        ModMap = riak_kv_crdt:mod_map(Type),
        {Type, Op, OpCtx} = riak_kv_crdt_json:update_request_from_json(Type, Json, ModMap),
        {ok, Op, OpCtx}
    catch
        throw:{invalid_operation, {BadType, BadOp}} ->
            {error, invalid_body_error(iolist_to_binary([
                <<"Invalid operation on datatype '">>,
                to_bin(BadType),
                <<"': ">>,
                mochijson2:encode(BadOp),
                <<"\n">>
            ]))};
        throw:{invalid_field_name, Field} ->
            {error, invalid_body_error(iolist_to_binary([
                <<"Invalid map field name '">>,
                Field,
                <<"'\n">>
            ]))};
        throw:invalid_utf8 ->
            {error, invalid_body_error(
                <<"Malformed JSON submitted, invalid UTF-8">>)};
        _Class:Reason ->
            logger:info("[riak_admin] CRDT JSON decode error: ~p", [Reason]),
            {error, invalid_body_error(<<"Couldn't decode CRDT update JSON">>)}
    end.

crdt_response_body(Type, Mod, Obj, IncludeContext) ->
    {{RespCtx, Value}, Stats} = riak_kv_crdt:value(Obj, Mod),
    _ = [ok = riak_kv_stat:update(S) || S <- Stats],
    ModMap = riak_kv_crdt:mod_map(Type),
    Context = case IncludeContext of
        true -> RespCtx;
        false -> undefined
    end,
    mochijson2:encode(
        riak_kv_crdt_json:fetch_response_to_json(Type, Value, Context, ModMap)).

crdt_notfound_reply(Type, Deleted, VClock) ->
    TypeBin = atom_to_binary(Type, utf8),
    Body = mochijson2:encode({struct, [{<<"type">>, TypeBin}, {<<"error">>, <<"notfound">>}]}),
    Reply0 = #{
        status => 404,
        body => Body,
        content_type => <<"application/json; charset=utf-8">>
    },
    Reply1 = case Deleted of
        true ->
            Reply0#{headers => #{<<"x-riak-deleted">> => <<"true">>}};
        false ->
            Reply0
    end,
    case VClock of
        undefined ->
            Reply1;
        _ ->
            Reply1#{reply_opts => #{vclock => encode_vclock(VClock)}}
    end.

crdt_query_flag(Query, Key, Default) ->
    case maps:get(Key, Query, Default) of
        true -> true;
        false -> false;
        <<"true">> -> true;
        <<"false">> -> false;
        default -> Default;
        <<"default">> -> Default;
        _ -> Default
    end.

build_crdt_location(Context, Key) ->
    Type = maps:get(bucket_type, Context, <<"default">>),
    Bucket = maps:get(bucket, Context, <<>>),
    <<"/types/", Type/binary, "/buckets/", Bucket/binary, "/datatypes/", Key/binary>>.

index_operation(Context, Client) ->
    case build_index_request(Context) of
        {ok, Request} ->
            case maps:get(streamed, Request, false) of
                true -> stream_index_reply(Request, Client);
                false -> list_index_reply(Request, Client)
            end;
        {error, Error} ->
            {error, Error}
    end.

build_index_request(Context) ->
    Query = maps:get(query, Context, #{}),
    Field = maps:get(field, Context, undefined),
    {Start, End, IsEqualOp} = index_terms(Context),
    InternalReturnTerms = not (IsEqualOp orelse Field =:= <<"$field">>),
    ReturnTermsInput = normalize_boolean_query(maps:get(<<"return_terms">>, Query, false), false),
    Continuation = maps:get(<<"continuation">>, Query, undefined),
    TermRegex = maps:get(<<"term_regex">>, Query, undefined),
    MaxResults = maps:get(<<"max_results">>, Query, all),
    Streamed = normalize_boolean_query(maps:get(<<"stream">>, Query, false), false),
    PaginationSort0 = case maps:get(<<"pagination_sort">>, Query, undefined) of
        undefined -> undefined;
        Value -> normalize_boolean_query(Value, false)
    end,
    PaginationSort = case Continuation of
        undefined -> PaginationSort0;
        _ -> true
    end,
    Timeout = maps:get(<<"timeout">>, Query, undefined),
    QueryArgs0 = [
        {field, Field},
        {start_term, Start},
        {end_term, End},
        {return_terms, InternalReturnTerms},
        {continuation, Continuation},
        {term_regex, TermRegex}
    ],
    QueryArgs = case MaxResults of
        all -> QueryArgs0;
        _ -> QueryArgs0 ++ [{max_results, MaxResults}]
    end,
    case catch riak_index:to_index_query(QueryArgs) of
        {ok, IndexQuery} ->
            case validate_index_term_regex(TermRegex, IndexQuery) of
                ok ->
                    ReturnTerms = riak_index:return_terms(ReturnTermsInput, IndexQuery),
                    Opts0 = [{max_results, MaxResults}] ++
                        [{pagination_sort, PaginationSort} || PaginationSort =/= undefined],
                    Opts = riak_index:add_timeout_opt(Timeout, Opts0),
                    {ok, #{
                        bucket => bucket_ref(Context),
                        query => IndexQuery,
                        opts => Opts,
                        return_terms => ReturnTerms,
                        streamed => Streamed,
                        max_results => MaxResults
                    }};
                {error, Error} ->
                    {error, Error}
            end;
        {error, Reason} ->
            {error, index_query_error(Reason)};
        {'EXIT', Reason} ->
            {error, index_query_error(Reason)}
    end.

index_terms(Context) ->
    case maps:get(range, Context, undefined) of
        {Start, End} ->
            {Start, End, false};
        undefined ->
            Extras = maps:get(extras, Context, #{}),
            Term = maps:get(term, Extras, undefined),
            {Term, Term, true}
    end.

validate_index_term_regex(undefined, _IndexQuery) ->
    ok;
validate_index_term_regex(TermRegex, _IndexQuery)
  when byte_size(TermRegex) > 256 ->
    {error, #{
        status => 400,
        code => <<"invalid_query">>,
        reason => <<"term_regex exceeds maximum length (256 bytes)">>
    }};
validate_index_term_regex(TermRegex, IndexQuery) ->
    case re:compile(TermRegex) of
        {ok, _Compiled} ->
            case IndexQuery of
                ?KV_INDEX_Q{start_term=StartTerm} when is_integer(StartTerm) ->
                    {error, #{
                        status => 400,
                        code => <<"invalid_query">>,
                        reason => <<"Can not use term regular expressions on integer queries">>
                    }};
                _ ->
                    ok
            end;
        {error, _ReError} ->
            {error, #{
                status => 400,
                code => <<"invalid_query">>,
                reason => <<"Invalid term regular expression">>
            }}
    end.

list_index_reply(Request, Client) ->
    Bucket = maps:get(bucket, Request),
    Query = maps:get(query, Request),
    Opts = maps:get(opts, Request),
    ReturnTerms = maps:get(return_terms, Request),
    MaxResults = maps:get(max_results, Request),
    case riak_client:get_index(Bucket, Query, Opts, Client) of
        {ok, Results} ->
            Continuation = make_index_continuation(MaxResults, Results, length(Results)),
            Body = riak_kv_wm_index:encode_results(ReturnTerms, Results, Continuation),
            {ok, json_backend_reply(200, iolist_to_binary(Body))};
        {error, timeout} ->
            {error, object_error_map(timeout)};
        {error, Reason} ->
            {error, bucket_error_map(Reason)}
    end.

stream_index_reply(Request, Client) ->
    Bucket = maps:get(bucket, Request),
    Query = maps:get(query, Request),
    Opts = maps:get(opts, Request),
    ReturnTerms = maps:get(return_terms, Request),
    MaxResults = maps:get(max_results, Request),
    Boundary = list_to_binary(riak_core_util:unique_id_62()),
    case riak_client:stream_get_index(Bucket, Query, Opts, Client) of
        {ok, ReqId, FSMPid} ->
            %% Apply stream_collection_ceiling to prevent unbounded blocking,
            %% consistent with key and bucket stream paths.
            Timeout0 = proplists:get_value(timeout, Opts, infinity),
            Timeout = erlang:min(Timeout0, stream_collection_ceiling()),
            case stream_incremental_enabled() of
                true ->
                    %% S2 (CG-001): True incremental streaming
                    StreamInit = #{
                        status => 200,
                        content_type => <<"multipart/mixed;boundary=", Boundary/binary>>
                    },
                    ChunkFun = fun(Emit) ->
                        try
                            stream_index_chunked(
                                ReqId, FSMPid, Boundary, ReturnTerms,
                                MaxResults, Timeout, undefined, 0, Emit)
                        catch
                            ExnClass:ExnReason:ExnStack ->
                                catch whack_index_fsm(ReqId, FSMPid),
                                erlang:raise(ExnClass, ExnReason, ExnStack)
                        end
                    end,
                    {stream, StreamInit, ChunkFun};
                false ->
                    try
                        Body = collect_stream_index(
                            ReqId, FSMPid, Boundary, ReturnTerms, MaxResults,
                            Timeout, undefined, 0, []),
                        {ok, #{
                            status => 200,
                            body => Body,
                            content_type => <<"multipart/mixed;boundary=", Boundary/binary>>
                        }}
                    catch
                        ExnClass:ExnReason:ExnStack ->
                            catch whack_index_fsm(ReqId, FSMPid),
                            erlang:raise(ExnClass, ExnReason, ExnStack)
                    end
            end;
        {error, Reason} ->
            {error, bucket_error_map(Reason)}
    end.

collect_stream_index(ReqId, FSMPid, Boundary, ReturnTerms, MaxResults, Timeout, LastResult, Count, Acc) ->
    receive
        {ReqId, done} ->
            Final = index_stream_final(Boundary, MaxResults, LastResult, Count),
            iolist_to_binary(lists:reverse([Final | Acc]));
        {ReqId, {results, []}} ->
            collect_stream_index(
                ReqId, FSMPid, Boundary, ReturnTerms, MaxResults, Timeout, LastResult, Count, Acc);
        {ReqId, {results, Results}} ->
            JsonResults = riak_kv_wm_index:encode_results(ReturnTerms, Results),
            Part = [
                "\r\n--", Boundary, "\r\n",
                "Content-Type: application/json\r\n\r\n",
                JsonResults
            ],
            LastResult1 = index_last_result(Results),
            Count1 = Count + length(Results),
            collect_stream_index(
                ReqId, FSMPid, Boundary, ReturnTerms, MaxResults, Timeout,
                LastResult1, Count1, [Part | Acc]);
        {ReqId, Error} ->
            iolist_to_binary(lists:reverse([index_stream_error(Boundary, Error) | Acc]))
    after Timeout ->
        whack_index_fsm(ReqId, FSMPid),
        iolist_to_binary(lists:reverse([index_stream_error(Boundary, {error, timeout}) | Acc]))
    end.

%% S2 (CG-001): Incremental streaming for index queries.
stream_index_chunked(ReqId, FSMPid, Boundary, ReturnTerms, MaxResults,
                     Timeout, LastResult, Count, Emit) ->
    receive
        {ReqId, done} ->
            Final = index_stream_final(Boundary, MaxResults, LastResult, Count),
            Emit(iolist_to_binary(Final), fin);
        {ReqId, {results, []}} ->
            stream_index_chunked(
                ReqId, FSMPid, Boundary, ReturnTerms,
                MaxResults, Timeout, LastResult, Count, Emit);
        {ReqId, {results, Results}} ->
            JsonResults = riak_kv_wm_index:encode_results(ReturnTerms, Results),
            Part = iolist_to_binary([
                "\r\n--", Boundary, "\r\n",
                "Content-Type: application/json\r\n\r\n",
                JsonResults
            ]),
            Emit(Part, nofin),
            LastResult1 = index_last_result(Results),
            Count1 = Count + length(Results),
            stream_index_chunked(
                ReqId, FSMPid, Boundary, ReturnTerms,
                MaxResults, Timeout, LastResult1, Count1, Emit);
        {ReqId, Error} ->
            Emit(iolist_to_binary(index_stream_error(Boundary, Error)), fin)
    after Timeout ->
        whack_index_fsm(ReqId, FSMPid),
        Emit(iolist_to_binary(index_stream_error(Boundary, {error, timeout})), fin)
    end.

index_stream_final(Boundary, MaxResults, LastResult, Count) ->
    case make_index_continuation(MaxResults, [LastResult], Count) of
        undefined ->
            ["\r\n--", Boundary, "--\r\n"];
        Continuation ->
            Json = mochijson2:encode({struct, [{?Q_2I_CONTINUATION_BIN, Continuation}]}),
            [
                "\r\n--", Boundary, "\r\n",
                "Content-Type: application/json\r\n\r\n",
                Json,
                "\r\n--", Boundary, "--\r\n"
            ]
    end.

index_stream_error(Boundary, Error) ->
    ErrorJson = encode_index_error(Error),
    [
        "\r\n--", Boundary, "\r\n",
        "Content-Type: application/json\r\n\r\n",
        ErrorJson,
        "\r\n--", Boundary, "--\r\n"
    ].

encode_index_error({error, E}) ->
    encode_index_error(E);
encode_index_error(Error) ->
    encode_stream_error(Error).

whack_index_fsm(ReqId, Pid) when is_pid(Pid) ->
    wait_for_death(Pid),
    clear_index_fsm_msgs(ReqId);
whack_index_fsm(_ReqId, _Pid) ->
    ok.

wait_for_death(Pid) ->
    Ref = erlang:monitor(process, Pid),
    exit(Pid, kill),
    receive
        {'DOWN', Ref, process, Pid, _Info} ->
            ok
    end.

clear_index_fsm_msgs(ReqId) ->
    receive
        {ReqId, _} ->
            clear_index_fsm_msgs(ReqId)
    after
        0 ->
            ok
    end.

index_last_result([]) ->
    undefined;
index_last_result(Results) ->
    lists:last(Results).

make_index_continuation(MaxResults, Results, MaxResults) when MaxResults =/= all ->
    riak_index:make_continuation(Results);
make_index_continuation(_, _, _) ->
    undefined.

normalize_boolean_query(Value, Default) ->
    case normalize_boolean(Value) of
        true -> true;
        false -> false;
        _ -> Default
    end.

query_operation(Context, Input, Client) ->
    Bucket = bucket_ref(Context),
    case query_body_map(Input) of
        {ok, QueryMap} ->
            case validate_query_request_body(QueryMap) of
                ok ->
                    case make_complex_query(Bucket, QueryMap) of
                        {ok, Query0} ->
                            AccOpt = riak_kv_query:get_accumulator(Query0),
                            {ok, Query} = riak_kv_query:add_result_encodingfun(
                                Query0,
                                query_encoding_function(AccOpt)),
                            execute_query(Query, AccOpt, Client);
                        {error, Stage, Reason} ->
                            {error, query_validation_error(Stage, Reason)}
                    end;
                {error, Reason} ->
                    {error, query_invalid_body_error(Reason)}
            end;
        {error, Reason} ->
            {error, query_invalid_body_error(Reason)}
    end.

query_body_map(Input) ->
    case maps:get(json, Input, undefined) of
        Json when is_map(Json) ->
            {ok, Json};
        _ ->
            decode_query_json_body(maps:get(body, Input, <<>>))
    end.

decode_query_json_body(Body) ->
    try
        case riak_kv_wm_json:decode(Body) of
            JsonBody when is_map(JsonBody) ->
                {ok, JsonBody};
            _ ->
                {error, <<"Body must be a JSON object">>}
        end
    catch
        error:Reason ->
            logger:info("[riak_admin] query JSON decode error: ~p", [Reason]),
            {error, <<"Malformed JSON in request body">>}
    end.

validate_query_request_body(QueryMap) ->
    case check_query_keys(maps:keys(QueryMap), request) of
        ok ->
            QueryList = maps:get(?QUERY_KEY_QUERY_LIST, QueryMap, []),
            check_query_list(QueryList, false);
        {error, Reason} ->
            {error, Reason}
    end.

check_query_list([], true) ->
    ok;
check_query_list([], false) ->
    {error, <<"No valid query provided">>};
check_query_list([HeadQuery | Rest], _AtLeastOne) when is_map(HeadQuery) ->
    case check_query_keys(maps:keys(HeadQuery), query) of
        ok ->
            check_query_list(Rest, true);
        {error, Reason} ->
            {error, Reason}
    end;
check_query_list(_, _AtLeastOne) ->
    {error, <<"No valid query provided">>}.

check_query_keys(Keys, request) ->
    check_query_keys(
        Keys,
        [?QUERY_KEY_QUERY_LIST],
        [
            ?QUERY_KEY_AGGREGATION_EXPRESSION,
            ?QUERY_KEY_ACCUMULATION_OPTION,
            ?QUERY_KEY_ACCUMULATION_TERM,
            ?QUERY_KEY_SUBSTITUTIONS,
            ?QUERY_KEY_TIMEOUT,
            ?QUERY_KEY_QUERY_LIST,
            ?QUERY_KEY_MAX_RESULTS,
            ?QUERY_KEY_CONTINUATION
        ]);
check_query_keys(Keys, query) ->
    check_query_keys(
        Keys,
        [
            ?QUERY_KEY_QL_INDEX_NAME,
            ?QUERY_KEY_QL_START_TERM,
            ?QUERY_KEY_QL_END_TERM
        ],
        [
            ?QUERY_KEY_QL_AGGREGATION_TAG,
            ?QUERY_KEY_QL_INDEX_NAME,
            ?QUERY_KEY_QL_START_TERM,
            ?QUERY_KEY_QL_END_TERM,
            ?QUERY_KEY_QL_REGULAR_EXPRESSION,
            ?QUERY_KEY_QL_EVALUATION_EXPRESSION,
            ?QUERY_KEY_QL_FILTER_EXPRESSION
        ]).

check_query_keys(Keys, RequiredKeys, PossibleKeys) ->
    RequiredKeyList = lists:filter(
        fun(Key) -> lists:member(Key, Keys) end,
        RequiredKeys),
    PossibleKeyList = lists:filter(
        fun(Key) -> lists:member(Key, PossibleKeys) end,
        Keys),
    case RequiredKeyList of
        RequiredKeys ->
            case PossibleKeyList of
                Keys ->
                    ok;
                _NotAllKeys ->
                    ExtraKeys = lists:subtract(Keys, PossibleKeyList),
                    {error, iolist_to_binary([
                        <<"Unexpected keys in request: ">>,
                        lists:join(<<", ">>, ExtraKeys)])}
            end;
        _NotAllRequiredKeys ->
            MissingKeys = lists:subtract(RequiredKeys, RequiredKeyList),
            {error, iolist_to_binary([
                <<"Missing required keys in request: ">>,
                lists:join(<<", ">>, MissingKeys)])}
    end.

make_complex_query(BucketType, QueryMap) ->
    TimeoutDefault = application:get_env(riak_kv, query_timeout_secs, ?QUERY_DEFAULT_TIMEOUT_SECS),
    Timeout = maps:get(?QUERY_KEY_TIMEOUT, QueryMap, TimeoutDefault),
    case Timeout of
        T when is_integer(T), T > 0 ->
            QueryList = maps:get(?QUERY_KEY_QUERY_LIST, QueryMap),
            InitQuery = case length(QueryList) of
                1 ->
                    riak_kv_query:new(BucketType, single_query, Timeout);
                _ ->
                    riak_kv_query:new(BucketType, combo_query, Timeout)
            end,
            case add_query_accumulation(QueryMap, InitQuery) of
                {ok, Query1} ->
                    case add_query_definitions(QueryMap, Query1, QueryList) of
                        {ok, Query2} ->
                            case maps:get(?QUERY_KEY_CONTINUATION, QueryMap, none) of
                                none ->
                                    {ok, Query2};
                                Continuation ->
                                    riak_kv_query:add_continuation(Query2, Continuation)
                            end;
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        _ ->
            {error, init, <<"Bad timeout">>}
    end.

add_query_accumulation(QueryMap, InitQuery) ->
    AccOpt = maps:get(?QUERY_KEY_ACCUMULATION_OPTION, QueryMap, undefined),
    AccTerm = maps:get(?QUERY_KEY_ACCUMULATION_TERM, QueryMap, undefined),
    MaxResults = maps:get(?QUERY_KEY_MAX_RESULTS, QueryMap, undefined),
    case riak_kv_query:add_accumulation_option(InitQuery, AccOpt) of
        {ok, Query0} ->
            case riak_kv_query:add_accumulation_term(Query0, AccTerm) of
                {ok, Query1} ->
                    case MaxResults of
                        undefined ->
                            {ok, Query1};
                        Value ->
                            riak_kv_query:add_maxresults(Query1, Value)
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

add_query_definitions(QueryMap, Query, QueryList) ->
    AggExpr = maps:get(?QUERY_KEY_AGGREGATION_EXPRESSION, QueryMap, undefined),
    case riak_kv_query:add_aggregation_expression(Query, AggExpr) of
        {ok, Query0} ->
            Subs = maps:get(?QUERY_KEY_SUBSTITUTIONS, QueryMap, maps:new()),
            riak_kv_query:add_queries(Query0, lists:map(fun convert_query_map/1, QueryList), Subs);
        Error ->
            Error
    end.

convert_query_map(QueryMap) ->
    {
        maps:get(?QUERY_KEY_QL_AGGREGATION_TAG, QueryMap, undefined),
        maps:get(?QUERY_KEY_QL_INDEX_NAME, QueryMap),
        maps:get(?QUERY_KEY_QL_START_TERM, QueryMap),
        maps:get(?QUERY_KEY_QL_END_TERM, QueryMap),
        maps:get(?QUERY_KEY_QL_REGULAR_EXPRESSION, QueryMap, undefined),
        maps:get(?QUERY_KEY_QL_EVALUATION_EXPRESSION, QueryMap, undefined),
        maps:get(?QUERY_KEY_QL_FILTER_EXPRESSION, QueryMap, undefined)
    }.

query_encoding_function(AccOpt) ->
    fun(Results) -> encode_query_results(AccOpt, Results) end.

encode_query_results(keys, Results) ->
    iolist_to_binary(
        riak_kv_wm_json:encode(
            #{?QUERY_RESULT_KEYS => Results},
            fun encode_query_key/2));
encode_query_results(raw_keys, Results) ->
    iolist_to_binary(
        riak_kv_wm_json:encode(
            #{?QUERY_RESULT_RAWKEYS => Results},
            fun encode_query_key/2));
encode_query_results(terms, Results) ->
    iolist_to_binary(
        riak_kv_wm_json:encode(
            #{?QUERY_RESULT_TERMS => Results},
            fun encode_query_key_with_term/2));
encode_query_results(raw_terms, Results) ->
    iolist_to_binary(
        riak_kv_wm_json:encode(
            #{?QUERY_RESULT_RAWTERMS => Results},
            fun encode_query_key_with_term/2));
encode_query_results(raw_count, Count) ->
    iolist_to_binary(riak_kv_wm_json:encode(#{?QUERY_RESULT_RAWCOUNT => Count}));
encode_query_results(count, Count) ->
    iolist_to_binary(riak_kv_wm_json:encode(#{?QUERY_RESULT_COUNT => Count}));
encode_query_results(term_with_rawcount, CountMap) ->
    iolist_to_binary(riak_kv_wm_json:encode(#{?QUERY_RESULT_TERMRAWCOUNT => CountMap}));
encode_query_results(term_with_count, CountMap) ->
    iolist_to_binary(riak_kv_wm_json:encode(#{?QUERY_RESULT_TERMCOUNT => CountMap})).

encode_query_key({{_Term, Key}}, Encode) when is_binary(Key) ->
    encode_query_key(Key, Encode);
encode_query_key({Key}, Encode) when is_binary(Key) ->
    encode_query_key(Key, Encode);
encode_query_key(Key, Encode) ->
    riak_kv_wm_json:encode_value(Key, Encode).

encode_query_key_with_term({TermKeyTuple}, Encode) when is_tuple(TermKeyTuple) ->
    encode_query_key_with_term(TermKeyTuple, Encode);
encode_query_key_with_term({Term, Key}, Encode) when is_binary(Term), is_binary(Key) ->
    [123, [Encode(Term, Encode), $: | Encode(Key, Encode)], 125];
encode_query_key_with_term(Result, Encode) ->
    riak_kv_wm_json:encode_value(Result, Encode).

execute_query(Query, AccOpt, Client) ->
    case riak_client:query(Query, Client) of
        {error, timeout} ->
            {error, object_error_map(timeout)};
        {error, Reason} ->
            logger:warning("[riak_admin] query failed (option=~w): ~p",
                           [AccOpt, Reason]),
            {error, #{
                status => 500,
                code => <<"backend_error">>,
                reason => <<"Query operation failed">>
            }};
        {JsonEncodedResults, none} when is_binary(JsonEncodedResults) ->
            {ok, json_backend_reply(200, JsonEncodedResults)};
        {JsonEncodedResults, {{LastTerm, LastKey}}}
                when
                    is_binary(JsonEncodedResults),
                    is_binary(LastTerm),
                    is_binary(LastKey) ->
            Continuation = riak_kv_query:make_continuation(LastTerm, LastKey),
            {ok, (json_backend_reply(200, JsonEncodedResults))#{
                headers => #{?QUERY_CONTINUATION_HEADER => to_bin(Continuation)}
            }};
        Other ->
            logger:warning("[riak_admin] unexpected query reply: ~p", [Other]),
            {error, #{
                status => 500,
                code => <<"backend_error">>,
                reason => <<"Unexpected query result">>
            }}
    end.

query_invalid_body_error(Reason) ->
    invalid_body_error(Reason).

query_validation_error(Stage, Reason) ->
    logger:info("[riak_admin] query validation failure at ~p: ~p",
                [Stage, Reason]),
    #{
        status => 400,
        code => <<"invalid_query">>,
        reason => <<"Query validation failed">>
    }.

mapred_operation(Context, Input, _Client) ->
    case mapred_backend_enabled() of
        false ->
            {error, mapred_disabled_error()};
        true ->
            mapred_operation_checked(Context, Input)
    end.

mapred_operation_checked(Context, Input) ->
    case mapred_body_map(Input) of
        {error, Reason} ->
            {error, mapred_invalid_body_error(Reason)};
        {ok, BodyMap} ->
            case validate_mapred_body(BodyMap) of
                {error, Reason} ->
                    {error, mapred_invalid_body_error(Reason)};
                ok ->
                    case mapred_backend_available() of
                        true -> mapred_operation_legacy(Context, Input);
                        false -> {error, mapred_unavailable_error()}
                    end
            end
    end.

mapred_body_map(Input) ->
    case maps:get(json, Input, undefined) of
        Json when is_map(Json) ->
            {ok, Json};
        _ ->
            decode_query_json_body(maps:get(body, Input, <<>>))
    end.

validate_mapred_body(BodyMap) ->
    Inputs = maps:get(?MAPRED_KEY_INPUTS, BodyMap, undefined),
    Query = maps:get(?MAPRED_KEY_QUERY, BodyMap, undefined),
    case {Inputs, Query} of
        {undefined, _} ->
            {error, <<"The POST body was missing the \"inputs\" or \"query\" field.">>};
        {_, undefined} ->
            {error, <<"The POST body was missing the \"inputs\" or \"query\" field.">>};
        {_Inputs, QueryPhases} when not is_list(QueryPhases) ->
            {error, <<"The value of the \"query\" field was not a list">>};
        _ ->
            ok
    end.

mapred_backend_available() ->
    code:which(riak_kv_mapred_json) =/= non_existing andalso
    code:which(riak_kv_mrc_pipe) =/= non_existing.

%% S2 (CG-006): Operator toggle for MapReduce backend.
%% When false, mapred_operation returns 503 immediately (operator-disabled).
%% When true (default), falls through to mapred_backend_available/0 which
%% checks module presence (returns 501 if absent).
mapred_backend_enabled() ->
    application:get_env(riak_admin_api, mapred_backend_enabled, true).

mapred_unavailable_error() ->
    #{
        status => 501,
        code => <<"not_implemented">>,
        reason => <<"MapReduce backend unavailable in this build">>
    }.

mapred_disabled_error() ->
    #{
        status => 503,
        code => <<"service_unavailable">>,
        reason => <<"MapReduce backend disabled by operator configuration">>
    }.

mapred_invalid_body_error(Reason) ->
    invalid_body_error(Reason).

mapred_operation_legacy(Context, Input) ->
    Body = maps:get(body, Input, <<>>),
    QueryParams = maps:get(query, Context, #{}),
    Chunked = query_truthy(<<"chunked">>, QueryParams),
    case riak_kv_mapred_json:parse_request(Body) of
        {ok, ParsedInputs, ParsedQuery, Timeout} ->
            case riak_kv_mrc_pipe:mapred_stream_sink(ParsedInputs, ParsedQuery, Timeout) of
                {ok, Mrc} ->
                    try
                        case Chunked of
                            true ->
                                mapred_collect_chunked_reply(Mrc, ParsedQuery);
                            _ ->
                                mapred_collect_nonchunked_reply(Mrc, ParsedQuery)
                        end
                    catch
                        ExnClass:ExnReason:ExnStack ->
                            catch riak_kv_mrc_pipe:destroy_sink(Mrc),
                            erlang:raise(ExnClass, ExnReason, ExnStack)
                    end;
                {error, {Fitting, Reason}} ->
                    logger:info("[riak_admin] mapred phase error at ~p: ~p",
                                [Fitting, Reason]),
                    {error, #{
                        status => 400,
                        code => <<"invalid_query">>,
                        reason => <<"MapReduce phase configuration error">>
                    }}
            end;
        {error, Reason} ->
            {error, mapred_parse_error(Reason)}
    end.

mapred_collect_nonchunked_reply(Mrc, ParsedQuery) ->
    case riak_kv_mrc_pipe:collect_sink(Mrc) of
        {ok, Results} ->
            HasMRQuery = ParsedQuery =/= [],
            JsonResults = mapred_jsonify_results(Results),
            JsonResults1 = riak_kv_mapred_json:jsonify_bkeys(JsonResults, HasMRQuery),
            riak_kv_mrc_pipe:cleanup_sink(Mrc),
            {ok, json_backend_reply(200, mochijson2:encode(JsonResults1))};
        {error, {sender_died, Error}} ->
            riak_kv_mrc_pipe:cleanup_sink(Mrc),
            {error, mapred_backend_error(Error)};
        {error, {sink_died, Error}} ->
            riak_kv_mrc_pipe:cleanup_sink(Mrc),
            {error, mapred_backend_error(Error)};
        {error, timeout} ->
            riak_kv_mrc_pipe:destroy_sink(Mrc),
            %% S1 (CG-005/CG-018): Unified timeout to 503 for consistency
            %% with query_operation timeout mapping.
            {error, mapred_timeout_error_map()};
        {error, {From, Info}} ->
            riak_kv_mrc_pipe:destroy_sink(Mrc),
            Json = riak_kv_mapred_json:jsonify_pipe_error(From, Info),
            {error, mapred_backend_error(iolist_to_binary(mochijson2:encode(Json)))}
    end.

mapred_collect_chunked_reply(Mrc, ParsedQuery) ->
    Boundary = list_to_binary(riak_core_util:unique_id_62()),
    HasMRQuery = ParsedQuery =/= [],
    case stream_incremental_enabled() of
        true ->
            %% S2 (CG-001): True incremental streaming for chunked mapred
            StreamInit = #{
                status => 200,
                content_type => <<"multipart/mixed;boundary=", Boundary/binary>>
            },
            ChunkFun = fun(Emit) ->
                try
                    mapred_stream_chunked_parts(Mrc, Boundary, HasMRQuery, Emit)
                catch
                    ExnClass:ExnReason:ExnStack ->
                        catch riak_kv_mrc_pipe:destroy_sink(Mrc),
                        erlang:raise(ExnClass, ExnReason, ExnStack)
                end
            end,
            {stream, StreamInit, ChunkFun};
        false ->
            case mapred_collect_chunked_parts(Mrc, Boundary, HasMRQuery, []) of
                {ok, Body} ->
                    {ok, #{
                        status => 200,
                        body => Body,
                        content_type => <<"multipart/mixed;boundary=", Boundary/binary>>
                    }};
                {error, ErrorMap} ->
                    {error, ErrorMap}
            end
    end.

mapred_collect_chunked_parts(Mrc, Boundary, HasMRQuery, Acc) ->
    case riak_kv_mrc_pipe:receive_sink(Mrc) of
        {ok, Done, Outputs} ->
            Parts = [mapred_result_part(Output, HasMRQuery, Boundary) || Output <- Outputs],
            Acc1 = [Acc, Parts],
            case Done of
                true ->
                    riak_kv_mrc_pipe:cleanup_sink(Mrc),
                    {ok, iolist_to_binary([Acc1, <<"\r\n--", Boundary/binary, "--\r\n">>])};
                false ->
                    mapred_collect_chunked_parts(Mrc, Boundary, HasMRQuery, Acc1)
            end;
        {error, timeout, _} ->
            riak_kv_mrc_pipe:destroy_sink(Mrc),
            %% S1 (CG-005/CG-018): Unified timeout to 503
            {error, mapred_timeout_error_map()};
        {error, {sender_died, Error}, _} ->
            riak_kv_mrc_pipe:cleanup_sink(Mrc),
            {error, mapred_backend_error(Error)};
        {error, {sink_died, Error}, _} ->
            riak_kv_mrc_pipe:cleanup_sink(Mrc),
            {error, mapred_backend_error(Error)};
        {error, {From, Info}, _} ->
            riak_kv_mrc_pipe:destroy_sink(Mrc),
            Json = riak_kv_mapred_json:jsonify_pipe_error(From, Info),
            {error, mapred_backend_error(iolist_to_binary(mochijson2:encode(Json)))}
    end.

%% S2 (CG-001): Incremental streaming for chunked mapreduce.
mapred_stream_chunked_parts(Mrc, Boundary, HasMRQuery, Emit) ->
    case riak_kv_mrc_pipe:receive_sink(Mrc) of
        {ok, Done, Outputs} ->
            Parts = [mapred_result_part(Output, HasMRQuery, Boundary)
                     || Output <- Outputs],
            case Done of
                true ->
                    riak_kv_mrc_pipe:cleanup_sink(Mrc),
                    Final = iolist_to_binary(
                        [Parts, <<"\r\n--", Boundary/binary, "--\r\n">>]),
                    Emit(Final, fin);
                false ->
                    case Parts of
                        [] -> ok;
                        _ -> Emit(iolist_to_binary(Parts), nofin)
                    end,
                    mapred_stream_chunked_parts(Mrc, Boundary, HasMRQuery, Emit)
            end;
        {error, timeout, _} ->
            riak_kv_mrc_pipe:destroy_sink(Mrc),
            %% S5 (M-7): Use mochijson2 for stream error framing
            %% consistency with bucket/key/index stream errors.
            ErrorJson = encode_stream_error(timeout),
            Emit(mapred_error_part(ErrorJson, Boundary), fin);
        {error, {Died, Error}, _} when Died =:= sender_died;
                                        Died =:= sink_died ->
            riak_kv_mrc_pipe:cleanup_sink(Mrc),
            ErrorJson = encode_stream_error(Error),
            Emit(mapred_error_part(ErrorJson, Boundary), fin);
        {error, {From, Info}, _} ->
            riak_kv_mrc_pipe:destroy_sink(Mrc),
            Json = riak_kv_mapred_json:jsonify_pipe_error(From, Info),
            Emit(mapred_error_part(mochijson2:encode(Json), Boundary), fin)
    end.

mapred_jsonify_results(Results) ->
    case Results of
        [First | _] when is_list(First) ->
            [[riak_kv_mapred_json:jsonify_not_found(PhaseResult)
              || PhaseResult <- PhaseResults]
             || PhaseResults <- Results];
        _ ->
            [riak_kv_mapred_json:jsonify_not_found(Result) || Result <- Results]
    end.

mapred_result_part({PhaseId, Results}, HasMRQuery, Boundary) ->
    Data = riak_kv_mapred_json:jsonify_bkeys(
        [riak_kv_mapred_json:jsonify_not_found(Result) || Result <- Results],
        HasMRQuery),
    Json = mochijson2:encode({struct, [{phase, PhaseId}, {data, Data}]}),
    [
        "\r\n--", Boundary, "\r\n",
        "Content-Type: application/json\r\n\r\n",
        Json
    ];
mapred_result_part(Other, _HasMRQuery, Boundary) ->
    Json = mochijson2:encode({struct, [{data, Other}]}),
    [
        "\r\n--", Boundary, "\r\n",
        "Content-Type: application/json\r\n\r\n",
        Json
    ].

mapred_error_part(ErrorJson, Boundary) ->
    iolist_to_binary([
        "\r\n--", Boundary, "\r\n",
        "Content-Type: application/json\r\n\r\n",
        ErrorJson,
        "\r\n--", Boundary, "--\r\n"
    ]).

mapred_parse_error({'query', Reason}) ->
    logger:info("[riak_admin] mapred query parse error: ~p", [Reason]),
    mapred_invalid_body_error(<<"An error occurred parsing the \"query\" field.">>);
mapred_parse_error({inputs, Reason}) ->
    logger:info("[riak_admin] mapred inputs parse error: ~p", [Reason]),
    mapred_invalid_body_error(<<"An error occurred parsing the \"inputs\" field.">>);
mapred_parse_error(missing_field) ->
    mapred_invalid_body_error(<<"The POST body was missing the \"inputs\" or \"query\" field.">>);
mapred_parse_error({invalid_json, _Message}) ->
    mapred_invalid_body_error(<<"The POST body was not valid JSON.">>);
mapred_parse_error(not_json) ->
    mapred_invalid_body_error(<<"The POST body was not a JSON object.">>);
mapred_parse_error(Reason) ->
    logger:info("[riak_admin] mapred parse error: ~p", [Reason]),
    mapred_invalid_body_error(<<"Invalid MapReduce request">>).

mapred_backend_error(Reason) ->
    logger:warning("[riak_admin] mapred backend error: ~p", [Reason]),
    #{
        status => 500,
        code => <<"backend_error">>,
        reason => <<"MapReduce operation failed">>
    }.

%% @doc Unified mapred timeout error map.
%%
%% S1 (CG-005/CG-018): MapReduce timeouts now return 503 instead of
%% 500, consistent with query_operation timeout mapping. This ensures
%% clients get a uniform timeout contract across all query-like paths.
-spec mapred_timeout_error_map() -> map().
mapred_timeout_error_map() ->
    #{status => 503, code => <<"timeout">>, reason => <<"timeout">>}.

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
%% S1 (CG-015): Reachability is now determined by parallel pings
%% with a bounded timeout instead of sequential net_adm:ping/1.
%% This prevents a single unreachable node from blocking the
%% entire cluster_status response for its full TCP timeout.
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

        %% S1: Parallel pings with bounded timeout (CG-015)
        PingTimeout = application:get_env(
            riak_admin_api, cluster_status_ping_timeout, 3000),
        Reachability = parallel_ping_nodes(Members, PingTimeout),

        Nodes = lists:map(
            fun(Node) ->
                Status = proplists:get_value(Node, MemberStatus, unknown),
                Count = maps:get(Node, OwnerCounts, 0),
                Pct = round_pct(Count, NumPartitions),
                Reachable = maps:get(Node, Reachability, false),
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

%% @doc Ping multiple nodes in parallel with a bounded timeout.
%%
%% S1 (CG-015): Spawns one process per node, each calling
%% net_adm:ping/1. The caller waits up to PingTimeout ms for all
%% responses. Nodes that don't respond in time are marked unreachable.
%% This bounds the total cluster_status latency to PingTimeout
%% regardless of how many nodes are unreachable.
-spec parallel_ping_nodes([node()], pos_integer()) -> #{node() => boolean()}.
parallel_ping_nodes(Nodes, PingTimeout) ->
    Parent = self(),
    Ref = make_ref(),
    Pids = lists:map(
        fun(Node) ->
            {Pid, _Mon} = spawn_monitor(fun() ->
                Result = (net_adm:ping(Node) =:= pong),
                Parent ! {Ref, Node, Result}
            end),
            Pid
        end, Nodes),
    Results = collect_ping_results(Ref, length(Nodes), PingTimeout, #{}),
    %% Kill timed-out processes and flush their DOWN messages
    lists:foreach(fun(Pid) ->
        exit(Pid, kill)
    end, Pids),
    flush_ping_monitors(Ref, Pids),
    Results.

collect_ping_results(_Ref, 0, _Timeout, Acc) ->
    Acc;
collect_ping_results(Ref, Remaining, Timeout, Acc) ->
    receive
        {Ref, Node, Result} ->
            collect_ping_results(Ref, Remaining - 1, Timeout,
                                 Acc#{Node => Result})
    after Timeout ->
        %% Remaining nodes are unreachable (timed out)
        Acc
    end.

flush_ping_monitors(_Ref, []) ->
    ok;
flush_ping_monitors(Ref, Pids) ->
    receive
        {Ref, _Node, _Result} ->
            flush_ping_monitors(Ref, Pids);
        {'DOWN', _Mon, process, Pid, _Reason} ->
            flush_ping_monitors(Ref, lists:delete(Pid, Pids))
    after 0 ->
        ok
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
%%
%% S5 (M-2): Functionally identical to riak_admin_api_response:to_binary/1.
%% Kept as a local alias (60+ call sites) to avoid a high-churn rename.
%% The canonical shared version lives in the response module.
-spec to_bin(term()) -> binary().
to_bin(V) when is_binary(V) -> V;
to_bin(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_bin(V) when is_integer(V) -> integer_to_binary(V);
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
%% Meta is term() per syn's API — guard against non-map metadata
%% (possible during cluster convergence or corrupt registrations).
-spec format_dc_member({pid(), term()}, binary()) -> dc_info().
format_dc_member({_Pid, Meta}, LocalDC) when is_map(Meta) ->
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
    };
format_dc_member({_Pid, _Meta}, _LocalDC) ->
    #{
        name => <<"unknown">>,
        local => false,
        admin_url => <<"http://127.0.0.1:8099">>,
        riak_url => <<"http://127.0.0.1:8098">>,
        riak_version => <<"unknown">>,
        node => unknown,
        reachable => true,
        started_at => 0
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
        {"integer conversion",
         fun() -> ?assertEqual(<<"42">>, to_bin(42)) end},
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
