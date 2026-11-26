[CmdletBinding()]
param(
    [string]$InstallDir = "$env:ARKARI_BUILD_ROOT/install",
    [ValidateSet('Normal', 'ThinLTO')]
    [string]$Variant = 'Normal',
    [switch]$IncludeBootstrap
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$repoRoot = Split-Path $PSScriptRoot -Parent
$installDir = $InstallDir
$metadata = Get-Content (Join-Path $installDir 'build-info.json') -Raw | ConvertFrom-Json
$variantSuffix = if ($Variant -eq 'ThinLTO') { '-ThinLTO' } else { '' }
$name = "Arkari-Windows-x64$variantSuffix-$($metadata.arkari_commit.Substring(0, 12))-$env:GITHUB_RUN_NUMBER-$env:GITHUB_RUN_ATTEMPT"
$distDir = Join-Path $repoRoot 'dist'
$licensesDir = Join-Path $installDir 'licenses'
New-Item -ItemType Directory -Force $distDir, $licensesDir | Out-Null

Copy-Item (Join-Path $repoRoot 'sources/arkari/LICENSE.TXT') (Join-Path $licensesDir 'Arkari-LLVM-LICENSE.txt')
Copy-Item (Join-Path $repoRoot 'sources/rpmalloc/LICENSE') (Join-Path $licensesDir 'rpmalloc-LICENSE.txt')
Get-ChildItem "$env:ARKARI_VCPKG_INSTALLED/x64-windows-static/share/*/copyright" | ForEach-Object {
    Copy-Item $_.FullName (Join-Path $licensesDir "$($_.Directory.Name)-copyright.txt")
}

$archive = Join-Path $distDir "$name.7z"
& 7z a -t7z -mx=5 -mmt=2 $archive "$installDir/*"
if ($LASTEXITCODE -ne 0) { throw 'Packaging failed.' }
& 7z t $archive
if ($LASTEXITCODE -ne 0) { throw 'Archive verification failed.' }
$hash = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
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
- Archive: $name.7z
- SHA256: $hash

Download the artifact below. It contains the toolchain archive, checksum and build metadata.
"@ >> $env:GITHUB_STEP_SUMMARY
