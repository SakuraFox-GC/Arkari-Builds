[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactDir,
    [Parameter(Mandatory)][string]$Destination,
    [string]$DependenciesDir = ''
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$archives = @(Get-ChildItem $ArtifactDir -Filter '*.7z' -File)
if ($archives.Count -ne 1) { throw 'Expected exactly one native toolchain archive.' }
$archive = $archives[0].FullName
$expectedHash = ((Get-Content "$archive.sha256" -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash $archive -Algorithm SHA256).Hash -ine $expectedHash) { throw 'Native archive checksum mismatch.' }
& 7z x $archive "-o$Destination" -y
if ($LASTEXITCODE -ne 0) { throw 'Extracting native bootstrap failed.' }
if ($DependenciesDir) {
    & 7z x "$ArtifactDir/bootstrap/vcpkg-installed.7z" "-o$DependenciesDir" -y
    if ($LASTEXITCODE -ne 0) { throw 'Extracting native dependencies failed.' }
}
