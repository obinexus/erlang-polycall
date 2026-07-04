-module(erlang_polycall_smoke).

-export([main/0]).

main() ->
    true = os:putenv("POLYCALL_EXPECT_CONFIG", "../erlang-polycallrc"),
    true = os:putenv("POLYCALL_MOCK_STATUS", "0"),
    {ok, 0} = erlang_polycall:run_config(<<"../erlang-polycallrc">>),

    true = os:putenv("POLYCALL_MOCK_STATUS", "37"),
    {error, 37} = erlang_polycall:run_config("../erlang-polycallrc"),
    try erlang_polycall:run_config_or_error("../erlang-polycallrc") of
        ok -> erlang:error(expected_polycall_error)
    catch
        error:{polycall_error, 37} -> ok
    end,

    io:format("erlang-polycall Erlang smoke test: PASS~n").
