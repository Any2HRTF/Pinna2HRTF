"""Inference backends. Mac releases use a native Core ML helper."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np


def checkpoint_path(path):
    """Resolve bundled model selections saved by the other desktop platform."""
    path = Path(path)
    if sys.platform == "darwin" and path.suffix == ".pth":
        native = path.with_suffix(".coreml.json")
        if native.is_file():
            return native
    elif sys.platform != "darwin" and path.name.endswith(".coreml.json"):
        pytorch = path.with_name(path.name.removesuffix(".coreml.json") + ".pth")
        if pytorch.is_file():
            return pytorch
    return path


class CoreMLModel:
    def __init__(self, manifest_path, configuration, output_size):
        path = Path(manifest_path)
        manifest = json.loads(path.read_text())
        channels = configuration["number_of_camera_views"] * (2 if configuration["depth"] else 1)
        self.shape = (1, channels, configuration["img_size"], configuration["img_size"])
        self.output_size = output_size
        if (manifest.get("format") != "pinna2hrtf-coreml-v1"
                or tuple(manifest.get("input_shape", [])) != self.shape
                or manifest.get("output_size") != output_size
                or manifest.get("precision") != "float32"
                or manifest.get("compute_units") != "cpuOnly"):
            raise ValueError("The selected Core ML model does not match its configuration")
        name = manifest.get("model", "")
        if not name or Path(name).name != name or not name.endswith(".mlmodelc"):
            raise ValueError("Invalid compiled Core ML model path")
        self.model = path.parent / name
        files = manifest.get("compiled_files", {})
        if not files or not self.model.is_dir():
            raise FileNotFoundError(f"The compiled Core ML model is missing: {self.model}")
        for relative, expected in files.items():
            item = self.model / relative
            if Path(relative).is_absolute() or ".." in Path(relative).parts or item.is_symlink():
                raise ValueError("Invalid compiled Core ML resource path")
            if not item.is_file() or hashlib.sha256(item.read_bytes()).hexdigest() != expected:
                raise ValueError(f"The compiled Core ML resource is missing or changed: {item}")
        self.helper = Path(__file__).resolve().parents[2] / "External/bin/ppm_predict"
        if not self.helper.is_file():
            raise FileNotFoundError("The native Core ML helper is missing. Rebuild or reinstall the Mac app.")

    def predict(self, data):
        values = np.ascontiguousarray(data, dtype="<f4")[None]
        if values.shape != self.shape or not np.isfinite(values).all():
            raise ValueError(f"Expected finite model input with shape {self.shape[1:]}")
        with tempfile.TemporaryDirectory(prefix="pinna2hrtf-coreml-") as directory:
            input_file = Path(directory) / "images.f32"
            values.tofile(input_file)
            result = subprocess.run([str(self.helper), str(self.model), str(input_file)],
                                    capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr.strip() or "The native Core ML helper failed")
        output = np.asarray(json.loads(result.stdout), dtype=np.float32)
        if output.shape != (self.output_size,) or not np.isfinite(output).all():
            raise ValueError("Core ML returned an invalid prediction")
        return output[None]


class PyTorchModel:
    def __init__(self, path, configuration, output_size):
        try:
            import torch
        except ImportError as error:
            raise RuntimeError("PyTorch is not bundled with the Mac release. To use a PyTorch checkpoint, "
                               "enable Developer mode in Settings > Tools and choose a Python environment "
                               "that has PyTorch installed, or select a bundled model.") from error
        try:
            from .src.swin_transformer_v2 import SwinTransformerV2
        except ImportError:
            from src.swin_transformer_v2 import SwinTransformerV2
        channels = configuration["number_of_camera_views"] * (2 if configuration["depth"] else 1)
        self.model = SwinTransformerV2(
            img_size=configuration["img_size"], in_chans=channels, num_classes=output_size,
            window_size=configuration["window_size"], depths=configuration["depths"],
            num_heads=configuration["num_heads"], weights=torch.ones(4))
        self.model.load_state_dict(torch.load(path, map_location="cpu", weights_only=True)["model_state_dict"])
        self.model.eval()

    def predict(self, data):
        import torch
        with torch.no_grad():
            return self.model(torch.tensor(data).unsqueeze(0)).detach().cpu().numpy()


def load_model(path, configuration, output_size):
    path = checkpoint_path(path)
    if path.name.endswith(".coreml.json"):
        if sys.platform != "darwin":
            raise ValueError("This platform needs the original PyTorch checkpoint for this model")
        return CoreMLModel(path, configuration, output_size)
    # Windows and source/CLI environments retain their existing PyTorch path.
    return PyTorchModel(path, configuration, output_size)
