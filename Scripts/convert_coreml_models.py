#!/usr/bin/env python3
"""Build float32 Core ML assets; conversion dependencies stay outside the app."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

import coremltools as ct
import numpy as np
import torch
import yaml

from HRTFCalculation.Inference.src.swin_transformer_v2 import SwinTransformerV2


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def convert(resources, cache):
    models = resources / "HRTFCalculation/Inference/resources"
    architecture = Path(__file__).resolve().parents[1] / "HRTFCalculation/Inference/src/swin_transformer_v2.py"
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-version"], text=True).strip()
    torch.set_num_threads(2)
    for views in (1, 3, 9, 25):
        name = f"Local {views} Views"
        checkpoint = models / (name + ".pth")
        configuration_path = models / (name + ".yaml")
        configuration = yaml.safe_load(configuration_path.read_text())["model"]
        channels = configuration["number_of_camera_views"] * (2 if configuration["depth"] else 1)
        shape = (1, channels, configuration["img_size"], configuration["img_size"])
        provenance = {"source_checkpoint_sha256": sha(checkpoint), "configuration_sha256": sha(configuration_path),
                      "architecture_sha256": sha(architecture), "parameter_layout_sha256": sha(models / "PPM Parameters.csv"),
                      "converter_script_sha256": sha(__file__), "coremltools": ct.__version__, "torch": torch.__version__,
                      "numpy": np.__version__, "sdk": sdk, "precision": "float32", "compute_units": "cpuOnly"}
        key = hashlib.sha256(json.dumps(provenance, sort_keys=True).encode()).hexdigest()
        directory = cache / key
        compiled = directory / (name + ".mlmodelc")
        validation_path = directory / "validation.json"
        if not validation_path.exists() or not compiled.is_dir():
            directory.mkdir(parents=True, exist_ok=True)
            model = SwinTransformerV2(img_size=shape[2], in_chans=channels, num_classes=188,
                                      window_size=configuration["window_size"], depths=configuration["depths"],
                                      num_heads=configuration["num_heads"], weights=torch.ones(4))
            model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True)["model_state_dict"])
            model.eval()
            example = torch.zeros(shape, dtype=torch.float32)
            traced = torch.jit.trace(model, example)
            native = ct.convert(traced, inputs=[ct.TensorType(name="images", shape=shape, dtype=np.float32)],
                                outputs=[ct.TensorType(name="parameters", dtype=np.float32)],
                                convert_to="mlprogram", minimum_deployment_target=ct.target.macOS13,
                                compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY)
            package = directory / (name + ".mlpackage")
            native.save(str(package))
            rng = np.random.default_rng(514)
            differences = []
            # Conversion checks are build integrity checks, not a replacement
            # for validating the full acoustics on representative ear scans.
            for values in (np.zeros(shape, np.float32), np.ones(shape, np.float32), rng.random(shape, dtype=np.float32)):
                with torch.inference_mode():
                    expected = model(torch.from_numpy(values)).numpy()
                actual = native.predict({"images": values})["parameters"]
                if actual.shape != (1, 188) or not np.isfinite(actual).all() or not np.allclose(expected, actual, rtol=1e-4, atol=1e-4):
                    raise RuntimeError(f"Core ML conversion changed predictions for {name}")
                differences.append(float(np.max(np.abs(actual - expected))))
            if compiled.exists():
                shutil.rmtree(compiled)
            subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(directory)], check=True)
            if not compiled.is_dir():
                raise RuntimeError(f"Core ML compilation did not produce {compiled}")
            validation_path.write_text(json.dumps({"max_abs_error": differences, "rtol": 1e-4, "atol": 1e-4}, indent=2) + "\n")
        destination = models / compiled.name
        if destination.exists():
            raise FileExistsError(f"Core ML release destination already exists: {destination}")
        shutil.copytree(compiled, destination)
        files = {str(path.relative_to(destination)): sha(path) for path in sorted(destination.rglob("*")) if path.is_file()}
        if not files:
            raise RuntimeError(f"Compiled model is empty: {destination}")
        # The compiled network fixes these; the runtime rejects a configuration that disagrees.
        network = {key: configuration[key] for key in ("window_size", "depths", "num_heads")}
        manifest = {"format": "pinna2hrtf-coreml-v2", "model": destination.name, "input_shape": list(shape),
                    "architecture": network,
                    "output_size": 188, "source_checkpoint": checkpoint.name, **provenance,
                    "compiled_files": files, "conversion_validation": json.loads(validation_path.read_text())}
        (models / (name + ".coreml.json")).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        print(f"Prepared native float32 Core ML model: {name}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    args = parser.parse_args()
    convert(args.resources.resolve(), args.cache.resolve())
