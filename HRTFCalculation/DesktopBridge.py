"""Validated project operations used by the Windows desktop app.

JSON requests on stdin and JSON responses on stdout; diagnostics stay on stderr.
Configuration validation and geometry processing remain owned by the pipeline.
"""
from __future__ import annotations

import contextlib
import json
import os
import re
import stat as stat_module
import hashlib
import warnings
from pathlib import Path
import shutil
import sys
import uuid

import yaml

from .Config import PipelineConfig, load_config


def _inside(path: Path, root: Path) -> bool:
    return path == root or root in path.parents


def relocate(value, source: Path, destination: Path):
    """Relocate path values, including paths embedded in identity strings."""
    if isinstance(value, dict):
        return {key: relocate(item, source, destination) for key, item in value.items()}
    if isinstance(value, list):
        return [relocate(item, source, destination) for item in value]
    if isinstance(value, str):
        # Identity records append size/time after a pipe. Plain paths, including
        # Windows drive colons, are handled without splitting on a colon.
        prefix = str(source).replace("\\", "/").rstrip("/")
        spelling = value.replace("\\", "/")
        if spelling.casefold() == prefix.casefold() or spelling.casefold().startswith(prefix.casefold() + "/"):
            return str(destination) + spelling[len(prefix):].replace("/", os.sep)
    return value


def duplicate(command: dict) -> dict:
    from .RunConfig import _output_manifest_lock
    with _output_manifest_lock(Path(command["source"]).resolve()) as held:
        if not held:
            raise RuntimeError("The source project is busy in another app window.")
        return _duplicate_locked(command)


