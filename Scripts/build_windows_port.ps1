$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$dist = Join-Path $root "dist\windows\Pinna2HRTF"
$publish = Join-Path $root "Pinna2HRTF.Windows\bin\Release\net8.0-windows\win-x64\publish"

if (Test-Path $dist) {
    Remove-Item $dist -Recurse -Force
}

dotnet publish (Join-Path $root "Pinna2HRTF.Windows\Pinna2HRTF.Windows.csproj") -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false

New-Item -ItemType Directory -Path $dist | Out-Null
Copy-Item (Join-Path $publish "*") $dist -Recurse -Force
Copy-Item (Join-Path $root "HRTFCalculation") (Join-Path $dist "HRTFCalculation") -Recurse -Force
Copy-Item (Join-Path $root "pyproject.toml") (Join-Path $dist "pyproject.toml") -Force

if (Test-Path (Join-Path $root "uv.lock")) {
    Copy-Item (Join-Path $root "uv.lock") (Join-Path $dist "uv.lock") -Force
}

if (Test-Path (Join-Path $root "External")) {
    Copy-Item (Join-Path $root "External") (Join-Path $dist "External") -Recurse -Force
} else {
    New-Item -ItemType Directory -Path (Join-Path $dist "External\bin") | Out-Null
}

Copy-Item (Join-Path $root "README-Windows.md") (Join-Path $dist "README-Windows.md") -Force
Write-Host "Windows portable app written to $dist"
