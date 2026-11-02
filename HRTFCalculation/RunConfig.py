from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import uuid
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
from typing import Callable, Iterable

from .Config import PipelineConfig, load_config, save_config, template_config
from .LiveEvents import emit_live_event


Logger = Callable[[str], None]


def log_default(message: str) -> None:
    print(message, flush=True)


def input_paths(config: PipelineConfig, validate: bool = False):
    if not config.scan_preparation.enabled:
        return config.paths.left_ear, config.paths.right_ear
    settings = config.scan_preparation
    if not settings.prepare_left and not settings.prepare_right:
        raise ValueError("Select at least one ear to prepare.")
    if validate:
        from .ScanPreparation import validate_prepared
        validate_prepared(config)
    from .MeshEditing import reviewed_inputs
    return reviewed_inputs(config, validate=validate)


def run_scan_preparation(config, dry_run, logger, force=False):
    settings = config.scan_preparation
    if settings.scan_path is None or settings.rotation_degrees is None:
        raise ValueError("Choose a full-head scan and an explicit crop rotation.")
    if not force:
        try:
            from .ScanPreparation import validate_prepared
            validate_prepared(config)
        except (OSError, ValueError, KeyError, TypeError):
            pass
        else:
            emit_live_event("Prepared ears are current; reusing them")
            logger(f"Scan preparation is current; reusing prepared ears in {config.paths.output_dir / 'Prepared'}")
            return False
    emit_live_event(f"Preparing {Path(settings.scan_path).name} · crop rotation {settings.rotation_degrees:g}°")
    logger(f"Preparing full-head scan {settings.scan_path} into {config.paths.output_dir / 'Prepared'}; crop rotation {settings.rotation_degrees} degrees")
    if dry_run:
        return False
    from .ScanPreparation import prepare_scan
    prepare_scan(config, logger)
    return True


def forget_ear_reviews(config: PipelineConfig, logger: Logger) -> None:
    """Fresh prepared ears supersede earlier manual edits for the rest of this run.

    Only this run's working copy changes (the desktop apps clear the saved
    project settings themselves).
    """
    settings = config.scan_preparation
    if settings.reviewed_left is not None or settings.reviewed_right is not None:
        logger("Scan preparation produced new ears; earlier manual ear edits are not used in this run.")
        settings.reviewed_left = settings.reviewed_right = None


def project_dirs(config: PipelineConfig) -> list[Path]:
    return [config.paths.output_dir / "Projects" / side for side, path in zip(("Left", "Right"), input_paths(config)) if path is not None]


def run_from_config(config: PipelineConfig, stages: Iterable[str] | None = None, dry_run: bool = False, logger: Logger = log_default) -> None:
    selected = list(stages or ["all"])
    config = config.resolved()
    run_all = "all" in selected
    ear_stages = [name for name in ("inference", "preprocessing", "numcalc", "postprocessing")
                  if name in selected or (run_all and getattr(config, name).enabled)]
    if ear_stages and not config.scan_preparation.enabled and config.paths.left_ear is None and config.paths.right_ear is None:
        raise ValueError("Set paths.left_ear and/or paths.right_ear, or enable scan_preparation.")
    prepared = False
    if "scan-preparation" in selected:
        prepared = run_scan_preparation(config, dry_run, logger, force=True)
    elif run_all and config.scan_preparation.enabled:
        prepared = run_scan_preparation(config, dry_run, logger)
    if prepared:
        forget_ear_reviews(config, logger)
    if "inference" in selected or (run_all and config.inference.enabled):
        run_inference(config, dry_run, logger)
    if "preprocessing" in selected and config.scan_preparation.enabled and "scan-preparation" not in selected:
        prepared = run_scan_preparation(config, dry_run, logger) or prepared
        if prepared:
            forget_ear_reviews(config, logger)
    if "preprocessing" in selected or (run_all and config.preprocessing.enabled):
        run_preprocessing(config, dry_run, logger)
    if "numcalc" in selected or (run_all and config.numcalc.enabled):
        run_numcalc(config, dry_run, logger)
    if "postprocessing" in selected or (run_all and config.postprocessing.enabled):
        run_postprocessing(config, dry_run, logger)


