$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { throw 'RUNNER_TEMP is required for smoke diagnostics.' }
$directory = Join-Path $env:RUNNER_TEMP 'arkari-smoke/crash-diagnostics'
New-Item -ItemType Directory -Force $directory | Out-Null
# Official Clang driver setting, also honored by clang-cl. Keep preprocessed
# sources, reproducer scripts and related crash files under the uploaded tree.
$env:CLANG_CRASH_DIAGNOSTICS_DIR = $directory
