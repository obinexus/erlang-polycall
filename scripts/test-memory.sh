#!/bin/sh
# Memory tooling for the erlang-polycall NIF against the REAL libpolycall.
#
#   sh scripts/test-memory.sh asan       NIF built with ASan + UBSan, run in an
#                                        uninstrumented BEAM with the ASan
#                                        runtime preloaded: the memory-tool
#                                        workload (test/polycall_memcheck.erl)
#                                        AND the full EUnit suite. LeakSanitizer
#                                        is on, with tests/lsan-beam.supp
#                                        (BEAM-internal allocations only).
#   sh scripts/test-memory.sh valgrind   the workload under valgrind memcheck in
#                                        OTP's valgrind emulator
#                                        (beam.valgrind.smp, see
#                                        scripts/build-valgrind-emulator.sh);
#                                        no suppressions.
#
# POLYCALL_CORE_LIBDIR=<dir> runs against another build of the core (e.g. one
# compiled with -fsanitize=address,undefined). Run from the repository root
# with polycall installed (pkg-config polycall, polycall on PATH). Exit 0 =
# clean, 1 = failure, 77 = SKIP (a tool is missing; never a pass).
set -u
MODE=${1:-}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1

skip() { echo "SKIP: $*" >&2; exit 77; }
command -v erl >/dev/null 2>&1 || skip "erl not found"
command -v rebar3 >/dev/null 2>&1 || skip "rebar3 not found"
command -v polycall >/dev/null 2>&1 || skip "polycall CLI not on PATH"
pkg-config --exists polycall 2>/dev/null || skip "libpolycall not installed (pkg-config polycall)"

ERL_ROOT=$(erl -noshell -eval 'io:format("~s", [code:root_dir()]), halt().')
ERTS=$(erl -noshell -eval 'io:format("~s", [filename:join(code:root_dir(), "erts-" ++ erlang:system_info(version))]), halt().')
EBIN=_build/test/lib/erlang_polycall/ebin
TEBIN=_build/test/lib/erlang_polycall/test
: "${POLYCALL_DEV_TOKEN:=memcheck-$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')}"
export POLYCALL_DEV_TOKEN POLYCALL_TELEMETRY=off
[ -n "${POLYCALL_CORE_LIBDIR:-}" ] && export LD_LIBRARY_PATH="$POLYCALL_CORE_LIBDIR${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

