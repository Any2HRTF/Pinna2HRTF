param(
    [switch]$SkipPythonEnvironment,
    [switch]$AllowMissingExternalTools
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$windowsProject = Join-Path $root "Sources\Pinna2HRTF.Windows"
$dist = Join-Path $root "dist\windows\Pinna2HRTF"
$publish = Join-Path $windowsProject "bin\Release\net8.0-windows10.0.19041.0\win-x64\publish"
$distExternal = Join-Path $dist "External"
$distBin = Join-Path $distExternal "bin"
$dotnet = Get-Command "dotnet.exe" -ErrorAction SilentlyContinue
if (-not $dotnet) {
    $dotnet = Get-Command "dotnet" -ErrorAction SilentlyContinue
}
$dotnetPath = if ($dotnet) { $dotnet.Source } else { "" }
if (-not $dotnet) {
    $localDotnet = Join-Path $root ".dotnet\dotnet.exe"
    if (Test-Path $localDotnet) {
        $dotnetPath = $localDotnet
    }
}
if (-not $dotnetPath) {
    throw "dotnet is not on PATH and .dotnet\dotnet.exe was not found."
}

if (Test-Path $dist) {
    Remove-Item $dist -Recurse -Force
}

& $dotnetPath publish (Join-Path $windowsProject "Pinna2HRTF.Windows.csproj") -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false

New-Item -ItemType Directory -Path $dist | Out-Null
Copy-Item (Join-Path $publish "*") $dist -Recurse -Force
Copy-Item (Join-Path $root "HRTFCalculation") (Join-Path $dist "HRTFCalculation") -Recurse -Force
Copy-Item (Join-Path $root "pyproject.toml") (Join-Path $dist "pyproject.toml") -Force
Copy-Item (Join-Path $root "ProjectSettingHelp.json") (Join-Path $dist "ProjectSettingHelp.json") -Force

if (-not (Test-Path (Join-Path $root "uv.lock"))) {
    throw "uv.lock is required to build the portable Windows app."
}
Copy-Item (Join-Path $root "uv.lock") (Join-Path $dist "uv.lock") -Force

New-Item -ItemType Directory -Path $distBin -Force | Out-Null
$sourceExternal = Join-Path $root "External"
foreach ($name in @("NumCalc.exe", "NumCalc.source-commit", "hrtf_mesh_grading.exe")) {
    $source = Join-Path (Join-Path $sourceExternal "bin") $name
    if (Test-Path $source) {
        Copy-Item $source (Join-Path $distBin $name) -Force
    }
}
$sourceMesh2Hrtf = Join-Path $sourceExternal "src\Mesh2HRTF"
$distMesh2Hrtf = Join-Path $distExternal "src\Mesh2HRTF"
if (Test-Path (Join-Path $sourceMesh2Hrtf "mesh2hrtf")) {
    New-Item -ItemType Directory -Path $distMesh2Hrtf -Force | Out-Null
    Copy-Item (Join-Path $sourceMesh2Hrtf "mesh2hrtf") (Join-Path $distMesh2Hrtf "mesh2hrtf") -Recurse -Force
    if (Test-Path (Join-Path $sourceMesh2Hrtf "VERSION")) {
        Copy-Item (Join-Path $sourceMesh2Hrtf "VERSION") (Join-Path $distMesh2Hrtf "VERSION") -Force
    }
}

$uvCommand = Get-Command "uv.exe" -ErrorAction SilentlyContinue
if (-not $uvCommand) {
    $uvCommand = Get-Command "uv" -ErrorAction SilentlyContinue
}
$uv = if ($uvCommand) { $uvCommand.Source } else { "" }

if (-not $SkipPythonEnvironment) {
    if ([string]::IsNullOrWhiteSpace($uv)) {
        throw "uv is not on PATH. Install uv before building the portable runtime, or pass -SkipPythonEnvironment for a shell-only build."
    }

    Push-Location $dist
    try {
        $env:UV_CACHE_DIR = Join-Path $root ".uv-cache"
        $env:UV_PYTHON_INSTALL_DIR = Join-Path $dist "Python"
        $env:UV_VENV_RELOCATABLE = "1"
        $env:GIT_CONFIG_COUNT = "1"
        $env:GIT_CONFIG_KEY_0 = "url.https://github.com/.insteadOf"
        $env:GIT_CONFIG_VALUE_0 = "git@github.com:"
        & $uv sync --locked --no-dev --no-install-project --managed-python --python 3.11
        if ($LASTEXITCODE -ne 0) {
            throw "uv sync failed with exit code $LASTEXITCODE"
        }

        $venvPython = Join-Path $dist ".venv\Scripts\python.exe"
        if (-not (Test-Path $venvPython)) {
            throw "uv sync did not create .venv\Scripts\python.exe"
        }

        $pythonHome = & $venvPython -c "from pathlib import Path; import sys; print(Path(sys.base_prefix).resolve())"
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $pythonHome)) {
            throw "Could not resolve the managed Python runtime used by the virtual environment."
        }
        $pythonHome = (Resolve-Path $pythonHome).Path

        if (-not $pythonHome.StartsWith((Join-Path $dist "Python"), [StringComparison]::OrdinalIgnoreCase)) {
            $pythonBundle = Join-Path (Join-Path $dist "Python") (Split-Path $pythonHome -Leaf)
            if (Test-Path $pythonBundle) {
                Remove-Item $pythonBundle -Recurse -Force
            }
            New-Item -ItemType Directory -Path (Split-Path $pythonBundle -Parent) -Force | Out-Null
            Copy-Item $pythonHome $pythonBundle -Recurse -Force
            $pythonHome = $pythonBundle
        }

        $pyvenv = Join-Path $dist ".venv\pyvenv.cfg"
        if (Test-Path $pyvenv) {
            $pythonHomeName = Split-Path $pythonHome -Leaf
            $relativePythonHome = "..\Python\$pythonHomeName"
            $relativePythonExe = "$relativePythonHome\python.exe"
            $lines = Get-Content $pyvenv | ForEach-Object {
                if ($_ -like "home = *") { "home = $relativePythonHome" }
                elseif ($_ -like "base-executable = *") { "base-executable = $relativePythonExe" }
                elseif ($_ -like "base-prefix = *") { "base-prefix = $relativePythonHome" }
                elseif ($_ -like "base-exec-prefix = *") { "base-exec-prefix = $relativePythonHome" }
                elseif ($_ -like "uv = *") { $null }
                else { $_ }
            }
            Set-Content -Path $pyvenv -Value $lines -Encoding UTF8
        }
        Get-ChildItem (Join-Path $dist ".venv\Scripts") -Force | Where-Object { $_.Name -notmatch '^python(w|3|3\.11)?\.exe$' } | Remove-Item -Recurse -Force
    }
    finally {
        Pop-Location
    }
}

