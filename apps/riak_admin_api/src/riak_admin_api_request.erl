%% @doc Shared Cowboy request normalization and security hooks.

-module(riak_admin_api_request).

-export([
    normalize/2,
    normalize_path/3,
    normalize_query/1,
    normalize_headers/1,
    ensure_security/2
]).

-type request_context() :: map().

-define(DEFAULT_BUCKET_TYPE, <<"default">>).

-spec normalize(cowboy_req:req(), map()) ->
    {ok, request_context(), cowboy_req:req()} |
    {error, map(), cowboy_req:req()}.
normalize(Req0, Opts) ->
    Method = request_method(Req0),
    Path = request_path(Req0),
    Headers0 = request_headers(Req0),
    Query0 = request_query(Req0),
    case normalize_headers(Headers0) of
        {error, Err0} ->
            {error, Err0, Req0};
        {ok, HeaderMeta} ->
            RequestId = maps:get(request_id, HeaderMeta),
            Headers = maps:remove(request_id, HeaderMeta),
            case normalize_query(Query0) of
                {error, Err1} ->
                    {error, with_request_id(Err1, RequestId), Req0};
                {ok, Query} ->
                    case normalize_path(Method, Path, Query) of
                        {error, Err2} ->
                            {error, with_request_id(Err2, RequestId), Req0};
                        {ok, PathCtx} ->
                            Context0 = PathCtx#{
                                method => Method,
                                route => Path,
                                query => Query,
                                headers => Headers,
                                request_id => RequestId
                            },
                            case ensure_allowed_query(Context0) of
                                ok ->
                                    case ensure_allowed_method(Method, Context0) of
                                        ok ->
                                            case ensure_security(Context0, Opts) of
                                                ok ->
                                                    {ok, Context0, Req0};
                                                {error, Err3} ->
                                                    {error, with_request_id(Err3, RequestId), Req0}
                                            end;
                                        {error, Err4} ->
                                            {error, with_request_id(Err4, RequestId), Req0}
                                    end;
                                {error, Err5} ->
                                    {error, with_request_id(Err5, RequestId), Req0}
                            end
                    end
            end
    end.

-spec normalize_path(binary(), binary() | list(), map()) ->
    {ok, request_context()} | {error, map()}.
normalize_path(Method, Path0, Query) ->
    Path = to_binary(Path0),
    Query1 = ensure_stream_mode(Query),
    case validate_path_shape(Path) of
        ok ->
            Segments = path_segments(Path),
            case Segments of
                [<<"riak">> | Tail] -> normalize_riak(Method, Tail, Query1);
                [<<"buckets">> | Tail] -> normalize_buckets(Method, Tail, Query1);
                [<<"types">>, BucketType | Tail] ->
                    normalize_types(Method, BucketType, Tail, Query1);
                _ ->
                    {error, #{
                        status => 404,
                        code => <<"unknown_route">>,
                        reason => <<"Route does not match Cowboy substrate aliases">>
                    }}
            end;
        {error, Error} ->
            {error, Error}
    end.

ensure_stream_mode(Query) ->
    case maps:is_key(stream_mode, Query) of
        true -> Query;
        false -> Query#{stream_mode => detect_stream_mode(Query)}
    end.

