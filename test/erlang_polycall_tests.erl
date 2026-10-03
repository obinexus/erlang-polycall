%% EUnit tests of erlang-polycall against the REAL installed libpolycall
%% (no mocks): binding ABI v1 checklist from docs/BINDING_ABI.md, plus
%% interop with the C CLI (`polycall start`, `polycall daemon`,
%% `polycall peer serve|send|recv|register`).
%%
%% Needs: the NIF built against libpolycall (make nif), the `polycall` CLI
%% (POLYCALL_CLI or PATH) and OTP >= 27 (json module, test-only).
%% Checks that need the CLI and cannot find it print "SKIP <name>: <reason>"
%% and are not counted as tests (never as passes).
-module(erlang_polycall_tests).

-include_lib("eunit/include/eunit.hrl").
-include("erlang_polycall.hrl").

-define(MIB, 1048576).
-define(TOKEN_ENV, "POLYCALL_DEV_TOKEN").

%%% ===================================================================
%%% fixture: one `polycall start` runtime, one `polycall daemon` (private
%%% state dir, ephemeral port) and one `polycall peer serve` node (C CLI,
%%% separate OS processes) shared by the whole suite

polycall_test_() ->
    {setup, fun start_env/0, fun stop_env/1,
     fun(Env) ->
         library_tests() ++ config_tests(Env) ++ rpc_tests(Env) ++
             daemon_tests(Env) ++ peer_tests(Env) ++ fairness_tests(Env) ++
             interop_tests(Env)
     end}.

start_env() ->
    Tmp = make_tmp(),
    Token = token(),
    case cli() of
        false ->
            io:format(user, "SKIP rpc/interop checks: polycall CLI not found "
                      "(set POLYCALL_CLI or put polycall on PATH)~n", []),
            #{tmp => Tmp, cli => false, token => Token};
        Cli ->
            {RpcPid, RpcEp} = spawn_cli(Cli, Tmp, "rpc",
                ["start", "--endpoint", "127.0.0.1:0"]),
            {NodePid, NodeEp} = spawn_cli(Cli, Tmp, "cli-node",
                ["peer", "serve", "--node-id", "cli-node", "--endpoint", "127.0.0.1:0"]),
            {Daemonfile, DaemonEp} = start_daemon(Cli, Tmp),
            #{tmp => Tmp, cli => Cli, token => Token,
              rpc => RpcEp, cli_node => NodeEp, pids => [RpcPid, NodePid],
              daemon => DaemonEp, daemonfile => Daemonfile}
    end.

