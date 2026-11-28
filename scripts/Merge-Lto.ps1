[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NativeDir,
    [Parameter(Mandatory)][string]$LtoDir,
    [string]$SourceDir = "$PSScriptRoot/../sources/arkari"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$nativeInfo = Get-Content "$NativeDir/build-info.json" -Raw | ConvertFrom-Json
$ltoInfo = Get-Content "$LtoDir/build-info.json" -Raw | ConvertFrom-Json
foreach ($field in @('arkari_commit', 'rpmalloc_commit', 'vcpkg_commit', 'build_type')) {
    if ($nativeInfo.$field -ne $ltoInfo.$field) { throw "Native/LTO revision mismatch: $field" }
}
if (-not $ltoInfo.thin_lto) { throw 'The second stage was not built with ThinLTO.' }
if (-not $nativeInfo.PSObject.Properties['bla_integration'] -or
    -not $ltoInfo.PSObject.Properties['bla_integration'] -or
    $nativeInfo.bla_integration.upstream_commit -cne $ltoInfo.bla_integration.upstream_commit) {
    throw 'Native/LTO BLA source integration mismatch.'
}
$typeHeader = "$SourceDir/clang/include/clang/AST/TypeBase.h"
if (-not (Test-Path $typeHeader)) { $typeHeader = "$SourceDir/clang/include/clang/AST/Type.h" }
$typeDeclarations = Get-Content $typeHeader -Raw
$getAsTypes = @([regex]::Matches($typeDeclarations, 'template\s*<>\s*const\s+(\w+)\s*\*\s*Type::getAs\(\)\s*const\s*;') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
if (-not $getAsTypes.Count) { throw 'Cannot determine the out-of-line Type::getAs plugin interfaces.' }
$exeDifferences = [Collections.Generic.List[object]]::new()

function Get-LibraryHashes([string]$Directory) {
    $hashes = @{}
    Get-ChildItem "$Directory/lib" -Recurse -File | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Directory, $_.FullName)
        $hashes[$relative] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Get-ExportNames([string]$BinaryPath) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $dump = & "$LtoDir/bin/llvm-readobj.exe" --coff-exports $BinaryPath
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect PE exports: $BinaryPath" }
    foreach ($line in $dump) {
        if ($line -match '^\s*Name: (.+?)\s*$') { [void]$names.Add($Matches[1]) }
    }
    return ,$names
}

$libraryHashes = Get-LibraryHashes $NativeDir
if ($libraryHashes.Count -eq 0) { throw 'The native package contains no libraries.' }
Get-ChildItem "$NativeDir/bin" -File | Where-Object { $_.Extension -in @('.dll', '.exe') } | ForEach-Object {
    $replacement = Join-Path "$LtoDir/bin" $_.Name
    # This native build-time tool is deliberately reused rather than rebuilt with LTO.
    if ($_.Name -eq 'llvm-tblgen.exe') { return }
    if (-not (Test-Path $replacement)) { throw "Missing LTO replacement binary: $($_.Name)" }
    $nativeExports = Get-ExportNames $_.FullName
    $ltoExports = Get-ExportNames $replacement
    $missing = @($nativeExports | Where-Object { -not $ltoExports.Contains($_) })
    if ($_.Extension -ieq '.dll') {
        if ($missing.Count) { throw "$($_.Name) lost native DLL exports: $($missing -join ', ')" }
    } else {
        if ($nativeExports.Count -and -not $ltoExports.Count) { throw "$($_.Name) no longer exports plugin symbols." }
        $requiredMissing = @($missing | Where-Object {
            $symbol = $_
            if ($symbol.Contains('getRegistryLinkListInstance')) { return $true }
            foreach ($type in $getAsTypes) {
                if ($symbol.StartsWith('??$getAs@V' + $type + '@clang@@@Type@clang@@')) { return $true }
            }
            return $false
        })
        if ($requiredMissing.Count) { throw "$($_.Name) lost required plugin exports: $($requiredMissing -join ', ')" }
        if ($missing.Count) {
            $exeDifferences.Add([ordered]@{ binary = $_.Name; missing_automatic_exports = $missing.Count })
            Write-Host "$($_.Name): $($missing.Count) automatic EXE exports differ; required plugin interfaces retained."
        }
    }
    if ($nativeExports.Count) {
        Write-Host "Verified $($_.Name): native DLL interface / required plugin exports retained."
    }
}

# Replace bin files individually, breaking destination hardlinks before writing.
# Headers, resource files, libraries and import libraries stay native.
Get-ChildItem "$LtoDir/bin" -Recurse -File | ForEach-Object {
    $relative = [IO.Path]::GetRelativePath("$LtoDir/bin", $_.FullName)
    $destination = Join-Path "$NativeDir/bin" $relative
    New-Item -ItemType Directory -Force (Split-Path $destination -Parent) | Out-Null
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
    Copy-Item -LiteralPath $_.FullName -Destination $destination
}
$afterHashes = Get-LibraryHashes $NativeDir
if ($afterHashes.Count -ne $libraryHashes.Count) { throw 'The native library set changed.' }
foreach ($path in $libraryHashes.Keys) {
    if ($afterHashes[$path] -ne $libraryHashes[$path]) { throw "Native library changed: $path" }
}
Write-Host "Verified $($libraryHashes.Count) native library files unchanged."

$mergedInfo = [ordered]@{
    arkari_repository = $nativeInfo.arkari_repository
    arkari_ref = $nativeInfo.arkari_ref
    arkari_commit = $nativeInfo.arkari_commit
    rpmalloc_commit = $nativeInfo.rpmalloc_commit
    vcpkg_commit = $nativeInfo.vcpkg_commit
    build_type = $nativeInfo.build_type
    thin_lto = $true
    package_layout = 'ThinLTO bin with native libraries and resources'
    native_build = $nativeInfo
    lto_build = $ltoInfo
    native_library_files_verified = $libraryHashes.Count
    automatic_exe_export_differences = @($exeDifferences.ToArray())
    bla_integration = $nativeInfo.bla_integration
}
$mergedInfo | ConvertTo-Json -Depth 10 | Set-Content "$NativeDir/build-info.json" -Encoding utf8
