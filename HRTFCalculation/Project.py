from __future__ import annotations

import contextlib
import copy
import hashlib
import json
import math
import os
import stat as stat_module
import tempfile

from .FileIdentity import sha256
import warnings
from pathlib import Path
import shutil
import sys
import uuid

import yaml

from .Config import DEFAULT_EVALUATION_GRID, PipelineConfig, config_from_text, default_resource, load_config
from .Compatibility import decode_settings, read_settings
from .MicrophonePlacement import ignore_stale_placements, placements_path, read_placements, statuses, updated_placements


class SettingsRevisionConflict(Exception):
    pass


def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def relocate(value, source, destination: Path):
    """Relocate path values, including paths embedded in identity strings."""
    if not source:
        return value
    if isinstance(value, dict):
        return {key: relocate(item, source, destination) for key, item in value.items()}
    if isinstance(value, list):
        return [relocate(item, source, destination) for item in value]
    if isinstance(value, str):
        spelling = value.replace("\\", "/")
        identity = os.path.normcase(spelling).replace("\\", "/")
        for root in source:
            prefix = str(root).replace("\\", "/").rstrip("/")
            base = os.path.normcase(prefix).replace("\\", "/")
            if identity == base or identity.startswith(base + "/"):
                return str(destination) + spelling[len(prefix):].replace("/", os.sep)
    return value


def publish_copy(staging: Path, destination: Path):
    if os.name == "nt":
        staging.rename(destination)
        return
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        status = libc.renamex_np(os.fsencode(staging), os.fsencode(destination), 4)
    else:
        status = libc.renameat2(-100, os.fsencode(staging), -100, os.fsencode(destination), 1)
    if status:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def duplicate(command: dict) -> dict:
    from .RunConfig import _output_manifest_lock
    source = Path(command["source"]).resolve() if command["source"] else None
    if source is None or not source.is_dir():
        if command.get("empty_project") and (source is None or not source.exists()):
            return _duplicate_locked(command, source=None)
        raise ValueError("The source project must exist.")
    with _output_manifest_lock(source) as held:
        if not held:
            raise RuntimeError("The source project is busy in another app window.")
        return _duplicate_locked(command, source)


