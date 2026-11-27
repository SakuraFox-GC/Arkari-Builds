[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallDir,
    [ValidateSet('Release', 'Debug')][string]$BuildType = 'Release'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $true
$compiler = Join-Path $InstallDir 'bin/clang-cl.exe'
$runtimeFlag = if ($BuildType -eq 'Debug') { '/MTd' } else { '/MT' }
$fixtureDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'tests/smoke'
$testDir = Join-Path $env:RUNNER_TEMP 'arkari-smoke/protection'
New-Item -ItemType Directory -Force $testDir | Out-Null
Copy-Item "$fixtureDir/*" $testDir -Force
$env:PATH = "$(Join-Path $InstallDir 'bin');$env:PATH"

function Invoke-SmokeProgram([string]$File, [string]$InputValue) {
    $process = [Diagnostics.Process]::new()
    $process.StartInfo.FileName = $File
    $process.StartInfo.WorkingDirectory = $testDir
    $process.StartInfo.ArgumentList.Add($InputValue)
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) {
            $process.Kill($true)
            throw "$File timed out for input $InputValue."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0) {
            throw "$File failed for input $InputValue (exit $($process.ExitCode)): $stderr"
        }
        if (-not $stdout.StartsWith('Arkari full protection smoke: OK ')) {
            throw "$File produced unexpected output for input $InputValue`: $stdout"
        }
        return $stdout
    }
    finally {
        $process.Dispose()
    }
}

Push-Location $testDir
try {
    $commonArgs = @('/nologo', '/O2', $runtimeFlag, '/EHsc', '/GR', '/std:c++17',
        '/clang:-fuse-ld=lld', 'protection-main.cpp', 'protection-worker.cpp')
    & $compiler @commonArgs /Fe:baseline.exe
    if ($LASTEXITCODE -ne 0) { throw 'Compiling the protection baseline failed.' }

    Write-Host 'Enabling all eight Arkari protections, with configurable levels set to 3.'
    $config = Join-Path $testDir 'full-protection.json'
    & $compiler @commonArgs /clang:-mllvm /clang:-irobf /clang:-mllvm "/clang:-arkari-cfg=$config" /Fe:protected.exe
    if ($LASTEXITCODE -ne 0) { throw 'Compiling with all Arkari protections enabled failed.' }

    # Confirm that string encryption and RTTI erasure actually transformed the
    # fixture, rather than only accepting flags without running the passes.
    $baselineBytes = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("$testDir/baseline.exe"))
    $protectedBytes = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes("$testDir/protected.exe"))
    foreach ($plaintext in @('ARKARI_PROTECTED_LITERAL_7D2BC640', '.?AUSmokeDerived@@')) {
        if (-not $baselineBytes.Contains($plaintext)) { throw "Baseline lacks the expected protection fixture: $plaintext" }
        if ($protectedBytes.Contains($plaintext)) { throw "Protection did not remove the plaintext fixture: $plaintext" }
    }

    $results = foreach ($value in @('0', '1', '2', '7', '19', '44', '97', '256')) {
        $expected = Invoke-SmokeProgram "$testDir/baseline.exe" $value
        $actual = Invoke-SmokeProgram "$testDir/protected.exe" $value
        if ($actual -cne $expected) { throw "Protected output differs from baseline for input $value`: $actual / $expected" }
        Write-Host $actual
        [ordered]@{ input = $value; output = $actual }
    }
    [ordered]@{
        application = 'Inventory CSV parser, sorter and summary'
        build_type = $BuildType
        protections = Get-Content $config -Raw | ConvertFrom-Json
        cases = @($results)
        string_encryption_verified = $true
        rtti_erasure_verified = $true
        cross_translation_unit_rtti_and_exceptions_verified = $true
        file_io_strings_containers_and_sorting_verified = $true
    } | ConvertTo-Json -Depth 6 | Set-Content "$testDir/results.json" -Encoding utf8
    Write-Host 'All-protections compile/link/runtime smoke test passed.'
}
finally {
    Pop-Location
}
