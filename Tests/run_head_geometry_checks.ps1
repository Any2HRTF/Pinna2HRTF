# Run the dependency-free checks directly with the installed SDK, without NuGet.
$ErrorActionPreference = 'Stop'
$dotnetPath = (Get-Command dotnet).Source
$dotnetRoot = Split-Path $dotnetPath -Parent
$sdkPath = Get-ChildItem (Join-Path $dotnetRoot 'sdk') -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$referencePath = Get-ChildItem (Join-Path $dotnetRoot 'packs\Microsoft.NETCore.App.Ref') -Directory | Where-Object Name -Like '8.*' | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
$output = Join-Path $PSScriptRoot 'bin\HeadGeometryChecks'
New-Item -ItemType Directory -Path $output -Force | Out-Null
$assembly = Join-Path $output 'checks.dll'
$usings = Join-Path $output 'Usings.cs'
'global using System; global using System.IO; global using System.Linq; global using System.Collections.Generic;' | Set-Content -LiteralPath $usings
$compilerArgs = @((Join-Path $sdkPath.FullName 'Roslyn\bincore\csc.dll'), '-nologo', '-target:exe', '-langversion:latest', '-nullable:enable', ('-out:' + $assembly), $usings, (Join-Path $PSScriptRoot 'HeadGeometryChecks.cs'), (Join-Path $PSScriptRoot '..\Sources\Pinna2HRTF.Windows\HeadGeometry.cs'))
Get-ChildItem (Join-Path $referencePath.FullName 'ref\net8.0') -Filter '*.dll' | ForEach-Object { $compilerArgs += '-reference:' + $_.FullName }
& $dotnetPath @compilerArgs
if ($LASTEXITCODE -ne 0) { throw 'Geometry check compilation failed.' }
'{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}' | Set-Content -LiteralPath (Join-Path $output 'checks.runtimeconfig.json')
& $dotnetPath $assembly
if ($LASTEXITCODE -ne 0) { throw 'Geometry checks failed.' }
