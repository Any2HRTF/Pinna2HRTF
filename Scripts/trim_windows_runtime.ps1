param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageRoot).Path.TrimEnd('\')
if (Test-Path -LiteralPath (Join-Path $package '.git')) { throw 'Runtime trimming must target a packaged app, not a Git checkout.' }

function Assert-PackagePath([string]$Path) {
    $absolute = [IO.Path]::GetFullPath($Path)
    if (-not $absolute.StartsWith($package + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Runtime trim path escapes the package: $absolute" }
    $current = $absolute
    while ($current -and $current -ne $package) {
        if ((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "Linked runtime paths cannot be trimmed: $current"
        }
        $current = Split-Path $current -Parent
    }
    if ((Get-Item -LiteralPath $package -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked package roots cannot be trimmed.' }
}

$torch = Join-Path $package '.venv\Lib\site-packages\torch'
$libraries = Join-Path $torch 'lib'
$headers = Join-Path $torch 'include'
Assert-PackagePath $libraries
if (-not (Test-Path -LiteralPath (Join-Path $torch '__init__.py')) -or -not (Test-Path -LiteralPath (Join-Path $libraries 'torch_cpu.dll'))) {
    throw 'The packaged CPU PyTorch runtime is incomplete.'
}

# Ship prebuilt inference, not the C++ extension SDK. Keep every DLL, Python
# extension, license and metadata file; limit removal to these exact locations.
$developmentLibraries = @(Get-ChildItem -LiteralPath $libraries -File -Filter '*.lib' -Force)
foreach ($file in $developmentLibraries) { Assert-PackagePath $file.FullName }
$headerItems = @()
if (Test-Path -LiteralPath $headers) {
    Assert-PackagePath $headers
    $headerItems = @(Get-ChildItem -LiteralPath $headers -Recurse -Force)
    if (@($headerItems | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Linked PyTorch headers cannot be trimmed.' }
}
$headerFiles = @($headerItems | Where-Object { -not $_.PSIsContainer })
$removedBytes = [long](($developmentLibraries | Measure-Object Length -Sum).Sum) + [long](($headerFiles | Measure-Object Length -Sum).Sum)
foreach ($file in $developmentLibraries) { Remove-Item -LiteralPath $file.FullName -Force }
if (Test-Path -LiteralPath $headers) { Remove-Item -LiteralPath $headers -Recurse -Force }
$report = [ordered]@{
    policy = 'PyTorch runtime only; omit torch/lib/*.lib and torch/include'
    removed_bytes = $removedBytes
    development_libraries_removed = $developmentLibraries.Count
    headers_removed = $headerFiles.Count
}
[IO.File]::WriteAllText((Join-Path $package 'runtime-pruning.json'), ($report | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
Write-Output ("Removed {0:N1} MB of PyTorch development files." -f ($removedBytes / 1000000))