def _duplicate_locked(command: dict, source: Path | None) -> dict:
    from .Outputs import classify
    roots = tuple(dict.fromkeys((source, Path(command["source"]).absolute()))) if source else ()
    parent = Path(command["parent"]).resolve()
    name = command["name"].strip()
    if not name or name in {".", ".."} or any(c in name for c in '<>:"/\\|?*') or name.endswith((" ", ".")):
        raise ValueError("Enter a valid project name without path separators.")
    if name.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}:
        raise ValueError("This project name is reserved by Windows.")
    destination = parent / name
    for root in command.get("project_roots", []):
        if root and _inside(destination, Path(root).resolve()):
            raise ValueError("Choose a destination outside existing project folders.")
    if source and (_inside(destination, source) or _inside(source, destination)):
        raise ValueError("Choose a destination outside the original project.")
    if destination.exists():
        raise FileExistsError("The destination already exists; choose another name.")
    parent.mkdir(parents=True, exist_ok=True)
    for directory, dirs, files in (os.walk(source, followlinks=False) if source else ()):
        for child in dirs + files:
            path = Path(directory) / child
            if path.is_symlink() or getattr(path.lstat(), "st_file_attributes", 0) & stat_module.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError("Linked project files cannot be duplicated automatically.")
    staging = parent / (".pinna-copy-" + uuid.uuid4().hex)
    try:
        uncopied = {"outputs.lock", "settings.lock", "slurm-jobs.json", "slurm"}
        def copied(relative):
            parts = relative.split("/")
            return not (len(parts) > 1 and parts[0] == ".pinna2hrtf" and parts[1] in uncopied)
        def snapshot():
            return {path.relative_to(source).as_posix(): (path.stat().st_size, path.stat().st_mtime_ns)
                    for path in source.rglob("*") if path.is_file() and copied(path.relative_to(source).as_posix())}
        before = snapshot() if source else {}
        if not source:
            staging.mkdir()
        else:
            shutil.copytree(source, staging, ignore=lambda folder, names: uncopied & set(names) if Path(folder) == source / ".pinna2hrtf" else set())
        if source and snapshot() != before:
            raise RuntimeError("The source changed during duplication; no copy was registered.")
        for relative in before:
            original, copied = source / relative, staging / relative
            if sha256(original) != sha256(copied):
                raise RuntimeError("The source changed during duplication: " + relative)
        external_ownership = staging / ".pinna2hrtf/external-sofa-outputs.json"
        if external_ownership.exists():
            external_ownership.unlink()
        for path in staging.rglob("*"):
            if path.suffix.lower() not in {".json", ".yaml", ".yml"} or not path.is_file():
                continue
            relative = path.relative_to(staging).as_posix()
            if relative not in {"pipeline.yaml", "Project Settings.yaml", ".pinna2hrtf/generated-output-manifest.json"} and not classify(relative):
                continue
            _, raw, _ = read_settings(path)
            if path.suffix == ".json":
                try:
                    data = json.loads(raw)
                except json.JSONDecodeError:
                    continue
            else:
                data = yaml.safe_load(raw)
            original_data = data
            data = relocate(data, roots, destination)
            if path.suffix != ".json" and isinstance(data, dict):
                if not isinstance(data.get("preprocessing"), dict):
                    data["preprocessing"] = {}
                data["preprocessing"]["title"] = name
            if data == original_data:
                continue
            path.write_text(json.dumps(data, indent=2, allow_nan=False) if path.suffix == ".json" else yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
        manifest = staging / ".pinna2hrtf/generated-output-manifest.json"
        if manifest.is_file():
            data = json.loads(manifest.read_text(encoding="utf-8-sig"))
            for relative, entry in data.get("Files", {}).items():
                copied = staging / relative
                if not _inside(copied.resolve(), staging):
                    raise ValueError("Invalid relative path in output manifest")
                original = source / relative
                if not copied.is_file() or not original.is_file():
                    continue
                if sha256(original).lower() != entry.get("Sha256", "").lower():
                    continue
                stat = copied.stat()
                entry.update(Size=stat.st_size, ModifiedUtcTicks=stat.st_mtime_ns // 100 + 621355968000000000,
                             Sha256=sha256(copied))
            data["Pending"] = None
            manifest.write_text(json.dumps(data, indent=2), encoding="utf-8")
        revision = settings_revision(staging / "Project Settings.yaml")
        if "mac_record" in command:
            record = relocate(command["mac_record"], roots, destination)
            record.update(id=str(uuid.uuid4()), name=name, saveLocation=str(destination), settingsRevision=revision)
            record.pop("stageOutcomes", None)
            if record.get("preservedConfigJSON"):
                record["preservedConfigJSON"] = json.dumps(relocate(json.loads(record["preservedConfigJSON"]), roots, destination))
            publish_copy(staging, destination)
            return {"project": record}
        if "project" not in command:
            publish_copy(staging, destination)
            return {"path": str(destination)}
        project = relocate(command["project"], roots, destination)
        project.update(Id=str(uuid.uuid4()), Name=name, SaveLocation=str(destination), SettingsRevision=revision)
        from .StageReceipt import windows_mesh_identity
        original_settings = command["project"]["Settings"]["Preprocessing"]
        settings = project["Settings"]["Preprocessing"]
        for key in ("SourcePositionInputLeft", "SourcePositionInputRight"):
            original = original_settings.get(key) or {}
            position = settings.get(key)
            mesh = original.get("MeshPath")
            identity = windows_mesh_identity(mesh) if mesh else ""
            if position and identity and original.get("MeshIdentity") == identity:
                target = Path(position["MeshPath"])
                local_mesh = staging / target.relative_to(destination) if target.is_relative_to(destination) else target
                suffix = windows_mesh_identity(local_mesh)
                if suffix:
                    position["MeshIdentity"] = ":".join([str(target.absolute()).lower(), *suffix.rsplit(":", 3)[1:]])
                    continue
            settings[key] = None
        preserved = project.get("PreservedConfigJSON")
        if preserved:
            project["PreservedConfigJSON"] = json.dumps(relocate(json.loads(preserved), roots, destination))
        publish_copy(staging, destination)
        return {"project": project}
    finally:
        if staging.exists():
            shutil.rmtree(staging)


EDITABLE_SETTINGS = {
    "scan_preparation": (
        "enabled", "scan_path", "original_scan_path", "rotation_degrees", "prepare_left",
        "prepare_right", "target_edge_mm", "left_margin_mm", "right_margin_mm", "side_min_mm",
        "side_max_mm", "require_manual_review", "reviewed_left", "reviewed_right",
    ),
    "paths": (
        "edited_left_ear", "edited_right_ear", "left_ear", "right_ear", "output_dir",
        "external_deps_dir", "mesh2hrtf_path", "numcalc_executable", "mesh_grading_executable", "evaluation_grid",
    ),
    "inference": (
        "enabled", "model_config_file", "model_checkpoint", "target_left_folder",
        "target_right_folder", "prediction_left_folder", "prediction_right_folder",
        "use_predictions_for_preprocessing",
    ),
    "ui": (
        "ear_model_method",
    ),
    "manual_ppm": (
        "enabled", "left_mesh", "right_mesh", "left_parameters", "right_parameters", "left_blend",
        "right_blend", "left_source", "right_source", "left_source_identity",
        "right_source_identity", "template_blend",
    ),
    "preprocessing": (
        "title", "ear_distance", "head_radius", "min_frequency", "max_frequency",
        "frequency_step_count", "source_assignment_face_count", "source_position_input_left",
        "source_position_input_right", "mesh_min_edge_length", "mesh_max_edge_length",
        "mesh_max_error", "mesh_gamma", "mesh_gamma_opposite", "skip_mesh_grading", "head_radius_scale",
        "head_width_scale", "head_height_scale", "head_y_deformation", "head_adaptive_ovalness",
        "head_ovalness_strength", "head_min_width_scale", "head_max_height_scale",
    ),
    "numcalc": (
        "max_instances", "max_cpu_load", "adaptive_fmm_length",
    ),
    "postprocessing": (
        "overwrite", "output_sofa_dir", "normalize", "level_offset_db", "resample_hrirs",
        "sampling_rate", "spatial_upsampling", "spatial_subdivisions", "spatial_normalize",
        "matlab_executable", "amt_path",
    ),
}


DEPRECATED_SETTINGS = {"matlab_executable", "amt_path"}


def settings_revision(path: Path | None) -> str | None:
    try:
        return sha256(path) if path is not None else None
    except FileNotFoundError:
        return None


@contextlib.contextmanager
def settings_lock(path: Path, create: bool = True):
    metadata = path.parent / ".pinna2hrtf"
    if create:
        metadata.mkdir(parents=True, exist_ok=True)
    try:
        handle = (metadata / "settings.lock").open("a+b")
    except OSError:
        if create:
            raise
        handle = None
    if handle is None:
        yield
        return
    with handle:
        if os.name == "nt":
            import msvcrt
            handle.seek(0)
            msvcrt.locking(handle.fileno(), msvcrt.LK_LOCK, 1)
            try:
                yield
            finally:
                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def settings_mapping(raw: bytes) -> dict:
    _, text, _ = decode_settings(raw)
    mapping = yaml.safe_load(text)
    return mapping if isinstance(mapping, dict) else {}


def saved_settings(path: Path | None) -> dict | None:
    if path is None or not path.is_file():
        return None
    return settings_mapping(path.read_bytes())


def loaded_settings(path: Path) -> tuple[bytes, PipelineConfig, list[str], dict]:
    with settings_lock(path, create=False):
        raw = path.read_bytes()
        with warnings.catch_warnings(record=True) as notices:
            warnings.simplefilter("always")
            config = config_from_text(decode_settings(raw)[1], path.parent)
        placements = read_placements(config.paths.output_dir)
    return raw, config, [str(notice.message) for notice in notices], placements


def settings_document(command: dict, saved: dict | None) -> tuple[PipelineConfig, dict, str, bool]:
    edited = command["config"]
    merging = "preserved" in command or "revision" in command or command.get("merge") is True
    current = merge_settings(edited, command.get("preserved"), saved) if merging else edited
    config = PipelineConfig.model_validate(current)
    mapping = config.model_dump(mode="json")
    serialized = yaml.safe_dump(current if command.get("preserve_fields") else mapping, sort_keys=False)
    return config, mapping, serialized, merging


def save_settings(command: dict, path: Path) -> dict:
    if command.get("stage"):
        from .SettingsRules import check
        found = check(command["config"], command["stage"])
        if found:
            raise ValueError(found[0]["message"])
    path.parent.mkdir(parents=True, exist_ok=True)
    with settings_lock(path):
        try:
            previous = path.read_bytes()
        except FileNotFoundError:
            previous = None
        if "revision" in command:
            expected = command["revision"]
            if previous is None and expected is not None:
                raise SettingsRevisionConflict(f"{path.name} was removed after it was loaded. Reload the project settings, then try again.")
            if previous is not None and expected is None:
                raise SettingsRevisionConflict(f"{path.name} was created by another save. Reload the project settings, then try again.")
            if previous is not None and hashlib.sha256(previous).hexdigest() != expected:
                raise SettingsRevisionConflict(f"{path.name} changed after it was loaded. Reload the project settings, then try again.")
        config, _, serialized, merging = settings_document(command, settings_mapping(previous) if previous is not None else None)
        placements_file, placements = None, None
        if merging:
            resolved = config.resolved(path.resolve().parent)
            placements_file = placements_path(resolved.paths.output_dir)
            placements = updated_placements(resolved, command["config"].get("preprocessing") or {}, read_placements(resolved.paths.output_dir))
        publish_settings(path, serialized, previous is not None, placements_file, placements)
        return {"path": str(path), "revision": settings_revision(path)}


def publish_settings(path: Path, serialized: str, existed: bool, placements_file: Path | None, placements: dict | None) -> None:
    from .Outputs import replace_text, write_json
    if placements is None:
        replace_text(path, serialized)
        return
    backup = path.with_name(f".{path.name}.{uuid.uuid4().hex}.bak") if existed else None
    if backup is not None:
        shutil.copy2(path, backup)
    try:
        replace_text(path, serialized)
        try:
            placements_file.parent.mkdir(parents=True, exist_ok=True)
            write_json(placements_file, placements)
        except BaseException:
            if backup is not None:
                os.replace(backup, path)
            else:
                path.unlink(missing_ok=True)
            raise
    finally:
        if backup is not None:
            backup.unlink(missing_ok=True)


def merge_settings(edited: dict, preserved: dict | None, saved: dict | None) -> dict:
    merged = copy.deepcopy(preserved if preserved is not None else saved or {})
    previous = saved if saved is not None else preserved or {}
    for section, keys in EDITABLE_SETTINGS.items():
        changes = edited.get(section) or {}
        if not isinstance(merged.get(section), dict):
            merged[section] = dict(changes)
        values = merged[section]
        earlier = previous.get(section) if isinstance(previous.get(section), dict) else {}
        for key in keys:
            if key in changes:
                values[key] = changes[key]
            elif key in earlier:
                values[key] = earlier[key]
            else:
                values.pop(key, None)
        if not values:
            merged.pop(section)
    if "ear_distance" in (edited.get("preprocessing") or {}):
        merged["preprocessing"].pop("head_radius", None)
    return merged


def copy_input(source: Path, folder: Path) -> Path:
    folder.mkdir(parents=True, exist_ok=True)
    digest = sha256(source)
    target = folder / source.name
    if target.exists() and sha256(target) != digest:
        target = folder / f"{source.stem}-{digest[:12]}{source.suffix}"
    if target.exists():
        if sha256(target) != digest:
            raise FileExistsError(f"An input copy already exists with different contents: {target}")
        return target
    with tempfile.NamedTemporaryFile(dir=folder, delete=False) as stream:
        staged = Path(stream.name)
    try:
        shutil.copy2(source, staged)
        if sha256(staged) != digest or sha256(source) != digest:
            raise ValueError("The input changed while it was being copied")
        try:
            publish_copy(staged, target)
        except FileExistsError:
            if sha256(target) != digest:
                raise
    finally:
        staged.unlink(missing_ok=True)
    return target


DEFAULTS_FILE_FORMAT = "Pinna2HRTF.ProjectDefaults"
DEFAULTS_FILE_VERSION = 2
PROJECT_DEFAULT_KEYS = ("project_directory", "input_handling", "evaluation_grid", "minimum_frequency", "maximum_frequency",
                        "frequency_steps", "max_instances", "max_cpu_load", "workflow")


def snake_case(name: str) -> str:
    import re
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def legacy_project_defaults(values: dict) -> dict:
    converted = {snake_case(key): value for key, value in values.items()}
    handling = converted.get("input_handling")
    converted["input_handling"] = {0: "copy", 1: "reference", "Copy": "copy", "Reference": "reference"}.get(handling, handling)
    if isinstance(converted.get("workflow"), dict):
        converted["workflow"] = {snake_case(key): value for key, value in converted["workflow"].items()}
    return converted


def validated_project_defaults(values) -> dict:
    if not isinstance(values, dict) or set(values) != set(PROJECT_DEFAULT_KEYS):
        raise ValueError("Choose a supported Pinna2HRTF project defaults file.")
    if values["input_handling"] not in ("copy", "reference"):
        raise ValueError("Input handling must be copy or reference.")
    directory, grid = values["project_directory"], values["evaluation_grid"]
    if not isinstance(directory, str) or not isinstance(grid, str):
        raise ValueError("The project location and evaluation grid must be text.")
    if directory and not Path(directory).expanduser().is_absolute():
        raise ValueError("The default project location must be an absolute folder.")
    if any(type(values[key]) is not int for key in PROJECT_DEFAULT_KEYS[3:8]):
        raise ValueError("Frequencies, steps, instances and CPU load must be whole numbers.")
    if grid:
        execute({"action": "validate-grid", "path": grid})
    new_project_workflow(values)
    return {key: values[key] for key in PROJECT_DEFAULT_KEYS}


def save_project_defaults(command: dict) -> dict:
    from .Outputs import replace_text
    path = Path(command["path"]).expanduser()
    document = {"format": DEFAULTS_FILE_FORMAT, "version": DEFAULTS_FILE_VERSION, "defaults": validated_project_defaults(command["defaults"])}
    path.parent.mkdir(parents=True, exist_ok=True)
    replace_text(path, json.dumps(document, indent=2, allow_nan=False) + "\n")
    return {"path": str(path)}


def read_project_defaults(command: dict) -> dict:
    path = Path(command["path"]).expanduser()
    if path.stat().st_size > 1024 * 1024:
        raise ValueError("This file is too large to be a project defaults file.")
    try:
        document = json.loads(path.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError as error:
        raise ValueError("Choose a supported Pinna2HRTF project defaults file.") from error
    if not isinstance(document, dict) or document.get("format") != DEFAULTS_FILE_FORMAT or document.get("version") not in (1, DEFAULTS_FILE_VERSION):
        raise ValueError("Choose a supported Pinna2HRTF project defaults file.")
    values = document.get("defaults")
    if document["version"] == 1 and isinstance(values, dict):
        values = legacy_project_defaults(values)
    return {"defaults": validated_project_defaults(values)}


def default_settings() -> dict:
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        mapping = PipelineConfig().model_dump(mode="json")
    return {section: {key: mapping[section][key] for key in keys if key in mapping[section] and key not in DEPRECATED_SETTINGS}
            for section, keys in EDITABLE_SETTINGS.items()}


def new_project_workflow(values: dict) -> dict:
    groups = {
        "scan_preparation": ("prepare_left", "prepare_right", "target_edge_mm", "left_margin_mm", "right_margin_mm", "side_min_mm", "side_max_mm", "require_manual_review"),
        "preprocessing": ("source_assignment_face_count", "mesh_min_edge_length", "mesh_max_edge_length", "mesh_max_error", "mesh_gamma", "mesh_gamma_opposite",
                          "head_radius_scale", "head_width_scale", "head_height_scale", "head_y_deformation", "head_adaptive_ovalness",
                          "head_ovalness_strength", "head_min_width_scale", "head_max_height_scale"),
        "numcalc": ("adaptive_fmm_length",),
        "postprocessing": ("normalize", "level_offset_db", "resample_hrirs", "sampling_rate", "spatial_upsampling", "spatial_subdivisions", "spatial_normalize"),
    }
    workflow = values.get("workflow", {})
    allowed = {key for keys in groups.values() for key in keys} | {"full_head_scan", "ear_model_method", "inference_model"}
    if not isinstance(workflow, dict) or workflow.keys() - allowed:
        raise ValueError("Unsupported new-project workflow defaults.")
    settings = {section: {key: workflow[key] for key in keys if key in workflow} for section, keys in groups.items()}
    settings["scan_preparation"]["enabled"] = workflow.get("full_head_scan", False)
    method = workflow.get("ear_model_method", "none")
    settings["ui"] = {"ear_model_method": method}
    settings["manual_ppm"] = {"enabled": method == "manual"}
    model = workflow.get("inference_model", "Local 3 Views")
    available = {path.stem for path in default_resource("Local 3 Views.yaml").parent.glob("*.yaml")}
    if model not in available:
        raise ValueError("Choose a bundled Mesh2PPM model.")
    settings["inference"] = {"model_config_file": str(default_resource(model + ".yaml")), "model_checkpoint": str(default_resource(model + ".pth")),
                             "enabled": method == "mesh2ppm", "use_predictions_for_preprocessing": method == "mesh2ppm"}
    settings["preprocessing"].update(min_frequency=values["minimum_frequency"], max_frequency=values["maximum_frequency"], frequency_step_count=values["frequency_steps"])
    settings["numcalc"].update(max_instances=values["max_instances"], max_cpu_load=values["max_cpu_load"])
    settings["paths"] = {"evaluation_grid": values.get("evaluation_grid") or DEFAULT_EVALUATION_GRID}
    from .SettingsRules import check
    checked = default_settings()
    for section, entries in settings.items():
        checked[section].update(entries)
    checked["scan_preparation"]["enabled"] = True
    for issue in check(checked):
        if issue["id"] not in {"scan.path", "ear_model.method"}:
            raise ValueError("New-project defaults: " + issue["message"])
    config = PipelineConfig.model_validate(settings)
    return config.model_dump(mode="json", exclude_unset=True)


def execute(command: dict) -> dict:
    action = command["action"]
    if action == "validate-grid":
        grid = Path(command["path"]).expanduser().resolve()
        if not all((grid / name).is_file() for name in ("Nodes.txt", "Elements.txt")):
            raise ValueError("Choose a folder with Nodes.txt and Elements.txt.")
        return {"path": str(grid)}
    if action == "new-defaults":
        values = command["defaults"]
        fields = ("minimum_frequency", "maximum_frequency", "frequency_steps", "max_instances", "max_cpu_load")
        if any(type(values[field]) is not int for field in fields):
            raise ValueError("New-project defaults must be whole numbers.")
        minimum, maximum, steps, instances, cpu = (values[field] for field in fields)
        grid = values.get("evaluation_grid", "")
        if grid:
            execute({"action": "validate-grid", "path": grid})
        save_location = Path(command["parent"]).expanduser().resolve() / ("Project " + str(command["index"]) + "-" + str(uuid.uuid4()))
        settings = new_project_workflow(values)
        config = default_settings()
        for section, entries in settings.items():
            config[section].update({key: value for key, value in entries.items() if key in config[section]})
        config["paths"].update(output_dir=str(save_location), evaluation_grid=grid or DEFAULT_EVALUATION_GRID)
        config["preprocessing"].update(title="Project " + str(command["index"]), min_frequency=minimum, max_frequency=maximum, frequency_step_count=steps)
        config["numcalc"].update(max_instances=instances, max_cpu_load=cpu)
        return {"save_location": str(save_location), "config": config,
                "preprocessing": {"min_frequency": minimum, "max_frequency": maximum, "frequency_step_count": steps, "evaluation_grid": grid},
                "numcalc": {"max_instances": instances, "max_cpu_load": cpu}, "settings": settings}
    if action == "defaults":
        return {"config": default_settings()}
    if action == "save-defaults":
        return save_project_defaults(command)
    if action == "read-defaults":
        return read_project_defaults(command)
    if action == "head-preview":
        from .Geometry import head_preview
        return head_preview(command)
    if action == "rules":
        from .SettingsRules import rules
        return rules()
    if action == "check":
        from .SettingsRules import check
        return {"issues": check(command["config"], command.get("stage"))}
    if action in {"recycle-plan", "recycle"}:
        from .ProjectTrash import execute as trash
        return trash(command)
    if action == "prepare-folder":
        path = Path(command["path"])
        if not path.is_absolute() or path == path.parent:
            raise ValueError("Choose an absolute project folder below the filesystem root")
        try:
            path.mkdir(parents=True)
            return {"created": True}
        except FileExistsError:
            if not path.is_dir():
                raise
        if command.get("migrate"):
            names = {entry.name for entry in path.iterdir()}
            if "intermediates" in names and "Intermediates" not in names:
                old = path / "intermediates"
                temp = path / (".pinna-migrate-" + uuid.uuid4().hex)
                publish_copy(old, temp)
                try:
                    publish_copy(temp, path / "Intermediates")
                except OSError:
                    publish_copy(temp, old)
                    raise
        return {"created": False}
    if action in {"stage-status", "record-stage"}:
        from .StageReceipt import execute as receipt
        return receipt(command)
    if action == "publish-editor":
        from .EditorPublication import publish
        return publish(command)
    if action == "copy-input":
        return {"path": str(copy_input(Path(command["source"]), Path(command["folder"])))}
    if action == "validate-prepared":
        from .ScanPreparation import validate_prepared
        validate_prepared(load_config(command["path"]))
        return {"valid": True}
    if action == "read":
        path = Path(command["path"])
        if not command.get("with_revision"):
            _, text, _ = read_settings(path)
            mapping = yaml.safe_load(text)
            if not isinstance(mapping, dict):
                raise ValueError("Project settings must contain a mapping")
            return mapping
        with settings_lock(path, create=False):
            raw = path.read_bytes()
            mapping = yaml.safe_load(decode_settings(raw)[1])
            if not isinstance(mapping, dict):
                raise ValueError("Project settings must contain a mapping")
            try:
                config = PipelineConfig.model_validate(mapping).resolved(path.resolve().parent)
                placements = read_placements(config.paths.output_dir)
            except ValueError:
                config = None
        return {"config": mapping, "revision": hashlib.sha256(raw).hexdigest(),
                "microphone_placements": statuses(config, placements) if config is not None else {}}
    if action == "load":
        path = Path(command["path"]).expanduser().resolve()
        raw, config, notices, placements = loaded_settings(path)
        ignore_stale_placements(config, notices.append, placements)
        mapping = config.model_dump(mode="json")
        if command.get("folder"):
            original = settings_mapping(raw)
            old_root = original.get("paths", {}).get("output_dir", "")
            new_root = str(Path(command["folder"]).resolve())
            def portable(value):
                if isinstance(value, dict):
                    return {key: portable(item) for key, item in value.items()}
                if isinstance(value, list):
                    return [portable(item) for item in value]
                if isinstance(value, str) and old_root:
                    spelling = value.replace("\\", "/")
                    prefix = str(old_root).replace("\\", "/").rstrip("/")
                    if str(old_root).startswith("/") and len(spelling) > 2 and spelling[1] == ":":
                        spelling = spelling[2:]
                    if spelling.casefold() == prefix.casefold() or spelling.casefold().startswith(prefix.casefold() + "/"):
                        return new_root + spelling[len(prefix):].replace("/", os.sep)
                return value
            mapping = portable(mapping)
            mapping["paths"]["output_dir"] = new_root
        return {"config": mapping, "warnings": notices, "revision": hashlib.sha256(raw).hexdigest()}
    if action == "save":
        return save_settings(command, Path(command["path"]))
    if action == "validate":
        path = Path(command["path"]) if command.get("path") else None
        _, mapping, serialized, _ = settings_document(command, saved_settings(path))
        return {"config": mapping, "yaml": serialized}
    if action == "duplicate":
        return duplicate(command)
    if action == "validate_outputs":
        from .SofaIO import install_windows_paths
        install_windows_paths()
        import numpy as np
        import sofar
        for path in command["paths"]:
            sofa = sofar.read_sofa(path, verify=True, verbose=False)
            arrays = [np.asarray(getattr(sofa, key)) for key in ("Data_IR", "Data_Real", "Data_Imag") if hasattr(sofa, key)]
            if not arrays or any(not array.size or not np.all(np.isfinite(array)) for array in arrays):
                raise ValueError("SOFA contains missing or nonfinite data: " + path)
        return {"valid": True}
    raise ValueError("Unknown desktop operation: " + action)
