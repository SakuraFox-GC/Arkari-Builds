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
    $normalized = 0
    foreach ($relative in $files) {
        $path = Join-Path $repository $relative
        $attributes = [IO.File]::GetAttributes($path)
        # LLVM's test data contains directory symlinks. File timestamp APIs
        # must not follow these links or operate on their directory targets.
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -or ($attributes -band [IO.FileAttributes]::Directory)) { continue }
        [IO.File]::SetLastWriteTimeUtc($path, $timestamp)
        $normalized++
    }
    # LLVM's find_first_existing_vc_file depends on .git/logs/HEAD when
    # generating VCSVersion.inc. A fresh reflog must not invalidate that header.
    $gitDir = (& git -C $repository rev-parse --absolute-git-dir).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Cannot locate Git metadata in $repository" }
    foreach ($relative in @('HEAD', 'logs/HEAD', 'packed-refs')) {
        $metadataFile = Join-Path $gitDir $relative
        if (Test-Path -LiteralPath $metadataFile -PathType Leaf) {
            [IO.File]::SetLastWriteTimeUtc($metadataFile, $timestamp)
        }
    }
    Write-Host "Normalized timestamps for $normalized tracked regular files in $repository"
}
