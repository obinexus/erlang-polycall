-module(basic).

-export([main/0]).

main() ->
    case erlang_polycall:run_config(<<"erlang-polycallrc">>) of
        {ok, 0} ->
            io:format("erlang-polycall: configuration started successfully~n");
        {error, Status} ->
            io:format(standard_error, "erlang-polycall failed: ~p~n", [Status]),
            erlang:halt(Status)
    end.
