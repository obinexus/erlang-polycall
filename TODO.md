# TODO — erlang-polycall (Erlang)

Status: NIF over the Polycall binding ABI v1 (polycall >= 1.1.0), tested
against the real library on Linux (erlang:27), including ASan/UBSan and
valgrind (OTP valgrind emulator) runs.

- [x] Adapter onto `<polycall.h>` (stub `generated/polycall/polycall_ffi.h` removed)
- [x] Library/ABI check, `run_config/2`, `describe/1`, `call/5`, `polycall_peer`
- [x] Blocking calls on dirty I/O schedulers; `recv` sliced so waiting
      receivers never starve dirty I/O; peer handles as NIF resources closed
      exactly once
- [x] rebar3 project; EUnit suite against the real core; `polycall daemon`
      and `polycall peer serve` interop; memory-tool runs
- [ ] Windows build of the NIF (no Erlang/OTP for Windows in the QA environment)
- [ ] Publish `erlang-polycall` / a Hex package (not done by QA)

Do not add config parsing or runtime logic here — adapt the core only.
