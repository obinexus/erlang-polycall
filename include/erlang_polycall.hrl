%% Error term of the Polycall Erlang binding.
%%
%%   code   -- the POLYCALL_E_* status (negative integer, see <polycall.h>)
%%   reason -- that status as an atom (timeout, transport, invalid_handle, ...)
%%   name   -- polycall_strerror(code), e.g. <<"POLYCALL_E_TIMEOUT: deadline exceeded">>
%%   detail -- polycall_last_error() of the failing call (thread-local in the
%%             core; captured inside the same NIF call)
%%   info   -- extra data: the remote error object JSON for call/5, the needed
%%             payload size for recv/3 with a too-small buffer, else undefined
-record(polycall_error, {
    code :: integer(),
    reason :: atom(),
    name :: binary(),
    detail :: binary(),
    info = undefined :: term()
}).

-define(POLYCALL_FFI_ABI_VERSION, 1).
-define(POLYCALL_PEER_MAX_PAYLOAD, 1048576).
-define(POLYCALL_CALL_MAX_OUTPUT, 1048576).