def run_inference(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    config = config.model_copy(deep=True)
    config.paths.left_ear, config.paths.right_ear = input_paths(config, validate=not dry_run)
    logger(f"Running inference in {config.paths.output_dir}")
    if config.paths.left_ear is None and config.paths.right_ear is None:
        logger("No ear meshes were selected for inference.")
        return
    if config.paths.left_ear is not None:
        logger(f"Left input mesh: {config.paths.left_ear}")
    if config.paths.right_ear is not None:
        logger(f"Right input mesh: {config.paths.right_ear}")
    if dry_run:
        return
    emit_live_event("Starting Mesh2PPM inference")
    config.paths.output_dir.mkdir(parents=True, exist_ok=True)
    from .Inference.inference_stl import main
    legacy_folders = [
        "Target STL Left", "Target STL Right", "ICP STL Left", "ICP STL Right",
        "Prediction STL Left", "Prediction STL Right", "Prediction Parameters Left", "Prediction Parameters Right",
        "Results Inference.csv"
    ]
    legacy_folders.extend([
        "Intermediates/Prediction STL Left", "Intermediates/Prediction STL Right",
        "Intermediates/Prediction Parameters Left", "Intermediates/Prediction Parameters Right",
        "Intermediates/ICP STL Left", "Intermediates/ICP STL Right"
    ])
    archive_legacy_outputs(config.paths.output_dir, legacy_folders,
                           [path for path in (config.paths.left_ear, config.paths.right_ear) if path is not None], logger)
    args = SimpleNamespace(
        configuration=str(config.inference.model_config_file),
        model_checkpoint=str(config.inference.model_checkpoint),
        data_dir=str(config.paths.output_dir),
        target_left_file=config.paths.left_ear.name if config.paths.left_ear is not None else None,
        target_right_file=config.paths.right_ear.name if config.paths.right_ear is not None else None,
        target_left_folder=str(config.paths.left_ear.parent) if config.paths.left_ear is not None else None,
        target_right_folder=str(config.paths.right_ear.parent) if config.paths.right_ear is not None else None,
        prediction_left_folder=config.inference.prediction_left_folder,
        prediction_right_folder=config.inference.prediction_right_folder,
        prediction_parameters_left_folder=config.inference.prediction_parameters_left_folder,
        prediction_parameters_right_folder=config.inference.prediction_parameters_right_folder,
        intermediates_folder="Intermediates",
    )
    main(args)
    if config.scan_preparation.enabled:
        from .ScanPreparation import record_stage
        predictions = [predicted_stl(config.paths.output_dir / folder, source.stem)
                       for source, folder in ((config.paths.left_ear, config.inference.prediction_left_folder),
                                              (config.paths.right_ear, config.inference.prediction_right_folder)) if source is not None]
        if any(path is None for path in predictions):
            raise ValueError("Inference did not produce all selected prepared-ear predictions.")
        record_stage(config, "inference", predictions)


def archive_legacy_outputs(output_dir: Path, names: Iterable[str], inputs: Iterable[Path], logger: Logger) -> Path | None:
    """Move outputs of older folder layouts aside; never delete them.

    They may contain user data, so they go to a timestamped backup under
    <output>/.pinna2hrtf/backups/ that the user can inspect or remove.
    """
    selected = [Path(path).resolve() for path in inputs]
    backup_root = None
    for name in names:
        legacy_path = output_dir / name
        if not legacy_path.exists() or legacy_path.is_symlink():
            continue
        resolved = legacy_path.resolve()
        if any(resolved == path or resolved in path.parents for path in selected):
            continue
        if backup_root is None:
            stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
            backup_root = output_dir / ".pinna2hrtf" / "backups" / f"legacy-inference-{stamp}-{uuid.uuid4().hex[:6]}"
        target = backup_root / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(legacy_path), str(target))
        logger(f"Moved legacy output {legacy_path} to {target}")
    return backup_root


