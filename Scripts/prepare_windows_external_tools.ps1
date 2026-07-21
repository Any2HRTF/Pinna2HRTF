param(
    [string]$ExternalRoot = ""
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
if ([string]::IsNullOrWhiteSpace($ExternalRoot)) {
    $ExternalRoot = Join-Path $root "External"
}

$bin = Join-Path $ExternalRoot "bin"
$src = Join-Path $ExternalRoot "src"
$tools = Join-Path $src "mesh2hrtf-tools"
$mesh2hrtf = Join-Path $src "Mesh2HRTF"
$mesh2input = Join-Path $mesh2hrtf "mesh2hrtf\Mesh2Input\mesh2input.py"

New-Item -ItemType Directory -Path $bin -Force | Out-Null
New-Item -ItemType Directory -Path $src -Force | Out-Null

if (-not (Test-Path $mesh2input)) {
    if (Test-Path $mesh2hrtf) {
        Remove-Item $mesh2hrtf -Recurse -Force
    }
    $git = Get-Command "git.exe" -ErrorAction SilentlyContinue
    if (-not $git) {
        $git = Get-Command "git" -ErrorAction SilentlyContinue
    }
    if (-not $git) {
        throw "git is required to download Mesh2HRTF sources."
    }
    & $git.Source clone --depth 1 "https://github.com/Any2HRTF/Mesh2HRTF.git" $mesh2hrtf
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $mesh2input)) {
        throw "Could not prepare Mesh2HRTF sources at $mesh2hrtf."
    }
}

$uv = Join-Path $bin "uv.exe"
if (-not (Test-Path $uv)) {
    $uvCommand = Get-Command "uv.exe" -ErrorAction SilentlyContinue
    if (-not $uvCommand) {
        throw "uv.exe is not on PATH. Install uv before preparing Windows external tools."
    }
    Copy-Item $uvCommand.Source $uv -Force
}

$needsNumCalc = -not (Test-Path (Join-Path $bin "NumCalc.exe"))
$needsGrading = -not (Test-Path (Join-Path $bin "hrtf_mesh_grading.exe"))
if ($needsNumCalc -or $needsGrading) {
    $svn = Get-Command "svn.exe" -ErrorAction SilentlyContinue
    if (-not $svn) {
        $svn = Get-Command "svn" -ErrorAction SilentlyContinue
    }
    if ($svn) {
        if (Test-Path $tools) {
            Remove-Item $tools -Recurse -Force
        }
        New-Item -ItemType Directory -Path $tools -Force | Out-Null

        & $svn.Source export --force "https://svn.code.sf.net/p/mesh2hrtf-tools/code/NumCalc_WindowsExe" (Join-Path $tools "NumCalc_WindowsExe")
        if ($LASTEXITCODE -ne 0) {
            throw "Could not export NumCalc_WindowsExe from mesh2hrtf-tools."
        }

        & $svn.Source export --force "https://svn.code.sf.net/p/mesh2hrtf-tools/code/hrtf_mesh_grading_WindowsExe/bin" (Join-Path $tools "hrtf_mesh_grading_WindowsExe\bin")
        if ($LASTEXITCODE -ne 0) {
            throw "Could not export hrtf_mesh_grading_WindowsExe from mesh2hrtf-tools."
        }

        $numCalc = Get-ChildItem (Join-Path $tools "NumCalc_WindowsExe") -Recurse -File -Filter "NumCalc.exe" | Select-Object -First 1
        if (-not $numCalc) {
            throw "The downloaded Mesh2HRTF tools did not contain NumCalc.exe."
        }
        Copy-Item $numCalc.FullName (Join-Path $bin "NumCalc.exe") -Force

        Get-ChildItem (Join-Path $tools "hrtf_mesh_grading_WindowsExe\bin") -File | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $bin $_.Name) -Force
        }
    } else {
        $numCalcFiles = @(
            "- run_NumCalc_instance.bat",
            "NumCalc.exe",
            "libgcc_s_seh-1.dll",
            "libstdc++-6.dll",
            "libwinpthread-1.dll",
            "readme.txt"
        )
        foreach ($name in $numCalcFiles) {
            $encoded = [Uri]::EscapeDataString($name).Replace("%2B", "%2B")
            Invoke-WebRequest -Uri "https://sourceforge.net/p/mesh2hrtf-tools/code/ci/master/tree/NumCalc_WindowsExe/$encoded`?format=raw" -OutFile (Join-Path $bin $name) -UseBasicParsing
        }

        $gradingFiles = @(
            "hrtf_mesh_grading.exe",
            "libgcc_s_seh-1.dll",
            "libpmp.dll",
            "libpmp_vis.dll",
            "libstdc++-6.dll",
            "libwinpthread-1.dll",
            "mpview.exe"
        )
        foreach ($name in $gradingFiles) {
            $encoded = [Uri]::EscapeDataString($name).Replace("%2B", "%2B")
            Invoke-WebRequest -Uri "https://sourceforge.net/p/mesh2hrtf-tools/code/ci/master/tree/hrtf_mesh_grading_WindowsExe/bin/$encoded`?format=raw" -OutFile (Join-Path $bin $name) -UseBasicParsing
        }
    }
}

$required = @("uv.exe", "NumCalc.exe", "hrtf_mesh_grading.exe")
foreach ($name in $required) {
    $path = Join-Path $bin $name
    if (-not (Test-Path $path)) {
        throw "Missing Windows external tool: $path"
    }
}

Write-Host "Windows external tools and Mesh2HRTF sources prepared in $ExternalRoot"
