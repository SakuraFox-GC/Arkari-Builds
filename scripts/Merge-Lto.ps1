[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$NativeDir,
    [Parameter(Mandatory)][string]$LtoDir
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$nativeInfo = Get-Content "$NativeDir/build-info.json" -Raw | ConvertFrom-Json
$ltoInfo = Get-Content "$LtoDir/build-info.json" -Raw | ConvertFrom-Json
foreach ($field in @('arkari_commit', 'rpmalloc_commit', 'vcpkg_commit')) {
    if ($nativeInfo.$field -ne $ltoInfo.$field) { throw "Native/LTO revision mismatch: $field" }
}
if (-not $ltoInfo.thin_lto) { throw 'The second stage was not built with ThinLTO.' }

function Get-LibraryHashes([string]$Directory) {
    $hashes = @{}
    Get-ChildItem "$Directory/lib" -Recurse -File | ForEach-Object {
        $relative = [IO.Path]::GetRelativePath($Directory, $_.FullName)
        $hashes[$relative] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    }
    return $hashes
}

function Get-ExportNames([string]$DllPath) {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $dump = & "$LtoDir/bin/llvm-readobj.exe" --coff-exports $DllPath
    if ($LASTEXITCODE -ne 0) { throw "Cannot inspect DLL exports: $DllPath" }
    foreach ($line in $dump) {
        if ($line -match '^\s*Name: (.+?)\s*$') { [void]$names.Add($Matches[1]) }
    }
    return ,$names
}

$libraryHashes = Get-LibraryHashes $NativeDir
if ($libraryHashes.Count -eq 0) { throw 'The native package contains no libraries.' }
Get-ChildItem "$NativeDir/bin" -Filter '*.dll' -File | ForEach-Object {
    $replacement = Join-Path "$LtoDir/bin" $_.Name
    if (-not (Test-Path $replacement)) { throw "Missing LTO replacement DLL: $($_.Name)" }
    $nativeExports = Get-ExportNames $_.FullName
    $ltoExports = Get-ExportNames $replacement
    $missing = @($nativeExports | Where-Object { -not $ltoExports.Contains($_) })
    if ($missing.Count) { throw "$($_.Name) lost native exports: $($missing -join ', ')" }
    Write-Host "Verified $($_.Name): all $($nativeExports.Count) native exports retained."
}

# Only bin is overlaid. Headers, resource files, libraries and import libraries stay native.
Copy-Item "$LtoDir/bin/*" "$NativeDir/bin" -Recurse -Force
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
    thin_lto = $true
    package_layout = 'ThinLTO bin with native libraries and resources'
    native_build = $nativeInfo
    lto_build = $ltoInfo
    native_library_files_verified = $libraryHashes.Count
}
$mergedInfo | ConvertTo-Json -Depth 10 | Set-Content "$NativeDir/build-info.json" -Encoding utf8