def run_preprocessing(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    emit_live_event("Preparing ear meshes and building the head model")
    logger(f"Running preprocessing into {config.paths.output_dir}")
    if dry_run:
        return
    from .Preprocessing import run_preprocessing_pipeline
    left_path, right_path = preprocessing_input_paths(config, logger)
    run_preprocessing_pipeline(
        left_path=left_path,
        right_path=right_path,
        output_dir=config.paths.output_dir,
        mesh_grading_executable=config.paths.mesh_grading_executable,
        mesh2hrtf_path=config.paths.mesh2hrtf_path,
        evaluation_grid=config.paths.evaluation_grid,
        preprocessing=config.preprocessing,
        logger=logger,
    )
    if config.scan_preparation.enabled:
        from .ScanPreparation import record_stage
        record_stage(config, "preprocessing", [path / "NumCalc/source_1/NC.inp" for path in project_dirs(config)])


def preprocessing_input_paths(config: PipelineConfig, logger: Logger) -> tuple[Path | None, Path | None]:
    left, right = input_paths(config, validate=True)
    if config.scan_preparation.enabled and config.inference.use_predictions_for_preprocessing and not config.manual_ppm.enabled:
        from .ScanPreparation import validate_stage
        validate_stage(config, "inference")
    inputs = []
    for side, source, folder_name, manual_path in [
        ("left", left, config.inference.prediction_left_folder, config.manual_ppm.left_mesh),
        ("right", right, config.inference.prediction_right_folder, config.manual_ppm.right_mesh),
    ]:
        if source is None:
            inputs.append(None)
            continue
        selected = source
        if config.manual_ppm.enabled and manual_path is not None:
            if not manual_path.is_file():
                raise FileNotFoundError(f"Saved manual {side} PPM fit is missing: {manual_path}")
            selected = manual_path
            logger(f"Using manually fitted {side} PPM for preprocessing: {manual_path}")
        elif config.inference.use_predictions_for_preprocessing:
            predicted = predicted_stl(config.paths.output_dir / folder_name, source.stem)
            if predicted is not None:
                selected = predicted
                logger(f"Using inferred {side} ear for preprocessing: {predicted}")
        inputs.append(selected)
    return inputs[0], inputs[1]


def predicted_stl(folder: Path, preferred_stem: str) -> Path | None:
    if not folder.exists():
        return None
    preferred = folder / f"Prediction_{preferred_stem}.stl"
    if preferred.exists():
        return preferred
    legacy_preferred = folder / f"{preferred_stem}.stl"
    if legacy_preferred.exists():
        return legacy_preferred
    files = [path for path in folder.iterdir() if path.suffix.lower() == ".stl"]
    if len(files) == 1:
        return files[0]
    return None


def run_numcalc(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    if config.scan_preparation.enabled and not dry_run:
        input_paths(config, validate=True)
        from .ScanPreparation import validate_stage
        validate_stage(config, "preprocessing")
    if config.numcalc.mode == "slurm":
        run_numcalc_slurm(config, dry_run, logger)
    else:
        run_numcalc_local(config, dry_run, logger)


def run_numcalc_local(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    emit_live_event("Checking completed frequency steps")
    logger(f"Running local NumCalc with {config.paths.numcalc_executable}")
    projects_root = config.paths.output_dir / "Projects"
    projects = project_dirs(config)
    for project_dir in projects:
        if not (project_dir / "parameters.json").exists():
            raise FileNotFoundError(f"Missing Mesh2HRTF project: {project_dir}")
    from .NumCalc import resolve_numcalc_executable, run_local_numcalc
    numcalc_path = resolve_numcalc_executable(config.paths.numcalc_executable)
    logger(f"Local NumCalc project root: {projects_root}")
    if dry_run:
        return
    run_local_numcalc(
        project_path=projects_root,
        numcalc_path=numcalc_path,
        max_ram_load_gb=config.numcalc.max_ram_load_gb,
        ram_safety_factor=config.numcalc.ram_safety_factor,
        max_cpu_load=config.numcalc.max_cpu_load,
        max_instances=config.numcalc.max_instances,
        starting_order=config.numcalc.starting_order,
        wait_time=config.numcalc.wait_time,
        adaptive_fmm_length=config.numcalc.adaptive_fmm_length,
    )


def run_numcalc_slurm(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    worker = config.paths.output_dir / "run_numcalc_array.sh"
    if not dry_run:
        worker.write_text(slurm_worker_text(config), encoding="utf-8")
        worker.chmod(0o755)
    for project_dir in project_dirs(config):
        parameters = project_dir / "parameters.json"
        with parameters.open("r", encoding="utf-8") as file:
            steps = json.load(file)["numFrequencies"]
        command = [
            "sbatch",
            "--parsable",
            f"--job-name={project_dir.parent.parent.name}_{project_dir.name}_NumCalc",
            f"--partition={config.numcalc.partition}",
            f"--qos={config.numcalc.qos}",
            f"--time={config.numcalc.time_limit}",
            f"--mem={config.numcalc.memory}",
            f"--array=1-{steps}%{config.numcalc.array_concurrency}",
            f"--output={config.paths.output_dir}/slurm-%x-%A_%a.out",
            "--wrap",
            f"bash {shlex.quote(str(worker))} {shlex.quote(str(project_dir))}",
        ]
        logger(shlex.join(command))
        if not dry_run:
            subprocess.run(command, check=True)


def slurm_worker_text(config: PipelineConfig) -> str:
    # Mirrors NumCalc.frequency_step_complete: all four outputs are non-empty and
    # the step log contains NumCalc's end marker.
    adaptive_flag = " -adapt_fmmlength" if config.numcalc.adaptive_fmm_length else ""
    return "\n".join([
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "PROJECT_DIR=\"${1:?missing project dir}\"",
        "STEP=\"${SLURM_ARRAY_TASK_ID:?missing array step}\"",
        f"NUMCALC_EXE={shlex.quote(str(config.paths.numcalc_executable))}",
        "step_complete() {",
        "    local source_dir=\"$1\" name",
        "    for name in pBoundary pEvalGrid vBoundary vEvalGrid; do",
        "        [[ -f \"$source_dir/be.out/be.$STEP/$name\" && -s \"$source_dir/be.out/be.$STEP/$name\" ]] || return 1",
        "    done",
        "    [[ -f \"$source_dir/NC${STEP}-${STEP}_log.txt\" ]] && grep -qF -- '---------- NumCalc ended:' \"$source_dir/NC${STEP}-${STEP}_log.txt\"",
        "}",
        "shopt -s nullglob",
        "SOURCE_DIRS=(\"$PROJECT_DIR\"/NumCalc/source_*/)",
        "if (( ${#SOURCE_DIRS[@]} == 0 )); then echo \"No NumCalc source folders in $PROJECT_DIR\" >&2; exit 1; fi",
        "for SOURCE_DIR in \"${SOURCE_DIRS[@]}\"; do",
        "    SOURCE_DIR=\"${SOURCE_DIR%/}\"",
        "    if step_complete \"$SOURCE_DIR\"; then echo \"Step $STEP already complete in $SOURCE_DIR\"; continue; fi",
        "    (cd \"$SOURCE_DIR\" && \"$NUMCALC_EXE\"" + adaptive_flag + " -istart \"$STEP\" -iend \"$STEP\" > \"NC${STEP}-${STEP}_log.txt\" 2>&1)",
        "    if ! step_complete \"$SOURCE_DIR\"; then echo \"NumCalc produced incomplete output for step $STEP in $SOURCE_DIR\" >&2; exit 1; fi",
        "done",
        "",
    ])


def collect_sofa_files(projects: list[Path], output_dir: Path) -> None:
    import mesh2hrtf as m2h
    if len(projects) == 2:
        m2h.merge_sofa_files([str(project) for project in projects], savedir=str(output_dir))
    else:
        for source in (projects[0] / "Output2HRTF").glob("*.sofa"):
            shutil.copy2(source, output_dir / source.name)


def inspect_sofa_files(output_dir: Path) -> None:
    import mesh2hrtf as m2h
    for plane in ["horizontal", "median"]:
        m2h.inspect_sofa_files(str(output_dir), pattern="HRIR", plot="3D", plane=plane)


def run_postprocessing(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    emit_live_event("Converting simulation results to SOFA")
    logger(f"Running postprocessing into {config.postprocessing.output_sofa_dir}")
    if dry_run:
        return
    import mesh2hrtf as m2h
    output_dir = config.postprocessing.output_sofa_dir
    if config.postprocessing.spatial_upsampling:
        from .Postprocessing.spatial_upsampling import resolve_dependencies
        resolve_dependencies(config.postprocessing)
    root = config.paths.output_dir.resolve()
    destination = output_dir.resolve()
    protected = [root / name for name in ("Input", "Projects", "Intermediates", "Prepared", "Manual PPM", "MeshEdits", "Logs", ".pinna2hrtf")]
    protected += [p.resolve() for p in (config.paths.left_ear, config.paths.right_ear, config.scan_preparation.scan_path) if p is not None]
    if root not in destination.parents or any(p == destination or p in destination.parents or destination in p.parents for p in protected):
        raise ValueError("Choose a separate SOFA output subfolder without inputs or project work.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".pinna-export-", dir=destination.parent))
    published = False
    try:
        _export_postprocessing(config, staging, logger)
        with _output_manifest_lock(root) as can_record:
            published_files = _publish_export(staging, destination, config.postprocessing.overwrite, root)
            if can_record:
                _record_published_outputs(root, published_files, logger)
            else:
                logger("Generated-output manifest is held by the desktop app; it records the published files.")
        published = True
    finally:
        backups = staging / ".backups"
        # A failed server rollback must keep the recovery copies for the user.
        if published or not backups.exists() or not any(p.is_file() for p in backups.rglob("*")):
            shutil.rmtree(staging, ignore_errors=True)
        else:
            logger(f"Recovery copies retained in {staging}")


MANIFEST_RELATIVE = Path(".pinna2hrtf") / "generated-output-manifest.json"
_DOTNET_EPOCH_TICKS = 621355968000000000


def _read_output_manifest(project_root: Path) -> dict:
    """Read the generated-output manifest shared with the desktop apps (schema v1).

    A missing manifest is an empty one: nothing is owned yet.
    """
    path = project_root / MANIFEST_RELATIVE
    if not path.is_file():
        return {"Version": 1, "Files": {}, "Directories": {}}
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict) or document.get("Version") != 1 or not isinstance(document.get("Files", {}), dict) \
            or not isinstance(document.get("Directories", {}), dict):
        raise ValueError(f"Unsupported generated-output manifest: {path}")
    document.setdefault("Files", {})
    document.setdefault("Directories", {})
    return document


def _manifest_key(mapping: dict, relative: str) -> str | None:
    # The Windows app compares manifest paths case-insensitively.
    if relative in mapping:
        return relative
    folded = relative.casefold()
    return next((key for key in mapping if key.casefold() == folded), None)


def _file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


@contextmanager
def _output_manifest_lock(project_root: Path):
    """Take the apps' .pinna2hrtf/outputs.lock without blocking.

    Yields False while a desktop app holds it (it runs this stage and captures
    the published outputs itself when the run completes).
    """
    metadata = project_root / ".pinna2hrtf"
    metadata.mkdir(parents=True, exist_ok=True)
    try:
        handle = (metadata / "outputs.lock").open("a+b")
    except OSError:
        yield False
        return
    try:
        if os.name == "nt":
            import msvcrt
            try:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            except OSError:
                yield False
                return
            try:
                yield True
            finally:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                yield False
                return
            try:
                yield True
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        handle.close()


def _record_published_outputs(project_root: Path, files: list[Path], logger: Logger) -> None:
    """Record published files in the manifest, using the Swift/Windows entry format."""
    document = _read_output_manifest(project_root)
    for path in files:
        relative = path.relative_to(project_root).as_posix()
        # Whole-second mtimes give identical .NET ticks in Python, Swift and C#.
        info = path.stat()
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns - info.st_mtime_ns % 1_000_000_000))
        info = path.stat()
        entry = {"Stage": "Postprocessing", "Size": info.st_size,
                 "ModifiedUtcTicks": info.st_mtime_ns // 100 + _DOTNET_EPOCH_TICKS,
                 "Sha256": _file_sha256(path).upper()}
        document["Files"][_manifest_key(document["Files"], relative) or relative] = entry
        parent = PurePosixPath(relative).parent
        while str(parent) != ".":
            if _manifest_key(document["Directories"], str(parent)) is None:
                document["Directories"][str(parent)] = "Postprocessing"
            parent = parent.parent
    manifest = project_root / MANIFEST_RELATIVE
    temporary = manifest.with_name(f"{uuid.uuid4().hex}.tmp")
    try:
        temporary.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, manifest)
    finally:
        temporary.unlink(missing_ok=True)
    logger(f"Recorded {len(files)} published files in {manifest}")


def _publish_export(staging, destination, overwrite, project_root=None) -> list[Path]:
    destination.mkdir(parents=True, exist_ok=True)
    backups = staging / ".backups"
    backups.mkdir()
    installed = []
    # Read once: only files whose current hash matches a manifest entry may be replaced.
    owned_files = _read_output_manifest(project_root)["Files"] if project_root is not None else {}
    try:
        for source in list(staging.rglob("*")):
            if not source.is_file() or backups in source.parents:
                continue
            relative = source.relative_to(staging)
            target = destination / relative
            if target.is_symlink() or any(p.is_symlink() for p in target.parents):
                raise ValueError("Linked export paths are not supported.")
            target.parent.mkdir(parents=True, exist_ok=True)
            backup = backups / relative
            if target.exists():
                if not overwrite:
                    raise FileExistsError(target)
                if project_root is not None:
                    key = _manifest_key(owned_files, target.relative_to(project_root).as_posix())
                    owned = owned_files.get(key) if key is not None else None
                    if not isinstance(owned, dict) or _file_sha256(target).lower() != str(owned.get("Sha256", "")).lower():
                        raise ValueError(f"Keeping modified or untracked output: {target}. Move it away, then export again.")
                backup.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, backup)
            installed.append((target, backup))
            source.replace(target)
    except BaseException:
        for target, backup in reversed(installed):
            if backup.exists():
                backup.replace(target)
            else:
                target.unlink(missing_ok=True)
        raise
    return [target for target, _ in installed]


def _export_postprocessing(config, output_dir, logger):
    import mesh2hrtf as m2h
    projects = project_dirs(config)
    for project in projects:
        emit_live_event(f"Converting {project.name} results")
        m2h.output2hrtf(str(project))
    if config.postprocessing.resample_hrirs:
        from .Postprocessing.postprocessing import resample_hrir_files
        for project in projects:
            emit_live_event(f"Resampling {project.name} HRIRs")
            resample_hrir_files(project / "Output2HRTF", config.postprocessing.sampling_rate)
    if config.postprocessing.normalize:
        from .Postprocessing.postprocessing import normalize_sofa_files
        for project in projects:
            emit_live_event(f"Normalizing {project.name} SOFA files")
            normalize_sofa_files(project / "Output2HRTF", config.postprocessing.level_offset_db)
    if len(projects) == 2:
        emit_live_event("Combining left and right results")
    collect_sofa_files(projects, output_dir)
    if config.postprocessing.spatial_upsampling:
        from .Postprocessing.spatial_upsampling import upsample_hrtf_files
        emit_live_event("Spatially upsampling HRTFs with LocaDyn")
        upsample_hrtf_files(output_dir, config.postprocessing, logger)
    try:
        emit_live_event("Creating SOFA inspection plots")
        inspect_sofa_files(output_dir)
        logger(f"Wrote SOFA visualizations into {output_dir}")
    except Exception as error:
        logger(f"Could not write SOFA visualizations: {error}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=str, help="Path to a pipeline YAML config file.")
    parser.add_argument("--stage", action="append", choices=["all", "scan-preparation", "inference", "preprocessing", "numcalc", "postprocessing"], help="Stage to run. Can be supplied multiple times.")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--write-template", type=str, help="Write a default config template and exit.")
    return parser.parse_args()


def parse_numcalc_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--project-path", required=True)
    parser.add_argument("--numcalc-path", required=True)
    parser.add_argument("--max-instances", type=int, default=1)
    parser.add_argument("--max-cpu-load", type=int, default=90)
    parser.add_argument("--max-ram-load-gb", type=float)
    parser.add_argument("--ram-safety-factor", type=float, default=1.05)
    parser.add_argument("--starting-order", choices=["high", "low", "alternate"], default="alternate")
    parser.add_argument("--wait-time", type=int, default=15)
    parser.add_argument("--adaptive-fmm-length", action=argparse.BooleanOptionalAction, default=True)
    return parser.parse_args()


def numcalc_cli() -> None:
    args = parse_numcalc_args()
    from .NumCalc import run_local_numcalc
    run_local_numcalc(
        project_path=Path(args.project_path).expanduser().resolve(),
        numcalc_path=Path(args.numcalc_path),
        max_ram_load_gb=args.max_ram_load_gb,
        ram_safety_factor=args.ram_safety_factor,
        max_instances=args.max_instances,
        max_cpu_load=args.max_cpu_load,
        starting_order=args.starting_order,
        wait_time=args.wait_time,
        adaptive_fmm_length=args.adaptive_fmm_length,
    )


def parse_sofa_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--left-project")
    parser.add_argument("--right-project")
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args()


def sofa_cli() -> None:
    args = parse_sofa_args()
    import mesh2hrtf as m2h
    output_dir = Path(args.output_dir)
    # Export never deletes anything in a user-selected directory.
    output_dir.mkdir(parents=True, exist_ok=True)
    projects = [Path(project) for project in (args.left_project, args.right_project) if project]
    if not projects:
        raise SystemExit("At least one project is required")
    for project in projects:
        m2h.output2hrtf(str(project))
    collect_sofa_files(projects, output_dir)
    inspect_sofa_files(output_dir)


def cli() -> None:
    args = parse_args()
    if args.write_template:
        save_config(template_config(), args.write_template)
        print(f"Wrote {args.write_template}")
        return
    if not args.config:
        raise SystemExit("--config is required unless --write-template is used")
    run_from_config(load_config(args.config), stages=args.stage, dry_run=args.dry_run)


def scan_preparation_cli():
    parser = argparse.ArgumentParser(description="Crop and repair ears from a full-head scan using a project YAML.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    run_scan_preparation(load_config(args.config), args.dry_run, log_default)


if __name__ == "__main__":
    cli()
