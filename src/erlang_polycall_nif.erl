%% @private
%% NIF stubs for the Polycall binding ABI v1. Use erlang_polycall and
%% polycall_peer instead of calling this module directly.
-module(erlang_polycall_nif).

-on_load(init/0).

-export([
    nif_abi_version/0, nif_version/0, nif_strerror/1,
    nif_run_config/2, nif_describe/1, nif_call/5,
    nif_peer_open/3, nif_peer_close/1, nif_peer_handle/1,
    nif_peer_endpoint/1, nif_peer_node_id/1,
    nif_peer_register/3, nif_peer_unregister/2, nif_peer_list/1,
    nif_peer_health/1, nif_peer_ping/3, nif_peer_send/5,
    nif_peer_recv/3, nif_peer_cancel/1
]).

-define(EXPECTED_ABI, 1).
-define(LOAD_ERROR_KEY, {erlang_polycall, load_error}).

init() ->
    Path = filename:join(priv_dir(), "erlang_polycall_nif"),
    Result =
        case erlang:load_nif(Path, 0) of
            ok ->
                case nif_abi_version() of
                    ?EXPECTED_ABI ->
                        ok;
                    Found ->
                        {error, {polycall_abi_mismatch,
                                 lists:flatten(io_lib:format(
                                     "libpolycall reports binding ABI ~p; "
                                     "erlang-polycall requires ABI ~p",
                                     [Found, ?EXPECTED_ABI]))}}
                end;
            {error, {Reason, Text}} ->
                %% e.g. libpolycall.so.1 missing, or an old 1.0 library
                %% without the ABI v1 symbols ("undefined symbol: ...")
                {error, {polycall_load_failed, Reason, Text}}
        end,
    case Result of
        ok -> persistent_term:erase(?LOAD_ERROR_KEY), ok;
        Error -> persistent_term:put(?LOAD_ERROR_KEY, Error), Error
    end.

priv_dir() ->
    case code:priv_dir(erlang_polycall) of
        {error, bad_name} ->
            Beam = code:which(?MODULE),
            filename:join(filename:dirname(filename:dirname(Beam)), "priv");
        Dir ->
            Dir
    end.

-define(NIF, erlang:nif_error({nif_not_loaded, ?MODULE})).

nif_abi_version() -> ?NIF.
nif_version() -> ?NIF.
nif_strerror(_Code) -> ?NIF.
nif_run_config(_Path, _Run) -> ?NIF.
nif_describe(_Path) -> ?NIF.
nif_call(_Endpoint, _Service, _Operation, _Input, _Timeout) -> ?NIF.
nif_peer_open(_NodeId, _Bind, _Token) -> ?NIF.
nif_peer_close(_Peer) -> ?NIF.
nif_peer_handle(_Peer) -> ?NIF.
nif_peer_endpoint(_Peer) -> ?NIF.
nif_peer_node_id(_Peer) -> ?NIF.
nif_peer_register(_Peer, _Id, _Endpoint) -> ?NIF.
nif_peer_unregister(_Peer, _Id) -> ?NIF.
nif_peer_list(_Peer) -> ?NIF.
nif_peer_health(_Peer) -> ?NIF.
nif_peer_ping(_Peer, _Target, _Timeout) -> ?NIF.
nif_peer_send(_Peer, _Target, _Payload, _MessageId, _Timeout) -> ?NIF.
nif_peer_recv(_Peer, _Timeout, _Capacity) -> ?NIF.
nif_peer_cancel(_Peer) -> ?NIF.
