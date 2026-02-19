#!/usr/bin/env escript
%%! -pa _build/test/lib/riak_admin_api/ebin -pa _build/default/lib/riak_admin_api/ebin

main(_Args) ->
    Iterations = 5000,
    io:format("cowboy_perf_probe iterations=~B~n", [Iterations]),
    ScenarioResults = [run_normalize_scenario(S, Iterations) || S <- scenarios()],
    TelemetryResult = run_telemetry_scenario(Iterations),
    Results = ScenarioResults ++ [TelemetryResult],
    lists:foreach(fun print_result/1, Results),
    TotalErrors = lists:sum([maps:get(errors, Result) || Result <- Results]),
    io:format("SUMMARY scenarios=~B errors=~B~n", [length(Results), TotalErrors]),
    case TotalErrors of
        0 -> ok;
        _ -> halt(1)
    end.

scenarios() ->
    [
        {<<"request.normalize.object_get">>, ok, #{
            method => <<"GET">>,
            path => <<"/riak/users/alice">>,
            headers => #{<<"x-request-id">> => <<"bench-object">>},
            query => #{}
        }},
        {<<"request.normalize.bucket_props_get">>, ok, #{
            method => <<"GET">>,
            path => <<"/buckets/users/props">>,
            headers => #{<<"x-request-id">> => <<"bench-bucket">>},
            query => #{}
        }},
        {<<"request.normalize.keys_list">>, ok, #{
            method => <<"GET">>,
            path => <<"/buckets/users/keys">>,
            headers => #{<<"x-request-id">> => <<"bench-keys">>},
            query => #{
                <<"keys">> => <<"true">>,
                <<"timeout">> => <<"2000">>
            }
        }},
        {<<"request.normalize.index_range">>, ok, #{
            method => <<"GET">>,
            path => <<"/types/default/buckets/users/index/email_bin/a/z">>,
            headers => #{<<"x-request-id">> => <<"bench-index">>},
            query => #{
                <<"max_results">> => <<"100">>,
                <<"continuation">> => <<"cont-token">>
            }
        }},
        {<<"request.normalize.query_post">>, ok, #{
            method => <<"POST">>,
            path => <<"/buckets/users/query">>,
            headers => #{<<"x-request-id">> => <<"bench-query">>},
            query => #{}
        }},
        {<<"request.normalize.mapred_post_chunked">>, ok, #{
            method => <<"POST">>,
            path => <<"/mapred">>,
            headers => #{<<"x-request-id">> => <<"bench-mapred">>},
            query => #{
                <<"chunked">> => <<"true">>
            }
        }},
        {<<"request.normalize.counter_post_returnvalue">>, ok, #{
            method => <<"POST">>,
            path => <<"/buckets/users/counters/visits">>,
            headers => #{<<"x-request-id">> => <<"bench-counter">>},
            query => #{
                <<"returnvalue">> => <<"true">>
            }
        }},
        {<<"request.normalize.crdt_get">>, ok, #{
            method => <<"GET">>,
            path => <<"/types/maps/buckets/users/datatypes/profile">>,
            headers => #{<<"x-request-id">> => <<"bench-crdt">>},
            query => #{
                <<"include_context">> => <<"true">>,
                <<"timeout">> => <<"5000">>
            }
        }},
        {<<"request.normalize.error_invalid_query">>, error, #{
            method => <<"GET">>,
            path => <<"/buckets/users/index/email_bin/alice">>,
            headers => #{<<"x-request-id">> => <<"bench-err">>},
            query => #{
                <<"max_results">> => <<"0">>
            }
        }}
    ].

run_normalize_scenario({Name, Expectation, Req}, Iterations) ->
    benchmark(
        Name,
        Iterations,
        fun() ->
            case riak_admin_api_request:normalize(Req, #{}) of
                {ok, _Context, _Req1} when Expectation =:= ok ->
                    ok;
                {error, _Error, _Req1} when Expectation =:= error ->
                    ok;
                {ok, _Context, _Req1} ->
                    {error, expected_error};
                {error, Error, _Req1} ->
                    {error, Error}
            end
        end).

run_telemetry_scenario(Iterations) ->
    Context = #{
        route => <<"/types/maps/buckets/users/datatypes/profile">>,
        op => crdt_item,
        alias => types
    },
    benchmark(
        <<"response.telemetry_tags">>,
        Iterations,
        fun() ->
            _ = riak_admin_api_response:telemetry_tags(Context, 200, 123),
            ok
        end).

benchmark(Name, Iterations, Fun) ->
    {Durations, Errors} = run_iterations(Iterations, Fun, [], 0),
    Sorted = lists:sort(Durations),
    Stats = duration_stats(Sorted),
    Stats#{
        name => Name,
        iterations => Iterations,
        errors => Errors
    }.

run_iterations(0, _Fun, Durations, Errors) ->
    {Durations, Errors};
run_iterations(N, Fun, Durations, Errors) ->
    Start = erlang:monotonic_time(microsecond),
    Result = Fun(),
    Duration = erlang:monotonic_time(microsecond) - Start,
    NextErrors = case Result of
        ok -> Errors;
        {error, _} -> Errors + 1
    end,
    run_iterations(N - 1, Fun, [Duration | Durations], NextErrors).

duration_stats([]) ->
    #{
        mean_us => 0.0,
        p50_us => 0,
        p95_us => 0,
        p99_us => 0,
        max_us => 0
    };
duration_stats(Sorted) ->
    Count = length(Sorted),
    Sum = lists:sum(Sorted),
    #{
        mean_us => Sum / Count,
        p50_us => percentile(Sorted, 50),
        p95_us => percentile(Sorted, 95),
        p99_us => percentile(Sorted, 99),
        max_us => lists:last(Sorted)
    }.

percentile(Sorted, Percentile) ->
    Count = length(Sorted),
    Position = max(1, trunc(math:ceil((Percentile / 100) * Count))),
    lists:nth(Position, Sorted).

print_result(Result) ->
    io:format(
        "RESULT name=~s iterations=~B errors=~B mean_us=~.2f p50_us=~B p95_us=~B p99_us=~B max_us=~B~n",
        [
            maps:get(name, Result),
            maps:get(iterations, Result),
            maps:get(errors, Result),
            maps:get(mean_us, Result),
            maps:get(p50_us, Result),
            maps:get(p95_us, Result),
            maps:get(p99_us, Result),
            maps:get(max_us, Result)
        ]).
