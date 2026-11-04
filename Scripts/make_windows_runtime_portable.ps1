param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$runtime = Get-ChildItem -LiteralPath (Join-Path $package 'Python') -Directory | Where-Object { $_.Name -match '^cpython-3\.11\.\d+-windows' } | Select-Object -First 1
if (-not $runtime) { throw 'The bundled Python 3.11 runtime is missing.' }
$scripts = Join-Path $package '.venv\Scripts'
New-Item -ItemType Directory -Force $scripts | Out-Null
# CPython's Windows venv launcher embeds a base interpreter path. Use the real
# interpreter and relative _pth files instead, so relocation does not depend on
# the current directory, a system Python, or the original build folder.
foreach ($name in @('python.exe', 'pythonw.exe')) {
    if (Test-Path -LiteralPath (Join-Path $runtime.FullName $name)) { Copy-Item -LiteralPath (Join-Path $runtime.FullName $name) -Destination (Join-Path $scripts $name) -Force }
}
Get-ChildItem -LiteralPath $runtime.FullName -Filter '*.dll' -File | Copy-Item -Destination $scripts -Force
$baseRelative = '..\..\Python\' + $runtime.Name
$launcherPaths = @("$baseRelative\python311.zip", "$baseRelative\Lib", "$baseRelative\DLLs", '..\Lib\site-packages', '..\..', 'import site')
[IO.File]::WriteAllLines((Join-Path $scripts 'python311._pth'), $launcherPaths, [Text.Encoding]::ASCII)
$basePaths = @('python311.zip', '.', 'Lib', 'DLLs', '..\..\.venv\Lib\site-packages', '..\..', 'import site')
[IO.File]::WriteAllLines((Join-Path $runtime.FullName 'python311._pth'), $basePaths, [Text.Encoding]::ASCII)
$configuration = @('home = ..\Python\' + $runtime.Name, 'include-system-site-packages = false', ('version = ' + ([regex]::Match($runtime.Name, 'cpython-(3\.11\.\d+)').Groups[1].Value)))
[IO.File]::WriteAllLines((Join-Path $package '.venv\pyvenv.cfg'), $configuration, [Text.Encoding]::ASCII)
Write-Output 'Portable Python uses only relative package paths.'
