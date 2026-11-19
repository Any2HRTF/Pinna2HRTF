from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import uuid
from contextlib import ExitStack, contextmanager
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
from typing import Callable, Iterable

from .Config import BUNDLED_EVALUATION_GRID_PATH, DEFAULT_EVALUATION_GRID, PipelineConfig, load_config, save_config, template_config
from .FileIdentity import sha256
from .LiveEvents import emit_live_event


Logger = Callable[[str], None]


def log_default(message: str) -> None:
    print(message, flush=True)


def input_paths(config: PipelineConfig, validate: bool = False):
    if not config.scan_preparation.enabled:
        if not (config.paths.edited_left_ear or config.paths.edited_right_ear):
            return config.paths.left_ear, config.paths.right_ear
        from .MeshEditing import reviewed_inputs
        return reviewed_inputs(config, validate=validate)
    settings = config.scan_preparation
    if not settings.prepare_left and not settings.prepare_right:
        raise ValueError("Select at least one ear to prepare.")
    if validate:
        from .ScanPreparation import validate_prepared
        validate_prepared(config)
    from .MeshEditing import reviewed_inputs
    paths = reviewed_inputs(config, validate=validate)
    if validate and settings.require_manual_review:
        for side, path, reviewed in zip(("left", "right"), paths, (settings.reviewed_left, settings.reviewed_right)):
            if path is not None and reviewed is None:
                raise ValueError(f"Review the prepared {side} ear before continuing")
    return paths


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
    from .Outputs import stage_outputs
    from .StageReceipt import execute as stage_receipt
    selected = list(stages or ["all"])
    config = config.resolved()
    run_all = "all" in selected
    ear_stages = [name for name in ("inference", "preprocessing", "numcalc", "postprocessing")
                  if name in selected or (run_all and getattr(config, name).enabled)]
    if ear_stages and not config.scan_preparation.enabled and config.paths.left_ear is None and config.paths.right_ear is None:
        raise ValueError("Set paths.left_ear and/or paths.right_ear, or enable scan_preparation.")
    prepared = False
    if "scan-preparation" in selected:
        with stage_outputs(config, "scan-preparation", dry_run):
            prepared = run_scan_preparation(config, dry_run, logger, force=True)
    elif run_all and config.scan_preparation.enabled:
        with stage_outputs(config, "scan-preparation", dry_run):
            prepared = run_scan_preparation(config, dry_run, logger)
    if prepared:
        forget_ear_reviews(config, logger)
    if "inference" in selected or (run_all and config.inference.enabled):
        with stage_outputs(config, "inference", dry_run):
            run_inference(config, dry_run, logger)
            if not dry_run:
                stage_receipt({"action": "record-stage", "stage": "inference", "config": config.model_dump()})
    if "preprocessing" in selected or (run_all and config.preprocessing.enabled):
        with stage_outputs(config, "preprocessing", dry_run):
            if "preprocessing" in selected and config.scan_preparation.enabled and "scan-preparation" not in selected:
                prepared = run_scan_preparation(config, dry_run, logger) or prepared
                if prepared:
                    forget_ear_reviews(config, logger)
            run_preprocessing(config, dry_run, logger)
    if "numcalc" in selected or (run_all and config.numcalc.enabled):
        with stage_outputs(config, "numcalc", dry_run):
            run_numcalc(config, dry_run, logger)
        if config.numcalc.mode == "slurm" and not dry_run:
            if "postprocessing" in selected or (run_all and config.postprocessing.enabled):
                logger("Postprocessing waits for the Slurm jobs. Run it after they finish.")
            return
    if "postprocessing" in selected or (run_all and config.postprocessing.enabled):
        with stage_outputs(config, "postprocessing", dry_run):
            run_postprocessing(config, dry_run, logger)
            if not dry_run:
                stage_receipt({"action": "record-stage", "stage": "postprocessing", "config": config.model_dump()})


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


PREPROCESSING_INPUT_RECEIPT = ".pinna2hrtf-preprocessing-inputs-v1.json"


