<p align="center">
  <img src="icon.png" alt="Pinna2HRTF icon" width="256">
</p>

# Pinna2HRTF

Pinna2HRTF calculates individualized head-related transfer functions (HRTFs) from left and right pinna meshes, or from a single ear mesh. Use the command line to run individual stages, or use the macOS and Windows desktop apps to manage projects and inspect meshes.

The pipeline has four stages:

1. **Inference (optional):** predict pinna geometry and PPM parameters from STL scans using the bundled models.
2. **Preprocessing:** close the ear canals, construct and stitch the head geometry, grade the mesh, and export Mesh2HRTF simulation projects.
3. **NumCalc:** calculate the acoustic response with the boundary element method.
4. **SOFA export:** convert simulation results to HRTF/HRIR SOFA files, merge left and right ears when available, and create inspection plots.

## Installation

### Desktop apps

The release workflow packages an Apple Silicon macOS app and an x64 Windows app. Packaged apps include Python 3.11, the Python dependencies, all four inference models, NumCalc, mesh grading, and Mesh2HRTF sources. A complete package runs offline without a separate Python, Blender, or `uv` installation.

- **macOS:** extract `Pinna2HRTF-macos.zip`, move `Pinna2HRTF.app` to Applications, and open it. The package targets macOS 13 or later and is ad-hoc signed, without notarization.
- **Windows:** extract the complete `Pinna2HRTF-windows.zip` archive and open `Pinna2HRTF.Windows.exe` inside the extracted folder. Keep that folder together. The project targets Windows 10 version 2004 (build 19041) or later, x64.