def _duplicate_locked(command: dict) -> dict:
    source = Path(command["source"]).resolve()
    parent = Path(command["parent"]).resolve()
    name = command["name"].strip()
    if not name or name in {".", ".."} or any(c in name for c in '<>:"/\\|?*') or name.endswith((" ", ".")):
        raise ValueError("Enter a valid project name without path separators.")
    if name.split(".")[0].upper() in {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}:
        raise ValueError("This project name is reserved by Windows.")
    destination = parent / name
    if not source.is_dir() or not parent.is_dir():
        raise ValueError("The source project and destination parent must exist.")
    if _inside(destination, source) or _inside(source, destination):
        raise ValueError("Choose a destination outside the original project.")
    if destination.exists():
        raise FileExistsError("The destination already exists; choose another name.")
    # Refuse links rather than copying content outside the selected project.
    for directory, dirs, files in os.walk(source, followlinks=False):
        for child in dirs + files:
            path = Path(directory) / child
            if path.is_symlink() or getattr(path.lstat(), "st_file_attributes", 0) & stat_module.FILE_ATTRIBUTE_REPARSE_POINT:
                raise ValueError("Linked project files cannot be duplicated automatically.")
    staging = parent / (".pinna-copy-" + uuid.uuid4().hex)
    try:
        ignored = {".pinna2hrtf/outputs.lock"}
        def snapshot():
            return {path.relative_to(source).as_posix(): (path.stat().st_size, path.stat().st_mtime_ns)
                    for path in source.rglob("*") if path.is_file() and path.relative_to(source).as_posix() not in ignored}
        before = snapshot()
        shutil.copytree(source, staging, ignore=lambda folder, names: {"outputs.lock"} if Path(folder) == source / ".pinna2hrtf" else set())
        if snapshot() != before:
            raise RuntimeError("The source changed during duplication; no copy was registered.")
        for relative in before:
            original, copied = source / relative, staging / relative
            def digest(path):
                value = hashlib.sha256()
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1 << 20), b""): value.update(block)
                return value.digest()
            if digest(original) != digest(copied):
                raise RuntimeError("The source changed during duplication: " + relative)
        # A copied project never acquires ownership of the original project's
        # external results. Internal SOFA files remain tracked by the main manifest.
        external_ownership = staging / ".pinna2hrtf/external-sofa-outputs.json"
        if external_ownership.exists():
            external_ownership.unlink()
        for path in staging.rglob("*"):
            if path.suffix.lower() not in {".json", ".yaml", ".yml"} or not path.is_file():
                continue
            relative = path.relative_to(staging).as_posix()
            # Only project metadata: never rewrite arbitrary input files/logs.
            if not (relative in {"Project Settings.yaml", ".pinna2hrtf_native_run.yaml", ".pinna2hrtf/generated-output-manifest.json"}
                    or re.fullmatch(r"Prepared/(mesh_preparation|inference|preprocessing)\.json", relative)
                    or re.fullmatch(r"Projects/(Left|Right)/parameters\.json", relative)
                    or re.fullmatch(r"(MeshEdits|Manual PPM)/(Left|Right|AlignedScan)\.json", relative)):
                continue
            raw = path.read_text(encoding="utf-8-sig")
            data = json.loads(raw) if path.suffix == ".json" else yaml.safe_load(raw)
            original_data = data
            data = relocate(data, source, destination)
            if isinstance(data, dict) and "preprocessing" in data:
                data["preprocessing"].pop("source_position_input_left", None)
                data["preprocessing"].pop("source_position_input_right", None)
            if data == original_data:
                continue
            path.write_text(json.dumps(data, indent=2, allow_nan=False) if path.suffix == ".json" else yaml.safe_dump(data, sort_keys=False), encoding="utf-8")
        # Rewritten owned metadata receives new fingerprints. Geometry timestamps
        # and bytes are preserved by copytree/copy2.
        manifest = staging / ".pinna2hrtf/generated-output-manifest.json"
        if manifest.is_file():
            data = json.loads(manifest.read_text(encoding="utf-8-sig"))
            for relative, entry in data.get("Files", {}).items():
                copied = staging / relative
                original = source / relative
                if not copied.is_file() or not original.is_file():
                    continue
                # Never bless an external modification to an owned file.
                if hashlib.sha256(original.read_bytes()).hexdigest().lower() != entry.get("Sha256", "").lower():
                    continue
                stat = copied.stat()
                entry.update(Size=stat.st_size, ModifiedUtcTicks=stat.st_mtime_ns // 100 + 621355968000000000,
                             Sha256=hashlib.sha256(copied.read_bytes()).hexdigest())
            data["Pending"] = None
            manifest.write_text(json.dumps(data, indent=2), encoding="utf-8")
        project = relocate(command["project"], source, destination)
        project.update(Id=str(uuid.uuid4()), Name=name, SaveLocation=str(destination))
        project["Settings"]["Preprocessing"]["SourcePositionInputLeft"] = None
        project["Settings"]["Preprocessing"]["SourcePositionInputRight"] = None
        # Relocate the preserved configuration rather than leaving its JSON string
        # pointing back to the original project.
        preserved = project.get("PreservedConfigJSON")
        if preserved:
            project["PreservedConfigJSON"] = json.dumps(relocate(json.loads(preserved), source, destination))
        # No existing destination is ever replaced.
        staging.rename(destination)
        return {"project": project}
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def execute(command: dict) -> dict:
    action = command["action"]
    if action == "load":
        with warnings.catch_warnings(record=True) as notices:
            warnings.simplefilter("always")
            config = load_config(command["path"])
        mapping = config.model_dump(mode="json")
        if command.get("folder"):
            # Read the original root spelling as well: a POSIX absolute path
            # becomes drive-relative when interpreted on Windows.
            from .Compatibility import read_settings
            _, text, _ = read_settings(command["path"])
            original = yaml.safe_load(text) or {}
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
                    # Windows resolution may have prefixed C: to /Users/...
                    if str(old_root).startswith("/") and len(spelling) > 2 and spelling[1] == ":":
                        spelling = spelling[2:]
                    if spelling.casefold() == prefix.casefold() or spelling.casefold().startswith(prefix.casefold() + "/"):
                        return new_root + spelling[len(prefix):].replace("/", os.sep)
                return value
            mapping = portable(mapping)
            mapping["paths"]["output_dir"] = new_root
        return {"config": mapping, "warnings": [str(notice.message) for notice in notices]}
    if action == "validate":
        config = PipelineConfig.model_validate(command["config"])
        return {"config": config.model_dump(mode="json"), "yaml": yaml.safe_dump(config.model_dump(mode="json"), sort_keys=False)}
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


def main():
    with contextlib.redirect_stdout(sys.stderr):
        result = execute(json.load(sys.stdin))
    print(json.dumps(result, allow_nan=False))


if __name__ == "__main__":
    main()
