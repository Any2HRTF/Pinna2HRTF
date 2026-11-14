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
    if not (site / "torch/lib/libtorch_cpu.dylib").is_file():
        raise SystemExit("The packaged PyTorch runtime is incomplete")

    def checked(path: Path) -> Path:
        path.relative_to(resources)
        if path.is_symlink() or path.resolve() != path:
            raise SystemExit(f"Refusing to trim a linked path: {path}")
        return path

    # These exact package test trees contain unit tests and example meshes.
    # Keep torch.testing, scipy._lib._testutils, Blender scripts, native plugins,
    # licenses and dist-info metadata: runtime imports can depend on them.
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
    # Validate every removal before starting; never follow links out of staging.
    for directory in directories:
        for path in directory.rglob("*"):
            checked(path)

    import torch

    checkpoints = []
    model_dir = resources / "HRTFCalculation/Inference/resources"
    for path in sorted(model_dir.glob("*.pth")):
        checked(path)
        original_bytes = path.stat().st_size
        source_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        checkpoint = torch.load(path, map_location="cpu", weights_only=True)
        weights = checkpoint["model_state_dict"]
        if not weights or not all(isinstance(value, torch.Tensor) for value in weights.values()):
            raise SystemExit(f"Unexpected model state: {path}")
        temporary = path.with_suffix(".pth.inference")
        if temporary.exists() or temporary.is_symlink():
            raise SystemExit(f"Stale checkpoint staging file: {temporary}")
        try:
            torch.save({"model_state_dict": weights}, temporary)
            restored = torch.load(temporary, map_location="cpu", weights_only=True)["model_state_dict"]
            if restored.keys() != weights.keys() or not all(torch.equal(value, restored[key]) for key, value in weights.items()):
                raise SystemExit(f"Checkpoint weights changed: {path}")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
        checkpoints.append({"path": str(path.relative_to(resources)), "source_sha256": source_hash,
                            "original_bytes": original_bytes, "bytes": path.stat().st_size,
                            "weights_verified_equal": True})
    if len(checkpoints) != 4:
        raise SystemExit(f"Expected four bundled checkpoints, found {len(checkpoints)}")

    removed = []
    for directory in directories:
        size = sum(path.stat().st_size for path in directory.rglob("*") if path.is_file())
        removed.append({"path": str(directory.relative_to(resources)), "bytes": size})
        shutil.rmtree(directory)
    saved = sum(row["bytes"] for row in removed) + sum(row["original_bytes"] - row["bytes"] for row in checkpoints)
    report = {"policy": "Inference weights only; omit selected package tests and PyTorch C++ headers",
              "removed_bytes": saved, "removed_directories": removed, "checkpoints": checkpoints}
    (resources / "runtime-pruning.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Removed {saved / 1024 ** 2:.1f} MiB of release-only training/development data")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("resources", type=Path)
    trim(parser.parse_args().resources.absolute())
