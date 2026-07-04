# Erlang adapter

The adapter calls across the FFI boundary only:

    status = polycall_ffi_run_config("erlang-polycallrc", /*run=*/1)

`erlang_polycall.erl` exposes `{ok, 0}` / `{error, Status}` results and an
exception helper. `erlang_polycall_nif.c` marshals Erlang iodata to a temporary
NUL-terminated path and calls the native adapter on a dirty I/O scheduler.
`erlang_polycall.c` forwards to `polycall_ffi_run_config(path, 1)`.

No layer parses configuration or duplicates core runtime logic.
