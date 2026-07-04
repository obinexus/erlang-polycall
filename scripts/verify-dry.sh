#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if grep -E -n 'fopen|open\(|CreateFile|sscanf|strtok|socket\(|connect\(' \
    "$root/c_src/erlang_polycall.c" "$root/c_src/erlang_polycall_nif.c"; then
    echo "erlang-polycall must not parse configuration or implement runtime logic" >&2
    exit 1
fi

grep -F -q 'polycall_ffi_run_config(config_path, 1)' \
    "$root/c_src/erlang_polycall.c"
grep -F -q 'enif_inspect_iolist_as_binary' \
    "$root/c_src/erlang_polycall_nif.c"
grep -F -q 'ERL_NIF_DIRTY_JOB_IO_BOUND' \
    "$root/c_src/erlang_polycall_nif.c"

echo "erlang-polycall thin-adapter check: PASS"