-spec normalize_query(map()) -> {ok, map()} | {error, map()}.
normalize_query(Query0) when is_map(Query0) ->
    case normalize_query_entries(maps:to_list(Query0), Query0) of
        {ok, Query1} ->
            StreamMode = detect_stream_mode(Query0),
            {ok, Query1#{stream_mode => StreamMode}};
        Error ->
            Error
    end;
normalize_query(_) ->
    {ok, #{stream_mode => none}}.

-spec normalize_headers(map()) -> {ok, map()} | {error, map()}.
normalize_headers(Headers0) when is_map(Headers0) ->
    Headers = maps:from_list([
        {header_name(K), to_binary(V)}
        || {K, V} <- maps:to_list(Headers0)
    ]),
    RequestId = case maps:get(<<"x-request-id">>, Headers, undefined) of
        undefined -> generate_request_id();
        <<>> -> generate_request_id();
        Value -> Value
    end,
    {ok, Headers#{request_id => RequestId}};
normalize_headers(_) ->
    {ok, #{request_id => generate_request_id()}}.

-spec ensure_security(request_context(), map()) -> ok | {error, map()}.
ensure_security(Context, Opts) ->
    case ensure_tls(Context, Opts) of
        ok ->
            case ensure_origin(Context, Opts) of
                ok ->
                    case run_security_hook(authn_fun, Context, Opts) of
                        ok -> run_security_hook(authz_fun, Context, Opts);
                        Error -> Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

normalize_riak(Method, Tail, Query) ->
    case Tail of
        [] ->
            {ok, base_context(buckets, riak, Query)};
        [Bucket] ->
            Op = resolve_riak_bucket_op(Method, Query),
            {ok, (base_context(Op, riak, Query))#{bucket => Bucket}};
        [Bucket, Key] ->
            {ok, (base_context(object_item, riak, Query))#{
                bucket => Bucket,
                key => Key
            }};
        _ ->
            {error, #{
                status => 404,
                code => <<"unknown_route">>,
                reason => <<"Unsupported /riak path shape">>
            }}
    end.

normalize_buckets(Method, Tail, Query) ->
    case Tail of
        [] ->
            {ok, base_context(buckets, buckets, Query)};
        [Bucket, <<"props">>] ->
            {ok, (base_context(bucket_props, buckets, Query))#{bucket => Bucket}};
        [Bucket, <<"keys">>] ->
            Op = case Method of
                <<"POST">> -> object_collection;
                _ -> keys
            end,
            {ok, (base_context(Op, buckets, Query))#{bucket => Bucket}};
        [Bucket, <<"keys">>, Key] ->
            {ok, (base_context(object_item, buckets, Query))#{
                bucket => Bucket,
                key => Key
            }};
        [Bucket, <<"index">>, Field, Term] ->
            {ok, (base_context(index_query, buckets, Query))#{
                bucket => Bucket,
                field => Field,
                extras => #{term => Term}
            }};
        [Bucket, <<"index">>, Field, Start, End] ->
            {ok, (base_context(index_query, buckets, Query))#{
                bucket => Bucket,
                field => Field,
                range => {Start, End}
            }};
        _ ->
            {error, #{
                status => 404,
                code => <<"unknown_route">>,
                reason => <<"Unsupported /buckets path shape">>
            }}
    end.

normalize_types(Method, BucketType, Tail, Query) ->
    case Tail of
        [<<"props">>] ->
            {ok, (base_context(bucket_type_props, types, Query, BucketType))#{
                bucket_type => BucketType
            }};
        [<<"buckets">>] ->
            {ok, base_context(buckets, types, Query, BucketType)};
        [<<"buckets">>, Bucket, <<"props">>] ->
            {ok, (base_context(bucket_props, types, Query, BucketType))#{
                bucket => Bucket
            }};
        [<<"buckets">>, Bucket, <<"keys">>] ->
            Op = case Method of
                <<"POST">> -> object_collection;
                _ -> keys
            end,
            {ok, (base_context(Op, types, Query, BucketType))#{bucket => Bucket}};
        [<<"buckets">>, Bucket, <<"keys">>, Key] ->
            {ok, (base_context(object_item, types, Query, BucketType))#{
                bucket => Bucket,
                key => Key
            }};
        [<<"buckets">>, Bucket, <<"index">>, Field, Term] ->
            {ok, (base_context(index_query, types, Query, BucketType))#{
                bucket => Bucket,
                field => Field,
                extras => #{term => Term}
            }};
        [<<"buckets">>, Bucket, <<"index">>, Field, Start, End] ->
            {ok, (base_context(index_query, types, Query, BucketType))#{
                bucket => Bucket,
                field => Field,
                range => {Start, End}
            }};
        _ ->
            {error, #{
                status => 404,
                code => <<"unknown_route">>,
                reason => <<"Unsupported /types path shape">>
            }}
    end.

base_context(Op, Alias, Query) ->
    base_context(Op, Alias, Query, ?DEFAULT_BUCKET_TYPE).

base_context(Op, Alias, Query, BucketType) ->
    #{
        op => Op,
        bucket_type => BucketType,
        bucket => undefined,
        key => undefined,
        field => undefined,
        range => undefined,
        extras => #{},
        query => Query,
        alias => Alias,
        api_version => alias_version(Alias)
    }.

resolve_riak_bucket_op(Method, Query) ->
    case is_keys_mode(Query) of
        true ->
            keys;
        false ->
            case props_enabled(Query) of
                true -> bucket_props;
                false when Method =:= <<"POST">> -> object_collection;
                false -> bucket_props
            end
    end.

