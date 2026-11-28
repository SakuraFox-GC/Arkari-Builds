[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [ValidateSet('Release', 'Debug')][string]$BuildType = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
& "$PSScriptRoot/Initialize-SmokeDiagnostics.ps1"
$reportDir = Join-Path $env:RUNNER_TEMP 'arkari-smoke/bla'
$repoRoot = Split-Path $PSScriptRoot -Parent
$metadataPath = Join-Path $InstallDir 'build-info.json'
$metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json
if (-not $metadata.PSObject.Properties['bla_integration'] -or
    $metadata.bla_integration.upstream_commit -cne 'dd9e72f53ad97e3eb228523ad25295029107bb63') {
    throw 'This package predates the BLA integration; use a toolchain built from the integrated source commit.'
}
& python "$PSScriptRoot/test_bla.py" --install $InstallDir --fixtures "$repoRoot/tests/smoke" --output $reportDir --build-type $BuildType
if ($LASTEXITCODE -ne 0) { throw 'BLA regression tests failed; inspect bla/results.json and the per-command logs.' }

$report = Get-Content "$reportDir/results.json" -Raw | ConvertFrom-Json
$metadata | Add-Member -NotePropertyName bla_validation -NotePropertyValue ([ordered]@{
    status = $report.status
    test_config_commit = $env:GITHUB_SHA
    test_run_url = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    upstream_commit = $report.upstream_commit
    runtime_architectures = $report.runtime_architectures
    structural_architectures = $report.structural_architectures
    checks_passed = $report.checks_passed
}) -Force
$metadata | ConvertTo-Json -Depth 14 | Set-Content $metadataPath -Encoding utf8
