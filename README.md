<p align="center">
  <img src="icon.png" alt="Pinna2HRTF icon" width="256">
</p>

# Pinna2HRTF

Pinna2HRTF calculates individualized head-related transfer functions (HRTFs) from one or two pinna meshes. It provides a command-line interface and desktop apps for macOS and Windows.

The pipeline consists of:

1. optional geometry inference from STL scans;
2. mesh preprocessing and Mesh2HRTF project generation;
3. acoustic simulation with NumCalc;
4. HRTF and HRIR export to SOFA.

## Desktop apps

Packaged releases include Python, the inference models, NumCalc, mesh grading, and Mesh2HRTF. They run offline and do not require Blender or `uv`.

- **macOS:** open `Pinna2HRTF-<version>-macOS-arm64.dmg`, drag Pinna2HRTF to Applications, and open it. Distribution builds require Apple Silicon and macOS 13 or later and are Developer ID signed and notarized. Local development builds remain ad-hoc signed.
- **Windows:** extract the complete `Pinna2HRTF-windows.zip` archive and run `Pinna2HRTF.exe` from the extracted folder. The current build requires x64 Windows 10 version 2004 or later.

Download the compiled macOS version [here](https://ecosystem.sonicom.eu/tools/30).

Project files stay in the folder you choose. App settings and caches are stored in `~/Library/Application Support/Pinna2HRTF` on macOS and `%APPDATA%\Pinna2HRTF` on Windows.

## Install from source

Python 3.11, [uv](https://docs.astral.sh/uv/getting-started/installation/), and Git are required.

```sh
git clone https://github.com/Any2HRTF/Pinna2HRTF.git
cd Pinna2HRTF
uv sync --locked --python 3.11
```

Prepare NumCalc, mesh grading, and Mesh2HRTF on macOS or Linux:

```sh
bash Scripts/prepare_external_tools.sh
```

On Windows, run:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
```

These scripts download and build the pinned native dependencies. macOS also needs the Xcode Command Line Tools. Linux needs a C/C++ toolchain, Make, and the system libraries required by Blender's `bpy` module.

Check the installation with:

```sh
uv run Pinna2HRTF --help
```

Run commands from the repository root.

## Command-line workflow

The examples below use a POSIX shell. Paths and frequency settings are examples; adjust them for your data and experiment.

### 1. Choose the input meshes

Input STL meshes must use millimetres. Keep each run in its own output folder.

```sh
OUT="runs/example"
LEFT_MESH="/path/to/left.stl"
RIGHT_MESH="/path/to/right.stl"
mkdir -p "$OUT"
```

### 2. Run inference if needed

Inference is optional. For a bilateral run, place both scans under the same subject filename. A single-ear run can provide only the available side:

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

`Local 3 Views` is the default model. Matching 1-, 9-, and 25-view models are also included. The right ear is mirrored internally. Skip this step to use the original meshes.

### 3. Create the simulation projects

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

Omit the unused ear argument for a single-ear run. Inspect the generated geometry and source placement before starting NumCalc. Rerunning preprocessing replaces the simulation projects.

### 4. Run NumCalc

```sh
uv run Pinna2HRTF numcalc \
  --project-path "$OUT" \
  --numcalc-path "External/bin/NumCalc" \
  --max-instances 1 \
  --max-cpu-load 90
```

`--project-path` may point to one Mesh2HRTF project or a folder containing several projects. Use `--max-ram-load-gb` to set a memory limit. Adaptive FMM expansion lengths are enabled by default.

Interrupted runs can be resumed. A frequency step is skipped only when its four result files are present and the NumCalc log contains the completion marker.

### 5. Export SOFA files

```sh
uv run Pinna2HRTF sofa \
  --left-project "$OUT/project-Left" \
  --right-project "$OUT/project-Right" \
  --output-dir "$OUT/HRTF"
```

Omit the unused project argument for a single-ear run. Bilateral runs produce merged HRTF and HRIR SOFA files when the projects are compatible. Add `--overwrite` only when the existing output directory may be deleted and recreated.

Run any command with `--help` for all available options.

## YAML workflow

For repeatable runs, create a configuration file:

```sh
uv run Pinna2HRTF run-config --write-template pinna2hrtf.yaml
```

Set the input meshes, output directory, external dependency directory, evaluation grid, and stage settings in the generated file. Use `null` for an unused ear. Relative paths are resolved from the YAML file.

Run one stage:

```sh
uv run Pinna2HRTF preprocessing --config pinna2hrtf.yaml
uv run Pinna2HRTF numcalc --config pinna2hrtf.yaml
uv run Pinna2HRTF sofa --config pinna2hrtf.yaml
```

Or run all enabled stages in order:

```sh
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage all
```

Only preprocessing is enabled in a new template. Add `--dry-run` to preview the selected stages. For cluster execution, set `numcalc.mode: slurm` and configure the Slurm options in the YAML file.

The YAML postprocessing defaults to a -30 dB level offset and replaces its output directory. Set `postprocessing.normalize: false` or `postprocessing.overwrite: false` to change this behaviour. Direct `sofa` commands do not apply the level offset.

## Build the desktop apps

Build the macOS app on Apple Silicon with the Swift toolchain and `uv` installed:

```sh
bash Scripts/prepare_external_tools.sh
bash Scripts/build_release_app.sh
```

The app is written to `build/release/Pinna2HRTF.app`. Use `Scripts/build_and_run.sh` to build and launch it.

To create a distributable DMG, install a Developer ID Application certificate and save notarization credentials in the login Keychain under the profile `Pinna2HRTF-notary`, then run:

```sh
bash Scripts/build_release_app.sh --distribution
```

The script signs all embedded executable code with the hardened runtime, notarizes and staples the app and DMG, and writes `dist/Pinna2HRTF-<version>-macOS-arm64.dmg` with a matching SHA-256 checksum. Set `PINNA2HRTF_SIGNING_IDENTITY` only when the Keychain contains more than one Developer ID Application identity. Set `PINNA2HRTF_NOTARY_PROFILE` to override the default Keychain profile name.

Build the Windows app on Windows with the .NET 8 SDK, `uv`, and Git:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
.\Scripts\build_windows_port.ps1
```

The packaged folder is written to `dist\windows\Pinna2HRTF`.

## License

Pinna2HRTF is licensed under the [European Union Public Licence 1.2](LICENSE). Bundled dependencies retain their own licences.
