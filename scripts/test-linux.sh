#!/bin/sh
# Full Linux test of erlang-polycall against the REAL installed libpolycall.
# Run from the repository root inside the erlang:27 image. If polycall is not
# installed and the QA core script is mounted at /qa, it is built first.
set -eu
if [ -d /opt/polycall/lib ]; then
  export PATH="/opt/polycall/bin:$PATH"
  export LD_LIBRARY_PATH="/opt/polycall/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  export PKG_CONFIG_PATH="/opt/polycall/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
fi
if ! pkg-config --exists polycall 2>/dev/null; then
  if [ -f /qa/build-linux-core.sh ]; then
    sh /qa/build-linux-core.sh
    export PATH="/opt/polycall/bin:$PATH" LD_LIBRARY_PATH=/opt/polycall/lib PKG_CONFIG_PATH=/opt/polycall/lib/pkgconfig
  else
    echo "SKIP: libpolycall (pkg-config polycall) is not installed" >&2; exit 77
  fi
fi
: "${POLYCALL_DEV_TOKEN:=erl-$(od -An -N8 -tx8 /dev/urandom | tr -d ' ')}"
export POLYCALL_DEV_TOKEN POLYCALL_TELEMETRY=off
make test
sh tests/load_errors.sh
# the example compiles against the application and runs
mkdir -p build/examples
ERL_LIBS=_build/test/lib erlc -o build/examples examples/basic.erl
erl -noshell -pa _build/test/lib/erlang_polycall/ebin -pa build/examples -eval 'basic:main(), halt().'
echo "example basic.erl: PASS"
