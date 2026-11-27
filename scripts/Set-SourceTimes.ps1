[CmdletBinding()]
param([Parameter(Mandatory)][string[]]$RepositoryPaths)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
# Ninja records input timestamps. A fresh checkout in the next job must have
# the same timestamps as the checkout used to compile the saved objects.
$timestamp = [DateTime]::new(2000, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
foreach ($repository in $RepositoryPaths) {
    $tracked = (& git -C $repository ls-files -z) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw "Cannot list sources in $repository" }
    $files = $tracked.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($relative in $files) {
        [IO.File]::SetLastWriteTimeUtc((Join-Path $repository $relative), $timestamp)
    }
    Write-Host "Normalized timestamps for $($files.Count) tracked files in $repository"
}
