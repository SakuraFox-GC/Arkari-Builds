[CmdletBinding()]
param([Parameter(Mandatory)][string]$SourceDir)

$ErrorActionPreference = 'Stop'
$path = Join-Path $SourceDir 'llvm/tools/llvm-shlib/gen-msvc-exports.py'
$text = Get-Content $path -Raw
$old = 'r"^\w+\s+T\s+'
$fixed = 'r"^[0-9A-Fa-f-]+\s+T\s+'
$oldCount = [regex]::Matches($text, [regex]::Escape($old)).Count
$fixedCount = [regex]::Matches($text, [regex]::Escape($fixed)).Count
if ($oldCount -eq 2) {
    # llvm-nm prints dashes instead of a numeric address for bitcode symbols.
    # Match both COFF addresses and bitcode's unknown addresses.
    [IO.File]::WriteAllText($path, $text.Replace($old, $fixed), [Text.UTF8Encoding]::new($false))
    Write-Host 'Patched LLVM-C export generation to accept bitcode symbol addresses.'
} elseif ($fixedCount -ne 2) {
    throw 'The LLVM-C export generator changed; review the bitcode address patch.'
}
'llvm-c-bitcode-export-addresses'