See the [SONICOM tool page](https://ecosystem.sonicom.eu/tools/30) for the project download entry.

Projects live in the folders you choose. The apps keep their project registry, viewer state, and caches separately in `~/Library/Application Support/Pinna2HRTF` on macOS and `%APPDATA%\Pinna2HRTF` on Windows.

### Command line from source

Install [uv](https://docs.astral.sh/uv/getting-started/installation/) and Git, then clone the repository:

```sh
git clone https://github.com/Any2HRTF/Pinna2HRTF.git
cd Pinna2HRTF
uv sync --locked --python 3.11
```

Run all commands below from this repository root: the folder containing `pyproject.toml`, `README.md`, and `Scripts/`. Python 3.11 is required; dependencies are recorded in `uv.lock`.

**macOS / Linux native tools:** install a C/C++ compiler and Make first. On macOS, these are supplied by the Xcode Command Line Tools. Then run:

```sh
bash Scripts/prepare_external_tools.sh
```

The script prepares:

```text
External/bin/NumCalc
External/bin/hrtf_mesh_grading
External/src/Mesh2HRTF/mesh2hrtf/
```

It uses CMake from `PATH`, or runs CMake through `uv` if it is missing. Initial setup needs internet access to fetch dependencies and native sources. Linux also needs the system libraries required by Blender's `bpy` module and the mesh-grading build; the release workflow builds desktop packages only for macOS and Windows.

**Windows native tools:** the PowerShell preparation script downloads Mesh2HRTF sources and validates native tools already present in `External\bin`; it does not build or download the complete Windows toolchain. Supply `NumCalc.exe`, `hrtf_mesh_grading.exe`, and their matching runtime DLLs before running:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
```

NumCalc must be built from Mesh2HRTF commit `e45d0436a6fbeca3db13828cbae23ca109225be3`, support `-adapt_fmmlength`, and have a matching `External/bin/NumCalc.source-commit` file. The Unix preparation script pins the same revision. Windows packaging additionally requires `libpmp.dll`, `libpmp_vis.dll`, `libgcc_s_seh-1.dll`, `libstdc++-6.dll`, and `libwinpthread-1.dll` alongside the executables.

Check the command line:

```sh
uv run Pinna2HRTF --help
uv run Pinna2HRTF preprocessing --help
```

### Setup and build scripts

All installation and packaging scripts are in the top-level [`Scripts/`](Scripts/) folder:

| Script | Purpose |
| --- | --- |
| `prepare_external_tools.sh` | Prepare NumCalc, mesh grading, and Mesh2HRTF sources on macOS/Linux. |
| `build_release_app.sh` | Build and ad-hoc sign the macOS app with its embedded runtime. Run native-tool preparation first. |
| `build_and_run.sh` | Prepare native tools, build the macOS app, and launch it. |
| `prepare_windows_external_tools.ps1` | Fetch pinned Mesh2HRTF sources and validate supplied Windows executables. |
| `build_windows_port.ps1` | Publish the Windows app and bundle Python and native dependencies. |

Build the macOS app on an Apple Silicon Mac with the Swift/macOS SDK toolchain and `uv` installed:

```sh
bash Scripts/prepare_external_tools.sh
bash Scripts/build_release_app.sh
```

The result is `build/release/Pinna2HRTF.app`. To build and launch in one step, use `bash Scripts/build_and_run.sh`. It also accepts `--debug`, `--logs`, `--telemetry`, and `--verify`; each mode rebuilds the app first and closes an existing Pinna2HRTF process.

Build the Windows app on Windows with the .NET 8 SDK, `uv`, Git, and the native files listed above:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
.\Scripts\build_windows_port.ps1
```

The result is `dist\windows\Pinna2HRTF`. The [release workflow](.github/workflows/build-macos-app.yml) packages both apps into ZIP archives and checks their embedded runtimes after relocation.

## Command-line workflow

The following examples use a POSIX shell on macOS/Linux. On Windows, use PowerShell syntax and the corresponding `.exe` paths. Every stage provides `--help`.

### 1. Select input meshes

Use STL meshes in millimeters for the direct workflow below. Choose a separate output folder for each subject or condition:

```sh
OUT="runs/example"
LEFT_MESH="/path/to/left.stl"
RIGHT_MESH="/path/to/right.stl"
mkdir -p "$OUT"
```

### 2. Predict pinna geometry (optional)

For a bilateral run, copy the meshes into separate side folders, using the same subject filename on both sides:

```sh
mkdir -p "$OUT/Input/Left" "$OUT/Input/Right"
cp "$LEFT_MESH" "$OUT/Input/Left/subject.stl"
cp "$RIGHT_MESH" "$OUT/Input/Right/subject.stl"

uv run Pinna2HRTF inference \
  --data_dir "$OUT" \
  --configuration "HRTFCalculation/Inference/resources/Local 3 Views.yaml" \
  --model_checkpoint "HRTFCalculation/Inference/resources/Local 3 Views.pth"

LEFT_MESH="$OUT/Intermediates/Left/Prediction_subject.stl"
RIGHT_MESH="$OUT/Intermediates/Right/Prediction_subject.stl"
```

`Local 3 Views` is the default. Matching configuration/checkpoint pairs for 1, 9, and 25 views are also included. Inference writes predicted meshes, aligned input meshes (`ICP_*.stl`), parameter CSVs, and `Intermediates/Results Inference.csv`. The right ear is mirrored internally.

Skip this section to preprocess your original meshes. The direct inference command expects both input folders to exist; one may be empty for a single-ear run. The app/YAML runner skips inference when only one ear is configured.

### 3. Create simulation projects

```sh
uv run Pinna2HRTF preprocessing \
  --left-path "$LEFT_MESH" \
  --right-path "$RIGHT_MESH" \
  --export-path "$OUT/project" \
  --mesh-grading-executable "External/bin/hrtf_mesh_grading" \
  --Mesh2HRTF-path "External/src/Mesh2HRTF/mesh2hrtf" \
  --Mesh2HRTF-Evaluation-Grid Default \
  --min-frequency 0 \
  --max-frequency 24000 \
  --frequency-step-count 129
```

The frequency settings above match the YAML defaults and request a uniformly spaced grid up to 24 kHz. Mesh2HRTF omits the zero-frequency simulation step. Select frequency settings and an evaluation grid appropriate for your experiment; the grid name is passed to Mesh2HRTF.

This creates:

```text
runs/example/project-Left/
runs/example/project-Right/
runs/example/project-Intermediates/Left/
runs/example/project-Intermediates/Right/
```

For a single ear, omit the unused `--left-path` or `--right-path`. Only the selected side becomes a simulation project. Inspect the generated geometry and source placement before starting NumCalc. Rerunning preprocessing regenerates the simulation projects; resume an existing calculation at the NumCalc stage.

### 4. Run NumCalc

Pass the output folder containing the generated projects directly:

```sh
uv run Pinna2HRTF numcalc \
  --project-path "$OUT" \
  --numcalc-path "External/bin/NumCalc" \
  --max-instances 1 \
  --max-cpu-load 90
```

`--project-path` accepts a single Mesh2HRTF project or a folder containing projects. The runner schedules frequency steps using RAM estimates; `--max-ram-load-gb` can set a memory budget. Adaptive FMM expansion lengths are enabled by default and can be disabled with `--no-adaptive-fmm-length`.

The runner skips steps whose `be.out/be.<step>` directory already exists. After an interrupted or failed calculation, inspect the corresponding NumCalc logs and outputs before resuming: directory existence alone does not verify a completed result.

### 5. Export SOFA files

```sh
uv run Pinna2HRTF sofa \
  --left-project "$OUT/project-Left" \
  --right-project "$OUT/project-Right" \
  --output-dir "$OUT/HRTF"
```

For a single ear, omit the unused project argument. For bilateral results with the `Default` grid, outputs include:

```text
runs/example/HRTF/HRTF_Default_merged.sofa
runs/example/HRTF/HRIR_Default_merged.sofa
runs/example/HRTF/HRIR_Default_merged_3D_horizontal_plane.jpeg
runs/example/HRTF/HRIR_Default_merged_3D_median_plane.jpeg
```

Single-ear exports retain the original SOFA filenames without `_merged`. HRIR export requires compatible frequency spacing and the project's HRIR setting to be enabled. Add `--overwrite` only when you want to delete and recreate the entire output directory.

## YAML workflow

Keep project settings in one file when running repeated stages or using settings not exposed by the direct commands:

```sh
uv run Pinna2HRTF run-config --write-template pinna2hrtf.yaml
```

Edit the generated template before running it:

- Set `paths.left_ear`, `paths.right_ear`, and `paths.output_dir` to your own paths. Set an unused ear to `null`.
- Check `paths.external_deps_dir` and `paths.evaluation_grid`. Relative paths resolve from the YAML file's folder.
- Set `inference.use_predictions_for_preprocessing: false` to force use of the original meshes; otherwise existing matching predictions may be selected even when inference is disabled.
- Review the stage settings, particularly frequencies, geometry, NumCalc resources, and postprocessing level offset.

Run stages individually:

```sh
uv run Pinna2HRTF inference --config pinna2hrtf.yaml
uv run Pinna2HRTF preprocessing --config pinna2hrtf.yaml
uv run Pinna2HRTF numcalc --config pinna2hrtf.yaml
uv run Pinna2HRTF sofa --config pinna2hrtf.yaml
```

An explicit stage runs regardless of its `enabled` flag. To run only enabled stages in pipeline order, use:

```sh
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage all
```

Only preprocessing is enabled in a fresh template. For a preview, append `--dry-run`; this reports the selected actions, but does not fully validate inputs or dependencies. Set `numcalc.mode: slurm` and configure the cluster settings to submit frequency arrays with `sbatch` instead of running locally.

The app/YAML workflow uses this project layout:

```text
project/
├── Input/Left/
├── Input/Right/
├── Intermediates/Left/
├── Intermediates/Right/
├── Projects/Left/
├── Projects/Right/
└── HRTF/
```

The YAML runner can also read input meshes from external folders. Only configured sides become simulation projects.

**Postprocessing levels:** `Pinna2HRTF sofa` with explicit project paths applies no additional level offset. The YAML route (including `sofa --config`) defaults to `postprocessing.normalize: true` and `level_offset_db: -30`, applying a fixed −30 dB gain. Set `normalize: false` to disable it. YAML postprocessing also defaults to deleting and recreating its output directory (`overwrite: true`).

`Pinna2HRTF postprocessing --data_dir ...` is a separate batch interface for the legacy `Target Left/<subject>`, `Target Right/<subject>`, `Prediction Left/<subject>`, and `Prediction Right/<subject>` layout; use `sofa` for the projects shown above.

## License

See [LICENSE](LICENSE) for the European Union Public Licence v1.2. Bundled dependencies retain their respective licenses.
