# Pinna2HRTF for Windows

This folder contains the Windows desktop shell for Pinna2HRTF and the shared Python pipeline.

## Requirements

- Windows 10 or Windows 11 x64.
- The release zip bundles `uv.exe`, `NumCalc.exe`, `hrtf_mesh_grading.exe`, a managed Python 3.11 runtime, and the Python environment.

The app looks for native tools in `External\bin` first, then on `PATH`. If a tool is missing, open the Environment panel and browse to the executable.

## First Run

1. Start `Pinna2HRTF.Windows.exe`.
2. Open Environment and confirm the bundled tool paths if you moved the folder manually.
3. Create a project, choose left and right STL meshes, and choose a save location.
4. Run each stage or use Run Next.

Project state is stored in `%APPDATA%\Pinna2HRTF\projects.json`.

## Portable Build

From the repository root on Windows:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
.\Scripts\build_windows_port.ps1
```

The portable folder is written to:

```text
dist\windows\Pinna2HRTF
```

The build script runs `uv sync --no-dev --managed-python --python 3.11` inside the portable folder so the release can run the bundled pipeline without setting up Python on first launch. For a quick shell-only build during development, use:

```powershell
.\Scripts\build_windows_port.ps1 -SkipPythonEnvironment -AllowMissingExternalTools
```

The folder can be moved to a path with spaces. Reopen the Environment panel after moving it if external tool paths need to be updated.
