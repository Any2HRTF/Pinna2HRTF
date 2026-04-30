from __future__ import annotations

import argparse
import json
import os
import subprocess
import shutil
import tempfile
from pathlib import Path
from types import SimpleNamespace
from typing import Callable, Iterable

from .Config import PipelineConfig, default_config, load_config, save_config


Logger = Callable[[str], None]


def log_default(message: str) -> None:
    print(message, flush=True)


def project_dirs(config: PipelineConfig) -> list[Path]:
    return [config.paths.output_dir / "Projects" / "Left", config.paths.output_dir / "Projects" / "Right"]


def run_from_config(config: PipelineConfig, stages: Iterable[str] | None = None, dry_run: bool = False, logger: Logger = log_default) -> None:
    selected = list(stages or ["all"])
    config = config.resolved()
    run_all = "all" in selected
    if "inference" in selected or (run_all and config.inference.enabled):
        run_inference(config, dry_run, logger)
    if "preprocessing" in selected or (run_all and config.preprocessing.enabled):
        run_preprocessing(config, dry_run, logger)
    if "numcalc" in selected or (run_all and config.numcalc.enabled):
        run_numcalc(config, dry_run, logger)
    if "postprocessing" in selected or (run_all and config.postprocessing.enabled):
        run_postprocessing(config, dry_run, logger)


