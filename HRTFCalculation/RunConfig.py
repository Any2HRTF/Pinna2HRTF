from __future__ import annotations

import argparse
import json
import os
import platform
import subprocess
import shutil
import tempfile
from pathlib import Path
from types import SimpleNamespace
from typing import Callable, Iterable

from .Config import PipelineConfig, load_config, save_config, template_config


Logger = Callable[[str], None]


def log_default(message: str) -> None:
    print(message, flush=True)


def project_dirs(config: PipelineConfig) -> list[Path]:
    return [config.paths.output_dir / "Projects" / side for side, path in (("Left", config.paths.left_ear), ("Right", config.paths.right_ear)) if path is not None]


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
    if config.paths.left_ear is None and config.paths.right_ear is None:
        logger("No ear meshes were selected for inference.")
        return
    if config.paths.left_ear is not None:
        logger(f"Left input mesh: {config.paths.left_ear}")
    if config.paths.right_ear is not None:
        logger(f"Right input mesh: {config.paths.right_ear}")
    if dry_run:
        return
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
    input_paths = [path.resolve() for path in (config.paths.left_ear, config.paths.right_ear) if path is not None]
    for name in legacy_folders:
        legacy_path = config.paths.output_dir / name
        if legacy_path.is_dir() and not any(legacy_path.resolve() in path.parents for path in input_paths):
            shutil.rmtree(legacy_path)
        elif legacy_path.is_file() and legacy_path.resolve() not in input_paths:
            legacy_path.unlink()
    args = SimpleNamespace(
        configuration=str(config.inference.model_config_file),
        model_checkpoint=str(config.inference.model_checkpoint),
        data_dir=str(config.paths.output_dir),
        target_left_folder=str(config.paths.left_ear.parent) if config.paths.left_ear is not None else None,
        target_right_folder=str(config.paths.right_ear.parent) if config.paths.right_ear is not None else None,
        prediction_left_folder=config.inference.prediction_left_folder,
        prediction_right_folder=config.inference.prediction_right_folder,
        prediction_parameters_left_folder=config.inference.prediction_parameters_left_folder,
        prediction_parameters_right_folder=config.inference.prediction_parameters_right_folder,
        intermediates_folder="Intermediates",
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


def preprocessing_input_paths(config: PipelineConfig, logger: Logger) -> tuple[Path | None, Path | None]:
    inputs = []
    for side, source, folder_name in [
        ("left", config.paths.left_ear, config.inference.prediction_left_folder),
        ("right", config.paths.right_ear, config.inference.prediction_right_folder),
    ]:
        if source is None:
            inputs.append(None)
            continue
        selected = source
        if config.inference.use_predictions_for_preprocessing:
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
    numcalc_path = config.paths.numcalc_executable
    if platform.system() == "Windows" and numcalc_path.is_file():
        numcalc_path = numcalc_path.parent
        logger(f"Using Windows NumCalc runtime folder: {numcalc_path}")
    elif " " in str(numcalc_path):
        link_dir = Path(tempfile.gettempdir()) / "Pinna2HRTF"
        link_dir.mkdir(parents=True, exist_ok=True)
        link_path = link_dir / "NumCalc"
        if link_path.exists() or link_path.is_symlink():
            link_path.unlink()
        link_path.symlink_to(numcalc_path)
        numcalc_path = link_path
        logger(f"Using shell-safe NumCalc link: {numcalc_path}")
    logger(f"Local NumCalc project root: {projects_root}")
    if dry_run:
        return
    from .NumCalc import run_local_numcalc
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
            f"bash '{worker}' '{project_dir}'",
        ]
        logger(" ".join(command))
        if not dry_run:
            subprocess.run(command, check=True)


def slurm_worker_text(config: PipelineConfig) -> str:
    adaptive_flag = "-adapt_fmmlength" if config.numcalc.adaptive_fmm_length else ""
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
        f"\"$NUMCALC_EXE\" {adaptive_flag} -istart \"$STEP\" -iend \"$STEP\" > \"NC${{STEP}}-${{STEP}}_log.txt\"",
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
    projects = project_dirs(config)
    for project in projects:
        m2h.output2hrtf(str(project))
    if config.postprocessing.normalize:
        from .Postprocessing.postprocessing import normalize_sofa_files
        for project in projects:
            normalize_sofa_files(project / "Output2HRTF", config.postprocessing.level_offset_db)
    if len(projects) == 2:
        m2h.merge_sofa_files([str(project) for project in projects], savedir=str(output_dir))
    else:
        source_dir = projects[0] / "Output2HRTF"
        for source in source_dir.glob("*.sofa"):
            shutil.copy2(source, output_dir / source.name)
    try:
        for plane in ["horizontal", "median"]:
            m2h.inspect_sofa_files(str(output_dir), pattern="HRIR", plot="3D", plane=plane)
        logger(f"Wrote SOFA visualizations into {output_dir}")
    except Exception as error:
        logger(f"Could not write SOFA visualizations: {error}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=str, help="Path to a pipeline YAML config file.")
    parser.add_argument("--stage", action="append", choices=["all", "inference", "preprocessing", "numcalc", "postprocessing"], help="Stage to run. Can be supplied multiple times.")
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
    numcalc_path = Path(args.numcalc_path).expanduser().resolve()
    if platform.system() == "Windows" and numcalc_path.is_file():
        numcalc_path = numcalc_path.parent
    from .NumCalc import run_local_numcalc
    run_local_numcalc(
        project_path=Path(args.project_path).expanduser().resolve(),
        numcalc_path=numcalc_path,
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
    parser.add_argument("--overwrite", action="store_true")
    return parser.parse_args()


def sofa_cli() -> None:
    args = parse_sofa_args()
    import shutil
    import mesh2hrtf as m2h
    output_dir = Path(args.output_dir)
    if output_dir.exists() and args.overwrite:
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    projects = [project for project in (args.left_project, args.right_project) if project]
    if not projects:
        raise SystemExit("At least one project is required")
    for project in projects:
        m2h.output2hrtf(project)
    if len(projects) == 2:
        m2h.merge_sofa_files(projects, savedir=str(output_dir))
    else:
        for source in Path(projects[0]).joinpath("Output2HRTF").glob("*.sofa"):
            shutil.copy2(source, output_dir / source.name)
    for plane in ["horizontal", "median"]:
        m2h.inspect_sofa_files(str(output_dir), pattern="HRIR", plot="3D", plane=plane)


def cli() -> None:
    args = parse_args()
    if args.write_template:
        save_config(template_config(), args.write_template)
        print(f"Wrote {args.write_template}")
        return
    if not args.config:
        raise SystemExit("--config is required unless --write-template is used")
    run_from_config(load_config(args.config), stages=args.stage, dry_run=args.dry_run)


if __name__ == "__main__":
    cli()