Get-ChildItem $dist -Directory -Recurse -Force | Where-Object { $_.Name -eq "__pycache__" } | Sort-Object { $_.FullName.Length } -Descending | Remove-Item -Recurse -Force
Get-ChildItem $dist -File -Recurse -Force | Where-Object { $_.Extension -in @(".pyc", ".pyo") } | Remove-Item -Force
if (Test-Path (Join-Path $distBin "uv.exe")) {
    throw "uv.exe must not be included in the portable Windows app."
}

$missingExternalTools = @("NumCalc.exe", "hrtf_mesh_grading.exe") | Where-Object {
    -not (Test-Path (Join-Path $distBin $_))
}
if ($missingExternalTools.Count -gt 0) {
    $message = "Missing Windows external tool(s): $($missingExternalTools -join ', '). Run Scripts\prepare_windows_external_tools.ps1 before building the portable app."
    if ($AllowMissingExternalTools) {
        Write-Warning $message
    } else {
        throw $message
    }
}

$mesh2input = Join-Path $distExternal "src\Mesh2HRTF\mesh2hrtf\Mesh2Input\mesh2input.py"
if (-not (Test-Path $mesh2input)) {
    throw "Missing Mesh2HRTF sources: $mesh2input. Run Scripts\prepare_windows_external_tools.ps1 before building the portable app."
}

Copy-Item (Join-Path $root "README.md") (Join-Path $dist "README.md") -Force
Write-Host "Windows portable app written to $dist"