def run_inference(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    logger(f"Running inference in {config.paths.output_dir}")
    logger(f"Left target folder: {config.inference.target_left_folder}")
    logger(f"Right target folder: {config.inference.target_right_folder}")
    if dry_run:
        return
    config.paths.output_dir.mkdir(parents=True, exist_ok=True)
    left_target = config.paths.output_dir / config.inference.target_left_folder
    right_target = config.paths.output_dir / config.inference.target_right_folder
    left_target.mkdir(parents=True, exist_ok=True)
    right_target.mkdir(parents=True, exist_ok=True)
    for source, target in [
        (config.paths.left_ear, left_target / config.paths.left_ear.name),
        (config.paths.right_ear, right_target / config.paths.right_ear.name),
    ]:
        if source.resolve() != target.resolve():
            shutil.copyfile(source, target)
    from .Inference.inference_stl import main
    args = SimpleNamespace(
        configuration=str(config.inference.model_config_file),
        model_checkpoint=str(config.inference.model_checkpoint),
        data_dir=str(config.paths.output_dir),
        target_left_folder=config.inference.target_left_folder,
        target_right_folder=config.inference.target_right_folder,
        prediction_left_folder=config.inference.prediction_left_folder,
        prediction_right_folder=config.inference.prediction_right_folder,
        prediction_parameters_left_folder=config.inference.prediction_parameters_left_folder,
        prediction_parameters_right_folder=config.inference.prediction_parameters_right_folder,
    )
    main(args)


def run_preprocessing(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
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


def preprocessing_input_paths(config: PipelineConfig, logger: Logger) -> tuple[Path, Path]:
    if not config.inference.use_predictions_for_preprocessing:
        return config.paths.left_ear, config.paths.right_ear
    left = predicted_stl(config.paths.output_dir / config.inference.prediction_left_folder, config.paths.left_ear.stem)
    right = predicted_stl(config.paths.output_dir / config.inference.prediction_right_folder, config.paths.right_ear.stem)
    if left is not None and right is not None:
        logger(f"Using inferred left ear for preprocessing: {left}")
        logger(f"Using inferred right ear for preprocessing: {right}")
        return left, right
    logger("No complete inferred STL pair found; preprocessing uses configured input ears.")
    return config.paths.left_ear, config.paths.right_ear


def predicted_stl(folder: Path, preferred_stem: str) -> Path | None:
    if not folder.exists():
        return None
    preferred = folder / f"{preferred_stem}.stl"
    if preferred.exists():
        return preferred
    files = sorted(path for path in folder.iterdir() if path.suffix.lower() == ".stl")
    if len(files) == 1:
        return files[0]
    return None


def run_numcalc(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    if config.numcalc.mode == "slurm":
        run_numcalc_slurm(config, dry_run, logger)
    else:
        run_numcalc_local(config, dry_run, logger)


def run_numcalc_local(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    logger(f"Running local NumCalc with {config.paths.numcalc_executable}")
    projects_root = config.paths.output_dir / "Projects"
    projects = project_dirs(config)
    for project_dir in projects:
        if not (project_dir / "parameters.json").exists():
            raise FileNotFoundError(f"Missing Mesh2HRTF project: {project_dir}")
    if not config.paths.numcalc_executable.exists():
        raise FileNotFoundError(f"Missing NumCalc executable: {config.paths.numcalc_executable}")
    numcalc_executable = config.paths.numcalc_executable
    if " " in str(numcalc_executable):
        link_dir = Path(tempfile.gettempdir()) / "Pinna2HRTF"
        link_dir.mkdir(parents=True, exist_ok=True)
        link_path = link_dir / "NumCalc"
        if link_path.exists() or link_path.is_symlink():
            link_path.unlink()
        link_path.symlink_to(numcalc_executable)
        numcalc_executable = link_path
        logger(f"Using shell-safe NumCalc link: {numcalc_executable}")
    logger(f"Local NumCalc project root: {projects_root}")
    if dry_run:
        return
    import mesh2hrtf as m2h
    m2h.manage_numcalc(
        project_path=str(projects_root),
        numcalc_path=str(numcalc_executable),
        max_instances=config.numcalc.max_instances,
        max_cpu_load=config.numcalc.max_cpu_load,
        confirm_errors=False,
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
            f"bash '{worker}' '{project_dir}'",
        ]
        logger(" ".join(command))
        if not dry_run:
            subprocess.run(command, check=True)


def slurm_worker_text(config: PipelineConfig) -> str:
    return "\n".join([
        "#!/usr/bin/env bash",
        "set -euo pipefail",
        "PROJECT_DIR=\"${1:?missing project dir}\"",
        "STEP=\"${SLURM_ARRAY_TASK_ID:?missing array step}\"",
        f"NUMCALC_EXE=\"{config.paths.numcalc_executable}\"",
        "SOURCE_DIR=\"$PROJECT_DIR/NumCalc/source_1\"",
        "OUTPUT_DIR=\"$SOURCE_DIR/be.out/be.$STEP\"",
        "if [[ -d \"$OUTPUT_DIR\" ]]; then exit 0; fi",
        "cd \"$SOURCE_DIR\"",
        "\"$NUMCALC_EXE\" -istart \"$STEP\" -iend \"$STEP\" > \"NC${STEP}-${STEP}_log.txt\"",
        "",
    ])


def run_postprocessing(config: PipelineConfig, dry_run: bool, logger: Logger) -> None:
    logger(f"Running postprocessing into {config.postprocessing.output_sofa_dir}")
    if dry_run:
        return
    import shutil
    import mesh2hrtf as m2h
    output_dir = config.postprocessing.output_sofa_dir
    if output_dir.exists() and config.postprocessing.overwrite:
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    left, right = project_dirs(config)
    m2h.output2hrtf(str(left))
    m2h.output2hrtf(str(right))
    m2h.merge_sofa_files([str(left), str(right)], savedir=str(output_dir))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=str, help="Path to a pipeline YAML config file.")
    parser.add_argument("--stage", action="append", choices=["all", "inference", "preprocessing", "numcalc", "postprocessing"], help="Stage to run. Can be supplied multiple times.")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--write-template", type=str, help="Write a default config template and exit.")
    return parser.parse_args()


def cli() -> None:
    args = parse_args()
    if args.write_template:
        save_config(default_config(), args.write_template)
        print(f"Wrote {args.write_template}")
        return
    if not args.config:
        raise SystemExit("--config is required unless --write-template is used")
    run_from_config(load_config(args.config), stages=args.stage, dry_run=args.dry_run)


if __name__ == "__main__":
    cli()
