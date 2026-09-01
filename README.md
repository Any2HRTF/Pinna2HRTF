<p align="center">
  <img src="icon.png" alt="Pinna2HRTF icon" width="256">
</p>

# Pinna2HRTF

Pinna2HRTF generates HRTFs from left and right pinna meshes, or from a single left or right mesh. The recommended workflow is the command line: run each pipeline stage as its own command, keep the generated folders on disk, and resume individual stages when needed.

The pipeline can:

- predict complete left and right pinna meshes with the bundled PPM models
- preprocess meshes into Mesh2HRTF projects
- run NumCalc locally
- merge bilateral projects, or export a single-ear project, into SOFA files and inspection plots

## Command-line Requirements

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
External/bin/NumCalc
External/bin/hrtf_mesh_grading
External/src/Mesh2HRTF
```

If `cmake` is not installed, the script bootstraps it through the developer's `uv` installation. `uv` is used to build and develop Pinna2HRTF, but it is not included in either app download.

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
mkdir -p "$OUT/Input/Left" "$OUT/Input/Right"
cp "$LEFT_MESH" "$OUT/Input/Left/left.stl"
cp "$RIGHT_MESH" "$OUT/Input/Right/right.stl"
```

Run inference:

```sh
uv run Pinna2HRTF inference \
  --data_dir "$OUT" \
  --configuration "HRTFCalculation/Inference/resources/Local 3 Views.yaml" \
  --model_checkpoint "HRTFCalculation/Inference/resources/Local 3 Views.pth"
```

Inference is optional. If you already have the left and right meshes you want to use, skip that step and pass them directly to preprocessing.

For the app and config-driven workflow, a project contains `Input/`, one `Intermediates/` folder with only `Left/` and `Right/` side folders for generated meshes and working data, `Projects/` for Mesh2HRTF simulations, and one `HRTF/` folder containing the finished SOFA files and plots.

The side folders contain preprocessing files plus prefixed inference outputs such as `Prediction_Left.stl`, `ICP_Left.stl`, and `Prediction_Parameters_Left.csv`; the shared `Results Inference.csv` stays directly in `Intermediates/`.

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
runs/example/project-Intermediates
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

## Desktop Apps

The desktop apps are self-contained wrappers around the same Python pipeline. They include Python 3.11, PyTorch, Blender's Python module, all four inference models, NumCalc, mesh grading, Mesh2HRTF preprocessing sources, and the evaluation grid. After download, they run offline and do not require Python or `uv` on the destination computer.

### macOS

The macOS app supports Apple Silicon Macs. Unzip the download, move `Pinna2HRTF.app` to Applications or any other folder, and open it. The app is ad-hoc signed rather than notarized, so macOS may require Control-clicking the app, choosing Open, and confirming Open the first time. Moving the app later does not invalidate its embedded runtime.

Projects and writable caches are stored separately in `~/Library/Application Support/Pinna2HRTF`, so replacing or moving the app does not remove projects and does not modify the app bundle.

Build and run the packaged macOS app locally:

```sh
./Scripts/build_and_run.sh
```

This requires `uv`, prepares external tools, builds `build/release/Pinna2HRTF.app`, embeds the offline runtime, and launches the app. The distributable zip is produced by the GitHub release workflow.

A compiled version is available to (download)[https://ecosystem.sonicom.eu/tools/30].

### Windows

The Windows app supports x64 Windows. Extract the complete `Pinna2HRTF-windows.zip` archive to any writable folder and run `Pinna2HRTF.Windows.exe`. Keep the extracted folder together; no Python or `uv` installation is required.

Build the portable Windows app from Windows:

The app bundles NumCalc built from Mesh2HRTF v1.3.0 (commit e45d0436a6fbeca3db13828cbae23ca109225be3); the Windows preparation script requires this bundled binary and does not use the obsolete SourceForge fallback. The macOS preparation script pins the same Mesh2HRTF revision.

```powershell
.\Scripts\prepare_windows_external_tools.ps1
.\Scripts\build_windows_port.ps1
```

The portable app is written to:

```text
dist\windows\Pinna2HRTF
```

Both packaged apps invoke the pipeline through their bundled Python module rather than a generated command launcher, so the downloads do not retain paths from the build machine. `uv` remains a reproducible build-time tool only.

## Citation

If you use this pipeline in academic work, please cite the associated paper or project once citation details are available.
