# Pinna2HRTF for Windows

This folder contains the Windows desktop shell for Pinna2HRTF and the shared Python pipeline.

## Requirements

- Windows 10 or Windows 11 x64.
- `uv.exe`.
- Python 3.11 managed through `uv`.
- `NumCalc.exe`.
- `hrtf_mesh_grading.exe`.

The app looks for tools in `External\bin` first, then on `PATH`. If a tool is missing, open the Environment panel and browse to the executable.

## First Run

1. Start `Pinna2HRTF.Windows.exe`.
2. Open Environment and confirm the paths for `uv.exe`, `NumCalc.exe`, `hrtf_mesh_grading.exe`, and the external dependency folder.
3. Select Set Up Environment.
4. Create a project, choose left and right STL meshes, and choose a save location.
5. Run each stage or use Run Next.

Project state is stored in `%APPDATA%\Pinna2HRTF\projects.json`.

## Portable Build

From the repository root on Windows:

```powershell
.\Scripts\build_windows_port.ps1
```

The portable folder is written to:

```text
dist\windows\Pinna2HRTF
```

The folder can be moved to a path with spaces. Reopen the Environment panel after moving it if external tool paths need to be updated.
