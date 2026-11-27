[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ArtifactDir,
    [Parameter(Mandatory)][string]$ArtifactName,
    [Parameter(Mandatory)][string]$RunId,
    [ValidateSet('Release', 'Debug')][string]$BuildType = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$sidecars = @(Get-ChildItem $ArtifactDir -Filter '*.build-info.json' -File)
if ($sidecars.Count -ne 1) { throw 'Expected one native build metadata file.' }
$info = Get-Content $sidecars[0].FullName -Raw | ConvertFrom-Json
if ($info.arkari_repository -ne 'SakuraFox-GC/Arkari' -or $info.thin_lto -or $info.build_type -ne $BuildType) {
    throw 'The saved artifact is not a matching native Arkari build.'
}
foreach ($field in @('arkari_commit', 'rpmalloc_commit', 'vcpkg_commit')) {
    if ($info.$field -notmatch '^[0-9a-f]{40}$') { throw "Invalid native revision: $field" }
}
if ($sidecars[0].Name -cne "$ArtifactName.build-info.json") { throw 'Native artifact name/metadata mismatch.' }
$archive = Join-Path $ArtifactDir "$ArtifactName.7z"
$expectedHash = ((Get-Content "$archive.sha256" -Raw).Trim() -split '\s+')[0]
if ((Get-FileHash $archive -Algorithm SHA256).Hash -ine $expectedHash) { throw 'Native archive checksum mismatch.' }
if (-not (Test-Path "$ArtifactDir/bootstrap/vcpkg-installed.7z")) { throw 'This native artifact has no bootstrap dependencies; build it with build_lto enabled.' }
"artifact_name=$ArtifactName" >> $env:GITHUB_OUTPUT
"bootstrap_run_id=$RunId" >> $env:GITHUB_OUTPUT
"arkari_commit=$($info.arkari_commit)" >> $env:GITHUB_OUTPUT
"rpmalloc_commit=$($info.rpmalloc_commit)" >> $env:GITHUB_OUTPUT
Write-Host "Reusing verified native $BuildType build from run $RunId, Arkari $($info.arkari_commit)."