is_keys_mode(Query) ->
    case maps:get(<<"keys">>, Query, undefined) of
        <<"true">> -> true;
        <<"stream">> -> true;
        true -> true;
        _ -> false
    end.

props_enabled(Query) ->
    case maps:get(<<"props">>, Query, undefined) of
        undefined -> true;
        false -> false;
        <<"false">> -> false;
        _ -> true
    end.

ensure_allowed_query(Context) ->
    Op = maps:get(op, Context, undefined),
    Query = maps:get(query, Context, #{}),
    case allowed_query_keys(Op) of
        all ->
            validate_query_values(Op, Query);
        Allowed ->
            Unknown = [
                Key
                || Key <- maps:keys(Query),
                   is_binary(Key),
                   not lists:member(Key, Allowed)
            ],
            case Unknown of
                [] ->
                    validate_query_values(Op, Query);
                [Key | _] ->
                    {error, #{
                        status => 400,
                        code => <<"invalid_query">>,
                        reason => iolist_to_binary([<<"Unsupported query parameter: ">>, Key])
                    }}
            end
    end.

allowed_query_keys(keys) ->
    [<<"keys">>, <<"props">>, <<"timeout">>];
allowed_query_keys(index_query) ->
    [
        <<"stream">>,
        <<"max_results">>,
        <<"continuation">>,
        <<"return_terms">>,
        <<"pagination_sort">>,
        <<"timeout">>,
        <<"term_regex">>
    ];
allowed_query_keys(_) ->
    all.

validate_query_values(keys, Query) ->
    case maps:get(<<"keys">>, Query, undefined) of
        undefined -> ok;
        <<"true">> -> ok;
        <<"false">> -> ok;
        <<"stream">> -> ok;
        true -> ok;
        false -> ok;
        _ ->
            {error, #{
                status => 400,
                code => <<"invalid_query">>,
                reason => <<"keys query must be true|false|stream">>
            }}
    end;
validate_query_values(index_query, Query) ->
    case maps:get(<<"stream">>, Query, undefined) of
        undefined -> ok;
        <<"true">> -> ok;
        <<"false">> -> ok;
        true -> ok;
        false -> ok;
        _ ->
            {error, #{
                status => 400,
                code => <<"invalid_query">>,
                reason => <<"stream query must be true|false">>
            }}
    end;
validate_query_values(_, _Query) ->
    ok.

ensure_allowed_method(Method, Context) ->
    Allowed = allowed_methods(maps:get(op, Context), maps:get(alias, Context)),
    case lists:member(Method, Allowed) of
        true -> ok;
        false ->
            {error, #{
                status => 405,
                code => <<"method_not_allowed">>,
                reason => iolist_to_binary(
                    io_lib:format("Unsupported HTTP method: ~p", [Method])),
                allow => Allowed
            }}
    end.

allowed_methods(buckets, _) -> [<<"GET">>, <<"HEAD">>];
allowed_methods(bucket_props, riak) -> [<<"GET">>, <<"HEAD">>, <<"PUT">>];
allowed_methods(bucket_props, _) -> [<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"DELETE">>];
allowed_methods(bucket_type_props, _) -> [<<"GET">>, <<"HEAD">>, <<"PUT">>];
allowed_methods(keys, _) -> [<<"GET">>, <<"HEAD">>];
allowed_methods(object_collection, _) -> [<<"POST">>];
allowed_methods(object_item, _) -> [<<"GET">>, <<"HEAD">>, <<"PUT">>, <<"POST">>, <<"DELETE">>];
allowed_methods(index_query, _) -> [<<"GET">>, <<"HEAD">>];
allowed_methods(_, _) -> [<<"GET">>].

normalize_query_entries([], Acc) ->
    {ok, Acc};
normalize_query_entries([{Key, Value0} | Rest], Acc0) ->
    Value = to_binary(Value0),
    case normalize_query_value(Key, Value) of
        {ok, Value1} ->
            normalize_query_entries(Rest, Acc0#{Key => Value1});
        {error, Reason} ->
            {error, #{
                status => 400,
                code => <<"invalid_query">>,
                reason => Reason
            }}
    end.

normalize_query_value(Key, Value) when
    Key =:= <<"basic_quorum">>;
    Key =:= <<"notfound_ok">>;
    Key =:= <<"returnbody">>;
    Key =:= <<"returnvalue">>;
    Key =:= <<"include_context">>;
    Key =:= <<"asis">>;
    Key =:= <<"stream">>;
    Key =:= <<"return_terms">>;
    Key =:= <<"pagination_sort">> ->
    parse_boolean(Value);
