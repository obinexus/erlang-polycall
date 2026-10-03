%% Memory-tool workload for erlang-polycall: drives every NIF entry point and
%% every error path against the REAL libpolycall, with functional checks
%% only (no timing limits), so it can run under valgrind (beam.valgrind.smp)
%% and AddressSanitizer, where BEAM runs many times slower.
%%
%%   POLYCALL_RPC=<host:port of `polycall start`>
%%   POLYCALL_CLI_NODE=<host:port of `polycall peer serve --node-id cli-node`>
%%   POLYCALL_CLI=<path to polycall>       (C -> Erlang interop)
%%   erl -pa <ebin> <test ebin> -eval 'polycall_memcheck:main()'
%%
%% Used by scripts/test-memory.sh. Prints "MEMCHECK PASS <n> checks" and
%% halts 0, or prints the failure and halts 1.
-module(polycall_memcheck).

-export([main/0, run/0]).

-include("erlang_polycall.hrl").

-define(MIB, 1048576).
-define(CHECK(Expr), check(?LINE, ??Expr, fun() -> Expr end)).

main() ->
    Code = try run() of
               N -> io:format("MEMCHECK PASS ~b checks~n", [N]), 0
           catch C:R:S ->
               io:format("MEMCHECK FAIL ~p:~p~n~p~n", [C, R, S]), 1
           end,
    erlang:halt(Code).

check(Line, Text, F) ->
    case catch F() of
        true -> put(checks, get_checks() + 1), ok;
        Other -> erlang:error({check_failed, Line, Text, Other})
    end.

get_checks() ->
    case get(checks) of undefined -> 0; N -> N end.

