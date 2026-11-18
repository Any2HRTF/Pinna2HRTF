import hashlib
import json
from pathlib import Path

from .Config import PipelineConfig
from .FileIdentity import cached_sha256 as sha256
from .Outputs import write_json
from .RunConfig import PREPROCESSING_INPUT_RECEIPT, input_paths, predicted_stl, preprocessing_input_signature, validate_preprocessing_inputs


def signature(config, stage):
    root = config.paths.output_dir
    ears = dict(zip(("left", "right"), input_paths(config)))
    if stage == "inference":
        settings = config.inference.model_dump(mode="json")
        model = Path(settings.pop("model_config_file"))
        from .Inference.model_runtime import checkpoint_path
        checkpoint = checkpoint_path(settings.pop("model_checkpoint"))
        weights = sha256(checkpoint)
        if checkpoint.name.endswith(".coreml.json"):
            weights = json.loads(checkpoint.read_text())["source_checkpoint_sha256"]
        result = {"settings": settings, "weights": weights, "model": sha256(model), "ears": {}}
        for side, ear in ears.items():
            if ear is not None:
                prediction = predicted_stl(root / settings[f"prediction_{side}_folder"], ear.stem)
                if prediction is None:
                    raise ValueError(f"Missing {side} prediction")
                result["ears"][side] = [sha256(ear), sha256(prediction)]
    else:
        settings = config.postprocessing.model_dump(mode="json")
        destination = Path(settings.pop("output_sofa_dir"))
        exports = sorted(destination.glob("*.sofa"))
        if not exports:
            raise ValueError("Missing SOFA exports")
        if settings.get("spatial_upsampling"):
            exports.extend(sorted((destination / "Upsampled").glob("HRIR_*/*.sofa")))
            exports.extend(sorted((destination / "Upsampled").glob("HRIR_*/upsampling.json")))
        for option in ("matlab_executable", "amt_path", "enabled", "overwrite"):
            settings.pop(option, None)
        result = {"settings": settings, "preprocessing": preprocessing_input_signature(config),
                  "exports": {p.relative_to(destination).as_posix(): sha256(p) for p in exports}, "ears": {}}
        for side, ear in ears.items():
            if ear is not None:
                files = sorted((root / "Projects" / side.title() / "Output2HRTF").glob("*.sofa"))
                if not files:
                    raise ValueError(f"Missing {side} SOFA results")
                result["ears"][side] = {p.name: sha256(p) for p in files}
    return hashlib.sha256(json.dumps(result, sort_keys=True, allow_nan=False).encode()).hexdigest()


def execute(command):
    stage = command["stage"]
    if stage not in {"inference", "preprocessing", "postprocessing"}:
        raise ValueError("Unknown receipt stage")
    config = PipelineConfig.model_validate(command["config"]).resolved()
    if stage == "preprocessing":
        path = config.paths.output_dir / PREPROCESSING_INPUT_RECEIPT
        if command["action"] == "record-stage":
            write_json(path, preprocessing_input_signature(config))
            return {"path": str(path)}
        if not path.exists():
            return {"current": False, "legacy": True}
        try:
            validate_preprocessing_inputs(config, lambda _: None)
            return {"current": True, "legacy": False}
        except (ValueError, OSError, KeyError):
            return {"current": False, "legacy": False}
    path = config.paths.output_dir / f".pinna2hrtf-{stage}-receipt.json"
    if command["action"] == "stage-status":
        if not path.exists():
            return {"current": False, "legacy": True}
        try:
            receipt = json.loads(path.read_text())
        except (ValueError, UnicodeError):
            return {"current": False, "legacy": True}
        if not isinstance(receipt, dict) or receipt.get("version") != 2:
            return {"current": False, "legacy": True}
        try:
            return {"current": receipt.get("sha256") == signature(config, stage), "legacy": False}
        except (ValueError, OSError, KeyError):
            return {"current": False, "legacy": False}
    receipt = {"version": 2, "sha256": signature(config, stage)}
    write_json(path, receipt)
    return receipt
