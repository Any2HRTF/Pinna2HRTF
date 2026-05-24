param(
    [switch]$SkipPythonEnvironment,
    [switch]$AllowMissingExternalTools
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$windowsProject = Join-Path $root "Sources\Pinna2HRTF.Windows"
$dist = Join-Path $root "dist\windows\Pinna2HRTF"
$publish = Join-Path $windowsProject "bin\Release\net8.0-windows\win-x64\publish"
$distExternal = Join-Path $dist "External"
$distBin = Join-Path $distExternal "bin"

if (Test-Path $dist) {
    Remove-Item $dist -Recurse -Force
}

dotnet publish (Join-Path $windowsProject "Pinna2HRTF.Windows.csproj") -c Release -r win-x64 --self-contained true -p:PublishSingleFile=false

New-Item -ItemType Directory -Path $dist | Out-Null
Copy-Item (Join-Path $publish "*") $dist -Recurse -Force
Copy-Item (Join-Path $root "HRTFCalculation") (Join-Path $dist "HRTFCalculation") -Recurse -Force
Copy-Item (Join-Path $root "pyproject.toml") (Join-Path $dist "pyproject.toml") -Force

if (Test-Path (Join-Path $root "uv.lock")) {
    Copy-Item (Join-Path $root "uv.lock") (Join-Path $dist "uv.lock") -Force
}

if (Test-Path (Join-Path $root "External")) {
    Copy-Item (Join-Path $root "External") $distExternal -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $distBin | Out-Null
}

$uv = Join-Path $distBin "uv.exe"
if (-not (Test-Path $uv)) {
    $uvCommand = Get-Command "uv.exe" -ErrorAction SilentlyContinue
    if ($uvCommand) {
        Copy-Item $uvCommand.Source $uv -Force
    }
}

if (-not $SkipPythonEnvironment) {
    if (-not (Test-Path $uv)) {
        throw "uv.exe was not found in External\bin or on PATH. Install uv before building the portable runtime, or pass -SkipPythonEnvironment for a shell-only build."
    }

    Push-Location $dist
    try {
        $env:UV_CACHE_DIR = Join-Path $root ".uv-cache"
        $env:UV_PYTHON_INSTALL_DIR = Join-Path $dist "Python"
        $env:UV_VENV_RELOCATABLE = "1"
        $env:GIT_CONFIG_COUNT = "1"
        $env:GIT_CONFIG_KEY_0 = "url.https://github.com/.insteadOf"
        $env:GIT_CONFIG_VALUE_0 = "git@github.com:"
        & $uv sync --no-dev --managed-python --python 3.11
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
                else { $_ }
            }
            Set-Content -Path $pyvenv -Value $lines -Encoding UTF8
        }
    }
    finally {
        Pop-Location
    }
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

Copy-Item (Join-Path $root "README.md") (Join-Path $dist "README.md") -Force
Write-Host "Windows portable app written to $dist"
