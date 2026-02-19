-module(cowboy_contract_inventory_test).
-include_lib("eunit/include/eunit.hrl").
-compile([export_all, nowarn_export_all]).

route_inventory_has_core_paths_test() ->
    {ok, Bin} = file:read_file(contract_matrix_path()),
    ?assert(binary:match(Bin, <<"/riak/">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"/buckets/">>) =/= nomatch),
    ?assert(binary:match(Bin, <<"/types/">>) =/= nomatch).

contract_matrix_path() ->
    Candidates = [
        "docs/plans/artifacts/cowboy-compat-matrix.md",
        filename:join(["..", "..", "docs", "plans", "artifacts", "cowboy-compat-matrix.md"]),
        filename:join(["..", "..", "..", "docs", "plans", "artifacts", "cowboy-compat-matrix.md"])
    ],
    case lists:dropwhile(fun(Path) -> not filelib:is_file(Path) end, Candidates) of
        [Path | _] -> Path;
        [] -> hd(Candidates)
    end.
