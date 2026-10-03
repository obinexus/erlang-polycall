# Erlang tests

* `test/erlang_polycall_tests.erl` — EUnit suite against the REAL installed
  libpolycall (no mocks): version/ABI; `run_config` (valid, missing, invalid,
  strict, TLS unsupported, non-ASCII paths as strings and UTF-8 binaries);
  `describe`; `call` against `polycall start` and against `polycall daemon`
  (private state dir, ephemeral port): success, unknown operation, remote
  error, deadline, invalid input, no runtime, output/request size limits,
  32 concurrent callers; peers: both directions with exact bytes, sender and
  message id, payloads empty / UTF-8 / NUL / exactly 1 MiB / 1 MiB + 1,
  receive buffers 0, 1 MiB - 1 and exactly 1 MiB, timeout boundaries
  (0..4294967295 | infinity, badarg outside), registry ownership, duplicate
  ids, auth, dead peer, receive timeout, cancel and close waking blocked
  receivers, double close / use after close, GC'd resource closing its node,
  concurrent senders (own nodes, and 8 processes sharing one handle with 4
  receivers), dirty-scheduler fairness (more receivers waiting with
  `infinity` than dirty I/O schedulers: file I/O keeps working, killed
  receivers free their scheduler, cancel/close wake all of them); interop
  with a `polycall peer serve` C node both ways (incl. 1 MiB, by registered
  id, the CLI's `peer register` into an Erlang node).
  Run: `rebar3 eunit` (needs `polycall` on PATH or `POLYCALL_CLI`).
* `test/polycall_memcheck.erl` — workload for the memory tools
  (`scripts/test-memory.sh asan|valgrind`): every NIF entry point and error
  path, functional checks only (no timing limits).
* `tests/load_errors.sh` — missing library, old 1.0 library, ABI 2 library
  (fake libraries from `tests/fixtures/fake_polycall.c`) must give a clear
  Erlang error, never a crash.
* `tests/lsan-beam.supp` — LeakSanitizer suppressions for allocations the
  Erlang runtime keeps until exit (no NIF or core frames, ever).
* `tests/erlang_polycall_adapter_test.c` — ADAPTER UNIT TEST against a MOCK
  `polycall_ffi_run_config` (`tests/polycall_ffi_mock.c`): checks only that
  the C entry point forwards `(path, 1)` and the status unchanged.
* `tests/package.test.js` — npm source-package index;
  `scripts/test-package.sh` packs, installs the tarball into a clean project
  and builds + runs the NIF from the installed sources.
