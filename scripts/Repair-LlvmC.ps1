[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NativeDir,
    [Parameter(Mandatory)][string]$LtoDir,
    [Parameter(Mandatory)][string]$BuildDir,
    [Parameter(Mandatory)][string]$SourceDir,
    [Parameter(Mandatory)][string]$RpmallocDir
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$NativeDir = $NativeDir.Replace('\', '/')
$BuildDir = $BuildDir.Replace('\', '/')
$SourceDir = $SourceDir.Replace('\', '/')
$RpmallocDir = $RpmallocDir.Replace('\', '/')
$nativeInfo = Get-Content "$NativeDir/build-info.json" -Raw | ConvertFrom-Json
$info = Get-Content "$LtoDir/build-info.json" -Raw | ConvertFrom-Json
foreach ($key in @('arkari_commit', 'rpmalloc_commit', 'vcpkg_commit', 'build_type')) {
    if ($nativeInfo.$key -ne $info.$key) { throw "Native/LTO revision mismatch before repair: $key" }
}
if (-not $info.thin_lto) { throw 'Repair requires linked ThinLTO binaries.' }
$saved = Get-Content "$BuildDir/arkari-checkpoint.json" -Raw | ConvertFrom-Json -AsHashtable
$expected = [ordered]@{
    arkari_commit = (& git -C $SourceDir rev-parse HEAD)
    rpmalloc_commit = (& git -C $RpmallocDir rev-parse HEAD)
    build_type = $info.build_type
    source_dir = $SourceDir
    build_dir = $BuildDir
    llvm_bin = "$NativeDir/bin"
    bootstrap_compiler = (& "$NativeDir/bin/clang-cl.exe" --version) -join [Environment]::NewLine
    vcpkg_installed = "$env:RUNNER_TEMP/arkari-vcpkg-installed".Replace('\', '/')
    vcpkg_dependency_commit = $nativeInfo.vcpkg_commit
    msvc_version = $env:VCToolsVersion
    windows_sdk_version = $env:WindowsSDKVersion
    cmake_version = (& cmake --version | Select-Object -First 1)
    ninja_version = (& ninja --version)
    cmake_arguments = @($info.cmake_arguments)
}
# The source revisions, compiler, SDK, paths and original CMake arguments must
# match. Only the export parser and final DLL link are changed by this repair.
foreach ($key in $expected.Keys) {
    $actualJson = $saved[$key] | ConvertTo-Json -Compress
    $expectedJson = $expected[$key] | ConvertTo-Json -Compress
    if ($actualJson -cne $expectedJson) { throw "Cannot reuse objects for LLVM-C repair: $key" }
}
$patch = & "$PSScriptRoot/Patch-LlvmCExports.ps1" -SourceDir $SourceDir
$repoRoot = Split-Path $PSScriptRoot -Parent
& "$PSScriptRoot/Set-SourceTimes.ps1" -RepositoryPaths @($SourceDir, $RpmallocDir, $repoRoot)
# The upstream custom command does not depend on its Python script. Remove
# just its generated export files to force regeneration after patching it.
Get-ChildItem $BuildDir -Recurse -File | Where-Object {
    $_.Name -in @('libllvm-c.exports', 'LLVM-C.def')
} | Remove-Item -Force
$plan = @(& ninja -C $BuildDir -n LLVM-C)
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the LLVM-C repair plan.' }
$plan | Set-Content "$BuildDir/llvm-c-repair-plan.txt" -Encoding utf8
if (@($plan | Where-Object { $_ -match 'Building (CXX|C|ASM\S*) object|Re-running CMake' }).Count) {
    throw 'LLVM-C repair would recompile sources; inspect llvm-c-repair-plan.txt.'
}
Write-Host 'Validated LLVM-C repair plan: regenerate exports and relink, without C++ recompilation.'
& cmake --build $BuildDir --target LLVM-C --parallel ([Environment]::ProcessorCount)
if ($LASTEXITCODE -ne 0) { throw 'Relinking LLVM-C failed.' }
function Get-Names([string]$File) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $lines = & "$NativeDir/bin/llvm-readobj.exe" --coff-exports $File
    foreach ($line in $lines) {
        if ($line -match '^\s*Name: (.+?)\s*$') { [void]$names.Add($Matches[1]) }
    }
    return ,$names
}
$before = Get-Names "$NativeDir/bin/LLVM-C.dll"
$after = Get-Names "$BuildDir/bin/LLVM-C.dll"
if (-not $before.Count) { throw 'The native LLVM-C DLL has no C API exports.' }
$missing = @($before | Where-Object { -not $after.Contains($_) })
if ($missing.Count) { throw "Repaired LLVM-C DLL still lacks native C API exports: $($missing -join ', ')" }
Copy-Item "$BuildDir/bin/LLVM-C.dll" "$LtoDir/bin/LLVM-C.dll" -Force
$info | Add-Member -NotePropertyName source_patches -NotePropertyValue @($patch) -Force
$info | Add-Member -NotePropertyName export_repair -NotePropertyValue ([ordered]@{
    config_commit = $env:GITHUB_SHA
    repaired_at_utc = [DateTime]::UtcNow.ToString('o')
    native_c_api_exports_verified = $before.Count
    original_lto_build_url = $info.build_url
}) -Force
$info | ConvertTo-Json -Depth 10 | Set-Content "$LtoDir/build-info.json" -Encoding utf8
Write-Host "Repaired LLVM-C.dll: all $($before.Count) native C API exports retained."