reason({error, #polycall_error{reason = R}}) -> R;
reason(Other) -> {unexpected, Other}.

env(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({missing_env, Name});
        V -> V
    end.

run() ->
    put(checks, 0),
    Token = os:getenv("POLYCALL_DEV_TOKEN", "memcheck-token"),
    Tmp = filename:join(os:getenv("TMPDIR", "/tmp"),
                        "polycall-memcheck-" ++ os:getpid()),
    ok = filelib:ensure_dir(filename:join(Tmp, "x")),
    library(),
    config(Tmp),
    rpc(env("POLYCALL_RPC")),
    peers(Token),
    interop(Token, env("POLYCALL_CLI_NODE"), env("POLYCALL_CLI"), Tmp),
    gc_close(),
    get_checks().

library() ->
    ?CHECK(erlang_polycall:abi_version() =:= 1),
    ?CHECK(erlang_polycall:version() =:= <<"1.1.0">>),
    [?CHECK(is_binary(erlang_polycall:strerror(C))) || C <- lists:seq(-20, 1)],
    ?CHECK(erlang_polycall:load_error() =:= undefined).

config(Tmp) ->
    W = fun(Name, Text) -> P = filename:join(Tmp, Name), ok = file:write_file(P, Text), P end,
    ?CHECK(erlang_polycall:run_config("erlang-polycallrc", true) =:= ok),
    ?CHECK(erlang_polycall:run_config(<<"erlang-polycallrc">>) =:= {ok, 0}),
    ?CHECK(reason(erlang_polycall:run_config(filename:join(Tmp, "missing"), true)) =:= not_found),
    ?CHECK(reason(erlang_polycall:run_config(W("bad", "max_connections=lots\n"), false)) =:= config),
    Unknown = W("unknown", "log_level=info\nmystery=1\n"),
    ?CHECK(erlang_polycall:run_config(Unknown, false) =:= ok),
    ?CHECK(reason(erlang_polycall:run_config(Unknown, true)) =:= config),
    Tls = W("tls", "tls_enabled=true\ncert_file=/x/c.pem\nkey_file=/x/k.pem\n"),
    ?CHECK(reason(erlang_polycall:run_config(Tls, true)) =:= unsupported),
    ?CHECK(reason(erlang_polycall:run_config(<<>>, true)) =:= invalid_argument),
    ?CHECK(catch_error(fun() -> erlang_polycall:run_config(<<"a", 0>>, true) end) =:= badarg),
    Uni = filename:join(Tmp, "caf\x{e9}-\x{4e16}\x{754c}-rc"),
    ok = file:write_file(unicode:characters_to_binary(Uni), <<"log_level=info\n">>),
    ?CHECK(erlang_polycall:run_config(Uni, true) =:= ok),
    {ok, Json} = erlang_polycall:describe(Uni),
    ?CHECK(is_map(json:decode(Json))),
    ?CHECK(reason(erlang_polycall:describe(filename:join(Tmp, "missing"))) =:= not_found).

rpc(Ep) ->
    {ok, Out} = erlang_polycall:call(Ep, "inventory", "get", <<"{\"item_id\":\"widget-a\"}">>, 30000),
    ?CHECK(maps:get(<<"quantity">>, json:decode(Out)) =:= 42),
    {error, E} = erlang_polycall:call(Ep, "inventory", "nope", null, 30000),
    ?CHECK(E#polycall_error.reason =:= not_found andalso is_binary(E#polycall_error.info)),
    ?CHECK(reason(erlang_polycall:call(Ep, "inventory", "get", <<"{\"item_id\":\"x\"}">>, 30000)) =:= remote),
    ?CHECK(reason(erlang_polycall:call(Ep, "debug", "sleep", <<"{\"ms\":3000}">>, 200)) =:= timeout),
    ?CHECK(reason(erlang_polycall:call(Ep, "debug", "echo", <<"{bad">>, 1000)) =:= invalid_argument),
    ?CHECK(reason(erlang_polycall:call(Ep, "debug", "echo", null, 0)) =:= invalid_argument),
    ?CHECK(reason(erlang_polycall:call("nope", "debug", "echo", null, 1000)) =:= invalid_argument),
    Text = binary:copy(<<"0123456789abcdef">>, 3840),
    {ok, Echo} = erlang_polycall:call(Ep, "debug", "echo", json:encode(#{<<"t">> => Text}), 30000),
    ?CHECK(json:decode(Echo) =:= #{<<"echo">> => #{<<"t">> => Text}}),
    ?CHECK(reason(erlang_polycall:call(Ep, "debug", "echo",
                                       json:encode(binary:copy(<<"x">>, 70000)), 30000)) =:= remote),
    ?CHECK(reason(erlang_polycall:call(Ep, "debug", "echo",
                                       json:encode(binary:copy(<<"x">>, ?MIB + 1)), 30000)) =:= too_large),
    Self = self(),
    Pids = [spawn(fun() ->
                      {ok, O} = erlang_polycall:call(Ep, "debug", "echo",
                                                     json:encode(#{<<"i">> => I}), 30000),
                      Self ! {call, self(), json:decode(O) =:= #{<<"echo">> => #{<<"i">> => I}}}
                  end) || I <- lists:seq(1, 12)],
    [?CHECK(receive {call, P, Ok} -> Ok after 120000 -> timeout end) || P <- Pids],
    {ok, Probe} = polycall_peer:open("mc-probe"),
    {ok, Free} = polycall_peer:endpoint(Probe),
    ok = polycall_peer:close(Probe),
    ?CHECK(reason(erlang_polycall:call(Free, "debug", "echo", null, 2000)) =:= transport).

open(Id, Token) ->
    {ok, P} = polycall_peer:open(Id, #{token => Token}),
    {ok, Ep} = polycall_peer:endpoint(P),
    {P, Ep}.

recv(P) ->
    {ok, M} = polycall_peer:recv(P, 60000),
    M.

peers(Token) ->
    ?CHECK(reason(polycall_peer:open("bad id")) =:= invalid_argument),
    ?CHECK(reason(polycall_peer:open("x", #{bind => "0.0.0.0:0"})) =:= config),
    ?CHECK(reason(polycall_peer:open("n\x{f6}de")) =:= invalid_argument),
    {A, EpA} = open("mc-a", Token),
    {B, EpB} = open("mc-b", Token),
    ?CHECK(polycall_peer:node_id(A) =:= {ok, <<"mc-a">>}),
    {ok, H} = polycall_peer:health(A),
    ?CHECK(is_map(json:decode(H))),
    ok = polycall_peer:register(A, "mc-b", EpB),
    ?CHECK(json:decode(element(2, polycall_peer:list(A))) =:= #{<<"mc-b">> => EpB}),
    ?CHECK(polycall_peer:ping(A, "mc-b", 30000) =:= ok),
    ?CHECK(reason(polycall_peer:register(A, "bad id", EpB)) =:= invalid_argument),
    Big = crypto:strong_rand_bytes(?MIB),
    Cases = [{"m-empty", <<>>}, {"m-utf8", unicode:characters_to_binary("h\x{e9}llo \x{1f30d}")},
             {"m-nul", <<0, 1, 0, 255>>}, {"m-max", Big}],
    [begin
         ok = polycall_peer:send(A, "mc-b", Bytes, #{message_id => Id, timeout => 60000}),
         ?CHECK(recv(B) =:= #{sender => <<"mc-a">>, message_id => list_to_binary(Id), payload => Bytes})
     end || {Id, Bytes} <- Cases],
    ok = polycall_peer:send(B, EpA, [<<"back">>, $!], #{message_id => "m-back", timeout => 60000}),
    ?CHECK(recv(A) =:= #{sender => <<"mc-b">>, message_id => <<"m-back">>, payload => <<"back!">>}),
    ?CHECK(reason(polycall_peer:send(A, EpB, <<Big/binary, 0>>, #{timeout => 60000})) =:= too_large),
    %% too-small buffers leave the message queued
    ok = polycall_peer:send(A, EpB, <<"0123456789">>, #{message_id => "m-small", timeout => 60000}),
    {error, Small} = polycall_peer:recv(B, 60000, 4),
    ?CHECK({Small#polycall_error.reason, Small#polycall_error.info} =:= {too_large, 10}),
    {error, Zero} = polycall_peer:recv(B, 0, 0),
    ?CHECK(Zero#polycall_error.info =:= 10),
    ?CHECK(maps:get(payload, recv(B)) =:= <<"0123456789">>),
    %% duplicates, auth, dead peer
    ok = polycall_peer:send(A, EpB, <<"once">>, #{message_id => "m-dup", timeout => 60000}),
    ok = polycall_peer:send(A, EpB, <<"once">>, #{message_id => "m-dup", timeout => 60000}),
    ?CHECK(maps:get(message_id, recv(B)) =:= <<"m-dup">>),
    ?CHECK(reason(polycall_peer:recv(B, 0)) =:= timeout),
    {ok, Anon} = polycall_peer:open("mc-anon", #{bind => undefined}),
    ?CHECK(reason(polycall_peer:send(Anon, EpB, <<"x">>, #{timeout => 60000})) =:= auth),
    ok = polycall_peer:close(Anon),
    %% sliced waits: a finite timeout longer than a slice, cancel, close
    ?CHECK(reason(polycall_peer:recv(B, 650)) =:= timeout),
    Self = self(),
    W1 = spawn(fun() -> Self ! {w, self(), polycall_peer:recv(B, infinity)} end),
    timer:sleep(700),
    ok = polycall_peer:cancel(B),
    ?CHECK(receive {w, W1, R1} -> reason(R1) after 120000 -> timeout end =:= cancelled),
    %% more receivers than dirty I/O schedulers, woken by close
    N = erlang:system_info(dirty_io_schedulers) + 2,
    {C, EpC} = open("mc-c", Token),
    Ws = [spawn(fun() -> Self ! {w, self(), polycall_peer:recv(C, infinity)} end) || _ <- lists:seq(1, N)],
    %% concurrent senders sharing one handle while receivers wait
    [spawn(fun() -> Self ! {s, polycall_peer:send(A, EpC, <<I:32>>,
                                                  #{message_id => "c" ++ integer_to_list(I),
                                                    timeout => 60000})} end)
     || I <- lists:seq(1, 6)],
    [?CHECK(receive {s, Res} -> Res after 120000 -> timeout end =:= ok) || _ <- lists:seq(1, 6)],
    Got = [receive {w, P, {ok, #{payload := <<I:32>>}}} when is_pid(P) -> I
           after 120000 -> timeout end || _ <- lists:seq(1, 6)],
    ?CHECK(lists:sort(Got) =:= lists:seq(1, 6)),
    timer:sleep(500),
    ok = polycall_peer:close(C),
    Closed = [receive {w, _, R} -> reason(R) after 120000 -> timeout end
              || _ <- lists:seq(1, N - 6)],
    ?CHECK(Closed =:= lists:duplicate(N - 6, closed)),
    ?CHECK(length(Ws) =:= N),
    %% killed receiver frees its slice
    K = spawn(fun() -> polycall_peer:recv(A, infinity) end),
    timer:sleep(500),
    exit(K, kill),
    timer:sleep(500),
    %% double close, use after close
    ok = polycall_peer:close(A),
    ?CHECK(reason(polycall_peer:close(A)) =:= invalid_handle),
    ?CHECK(reason(polycall_peer:send(A, EpB, <<"x">>)) =:= invalid_handle),
    ?CHECK(reason(polycall_peer:recv(A, 0)) =:= invalid_handle),
    ?CHECK(reason(polycall_peer:endpoint(A)) =:= invalid_handle),
    ?CHECK(reason(polycall_peer:list(A)) =:= invalid_handle),
    ?CHECK(reason(polycall_peer:cancel(A)) =:= invalid_handle),
    ?CHECK(catch_error(fun() -> polycall_peer:close(make_ref()) end) =:= badarg),
    ?CHECK(reason(polycall_peer:send(B, EpA, <<"x">>, #{timeout => 30000})) =:= transport),
    ok = polycall_peer:close(B).

interop(Token, CliEp, Cli, Tmp) ->
    {A, EpA} = open("mc-interop", Token),
    ok = polycall_peer:send(A, CliEp, <<0, 1, 2, 255>>, #{message_id => "mc-e2c", timeout => 60000}),
    ok = polycall_peer:ping(A, CliEp, 30000),
    File = filename:join(Tmp, "c2e.bin"),
    ok = file:write_file(File, <<1, 0, 2>>),
    %% the CLI runs without the VM's sanitizer preload
    Port = open_port({spawn_executable, Cli},
                     [{args, ["peer", "send", "--from", "cli-node", "--to", binary_to_list(EpA),
                              "--id", "mc-c2e", "--payload-file", File, "-t", "30000"]},
                      exit_status, stderr_to_stdout, {env, [{"LD_PRELOAD", false}]}]),
    ?CHECK(port_exit(Port) =:= 0),
    ?CHECK(recv(A) =:= #{sender => <<"cli-node">>, message_id => <<"mc-c2e">>, payload => <<1, 0, 2>>}),
    ok = polycall_peer:close(A).

%% resources dropped without close/1 are closed by the destructor
gc_close() ->
    Self = self(),
    [spawn(fun() ->
               {ok, P} = polycall_peer:open("mc-gc-" ++ integer_to_list(I)),
               {ok, Ep} = polycall_peer:endpoint(P),
               Self ! {gc, Ep}
           end) || I <- lists:seq(1, 4)],
    Eps = [receive {gc, Ep} -> Ep after 60000 -> error(no_gc_endpoint) end || _ <- lists:seq(1, 4)],
    erlang:garbage_collect(),
    {ok, Probe} = polycall_peer:open("mc-gc-probe", #{bind => undefined}),
    [?CHECK(wait_down(Probe, Ep, 600)) || Ep <- Eps],
    ok = polycall_peer:close(Probe).

wait_down(_Probe, _Ep, 0) -> false;
wait_down(Probe, Ep, N) ->
    case polycall_peer:ping(Probe, Ep, 5000) of
        {error, #polycall_error{reason = transport}} -> true;
        _ -> timer:sleep(100), wait_down(Probe, Ep, N - 1)
    end.

port_exit(Port) ->
    receive
        {Port, {data, _}} -> port_exit(Port);
        {Port, {exit_status, S}} -> S
    after 120000 -> timeout
    end.

catch_error(F) ->
    try F(), no_error catch error:R -> R end.
