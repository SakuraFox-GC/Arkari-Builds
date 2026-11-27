[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [ValidateSet('Release', 'Debug')][string]$BuildType = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$runtimeFlag = if ($BuildType -eq 'Debug') { '/MTd' } else { '/MT' }
$binDir = Join-Path $InstallDir 'bin'
$env:PATH = "$binDir;$env:PATH"
$smokeDir = Join-Path $env:RUNNER_TEMP 'arkari-smoke'
New-Item -ItemType Directory -Force $smokeDir | Out-Null

foreach ($tool in @('clang.exe', 'clang-cl.exe', 'lld-link.exe', 'lldb.exe', 'clangd.exe')) {
    & (Join-Path $binDir $tool) --version
    if ($LASTEXITCODE -ne 0) { throw "$tool failed to start." }
}

@'
#include <iostream>
#ifndef __ARKARI__
#error Expected an Arkari compiler
#endif
int main() {
    std::cout << "Arkari C++ smoke test\n";
    return 0;
}
'@ | Set-Content (Join-Path $smokeDir 'smoke.cpp') -Encoding utf8

Push-Location $smokeDir
try {
    & "$binDir/clang-cl.exe" /nologo $runtimeFlag /EHsc smoke.cpp /Fe:smoke.exe
    if ($LASTEXITCODE -ne 0) { throw 'C++ compile/link smoke test failed.' }
    & ./smoke.exe
    if ($LASTEXITCODE -ne 0) { throw 'C++ executable smoke test failed.' }

    'int answer(void) { return 42; }' | Set-Content targets.c -Encoding utf8
    foreach ($target in @('x86_64-pc-windows-msvc', 'i686-pc-windows-msvc', 'aarch64-pc-windows-msvc')) {
        & "$binDir/clang.exe" "--target=$target" -c targets.c -o "$target.obj"
        if ($LASTEXITCODE -ne 0) { throw "Code generation for $target failed." }
    }

    @'
#include <omp.h>
int main(void) {
    int count = 0;
    #pragma omp parallel reduction(+:count)
    count += 1;
    return count < 1;
}
'@ | Set-Content openmp.c -Encoding utf8
    & "$binDir/clang-cl.exe" /nologo $runtimeFlag /clang:-fopenmp openmp.c /Fe:openmp.exe /link "/LIBPATH:$InstallDir/lib"
    if ($LASTEXITCODE -ne 0) { throw 'OpenMP compile/link smoke test failed.' }
    & ./openmp.exe
    if ($LASTEXITCODE -ne 0) { throw 'OpenMP runtime smoke test failed.' }

    @'
#include <clang-c/Index.h>
int main(void) {
    CXIndex index = clang_createIndex(0, 0);
    if (!index) return 1;
    clang_disposeIndex(index);
    return 0;
}
'@ | Set-Content libclang.c -Encoding utf8
    $repoRoot = Split-Path $PSScriptRoot -Parent
    & cl.exe /nologo $runtimeFlag libclang.c "/I$repoRoot/sources/arkari/clang/include" /Fe:libclang-smoke.exe /link "/LIBPATH:$InstallDir/lib" libclang.lib
    if ($LASTEXITCODE -ne 0) { throw 'MSVC could not link the native libclang import library.' }
    & ./libclang-smoke.exe
    if ($LASTEXITCODE -ne 0) { throw 'libclang DLL/import-library compatibility smoke test failed.' }

    @'
typedef struct LLVMOpaqueContext *LLVMContextRef;
__declspec(dllimport) LLVMContextRef LLVMContextCreate(void);
__declspec(dllimport) void LLVMContextDispose(LLVMContextRef context);
int main(void) {
    LLVMContextRef context = LLVMContextCreate();
    if (!context) return 1;
    LLVMContextDispose(context);
    return 0;
}
'@ | Set-Content llvm-c.c -Encoding utf8
    & cl.exe /nologo $runtimeFlag llvm-c.c /Fe:llvm-c-smoke.exe /link "/LIBPATH:$InstallDir/lib" LLVM-C.lib
    if ($LASTEXITCODE -ne 0) { throw 'MSVC could not link the native LLVM-C import library.' }
    & ./llvm-c-smoke.exe
    if ($LASTEXITCODE -ne 0) { throw 'LLVM-C DLL/import-library compatibility smoke test failed.' }
}
finally {
    Pop-Location
}
