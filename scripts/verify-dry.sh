#!/usr/bin/env sh
# Thin-adapter check: the C layer only marshals onto <polycall.h>; it never
# parses configuration or opens files/sockets itself.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if grep -E -n '(^|[^_A-Za-z0-9])(fopen|open|socket|connect|sscanf|strtok)\(' \
    "$root/c_src/erlang_polycall.c" "$root/c_src/erlang_polycall_nif.c"; then
    echo "erlang-polycall must not parse configuration or implement runtime logic" >&2
    exit 1
fi

grep -F -q '#include <polycall.h>' "$root/c_src/erlang_polycall_nif.c"
grep -F -q 'polycall_ffi_run_config(config_path, 1)' "$root/c_src/erlang_polycall.c"
grep -F -q 'ERL_NIF_DIRTY_JOB_IO_BOUND' "$root/c_src/erlang_polycall_nif.c"
if grep -R -n 'polycall_ffi\.h' "$root/c_src" "$root/include"; then
    echo "stale reference to the stub polycall_ffi.h" >&2
    exit 1
fi

echo "erlang-polycall thin-adapter check: PASS"
