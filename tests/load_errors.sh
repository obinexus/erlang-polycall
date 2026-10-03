#!/bin/sh
# The NIF must fail cleanly -- a clear Erlang error, never a VM crash -- when
# libpolycall is missing, is an old 1.0 library without the ABI v1 symbols,
# or reports a binding ABI other than 1. Uses tests/fixtures/fake_polycall.c
# (fake libraries, test-only). Run after `rebar3 compile` (or `make test`).
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT" || exit 1
CC=${CC:-cc}
EBIN=_build/default/lib/erlang_polycall/ebin
[ -d "$EBIN" ] || EBIN=_build/test/lib/erlang_polycall/ebin
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS  $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

if ! command -v erl >/dev/null 2>&1; then echo "SKIP  load errors: erl not found"; exit 77; fi
if [ ! -d "$EBIN" ]; then echo "SKIP  load errors: $EBIN missing (run rebar3 compile)"; exit 77; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/empty" "$TMP/v10" "$TMP/abi2"
$CC -shared -fPIC -Wl,-soname,libpolycall.so.1 -DFAKE_V10 tests/fixtures/fake_polycall.c -o "$TMP/v10/libpolycall.so.1" || exit 1
$CC -shared -fPIC -Wl,-soname,libpolycall.so.1 -DFAKE_ABI=2 tests/fixtures/fake_polycall.c -o "$TMP/abi2/libpolycall.so.1" || exit 1

probe() { # probe LD_LIBRARY_PATH -> prints the caught error, exit status of erl
  LD_LIBRARY_PATH=$1 erl -noshell -pa "$EBIN" -eval '
    R = (catch erlang_polycall:version()),
    io:format("RESULT ~s~n", [re:replace(io_lib:format("~p", [R]), "\\s+", " ", [global, {return, list}])]),
    halt(0).' 2>&1
}

OUT=$(probe "$TMP/empty"); RC=$?
echo "$OUT" | grep RESULT | cut -c1-600
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "polycall_unavailable" && echo "$OUT" | grep -q "libpolycall.so.1"; then
  ok "missing libpolycall.so.1 -> error polycall_unavailable naming the library"
else bad "missing library (rc=$RC): $OUT"; fi

OUT=$(probe "$TMP/v10"); RC=$?
echo "$OUT" | grep RESULT | cut -c1-600
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "polycall_unavailable" && echo "$OUT" | grep -q "undefined symbol: polycall_"; then
  ok "old 1.0 library (no ABI v1 symbols) -> error polycall_unavailable naming the missing symbol"
else bad "1.0 library (rc=$RC): $OUT"; fi

OUT=$(probe "$TMP/abi2"); RC=$?
echo "$OUT" | grep RESULT | cut -c1-600
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "polycall_abi_mismatch" && echo "$OUT" | grep -q "ABI 2"; then
  ok "library reporting ABI 2 -> error polycall_abi_mismatch (refused)"
else bad "ABI mismatch (rc=$RC): $OUT"; fi

echo "--- load errors: $PASS passed, $FAIL failed ---"
[ $FAIL -eq 0 ]
