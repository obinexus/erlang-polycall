# TODO — erlang-polycall (Erlang)

Status: implemented thin adapter for libpolycall 1.5.0.

- [x] Folder structure, manifest, and `erlang-polycallrc` (shared schema)
- [x] Generate the consumed declaration from `polycall_ffi.h`
- [x] Implement the Erlang module, NIF, and native adapter
- [x] Add a runnable example under `examples/`
- [x] Add native, NIF, and npm smoke tests under `tests/`
- [x] Add `scripts/verify-dry.sh` (no core duplication)

Do not add config parsing or runtime logic here — adapt the core only.
