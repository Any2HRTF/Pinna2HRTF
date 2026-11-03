param([string]$BasePackage, [string]$OutputDirectory, [string]$ExternalRoot)
$ErrorActionPreference = 'Stop'
$source = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
if (-not $BasePackage) {
    foreach ($parent in @((Split-Path $source -Parent), (Split-Path (Split-Path $source -Parent) -Parent))) {
        $candidate = Join-Path $parent 'Pinna2HRTF_v2.0.0-review-macimitation-ui7'
        if (Test-Path -LiteralPath $candidate) { $BasePackage = $candidate; break }
    }
}
if (-not $BasePackage) { throw 'Provide a complete existing portable build through -BasePackage.' }
if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Split-Path $BasePackage -Parent) 'Pinna2HRTF_v2.0.0-review-main-macimitation' }
& (Join-Path $PSScriptRoot 'build_windows_port.ps1') -RuntimePackage $BasePackage -OutputDirectory $OutputDirectory -ExternalRoot $ExternalRoot -MacImitation
if (-not $?) { throw 'Mac-imitation packaging failed.' }
