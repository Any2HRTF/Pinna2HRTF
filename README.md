<p align="center">
  <img src="icon.png" alt="Pinna2HRTF icon" width="256">
</p>

# Pinna2HRTF

Calculate individualized head-related transfer functions (HRTFs) from one or two pinna meshes. Available as a CLI and macOS/Windows apps.

The pipeline runs optional Mesh2PPM inference, prepares the meshes, solves the acoustics with Mesh2HRTF/NumCalc, and exports HRTFs and HRIRs as SOFA files.

## Desktop apps

- **macOS:** Apple Silicon, macOS 13 or later. Open the DMG and drag Pinna2HRTF to Applications.
- **Windows:** x64 portable App, Windows 10 version 2004 or later.

[Downloads available on the release page.](https://github.com/Any2HRTF/Pinna2HRTF/releases)

Packaged apps include Python, the models, and the simulation tools. They work offline without a separate Blender or `uv` installation.

Create or import a project, select at least one ear mesh, and choose a save folder. Enable **Use Mesh2PPM** for inference, or use the macOS **Manual PPM Fit** editor to fit a Bezier PPM by hand. Run the stages in order. **Preview** shows meshes and plots; **Live Log** shows progress. **Place Left/Right Mic** lets you click a microphone position and confirm with **Done**. Escape cancels microphone placement. All macOS 3D viewers share these controls:

| Action | Trackpad | Mouse |
| --- | --- | --- |
| Rotate | Two-finger scroll | Right-drag |
| Pan | Shift–two-finger scroll | Middle-drag or Shift–right-drag |
| Zoom | Pinch or Command-scroll | Scroll wheel or Command-scroll |

In the ear editor, left-click toggles a face and left-drag draws a lasso while
**Select Faces** stays active. Camera gestures preserve the current selection.

### Pressure fields (macOS)

After NumCalc produces pressure results, choose **Left/Right pressure · Source N**
from **Preview**. Select a calculated frequency and either **Boundary** (pressure
on mesh faces) or **Evaluation Grid** (pressure at grid nodes). Magnitude, real,
and imaginary components are in Pa; level is `20 log10(|p| / 20 µPa)` and phase
is in radians. These are raw solver results, before SOFA normalization.

The legend normally rescales for each frequency. Enable **Lock color scale** to
compare frequencies using the same range. Zero pressure uses a −160 dB display
floor; its phase is undefined and shown in gray. **Refresh** reloads results after
additional frequency steps finish. Incomplete or inconsistent files display an
error instead of filling missing values. This viewer reads `NC.inp`, its geometry
files, and `pBoundary`/`pEvalGrid` directly; MATLAB and VTK export are not required.

### Manual PPM fitting (macOS)

Choose **Fit…** for an ear in the **Manual PPM Fit** project settings. The editor
overlays the target mesh and BezierPPM so you can adjust the global transform,
the local bendy-bone controls for convex regions, and shape keys for concave
details. The 3D preview updates directly from the evaluated mesh as you move a
control, without exporting an STL for each change. Nearest-vertex RMSE is reported
in both directions and as a symmetric RMSE; mean, median, maximum, and minimum
report PPM-to-target distances. Shape-key weights follow the published ranges:
all keys allow −1 to 1 except Crus helicis–Upper dent and Crus helicis–Lower dent,
which allow 0 to 1. The PPM is color-mapped by each vertex's nearest
target-vertex distance on a fixed 0–3+ mm scale, and the colors update with the
preview. The metric panel stays above the scrolling controls, with Undo and Redo
for parameter edits. The Target opacity slider fades the scanned ear over the opaque PPM error map
so the distance colors stay readable. At 0% the target is hidden; at 100% it is opaque. The editor uses
`~/Desktop/PPM.blend` when available and otherwise uses the built-in BezierPPM
defaults. The template source is preserved, and a copy plus the parameter
values are saved with the project.
Saving a fit selects manual preprocessing and turns off Mesh2PPM; an unfitted
side keeps its current input mesh. The right-side preview and export mirror the
template across Y. On macOS, Reset Outputs removes saved fits, their parameters,
editable Blender files, and archived template copies.

The fitting sequence follows the manual registration procedure in
[Perfler et al. (2025)](https://doi.org/10.1016/j.compbiomed.2025.109817):
align the whole model, adjust convex features, tune concave shape keys, then
iterate as needed.

**Reset Outputs** removes generated results while keeping original inputs and settings. On macOS this also clears saved manual PPM fits, ear edits, and scan alignments, restores the original scan, and clears references to removed fits and reviews. Files used as inputs by another project, externally modified files, logs, and unrelated files are preserved. Project files live in the chosen save folder; app settings and caches live in `~/Library/Application Support/Pinna2HRTF` on macOS or `%APPDATA%\Pinna2HRTF` on Windows.

## Full-head scan preparation (pipeline and macOS)

On macOS, enable **Prepare ears from a full-head scan**, choose an edited scan in
millimeters, enter its temporary **Crop rotation**, and select the ears to prepare.
Run **Scan Preparation** before Mesh2PPM Inference or Preprocessing. Preview the
prepared ears before continuing. Existing projects with separate ear inputs
keep their current workflow. The Windows app includes corresponding scan
alignment, preparation, and ear-editing controls.

The workflow uses convex ear cropping, cleanup and 0.75 mm isotropic remeshing
(six iterations, capped at 150,000 faces),
Screened Poisson reconstruction (depth 7, one worker), attachment-boundary
restoration, and residual-hole closure. Each exported ear must have one connected
surface, consistent winding, finite coordinates, positive volume, and exactly
one simple open attachment boundary. Original scans are preserved. Only the
validated STL files and provenance report are kept in `Prepared/`; intermediate
geometry stays in temporary storage.

The macOS preparation workspace also supports the manual steps around this stage:

1. Before preparation, choose **Align Using Nose and Ears…**. Pick the nose tip,
   the center of the left ear-canal entrance, then the right entrance. Left and
   right refer to the person being scanned. Preview the rigid alignment and save.
   The three points become horizontal; X points toward the nose, Y left, and Z
   superior, with the ear midpoint at the origin. Saving selects the aligned copy and sets crop rotation
   to zero; scans already aligned outside the app can skip this step.
2. Run **Scan Preparation**.
3. Use **Edit Left Ear…** / **Edit Right Ear…** to open the canal and trim the
   attachment area. Draw a lasso or click faces, inspect the red selection, and
   delete. Selection affects the visible surface by default; **Select through
   mesh** explicitly includes occluded faces. **Cutting Plane** provides axis
   presets, an arbitrary normal, offset, a kept-side switch, and an open cut.
   The cyan preview fits the current mesh cross-section with a small margin;
   it resizes as the plane moves or tilts. Turn off **Fit plane preview to mesh**
   to set a custom width and height in millimeters. Preview size only changes the
   cyan overlay; the cut extends through the mesh.
4. Inspect the result, undo/redo as needed, and **Save Reviewed Ear**. Saved edits
   feed the next pipeline stages automatically. **Require ear review before
   continuing** is an optional pause; it is off by default.

Working edits stay in a temporary workspace until Save. Originals and automatic
prepared meshes remain intact. Saved manual geometry and provenance live in
`MeshEdits/`; on macOS, Reset Outputs also removes these saved edits and alignments.

The aligner’s **Show coordinate system** option displays world axes at the scan
origin and a camera-linked X/Y/Z reference in the corner. After alignment, X
points forward, Y left, and Z up; the ear-canal midpoint is the origin.

The ear editor requires a connected, manifold surface with consistent winding and one simple
attachment boundary, plus at most one canal opening. It does not fill the new
opening. Later simulation preprocessing closes the canal and estimates its
source landmark using the existing pipeline.

This nose-and-ear reference plane differs from the anatomical Frankfort plane,
which uses porion and orbitale landmarks (see this
[cranial-orientation study](https://pmc.ncbi.nlm.nih.gov/articles/PMC8773378/)).
Landmarks are picked by the user; the app does not infer anatomical landmarks.
Saved alignment operations record the method, ordered landmark labels, picked
coordinates, and rigid transform.

The default crop polygon and margins are calibrated for edited, aligned scans.
They are not an automatic anatomical locator, so check orientation and placement
for each scan. Nose-and-ear alignment in the app sets crop rotation to zero;
externally aligned scans may need a Z rotation of 90 or 270 degrees. The app does
not infer rotation from a subject name. Prepared ears are exported in the crop
frame (left +Y, right -Y). Crop margins, lateral limits, and remesh edge length
are editable in the Mac app; YAML also exposes `crop_polygon_xz`.

For YAML runs, add this section (use `null` for unused `paths.left_ear` and
`paths.right_ear`; prepared inputs are routed automatically):

```yaml
scan_preparation:
  enabled: true
  scan_path: /path/to/edited-head.stl
  rotation_degrees: 90
  prepare_left: true
  prepare_right: true
  target_edge_mm: 0.75
  require_manual_review: false
  reviewed_left: null
  reviewed_right: null
```

```sh
uv run Pinna2HRTF scan-preparation --config pinna2hrtf.yaml
uv run Pinna2HRTF run-config --config pinna2hrtf.yaml --stage all
```

`all` runs enabled scan preparation before inference and simulation preprocessing.
Changed scans or preparation settings require preparation again. Saved ear edits
are checked against that preparation generation, and changed edits invalidate
inference and simulation receipts without forcing automatic scan preparation again. Inference and
simulation projects record their preparation generation so earlier geometry
cannot silently feed a later stage. **Reset Outputs** includes generated prepared
ears and receipts while protecting original input files.

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

## macOS window accessibility checks

Alignment, ear editing, and PPM fitting share `EditorSheetLayout` and `EditorCameraControls`, presented through one project-attached sheet. Keep editor headers, preview/sidebar sizing, and Cancel/Save footers in this shared layout when adding editor features.

The main workspace, nose-and-ear alignment, ear editor, and manual PPM fitting expose standard labelled controls. Fitting fields, sliders, and steppers include the region, transform, and axis in their accessibility names. The fitting sections use plain headings and rows: replacing them with SwiftUI `GroupBox` causes the Computer helper to crash while reading the fitting window on the tested macOS setup.

After changing an editor or its window host, use the Computer tool to:

1. Open nose-and-ear alignment, change camera views, expand Alignment Details, capture a screenshot, and cancel.
2. Open an ear editor, change camera views, switch between Select Faces and Cutting Plane, inspect the plane fields, and cancel without applying a cut.
3. Open both left and right manual fits. Read the Global controls and Distance Details, expand a Convex region, switch to Concave, and capture a screenshot.
4. Change one fitting parameter, verify that its displayed value and distance metrics update, then Undo and verify restoration. Check the display menu, opacity, Help, and Cancel. Reopen the fit to verify that unsaved edits were discarded.

Keep tests on existing copies and cancel rather than saving diagnostic edits. Successful compilation does not replace this window-readability check.

## Build the apps

### macOS

The Mac app is currently **2.0 beta**. Its app version is set in `Scripts/build_release_app.sh`; the About panel shows the beta label, and installer filenames use `2.0-beta`.

On Apple Silicon, with the Swift toolchain, Git, and `uv` installed:

```sh
bash Scripts/build_and_run.sh
```

This prepares the tools, builds `build/release/Pinna2HRTF.app`, and opens it. To build without launching, run `Scripts/prepare_external_tools.sh`, then `Scripts/build_release_app.sh`. Local builds are ad-hoc signed.

To package an ad-hoc signed, unnotarized drag-to-Applications DMG:

```sh
bash Scripts/build_release_app.sh --installer
```

This creates `dist/Pinna2HRTF-<version>-macOS-arm64.dmg` and a SHA-256 checksum. Apple may block the first launch because this build is not notarized. The macOS build defaults to SDK 26.5; set `PINNA2HRTF_MACOS_SDK` to select another installed SDK.

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

### Duplicate a project

Duplicate Project opens a dialog for the project name and save location. The new project folder is named after the project and appears beneath the selected parent folder. Missing parent folders are created automatically. Existing destination folders and locations inside another project are rejected. Copies are prepared in a temporary folder before being added to the sidebar, and internal paths in project metadata and saved PPM parameters are relocated to the new folder.
