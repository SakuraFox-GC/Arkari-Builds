[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$fixture = Join-Path $env:RUNNER_TEMP "arkari handoff test-$([Guid]::NewGuid().ToString('N'))"
$source = Join-Path $fixture 'source'
$build = Join-Path $fixture 'build'
$archive = Join-Path $fixture 'objects.7z'
New-Item -ItemType Directory -Force $source | Out-Null
try {
    @'
cmake_minimum_required(VERSION 3.20)
project(CheckpointTest C)
configure_file(config.h.in config.h)
add_custom_command(
  OUTPUT "@BINARY@/version.h"
  COMMAND "@CMAKE@" -E copy_if_different "@SOURCE@/version.h.in" "@BINARY@/version.h"
  DEPENDS "@SOURCE@/.git/logs/HEAD" "@SOURCE@/version.h.in")
add_executable(fixture main.c helper.c "@BINARY@/version.h")
target_include_directories(fixture PRIVATE "@BINARY@")
add_executable(unused EXCLUDE_FROM_ALL unused.c)
add_custom_target(distribution DEPENDS fixture)
'@.Replace('@BINARY@', ('$' + '{CMAKE_CURRENT_BINARY_DIR}')).Replace('@SOURCE@', ('$' + '{CMAKE_CURRENT_SOURCE_DIR}')).Replace('@CMAKE@', ('$' + '{CMAKE_COMMAND}')) | Set-Content "$source/CMakeLists.txt"
    '#define EXPECTED 42' | Set-Content "$source/config.h.in"
    '#define VCS_VERSION 42' | Set-Content "$source/version.h.in"
    (@('#include "config.h"', '#include "version.h"', 'int helper(void); int main(void) { return helper() != EXPECTED || VCS_VERSION != 42; }') -join [Environment]::NewLine) | Set-Content "$source/main.c"
    'int helper(void) { return 42; }' | Set-Content "$source/helper.c"
    '#error This target must not be compiled' | Set-Content "$source/unused.c"
    & git -C $source init --quiet
    New-Item -ItemType Directory -Force "$source/.git/logs" | Out-Null
    'fixture revision metadata' | Set-Content "$source/.git/logs/HEAD"
    & git -C $source add .
    & "$PSScriptRoot/Set-SourceTimes.ps1" -RepositoryPaths @($source)
    & cmake -S $source -B $build -G Ninja -DCMAKE_C_COMPILER=cl
    if ($LASTEXITCODE -ne 0) { throw 'Cannot configure the handoff fixture.' }
    & "$PSScriptRoot/Compile-Objects.ps1" -BuildDir $build -ParallelJobs 2
    if (Test-Path "$build/fixture.exe") { throw 'The compile phase linked the fixture.' }
    $objects = @(Get-ChildItem "$build/CMakeFiles/fixture.dir" -Recurse -Filter '*.obj')
    if ($objects.Count -ne 2) { throw "Expected two fixture objects, found $($objects.Count)." }
    $hashes = @{}
    foreach ($object in $objects) {
        $hashes[[IO.Path]::GetRelativePath($build, $object.FullName)] = (Get-FileHash $object.FullName).Hash
    }
    & 7z a -t7z -mx=1 $archive "$build/*"
    if ($LASTEXITCODE -ne 0) { throw 'Cannot archive the handoff fixture.' }
    Remove-Item $build -Recurse -Force
    # Simulate a new checkout before restoring the archived build directory.
    Get-ChildItem $source -File | ForEach-Object { $_.LastWriteTimeUtc = [DateTime]::UtcNow }
    (Get-Item "$source/.git/logs/HEAD").LastWriteTimeUtc = [DateTime]::UtcNow
    & "$PSScriptRoot/Set-SourceTimes.ps1" -RepositoryPaths @($source)
    & 7z x $archive "-o$build" -y
    if ($LASTEXITCODE -ne 0) { throw 'Cannot restore the handoff fixture.' }
    $plan = (& ninja -C $build -n distribution) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the restored build plan.' }
    if ($plan -match 'Building C object|Re-running CMake') { throw "The restored checkpoint recompiles objects: $plan" }
    if ($plan -notmatch 'Linking C executable') { throw "The link phase has no pending link: $plan" }
    & cmake --build $build --target distribution
    if ($LASTEXITCODE -ne 0) { throw 'Cannot link the restored fixture.' }
    foreach ($relative in $hashes.Keys) {
        if ((Get-FileHash (Join-Path $build $relative)).Hash -ne $hashes[$relative]) { throw "Restored object changed: $relative" }
    }
    & "$build/fixture.exe"
    if ($LASTEXITCODE -ne 0) { throw 'The restored fixture failed to run.' }
    Write-Host 'Checkpoint verified: selected objects compiled, archived, restored and linked without recompilation.'
} finally {
    Remove-Item $fixture -Recurse -Force
}
