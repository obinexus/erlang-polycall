#!/bin/sh
# npm source package erlang-polycall: pack it, install the
# tarball into a clean temporary project, check the entry point, then build
# the NIF from the INSTALLED package sources and run it against the real
# libpolycall (polycall installed: pkg-config polycall). Exit 77 = SKIP.
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
skip() { echo "SKIP: $*" >&2; exit 77; }
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v node >/dev/null 2>&1 || skip "node not found"
command -v npm >/dev/null 2>&1 || skip "npm not found"
command -v erl >/dev/null 2>&1 || skip "erl not found"
pkg-config --exists polycall 2>/dev/null || skip "libpolycall not installed (pkg-config polycall)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cd "$ROOT" || exit 1
node tests/package.test.js || fail "package index test"
TGZ=$(npm pack --silent --pack-destination "$TMP" | tail -1)
[ -f "$TMP/$TGZ" ] || fail "npm pack produced no tarball"
echo "packed $TGZ ($(wc -c <"$TMP/$TGZ") bytes, $(tar tzf "$TMP/$TGZ" | wc -l) files)"
if tar tzf "$TMP/$TGZ" | grep -E '\.(so|dll|beam|o|obj|tgz)$|/generated/|/_build/|/priv/|pyproject\.toml'; then
  fail "tarball ships build products, the stub header or the QA descriptor"
fi
for f in package/src/erlang_polycall.erl package/src/polycall_peer.erl package/c_src/erlang_polycall_nif.c \
         package/include/erlang_polycall.hrl package/Makefile package/rebar.config package/LICENSE; do
  tar tzf "$TMP/$TGZ" | grep -qx "$f" || fail "tarball misses $f"
done

mkdir "$TMP/app" && cd "$TMP/app" || exit 1
npm init -y >/dev/null || fail "npm init"
npm install --no-audit --no-fund --silent "$TMP/$TGZ" || fail "npm install of the tarball"
node -e '
const fs = require("fs");
const p = require("erlang-polycall");
for (const [k, v] of Object.entries(p)) if (!fs.existsSync(v)) throw new Error(k + " missing: " + v);
console.log("entry point OK:", Object.keys(p).join(","));' || fail "entry point"

# build the NIF + beams from the installed package and use the real core
PKG="$TMP/app/node_modules/erlang-polycall"
cp -a "$PKG" "$TMP/build" && cd "$TMP/build" || exit 1
make --no-print-directory nif beams >"$TMP/build.log" 2>&1 || { cat "$TMP/build.log"; fail "make nif beams"; }
erl -noshell -pa ebin -eval '
    1 = erlang_polycall:abi_version(),
    V = erlang_polycall:version(),
    ok = erlang_polycall:run_config("erlang-polycallrc", true),
    {ok, A} = polycall_peer:open("pkg-a"),
    {ok, B} = polycall_peer:open("pkg-b"),
    {ok, EpB} = polycall_peer:endpoint(B),
    ok = polycall_peer:send(A, EpB, <<0, "from the npm package", 255>>, #{message_id => "pkg-1"}),
    {ok, #{sender := <<"pkg-a">>, message_id := <<"pkg-1">>,
           payload := <<0, "from the npm package", 255>>}} = polycall_peer:recv(B, 5000),
    ok = polycall_peer:close(A), ok = polycall_peer:close(B),
    io:format("installed package: NIF built and used libpolycall ~s~n", [V]),
    halt(0).' || fail "NIF from the installed package"
echo "package: PASS"
