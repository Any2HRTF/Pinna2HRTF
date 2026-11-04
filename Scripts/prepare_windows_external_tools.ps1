param(
    [string]$ExternalRoot = "",
    [string]$Msys2Root = "C:\msys64",
    [string]$Msys2InstallerPath,
    [string]$Msys2InstallerUrl = "https://github.com/msys2/msys2-installer/releases/download/2026-09-27/msys2-x86_64-20260927.exe",
    [switch]$SkipMsys2Install,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$mesh2hrtfCommit = "e45d0436a6fbeca3db13828cbae23ca109225be3"
$pmpCommit = "58283eee4749553345bf4eed74c87c889b03e06c"
if ([string]::IsNullOrWhiteSpace($ExternalRoot)) { $ExternalRoot = Join-Path $root "External" }
$ExternalRoot = [IO.Path]::GetFullPath($ExternalRoot)
$bin = Join-Path $ExternalRoot "bin"
$src = Join-Path $ExternalRoot "src"
$mesh2hrtf = Join-Path $src "Mesh2HRTF"
$grading = Join-Path $src "hrtf_mesh_grading"
$pmp = Join-Path $grading "pmp-library"
$gradingBuild = Join-Path $src "hrtf_mesh_grading-build"
$mesh2input = Join-Path $mesh2hrtf "mesh2hrtf\Mesh2Input\mesh2input.py"
$numCalcPath = Join-Path $bin "NumCalc.exe"
$gradingPath = Join-Path $bin "hrtf_mesh_grading.exe"
$requiredDlls = @("libpmp.dll", "libpmp_vis.dll", "libgcc_s_seh-1.dll", "libstdc++-6.dll", "libwinpthread-1.dll")
$script:gradingCommit = ""
$gradingPinnedCommit = "0bebaaeaf2785ab823dff65523712ceba042e8c0"
$installerSha256 = "416D506C839A2DA4BC184EEEC8CBAAF1055EE698618228C62DFC4232A6970F0E"
$installerSigner = "A9CBF1206F1ECB149C721275F25086B8F886FF79"
$scriptIdentity = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash
$finalBin = $bin
$bin = Join-Path $ExternalRoot (".bin-staging-" + [Guid]::NewGuid().ToString('N'))
$numCalcPath = Join-Path $bin "NumCalc.exe"
$gradingPath = Join-Path $bin "hrtf_mesh_grading.exe"

function Fail([string]$Message) { throw "Windows external preparation failed: $Message" }
function Require-Git {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { $cmd = Get-Command git -ErrorAction SilentlyContinue }
    if (-not $cmd) { Fail "Git for Windows is required and was not found on PATH." }
    return $cmd.Source
}
function Invoke-Git([string[]]$Arguments) {
    & $script:git @Arguments
    if ($LASTEXITCODE -ne 0) { Fail "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
}
function Find-Msys2 {
    $candidates = @($Msys2Root, "C:\msys64") | Select-Object -Unique
    foreach ($candidate in $candidates) {
        # A fresh MSYS2 installation has bash before the UCRT64 packages are installed.
        if (Test-Path (Join-Path $candidate "usr\bin\bash.exe")) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}
function Install-Msys2 {
    if ($SkipMsys2Install) { Fail "MSYS2 UCRT64 was not found. Install MSYS2 or omit -SkipMsys2Install." }
    $installer = if ($Msys2InstallerPath) { [IO.Path]::GetFullPath($Msys2InstallerPath) } else { Join-Path ([IO.Path]::GetTempPath()) "Pinna2HRTF-msys2-x86_64-20260927.exe" }
    if (-not (Test-Path -LiteralPath $installer)) {
        $download = $installer + "." + [Guid]::NewGuid().ToString('N') + ".download"
        try { Invoke-WebRequest -UseBasicParsing -Uri $Msys2InstallerUrl -OutFile $download; Move-Item -LiteralPath $download -Destination $installer }
        finally { if (Test-Path -LiteralPath $download) { Remove-Item -LiteralPath $download } }
    }
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne $installerSha256) { Fail "MSYS2 installer checksum is not the pinned release." }
    $signature = Get-AuthenticodeSignature -LiteralPath $installer
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $installerSigner) { Fail "MSYS2 installer signature/publisher verification failed." }
    Write-Host "Installing MSYS2 to $Msys2Root"
    $proc = Start-Process -FilePath $installer -ArgumentList @("in", "--confirm-command", "--accept-messages", "--root", ('"' + $Msys2Root.TrimEnd('\') + '"')) -Wait -PassThru -WindowStyle Hidden
    if ($proc.ExitCode -ne 0) { Fail "MSYS2 installer exited with code $($proc.ExitCode)." }
    if (-not (Test-Path (Join-Path $Msys2Root "usr\bin\bash.exe"))) { Fail "MSYS2 installation did not produce usr\bin\bash.exe." }
}
function Invoke-Msys2([string]$Command, [hashtable]$Environment = @{}, [switch]$AllowRuntimeRestart) {
    $bash = Join-Path $script:msysRoot "usr\bin\bash.exe"
    $saved = @{}
    $allEnvironment = @{} + $Environment
    $allEnvironment["MSYSTEM"] = "UCRT64"
    $allEnvironment["CHERE_INVOKING"] = "1"
    foreach ($key in $allEnvironment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        [Environment]::SetEnvironmentVariable($key, [string]$allEnvironment[$key], "Process")
    }
    try {
        $previousNativePreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $nativeOutput = @($Command | & $bash -lc 'export PATH="/ucrt64/bin:/usr/bin:$PATH"; bash -s' 2>&1)
            $nativeExit = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousNativePreference }
        $nativeOutput | ForEach-Object { Write-Output $_.ToString() }
        $knownRestart = $AllowRuntimeRestart -and $nativeExit -eq 1 -and ($nativeOutput -join "`n") -match 'To complete this update all MSYS2 processes including this terminal will be closed'
        if ($nativeExit -ne 0 -and -not $knownRestart) { Fail "MSYS2 command failed with exit code ${nativeExit}: $Command" }
        if ($knownRestart) { Write-Host 'MSYS2 completed its core runtime replacement; the next checked step starts a fresh shell.' }
    } finally {
        foreach ($key in $allEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key], "Process") }
    }
}
function Set-GitHttpsRewrite {
    $script:gitEnv = @{}
    foreach ($name in @("GIT_CONFIG_COUNT", "GIT_CONFIG_KEY_0", "GIT_CONFIG_VALUE_0", "GIT_CONFIG_KEY_1", "GIT_CONFIG_VALUE_1")) {
        $script:gitEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    $env:GIT_CONFIG_COUNT = "2"
    $env:GIT_CONFIG_KEY_0 = "url.https://github.com/.insteadOf"
    $env:GIT_CONFIG_VALUE_0 = "git@github.com:"
    $env:GIT_CONFIG_KEY_1 = "url.https://github.com/.insteadOf"
    $env:GIT_CONFIG_VALUE_1 = "ssh://git@github.com/"
}
function Restore-GitRewrite {
    if (-not $script:gitEnv) { return }
    foreach ($name in $script:gitEnv.Keys) { [Environment]::SetEnvironmentVariable($name, $script:gitEnv[$name], "Process") }
}
function Ensure-Checkout([string]$Path, [string]$Url, [string]$Commit, [switch]$Recursive, [string[]]$Submodules = @()) {
    if (-not (Test-Path (Join-Path $Path ".git"))) {
        if ((Test-Path -LiteralPath $Path) -and @(Get-ChildItem -LiteralPath $Path -Force).Count) { Fail "Existing non-repository source folder was preserved: $Path" }
        Invoke-Git @("clone", "--no-recurse-submodules", $Url, $Path)
    }
    Invoke-Git @("-c", "safe.directory=$Path", "-C", $Path, "fetch", "--tags", "origin")
    & $script:git -c "safe.directory=$Path" -C $Path cat-file -e "$Commit^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) { Invoke-Git @("-c", "safe.directory=$Path", "-C", $Path, "fetch", "origin", $Commit) }
    Invoke-Git @("-c", "safe.directory=$Path", "-C", $Path, "checkout", "--detach", $Commit)
    $actualCommit = (& $script:git -C $Path rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualCommit -ne $Commit) { Fail "Checkout identity mismatch: $Path" }
    if ($Recursive) { Invoke-Git @("-c", "safe.directory=$Path", "-C", $Path, "submodule", "update", "--init", "--recursive") }
    if ($Submodules.Count) { Invoke-Git (@("-c", "safe.directory=$Path", "-C", $Path, "submodule", "update", "--init", "--") + $Submodules) }
}
function Ensure-MsysPackages {
    Invoke-Msys2 'pacman --noconfirm -Syuu' -AllowRuntimeRestart
    Invoke-Msys2 'set -e; pacman --noconfirm -Syuu; pacman --noconfirm --needed -S mingw-w64-ucrt-x86_64-toolchain mingw-w64-ucrt-x86_64-cmake mingw-w64-ucrt-x86_64-ninja mingw-w64-ucrt-x86_64-eigen3 make git patch file'
    Invoke-Msys2 'set -e; command -v gcc; command -v cmake; command -v ninja; command -v make; command -v git'
}
function Build-NumCalc {
    $marker = Join-Path $bin "NumCalc.source-commit"
    $keyFile = Join-Path $bin "NumCalc.build-key"
    if (-not $Force -and (Test-Path $keyFile) -and ((Get-Content -Raw -LiteralPath $keyFile).Trim() -eq $script:buildKey) -and (Test-Path $numCalcPath) -and (Test-Path $marker) -and ((Get-Content -Raw $marker).Trim() -eq $mesh2hrtfCommit)) { Write-Host "Reusing validated NumCalc.exe"; return }
    $numSrc = Join-Path $mesh2hrtf "mesh2hrtf\NumCalc\src"
    if (-not (Test-Path (Join-Path $numSrc "Makefile"))) { Fail "NumCalc Makefile is missing in the pinned Mesh2HRTF checkout." }
    Invoke-Msys2 'set -e; src="$(cygpath -u "$P2H_NUMCALC_SRC")"; if compgen -G "$src/*.o" > /dev/null; then make -C "$src" clean; fi; make -C "$src" -j"$(nproc)"' @{ P2H_NUMCALC_SRC = $numSrc }
    $candidate = Get-ChildItem -LiteralPath (Join-Path $mesh2hrtf "mesh2hrtf\NumCalc") -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @("NumCalc", "NumCalc.exe") } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $candidate) { Fail "NumCalc build completed without producing NumCalc or NumCalc.exe." }
    Copy-Item -LiteralPath $candidate.FullName -Destination $numCalcPath -Force
    Set-Content -LiteralPath $marker -Value $mesh2hrtfCommit -NoNewline
    Set-Content -LiteralPath $keyFile -Value $script:buildKey -NoNewline
}
function Apply-GradingCompatibilityPatch {
    $files = @(
        (Join-Path $pmp "src\apps\CMakeLists.txt"),
        (Join-Path $pmp "CMakeLists.txt"),
        (Join-Path $pmp "external\rply\CMakeLists.txt")
    )
    foreach ($cmakeFile in $files) {
        if (-not (Test-Path $cmakeFile)) { continue }
        $text = Get-Content -Raw -LiteralPath $cmakeFile
        $text = [regex]::Replace($text, '(?m)^\s*add_compile_options\(/wd\d+\).*$', '')
        $text = $text -replace 'if\s*\(\s*NOT\s+WIN32\s*\)', 'if(TRUE)'
        Set-Content -LiteralPath $cmakeFile -Value $text -NoNewline
    }
}
function Build-Grading {
    $sourceCommit = (& $script:git -c "safe.directory=$grading" -C $grading rev-parse HEAD).Trim()
    $marker = Join-Path $bin "hrtf_mesh_grading.source-commit"
    $keyFile = Join-Path $bin "hrtf_mesh_grading.build-key"
    if (-not $Force -and (Test-Path $keyFile) -and ((Get-Content -Raw -LiteralPath $keyFile).Trim() -eq $script:buildKey) -and (Test-Path $gradingPath) -and (Test-Path $marker) -and ((Get-Content -Raw $marker).Trim() -eq $sourceCommit)) { Write-Host "Reusing validated hrtf_mesh_grading.exe" }
    else {
        if (-not (Test-Path (Join-Path $pmp "CMakeLists.txt"))) { Fail "PMP library checkout has no CMakeLists.txt." }
        Apply-GradingCompatibilityPatch
        if (Test-Path $gradingBuild) { Move-Item -LiteralPath $gradingBuild -Destination ($gradingBuild + ".previous-" + [Guid]::NewGuid().ToString("N")) }
        New-Item -ItemType Directory -Path $gradingBuild -Force | Out-Null
        Invoke-Msys2 'cmake -S "$(cygpath -u "$P2H_PMP_SRC")" -B "$(cygpath -u "$P2H_GRADING_BUILD")" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DPMP_BUILD_TESTS=OFF -DPMP_BUILD_DOCS=OFF -DPMP_BUILD_EXAMPLES=OFF -Wno-dev && cmake --build "$(cygpath -u "$P2H_GRADING_BUILD")" --target hrtf_mesh_grading pmp_vis --parallel' @{ P2H_PMP_SRC = $pmp; P2H_GRADING_BUILD = $gradingBuild }
        $gradingExe = Get-ChildItem -LiteralPath $gradingBuild -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "hrtf_mesh_grading.exe" -or $_.Name -eq "hrtf-mesh-grading.exe" } | Select-Object -First 1
        if (-not $gradingExe) { Fail "CMake finished without producing hrtf_mesh_grading.exe." }
        Copy-Item -LiteralPath $gradingExe.FullName -Destination $gradingPath -Force
    }
    Set-Content -LiteralPath $keyFile -Value $script:buildKey -NoNewline
    $script:gradingCommit = $sourceCommit
    $optional = Get-ChildItem -LiteralPath $gradingBuild -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq "mpview.exe" } | Select-Object -First 1
    if ($optional) { Copy-Item -LiteralPath $optional.FullName -Destination (Join-Path $bin "mpview.exe") -Force }
}
function Copy-RuntimeDlls {
    foreach ($name in $requiredDlls) {
        $destination = Join-Path $bin $name
        $source = Join-Path $script:msysRoot "ucrt64\bin\$name"
        if (-not (Test-Path $source)) { $source = Get-ChildItem -LiteralPath $src -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1 | ForEach-Object FullName }
        if (-not $source -and (Test-Path $destination) -and -not $Force) { $source = $destination }
        if (-not $source -or -not (Test-Path $source)) { Fail "Required runtime DLL was not found: $name" }
        Copy-Item -LiteralPath $source -Destination $destination -Force
    }
}
function Get-NativeCommandOutput([string]$Path, [string[]]$Arguments = @()) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = (& $Path @Arguments 2>&1 | Out-String)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    return [PSCustomObject]@{ Output = $output; ExitCode = $exitCode }
}
function Validate-Outputs {
    $required = @("NumCalc.exe", "hrtf_mesh_grading.exe") + $requiredDlls
    foreach ($name in $required) { if (-not (Test-Path (Join-Path $bin $name))) { Fail "Missing output: $(Join-Path $bin $name)" } }
    if (-not (Test-Path $mesh2input)) { Fail "Missing Mesh2HRTF source: $mesh2input" }
    $numCalcHelp = Get-NativeCommandOutput $numCalcPath @("-h")
    $help = $numCalcHelp.Output
    if ($numCalcHelp.ExitCode -notin @(0,1)) { Fail "NumCalc help failed with exit code $($numCalcHelp.ExitCode)." }
    if ($help -notmatch "-adapt_fmmlength") { Fail "NumCalc -h does not advertise -adapt_fmmlength." }
    $gradingRun = Get-NativeCommandOutput $gradingPath
    $gradingHelp = $gradingRun.Output
    if ($gradingHelp -match "(missing|not found).*\.dll|DLL not found") { Fail "hrtf_mesh_grading.exe reported a missing DLL: $gradingHelp" }
    if ([string]::IsNullOrWhiteSpace($gradingHelp)) { Fail "hrtf_mesh_grading.exe produced no output (exit code $($gradingRun.ExitCode))." }
    if ($gradingHelp -notmatch "Example usage|Parameters") { Fail "hrtf_mesh_grading.exe did not print its usage information (exit code $($gradingRun.ExitCode)): $gradingHelp" }
    Invoke-Msys2 'for f in "$P2H_NUMCALC" "$P2H_GRADING"; do info="$(file "$(cygpath -u "$f")")"; echo "$info"; echo "$info" | grep -E "PE32\\+.*x86-64" >/dev/null || { echo "not a 64-bit Windows binary: $f"; exit 1; }; ldd "$(cygpath -u "$f")" | grep "not found" && exit 1 || true; done' @{ P2H_NUMCALC = $numCalcPath; P2H_GRADING = $gradingPath }
    Set-Content -LiteralPath (Join-Path $bin "hrtf_mesh_grading.source-commit") -Value $script:gradingCommit -NoNewline
    $manifest = [ordered]@{ mesh2hrtf = $mesh2hrtfCommit; pmp = $pmpCommit; hrtf_mesh_grading = $script:gradingCommit; toolchain = "MSYS2 UCRT64"; generated_utc = [DateTime]::UtcNow.ToString("o") }
    $manifest['build_key'] = $script:buildKey
    $manifest['packages'] = $script:resolvedPackages
    $manifest['installer_url'] = $Msys2InstallerUrl
    $manifest['installer_sha256'] = $installerSha256
    $manifest['binaries'] = @{}; Get-ChildItem -LiteralPath $bin -File | Where-Object { $_.Extension -in @('.exe','.dll') } | ForEach-Object { $manifest['binaries'][$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $bin "external-build-manifest.json")
}

New-Item -ItemType Directory -Path $bin, $src -Force | Out-Null
$script:git = Require-Git
$script:msysRoot = Find-Msys2
if (-not $script:msysRoot) { Install-Msys2; $script:msysRoot = Find-Msys2 }
if (-not $script:msysRoot) { Fail "MSYS2 UCRT64 could not be located after installation." }
Set-GitHttpsRewrite
try {
    Ensure-MsysPackages
    $script:resolvedPackages = @(Invoke-Msys2 'pacman -Q')
    $buildIdentityText = "$mesh2hrtfCommit|$gradingPinnedCommit|$pmpCommit|$scriptIdentity|" + ($script:resolvedPackages -join "`n")
    $script:buildKey = [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($buildIdentityText))).Replace("-", "")
    if (-not (Test-Path (Join-Path $script:msysRoot "ucrt64\bin\gcc.exe"))) { Fail "MSYS2 UCRT64 GCC was not installed successfully." }
    Ensure-Checkout $mesh2hrtf "https://github.com/Any2HRTF/Mesh2HRTF.git" $mesh2hrtfCommit
    Ensure-Checkout $grading "https://github.com/cg-tub/hrtf_mesh_grading.git" $gradingPinnedCommit
    Ensure-Checkout $pmp "https://github.com/cg-tub/pmp-library.git" $pmpCommit -Submodules @('external/eigen','external/glfw')
    if (Test-Path -LiteralPath $finalBin) { Get-ChildItem -LiteralPath $finalBin -File | Copy-Item -Destination $bin }
    Build-NumCalc
    Build-Grading
    Copy-RuntimeDlls
    Validate-Outputs
    $previousBin = $finalBin + ".previous-" + [Guid]::NewGuid().ToString('N')
    if (Test-Path -LiteralPath $finalBin) { Move-Item -LiteralPath $finalBin -Destination $previousBin }
    try { Move-Item -LiteralPath $bin -Destination $finalBin }
    catch { if ((Test-Path -LiteralPath $previousBin) -and -not (Test-Path -LiteralPath $finalBin)) { Move-Item -LiteralPath $previousBin -Destination $finalBin }; throw }
} finally { Restore-GitRewrite }
Write-Host "Windows external tools prepared and validated in $ExternalRoot"
