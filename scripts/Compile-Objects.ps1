[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildDir,
    [ValidateRange(1, 1024)][int]$ParallelJobs = [Environment]::ProcessorCount
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
# Query the distribution's dependency closure, rather than compiling every
# object target in LLVM (which would include tools outside this distribution).
$graph = & ninja -C $BuildDir -t graph distribution
if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the Ninja distribution graph.' }
$objects = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($line in $graph) {
    if ($line -match '\[\s*label="((?:\\.|[^"\\])*)"\s*[\],]') {
        $target = $Matches[1].Replace('\"', '"').Replace('\\', '\')
        if ($target -match '\.(obj|o)$') { [void]$objects.Add($target) }
    }
}
if (-not $objects.Count) { throw 'No object targets found in the distribution graph.' }

# A wrapper Ninja file avoids Windows' command-line length limit for thousands
# of object targets. Necessary code-generation tools still build as dependencies.
$escaped = @($objects | Sort-Object | ForEach-Object {
    $_.Replace('$', '$$').Replace(' ', '$ ').Replace(':', '$:')
})
$wrapper = @('include build.ninja', '', "build arkari-compile-objects: phony $($escaped -join ' ')")
Set-Content (Join-Path $BuildDir 'arkari-objects.ninja') $wrapper -Encoding utf8
Write-Host "Compiling $($objects.Count) distribution object targets; final binaries are deferred to the link job."
& ninja -C $BuildDir -f arkari-objects.ninja -j $ParallelJobs arkari-compile-objects
if ($LASTEXITCODE -ne 0) { throw 'Compiling distribution objects failed.' }