TMP=$(mktemp -d)
PIDS=""
cleanup() { for p in $PIDS; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

# CLI helpers for the workload: a runtime and a C peer node (no preload)
start_cli() {
  polycall start --endpoint 127.0.0.1:0 --endpoint-file "$TMP/rpc.ep" >"$TMP/rpc.log" 2>&1 &
  PIDS="$PIDS $!"
  polycall peer serve --node-id cli-node --endpoint 127.0.0.1:0 \
      --endpoint-file "$TMP/node.ep" >"$TMP/node.log" 2>&1 &
  PIDS="$PIDS $!"
  i=0
  while [ $i -lt 100 ] && ! { [ -s "$TMP/rpc.ep" ] && [ -s "$TMP/node.ep" ]; }; do
    sleep 0.1; i=$((i+1))
  done
  [ -s "$TMP/rpc.ep" ] && [ -s "$TMP/node.ep" ] || { echo "polycall CLI helpers did not start" >&2; exit 1; }
  POLYCALL_RPC=$(cat "$TMP/rpc.ep"); POLYCALL_CLI_NODE=$(cat "$TMP/node.ep")
  POLYCALL_CLI=$(command -v polycall)
  export POLYCALL_RPC POLYCALL_CLI_NODE POLYCALL_CLI
}

# beam started the way erlexec starts it (BINDIR/ROOTDIR/EMU/PROGNAME)
export BINDIR="$ERTS/bin" ROOTDIR="$ERL_ROOT" EMU=beam PROGNAME=erl

case "$MODE" in
asan)
  ASAN_LIB=$(cc -print-file-name=libasan.so)
  UBSAN_LIB=$(cc -print-file-name=libubsan.so)
  [ -f "$ASAN_LIB" ] && [ -f "$UBSAN_LIB" ] || skip "libasan/libubsan not found for $(cc --version | head -1)"
  rebar3 as test compile >/dev/null || exit 1
  rm -f priv/erlang_polycall_nif.so
  make --no-print-directory nif \
    CFLAGS="-O1 -g -fno-omit-frame-pointer -fsanitize=address,undefined -fno-sanitize-recover=undefined -std=c11 -Wall -Wextra -Wpedantic" \
    NIF_LDFLAGS="-shared -fsanitize=address,undefined" || exit 1
  # GCC 12's libasan cannot map its shadow under 32-bit mmap randomization
  # (vm.mmap_rnd_bits=32, e.g. WSL2 kernel 6.x): every process it is preloaded
  # into, even /bin/sh, loops on "AddressSanitizer:DEADLYSIGNAL". Turning ASLR
  # off for the test process (setarch -R) avoids it without a sysctl change.
  NORAND=""
  if setarch -R true 2>/dev/null; then NORAND="setarch -R"; fi
  ASAN_ENV="LD_PRELOAD=$ASAN_LIB $UBSAN_LIB"
  export ASAN_OPTIONS="detect_leaks=1:halt_on_error=1:exitcode=23"
  export LSAN_OPTIONS="suppressions=$ROOT/tests/lsan-beam.supp:print_suppressions=1"
  export UBSAN_OPTIONS="print_stacktrace=1:halt_on_error=1"
  start_cli
  echo "=== asan: workload (NIF -fsanitize=address,undefined; +Mea min: BEAM allocators on malloc) ==="
  # shellcheck disable=SC2086
  $NORAND env "$ASAN_ENV" "$ERTS/bin/erlexec" +Mea min -noshell -pa "$EBIN" -pa "$TEBIN" \
      -eval 'polycall_memcheck:main()'
  RC1=$?
  echo "workload exit=$RC1"
  echo "=== asan: full EUnit suite ==="
  # shellcheck disable=SC2086
  $NORAND env "$ASAN_ENV" "$ERTS/bin/erlexec" +Mea min -noshell -pa "$EBIN" -pa "$TEBIN" \
      -eval 'R = eunit:test(erlang_polycall_tests, [verbose]), halt(case R of ok -> 0; _ -> 1 end).'
  RC2=$?
  echo "eunit exit=$RC2"
  rm -f priv/erlang_polycall_nif.so       # never leave the ASan NIF behind
  [ $RC1 -eq 0 ] && [ $RC2 -eq 0 ] && { echo "asan: PASS"; exit 0; }
  echo "asan: FAIL"; exit 1
  ;;
valgrind)
  command -v valgrind >/dev/null 2>&1 || skip "valgrind not found"
  [ -x "$ERTS/bin/beam.valgrind.smp" ] && [ -x "$ERTS/bin/erl_child_setup.valgrind" ] || \
    skip "OTP valgrind emulator not installed in $ERTS/bin (sh scripts/build-valgrind-emulator.sh)"
  rebar3 as test compile >/dev/null || exit 1
  start_cli
  echo "=== valgrind: workload in beam.valgrind.smp (no suppressions) ==="
  valgrind --tool=memcheck --error-exitcode=99 --leak-check=full \
      --show-leak-kinds=definite,indirect --errors-for-leak-kinds=definite,indirect \
      --num-callers=40 --track-origins=yes \
      "$ERTS/bin/beam.valgrind.smp" -JMsingle true -Mea min -- -root "$ERL_ROOT" \
      -bindir "$ERTS/bin" -progname erl -- -home "${HOME:-/root}" -- \
      -noshell -pa "$EBIN" -pa "$TEBIN" -eval 'polycall_memcheck:main()'
  RC=$?
  echo "valgrind exit=$RC"
  [ $RC -eq 0 ] && { echo "valgrind: PASS"; exit 0; }
  echo "valgrind: FAIL"; exit 1
  ;;
*)
  echo "usage: sh scripts/test-memory.sh asan|valgrind" >&2; exit 2
  ;;
esac
