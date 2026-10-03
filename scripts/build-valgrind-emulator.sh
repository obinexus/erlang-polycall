#!/bin/sh
# Build OTP's valgrind emulator (beam.valgrind.smp + erl_child_setup.valgrind)
# for the INSTALLED Erlang/OTP and copy it next to beam.smp, so that
# `sh scripts/test-memory.sh valgrind` can run the NIF under memcheck without
# the false positives of the normal emulator (conservative GC stack scans,
# alloc_util carriers). Needs a C/C++ toolchain, curl, perl, ncurses and
# OpenSSL headers, and valgrind itself: OTP's configure silently omits the
# valgrind emulator without <valgrind/memcheck.h> (Debian: apt-get install
# autoconf libncurses-dev libssl-dev curl perl valgrind). Downloads the
# official source of exactly the installed release.
set -eu
CC=${CC:-cc}
printf '#include <valgrind/memcheck.h>\nint main(void){return 0;}\n' | $CC -x c -o /dev/null - 2>/dev/null || {
  echo "valgrind headers (<valgrind/memcheck.h>) not found: install valgrind first" >&2; exit 1; }
V=$(erl -noshell -eval 'io:format("~s", [string:trim(element(2, file:read_file(filename:join([code:root_dir(), "releases", erlang:system_info(otp_release), "OTP_VERSION"]))))]), halt().')
ERTS=$(erl -noshell -eval 'io:format("~s", [filename:join(code:root_dir(), "erts-" ++ erlang:system_info(version))]), halt().')
WORK=${WORK:-${TMPDIR:-/tmp}/otp-valgrind-$V}
mkdir -p "$WORK" && cd "$WORK"
[ -f "otp_src_$V.tar.gz" ] || curl -fsSL -o "otp_src_$V.tar.gz" \
  "https://github.com/erlang/otp/releases/download/OTP-$V/otp_src_$V.tar.gz"
rm -rf "otp_src_$V" && tar xzf "otp_src_$V.tar.gz" && cd "otp_src_$V"
export ERL_TOP=$PWD MAKEFLAGS=${MAKEFLAGS:--j4}
./configure --without-javac --without-wx --without-odbc --without-jinterface \
  --without-debugger --without-observer --without-et >configure.log 2>&1
# the emulator's "valgrind" target builds beam.valgrind.smp and the matching
# erl_child_setup.valgrind (the valgrind emulator only talks to that one)
make -C erts/emulator valgrind >make-valgrind.log 2>&1
if grep -q "valgrind emulator disabled by configure" make-valgrind.log; then
  echo "configure disabled the valgrind emulator; see $PWD/configure.log" >&2; exit 1
fi
B=$(ls -d bin/*-*-*/ | head -1)
for f in beam.valgrind.smp erl_child_setup.valgrind; do
  [ -x "$B/$f" ] || { echo "missing $B/$f; see $PWD/make-valgrind.log" >&2; exit 1; }
  install -m 0755 "$B/$f" "$ERTS/bin/$f"
done
echo "installed beam.valgrind.smp and erl_child_setup.valgrind for OTP $V into $ERTS/bin"