normalize_query_value(Key, Value) when
    Key =:= <<"r">>;
    Key =:= <<"pr">>;
    Key =:= <<"w">>;
    Key =:= <<"pw">>;
    Key =:= <<"dw">>;
    Key =:= <<"rw">>;
    Key =:= <<"node_confirms">> ->
    parse_quorum(Value);
normalize_query_value(<<"timeout">>, Value) ->
    parse_timeout(Value);
normalize_query_value(<<"max_results">>, Value) ->
    parse_max_results(Value);
normalize_query_value(_, Value) ->
    {ok, Value}.

parse_boolean(Value0) ->
    Value = string:lowercase(binary_to_list(Value0)),
    case Value of
        "true" -> {ok, true};
        "false" -> {ok, false};
        _ -> {error, <<"Boolean query params must be true|false">>}
    end.

parse_quorum(<<"default">>) -> {ok, default};
parse_quorum(<<"one">>) -> {ok, one};
parse_quorum(<<"quorum">>) -> {ok, quorum};
parse_quorum(<<"all">>) -> {ok, all};
parse_quorum(Value) ->
    case integer_from_binary(Value) of
        {ok, Int} when Int >= 0 -> {ok, Int};
        _ -> {error, <<"Invalid quorum value">>}
    end.

parse_timeout(Value) ->
    case integer_from_binary(Value) of
        {ok, Int} when Int >= 0 -> {ok, Int};
        _ -> {error, <<"Invalid timeout value">>}
    end.

parse_max_results(Value) ->
    case integer_from_binary(Value) of
        {ok, Int} when Int > 0 -> {ok, Int};
        _ -> {error, <<"Invalid max_results value">>}
    end.

detect_stream_mode(Query) ->
    case maps:get(<<"buckets">>, Query, undefined) of
        <<"stream">> -> buckets;
        _ ->
            case maps:get(<<"keys">>, Query, undefined) of
                <<"stream">> -> keys;
                _ ->
                    case maps:get(<<"stream">>, Query, undefined) of
                        <<"true">> -> index;
                        true -> index;
                        _ ->
                            case maps:get(<<"chunked">>, Query, undefined) of
                                <<"true">> -> mapred;
                                true -> mapred;
                                _ -> none
                            end
                    end
            end
    end.

ensure_tls(Context, Opts) ->
    case maps:get(require_tls, Opts, false) of
        true ->
            Headers = maps:get(headers, Context, #{}),
            case maps:get(<<"x-forwarded-proto">>, Headers, <<"http">>) of
                <<"https">> -> ok;
                _ ->
                    {error, #{
                        status => 426,
                        code => <<"tls_required">>,
                        reason => <<"TLS is required for this endpoint">>
                    }}
            end;
        false ->
            ok
    end.

ensure_origin(Context, Opts) ->
    TrustedOrigins = maps:get(trusted_origins, Opts, []),
    Method = maps:get(method, Context, <<"GET">>),
    case {is_safe_method(Method), TrustedOrigins} of
        {true, _} ->
            ok;
        {false, []} ->
            ok;
        {false, _} ->
            Headers = maps:get(headers, Context, #{}),
            Origin = maps:get(<<"origin">>, Headers, undefined),
            case Origin of
                undefined -> ok;
                _ when is_binary(Origin) ->
                    case lists:member(Origin, TrustedOrigins) of
                        true -> ok;
                        false ->
                            {error, #{
                                status => 403,
                                code => <<"forbidden">>,
                                reason => <<"Origin is not allowed">>
                            }}
                    end
            end
    end.

is_safe_method(<<"GET">>) -> true;
is_safe_method(<<"HEAD">>) -> true;
is_safe_method(<<"OPTIONS">>) -> true;
is_safe_method(_) -> false.

run_security_hook(Key, Context, Opts) ->
    case maps:get(Key, Opts, undefined) of
        undefined ->
            ok;
        Fun when is_function(Fun, 1) ->
            normalize_hook_result(Fun(Context));
        Fun when is_function(Fun, 2) ->
            normalize_hook_result(Fun(Context, Opts));
        _ ->
            {error, #{
                status => 500,
                code => <<"security_hook_error">>,
                reason => <<"Security hook must be a function">>
            }}
    end.

