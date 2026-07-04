-module(erlang_polycall).

-on_load(init/0).

-export([
    run_config/0,
    run_config/1,
    run_config_or_error/0,
    run_config_or_error/1
]).

-type config_path() :: iodata().
-type status() :: integer().
-type result() :: {ok, status()} | {error, status() | out_of_memory}.

-export_type([config_path/0, status/0, result/0]).

-spec init() -> ok | {error, term()}.
init() ->
    erlang:load_nif(filename:join(priv_dir(), "erlang_polycall_nif"), 0).

-spec priv_dir() -> file:filename_all().
priv_dir() ->
    case code:priv_dir(erlang_polycall) of
        {error, bad_name} ->
            Beam = code:which(?MODULE),
            filename:join(filename:dirname(filename:dirname(Beam)), "priv");
        Dir ->
            Dir
    end.

-spec run_config() -> result().
run_config() ->
    run_config(<<"erlang-polycallrc">>).

-spec run_config(config_path()) -> result().
run_config(_ConfigPath) ->
    erlang:nif_error(nif_not_loaded).

-spec run_config_or_error() -> ok.
run_config_or_error() ->
    run_config_or_error(<<"erlang-polycallrc">>).

-spec run_config_or_error(config_path()) -> ok.
run_config_or_error(ConfigPath) ->
    case run_config(ConfigPath) of
        {ok, 0} ->
            ok;
        {error, Status} ->
            erlang:error({polycall_error, Status})
    end.
