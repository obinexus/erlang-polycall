%% Erlang binding for the Polycall C library, binding ABI v1
%% (<polycall.h>; contract: docs/BINDING_ABI.md in
%% https://github.com/obinexus/polycall).
%%
%% Library + configuration + RPC client live here; peer nodes are in
%% polycall_peer. Every blocking call runs on a dirty I/O scheduler.
-module(erlang_polycall).

-include("erlang_polycall.hrl").

-export([
    %% library
    abi_version/0,
    version/0,
    strerror/1,
    reason/1,
    format_error/1,
    load_error/0,
    %% configuration
    run_config/0,
    run_config/1,
    run_config/2,
    run_config_or_error/0,
    run_config_or_error/1,
    describe/1,
    %% RPC
    call/5
]).

%% internal, shared with polycall_peer
-export([nif/2, error_from/3, text/1]).

%% Text arguments (paths, endpoints, ids, names, tokens, JSON) are Unicode
%% chardata -- a string such as "conf/caf\x{e9}" or a UTF-8 binary -- and
%% reach the core as UTF-8, as the binding ABI requires. A binary is passed
%% through unchanged.
-type config_path() :: unicode:chardata().
-type status() :: integer().
-type result() :: {ok, 0} | {error, status()}.
-type polycall_error() :: #polycall_error{}.
-type json() :: binary().

-export_type([config_path/0, status/0, result/0, polycall_error/0, json/0]).

-define(DEFAULT_CONFIG, <<"erlang-polycallrc">>).
-define(LOAD_ERROR_KEY, {erlang_polycall, load_error}).

%%% ---------------------------------------------------------------------
%%% library

%% @doc POLYCALL_FFI_ABI_VERSION of the loaded library (always 1 here: the
%% NIF refuses to load a library reporting anything else).
-spec abi_version() -> integer().
abi_version() ->
    nif(nif_abi_version, []).

%% @doc Library version, e.g. <<"1.1.0">>.
-spec version() -> binary().
version() ->
    nif(nif_version, []).

%% @doc polycall_strerror(Code): static name for any status code.
-spec strerror(integer()) -> binary().
strerror(Code) when is_integer(Code) ->
    nif(nif_strerror, [Code]).

%% @doc A status code as an atom.
-spec reason(integer()) -> atom().
reason(0) -> ok;
reason(-1) -> invalid_argument;
reason(-2) -> no_memory;
reason(-3) -> invalid_handle;
reason(-4) -> timeout;
reason(-5) -> transport;
reason(-6) -> protocol;
reason(-7) -> not_found;
reason(-8) -> auth;
reason(-9) -> remote;
reason(-10) -> too_large;
reason(-11) -> busy;
reason(-12) -> cancelled;
reason(-13) -> config;
reason(-14) -> address_in_use;
reason(-15) -> unsupported;
reason(-16) -> permission;
reason(-17) -> closed;
reason(-18) -> internal;
reason(_) -> unknown.

%% @doc Human-readable text for a #polycall_error{}.
-spec format_error(polycall_error() | term()) -> string().
format_error(#polycall_error{code = Code, name = Name, detail = Detail}) ->
    lists:flatten(io_lib:format("~s (~p): ~s", [Name, Code, Detail]));
format_error({polycall_unavailable, Reason}) ->
    lists:flatten(io_lib:format("libpolycall is unavailable: ~p", [Reason]));
format_error(Other) ->
    lists:flatten(io_lib:format("~p", [Other])).

%% @doc Why the NIF library failed to load, or undefined when it loaded.
-spec load_error() -> term().
load_error() ->
    persistent_term:get(?LOAD_ERROR_KEY, undefined).

%%% ---------------------------------------------------------------------
%%% configuration

%% @doc Legacy entry point: polycall_ffi_run_config(Path, 1).
%% Returns {ok, 0} or {error, Status} (Status is the negative POLYCALL_E_*
%% code). Use run_config/2 for the detailed #polycall_error{}.
-spec run_config() -> result().
run_config() ->
    run_config(?DEFAULT_CONFIG).

-spec run_config(config_path()) -> result().
run_config(ConfigPath) ->
    case nif(nif_run_config, [text(ConfigPath), 1]) of
        ok -> {ok, 0};
        {error, Status, _Detail} -> {error, Status}
    end.

%% @doc polycall_ffi_run_config(Path, Strict). Strict = true validates for
%% running with this build (unknown keys are errors, tls_enabled=true is
%% refused with reason unsupported); false only validates. A non-ASCII path
%% is sent as UTF-8; the core opens it by that name (on Windows through
%% _wfopen).
-spec run_config(config_path(), boolean()) -> ok | {error, polycall_error()}.
run_config(ConfigPath, Strict) when is_boolean(Strict) ->
    Run = case Strict of true -> 1; false -> 0 end,
    case nif(nif_run_config, [text(ConfigPath), Run]) of
        ok -> ok;
        {error, Code, Detail} -> {error, error_from(Code, Detail, undefined)}
    end.

%% @doc Legacy: raises error({polycall_error, Status}) on failure.
-spec run_config_or_error() -> ok.
run_config_or_error() ->
    run_config_or_error(?DEFAULT_CONFIG).

-spec run_config_or_error(config_path()) -> ok.
run_config_or_error(ConfigPath) ->
    case run_config(ConfigPath) of
        {ok, 0} -> ok;
        {error, Status} -> erlang:error({polycall_error, Status})
    end.

%% @doc JSON description of a configuration file (secrets never resolved).
-spec describe(config_path()) -> {ok, json()} | {error, polycall_error()}.
describe(ConfigPath) ->
    case nif(nif_describe, [text(ConfigPath)]) of
        {ok, Json} -> {ok, Json};
        {error, Code, Detail} -> {error, error_from(Code, Detail, undefined)}
    end.

%%% ---------------------------------------------------------------------
%%% RPC

%% @doc One polycall_rpc v1 round trip (never retried) to a running
%% `polycall start' / `polycall daemon' at Endpoint ("host:port").
%% Input is JSON text (chardata, e.g. the iodata json:encode/1 returns) or
%% null. TimeoutMs is 1..600000 (the core rejects anything else with
%% invalid_argument). The call blocks a dirty I/O scheduler for at most
%% TimeoutMs. On error, #polycall_error.info holds the remote error object
%% JSON ({"code":..,"message":..}) when the runtime sent one.
-spec call(unicode:chardata(), unicode:chardata(), unicode:chardata(),
           unicode:chardata() | null, non_neg_integer()) ->
    {ok, json()} | {error, polycall_error()}.
call(Endpoint, Service, Operation, InputJson, TimeoutMs) when is_integer(TimeoutMs) ->
    Args = [text(Endpoint), text(Service), text(Operation), text(InputJson), TimeoutMs],
    case nif(nif_call, Args) of
        {ok, Output} -> {ok, Output};
        {error, Code, Detail, Info} -> {error, error_from(Code, Detail, Info)}
    end.

%%% ---------------------------------------------------------------------
%%% internal

%% @private Text argument -> UTF-8 binary (undefined/null kept for NULL).
%% Lists are Unicode chardata ("caf\x{e9}" becomes <<"caf", 195, 169>>, not
%% the Latin-1 byte 233); binaries are passed through unchanged; anything
%% else is left for the NIF to reject with badarg.
text(undefined) -> undefined;
text(null) -> null;
text(Bin) when is_binary(Bin) -> Bin;
text(List) when is_list(List) ->
    case unicode:characters_to_binary(List) of
        Bin when is_binary(Bin) -> Bin;
        _ -> erlang:error(badarg, [List])
    end;
text(Other) -> Other.

%% @private
error_from(Code, Detail, Info) ->
    #polycall_error{code = Code, reason = reason(Code), name = strerror(Code),
                    detail = Detail, info = Info}.

%% @private Call into the NIF; a library that failed to load (missing
%% libpolycall, old 1.0 library, ABI mismatch) is reported as
%% error({polycall_unavailable, Why}) instead of a bare undef.
nif(Fun, Args) ->
    try
        erlang:apply(erlang_polycall_nif, Fun, Args)
    catch
        error:undef:Stack ->
            case code:ensure_loaded(erlang_polycall_nif) of
                {module, _} -> erlang:raise(error, undef, Stack);
                {error, _} -> erlang:error({polycall_unavailable, load_error()})
            end
    end.
