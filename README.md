<p align="center">
  <img src="icon.png" alt="Pinna2HRTF icon" width="256">
</p>

# Pinna2HRTF

Calculate individualized head-related transfer functions (HRTFs) from one or two pinna meshes. Available as a CLI and macOS/Windows apps.

The pipeline runs optional Mesh2PPM inference, prepares the meshes, solves the acoustics with Mesh2HRTF/NumCalc, and exports HRTFs and HRIRs as SOFA files.

## Desktop apps

- **macOS:** Apple Silicon, macOS 13 or later. Open the DMG and drag Pinna2HRTF to Applications. [Download the macOS app](https://ecosystem.sonicom.eu/tools/30).
- **Windows:** x64, Windows 10 version 2004 or later. Extract the entire ZIP and open `Pinna2HRTF.exe` inside it.

Packaged apps include Python, the models, and the simulation tools. They work offline without a separate Blender or `uv` installation.

Create or import a project, select at least one ear mesh, and choose a save folder. Enable **Use Mesh2PPM** for inference; disable it to use the original meshes. Run the stages in order. **Preview** shows meshes and plots; **Live Log** shows progress. **Place Left/Right Mic** lets you click a microphone position and confirm with **Done**. Drag to rotate; Escape cancels.

**Reset Outputs** removes generated results while keeping configured inputs and settings. Project files live in the chosen save folder; app settings and caches live in `~/Library/Application Support/Pinna2HRTF` on macOS or `%APPDATA%\Pinna2HRTF` on Windows.

## Install the CLI

Install [Git](https://git-scm.com/install/) and [uv](https://docs.astral.sh/uv/getting-started/installation/), then:

```sh
git clone https://github.com/Any2HRTF/Pinna2HRTF.git
cd Pinna2HRTF
uv sync --locked --python 3.11
```

Prepare the native tools on macOS or Linux:

```sh
bash Scripts/prepare_external_tools.sh
```

On Windows, use PowerShell:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
```

The scripts download and build native dependencies. macOS needs Xcode Command Line Tools; Linux needs a C/C++ toolchain, Make, and Blender `bpy` system libraries. Windows installs MSYS2 if needed.

Run commands from the repository root. Use `uv run Pinna2HRTF --help` or `<subcommand> --help` for options.

## CLI: step by step

Use Bash on macOS/Linux or Git Bash on Windows. Windows paths use `/c/Users/...`; append `.exe` to tool names. Adjust paths, evaluation grid, and frequencies for your experiment.

### 1. Select meshes

Use a separate output folder for each run:

```sh
OUT="runs/example"
LEFT_MESH="/path/to/left.stl"
RIGHT_MESH="/path/to/right.stl"
mkdir -p "$OUT"
```

For one ear, omit the other side's commands and arguments throughout.

### 2. Infer geometry (optional)

Skip this step to use the original meshes. For two ears, give both inputs the same subject filename:

```sh
mkdir -p "$OUT/Input/Left" "$OUT/Input/Right"
cp "$LEFT_MESH" "$OUT/Input/Left/subject.stl"
cp "$RIGHT_MESH" "$OUT/Input/Right/subject.stl"

uv run Pinna2HRTF inference --data_dir "$OUT"

LEFT_MESH="$OUT/Intermediates/Left/Prediction_subject.stl"
RIGHT_MESH="$OUT/Intermediates/Right/Prediction_subject.stl"
```

The default model is `Local 3 Views`; the right ear is mirrored internally. For 1, 9, or 25 views, pass matching `.yaml` and `.pth` files from `HRTFCalculation/Inference/resources` with `--configuration` and `--model_checkpoint`.

### 3. Prepare simulation projects

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

This creates `project-Left` and/or `project-Right` under `$OUT`. Inspect the geometry and source placement before solving. Rerunning preprocessing replaces these simulation projects.

### 4. Solve with NumCalc

```sh
uv run Pinna2HRTF numcalc \
  --project-path "$OUT" \
  --numcalc-path "External/bin/NumCalc" \
  --max-instances 1 \
  --max-cpu-load 90
```

`--project-path` accepts one simulation project or its parent folder. Set `--max-ram-load-gb` to limit memory use. Adaptive FMM expansion lengths are enabled by default; disable them with `--no-adaptive-fmm-length`.

Rerun the command to resume: a frequency step is skipped only when all four result files and the log's completion marker are present.

### 5. Export SOFA files

```sh
uv run Pinna2HRTF sofa \
  --left-project "$OUT/project-Left" \
  --right-project "$OUT/project-Right" \
  --output-dir "$OUT/HRTF"
```

This exports SOFA files and plots, merging compatible left/right projects. Existing filenames can be overwritten; `--overwrite` deletes and recreates the entire output folder first.

## CLI: YAML configuration

Generate a configuration template:

```sh
uv run Pinna2HRTF run-config --write-template pinna2hrtf.yaml
```

Edit the input paths, output folder, external tool paths, evaluation grid, and stage settings. Relative paths are resolved from the YAML file's folder. Set an unused ear to `null`; set `inference.use_predictions_for_preprocessing: false` to use original meshes.

Run individual stages:

```sh
uv run Pinna2HRTF inference --config pinna2hrtf.yaml
uv run Pinna2HRTF preprocessing --config pinna2hrtf.yaml
uv run Pinna2HRTF numcalc --config pinna2hrtf.yaml
uv run Pinna2HRTF sofa --config pinna2hrtf.yaml
```

Run all enabled stages:

```sh
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage all
```

Only preprocessing is enabled in the template. Explicitly selected stages ignore `enabled`. Add `--dry-run` to preview a config-based run. YAML runs place simulation projects in `Projects/Left` and `Projects/Right` under the output folder.

**YAML postprocessing applies a −30 dB level offset and replaces its output folder by default.** Set `postprocessing.normalize: false` and/or `postprocessing.overwrite: false` to change these defaults. Direct `sofa` commands without `--config` do not apply the offset.

For Slurm, set `numcalc.mode: slurm` and fill in the cluster settings. The Slurm worker skips existing frequency output folders; remove incomplete step folders before resubmitting.

## Build the apps

### macOS

On Apple Silicon, with the Swift toolchain, Git, and `uv` installed:

```sh
bash Scripts/build_and_run.sh
```

This prepares the tools, builds `build/release/Pinna2HRTF.app`, and opens it. To build without launching, run `Scripts/prepare_external_tools.sh`, then `Scripts/build_release_app.sh`. Local builds are ad-hoc signed.

For a signed and notarized DMG, install a Developer ID Application certificate and save notarization credentials in Keychain under `Pinna2HRTF-notary`, then:

```sh
bash Scripts/build_release_app.sh --distribution
```

Output: `dist/Pinna2HRTF-<version>-macOS-arm64.dmg` and a SHA-256 checksum. Set `PINNA2HRTF_SIGNING_IDENTITY` to choose among certificates or `PINNA2HRTF_NOTARY_PROFILE` to use another Keychain profile.

### Windows

With the .NET 8 SDK, Git, and `uv` installed, run in PowerShell:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
.\Scripts\build_windows_port.ps1
```

The packaged app is written to `dist\windows\Pinna2HRTF`.

## License

[European Union Public Licence 1.2](LICENSE). Bundled dependencies retain their own licences.
