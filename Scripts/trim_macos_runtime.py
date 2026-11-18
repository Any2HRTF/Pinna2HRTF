#!/usr/bin/env python3
"""Trim release staging only; preserve source checkpoints and runtime libraries."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sysconfig


def trim(resources: Path) -> None:
    if resources.is_symlink() or resources.resolve() != resources.absolute():
        raise SystemExit("Runtime trimming requires a physical staging directory")
    if resources.name != "Resources" or resources.parent.name != "Contents" or resources.parent.parent.suffix != ".app":
        raise SystemExit("Runtime trimming must target an app's Contents/Resources")
    if (resources.parent / "_CodeSignature").exists():
        raise SystemExit("Refusing to trim an already signed app; use unsigned release staging")
    site = resources / ".venv/lib/python3.11/site-packages"
    if Path(sysconfig.get_path("purelib")).resolve() != site:
        raise SystemExit("Run trimming with the staged app's Python interpreter")
    if not (resources / "External/bin/ppm_predict").is_file():
        raise SystemExit("The native Core ML helper is missing")

    def checked(path: Path) -> Path:
        path.relative_to(resources)
        if path.is_symlink() or path.resolve() != path:
            raise SystemExit(f"Refusing to trim a linked path: {path}")
        return path

    candidates = [site / "tests", site / "torch/include"]
    for package in ("scipy", "pandas", "pymeshlab", "sympy", "numpy", "networkx", "matplotlib", "shapely", "mpmath", "mesh2hrtf"):
        candidates.extend((site / package).rglob("tests"))
    directories = []
    for path in sorted(candidates, key=lambda p: (len(p.parts), str(p))):
        if not path.exists():
            continue
        checked(path)
        if not path.is_dir():
            raise SystemExit(f"Expected a directory: {path}")
        if not any(parent in path.parents for parent in directories):
            directories.append(path)
    for directory in directories:
        for path in directory.rglob("*"):
            checked(path)

    checkpoints = []
    model_dir = resources / "HRTFCalculation/Inference/resources"
    for path in sorted(model_dir.glob("*.pth")):
        checked(path)
        manifest_path = path.with_suffix(".coreml.json")
        manifest = json.loads(manifest_path.read_text())
        if manifest.get("source_checkpoint_sha256") != hashlib.sha256(path.read_bytes()).hexdigest():
            raise SystemExit(f"Core ML model does not match checkpoint: {path}")
        if manifest.get("precision") != "float32" or manifest.get("compute_units") != "cpuOnly":
            raise SystemExit(f"Unexpected Core ML precision or execution policy: {manifest_path}")
        compiled = model_dir / manifest["model"]
        checked(compiled)
        if not manifest.get("compiled_files"):
            raise SystemExit(f"Compiled Core ML model is empty: {compiled}")
        for relative, expected in manifest["compiled_files"].items():
            file = checked(compiled / relative)
            if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != expected:
                raise SystemExit(f"Compiled Core ML asset is missing or changed: {file}")
        checkpoints.append({"path": str(path.relative_to(resources)),
                            "source_sha256": manifest["source_checkpoint_sha256"],
                            "original_bytes": path.stat().st_size, "bytes": 0,
                            "replacement": str(manifest_path.relative_to(resources))})
    if len(checkpoints) != 4:
        raise SystemExit(f"Expected four source checkpoints, found {len(checkpoints)}")

    import importlib.metadata as metadata
    import tomllib
    from packaging.requirements import Requirement
    from packaging.utils import canonicalize_name

    requirements = tomllib.loads((resources / "pyproject.toml").read_text())["project"]["dependencies"]

    def closure(roots):
        result = {}
        pending = [Requirement(value) for value in roots]
        while pending:
            requirement = pending.pop()
            name = canonicalize_name(requirement.name)
            extras = set(requirement.extras)
            if name in result and extras <= result[name]:
                continue
            result.setdefault(name, set()).update(extras)
            for value in metadata.distribution(name).requires or []:
                dependency = Requirement(value)
                if dependency.marker is None or any(dependency.marker.evaluate({"extra": extra})
                        for extra in [""] + list(result[name])):
                    pending.append(dependency)
        return set(result)

    full = closure(requirements)
    retained = closure([value for value in requirements
                        if canonicalize_name(Requirement(value).name) not in {"torch", "timm"}])
    removable = full - retained
    package_files = set()
    for name in sorted(removable):
        distribution = metadata.distribution(name)
        for relative in distribution.files or []:
            path = Path(distribution.locate_file(relative)).resolve()
            if not path.exists():
                continue
            checked(path)
            if path.is_file():
                package_files.add(path)
    for name in retained:
        for relative in metadata.distribution(name).files or []:
            path = Path(metadata.distribution(name).locate_file(relative)).resolve()
            if path in package_files:
                raise SystemExit(f"A retained package shares a file selected for removal: {path}")

    removed = []
    for directory in directories:
        size = sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())
        removed.append({"path": str(directory.relative_to(resources)), "bytes": size})
        shutil.rmtree(directory)
    package_bytes = 0
    parents = set()
    for path in package_files:
        if path.exists():
            package_bytes += path.stat().st_size
            path.unlink()
        parents.update(parent for parent in path.parents if parent != site and site in parent.parents)
    for parent in sorted(parents, key=lambda item: len(item.parts), reverse=True):
        if parent.is_dir() and not any(parent.iterdir()):
            parent.rmdir()
    for checkpoint in checkpoints:
        (resources / checkpoint["path"]).unlink()
    saved = sum(row["bytes"] for row in removed) + package_bytes + sum(row["original_bytes"] for row in checkpoints)
    report = {"policy": "Native float32 Core ML; omit PyTorch stack, training checkpoints and selected package tests",
              "removed_bytes": saved, "removed_distributions": sorted(removable),
              "removed_directories": removed, "checkpoints": checkpoints}

    (resources / "runtime-pruning.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Removed {saved / 1024 ** 2:.1f} MiB of unused Mac runtime/training/development data")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resources", type=Path)
    trim(parser.parse_args().resources.absolute())