stop_env(#{pids := Pids} = Env) ->
    case Env of
        #{cli := Cli, daemonfile := Df} ->
            {S, Out} = run_cli(Cli, ["daemon", "stop", "--force", "-t", "8000", Df]),
            io:format(user, "polycall daemon stop: ~p ~s~n", [S, Out]);
        _ -> ok
    end,
    %% only the OS pids this suite started
    [sh("kill " ++ P ++ " 2>/dev/null") || P <- Pids],
    ok;
stop_env(_) ->
    ok.

%% `polycall daemon start` for a Polycallfile in our temp dir: ephemeral port,
%% private state dir, token from POLYCALL_DEV_TOKEN. Returns {File, Endpoint}.
start_daemon(Cli, Tmp) ->
    Dir = filename:join(Tmp, "daemon"),
    File = filename:join(Dir, "Polycallfile"),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, ["server node 8080:8084
network start
",
                                "daemon_endpoint=127.0.0.1:0
",
                                "daemon_state_dir=", filename:join(Dir, "state"), "
",
                                "auth_token_env=POLYCALL_DEV_TOKEN
"]),
    {0, Out} = run_cli(Cli, ["--format", "json", "daemon", "start", "-t", "15000", File]),
    #{<<"ok">> := true, <<"data">> := #{<<"endpoint">> := Ep}} = json:decode(string:trim(Out)),
    {File, binary_to_list(Ep)}.

cli() ->
    case os:getenv("POLYCALL_CLI") of
        false -> os:find_executable("polycall");
        Path -> Path
    end.

%% The shared secret every node of this suite uses (random per run).
token() ->
    case os:getenv(?TOKEN_ENV) of
        T when is_list(T), T =/= "" -> T;
        _ ->
            T = "erl-test-" ++ integer_to_list(erlang:unique_integer([positive])) ++
                "-" ++ integer_to_list(rand:uniform(1 bsl 40)),
            os:putenv(?TOKEN_ENV, T),
            T
    end.

make_tmp() ->
    Base = case os:getenv("TMPDIR") of false -> "/tmp"; D -> D end,
    Dir = filename:join(Base, "erlang-polycall-test-" ++ os:getpid() ++ "-" ++
                        integer_to_list(erlang:unique_integer([positive]))),
    ok = filelib:ensure_dir(filename:join(Dir, "x")),
    Dir.

%% Start a CLI process detached from the VM (its own process group), wait
%% for its endpoint file. Returns {OsPid, Endpoint}.
spawn_cli(Cli, Tmp, Name, Args) ->
    EpFile = filename:join(Tmp, Name ++ ".ep"),
    Log = filename:join(Tmp, Name ++ ".log"),
    Cmd = sh_quote(Cli) ++ " " ++
          lists:join(" ", [sh_quote(A) || A <- Args]) ++
          " --endpoint-file " ++ sh_quote(EpFile) ++
          " >" ++ sh_quote(Log) ++ " 2>&1 & echo $!",
    {0, Out} = sh(Cmd),
    Pid = string:trim(binary_to_list(Out)),
    Ep = wait_file(EpFile, 100),
    {Pid, Ep}.

%% /bin/sh -c Cmd for the CLI helpers. They never inherit the test VM's
%% LD_PRELOAD (scripts/test-memory.sh asan preloads the ASan runtime into
%% the VM only).
sh(Cmd) ->
    run_port("/bin/sh", ["-c", lists:flatten(Cmd)]).

wait_file(_File, 0) -> error(endpoint_file_timeout);
wait_file(File, N) ->
    case file:read_file(File) of
        {ok, B} when byte_size(B) > 0 -> string:trim(binary_to_list(B));
        _ -> timer:sleep(100), wait_file(File, N - 1)
    end.

sh_quote(S) ->
    "'" ++ lists:flatten(string:replace(S, "'", "'\\''", all)) ++ "'".

%% Run the CLI synchronously; returns {ExitStatus, Output}.
run_cli(Cli, Args) ->
    run_port(Cli, Args).

run_port(Exe, Args) ->
    Port = open_port({spawn_executable, Exe},
                     [{args, Args}, exit_status, binary, stderr_to_stdout,
                      {env, [{"POLYCALL_TELEMETRY", "off"}, {"LD_PRELOAD", false}]}]),
    collect(Port, []).

collect(Port, Acc) ->
    receive
        {Port, {data, D}} -> collect(Port, [D | Acc]);
        {Port, {exit_status, S}} -> {S, iolist_to_binary(lists:reverse(Acc))}
    after 30000 ->
        catch port_close(Port),
        {timeout, iolist_to_binary(lists:reverse(Acc))}
    end.

skip_unless_cli(#{cli := false}, Name, _Tests) ->
    io:format(user, "SKIP ~s: polycall CLI not found~n", [Name]),
    [];
skip_unless_cli(_Env, _Name, Tests) ->
    Tests.

%%% ===================================================================
%%% helpers

err_reason({error, #polycall_error{reason = R}}) -> R;
err_reason(Other) -> {unexpected, Other}.

open_node(Id) ->
    {ok, P} = polycall_peer:open(Id, #{token => token()}),
    {ok, Ep} = polycall_peer:endpoint(P),
    {P, Ep}.

recv_ok(Peer, Timeout) ->
    {ok, Msg} = polycall_peer:recv(Peer, Timeout),
    Msg.

write_tmp(Name, Bytes) ->
    Path = filename:join(make_tmp(), Name),
    ok = file:write_file(Path, Bytes),
    Path.

binary_0_255() ->
    list_to_binary(lists:seq(0, 255)).

utf8_text() ->
    unicode:characters_to_binary("h\x{e9}llo \x{2014} \x{4e16}\x{754c} \x{1f30d}").

now_ms() ->
    erlang:monotonic_time(millisecond).

%%% ===================================================================
%%% library

library_tests() ->
    [{"version and ABI check", fun() ->
        ?assertEqual(1, erlang_polycall:abi_version()),
        ?assertEqual(<<"1.1.0">>, erlang_polycall:version()),
        ?assertMatch(<<"POLYCALL_E_TIMEOUT", _/binary>>, erlang_polycall:strerror(-4)),
        ?assertMatch(<<"POLYCALL_OK", _/binary>>, erlang_polycall:strerror(0)),
        ?assertNotEqual(nomatch, binary:match(erlang_polycall:strerror(-999), <<"UNKNOWN">>)),
        [?assertMatch(<<"POLYCALL_", _/binary>>, erlang_polycall:strerror(C))
         || C <- lists:seq(-18, 0)],
        ?assertEqual(undefined, erlang_polycall:load_error())
     end}].

%%% ===================================================================
%%% configuration

config_tests(#{tmp := Tmp}) ->
    Rc = fun(Name, Text) ->
             P = filename:join(Tmp, Name),
             ok = file:write_file(P, Text),
             P
         end,
    [{"run_config valid (legacy run_config/1 and strict run_config/2)", fun() ->
        ?assertEqual({ok, 0}, erlang_polycall:run_config(<<"erlang-polycallrc">>)),
        ?assertEqual({ok, 0}, erlang_polycall:run_config("examples/erlang-polycallrc")),
        ?assertEqual(ok, erlang_polycall:run_config("erlang-polycallrc", true)),
        ?assertEqual(ok, erlang_polycall:run_config_or_error("erlang-polycallrc"))
     end},
     {"run_config missing file -> not_found", fun() ->
        Missing = filename:join(Tmp, "does-not-exist-polycallrc"),
        R = erlang_polycall:run_config(Missing, true),
        ?assertEqual(not_found, err_reason(R)),
        {error, E} = R,
        ?assertEqual(-7, E#polycall_error.code),
        ?assertMatch(<<"POLYCALL_E_NOT_FOUND", _/binary>>, E#polycall_error.name),
        ?assertEqual({error, -7}, erlang_polycall:run_config(Missing)),
        ?assertError({polycall_error, -7}, erlang_polycall:run_config_or_error(Missing))
     end},
     {"run_config invalid -> config error naming the key", fun() ->
        P = Rc("bad-polycallrc", "max_connections=lots\n"),
        {error, E} = erlang_polycall:run_config(P, false),
        ?assertEqual(config, E#polycall_error.reason),
        ?assertNotEqual(nomatch, binary:match(E#polycall_error.detail, <<"max_connections">>))
     end},
     {"run_config strict: unknown key is a warning, strict an error", fun() ->
        P = Rc("unknown-polycallrc", "log_level=info\nmystery_key=1\n"),
        ?assertEqual(ok, erlang_polycall:run_config(P, false)),
        ?assertEqual(config, err_reason(erlang_polycall:run_config(P, true)))
     end},
     {"run_config tls_enabled=true -> unsupported when strict", fun() ->
        P = Rc("tls-polycallrc", "tls_enabled=true\ncert_file=/x/c.pem\nkey_file=/x/k.pem\n"),
        ?assertEqual(ok, erlang_polycall:run_config(P, false)),
        {error, E} = erlang_polycall:run_config(P, true),
        ?assertEqual(unsupported, E#polycall_error.reason),
        ?assertEqual(-15, E#polycall_error.code)
     end},
     {"run_config argument errors", fun() ->
        ?assertEqual(invalid_argument, err_reason(erlang_polycall:run_config(<<>>, true))),
        ?assertError(badarg, erlang_polycall:run_config(<<"a", 0, "b">>, true)),
        ?assertError(badarg, erlang_polycall:run_config(42, true))
     end},
     {"describe reports peers and keys", fun() ->
        P = Rc("Polycallfile", "server node 8080:8084\nnetwork start\nworkspace_root=/opt/x\n"
                              "log_directory=/var/log/x\ndaemon_endpoint=127.0.0.1:0\n"
                              "auth_token_env=POLYCALL_DEV_TOKEN\npeer_node_id=alpha\n"
                              "peer beta 127.0.0.1:9002\n"),
        ?assertEqual(ok, erlang_polycall:run_config(P, true)),
        {ok, Json} = erlang_polycall:describe(P),
        ?assertNotEqual(nomatch, binary:match(Json, <<"\"beta\":\"127.0.0.1:9002\"">>)),
        #{} = json:decode(Json)
     end},
     {"non-ASCII config path: Unicode string and UTF-8 binary reach the same file", fun() ->
        %% created by their UTF-8 bytes, so independent of
        %% file:native_name_encoding() (latin1 in a container without LANG)
        Dir = filename:join(Tmp, "conf-caf\x{e9}-\x{8a2d}\x{5b9a}"),
        Path = filename:join(Dir, "erlang-polycallrc-\x{1f30d}"),   %% a Unicode string
        PathBin = unicode:characters_to_binary(Path),
        ok = file:make_dir(unicode:characters_to_binary(Dir)),
        ok = file:write_file(PathBin, <<"log_level=info\nmax_connections=10\n">>),
        ?assertEqual(ok, erlang_polycall:run_config(Path, true)),
        ?assertEqual(ok, erlang_polycall:run_config(PathBin, true)),
        ?assertEqual({ok, 0}, erlang_polycall:run_config(Path)),
        ?assertEqual(ok, erlang_polycall:run_config([Dir, "/", <<"erlang-polycallrc-"/utf8>>,
                                                     <<"\x{1f30d}"/utf8>>], false)),
        {ok, Json} = erlang_polycall:describe(Path),
        #{} = json:decode(Json),
        %% a name of Latin-1 characters only (U+00E9) is sent as UTF-8 too,
        %% not as the byte 233
        Latin = filename:join(Tmp, "caf\x{e9}-polycallrc"),
        ok = file:write_file(unicode:characters_to_binary(Latin), <<"log_level=info\n">>),
        ?assertEqual(ok, erlang_polycall:run_config(Latin, true)),
        %% a missing non-ASCII path: not_found with a detail
        {error, E} = erlang_polycall:run_config(filename:join(Dir, "nope-\x{e9}"), true),
        ?assertEqual(not_found, E#polycall_error.reason),
        ?assertNotEqual(<<>>, E#polycall_error.detail),
        %% invalid chardata is a badarg, never a crash
        ?assertError(badarg, erlang_polycall:run_config([16#110000], true))
     end}].

%%% ===================================================================
%%% RPC against `polycall start`

rpc_tests(#{cli := false} = Env) ->
    skip_unless_cli(Env, "polycall_call checks", []);
rpc_tests(#{rpc := Ep}) ->
    [{"call success (inventory.get against polycall start)", fun() ->
        {ok, Out} = erlang_polycall:call(Ep, "inventory", "get",
                                         <<"{\"item_id\":\"widget-a\"}">>, 5000),
        ?assertMatch(#{<<"item_id">> := <<"widget-a">>, <<"quantity">> := 42,
                       <<"in_stock">> := true}, json:decode(Out))
     end},
     {"call debug.echo round-trips UTF-8 JSON; null input", fun() ->
        In = iolist_to_binary(json:encode(#{<<"text">> => utf8_text()})),
        {ok, Out} = erlang_polycall:call(Ep, <<"debug">>, <<"echo">>, In, 5000),
        ?assertEqual(#{<<"echo">> => #{<<"text">> => utf8_text()}}, json:decode(Out)),
        {ok, Null} = erlang_polycall:call(Ep, <<"debug">>, <<"echo">>, null, 5000),
        ?assertEqual(#{<<"echo">> => null}, json:decode(Null))
     end},
     {"call unknown operation -> not_found with the remote error object", fun() ->
        {error, E} = erlang_polycall:call(Ep, "inventory", "nope", null, 5000),
        ?assertEqual(not_found, E#polycall_error.reason),
        ?assertMatch(#{<<"code">> := <<"operation.unknown">>}, json:decode(E#polycall_error.info))
     end},
     {"call remote failure -> remote (item.unknown)", fun() ->
        {error, E} = erlang_polycall:call(Ep, "inventory", "get",
                                          <<"{\"item_id\":\"nope\"}">>, 5000),
        ?assertEqual(remote, E#polycall_error.reason),
        ?assertMatch(#{<<"code">> := <<"item.unknown">>}, json:decode(E#polycall_error.info))
     end},
     {"call deadline exceeded -> timeout", fun() ->
        T0 = now_ms(),
        R = erlang_polycall:call(Ep, "debug", "sleep", <<"{\"ms\":3000}">>, 300),
        ?assertEqual(timeout, err_reason(R)),
        ?assert(now_ms() - T0 < 2900)
     end},
     {"call invalid input -> invalid_argument (never sent)", fun() ->
        ?assertEqual(invalid_argument,
                     err_reason(erlang_polycall:call(Ep, "debug", "echo", <<"{bad">>, 1000))),
        ?assertEqual(invalid_argument,
                     err_reason(erlang_polycall:call(Ep, "debug", "echo", null, 0))),
        ?assertEqual(invalid_argument,
                     err_reason(erlang_polycall:call(Ep, "debug", "echo", null, 600001))),
        ?assertEqual(invalid_argument,
                     err_reason(erlang_polycall:call("no-port", "debug", "echo", null, 1000))),
        ?assertEqual(invalid_argument,
                     err_reason(erlang_polycall:call(Ep, "", "echo", null, 1000)))
     end},
     {"call with no runtime -> transport (detail names the endpoint)", fun() ->
        {ok, P} = polycall_peer:open("probe"),
        {ok, Free} = polycall_peer:endpoint(P),
        ok = polycall_peer:close(P),
        {error, E} = erlang_polycall:call(Free, "debug", "echo", null, 2000),
        ?assertEqual(transport, E#polycall_error.reason),
        ?assertEqual(-5, E#polycall_error.code),
        ?assertMatch(<<"POLYCALL_E_TRANSPORT", _/binary>>, E#polycall_error.name),
        ?assertNotEqual(nomatch, binary:match(E#polycall_error.detail, Free))
     end},
     {timeout, 60, {"call sizes: 60 KiB echoed exactly; 70 KiB -> remote output.too_large; request over 1 MiB -> too_large", fun() ->
        %% the core runtime gives an operation a 64 KiB output buffer
        %% (RT_OUT_CAP in src/runtime/runtime.c), so that is the largest
        %% output a built-in operation can produce
        Text = binary:copy(<<"0123456789abcdef">>, 60 * 64),
        In = json:encode(#{<<"text">> => Text}),            %% iodata
        {ok, Out} = erlang_polycall:call(Ep, "debug", "echo", In, 20000),
        ?assertEqual(#{<<"echo">> => #{<<"text">> => Text}}, json:decode(Out)),
        {error, E} = erlang_polycall:call(Ep, "debug", "echo",
                                          json:encode(binary:copy(<<"x">>, 70 * 1024)), 5000),
        ?assertEqual(remote, E#polycall_error.reason),
        ?assertMatch(#{<<"code">> := <<"output.too_large">>}, json:decode(E#polycall_error.info)),
        Huge = iolist_to_binary(json:encode(binary:copy(<<"x">>, ?MIB + 1))),
        {error, E2} = erlang_polycall:call(Ep, "debug", "echo", Huge, 5000),
        ?assertEqual(too_large, E2#polycall_error.reason),
        ?assertNotEqual(nomatch, binary:match(E2#polycall_error.detail, <<"1 MiB">>))
     end}},
     {timeout, 60, {"concurrent calls: 32 processes x 8 calls, every answer matches its request", fun() ->
        Self = self(),
        Pids = [spawn_link(fun() ->
                    Ok = lists:all(
                           fun(J) ->
                               In = json:encode(#{<<"p">> => I, <<"n">> => J}),
                               {ok, Out} = erlang_polycall:call(Ep, "debug", "echo", In, 20000),
                               json:decode(Out) =:= #{<<"echo">> => #{<<"p">> => I, <<"n">> => J}}
                           end, lists:seq(1, 8)),
                    Self ! {done, self(), Ok}
                end) || I <- lists:seq(1, 32)],
        [receive {done, P, Ok} -> ?assert(Ok) after 40000 -> error({call_stuck, P}) end
         || P <- Pids]
     end}}].

%%% ===================================================================
%%% RPC against `polycall daemon` (private state dir)

daemon_tests(#{cli := false} = Env) ->
    skip_unless_cli(Env, "polycall daemon checks", []);
daemon_tests(#{daemon := Ep}) ->
    [{"call against polycall daemon: success, unknown operation, remote error, deadline", fun() ->
        {ok, Out} = erlang_polycall:call(Ep, "inventory", "get",
                                         <<"{\"item_id\":\"widget-a\"}">>, 5000),
        ?assertMatch(#{<<"item_id">> := <<"widget-a">>, <<"quantity">> := 42}, json:decode(Out)),
        {error, E} = erlang_polycall:call(Ep, "inventory", "nope", null, 5000),
        ?assertEqual(not_found, E#polycall_error.reason),
        ?assertMatch(<<"POLYCALL_E_NOT_FOUND", _/binary>>, E#polycall_error.name),
        ?assertNotEqual(nomatch, binary:match(E#polycall_error.detail, <<"operation.unknown">>)),
        ?assertMatch(#{<<"code">> := <<"operation.unknown">>}, json:decode(E#polycall_error.info)),
        ?assertEqual(remote, err_reason(erlang_polycall:call(Ep, "inventory", "get",
                                                             <<"{\"item_id\":\"nope\"}">>, 5000))),
        ?assertEqual(timeout, err_reason(erlang_polycall:call(Ep, "debug", "sleep",
                                                              <<"{\"ms\":2000}">>, 200)))
     end}].

%%% ===================================================================
%%% peers (two or more Erlang-side nodes, real sockets)

peer_tests(_Env) ->
    [{"peer open: endpoint, node id, send-only, invalid arguments", fun() ->
        {ok, P} = polycall_peer:open(<<"erl-open">>),
        {ok, Ep} = polycall_peer:endpoint(P),
        ?assertMatch(<<"127.0.0.1:", _/binary>>, Ep),
        ?assertNotEqual(<<"127.0.0.1:0">>, Ep),
        ?assertEqual({ok, <<"erl-open">>}, polycall_peer:node_id(P)),
        ?assert(polycall_peer:handle(P) > 0),
        {ok, H} = polycall_peer:health(P),
        ?assertMatch(#{<<"node_id">> := <<"erl-open">>}, json:decode(H)),
        ok = polycall_peer:close(P),
        {ok, S} = polycall_peer:open("erl-sendonly", #{bind => undefined}),
        ?assertEqual({ok, <<>>}, polycall_peer:endpoint(S)),
        ok = polycall_peer:close(S),
        ?assertEqual(invalid_argument, err_reason(polycall_peer:open("bad id!"))),
        ?assertEqual(invalid_argument, err_reason(polycall_peer:open(binary:copy(<<"a">>, 64)))),
        ?assertEqual(invalid_argument, err_reason(polycall_peer:open("x", #{bind => "nonsense"}))),
        ?assertEqual(config, err_reason(polycall_peer:open("x", #{bind => "0.0.0.0:0"}))),
        %% ids are [A-Za-z0-9._-]: a non-ASCII id reaches the core as UTF-8
        %% and is refused there, with the detail
        {error, E} = polycall_peer:open("n\x{f6}de-\x{4e16}"),
        ?assertEqual(invalid_argument, E#polycall_error.reason),
        ?assertMatch(<<"POLYCALL_E_INVALID_ARGUMENT", _/binary>>, E#polycall_error.name),
        ?assertNotEqual(nomatch, binary:match(E#polycall_error.detail, <<"node_id">>)),
        ?assertError(badarg, polycall_peer:open(<<"a", 0, "b">>)),
        ?assertError(badarg, polycall_peer:open(alpha))
     end},
     {timeout, 60, {"recv buffer boundaries: 1 MiB into exactly 1 MiB; 1 MiB - 1 and 0 leave it queued", fun() ->
        {A, _} = open_node("erl-cap-a"),
        {B, EpB} = open_node("erl-cap-b"),
        Big = crypto:strong_rand_bytes(?MIB),
        ok = polycall_peer:send(A, EpB, Big, #{message_id => "m-mib", timeout => 10000}),
        {error, E} = polycall_peer:recv(B, 5000, ?MIB - 1),
        ?assertEqual({too_large, ?MIB}, {E#polycall_error.reason, E#polycall_error.info}),
        ?assertNotEqual(<<>>, E#polycall_error.detail),
        {error, E0} = polycall_peer:recv(B, 0, 0),
        ?assertEqual({too_large, ?MIB}, {E0#polycall_error.reason, E0#polycall_error.info}),
        ?assertEqual(#{sender => <<"erl-cap-a">>, message_id => <<"m-mib">>, payload => Big},
                     element(2, polycall_peer:recv(B, 1000, ?MIB))),
        ok = polycall_peer:send(A, EpB, <<>>, #{message_id => "m-zero"}),
        ?assertEqual({ok, #{sender => <<"erl-cap-a">>, message_id => <<"m-zero">>, payload => <<>>}},
                     polycall_peer:recv(B, 3000, 0)),
        ok = polycall_peer:send(A, EpB, <<0>>, #{message_id => "m-one"}),
        ?assertEqual({ok, #{sender => <<"erl-cap-a">>, message_id => <<"m-one">>, payload => <<0>>}},
                     polycall_peer:recv(B, 3000, 1)),
        ?assertError(badarg, polycall_peer:recv(B, 0, ?MIB + 1)),
        ?assertError(badarg, polycall_peer:recv(B, 0, -1)),
        ok = polycall_peer:close(A), ok = polycall_peer:close(B)
     end}},
     {timeout, 30, {"timeout boundaries: 0..4294967295 | infinity, anything else is badarg", fun() ->
        {A, EpA} = open_node("erl-tmo"),
        ?assertError(badarg, polycall_peer:recv(A, -1)),
        ?assertError(badarg, polycall_peer:recv(A, 4294967296)),
        ?assertError(badarg, polycall_peer:recv(A, 1.5)),
        ?assertError(badarg, polycall_peer:send(A, EpA, <<"x">>, #{timeout => 4294967296})),
        ?assertError(badarg, polycall_peer:ping(A, EpA, -5)),
        ?assertError(badarg, erlang_polycall:call(EpA, "debug", "echo", null, 4294967296)),
        ?assertEqual(timeout, err_reason(polycall_peer:recv(A, 1))),
        %% 4294967295 is the ABI's "wait indefinitely": only cancel ends it
        Self = self(),
        spawn(fun() -> Self ! {woke, polycall_peer:recv(A, 4294967295)} end),
        receive {woke, Early} -> error({returned_early, Early}) after 600 -> ok end,
        ok = polycall_peer:cancel(A),
        receive {woke, R} -> ?assertEqual(cancelled, err_reason(R))
        after 3000 -> error(cancel_did_not_wake_recv) end,
        %% a long finite wait reports the caller's timeout, not a slice
        {error, ET} = polycall_peer:recv(A, 450),
        ?assertEqual(timeout, ET#polycall_error.reason),
        ?assertEqual(<<"no message within 450 ms">>, ET#polycall_error.detail),
        ok = polycall_peer:close(A)
     end}},
     {timeout, 60, {"one node shared by many processes: 8 senders on one handle, 4 receivers, each message once", fun() ->
        {S, _} = open_node("erl-share-s"),
        {R, EpR} = open_node("erl-share-r"),
        Senders = 8, Per = 25,
        Self = self(),
        Receivers = [spawn_link(fun() -> Self ! {got, self(), drain(R, [])} end)
                     || _ <- lists:seq(1, 4)],
        [spawn_link(fun() ->
                        [ok = polycall_peer:send(S, EpR, <<I:32, J:32>>,
                                                 #{message_id => io_lib:format("s~b-~b", [I, J])})
                         || J <- lists:seq(1, Per)],
                        Self ! {sent, I}
                    end) || I <- lists:seq(1, Senders)],
        [receive {sent, I} -> ok after 30000 -> error({sender_stuck, I}) end
         || I <- lists:seq(1, Senders)],
        Got = lists:append([receive {got, P, L} -> L after 30000 -> error({receiver_stuck, P}) end
                            || P <- Receivers]),
        Expected = lists:sort([<<I:32, J:32>> || I <- lists:seq(1, Senders), J <- lists:seq(1, Per)]),
        ?assertEqual(Expected, lists:sort(Got)),           %% all, and none twice
        {ok, H} = polycall_peer:health(S),
        ?assertMatch(#{<<"sent_ok">> := 200}, json:decode(H)),
        ok = polycall_peer:close(S), ok = polycall_peer:close(R)
     end}},
     {timeout, 30, {"two Erlang nodes exchange payloads both ways (bytes, sender, id)", fun() ->
        {A, EpA} = open_node("erl-alpha"),
        {B, EpB} = open_node("erl-beta"),
        ok = polycall_peer:send(A, EpB, <<"hello beta">>, #{message_id => "m-a2b"}),
        ?assertEqual(#{sender => <<"erl-alpha">>, message_id => <<"m-a2b">>,
                       payload => <<"hello beta">>}, recv_ok(B, 3000)),
        ok = polycall_peer:send(B, EpA, [<<"hello ">>, "alpha"], #{message_id => <<"m-b2a">>}),
        ?assertEqual(#{sender => <<"erl-beta">>, message_id => <<"m-b2a">>,
                       payload => <<"hello alpha">>}, recv_ok(A, 3000)),
        %% generated message id
        ok = polycall_peer:send(A, EpB, <<"auto">>),
        #{message_id := Gen, payload := <<"auto">>} = recv_ok(B, 3000),
        ?assert(byte_size(Gen) > 0),
        ok = polycall_peer:close(A), ok = polycall_peer:close(B)
     end}},
     {timeout, 60, {"payloads: empty, UTF-8, binary with NUL, 1 MiB exact, 1 MiB + 1", fun() ->
        {A, _} = open_node("erl-sizes-a"),
        {B, EpB} = open_node("erl-sizes-b"),
        Big = crypto:strong_rand_bytes(?MIB),
        Cases = [{"m-empty", <<>>}, {"m-utf8", utf8_text()},
                 {"m-bin", binary_0_255()}, {"m-nul", <<0, 0, 1, 0>>}, {"m-max", Big}],
        lists:foreach(
          fun({Id, Bytes}) ->
              ok = polycall_peer:send(A, EpB, Bytes, #{message_id => Id, timeout => 10000}),
              #{sender := <<"erl-sizes-a">>, message_id := MId, payload := Got} = recv_ok(B, 10000),
              ?assertEqual(list_to_binary(Id), MId),
              ?assertEqual(Bytes, Got)
          end, Cases),
        Over = <<Big/binary, 7>>,
        {error, E} = polycall_peer:send(A, EpB, Over, #{message_id => "m-over"}),
        ?assertEqual(too_large, E#polycall_error.reason),
        ?assertEqual(timeout, err_reason(polycall_peer:recv(B, 300))),
        ok = polycall_peer:close(A), ok = polycall_peer:close(B)
     end}},
     {timeout, 30, {"registry ownership: per node, explicit, never implied by receiving", fun() ->
        {A, EpA} = open_node("erl-reg-a"),
        {B, EpB} = open_node("erl-reg-b"),
        ?assertEqual(#{}, json:decode(element(2, polycall_peer:list(A)))),
        ok = polycall_peer:register(A, "erl-reg-b", EpB),
        ?assertEqual(#{<<"erl-reg-b">> => EpB}, json:decode(element(2, polycall_peer:list(A)))),
        ?assertEqual(#{}, json:decode(element(2, polycall_peer:list(B)))),
        ok = polycall_peer:send(A, "erl-reg-b", <<"by id">>, #{message_id => "m-id"}),
        #{sender := <<"erl-reg-a">>, payload := <<"by id">>} = recv_ok(B, 3000),
        %% receiving never registers the sender
        ?assertEqual(#{}, json:decode(element(2, polycall_peer:list(B)))),
        ok = polycall_peer:ping(A, "erl-reg-b", 2000),
        ok = polycall_peer:ping(A, EpA, 2000),
        %% a registered id answered by a node with another identity
        ok = polycall_peer:register(A, "impostor", EpB),
        ?assertEqual(protocol, err_reason(polycall_peer:ping(A, "impostor", 2000))),
        %% the receiver may already have stored it: "not known to be delivered"
        ?assertEqual(protocol, err_reason(polycall_peer:send(A, "impostor", <<"x">>))),
        _ = polycall_peer:recv(B, 500),
        ok = polycall_peer:unregister(A, "impostor"),
        ok = polycall_peer:unregister(A, "erl-reg-b"),
        ?assertEqual(not_found, err_reason(polycall_peer:unregister(A, "erl-reg-b"))),
        ?assertEqual(not_found, err_reason(polycall_peer:send(A, "erl-reg-b", <<"x">>))),
        ?assertEqual(invalid_argument, err_reason(polycall_peer:register(A, "bad id", EpB))),
        ?assertEqual(#{}, json:decode(element(2, polycall_peer:list(A)))),
        ok = polycall_peer:close(A), ok = polycall_peer:close(B)
     end}},
     {timeout, 30, {"duplicate message id is delivered once", fun() ->
        {A, _} = open_node("erl-dup-a"),
        {B, EpB} = open_node("erl-dup-b"),
        ok = polycall_peer:send(A, EpB, <<"once">>, #{message_id => "m-dup"}),
        ok = polycall_peer:send(A, EpB, <<"once">>, #{message_id => "m-dup"}),
        ?assertEqual(#{sender => <<"erl-dup-a">>, message_id => <<"m-dup">>, payload => <<"once">>},
                     recv_ok(B, 3000)),
        ?assertEqual(timeout, err_reason(polycall_peer:recv(B, 500))),
        {ok, H} = polycall_peer:health(B),
        ?assertMatch(#{<<"duplicates">> := 1}, json:decode(H)),
        ok = polycall_peer:close(A), ok = polycall_peer:close(B)
     end}},
     {timeout, 30, {"auth failure: wrong or missing token is refused, nothing queued", fun() ->
        {B, EpB} = open_node("erl-auth-b"),
        {ok, Wrong} = polycall_peer:open("erl-mallory", #{token => "not-the-token"}),
        ?assertEqual(auth, err_reason(polycall_peer:send(Wrong, EpB, <<"x">>))),
        {ok, None} = polycall_peer:open("erl-anon", #{bind => undefined}),
        ?assertEqual(auth, err_reason(polycall_peer:send(None, EpB, <<"x">>))),
        ?assertEqual(timeout, err_reason(polycall_peer:recv(B, 300))),
        %% /health needs no token
        ok = polycall_peer:ping(None, EpB, 2000),
        [ok = polycall_peer:close(P) || P <- [B, Wrong, None]]
     end}},
     {timeout, 30, {"send to a dead peer -> transport", fun() ->
        {A, _} = open_node("erl-live"),
        {D, EpD} = open_node("erl-dead"),
        ok = polycall_peer:close(D),
        ?assertEqual(transport, err_reason(polycall_peer:send(A, EpD, <<"void">>, #{timeout => 2000}))),
        ?assertEqual(transport, err_reason(polycall_peer:ping(A, EpD, 1000))),
        ok = polycall_peer:close(A)
     end}},
     {timeout, 30, {"receive timeout and poll", fun() ->
        {A, _} = open_node("erl-timeout"),
        T0 = now_ms(),
        ?assertEqual(timeout, err_reason(polycall_peer:recv(A, 250))),
        Elapsed = now_ms() - T0,
        ?assert(Elapsed >= 200),
        ?assert(Elapsed < 3000),
        ?assertEqual(timeout, err_reason(polycall_peer:recv(A, 0))),
        ok = polycall_peer:close(A)
     end}},
     {timeout, 30, {"too-small buffer -> too_large with size, message stays queued", fun() ->
        {A, _} = open_node("erl-small-a"),
        {B, EpB} = open_node("erl-small-b"),
        Payload = binary:copy(<<"0123456789">>, 10),
        ok = polycall_peer:send(A, EpB, Payload, #{message_id => "m-small"}),
        {error, E} = polycall_peer:recv(B, 3000, 10),
        ?assertEqual(too_large, E#polycall_error.reason),
        ?assertEqual(100, E#polycall_error.info),
        ?assertEqual(#{sender => <<"erl-small-a">>, message_id => <<"m-small">>, payload => Payload},
                     recv_ok(B, 1000)),
        ok = polycall_peer:close(A), ok = polycall_peer:close(B)
     end}},
     {timeout, 30, {"cancel wakes a blocked recv; later calls wait normally", fun() ->
        {A, _} = open_node("erl-cancel"),
        Self = self(),
        W = spawn(fun() -> Self ! {woke, self(), polycall_peer:recv(A, infinity)} end),
        timer:sleep(300),
        ok = polycall_peer:cancel(A),
        receive {woke, W, R} -> ?assertEqual(cancelled, err_reason(R))
        after 5000 -> error(cancel_did_not_wake_recv) end,
        ?assertEqual(timeout, err_reason(polycall_peer:recv(A, 100))),
        ok = polycall_peer:close(A)
     end}},
     {timeout, 30, {"close wakes a blocked recv with closed", fun() ->
        {A, _} = open_node("erl-close-wake"),
        Self = self(),
        W = spawn(fun() -> Self ! {woke, self(), polycall_peer:recv(A, infinity)} end),
        timer:sleep(300),
        ok = polycall_peer:close(A),
        receive {woke, W, R} -> ?assertEqual(closed, err_reason(R))
        after 5000 -> error(close_did_not_wake_recv) end
     end}},
     {timeout, 30, {"double close, use after close, invalid handles are defined", fun() ->
        {A, EpA} = open_node("erl-closed"),
        ok = polycall_peer:close(A),
        {error, E2} = polycall_peer:close(A),
        ?assertEqual({invalid_handle, -3}, {E2#polycall_error.reason, E2#polycall_error.code}),
        ?assertMatch(<<"POLYCALL_E_INVALID_HANDLE", _/binary>>, E2#polycall_error.name),
        ?assertNotEqual(<<>>, E2#polycall_error.detail),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:close(A))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:unregister(A, "x"))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:recv(A, infinity))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:send(A, EpA, <<"x">>))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:recv(A, 0))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:endpoint(A))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:node_id(A))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:list(A))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:health(A))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:register(A, "x", EpA))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:cancel(A))),
        ?assertEqual(invalid_handle, err_reason(polycall_peer:ping(A, EpA, 100))),
        %% a term that is not a peer resource is a badarg, never a crash
        ?assertError(badarg, polycall_peer:close(make_ref())),
        ?assertError(badarg, polycall_peer:send(42, EpA, <<"x">>))
     end}},
     {timeout, 30, {"garbage-collected peer resource closes its node", fun() ->
        Self = self(),
        spawn(fun() ->
                  {ok, P} = polycall_peer:open("erl-gc"),
                  {ok, Ep} = polycall_peer:endpoint(P),
                  Self ! {gc_ep, Ep}
              end),
        Ep = receive {gc_ep, E} -> E after 5000 -> error(no_endpoint) end,
        {ok, Probe} = polycall_peer:open("erl-gc-probe", #{bind => undefined}),
        erlang:garbage_collect(),
        ?assert(wait_until(fun() -> polycall_peer:ping(Probe, Ep, 500) =/= ok end, 50)),
        ?assertEqual(transport, err_reason(polycall_peer:ping(Probe, Ep, 500))),
        ok = polycall_peer:close(Probe)
     end}},
     {timeout, 60, {"concurrent senders (8 processes x 25 messages) all delivered once", fun() ->
        {B, EpB} = open_node("erl-conc-b"),
        Senders = 8, PerSender = 25,
        Self = self(),
        [spawn_link(fun() ->
                        {ok, S} = polycall_peer:open("erl-conc-" ++ integer_to_list(I),
                                                     #{bind => undefined, token => token()}),
                        [ok = polycall_peer:send(S, EpB, <<I:32, J:32>>,
                                                 #{message_id => io_lib:format("c~b-~b", [I, J])})
                         || J <- lists:seq(1, PerSender)],
                        ok = polycall_peer:close(S),
                        Self ! {sent, I}
                    end) || I <- lists:seq(1, Senders)],
        [receive {sent, I} -> ok after 30000 -> error({sender_stuck, I}) end
         || I <- lists:seq(1, Senders)],
        Got = [recv_ok(B, 5000) || _ <- lists:seq(1, Senders * PerSender)],
        ?assertEqual(timeout, err_reason(polycall_peer:recv(B, 200))),
        Keys = lists:usort([{S, M, P} || #{sender := S, message_id := M, payload := P} <- Got]),
        ?assertEqual(Senders * PerSender, length(Keys)),
        Expected = lists:usort([{list_to_binary("erl-conc-" ++ integer_to_list(I)),
                                 iolist_to_binary(io_lib:format("c~b-~b", [I, J])),
                                 <<I:32, J:32>>}
                                || I <- lists:seq(1, Senders), J <- lists:seq(1, PerSender)]),
        ?assertEqual(Expected, Keys),
        ok = polycall_peer:close(B)
     end}},
     {timeout, 30, {"blocked recv runs on a dirty I/O scheduler (one normal scheduler stays free)", fun() ->
        ?assert(erlang:system_info(dirty_io_schedulers) > 0),
        {A, _} = open_node("erl-dirty"),
        Old = erlang:system_flag(schedulers_online, 1),
        try
            Self = self(),
            W = spawn(fun() -> Self ! {done, self(), polycall_peer:recv(A, 1500)} end),
            timer:sleep(100),
            T0 = now_ms(),
            Echo = spawn(fun() -> receive {ping, F} -> F ! pong end end),
            Echo ! {ping, self()},
            receive pong -> ok after 1000 -> error(normal_scheduler_blocked) end,
            timer:sleep(50),
            ?assert(now_ms() - T0 < 500),
            receive {done, W, R} -> ?assertEqual(timeout, err_reason(R))
            after 5000 -> error(recv_never_returned) end
        after
            erlang:system_flag(schedulers_online, Old)
        end,
        ok = polycall_peer:close(A)
     end}}].

wait_until(_F, 0) -> false;
wait_until(F, N) ->
    case F() of
        true -> true;
        false -> timer:sleep(100), wait_until(F, N - 1)
    end.

%% receive payloads until the node stays quiet for 2 s
drain(Peer, Acc) ->
    case polycall_peer:recv(Peer, 2000) of
        {ok, #{payload := P}} -> drain(Peer, [P | Acc]);
        {error, #polycall_error{reason = timeout}} -> Acc
    end.

%%% ===================================================================
%%% dirty-scheduler fairness: more blocked receivers than dirty I/O
%%% schedulers (file I/O and code loading share those schedulers)

fairness_tests(#{tmp := Tmp}) ->
    Probe = filename:join(Tmp, "dirty-io-probe"),
    ok = file:write_file(Probe, <<"probe">>),
    Waiters = fun(Peer, N) ->
                  Self = self(),
                  [spawn(fun() -> Self ! {woke, self(), polycall_peer:recv(Peer, infinity)} end)
                   || _ <- lists:seq(1, N)]
              end,
    FileReadMs = fun() ->
                     Self = self(),
                     T0 = now_ms(),
                     F = spawn(fun() -> Self ! {file, self(), file:read_file(Probe)} end),
                     receive {file, F, {ok, <<"probe">>}} -> now_ms() - T0
                     after 5000 -> starved
                     end
                 end,
    N = erlang:system_info(dirty_io_schedulers) + 2,
    [{timeout, 60, {"N+2 receivers waiting with infinity do not starve file I/O; cancel wakes all N+2", fun() ->
        {A, _} = open_node("erl-fair-cancel"),
        Rs = Waiters(A, N),
        timer:sleep(500),
        Ms = try FileReadMs() after ok = polycall_peer:cancel(A) end,
        Woken = [receive {woke, P, R} -> err_reason(R) after 5000 -> {not_woken, P} end || P <- Rs],
        ok = polycall_peer:close(A),
        ?assert(is_integer(Ms) andalso Ms < 2000),
        ?assertEqual(lists:duplicate(N, cancelled), Woken)
     end}},
     {timeout, 60, {"killed receivers release their dirty schedulers", fun() ->
        {A, _} = open_node("erl-fair-kill"),
        Rs = Waiters(A, N),
        timer:sleep(500),
        Refs = [monitor(process, P) || P <- Rs],
        [exit(P, kill) || P <- Rs],
        [receive {'DOWN', Ref, process, _, killed} -> ok after 5000 -> error(not_down) end
         || Ref <- Refs],
        timer:sleep(100),
        Ms = try FileReadMs() after ok = polycall_peer:close(A) end,
        ?assert(is_integer(Ms) andalso Ms < 2000)
     end}},
     {timeout, 60, {"close wakes all N+2 receivers with closed (also those not yet in the core)", fun() ->
        {A, _} = open_node("erl-fair-close"),
        Rs = Waiters(A, N),
        timer:sleep(500),
        ok = polycall_peer:close(A),
        Woken = [receive {woke, P, R} -> err_reason(R) after 5000 -> {not_woken, P} end || P <- Rs],
        ?assertEqual(lists:duplicate(N, closed), Woken)
     end}}].

%%% ===================================================================
%%% interop with the C CLI node (`polycall peer serve`, other OS process)

interop_tests(#{cli := false} = Env) ->
    skip_unless_cli(Env, "interop with polycall peer serve", []);
interop_tests(#{cli := Cli, cli_node := CliEp}) ->
    Big = crypto:strong_rand_bytes(?MIB),
    [{timeout, 60, {"interop: Erlang peer -> C CLI node (verified by polycall peer recv)", fun() ->
        {A, _} = open_node("erl-interop"),
        lists:foreach(
          fun({Id, Bytes}) ->
              ok = polycall_peer:send(A, CliEp, Bytes, #{message_id => Id, timeout => 10000}),
              {0, Out} = run_cli(Cli, ["peer", "recv", "--to", CliEp, "-t", "5000"]),
              ?assertMatch(#{<<"from">> := <<"erl-interop">>}, cli_message(Out)),
              #{<<"id">> := MId, <<"payload_b64">> := B64} = cli_message(Out),
              ?assertEqual(list_to_binary(Id), MId),
              ?assertEqual(Bytes, base64:decode(B64))
          end,
          [{"x-e2c-text", <<"hello C node">>}, {"x-e2c-utf8", utf8_text()},
           {"x-e2c-bin", binary_0_255()}, {"x-e2c-nul", <<0, 0, 1, 0>>},
           {"x-e2c-empty", <<>>}, {"x-e2c-mib", Big}]),
        %% by registered id: the C node must acknowledge as "cli-node"
        ok = polycall_peer:register(A, "cli-node", CliEp),
        ok = polycall_peer:ping(A, "cli-node", 2000),
        ok = polycall_peer:send(A, "cli-node", <<"by id">>, #{message_id => "x-e2c-id"}),
        {0, Out2} = run_cli(Cli, ["peer", "recv", "--to", CliEp, "-t", "5000"]),
        ?assertMatch(#{<<"from">> := <<"erl-interop">>, <<"id">> := <<"x-e2c-id">>},
                     cli_message(Out2)),
        ok = polycall_peer:register(A, "not-cli-node", CliEp),
        ?assertEqual(protocol, err_reason(polycall_peer:ping(A, "not-cli-node", 2000))),
        ok = polycall_peer:close(A)
     end}},
     {timeout, 60, {"interop: C CLI (polycall peer send/register/health) -> Erlang peer", fun() ->
        {A, EpA} = open_node("erl-interop-rx"),
        To = binary_to_list(EpA),
        BinFile = write_tmp("bin.in", binary_0_255()),
        BigFile = write_tmp("mib.in", Big),
        {0, _} = run_cli(Cli, ["peer", "send", "--from", "cli-node", "--to", To,
                               "--id", "x-c2e-text", "--payload", "hello Erlang"]),
        ?assertEqual(#{sender => <<"cli-node">>, message_id => <<"x-c2e-text">>,
                       payload => <<"hello Erlang">>}, recv_ok(A, 3000)),
        {0, _} = run_cli(Cli, ["peer", "send", "--from", "cli-node", "--to", To,
                               "--id", "x-c2e-bin", "--payload-file", BinFile]),
        ?assertEqual(#{sender => <<"cli-node">>, message_id => <<"x-c2e-bin">>,
                       payload => binary_0_255()}, recv_ok(A, 3000)),
        {0, _} = run_cli(Cli, ["peer", "send", "--from", "cli-node", "--to", To,
                               "--id", "x-c2e-mib", "--payload-file", BigFile, "-t", "10000"]),
        ?assertEqual(#{sender => <<"cli-node">>, message_id => <<"x-c2e-mib">>,
                       payload => Big}, recv_ok(A, 5000)),
        %% the CLI sending the same message id again: delivered once
        {0, _} = run_cli(Cli, ["peer", "send", "--from", "cli-node", "--to", To,
                               "--id", "x-c2e-text", "--payload", "hello Erlang"]),
        ?assertEqual(timeout, err_reason(polycall_peer:recv(A, 300))),
        %% the authenticated POST /register of this node changes its registry
        {0, _} = run_cli(Cli, ["peer", "register", "--to", To, "--id", "from-cli",
                               "--peer-endpoint", "127.0.0.1:9"]),
        ?assertEqual(#{<<"from-cli">> => <<"127.0.0.1:9">>},
                     json:decode(element(2, polycall_peer:list(A)))),
        %% the CLI's view of the Erlang node
        {0, H} = run_cli(Cli, ["peer", "health", "--to", To]),
        ?assertNotEqual(nomatch, binary:match(H, <<"\"node_id\":\"erl-interop-rx\"">>)),
        ok = polycall_peer:ping(A, CliEp, 2000),
        ok = polycall_peer:close(A)
     end}}].

%% `polycall peer recv` prints {"from":..,"id":..,"payload_b64":..} (maybe
%% inside a {"message":...} envelope).
cli_message(Out) ->
    Line = lists:last([L || L <- binary:split(string:trim(Out), <<"\n">>, [global]),
                            binary:match(L, <<"{">>) =/= nomatch]),
    case json:decode(Line) of
        #{<<"message">> := M} when is_map(M) -> M;
        #{<<"data">> := #{<<"message">> := M}} -> M;
        M -> M
    end.
