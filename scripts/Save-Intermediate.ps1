[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Objects', 'Binaries')][string]$Kind)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$outputDir = Join-Path $env:RUNNER_TEMP 'arkari-intermediate'
New-Item -ItemType Directory -Force $outputDir | Out-Null
$name = "arkari-lto-$($Kind.ToLowerInvariant())-$env:GITHUB_RUN_ID-$env:GITHUB_RUN_ATTEMPT"
$archive = Join-Path $outputDir "$name.7z"
if ($Kind -eq 'Objects') {
    $directory = "$env:ARKARI_BUILD_ROOT/build"
    if (-not (Test-Path "$directory/arkari-checkpoint.json")) { throw 'Missing compilation checkpoint.' }
    $inputs = @("$directory/*")
} else {
    $directory = "$env:ARKARI_BUILD_ROOT/install"
    if (-not (Test-Path "$directory/build-info.json")) { throw 'Missing linked toolchain metadata.' }
    # Only the LTO bin directory will replace files in the native distribution.
    $inputs = @("$directory/bin", "$directory/build-info.json")
}
& 7z a -t7z -mx=1 -mmt=2 $archive @inputs
if ($LASTEXITCODE -ne 0) { throw "Saving $Kind failed." }
& 7z t $archive
if ($LASTEXITCODE -ne 0) { throw "Verifying $Kind failed." }
"artifact_name=$name" >> $env:GITHUB_OUTPUT
"artifact_path=$archive" >> $env:GITHUB_OUTPUT
