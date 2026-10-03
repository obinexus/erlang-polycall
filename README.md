# erlang-polycall

Erlang NIF binding for the [Polycall](https://github.com/obinexus/polycall)
C library, **binding ABI v1** (`polycall >= 1.1.0`, `#include <polycall.h>`).
Source package on npm: `erlang-polycall` (not yet published).

The NIF is a thin marshalling layer over the ABI described in the core's
`docs/BINDING_ABI.md`: no configuration parsing, no networking of its own.

* Every call that can block (`run_config`, `describe`, `call`, peer
  `open`/`close`/`ping`/`send`/`recv`) runs on a **dirty I/O scheduler**, never
  on a normal scheduler. `call`, `send` and `ping` hold one for at most their
  timeout.
* `recv` waits in slices of at most 200 ms and yields the dirty scheduler in
  between, so any number of processes waiting with `infinity` cannot starve
  file I/O or code loading (which share the dirty I/O schedulers), and a
  killed receiver releases its scheduler within one slice. `cancel/1` wakes
  every `recv` called before it, also one still queued for a scheduler;
  `close/1` wakes them all with `closed`. No payload buffer is allocated
  while waiting.
* A peer node is a **NIF resource**. Its core handle is closed exactly once:
  by `close/1`, or when the last reference is garbage collected (on a
  private closer thread). Double close and use after close are defined and
  return `{error, #polycall_error{reason = invalid_handle}}` without passing
  the old handle number to the core again.
* Text arguments (paths, endpoints, ids, tokens, JSON) are Unicode chardata —
  a string such as `"conf/café-rc"` or a UTF-8 binary — and reach the core as
  UTF-8, as the ABI requires; a binary is passed through unchanged. Payloads
  are raw iodata, sent byte for byte (empty, NUL bytes, up to 1 MiB).
* Errors are `#polycall_error{code, reason, name, detail, info}`
  (`include/erlang_polycall.hrl`): the status code, its atom, the
  `polycall_strerror` name and the `polycall_last_error` detail captured in
  the same NIF call.
* The NIF refuses to load a library whose `polycall_ffi_abi_version()` is not
  1; a missing `libpolycall.so.1` or an old 1.0 library (missing symbols) is
  reported as `error({polycall_unavailable, Why})`, never a VM crash.

## Requirements

* Erlang/OTP 21.2+ (dirty NIFs, `persistent_term`); the test suite needs
  OTP 27+ (`json`). Tested with OTP 27.3.4.18 (`erlang:27`).
* rebar3, a C11 compiler, `pkg-config`.
* Polycall core `>= 1.1.0` installed so that `pkg-config --cflags --libs
  polycall` works (and `libpolycall.so.1` is on the loader path at run time).

## Build

```sh
rebar3 compile          # runs `make nif` (pkg-config polycall) then compiles
# or, without rebar3:
make nif beams
```

## API

```erlang
-include_lib("erlang_polycall/include/erlang_polycall.hrl").

1 = erlang_polycall:abi_version(),
<<"1.1.0">> = erlang_polycall:version(),

%% configuration: polycall_ffi_run_config(Path, Strict)
ok = erlang_polycall:run_config("erlang-polycallrc", true),
{error, #polycall_error{reason = unsupported}} =
    erlang_polycall:run_config("tls-polycallrc", true),

%% one RPC round trip to `polycall start` / `polycall daemon start`
{ok, Json} = erlang_polycall:call("127.0.0.1:7000", "inventory", "get",
                                  <<"{\"item_id\":\"widget-a\"}">>, 5000),

%% peers
{ok, A} = polycall_peer:open("alpha", #{token => Token}),       % 127.0.0.1:0
{ok, B} = polycall_peer:open("beta", #{token => Token}),
{ok, EpB} = polycall_peer:endpoint(B),
ok = polycall_peer:register(A, "beta", EpB),
ok = polycall_peer:send(A, "beta", <<"hello">>, #{message_id => "m1"}),
{ok, #{sender := <<"alpha">>, message_id := <<"m1">>, payload := <<"hello">>}} =
    polycall_peer:recv(B, 5000),
ok = polycall_peer:close(A), ok = polycall_peer:close(B).
```

`polycall_peer` also provides `node_id/1`, `unregister/2`, `list/1` (JSON),
`ping/2,3`, `recv/1,3` (`recv/3` takes a payload buffer size: a larger message
gives `reason = too_large` with `info = NeededBytes` and stays queued),
`cancel/1` (wakes blocked receivers with `cancelled`) and `health/1` (JSON).
Timeouts are milliseconds `0..4294967295` or `infinity` (4294967295 is the
ABI's "wait indefinitely" for `recv`); anything else is `badarg`. `call/5`
takes 1..600000 ms (the core answers `invalid_argument` otherwise).

The legacy status API is unchanged: `erlang_polycall:run_config/0,1` returns
`{ok, 0} | {error, Status}` (strict, `polycall_ffi_run_config(Path, 1)`) and
`run_config_or_error/0,1` raises `error({polycall_error, Status})`.

## Tests

```sh
sh scripts/test-linux.sh            # inside erlang:27 with polycall installed
sh scripts/test-memory.sh asan      # NIF with ASan + UBSan, LeakSanitizer on
sh scripts/test-memory.sh valgrind  # memcheck in OTP's valgrind emulator
sh scripts/test-package.sh          # npm pack -> clean install -> build + run
```

`test-linux.sh` runs the C adapter unit test (mock core, labelled as such),
the EUnit suite `test/erlang_polycall_tests.erl` against the **real** library
— the `docs/BINDING_ABI.md` checklist, non-ASCII config paths, `polycall_call`
against `polycall start` and `polycall daemon`, concurrency (one node shared
by many processes, concurrent calls, more blocked receivers than dirty
schedulers) and interop with a `polycall peer serve` C node in both
directions — then `tests/load_errors.sh` (missing library, 1.0 library,
ABI 2) and the example. A missing toolchain is reported as SKIP (exit 77),
never as success.

`test-memory.sh` drives every NIF entry point (`test/polycall_memcheck.erl`)
under the tool. The ASan run also runs the whole EUnit suite; its only
suppressions (`tests/lsan-beam.supp`) are allocations the Erlang runtime keeps
until exit. The valgrind run needs `beam.valgrind.smp`
(`sh scripts/build-valgrind-emulator.sh` builds it for the installed OTP) and
uses no suppressions: the normal emulator is not usable under memcheck.

Windows: the Makefile builds the NIF as a `.dll` (GNU make with a POSIX
shell, e.g. MSYS2). It has not been built or tested on Windows: no Erlang/OTP
for Windows was available in the QA environment.

## npm source package

`require('erlang-polycall')` returns absolute paths to the
Erlang/C sources for build tooling; it contains no JavaScript implementation.

## License

MIT — see [LICENSE](LICENSE). Author: Nnamdi Michael Okpala
<okpalan@protonmail.com>.