normalize_hook_result(ok) -> ok;
normalize_hook_result(allow) -> ok;
normalize_hook_result(unauthorized) ->
    {error, #{
        status => 401,
        code => <<"unauthorized">>,
        reason => <<"Authentication required">>
    }};
normalize_hook_result(forbidden) ->
    {error, #{
        status => 403,
        code => <<"forbidden">>,
        reason => <<"Access denied">>
    }};
normalize_hook_result({deny, Status, Code, Reason}) ->
    {error, #{
        status => Status,
        code => to_binary(Code),
        reason => to_binary(Reason)
    }};
normalize_hook_result({error, ErrorMap}) when is_map(ErrorMap) ->
    {error, ErrorMap};
normalize_hook_result(_) ->
    {error, #{
        status => 500,
        code => <<"security_hook_error">>,
        reason => <<"Security hook returned an unsupported value">>
    }}.

request_method(#{method := Method}) -> to_binary(Method);
request_method(Req) -> to_binary(cowboy_req:method(Req)).

request_path(#{path := Path}) -> to_binary(Path);
request_path(Req) -> to_binary(cowboy_req:path(Req)).

request_headers(#{headers := Headers}) when is_map(Headers) -> Headers;
request_headers(Req) ->
    try cowboy_req:headers(Req)
    catch
        _:_ -> #{}
    end.

request_query(#{query := Query}) when is_map(Query) -> Query;
request_query(#{qs := Qs}) when is_binary(Qs) -> parse_qs_binary(Qs);
request_query(#{query_string := Qs}) when is_binary(Qs) -> parse_qs_binary(Qs);
request_query(Req) ->
    try
        lists:foldl(
            fun({K, V}, Acc) -> Acc#{to_binary(K) => to_binary(V)} end,
            #{},
            cowboy_req:parse_qs(Req))
    catch
        _:_ -> #{}
    end.

parse_qs_binary(<<>>) -> #{};
parse_qs_binary(Qs) ->
    Pairs = [Pair || Pair <- binary:split(Qs, <<"&">>, [global]), Pair =/= <<>>],
    lists:foldl(
        fun(Pair, Acc) ->
            {K, V} = parse_qs_pair(Pair),
            Acc#{K => V}
        end,
        #{},
        Pairs).

parse_qs_pair(Pair) ->
    case binary:split(Pair, <<"=">>) of
        [Key, Value] ->
            {decode_qs_component(Key), decode_qs_component(Value)};
        [Key] ->
            {decode_qs_component(Key), <<"true">>}
    end.

decode_qs_component(Component) ->
    try uri_string:percent_decode(Component)
    catch
        _:_ -> Component
    end.

path_segments(Path) ->
    [Segment || Segment <- binary:split(Path, <<"/">>, [global]),
                Segment =/= <<>>].

validate_path_shape(<<"/", _/binary>> = Path) ->
    case binary:match(Path, <<"//">>) of
        nomatch ->
            ok;
        _ ->
            {error, #{
                status => 404,
                code => <<"unknown_route">>,
                reason => <<"Unsupported path shape">>
            }}
    end;
validate_path_shape(_) ->
    {error, #{
        status => 404,
        code => <<"unknown_route">>,
        reason => <<"Unsupported path shape">>
    }}.

alias_version(riak) -> 1;
alias_version(buckets) -> 2;
alias_version(types) -> 3.

header_name(Key) when is_binary(Key) ->
    list_to_binary(string:lowercase(binary_to_list(Key)));
header_name(Key) when is_atom(Key) ->
    header_name(atom_to_binary(Key, utf8));
header_name(Key) when is_list(Key) ->
    header_name(list_to_binary(Key)).

integer_from_binary(Value) ->
    try {ok, binary_to_integer(Value)}
    catch
        _:_ -> error
    end.

generate_request_id() ->
    I = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    <<"riak-admin-", I/binary>>.

with_request_id(Error0, RequestId) ->
    Error = case maps:is_key(reason, Error0) of
        true -> Error0;
        false -> Error0#{reason => <<"Request normalization failed">>}
    end,
    Error#{request_id => RequestId}.

to_binary(Value) when is_binary(Value) -> Value;
to_binary(Value) when is_atom(Value) -> atom_to_binary(Value, utf8);
to_binary(Value) when is_integer(Value) -> integer_to_binary(Value);
to_binary(Value) when is_list(Value) -> list_to_binary(Value);
to_binary(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
