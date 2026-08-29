param(
    [string]$ExternalRoot = ""
)

$ErrorActionPreference = "Stop"

$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$mesh2hrtfCommit = "e45d0436a6fbeca3db13828cbae23ca109225be3"
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

if (-not (Test-Path (Join-Path $mesh2hrtf ".git"))) {
    throw "Mesh2HRTF source checkout is not a Git repository: $mesh2hrtf"
}
$git = Get-Command "git.exe" -ErrorAction SilentlyContinue
if (-not $git) {
    $git = Get-Command "git" -ErrorAction SilentlyContinue
}
if (-not $git) {
    throw "git is required to verify Mesh2HRTF source revision."
}
& $git.Source -c safe.directory="$mesh2hrtf" -C $mesh2hrtf cat-file -e "$mesh2hrtfCommit^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    & $git.Source -c safe.directory="$mesh2hrtf" -C $mesh2hrtf fetch --depth 1 origin $mesh2hrtfCommit
    if ($LASTEXITCODE -ne 0) { throw "Could not fetch Mesh2HRTF commit $mesh2hrtfCommit." }
}
& $git.Source -c safe.directory="$mesh2hrtf" -C $mesh2hrtf checkout --detach $mesh2hrtfCommit
if ($LASTEXITCODE -ne 0) { throw "Could not check out Mesh2HRTF commit $mesh2hrtfCommit." }

$uv = Join-Path $bin "uv.exe"
if (-not (Test-Path $uv)) {
    $uvCommand = Get-Command "uv.exe" -ErrorAction SilentlyContinue
    if (-not $uvCommand) {
        throw "uv.exe is not on PATH. Install uv before preparing Windows external tools."
    }
    Copy-Item $uvCommand.Source $uv -Force
}

$numCalcPath = Join-Path $bin "NumCalc.exe"
if (-not (Test-Path $numCalcPath)) {
    throw "NumCalc.exe is not bundled. Build it from Mesh2HRTF commit $mesh2hrtfCommit and place it at $numCalcPath."
}
$help = (& $numCalcPath -h 2>&1 | Out-String)
if ($LASTEXITCODE -ne 0 -or $help -notmatch "-adapt_fmmlength") {
    throw "Bundled NumCalc.exe does not support the required Mesh2HRTF $mesh2hrtfCommit feature -adapt_fmmlength."
}
$revisionFile = Join-Path $bin "NumCalc.source-commit"
if (-not (Test-Path $revisionFile) -or ((Get-Content -Raw $revisionFile).Trim() -ne $mesh2hrtfCommit)) {
    throw "NumCalc.source-commit is missing or does not match Mesh2HRTF $mesh2hrtfCommit."
}

$required = @("uv.exe", "NumCalc.exe", "hrtf_mesh_grading.exe")
foreach ($name in $required) {
    $path = Join-Path $bin $name
    if (-not (Test-Path $path)) {
        throw "Missing Windows external tool: $path"
    }
}

Write-Host "Windows external tools and Mesh2HRTF sources prepared in $ExternalRoot"
