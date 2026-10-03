$ErrorActionPreference = 'Stop'

# Thin-adapter check: the C layer only marshals onto <polycall.h>.
$root = Split-Path -Parent $PSScriptRoot
$nativeSources = @(
    (Join-Path $root 'c_src/erlang_polycall.c'),
    (Join-Path $root 'c_src/erlang_polycall_nif.c')
)
$forbidden = '(^|[^_A-Za-z0-9])(fopen|open|socket|connect|sscanf|strtok)\('
$found = Select-String -Path $nativeSources -Pattern $forbidden

if ($found) {
    $found | ForEach-Object { Write-Error $_.Line }
    throw 'erlang-polycall must not parse configuration or implement runtime logic'
}

$adapter = Get-Content -Raw (Join-Path $root 'c_src/erlang_polycall.c')
$nif = Get-Content -Raw (Join-Path $root 'c_src/erlang_polycall_nif.c')
if (-not $adapter.Contains('polycall_ffi_run_config(config_path, 1)')) {
    throw 'erlang-polycall does not forward through polycall_ffi_run_config'
}
if (-not $nif.Contains('#include <polycall.h>')) {
    throw 'erlang-polycall NIF does not include <polycall.h>'
}
if (-not $nif.Contains('ERL_NIF_DIRTY_JOB_IO_BOUND')) {
    throw 'erlang-polycall does not use a dirty I/O scheduler'
}

Write-Output 'erlang-polycall thin-adapter check: PASS'
