<p align="center">
  <img src="Sources/Pinna2HRTF/Resources/app_icon.png" alt="Pinna2HRTF icon" width="128" height="128">
</p>

# Pinna2HRTF

Pinna2HRTF generates HRTFs from left and right pinna meshes, or from a single left or right mesh. The recommended workflow is the command line: run each pipeline stage as its own command, keep the generated folders on disk, and resume individual stages when needed.

The pipeline can:

- predict complete left and right pinna meshes with the bundled PPM models
- preprocess meshes into Mesh2HRTF projects
- run NumCalc locally
- merge bilateral projects, or export a single-ear project, into SOFA files and inspection plots

## Requirements

- macOS or Linux with Python 3.11 through `uv`
- `uv`
- `NumCalc`
- `hrtf_mesh_grading`
- Mesh2HRTF sources for preprocessing

Prepare the Python environment:

```sh
uv sync
```

Prepare native tools:

```sh
Sources/Pinna2HRTF/Scripts/prepare_external_tools.sh
```

That script creates:

```text
External/bin/uv
External/bin/NumCalc
External/bin/hrtf_mesh_grading
External/src/Mesh2HRTF
```

If `cmake` is not installed, the script bootstraps it through `uvx`.

## CLI Workflow

The examples below pass paths and settings directly to each command. Paths may be absolute or relative.

Choose an output folder:

```sh
OUT="runs/example"
LEFT_MESH="/path/to/left.stl"
RIGHT_MESH="/path/to/right.stl"
mkdir -p "$OUT"
```

If you want to run mesh prediction first, place or copy the input ears into the folders expected by inference:

```sh
mkdir -p "$OUT/Target STL Left" "$OUT/Target STL Right"
cp "$LEFT_MESH" "$OUT/Target STL Left/left.stl"
cp "$RIGHT_MESH" "$OUT/Target STL Right/right.stl"
```

Run inference:

```sh
uv run Pinna2HRTF inference \
  --data_dir "$OUT" \
  --configuration "HRTFCalculation/Inference/resources/Local 3 Views.yaml" \
  --model_checkpoint "HRTFCalculation/Inference/resources/Local 3 Views.pth"
```

Inference is optional. If you already have the left and right meshes you want to use, skip that step and pass them directly to preprocessing.

Run preprocessing. Provide one or both mesh paths; only the configured sides become Mesh2HRTF projects:

```sh
uv run Pinna2HRTF preprocessing \
  --left-path "$LEFT_MESH" \
  --right-path "$RIGHT_MESH" \
  --export-path "$OUT/project" \
  --mesh-grading-executable "External/bin/hrtf_mesh_grading" \
  --Mesh2HRTF-path "External/src/Mesh2HRTF/mesh2hrtf" \
  --Mesh2HRTF-Evaluation-Grid Default \
  --min-frequency 1000 \
  --max-frequency 8000 \
  --frequency-step-count 2
```

This writes:

```text
runs/example/project-Left
runs/example/project-Right
runs/example/project-intermediates
```

Run NumCalc:

```sh
mkdir -p "$OUT/Projects"
rm -rf "$OUT/Projects/Left" "$OUT/Projects/Right"
cp -R "$OUT/project-Left" "$OUT/Projects/Left"
cp -R "$OUT/project-Right" "$OUT/Projects/Right"

uv run Pinna2HRTF numcalc \
  --project-path "$OUT/Projects" \
  --numcalc-path "External/bin/NumCalc" \
  --max-instances 1 \
  --max-cpu-load 90
```

`Pinna2HRTF numcalc` is resumable. If one side or frequency already finished, Mesh2HRTF skips it.
The local runner uses NumCalc RAM estimates to schedule frequency steps and enables adaptive FMM expansion lengths by default. This follows Kreuzer and Kasess, who show that adapting the expansion length to the local cluster radii avoids instability from non-uniform head meshes and can reduce memory and computation time. Use `--no-adaptive-fmm-length` only for an explicit baseline comparison.

The underlying clustering and expansion behavior is discussed in [Effect of different clustering approaches on the multilevel fast multipole method for the Helmholtz equation](https://arxiv.org/html/2606.31771v1).

Generate SOFA files and plots:

```sh
uv run Pinna2HRTF sofa \
  --left-project "$OUT/Projects/Left" \
  --right-project "$OUT/Projects/Right" \
  --output-dir "$OUT/HRTF" \
  --overwrite
```

Expected final files:

```text
runs/example/HRTF/HRIR_Default_merged.sofa
runs/example/HRTF/HRTF_Default_merged.sofa
runs/example/HRTF/HRIR_Default_merged_3D_horizontal_plane.jpeg
runs/example/HRTF/HRIR_Default_merged_3D_median_plane.jpeg
```

## Config Runner

There is also a YAML-based runner for app integration and scripted staged runs:

```sh
uv run Pinna2HRTF run-config --write-template pinna2hrtf.yaml
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage inference
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage preprocessing
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage numcalc
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage postprocessing
```

Use this when you prefer to keep all stage settings in one file. The stage-by-stage CLI commands above are the recommended workflow.

## Experimental Apps

Native apps exist, but they are experimental wrappers around the same Python pipeline.

### macOS

Build and run the packaged macOS app locally:

```sh
./script/build_and_run.sh
```

This prepares external tools, builds `build/release/Pinna2HRTF.app`, embeds Python dependencies, and launches the app.

### Windows

Build the portable Windows app from Windows:

```powershell
.\Scripts\prepare_windows_external_tools.ps1
.\Scripts\build_windows_port.ps1
```

The portable app is written to:

```text
dist\windows\Pinna2HRTF
```

## Citation

If you use this pipeline in academic work, please cite the associated paper or project once citation details are available.
