param([string]$Dotnet = "")
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$source = Join-Path $root "Sources\Pinna2HRTF.Windows"
$work = Join-Path $root "build\windows-regression"
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (-not $Dotnet) { $Dotnet = Join-Path $root ".dotnet\dotnet.exe" }
if (-not (Test-Path $Dotnet)) { $Dotnet = (Get-Command dotnet).Source }
Get-ChildItem -LiteralPath $source -File | Copy-Item -Destination $work -Force
Copy-Item -LiteralPath (Join-Path $source "Resources") -Destination $work -Recurse -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "MicrophoneValidation.cs") -Destination $work -Force
$main = Join-Path $work "MainWindow.xaml.cs"
$text = [IO.File]::ReadAllText($main)
$original = 'appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Pinna2HRTF");'
if (-not $text.Contains($original)) { throw "Cannot isolate the validation profile: appData assignment changed." }
[IO.File]::WriteAllText($main, $text.Replace($original, 'appData = Path.Combine(packageRoot, "build", "windows-regression", "profile");'))
$app = Join-Path $work "App.xaml.cs"
$text = [IO.File]::ReadAllText($app).Replace('window.Activate();', 'window.Activate(); ((MainWindow)window).RunMicrophoneValidation();')
[IO.File]::WriteAllText($app, $text)
$project = Join-Path $work "Pinna2HRTF.Windows.csproj"
$text = [IO.File]::ReadAllText($project).Replace('..\Pinna2HRTF\Resources\app_icon.png', '..\..\Sources\Pinna2HRTF\Resources\app_icon.png')
[IO.File]::WriteAllText($project, $text)
& $Dotnet build $project -c Release -r win-x64 --nologo
if ($LASTEXITCODE -ne 0) { throw "Validation build failed." }
$exe = Join-Path $work "bin\Release\net8.0-windows10.0.19041.0\win-x64\Pinna2HRTF.Windows.exe"
$process = Start-Process -FilePath $exe -WorkingDirectory $root -WindowStyle Hidden -PassThru
if (-not $process.WaitForExit(180000)) { $process.Kill(); throw "Validation timed out." }
Get-Content (Join-Path $work "results.json")
if ($process.ExitCode -ne 0) { throw "Windows microphone validation failed." }
