<p align="center">
  <img src="Sources/Pinna2HRTF/Resources/app_icon.png" alt="Pinna2HRTF icon" width="128" height="128">
</p>

# Pinna2HRTF

Pinna2HRTF is a macOS app and Python pipeline for generating head-related transfer functions from left and right pinna meshes. It wraps the full workflow from PPM-based ear prediction through mesh preprocessing, Mesh2HRTF project creation, NumCalc execution, and SOFA postprocessing.

The repository can be used in two ways:

- `Pinna2HRTF`, a native SwiftUI macOS app for project setup, staged execution, artifact browsing, mesh preview, logs, and environment setup.
- `HRTFCalculation`, a `uv`-managed Python package with command line entry points for scripted and batch runs.

## Features

- Native macOS project manager for multiple HRTF runs.
- Left and right input mesh selection with copy or reference handling.
- PPM inference models bundled under `HRTFCalculation/Inference/resources`.
- Config-driven staged pipeline execution:
  - Inference
  - Preprocessing
  - NumCalc
  - Postprocessing
- Automatic output scanning for predicted ears, intermediate meshes, Mesh2HRTF projects, NumCalc results, and SOFA files.
- Built-in mesh and image preview for generated artifacts.
- Local NumCalc execution and SLURM array-job support from the Python config runner.
- Release app packaging script that bundles the Swift app, Python pipeline, app icon, runtime environment, and external binaries when available.

## Requirements

- macOS 13 or newer for the native app.
- Swift 5.9 or newer.
- `uv`.
- Python 3.11, managed through `uv`.
- Mesh2HRTF and NumCalc.
- `hrtf_mesh_grading`.

The app looks for external tools in this order:

- bundled `External/bin` inside the app or repository
- tools available on `PATH`
- installed tools under `~/Library/Application Support/Pinna2HRTF/External/bin`

## Setup

Install the Python environment from the repository root:

```sh
uv sync
```

The Python dependencies include the Mesh2HRTF and PPM packages from GitHub, so the first sync may take a while.

Prepare external binaries in an `External/bin` folder when they are not already available on `PATH`:

```text
External/bin/uv
External/bin/NumCalc
External/bin/hrtf_mesh_grading
```

The app can also copy missing `PATH` tools into its application support dependency folder when you run environment setup from the UI.

## Run The macOS App

For development:

```sh
swift run Pinna2HRTF
```

In the app:

1. Create a project.
2. Select the left and right ear STL files.
3. Choose an output folder.
4. Check the environment panel for `uv`, `NumCalc`, and mesh grading.
5. Run stages individually or use `Command-R` to run the next incomplete stage.
6. Inspect generated meshes, plots, logs, and SOFA outputs from the artifact browser.

Useful menu commands:

- `Command-N`: new project
- `Command-R`: run next stage
- `Command-.`: stop the running stage
- `Shift-Command-R`: refresh artifacts

## Build A Release App

```sh
Sources/Pinna2HRTF/Scripts/build_release_app.sh
```

The release bundle is written to:

```text
build/release/Pinna2HRTF.app
```

The script builds the Swift executable, copies the Python pipeline into the app resources, includes the app icon, copies available external binaries, installs the Python environment with `uv`, and writes the app `Info.plist`.

## Command Line Usage

The command line runner is config based. Write a template first:

```sh
uv run hrtf-run-config --write-template pinna2hrtf.yaml
```

Edit the paths and settings in `pinna2hrtf.yaml`, then run one stage:

```sh
uv run hrtf-run-config --config pinna2hrtf.yaml --stage inference
uv run hrtf-run-config --config pinna2hrtf.yaml --stage preprocessing
uv run hrtf-run-config --config pinna2hrtf.yaml --stage numcalc
uv run hrtf-run-config --config pinna2hrtf.yaml --stage postprocessing
```

Run every enabled stage:

```sh
uv run hrtf-run-config --config pinna2hrtf.yaml --stage all
```

Preview the selected actions without running them:

```sh
uv run hrtf-run-config --config pinna2hrtf.yaml --stage all --dry-run
```

The legacy entry points are still available:

```sh
uv run hrtf-inference --data_dir /path/to/Data
uv run hrtf-preprocessing --left-path /path/to/left.stl --right-path /path/to/right.stl --export-path /path/to/output --mesh-grading-executable /path/to/hrtf_mesh_grading --Mesh2HRTF-path /path/to/Mesh2HRTF/mesh2hrtf
uv run hrtf-postprocessing --data_dir /path/to/Data
```

Add `--head-radius 75` to `hrtf-preprocessing` only when the input pinnae need to be placed laterally before preprocessing.

## Pipeline Outputs

A typical project output folder contains:

```text
Input/
Target STL Left/
Target STL Right/
Prediction STL Left/
Prediction STL Right/
Prediction Parameters Left/
Prediction Parameters Right/
intermediates/
Projects/
HRTF/
.pinna2hrtf_native_run.yaml
```

Important generated files include:

- predicted ear meshes in `Prediction STL Left` and `Prediction STL Right`
- closed ears, dummy head, cut heads, stitched heads, and graded heads in `intermediates`
- Mesh2HRTF projects in `Projects/Left` and `Projects/Right`
- merged SOFA files and HRTF plots in `HRTF`

## Configuration Notes

The app writes `.pinna2hrtf_native_run.yaml` into each project output folder before launching a stage. This is the same configuration format accepted by `hrtf-run-config`.

Key settings include:

- input ear paths and output directory
- PPM model configuration and checkpoint
- mesh grading executable
- Mesh2HRTF path
- evaluation grid
- preprocessing frequency range and mesh parameters
- optional `head_radius`, which laterally places the left and right pinnae at `+head_radius` and `-head_radius` before preprocessing; leave it empty to keep the input mesh positions unchanged
- local or SLURM NumCalc mode
- SOFA postprocessing output directory

## Repository Layout

```text
HRTFCalculation/                 Python pipeline package
HRTFCalculation/Inference/       PPM inference code and model resources
HRTFCalculation/Preprocessing/   mesh preparation and Mesh2HRTF export
HRTFCalculation/Postprocessing/  SOFA generation and merge helpers
Sources/Pinna2HRTF/             SwiftUI macOS app
Sources/Pinna2HRTF/Resources/   app icon assets
Sources/Pinna2HRTF/Scripts/     packaging and external-tool scripts
Package.swift                   Swift package manifest
pyproject.toml                  Python package and uv dependency metadata
```

## Citation

If you use this pipeline in academic work, please cite the associated paper or project once citation details are available.
