[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ARKARI_BUILD_ROOT/install",
    [ValidateSet('Normal', 'ThinLTO')]
    [string]$Variant = 'Normal',
    [switch]$IncludeBootstrap,
    [switch]$ReuseLicenses,
    [switch]$Unverified
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = Split-Path $PSScriptRoot -Parent
$installDir = $InstallDir
$metadata = Get-Content (Join-Path $installDir 'build-info.json') -Raw | ConvertFrom-Json
if ($Unverified) {
    if ($Variant -cne 'Normal' -or -not $IncludeBootstrap -or $metadata.thin_lto) {
        throw 'Unverified checkpoints require a native SDK and its bootstrap dependencies.'
    }
    $metadata | Add-Member -NotePropertyName validation_state -NotePropertyValue 'unverified' -Force
    $validation = [ordered]@{
        status = 'failed'
        checks_passed = 0
        upstream_commit = $metadata.bla_integration.upstream_commit
        test_config_commit = $env:GITHUB_SHA
        test_run_url = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    }
    $message = 'The native smoke step failed before full validation completed.'
    $reportPath = Join-Path $env:RUNNER_TEMP 'arkari-smoke/bla/results.json'
    if (Test-Path $reportPath) {
        $report = Get-Content $reportPath -Raw | ConvertFrom-Json
        if ($report.PSObject.Properties['checks_passed']) { $validation.checks_passed = $report.checks_passed }
        if ($report.PSObject.Properties['error']) { $message = $report.error }
    }
    $metadata | Add-Member -NotePropertyName bla_validation -NotePropertyValue $validation -Force
    $metadata | Add-Member -NotePropertyName validation_failure -NotePropertyValue ([ordered]@{
        stage = 'native-smoke'
        message = $message
        run_url = $validation.test_run_url
    }) -Force
    $metadata | ConvertTo-Json -Depth 14 | Set-Content (Join-Path $installDir 'build-info.json') -Encoding utf8
} elseif (-not $metadata.PSObject.Properties['validation_state'] -or $metadata.validation_state -cne 'verified' -or
    -not $metadata.PSObject.Properties['bla_validation'] -or $metadata.bla_validation.status -cne 'passed') {
    throw 'Normal toolchain artifacts require a completed full validation; use -Unverified only for a diagnostic checkpoint.'
}
$variantSuffix = if ($Variant -eq 'ThinLTO') { '-ThinLTO' } else { '' }
$name = "Arkari-Windows-x64$variantSuffix-$($metadata.build_type)-$($metadata.arkari_commit.Substring(0, 12))-$env:GITHUB_RUN_NUMBER-$env:GITHUB_RUN_ATTEMPT"
if ($Unverified) { $name = "unverified-$name" }
$distDir = Join-Path $repoRoot 'dist'
$licensesDir = Join-Path $installDir 'licenses'
New-Item -ItemType Directory -Force $distDir, $licensesDir | Out-Null

if ($ReuseLicenses) {
    foreach ($license in @('Arkari-LLVM-LICENSE.txt', 'BLA-MIT-LICENSE.txt', 'rpmalloc-LICENSE.txt', 'zlib-copyright.txt', 'liblzma-copyright.txt', 'libxml2-copyright.txt')) {
        if (-not (Test-Path (Join-Path $licensesDir $license))) { throw "Missing native license: $license" }
    }
} else {
    Copy-Item (Join-Path $repoRoot 'sources/arkari/LICENSE.TXT') (Join-Path $licensesDir 'Arkari-LLVM-LICENSE.txt')
    Copy-Item (Join-Path $repoRoot 'sources/arkari/llvm/lib/Transforms/Obfuscation/Bla/LICENSE.BLA') (Join-Path $licensesDir 'BLA-MIT-LICENSE.txt')
    Copy-Item (Join-Path $repoRoot 'sources/rpmalloc/LICENSE') (Join-Path $licensesDir 'rpmalloc-LICENSE.txt')
    Get-ChildItem "$env:ARKARI_VCPKG_INSTALLED/x64-windows-static/share/*/copyright" | ForEach-Object {
        Copy-Item $_.FullName (Join-Path $licensesDir "$($_.Directory.Name)-copyright.txt")
    }
}

$archive = Join-Path $distDir "$name.7z"
& 7z a -t7z -mx=5 -mmt=2 $archive "$installDir/*"
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed.' }
& 7z t $archive
if ($LASTEXITCODE -ne 0) { throw 'Archive verification failed.' }
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host "Archive: $name.7z"
Write-Host "SHA256: $hash"
Write-Host "Verification state: $($metadata.validation_state)"
"$hash  $name.7z" | Set-Content (Join-Path $distDir "$name.7z.sha256") -Encoding ascii
Copy-Item (Join-Path $installDir 'build-info.json') (Join-Path $distDir "$name.build-info.json")
if ($IncludeBootstrap) {
    $bootstrapDir = Join-Path $distDir 'bootstrap'
    New-Item -ItemType Directory -Force $bootstrapDir | Out-Null
    & 7z a -t7z -mx=1 -mmt=2 "$bootstrapDir/vcpkg-installed.7z" "$env:ARKARI_VCPKG_INSTALLED/*"
    if ($LASTEXITCODE -ne 0) { throw 'Packaging bootstrap dependencies failed.' }
}
"artifact_name=$name" >> $env:GITHUB_OUTPUT
@"
## Windows x64 toolchain

- Arkari commit: $($metadata.arkari_commit)
- rpmalloc commit: $($metadata.rpmalloc_commit)
- vcpkg commit: $($metadata.vcpkg_commit)
- Targets: X86 (x86/x64), AArch64
- CRT/dependencies: static, x64-windows-static
- Variant: $Variant
- Configuration: $($metadata.build_type)
- BLA upstream: $($metadata.bla_integration.upstream_commit)
- BLA validation: $($metadata.bla_validation.status), $($metadata.bla_validation.checks_passed) regression groups
- Verification state: $($metadata.validation_state)
- Archive: $name.7z
- SHA256: $hash

Download the artifact below. It contains the toolchain archive, checksum and build metadata.
"@ >> $env:GITHUB_STEP_SUMMARY
if ($Unverified) {
    'This is an unverified diagnostic SDK checkpoint. Use the manual smoke workflow with recover_unverified=true; it cannot be used as native_run_id.' >> $env:GITHUB_STEP_SUMMARY
}
