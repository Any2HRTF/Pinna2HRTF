import hashlib
import json
import shutil
import tempfile
from pathlib import Path


GRID_FILES = ("Nodes.txt", "Elements.txt", "torso_grid_manifest.json")


def digest(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected an unchanged regular file: {path}")
    return hashlib.sha256(path.read_bytes()).hexdigest()


def algorithm_identity(names):
    return {name: digest(Path(__file__).parent / name) for name in names}


def source_grid(config):
    from ..Config import DEFAULT_EVALUATION_GRID, BUNDLED_EVALUATION_GRID_PATH
    path = Path(config.paths.evaluation_grid)
    if str(path) == DEFAULT_EVALUATION_GRID:
        return BUNDLED_EVALUATION_GRID_PATH
    return path if path.is_absolute() else config.paths.mesh2hrtf_path / "Mesh2Input/EvaluationGrids/Data" / path


def setup_spec(config):
    grid = source_grid(config)
    settings = config.acoustic_torso
    return {"version": 1, "source": {name: digest(grid / name) for name in ("Nodes.txt", "Elements.txt")},
            "parameters": {"min_source_elevation_deg": settings.min_source_elevation_deg,
                           "max_angular_gap_deg": settings.max_angular_gap_deg, "symmetry": settings.symmetry},
            "algorithm": algorithm_identity(("grid_workflow.py", "torso_reflection_model.py"))}


def grid_path(config):
    key = hashlib.sha256(json.dumps(setup_spec(config), sort_keys=True, allow_nan=False).encode()).hexdigest()
    root = config.paths.output_dir.resolve()
    destination = root / "Intermediates/AcousticTorsoGrids" / key
    if not destination.resolve().is_relative_to(root) or any(p.is_symlink() for p in (destination, *destination.parents) if p != root and p.is_relative_to(root)):
        raise ValueError("Acoustic torso grid output must stay inside the project without symbolic links.")
    return destination


def validate_grid(config):
    grid = grid_path(config)
    receipt_path = grid / "pinna_torso_grid.json"
    if not receipt_path.exists():
        raise ValueError("Run Simulation setup first: the prepared acoustic torso grid is missing.")
    try:
        digest(receipt_path)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValueError("Run Simulation setup first: the prepared acoustic torso grid is missing.") from error
    expected_files = {*GRID_FILES, "requested/Nodes.txt", "requested/Elements.txt"}
    if set(receipt.get("files", {})) != expected_files:
        raise ValueError("The acoustic torso grid receipt is incomplete. Run Simulation setup again.")
    if receipt["setup"] != setup_spec(config):
        raise ValueError("Acoustic torso grid settings changed. Run Simulation setup again.")
    for name, expected in receipt["files"].items():
        if digest(grid / name) != expected:
            raise ValueError("The prepared acoustic torso grid was modified. Restore it or run Simulation setup with a new grid.")
    return grid


def prepare_grid(config, logger=print):
    from .grid_workflow import extend_grid
    spec = setup_spec(config)
    destination = grid_path(config)
    if destination.exists():
        return validate_grid(config)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".torso-grid-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        requested = staging / "requested"
        requested.mkdir()
        for name in ("Nodes.txt", "Elements.txt"):
            shutil.copy2(source_grid(config) / name, requested / name)
            if digest(requested / name) != spec["source"][name]:
                raise ValueError("Evaluation grid changed during acoustic torso preparation.")
        grid = staging / "grid"
        manifest = extend_grid(requested, grid, **spec["parameters"])
        shutil.copytree(requested, grid / "requested")
        files = (*GRID_FILES, "requested/Nodes.txt", "requested/Elements.txt")
        receipt = {"setup": spec, "files": {name: digest(grid / name) for name in files}}
        (grid / "pinna_torso_grid.json").write_text(json.dumps(receipt, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        if setup_spec(config) != spec:
            raise ValueError("Evaluation grid changed during acoustic torso preparation.")
        if destination.exists():
            return validate_grid(config)
        grid.rename(destination)
    logger(f"Acoustic torso grid: {len(manifest['original_node_ids'])} output directions, {len(manifest['added_node_ids'])} helper directions")
    return destination


def export_identity(config):
    return {"parameters": config.acoustic_torso.model_dump(mode="json"),
            "algorithm": algorithm_identity(("__init__.py", "apply_torso.py", "sofa_subset.py", "torso_reflection_model.py", "grid_workflow.py"))}


def process_exports(config, output_dir, logger=print):
    from netCDF4 import Dataset
    from .apply_torso import add_torso_reflection_to_sofa
    from .grid_workflow import trim_to_original_grid
    grid = validate_grid(config)
    settings = config.acoustic_torso
    raw = sorted(Path(output_dir).glob("*.sofa"))
    fir = []
    for path in raw:
        with Dataset(path) as sofa:
            kind = sofa.getncattr("DataType")
            if kind == "FIR":
                fir.append(path)
            elif kind != "TF":
                raise ValueError(f"Unsupported acoustic torso export data type: {kind}")
    if not fir:
        raise ValueError("Acoustic torso modelling requires HRIR output. Enable preprocessing.compute_hrirs.")
    for path in fir:
        logger(f"Applying acoustic torso reflection and shadow to {path.name}")
        corrected = add_torso_reflection_to_sofa(path, g_t=settings.gain,
            min_source_elevation_deg=settings.min_source_elevation_deg,
            interpolation=settings.interpolation, missing_policy=settings.missing_policy,
            delay_model=settings.delay_model, model_source_distance_m=settings.model_source_distance_m,
            apply_shadow=settings.apply_shadow, normalize_reflection_mix=settings.normalize_reflection_mix,
            augmented_grid=grid)
        trimmed = trim_to_original_grid(corrected, grid)
        target = path.with_name(path.stem.replace(grid.name, source_grid(config).name) + "_acTorso.sofa")
        if target.exists():
            raise FileExistsError(target)
        trimmed.rename(target)
        corrected.unlink()
    for path in raw:
        path.unlink()


def mark_geometric_exports(folder):
    from netCDF4 import Dataset
    for path in Path(folder).glob("*.sofa"):
        with Dataset(path, "a") as sofa:
            sofa.setncattr("Pinna2HRTF_TorsoModel", "geometric")


def execute(command):
    action = command["action"]
    if action == "extend-grid":
        from .grid_workflow import extend_grid
        from ..Config import AcousticTorsoConfig
        settings = AcousticTorsoConfig.model_validate(command.get("settings", {}))
        return extend_grid(command["source_grid"], command["output_grid"],
            min_source_elevation_deg=settings.min_source_elevation_deg,
            max_angular_gap_deg=settings.max_angular_gap_deg, symmetry=settings.symmetry)
    if action == "trim":
        from .grid_workflow import trim_to_original_grid
        return {"path": str(trim_to_original_grid(command["path"], command["augmented_grid"], overwrite=command.get("overwrite", False)))}
    if action == "apply":
        from .apply_torso import add_torso_reflection_to_sofa
        from ..Config import AcousticTorsoConfig
        settings = AcousticTorsoConfig.model_validate(command.get("settings", {}))
        return {"path": str(add_torso_reflection_to_sofa(command["path"], g_t=settings.gain,
            min_source_elevation_deg=settings.min_source_elevation_deg,
            max_angular_distance_deg=None if command.get("augmented_grid") else settings.max_angular_gap_deg,
            interpolation=settings.interpolation, missing_policy=settings.missing_policy,
            delay_model=settings.delay_model, model_source_distance_m=settings.model_source_distance_m,
            apply_shadow=settings.apply_shadow, normalize_reflection_mix=settings.normalize_reflection_mix,
            augmented_grid=command.get("augmented_grid"), overwrite=command.get("overwrite", False)))}
    if action == "prepare-grid":
        from ..Config import load_config
        from ..Outputs import stage_outputs
        config = load_config(command["config"])
        if config.preprocessing.torso_mode != "acoustic":
            raise ValueError("Select preprocessing.torso_mode: acoustic first.")
        with stage_outputs(config, "preprocessing", False):
            grid = prepare_grid(config)
        return {"path": str(grid), "manifest": json.loads((grid / "torso_grid_manifest.json").read_text(encoding="utf-8"))}
    raise ValueError("Unknown acoustic torso action: " + str(action))
