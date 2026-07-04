# erlang-polycall

Erlang NIF binding for libpolycall 1.5.0, published as
`@obinexusltd/erlang-polycall`.

The binding has three deliberately small layers:

1. `erlang_polycall.erl` provides Erlang result tuples and exceptions.
2. `erlang_polycall_nif.c` marshals an iolist/binary configuration path.
3. `erlang_polycall.c` calls `polycall_ffi_run_config(path, 1)`.

No layer parses configuration or duplicates libpolycall runtime logic. The NIF
call runs as dirty I/O work so a potentially blocking core call does not occupy
a normal BEAM scheduler.

## Erlang API

Status-oriented usage:

```erlang
case erlang_polycall:run_config(<<"erlang-polycallrc">>) of
    {ok, 0} -> ok;
    {error, Status} -> {stop, Status}
end.
```

Exception-oriented usage:

```erlang
try erlang_polycall:run_config_or_error("erlang-polycallrc") of
    ok -> continue
catch
    error:{polycall_error, Status} -> {stop, Status}
end.
```

`run_config/0` and `run_config_or_error/0` use `erlang-polycallrc`. Paths can be
binaries or byte-oriented iodata; convert Unicode character data with
`unicode:characters_to_binary/1` before calling.

## Install from npm

```sh
npm install @obinexusltd/erlang-polycall
```

This is a native source package. Its CommonJS entry point exposes absolute
paths for Erlang and C build tooling:

```js
const polycall = require('@obinexusltd/erlang-polycall');

console.log(polycall.erlangModule);
console.log(polycall.applicationSource);
console.log(polycall.nativeAdapter);
console.log(polycall.nifSource);
console.log(polycall.publicHeader);
console.log(polycall.ffiHeader);
```

The npm tarball includes Erlang/C sources, headers, examples, tests, scripts,
Makefile, manifest, and runtime configuration. Platform-specific BEAM and NIF
binaries are excluded.

## Build and test

The native forwarding layer can be built and tested without Erlang/OTP:

```sh
npm run build
npm test
npm run verify
```

With Erlang/OTP installed, build and run the mock NIF smoke test:

```sh
npm run test:erlang
```

That test covers binary and list paths, `{ok, 0}`, `{error, Status}`, and the
`{polycall_error, Status}` exception contract.

## Build the production NIF

Point the linker at a libpolycall v1.5 library exporting
`polycall_ffi_run_config`:

```sh
make nif POLYCALL_LDFLAGS="-L/path/to/libpolycall/lib -lpolycall"
```

The build detects the ERTS include directory through `erl`. It produces the
BEAM application under `ebin/` and the native library under `priv/`. If
automatic detection is unavailable, pass `ERL_INCLUDE=/path/to/erts/include`.

Example invocation:

```sh
erl -noshell -pa ebin \
  -eval 'io:format("~p~n", [erlang_polycall:run_config()]), halt().'
```

The NIF follows the official
[Erlang NIF API](https://www.erlang.org/doc/apps/erts/erl_nif.html) and resolves
its native library through the application's `priv` directory.

## Publishing

```sh
npm pack --dry-run
npm publish --access public
```

Publishing is not performed automatically.

## Author

Nnamdi Michael Okpala — <okpalan@protonmail.com>