def preprocessing_input_signature(config: PipelineConfig) -> dict:
    from .FileIdentity import cached_sha256
    settings = config.preprocessing.model_dump(mode="json")
    for key in ("enabled", "title", "pictures", "write_intermediates"):
        settings.pop(key, None)
    grid = Path(config.paths.evaluation_grid)
    if config.paths.evaluation_grid == DEFAULT_EVALUATION_GRID:
        grid = BUNDLED_EVALUATION_GRID_PATH
    elif not grid.is_absolute():
        grid = config.paths.mesh2hrtf_path / "Mesh2Input" / "EvaluationGrids" / "Data" / grid
    grid_hashes = {name: cached_sha256(grid / name) for name in ("Nodes.txt", "Elements.txt")}
    ears = {}
    for side, source in zip(("left", "right"), preprocessing_input_paths(config, lambda _: None)):
        if source is None:
            continue
        effective = dict(settings)
        other = "right" if side == "left" else "left"
        effective.pop("source_position_" + other, None)
        effective.pop("source_position_input_" + other, None)
        ears[side] = {"mesh_sha256": cached_sha256(source), "settings": effective, "grid": grid_hashes}
    return {"format": "pinna2hrtf-preprocessing-inputs-v1", "ears": ears}


def validate_preprocessing_inputs(config: PipelineConfig, logger: Logger, allow_legacy: bool = False) -> None:
    from .StageReceipt import StageNotCurrent, preprocessing_outputs_match
    path = config.paths.output_dir / PREPROCESSING_INPUT_RECEIPT
    if not path.exists():
        if allow_legacy:
            if not preprocessing_outputs_match(config):
                raise StageNotCurrent("The generated solver inputs changed. Run preprocessing again.")
            logger("Legacy preprocessing has no shared input receipt; proceeding with the existing simulation records. Current desktop preprocessing checks still apply.")
            return
        raise ValueError("This legacy project has no shared preprocessing input receipt. Validate and rerun preprocessing with the current inputs before config-based SOFA export. Existing results are preserved.")
    recorded = json.loads(path.read_text(encoding="utf-8"))
    current = preprocessing_input_signature(config)
    if recorded.get("format") != current["format"] or recorded.get("ears") != current["ears"]:
        raise StageNotCurrent("Preprocessing inputs or settings changed. Run preprocessing with the current inputs before NumCalc or SOFA export.")
    if not preprocessing_outputs_match(config, recorded.get("outputs")):
        raise StageNotCurrent("The generated solver inputs changed. Run preprocessing again.")


