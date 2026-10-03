-module(basic).

-export([main/0]).

-include_lib("erlang_polycall/include/erlang_polycall.hrl").

%% erl -noshell -pa _build/default/lib/erlang_polycall/ebin -pa examples \
%%     -eval 'basic:main(), halt().'
main() ->
    io:format("polycall ~s (binding ABI ~b)~n",
              [erlang_polycall:version(), erlang_polycall:abi_version()]),
    case erlang_polycall:run_config(<<"erlang-polycallrc">>, true) of
        ok ->
            io:format("erlang-polycallrc is valid for this build~n");
        {error, #polycall_error{name = Name, detail = Detail}} ->
            io:format(standard_error, "~s: ~s~n", [Name, Detail]),
            erlang:halt(1)
    end,
    {ok, A} = polycall_peer:open("example-a"),
    {ok, B} = polycall_peer:open("example-b"),
    {ok, EpB} = polycall_peer:endpoint(B),
    ok = polycall_peer:send(A, EpB, <<"hello from Erlang">>),
    {ok, #{sender := From, payload := Payload}} = polycall_peer:recv(B, 5000),
    io:format("~s received ~p from ~s~n", [EpB, Payload, From]),
    ok = polycall_peer:close(A),
    ok = polycall_peer:close(B).
