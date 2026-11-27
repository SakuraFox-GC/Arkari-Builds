[CmdletBinding()]
param(
    [ValidateRange(0, 1024)]
    [int]$ParallelJobs = 0,
    [string]$LlvmBin = "$env:VSINSTALLDIR/VC/Tools/Llvm/x64/bin",
    [ValidateSet('Release', 'Debug')]
    [string]$BuildType = 'Release',
    [switch]$ThinLto,
    [ValidateSet('All', 'Compile', 'Link')]
    [string]$Phase = 'All'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
if ($Phase -ne 'All' -and -not $ThinLto) { throw 'Split build phases require ThinLTO.' }

$repoRoot = (Split-Path $PSScriptRoot -Parent).Replace('\', '/')
$sourceDir = "$repoRoot/sources/arkari"
$rpmallocDir = "$repoRoot/sources/rpmalloc"
$buildDir = "$env:ARKARI_BUILD_ROOT/build".Replace('\', '/')
$installDir = "$env:ARKARI_BUILD_ROOT/install".Replace('\', '/')
$LlvmBin = $LlvmBin.Replace('\', '/')
$vcpkgRoot = $env:VCPKG_ROOT.Replace('\', '/')
$vcpkgInstalled = $env:ARKARI_VCPKG_INSTALLED.Replace('\', '/')
$diaSdkDir = $null
foreach ($sdkPath in @('DIA SDK/Preview', 'DIA SDK')) {
    $candidate = Join-Path $env:VSINSTALLDIR $sdkPath
    if ((Test-Path "$candidate/include/dia2.h") -and (Test-Path "$candidate/lib/amd64/diaguids.lib")) {
        $diaSdkDir = $candidate.Replace('\', '/')
        break
    }
}
if (-not $diaSdkDir) { throw "No x64 DIA SDK found under $env:VSINSTALLDIR" }

foreach ($file in @(
    "$sourceDir/llvm/CMakeLists.txt",
    "$sourceDir/libc/CMakeLists.txt",
    "$sourceDir/libunwind/include/mach-o/compact_unwind_encoding.h",
    "$rpmallocDir/rpmalloc/rpmalloc.c",
    "$env:VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake",
    "$env:ARKARI_VCPKG_INSTALLED/x64-windows-static/include/zlib.h",
    "$env:ARKARI_VCPKG_INSTALLED/x64-windows-static/include/lzma.h",
    "$env:ARKARI_VCPKG_INSTALLED/x64-windows-static/include/libxml2/libxml/parser.h",
    "$diaSdkDir/include/dia2.h",
    "$diaSdkDir/lib/amd64/diaguids.lib"
)) {
    if (-not (Test-Path -LiteralPath $file)) { throw "Required build input is missing: $file" }
}
foreach ($tool in @('clang-cl.exe', 'lld-link.exe', 'llvm-ranlib.exe', 'llvm-lib.exe')) {
    if (-not (Test-Path -LiteralPath (Join-Path $LlvmBin $tool))) {
        throw "Missing bootstrap tool: $LlvmBin/$tool"
    }
}

if ($ParallelJobs -eq 0) { $ParallelJobs = [Environment]::ProcessorCount }
$msvcRuntime = if ($BuildType -eq 'Debug') { 'MultiThreadedDebug' } else { 'MultiThreaded' }
$assertions = if ($BuildType -eq 'Debug') { 'ON' } else { 'OFF' }
# LLVM explicitly rejects integrated CRT allocators in Debug configurations.
$allocator = if ($BuildType -eq 'Debug') { '' } else { $rpmallocDir }
$env:CMAKE_BUILD_PARALLEL_LEVEL = "$ParallelJobs"
New-Item -ItemType Directory -Force $buildDir, $installDir | Out-Null

# Keep the supplied distribution component list, including compiler-rt and OpenMP.
$components = @(
    'clang', 'clang-resource-headers', 'clang-apply-replacements', 'clang-change-namespace',
    'clang-check', 'clang-doc', 'clang-extdef-mapping', 'clang-format', 'clang-include-cleaner',
    'clang-include-fixer', 'clang-installapi', 'clang-linker-wrapper', 'clang-move',
    'clang-nvlink-wrapper', 'clang-offload-bundler', 'clang-query', 'clang-refactor',
    'clang-reorder-fields', 'clang-repl', 'clang-scan-deps', 'clang-sycl-linker', 'clang-tidy',
    'clangd', 'diagtool', 'find-all-symbols', 'hmaptool', 'libclang', 'modularize',
    'offload-arch', 'pp-trace', 'scan-build', 'scan-build-py', 'scan-view', 'lld', 'lldb',
    'lldb-argdumper', 'lldb-dap', 'lldb-instr', 'lldb-mcp', 'lldb-server', 'liblldb',
    'yaml2macho-core', 'LLVM-C', 'LTO', 'Remarks', 'llvm-ar', 'llvm-ranlib', 'llvm-lib',
    'llvm-dlltool', 'llvm-cov', 'llvm-cxxfilt', 'llvm-dwp', 'llvm-mca', 'llvm-ml',
    'llvm-ml64', 'llvm-mt', 'llvm-nm', 'llvm-objcopy', 'llvm-objdump', 'llvm-pdbutil',
    'llvm-profdata', 'llvm-profgen', 'llvm-rc', 'llvm-readobj', 'llvm-size', 'llvm-strings',
    'llvm-strip', 'llvm-symbolizer', 'builtins', 'runtimes'
)

$cmakeArgs = @(
    '-S', "$sourceDir/llvm", '-B', $buildDir, '-G', 'Ninja',
    "-DCMAKE_C_COMPILER=$LlvmBin/clang-cl.exe",
    "-DCMAKE_CXX_COMPILER=$LlvmBin/clang-cl.exe",
    "-DCMAKE_LINKER=$LlvmBin/lld-link.exe",
    "-DCMAKE_RANLIB=$LlvmBin/llvm-ranlib.exe",
    "-DCMAKE_AR=$LlvmBin/llvm-lib.exe",
    '-DLLVM_USE_LINKER=lld',
    '-DLLVM_PARALLEL_LINK_JOBS=2',
    '-DCMAKE_CXX_FLAGS=-DLIBXML_STATIC /utf-8 /EHsc',
    '-DCMAKE_C_FLAGS=-DLIBXML_STATIC /utf-8 /std:clatest /experimental:c11atomics',
    "-DCMAKE_INSTALL_PREFIX=$installDir",
    "-DCMAKE_MSVC_RUNTIME_LIBRARY=$msvcRuntime",
    "-DCMAKE_BUILD_TYPE=$BuildType",
    '-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON',
    '-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld;lldb',
    '-DLLVM_TARGETS_TO_BUILD=X86;AArch64',
    '-DLLVM_ENABLE_RUNTIMES=compiler-rt;openmp',
    "-DRUNTIMES_CMAKE_ARGS=-DCMAKE_MSVC_RUNTIME_LIBRARY=$msvcRuntime",
    "-DBUILTINS_CMAKE_ARGS=-DCMAKE_MSVC_RUNTIME_LIBRARY=$msvcRuntime",
    '-DCOMPILER_RT_BUILD_ORC=OFF',
    '-DLLVM_BUILD_LLVM_C_DYLIB=ON',
    '-DPython3_FIND_REGISTRY=NEVER',
    '-DLLDB_ENABLE_PYTHON=OFF',
    '-DLLVM_BUILD_TOOLS=ON',
    '-DLLVM_INSTALL_TOOLCHAIN_ONLY=OFF',
    "-DLLVM_DISTRIBUTION_COMPONENTS=$($components -join ';')",
    '-DLLVM_ENABLE_ZLIB=FORCE_ON',
    '-DLLVM_ENABLE_ZSTD=OFF',
    '-DLLVM_ENABLE_LIBXML2=FORCE_ON',
    '-DCLANG_ENABLE_LIBXML2=OFF',
    '-DLLDB_ENABLE_LZMA=ON',
    '-DLLDB_ENABLE_LIBXML2=ON',
    # LLVM_ENABLE_RPMALLOC=ON would override the external path with the in-tree copy.
    '-DLLVM_ENABLE_RPMALLOC=OFF',
    "-DLLVM_INTEGRATED_CRT_ALLOC=$allocator",
    '-DLLVM_INCLUDE_TESTS=OFF',
    '-DLLVM_INCLUDE_EXAMPLES=OFF',
    '-DLLVM_INCLUDE_BENCHMARKS=OFF',
    "-DLLVM_ENABLE_ASSERTIONS=$assertions",
    '-DLLVM_EXPORT_SYMBOLS_FOR_PLUGINS=ON',
    "-DCMAKE_TOOLCHAIN_FILE=$vcpkgRoot/scripts/buildsystems/vcpkg.cmake",
    '-DVCPKG_TARGET_TRIPLET=x64-windows-static',
    '-DVCPKG_HOST_TRIPLET=x64-windows-static',
    '-DVCPKG_MANIFEST_MODE=ON',
    "-DVCPKG_MANIFEST_DIR=$repoRoot",
    "-DVCPKG_INSTALLED_DIR=$vcpkgInstalled",
    '-DVCPKG_MANIFEST_INSTALL=OFF',
    "-DMSVC_DIA_SDK_DIR=$diaSdkDir"
)

$arkariCommit = & git -C $sourceDir rev-parse HEAD
$rpmallocCommit = & git -C $rpmallocDir rev-parse HEAD
if ($ThinLto) {
    $tablegen = "$LlvmBin/llvm-tblgen.exe"
    if (-not (Test-Path $tablegen)) { throw "Missing native bootstrap tablegen: $tablegen" }
    $nativeInfo = Get-Content "$LlvmBin/../build-info.json" -Raw | ConvertFrom-Json
    if ($nativeInfo.arkari_commit -ne $arkariCommit -or $nativeInfo.rpmalloc_commit -ne $rpmallocCommit -or $nativeInfo.build_type -ne $BuildType) {
        throw 'ThinLTO sources must match the native bootstrap revisions.'
    }
    $cmakeArgs += '-DLLVM_ENABLE_LTO=Thin'
    $cmakeArgs += "-DLLVM_TABLEGEN=$tablegen"
}
else {
    $cmakeArgs += '-DLLVM_ENABLE_LTO=OFF'
}

# Keep checkout mtimes stable when objects move to another runner.
if ($Phase -ne 'All') {
    & "$PSScriptRoot/Set-SourceTimes.ps1" -RepositoryPaths @($sourceDir, $rpmallocDir, $repoRoot)
}
$checkpointPath = Join-Path $buildDir 'arkari-checkpoint.json'
if ($Phase -ne 'All') {
    $fingerprint = [ordered]@{
        arkari_commit = $arkariCommit
        rpmalloc_commit = $rpmallocCommit
        build_type = $BuildType
        build_config_commit = $env:GITHUB_SHA
        source_dir = $sourceDir
        build_dir = $buildDir
        llvm_bin = $LlvmBin
        bootstrap_compiler = (& "$LlvmBin/clang-cl.exe" --version) -join [Environment]::NewLine
        vcpkg_installed = $vcpkgInstalled
        vcpkg_dependency_commit = $nativeInfo.vcpkg_commit
        msvc_version = $env:VCToolsVersion
        windows_sdk_version = $env:WindowsSDKVersion
        cmake_version = (& cmake --version | Select-Object -First 1)
        ninja_version = (& ninja --version)
        cmake_arguments = $cmakeArgs
    }
}
if ($Phase -eq 'Link') {
    $saved = Get-Content $checkpointPath -Raw | ConvertFrom-Json -AsHashtable
    foreach ($key in $fingerprint.Keys) {
        $expected = $fingerprint[$key] | ConvertTo-Json -Compress
        $actual = $saved[$key] | ConvertTo-Json -Compress
        if ($expected -cne $actual) { throw "Checkpoint does not match this link job: $key" }
    }
    Write-Host 'Validated compilation checkpoint; resuming Ninja without reconfiguring CMake.'
    $plan = @(& ninja -C $buildDir -n distribution)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect the resumed link plan.' }
    $plan | Set-Content (Join-Path $buildDir 'link-plan.txt') -Encoding utf8
    $recompiles = @($plan | Where-Object { $_ -match 'Building (CXX|C|ASM\S*) object|Re-running CMake' })
    if ($recompiles.Count) { throw "Checkpoint requires unexpected recompilation/reconfiguration; inspect link-plan.txt ($($recompiles.Count) steps)." }
    Write-Host "Verified link plan: no top-level object recompilation ($($plan.Count) pending steps)."
} else {
    # The native stage builds tablegen from source; LTO reuses that exact version.
    & "$LlvmBin/clang-cl.exe" --version
    & cmake @cmakeArgs
    if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
}
if ($Phase -eq 'Compile') {
    & "$PSScriptRoot/Compile-Objects.ps1" -BuildDir $buildDir -ParallelJobs $ParallelJobs
    $fingerprint | ConvertTo-Json -Depth 5 | Set-Content $checkpointPath -Encoding utf8
    return
}
& cmake --build $buildDir --target distribution --parallel $ParallelJobs
if ($LASTEXITCODE -ne 0) { throw 'Building distribution failed.' }
& cmake --build $buildDir --target install-distribution --parallel $ParallelJobs
if ($LASTEXITCODE -ne 0) { throw 'Installing distribution failed.' }

if (-not $ThinLto) {
    # distribution does not install this build-time tool, but the next stage needs it.
    Copy-Item "$buildDir/bin/llvm-tblgen.exe" "$installDir/bin/llvm-tblgen.exe"
}

$vcpkgToolchainCommit = & git -C $env:VCPKG_ROOT rev-parse HEAD
$metadata = [ordered]@{
    arkari_repository = 'SakuraFox-GC/Arkari'
    arkari_ref = $env:ARKARI_REQUESTED_REF
    arkari_commit = $arkariCommit
    rpmalloc_repository = 'mjansson/rpmalloc'
    rpmalloc_ref = 'develop'
    rpmalloc_commit = $rpmallocCommit
    vcpkg_commit = $(if ($ThinLto) { $nativeInfo.vcpkg_commit } else { $vcpkgToolchainCommit })
    vcpkg_toolchain_commit = $vcpkgToolchainCommit
    vcpkg_triplet = 'x64-windows-static'
    build_type = $BuildType
    integrated_allocator = $(if ($BuildType -eq 'Debug') { 'none' } else { 'rpmalloc' })
    thin_lto = [bool]$ThinLto
    build_config_commit = $env:GITHUB_SHA
    build_url = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    bootstrap_compiler = (& "$LlvmBin/clang-cl.exe" --version) -join "`n"
    cmake_arguments = $cmakeArgs
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $installDir 'build-info.json') -Encoding utf8
if ($env:GITHUB_OUTPUT) {
    "arkari_commit=$($metadata.arkari_commit)" >> $env:GITHUB_OUTPUT
    "rpmalloc_commit=$($metadata.rpmalloc_commit)" >> $env:GITHUB_OUTPUT
}