def run_preprocessing(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    emit_live_event("Preparing ear meshes and building the head model")
    logger(f"Running preprocessing into {config.paths.output_dir}")
    if dry_run:
        return
    from .Preprocessing import run_preprocessing_pipeline
    left_path, right_path = preprocessing_input_paths(config, logger)
    if config.inference.use_predictions_for_preprocessing and not config.manual_ppm.enabled:
        from .StageReceipt import require_current_inference
        require_current_inference(config, [side for side, path in (("left", left_path), ("right", right_path)) if path is not None])
    signature = preprocessing_input_signature(config)
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
    if signature != preprocessing_input_signature(config):
        raise ValueError("Preprocessing inputs changed while the mesh was being built. Rerun preprocessing.")
    from .StageReceipt import record_preprocessing
    record_preprocessing(config, signature)
    if config.scan_preparation.enabled:
        from .ScanPreparation import record_stage
        record_stage(config, "preprocessing", [path / "NumCalc/source_1/NC.inp" for path in project_dirs(config)])


def preprocessing_input_paths(config: PipelineConfig, logger: Logger) -> tuple[Path | None, Path | None]:
    if config.manual_ppm.enabled and config.inference.use_predictions_for_preprocessing:
        raise ValueError('Choose one ear modelling method: Mesh2PPM, manual PPM, or no PPM.')
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
        if config.manual_ppm.enabled:
            from .StageReceipt import mac_mesh_identity_matches, windows_mesh_identity
            if manual_path is None:
                raise ValueError(f'Fit the {side} ear before running manual PPM preprocessing.')
            parameters = getattr(config.manual_ppm, f"{side}_parameters")
            if parameters is None or not parameters.is_file():
                raise ValueError(f"Refit the {side} ear: the saved fit parameters are missing.")
            if not manual_path.is_file():
                raise FileNotFoundError(f"Saved manual {side} PPM fit is missing: {manual_path}")
            fit_source = getattr(config.manual_ppm, f"{side}_source")
            identity = getattr(config.manual_ppm, f"{side}_source_identity") or ""
            if (fit_source is None or fit_source.resolve() != source.resolve()
                    or not identity
                    or not (identity == windows_mesh_identity(fit_source)
                            or mac_mesh_identity_matches(identity, str(fit_source)))):
                raise ValueError(f"Refit the {side} ear: the saved fit does not match the current source mesh.")
            selected = manual_path
            logger(f"Using manually fitted {side} PPM for preprocessing: {manual_path}")
        elif config.inference.use_predictions_for_preprocessing:
            predicted = predicted_stl(config.paths.output_dir / folder_name, source.stem)
            if predicted is None:
                raise FileNotFoundError(f"Run Mesh2PPM inference for the {side} ear before preprocessing.")
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
    if not dry_run:
        validate_preprocessing_inputs(config, logger, allow_legacy=True)
    if config.numcalc.mode == "slurm":
        run_numcalc_slurm(config, dry_run, logger)
    else:
        run_numcalc_local(config, dry_run, logger)


def run_numcalc_local(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    emit_live_event("Checking completed frequency steps")
    logger(f"Running local NumCalc with {config.paths.numcalc_executable}")
    if not dry_run:
        require_no_slurm_jobs(config.paths.output_dir)
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
        project_path=projects,
        numcalc_path=numcalc_path,
        max_ram_load_gb=config.numcalc.max_ram_load_gb,
        ram_safety_factor=config.numcalc.ram_safety_factor,
        max_cpu_load=config.numcalc.max_cpu_load,
        max_instances=config.numcalc.max_instances,
        starting_order=config.numcalc.starting_order,
        wait_time=config.numcalc.wait_time,
        adaptive_fmm_length=config.numcalc.adaptive_fmm_length,
    )


SLURM_RECORD = Path(".pinna2hrtf") / "slurm-jobs.json"
SLURM_WORKERS = Path(".pinna2hrtf") / "slurm"
SLURM_ACTIVE_STATES = {"PENDING", "RUNNING", "REQUEUED", "REQUEUE_FED", "REQUEUE_HOLD", "RESIZING", "SUSPENDED",
                       "CONFIGURING", "COMPLETING", "SIGNALING", "STAGE_OUT", "STOPPED"}
SLURM_CANCEL_HINT = "cancel them with Pinna2HRTF numcalc --config <settings> --cancel"


def run_numcalc_slurm(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    from .NumCalc import solver_inputs
    from .Outputs import write_json
    root = config.paths.output_dir
    jobs = slurm_jobs(root) if dry_run else release_finished_slurm_jobs(root)
    unknown = [job for job in jobs if job["State"] == "unknown"]
    if unknown:
        raise RuntimeError(f"Cannot query Slurm for {describe_slurm_jobs(unknown)}. Run this command where squeue or sacct is available, or {SLURM_CANCEL_HINT}.")
    active = {job["Side"]: job for job in jobs}
    missing = []
    for project_dir in project_dirs(config):
        if project_dir.name in active:
            logger(f"{project_dir.name}: Slurm job {active[project_dir.name]['JobId']} is still active and is not submitted again")
        else:
            missing.append(project_dir)
    if not missing:
        raise RuntimeError(slurm_busy_message(jobs))
    recorded = [slurm_record_entry(job) for job in jobs]
    submitted = []
    plans = [(project, solver_inputs(project)[1]) for project in missing]
    for project_dir, steps in plans:
        side = project_dir.name
        worker_relative = SLURM_WORKERS / f"numcalc-{side.lower()}-{datetime.now():%Y%m%d-%H%M%S}-{uuid.uuid4().hex[:8]}.sh"
        worker = root / worker_relative
        command = [
            "sbatch",
            "--parsable",
            f"--job-name={project_dir.parent.parent.name}_{side}_NumCalc",
            f"--partition={config.numcalc.partition}",
            f"--qos={config.numcalc.qos}",
            f"--time={config.numcalc.time_limit}",
            f"--mem={config.numcalc.memory}",
            f"--array=1-{steps}%{config.numcalc.array_concurrency}",
            f"--output={root}/slurm-%x-%A_%a.out",
            str(worker),
            str(project_dir),
        ]
        logger(shlex.join(command))
        if dry_run:
            continue
        worker.parent.mkdir(parents=True, exist_ok=True)
        with open(worker, "x", encoding="utf-8", newline="\n") as stream:
            stream.write(slurm_worker_text(config))
        worker.chmod(0o555)
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            raise RuntimeError(slurm_submission_failure(side, "sbatch did not reply within 5 minutes and may have queued the job. Check squeue before submitting again", submitted)) from None
        except OSError as error:
            worker.unlink(missing_ok=True)
            raise RuntimeError(slurm_submission_failure(side, f"sbatch is unavailable ({error.strerror or error})", submitted)) from None
        if result.returncode != 0:
            worker.unlink(missing_ok=True)
            raise RuntimeError(slurm_submission_failure(side, f"sbatch failed: {result.stderr.strip() or result.returncode}", submitted))
        reply = result.stdout.strip().splitlines()
        job_id, _, cluster = (reply[-1] if reply else "").strip().partition(";")
        if not job_id.isdigit():
            raise RuntimeError(slurm_submission_failure(side, f"sbatch returned no job ID ({result.stdout.strip()!r}) and may have queued the job. Check squeue before submitting again", submitted))
        entry = {"Side": side, "JobId": job_id, "Cluster": cluster or None, "Project": project_dir.relative_to(root).as_posix(),
                 "Steps": steps, "SubmittedUtc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "Worker": worker_relative.as_posix(), "WorkerSha256": sha256(worker).upper()}
        try:
            write_json(root / SLURM_RECORD, {"Version": 1, "Jobs": [*recorded, entry]})
        except BaseException:
            slurm_command(entry, "scancel", job_id)
            raise
        recorded.append(entry)
        submitted.append(entry)
        logger(f"{side}: submitted Slurm job {job_id} for {steps} frequency steps")


def slurm_submission_failure(side: str, reason: str, submitted: list[dict]) -> str:
    message = f"The {side} ear was not submitted: {reason}."
    if submitted:
        message += f" {describe_slurm_jobs(submitted)} stays queued and recorded. Run the command again to submit only the missing ear, or {SLURM_CANCEL_HINT}."
    return message


def describe_slurm_jobs(jobs: Iterable[dict]) -> str:
    return ", ".join(f"{job['Side']} job {job['JobId']}" for job in jobs)


def slurm_record_entry(job: dict) -> dict:
    return {key: value for key, value in job.items() if key != "State"}


def slurm_command(job: dict, *command: str) -> subprocess.CompletedProcess | None:
    cluster = ["--clusters", job["Cluster"]] if job.get("Cluster") else []
    try:
        return subprocess.run([*command, *cluster], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None


def slurm_job_state(job: dict) -> str:
    queue = slurm_command(job, "squeue", "--noheader", "--jobs", job["JobId"], "--format", "%i")
    if queue is not None:
        if queue.returncode == 0:
            listed = any(line.strip().split("_")[0] == job["JobId"] for line in queue.stdout.splitlines())
            return "active" if listed else "finished"
        if "invalid job id" in queue.stderr.lower():
            return "finished"
    accounting = slurm_command(job, "sacct", "--noheader", "--allocations", "--parsable2", "--jobs", job["JobId"], "--format", "State")
    if accounting is not None and accounting.returncode == 0:
        states = {line.split()[0].upper() for line in accounting.stdout.splitlines() if line.strip()}
        if states:
            return "active" if states & SLURM_ACTIVE_STATES else "finished"
    return "finished" if job.get("Cancelled") else "unknown"


def slurm_jobs(root: Path) -> list[dict]:
    path = root / SLURM_RECORD
    if not path.is_file():
        return []
    record = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(record, dict) or record.get("Version") != 1 or not isinstance(record.get("Jobs"), list) \
            or not all(isinstance(job, dict) and job.get("Side") in ("Left", "Right") and str(job.get("JobId", "")).isdigit() for job in record["Jobs"]):
        raise ValueError(f"Unsupported Slurm job record: {path}")
    return [dict(job, State=slurm_job_state(job)) for job in record["Jobs"]]


def release_finished_slurm_jobs(root: Path) -> list[dict]:
    from .Outputs import write_json
    jobs = slurm_jobs(root)
    remaining = [job for job in jobs if job["State"] != "finished"]
    if len(remaining) != len(jobs):
        write_json(root / SLURM_RECORD, {"Version": 1, "Jobs": [slurm_record_entry(job) for job in remaining]})
        for job in jobs:
            if job["State"] == "finished":
                remove_slurm_worker(root, job)
    return remaining


def remove_slurm_worker(root: Path, job: dict) -> None:
    relative = PurePosixPath(str(job.get("Worker", "")))
    if relative.parent != PurePosixPath(SLURM_WORKERS.as_posix()) or not relative.name.endswith(".sh"):
        return
    worker = root / relative
    if worker.is_symlink() or not worker.is_file() or sha256(worker).upper() != str(job.get("WorkerSha256", "")).upper():
        return
    worker.unlink()


def cancel_numcalc_slurm(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    from .Outputs import write_json
    root = config.paths.output_dir
    if dry_run:
        for job in slurm_jobs(root):
            logger(f"{job['Side']}: Slurm job {job['JobId']} is {job['State']}")
        return
    with _output_manifest_lock(root) as held:
        if not held:
            raise RuntimeError("Project outputs are busy")
        jobs = release_finished_slurm_jobs(root)
        if not jobs:
            logger("No active Slurm jobs for this project")
            return
        failures = []
        for job in jobs:
            result = slurm_command(job, "scancel", job["JobId"])
            if result is not None and (result.returncode == 0 or "invalid job id" in result.stderr.lower()):
                job["Cancelled"] = True
                logger(f"{job['Side']}: cancelled Slurm job {job['JobId']}")
            else:
                failures.append(job)
        write_json(root / SLURM_RECORD, {"Version": 1, "Jobs": [slurm_record_entry(job) for job in jobs]})
    if failures:
        raise RuntimeError(f"Could not cancel {describe_slurm_jobs(failures)}. Check scancel and squeue on the cluster.")


def slurm_busy_message(jobs: Iterable[dict]) -> str:
    return f"NumCalc is running on Slurm ({describe_slurm_jobs(jobs)}). Wait for the jobs to finish, or {SLURM_CANCEL_HINT}."


def require_no_slurm_jobs(root: Path) -> None:
    jobs = [job for job in slurm_jobs(root) if job["State"] != "finished"]
    if jobs:
        raise RuntimeError(slurm_busy_message(jobs))


def slurm_worker_text(config: PipelineConfig) -> str:
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
    if not projects:
        raise ValueError("No projects were provided for SOFA export")
    if len(projects) == 2:
        from mesh2hrtf.Output2HRTF.merge_sofa_files import _merge_sofa_files
        import numpy as np
        import sofar
        ears = [{source.name: source for source in (project / "Output2HRTF").glob("*.sofa")} for project in projects]
        if not ears[0] or set(ears[0]) != set(ears[1]):
            raise ValueError("Left and right projects must contain matching, non-empty SOFA file sets")
        for name in sorted(ears[0]):
            left_path, right_path = (ear[name] for ear in ears)
            left, right = (sofar.read_sofa(str(path)) for path in (left_path, right_path))
            left_positions, right_positions = (np.asarray(sofa.SourcePosition) for sofa in (left, right))
            if (left.SourcePosition_Type != right.SourcePosition_Type
                    or left.SourcePosition_Units != right.SourcePosition_Units
                    or left_positions.shape != right_positions.shape
                    or not np.allclose(left_positions, right_positions, atol=1e-8, rtol=0)):
                raise ValueError(f"Left and right SOFA source positions or their order differ for {name}. Use the same evaluation grid for both ears.")
            target = output_dir / (Path(name).stem + "_merged.sofa")
            _merge_sofa_files((str(left_path), str(right_path)), str(target))
            if not target.is_file():
                raise ValueError(f"SOFA merge did not produce {target}")
    elif len(projects) == 1:
        files = sorted((projects[0] / "Output2HRTF").glob("*.sofa"))
        if not files:
            raise ValueError(f"No SOFA files found for {projects[0]}")
        for source in files:
            shutil.copy2(source, output_dir / source.name)
    else:
        raise ValueError("SOFA export requires one or two projects")


def inspect_sofa_files(output_dir: Path) -> None:
    import matplotlib
    matplotlib.use("Agg", force=True)
    import mesh2hrtf as m2h
    for plane in ["horizontal", "median"]:
        m2h.inspect_sofa_files(str(output_dir), pattern="HRIR", plot="3D", plane=plane)


def run_postprocessing(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    from .SofaIO import install_windows_paths
    install_windows_paths()
    emit_live_event("Converting simulation results to SOFA")
    logger(f"Running postprocessing into {config.postprocessing.output_sofa_dir}")
    if dry_run:
        return
    import mesh2hrtf as m2h
    output_dir = config.postprocessing.output_sofa_dir
    if config.postprocessing.spatial_upsampling:
        from .Postprocessing.spatial_upsampling import resolve_dependencies
        resolve_dependencies(config.postprocessing)
    validate_preprocessing_inputs(config, logger, allow_legacy=True)
    root = config.paths.output_dir.resolve()
    destination = output_dir.resolve()
    protected = [root / name for name in ("Input", "Projects", "Intermediates", "Prepared", "Manual PPM", "MeshEdits", "Logs", ".pinna2hrtf")]
    protected += [p.resolve() for p in (config.paths.left_ear, config.paths.right_ear, config.scan_preparation.scan_path) if p is not None]
    protected += [Path(p).resolve() for p in json.loads(os.environ.get("PINNA2HRTF_PROTECTED_INPUTS", "[]")) if p]
    if destination == destination.parent or destination == root or destination in root.parents or any(p == destination or p in destination.parents or destination in p.parents for p in protected):
        raise ValueError("Choose a separate SOFA output subfolder without inputs or project work.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".pinna-export-", dir=destination.parent))
    published = False
    try:
        _export_postprocessing(config, staging, logger)
        with _output_manifest_lock(root) as can_record:
            published_files = _publish_export(staging, destination, config.postprocessing.overwrite, root)
            if can_record and destination.is_relative_to(root):
                _record_published_outputs(root, published_files, logger)
            else:
                logger("The active stage records the published files at completion.")
        published = True
    finally:
        backups = staging / ".backups"
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
    if relative in mapping:
        return relative
    folded = relative.casefold()
    return next((key for key in mapping if key.casefold() == folded), None)


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
        info = path.stat()
        os.utime(path, ns=(info.st_atime_ns, info.st_mtime_ns - info.st_mtime_ns % 1_000_000_000))
        info = path.stat()
        entry = {"Stage": "Postprocessing", "Size": info.st_size,
                 "ModifiedUtcTicks": info.st_mtime_ns // 100 + _DOTNET_EPOCH_TICKS,
                 "Sha256": sha256(path).upper()}
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
    from .Outputs import classify, write_json
    from .Project import publish_copy
    external = project_root is not None and not destination.is_relative_to(project_root)
    ledger = project_root / ".pinna2hrtf/external-sofa-outputs.json" if external else None
    if ledger and ledger.resolve() != ledger:
        raise ValueError("Linked SOFA ownership file")
    external_files = json.loads(ledger.read_text(encoding="utf-8-sig")) if ledger and ledger.exists() else {}
    owned_files = _read_output_manifest(project_root)["Files"] if project_root and not external else {}
    try:
        for source in list(staging.rglob("*")):
            if not source.is_file() or backups in source.parents:
                continue
            relative = source.relative_to(staging)
            if external and classify("HRTF/" + relative.as_posix()) != "Postprocessing":
                continue
            target = destination / relative
            if target.is_symlink() or any(p.is_symlink() for p in target.parents):
                raise ValueError("Linked export paths are not supported.")
            target.parent.mkdir(parents=True, exist_ok=True)
            backup = backups / relative
            if not overwrite:
                publish_copy(source, target)
                installed.append((target, backup))
            elif target.exists():
                if external:
                    if sha256(target).upper() != external_files.get(str(target), "").upper():
                        raise ValueError(f"Keeping modified or untracked output: {target}")
                elif project_root is not None:
                    key = _manifest_key(owned_files, target.relative_to(project_root).as_posix())
                    owned = owned_files.get(key) if key is not None else None
                    if not isinstance(owned, dict) or sha256(target).lower() != str(owned.get("Sha256", "")).lower():
                        raise ValueError(f"Keeping modified or untracked output: {target}. Move it away, then export again.")
                backup.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(target, backup)
            if overwrite:
                installed.append((target, backup))
                source.replace(target)
            if external:
                external_files[str(target)] = sha256(target)
        if ledger:
            if not any(target.suffix.lower() == ".sofa" for target, _ in installed):
                raise ValueError("Postprocessing produced no SOFA files")
            write_json(ledger, external_files)
    except BaseException:
        for target, backup in reversed(installed):
            if backup.exists():
                backup.replace(target)
            else:
                target.unlink(missing_ok=True)
        raise
    return [target for target, _ in installed]


def validate_hrir_frequencies(project: Path) -> None:
    """Reject frequency vectors that cannot map onto the HRIR FFT bins."""
    import numpy as np

    with (project / "parameters.json").open(encoding="utf-8") as stream:
        parameters = json.load(stream)
    if not parameters.get("computeHRIRs", False):
        return
    frequencies = np.asarray(parameters["frequencies"], dtype=float).reshape(-1)
    if len(frequencies) < 2 or not np.all(np.isfinite(frequencies)):
        raise ValueError(f"Invalid HRIR frequency vector in {project}")
    spacing = np.diff(frequencies)
    if np.any(spacing <= 0) or not np.allclose(spacing, spacing[0], atol=0.1, rtol=0) or not np.isclose(frequencies[0], spacing[0], atol=0.1, rtol=0):
        raise ValueError(f"HRIR frequencies in {project} must begin at one frequency step and be evenly spaced")


def _export_postprocessing(config, output_dir, logger):
    import mesh2hrtf as m2h
    from .SolverProjectFiles import snapshot_generated_outputs, claim_generated_outputs
    projects = project_dirs(config)
    snapshots = {project: snapshot_generated_outputs(project) for project in projects}
    for project in projects:
        emit_live_event(f"Converting {project.name} results")
        validate_hrir_frequencies(project)
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
    for project in projects:
        claim_generated_outputs(project, snapshots[project])
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
    parser.add_argument("--numcalc-mode", choices=["local", "slurm"], help="Run NumCalc in this mode for this run only; the saved setting is unchanged.")
    parser.add_argument("--write-template", type=str, help="Write a default config template and exit.")
    parser.add_argument("--cancel", action="store_true", help="Cancel this project's recorded Slurm NumCalc jobs instead of running a stage.")
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
    from .SofaIO import install_windows_paths
    install_windows_paths()
    import mesh2hrtf as m2h
    output_dir = Path(args.output_dir).expanduser().resolve()
    projects = [Path(project).expanduser().resolve() for project in (args.left_project, args.right_project) if project]
    if not projects:
        raise SystemExit("At least one project is required")
    if len(set(projects)) != len(projects):
        raise ValueError("Choose different simulation projects for the left and right ears.")
    output_dir.parent.mkdir(parents=True, exist_ok=True)
    with ExitStack() as locks:
        for project in projects:
            validate_hrir_frequencies(project)
        roots = {project.parent.parent if project.parent.name == "Projects" else project for project in projects}
        for root in sorted(roots):
            if not locks.enter_context(_output_manifest_lock(root)):
                raise RuntimeError(f"Project outputs are busy: {root}")
            require_no_slurm_jobs(root)
        with tempfile.TemporaryDirectory(prefix=".pinna-export-", dir=output_dir.parent) as temporary:
            staging = Path(temporary)
            results = []
            for index, project in enumerate(projects):
                staged_project = staging / str(index)
                staged_project.mkdir()
                shutil.copy2(project / "parameters.json", staged_project / "parameters.json")
                for folder in ("ObjectMeshes", "EvaluationGrids", "NumCalc"):
                    shutil.copytree(project / folder, staged_project / folder, copy_function=link_solver_file)
                m2h.output2hrtf(str(staged_project))
                results.append(staged_project)
            export = staging / "export"
            export.mkdir()
            collect_sofa_files(results, export)
            inspect_sofa_files(export)
            _publish_export(export, output_dir, overwrite=False)


def link_solver_file(source, destination):
    try:
        os.link(source, destination)
    except OSError:
        shutil.copy2(source, destination)


def cli() -> None:
    args = parse_args()
    if args.write_template:
        save_config(template_config(), args.write_template)
        print(f"Wrote {args.write_template}")
        return
    if not args.config:
        raise SystemExit("--config is required unless --write-template is used")
    from .MicrophonePlacement import ignore_stale_placements
    config = load_config(args.config)
    if args.cancel:
        if args.stage != ["numcalc"]:
            raise SystemExit("--cancel applies only to the numcalc stage")
        cancel_numcalc_slurm(config.resolved(), args.dry_run, log_default)
        return
    if args.numcalc_mode:
        config.numcalc.mode = args.numcalc_mode
    if not args.stage or {"all", "preprocessing"} & set(args.stage):
        ignore_stale_placements(config, log_default)
    run_from_config(config, stages=args.stage, dry_run=args.dry_run)


def scan_preparation_cli():
    parser = argparse.ArgumentParser(description="Crop and repair ears from a full-head scan using a project YAML.")
    parser.add_argument("--config", required=True)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    run_scan_preparation(load_config(args.config), args.dry_run, log_default)


if __name__ == "__main__":
    cli()
