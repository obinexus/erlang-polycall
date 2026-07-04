$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$nativeSources = @(
    (Join-Path $root 'c_src/erlang_polycall.c'),
    (Join-Path $root 'c_src/erlang_polycall_nif.c')
)
$forbidden = 'fopen|open\(|CreateFile|sscanf|strtok|socket\(|connect\('
$matches = Select-String -Path $nativeSources -Pattern $forbidden

if ($matches) {
    $matches | ForEach-Object { Write-Error $_.Line }
    throw 'erlang-polycall must not parse configuration or implement runtime logic'
}

$adapter = Get-Content -Raw (Join-Path $root 'c_src/erlang_polycall.c')
$nif = Get-Content -Raw (Join-Path $root 'c_src/erlang_polycall_nif.c')
if (-not $adapter.Contains('polycall_ffi_run_config(config_path, 1)')) {
    throw 'erlang-polycall does not forward through polycall_ffi_run_config'
}
if (-not $nif.Contains('enif_inspect_iolist_as_binary')) {
    throw 'erlang-polycall does not marshal Erlang iodata'
}
if (-not $nif.Contains('ERL_NIF_DIRTY_JOB_IO_BOUND')) {
    throw 'erlang-polycall does not use a dirty I/O scheduler'
}

Write-Output 'erlang-polycall thin-adapter check: PASS'
