[CmdletBinding()]
param(
    [ValidateRange(0, 1024)]
    [int]$ParallelJobs = 0,
    [string]$LlvmBin = "$env:ProgramFiles/LLVM/bin"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true

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
    '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
    '-DCMAKE_BUILD_TYPE=Release',
    '-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON',
    '-DLLVM_ENABLE_PROJECTS=clang;clang-tools-extra;lld;lldb',
    '-DLLVM_TARGETS_TO_BUILD=X86;AArch64',
    '-DLLVM_ENABLE_RUNTIMES=compiler-rt;openmp',
    '-DRUNTIMES_CMAKE_ARGS=-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
    '-DBUILTINS_CMAKE_ARGS=-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreaded',
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
    "-DLLVM_INTEGRATED_CRT_ALLOC=$rpmallocDir",
    '-DLLVM_INCLUDE_TESTS=OFF',
    '-DLLVM_INCLUDE_EXAMPLES=OFF',
    '-DLLVM_INCLUDE_BENCHMARKS=OFF',
    '-DLLVM_ENABLE_ASSERTIONS=OFF',
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

# Build llvm-tblgen from these sources; a bootstrap LLVM version may have a different schema.
& "$LlvmBin/clang-cl.exe" --version
& cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw 'CMake configuration failed.' }
& cmake --build $buildDir --target distribution --parallel $ParallelJobs
if ($LASTEXITCODE -ne 0) { throw 'Building distribution failed.' }
& cmake --build $buildDir --target install-distribution --parallel $ParallelJobs
if ($LASTEXITCODE -ne 0) { throw 'Installing distribution failed.' }

$metadata = [ordered]@{
    arkari_repository = 'SakuraFox-GC/Arkari'
    arkari_ref = $env:ARKARI_REQUESTED_REF
    arkari_commit = (& git -C $sourceDir rev-parse HEAD)
    rpmalloc_repository = 'mjansson/rpmalloc'
    rpmalloc_ref = 'develop'
    rpmalloc_commit = (& git -C $rpmallocDir rev-parse HEAD)
    vcpkg_commit = (& git -C $env:VCPKG_ROOT rev-parse HEAD)
    vcpkg_triplet = 'x64-windows-static'
    build_config_commit = $env:GITHUB_SHA
    build_url = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
    built_at_utc = [DateTime]::UtcNow.ToString('o')
    bootstrap_compiler = (& "$LlvmBin/clang-cl.exe" --version) -join "`n"
    cmake_arguments = $cmakeArgs
}
$metadata | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $installDir 'build-info.json') -Encoding utf8
