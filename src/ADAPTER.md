# Erlang adapter

Three thin layers over the Polycall binding ABI v1 (`<polycall.h>`):

1. `erlang_polycall.erl` / `polycall_peer.erl` — Erlang API, result tuples and
   `#polycall_error{}` (code, reason atom, `polycall_strerror` name,
   `polycall_last_error` detail). Text arguments are encoded as UTF-8
   (`erlang_polycall:text/1`); payloads stay raw iodata.
2. `erlang_polycall_nif.c` — marshals binaries to C strings and
   `(pointer, length)` payloads, runs blocking calls on dirty I/O schedulers
   (`recv` in 200 ms slices that yield in between), wraps peer handles in NIF
   resources with an open/closing/closed state so each core handle is closed
   exactly once (destructor closes on a private thread).
3. `erlang_polycall.c` — the documented entry point
   `run_config(path)` → `polycall_ffi_run_config(path, 1)`.

No layer parses configuration or duplicates core runtime logic.
