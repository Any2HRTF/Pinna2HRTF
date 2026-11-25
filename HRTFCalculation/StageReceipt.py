import base64
import copy
import hashlib
import json
import math
import os
import re
import stat
import unicodedata
from decimal import Decimal
from pathlib import Path, PurePosixPath

from .Config import BUNDLED_EVALUATION_GRID_PATH, DEFAULT_EVALUATION_GRID, PipelineConfig
from .FileIdentity import cached_sha256 as sha256
from .Outputs import write_json
from .SolverProjectFiles import preprocessing_outputs, recorded_preprocessing_outputs
from .RunConfig import PREPROCESSING_INPUT_RECEIPT, input_paths, predicted_stl, preprocessing_input_signature, validate_preprocessing_inputs

STAGES = ("inference", "preprocessing", "postprocessing")
MAC_PREPROCESSING_RECEIPT = ".pinna2hrtf-preprocessing-mac-v2.json"
WINDOWS_PREPROCESSING_RECEIPT = ".pinna2hrtf-preprocessing-windows-v3.json"
LEGACY_PREPROCESSING_RECEIPT = ".pinna2hrtf-preprocessing-signature"
WINDOWS_INFERENCE_RECEIPT = ".pinna2hrtf-inference-signature"
MESSAGES = {
    "current": "Up to date.",
    "legacy-current": "Up to date.",
    "missing-receipt": "Not run yet.",
    "inputs-changed": "Inputs, settings or outputs changed since the last run.",
    "inputs-unavailable": "Inputs or outputs of the last run are missing.",
    "receipt-unreadable": "The stage record can't be read.",
    "legacy-unsupported": "This stage record was written by an older app. Open the project in that app or run the stage again.",
    "spatial-upsampling-stale": "Spatially upsampled HRIRs are missing or out of date.",
}
CHECK_ERRORS = (ValueError, OSError, KeyError, TypeError, AttributeError, IndexError)


class StageNotCurrent(ValueError):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, allow_nan=False).encode()).hexdigest()


def receipt_path(config, stage):
    return config.paths.output_dir / f".pinna2hrtf-{stage}-receipt.json"


def inference_signatures(config):
    settings = config.inference.model_dump(mode="json")
    model = sha256(Path(settings.pop("model_config_file")))
    from .Inference.model_runtime import checkpoint_path
    checkpoint = checkpoint_path(settings.pop("model_checkpoint"))
    weights = sha256(checkpoint)
    if checkpoint.name.endswith(".coreml.json"):
        weights = json.loads(checkpoint.read_text())["source_checkpoint_sha256"]
    ears = {}
    for side, ear in zip(("left", "right"), input_paths(config)):
        if ear is not None:
            prediction = predicted_stl(config.paths.output_dir / settings[f"prediction_{side}_folder"], ear.stem)
            if prediction is None:
                raise ValueError(f"Missing {side} prediction")
            ears[side] = [sha256(ear), sha256(prediction)]
    overall = digest({"settings": settings, "weights": weights, "model": model, "ears": ears})
    sides = {}
    for side, identity in ears.items():
        other = "right" if side == "left" else "left"
        side_settings = {name: value for name, value in settings.items()
                         if name not in ("enabled", "use_predictions_for_preprocessing") and not name.endswith(f"_{other}_folder")}
        sides[side] = digest({"settings": side_settings, "weights": weights, "model": model, "ear": identity})
    return overall, sides


def require_current_inference(config, sides):
    receipt = json_object(read_text(receipt_path(config, "inference")))
    if receipt is None or receipt.get("version") != 2:
        raise StageNotCurrent(f"The {' and '.join(sides)} Mesh2PPM prediction has no inference record from this version of Pinna2HRTF. Run inference again before preprocessing.")
    overall, current = inference_signatures(config)
    recorded = receipt.get("ears")
    if isinstance(recorded, dict):
        stale = [side for side in sides if recorded.get(side) != current.get(side)]
    else:
        stale = [] if receipt.get("sha256") == overall else list(sides)
    if stale:
        raise StageNotCurrent(f"The {' and '.join(stale)} Mesh2PPM prediction does not match the current ear mesh, model or inference settings. Run inference again before preprocessing.")


def signature(config, stage):
    if stage == "inference":
        return inference_signatures(config)[0]
    root = config.paths.output_dir
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
    for side, ear in zip(("left", "right"), input_paths(config)):
        if ear is not None:
            files = sorted((root / "Projects" / side.title() / "Output2HRTF").glob("*.sofa"))
            if not files:
                raise ValueError(f"Missing {side} SOFA results")
            result["ears"][side] = {p.name: sha256(p) for p in files}
    return digest(result)


def preprocessing_outputs_match(config, recorded=None):
    for side, ear in zip(("left", "right"), input_paths(config)):
        if ear is None:
            continue
        project = config.paths.output_dir / "Projects" / side.title()
        current = preprocessing_outputs(project)
        expected = recorded.get(side) if isinstance(recorded, dict) else recorded_preprocessing_outputs(project)
        if (isinstance(recorded, dict) or expected is not None) and expected != current:
            return False
    return True


def record_preprocessing(config, inputs=None):
    inputs = inputs or preprocessing_input_signature(config)
    outputs = {side: preprocessing_outputs(config.paths.output_dir / "Projects" / side.title()) for side in inputs["ears"]}
    path = config.paths.output_dir / PREPROCESSING_INPUT_RECEIPT
    write_json(path, {**inputs, "outputs": outputs})
    return path


def verdict(reason, legacy=False):
    return {"current": reason in ("current", "legacy-current"), "reason": reason, "message": MESSAGES[reason], "legacy": legacy}


def checked(check, legacy):
    try:
        matches = check()
    except StageNotCurrent:
        return verdict("inputs-changed", legacy)
    except CHECK_ERRORS:
        return verdict("inputs-unavailable", legacy)
    return verdict(("legacy-current" if legacy else "current") if matches else "inputs-changed", legacy)


def read_text(path):
    try:
        return path.read_bytes().decode("utf-8")
    except FileNotFoundError:
        return None
    except (OSError, UnicodeError):
        return ""


def json_object(text):
    try:
        value = json.loads(text)
    except (TypeError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def receipt_status(config, stage, app, record, command_config):
    root = config.paths.output_dir
    text = read_text(receipt_path(config, stage))
    receipt = json_object(text) if text else None
    if receipt is not None:
        if receipt.get("version") != 2:
            return verdict("receipt-unreadable")
        return checked(lambda: receipt.get("sha256") == signature(config, stage), False)
    if app == "windows" and stage == "inference":
        recorded = read_windows_text(root / WINDOWS_INFERENCE_RECEIPT)
        if recorded is None:
            return verdict("missing-receipt")
        return checked(lambda: recorded == windows_inference_stamp(record, command_config), True)
    if text is None:
        return verdict("missing-receipt")
    if app == "windows":
        recorded = read_windows_text(receipt_path(config, stage))
        return checked(lambda: recorded == windows_postprocessing_stamp(record, command_config), True)
    if app == "mac":
        if not text:
            return verdict("receipt-unreadable", True)
        return checked(lambda: text == mac_stage_signature(stage, record, config), True)
    return verdict("legacy-unsupported", True)


def preprocessing_status(config, app, record, command_config):
    root = config.paths.output_dir
    shared = root / PREPROCESSING_INPUT_RECEIPT
    if shared.exists():
        def shared_matches():
            validate_preprocessing_inputs(config, lambda _: None)
            return True
        return checked(shared_matches, False)
    if any((root / name).exists() for name in (LEGACY_PREPROCESSING_RECEIPT, MAC_PREPROCESSING_RECEIPT, WINDOWS_PREPROCESSING_RECEIPT)):
        return verdict("inputs-changed", True)
    return verdict("missing-receipt")


def spatial_upsampling_current(config):
    settings = config.postprocessing
    if not settings.spatial_upsampling:
        return True
    from .Postprocessing.spatial_upsampling import dense_name
    root = Path(settings.output_sofa_dir)
    try:
        sources = [path for path in root.iterdir() if path.name.startswith("HRIR_") and path.suffix.lower() == ".sofa"]
    except OSError:
        return False
    if not sources:
        return False
    for source in sources:
        folder = root / "Upsampled" / source.stem
        target = folder / dense_name(settings.spatial_subdivisions)
        try:
            receipt = json.loads((folder / "upsampling.json").read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return False
        if not isinstance(receipt, dict) or receipt.get("method") != "LocaDyn-1948":
            return False
        if not is_number(receipt.get("subdivisions")) or receipt["subdivisions"] != settings.spatial_subdivisions:
            return False
        if not isinstance(receipt.get("normalize"), bool) or receipt["normalize"] != settings.spatial_normalize:
            return False
        if not identity_matches(source, receipt.get("input")) or not identity_matches(target, receipt.get("output")):
            return False
        if not is_sofa_container(target):
            return False
    return True


def is_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def identity_matches(path, identity, tolerance_s=0.001):
    if not isinstance(identity, dict) or not is_number(identity.get("size")) or not is_number(identity.get("mtime")):
        return False
    try:
        info = os.stat(path)
    except OSError:
        return False
    return info.st_size == identity["size"] and abs(info.st_mtime - identity["mtime"]) < tolerance_s


def is_sofa_container(path):
    try:
        with open(path, "rb") as stream:
            head = stream.read(8)
    except OSError:
        return False
    return head == b"\x89HDF\r\n\x1a\n" or (len(head) == 8 and head[:3] == b"CDF" and head[3] in (1, 2, 5))


def stage_status(command):
    stage = command["stage"]
    config = PipelineConfig.model_validate(command["config"]).resolved()
    app = command.get("app")
    record = command.get("project") if isinstance(command.get("project"), dict) else None
    if app not in ("mac", "windows") or record is None:
        app = None
    if stage == "preprocessing":
        return preprocessing_status(config, app, record, command["config"])
    result = receipt_status(config, stage, app, record, command["config"])
    if stage == "postprocessing" and result["current"] and not spatial_upsampling_current(config):
        return verdict("spatial-upsampling-stale", result["legacy"])
    return result


def execute(command):
    stage = command["stage"]
    if stage not in STAGES:
        raise ValueError("Unknown receipt stage")
    if command["action"] == "stage-status":
        return stage_status(command)
    config = PipelineConfig.model_validate(command["config"]).resolved()
    if stage == "preprocessing":
        status = stage_status(command)
        if not status["current"]:
            raise StageNotCurrent(f"Preprocessing outputs can't be recorded ({status['reason']}): {status['message']} Run preprocessing again.")
        return {"path": str(record_preprocessing(config))}
    if stage == "inference":
        overall, sides = inference_signatures(config)
        receipt = {"version": 2, "sha256": overall, "ears": sides}
    else:
        receipt = {"version": 2, "sha256": signature(config, stage)}
    write_json(receipt_path(config, stage), receipt)
    return receipt


PUNCTUATION_ORDER = " _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$"


def darwin_sort_key(text):
    primary, secondary, tertiary, digits = [], [], [], []
    index = 0
    while index < len(text):
        character = text[index]
        if "0" <= character <= "9":
            end = index
            while end < len(text) and "0" <= text[end] <= "9":
                end += 1
            primary.append((2, int(text[index:end])))
            digits.append(end - index)
            index = end
            continue
        decomposed = unicodedata.normalize("NFD", character)
        base = decomposed[0]
        if base.isalpha():
            primary.append((3, base.casefold()))
            secondary.append(decomposed[1:])
            tertiary.append(1 if base.isupper() else 0)
        elif character in PUNCTUATION_ORDER:
            primary.append((1, PUNCTUATION_ORDER.index(character)))
        elif character.isspace():
            primary.append((0, ord(character)))
        else:
            primary.append((4, ord(character)))
        index += 1
    return tuple(primary), tuple(secondary), tuple(tertiary), tuple(digits), text


def darwin_string(text):
    escaped = []
    for character in text:
        code = ord(character)
        if character in '"\\/':
            escaped.append("\\" + character)
        elif character in "\b\f\n\r\t":
            escaped.append({"\b": "\\b", "\f": "\\f", "\n": "\\n", "\r": "\\r", "\t": "\\t"}[character])
        elif code < 0x20:
            escaped.append(f"\\u{code:04x}")
        else:
            escaped.append(character)
    return '"' + "".join(escaped) + '"'


def darwin_scalar(value):
    if isinstance(value, str):
        return darwin_string(value)
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float) and math.isfinite(value):
        return "%.17g" % value
    raise TypeError(f"Unsupported JSON value {value!r}")


def darwin_json(value):
    if isinstance(value, dict):
        keys = sorted(value, key=darwin_sort_key)
        return "{" + ",".join(darwin_string(key) + ":" + darwin_json(value[key]) for key in keys) + "}"
    if isinstance(value, list):
        return "[" + ",".join(darwin_json(item) for item in value) + "]"
    return darwin_scalar(value)


def darwin_pretty(mapping):
    keys = sorted(mapping, key=darwin_sort_key)
    return "{\n" + ",\n".join(f"  {darwin_string(key)} : {darwin_scalar(mapping[key])}" for key in keys) + "\n}"


SWIFT_DECIMAL = re.compile(r"[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?")
SWIFT_HEXADECIMAL = re.compile(r"[+-]?0[xX]([0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)([pP][+-]?\d+)?")


def swift_double(text):
    try:
        if SWIFT_DECIMAL.fullmatch(text):
            return float(text)
        if SWIFT_HEXADECIMAL.fullmatch(text):
            return float.fromhex(text)
    except (OverflowError, ValueError):
        return math.inf
    return None


def swift_int(text):
    return int(text) if re.fullmatch(r"[+-]?\d+", text) else None


MAC_POSITION = {"x": ("number", True), "y": ("number", True), "z": ("number", True), "meshPath": ("string", True), "meshIdentity": ("string", True)}
MAC_INFERENCE = {name: ("string", True) for name in ("modelConfig", "modelCheckpoint", "targetLeftFolder", "targetRightFolder", "predictionLeftFolder", "predictionRightFolder")}
MAC_INFERENCE["usePredictionsForPreprocessing"] = ("bool", True)
MAC_PREPROCESSING = {name: ("string", True) for name in ("minFrequency", "maxFrequency", "frequencyStepCount", "meshMinEdgeLength", "meshMaxEdgeLength", "meshMaxError", "meshGamma", "meshGammaOpposite")}
MAC_PREPROCESSING.update({"evaluationGrid": ("string", False), "earDistance": ("string", False), "skipMeshGrading": ("bool", False),
                          "sourceAssignmentFaceCount": ("string", False), "sourcePositionInputLeft": (MAC_POSITION, False),
                          "sourcePositionInputRight": (MAC_POSITION, False)})
MAC_MANUAL = {name: ("string", False) for name in ("templateBlendPath", "leftMeshPath", "rightMeshPath", "leftParametersPath", "rightParametersPath", "leftBlendPath",
                                                     "rightBlendPath", "leftSourcePath", "rightSourcePath", "leftSourceIdentity", "rightSourceIdentity")}
MAC_MANUAL.update({"selectedMethod": ("method", False), "useForPreprocessing": ("bool", True)})
MAC_SCAN = {name: ("string", True) for name in ("scanPath", "rotationDegrees", "targetEdgeMM", "leftMarginMM", "rightMarginMM", "sideMinMM", "sideMaxMM")}
MAC_SCAN.update({name: ("bool", True) for name in ("enabled", "prepareLeft", "prepareRight")})
MAC_SCAN.update({name: ("string", False) for name in ("originalScanPath", "individualLeftEdit", "individualRightEdit", "reviewedLeftPath", "reviewedRightPath")})
MAC_SCAN["requireManualReview"] = ("bool", False)
MAC_SCAN_DEFAULTS = {"enabled": False, "scanPath": "", "rotationDegrees": "0", "prepareLeft": True, "prepareRight": True, "targetEdgeMM": "0.75",
                     "leftMarginMM": "20", "rightMarginMM": "10", "sideMinMM": "30", "sideMaxMM": "110"}


def swift_decode(schema, value):
    if not isinstance(value, dict):
        raise ValueError("Expected an object")
    result = {}
    for key, (kind, required) in schema.items():
        item = value.get(key)
        if item is None:
            if required:
                raise ValueError(f"Missing {key}")
            continue
        if isinstance(kind, dict):
            item = swift_decode(kind, item)
        elif kind == "string" and not isinstance(item, str):
            raise ValueError(f"{key} must be a string")
        elif kind == "bool" and not isinstance(item, bool):
            raise ValueError(f"{key} must be a Boolean")
        elif kind == "number" and not is_number(item):
            raise ValueError(f"{key} must be a number")
        elif kind == "method" and item not in ("mesh2ppm", "manual", "none"):
            raise ValueError(f"Unknown {key}")
        result[key] = item
    return result


def swift_decode_text(schema, text):
    try:
        return swift_decode(schema, json.loads(text))
    except (TypeError, ValueError):
        return None


def mac_settings(record):
    settings = record["settings"]
    scan = dict(MAC_SCAN_DEFAULTS)
    scan.update(settings.get("scanPreparation") or {})
    return settings["inference"], settings.get("manualPPMFitting") or {"useForPreprocessing": False}, settings["preprocessing"], scan


def mac_attributes(path):
    try:
        return os.stat(path)
    except (OSError, ValueError):
        return None


def mac_document(path):
    try:
        return json_object(Path(path).read_bytes().decode("utf-8"))
    except (OSError, UnicodeError, ValueError):
        return None


def mac_matches_stamp(path, stamp):
    if not isinstance(stamp, dict) or not is_number(stamp.get("size")) or not is_number(stamp.get("mtime")):
        return False
    info = mac_attributes(path)
    return info is not None and info.st_size == int(stamp["size"]) and abs(info.st_mtime - stamp["mtime"]) < 0.001


def mac_fingerprint(path):
    if not path:
        return ""
    resolved = os.path.realpath(path)
    info = mac_attributes(resolved)
    if info is None or not stat.S_ISREG(info.st_mode):
        return "unavailable"
    try:
        return "sha256:" + sha256(resolved)
    except OSError:
        return "unavailable"


def mac_checkpoint_fingerprint(path):
    if path.endswith(".coreml.json"):
        document = mac_document(path) or {}
        digest = document.get("source_checkpoint_sha256")
        if isinstance(digest, str) and len(digest) == 64 and all(character in "0123456789abcdefABCDEF" for character in digest):
            return "sha256:" + digest.lower()
    return mac_fingerprint(path)


def mac_source_checkpoint_path(path):
    return path[:-len(".coreml.json")] + ".pth" if path.endswith(".coreml.json") else path


def mac_ear_edit(scan, side):
    if scan["enabled"]:
        return scan.get("reviewedLeftPath" if side == "left" else "reviewedRightPath")
    return scan.get("individualLeftEdit" if side == "left" else "individualRightEdit")


def mac_review_is_current(record, side):
    _, _, _, scan = mac_settings(record)
    path = mac_ear_edit(scan, side)
    if path is None:
        return False
    folder = os.path.join(record["saveLocation"], "Prepared")
    receipt = mac_document(os.path.splitext(path)[0] + ".json")
    if not scan["enabled"]:
        original = record["leftEar" if side == "left" else "rightEar"]
        if not original or receipt is None or receipt.get("kind") != "ear" or receipt.get("side") != side or "generation" in receipt:
            return False
        source, output = receipt.get("source_identity"), receipt.get("output_identity")
        if not isinstance(source, dict) or not isinstance(output, dict):
            return False
        return mac_matches_stamp(original, source) and mac_matches_stamp(path, output)
    report = mac_document(os.path.join(folder, "mesh_preparation.json"))
    if report is None or not isinstance(report.get("generation"), str) or not isinstance(report.get("ears"), dict):
        return False
    base = report["ears"].get(side)
    digest = base.get("sha256") if isinstance(base, dict) else None
    if not isinstance(digest, str) or receipt is None or receipt.get("kind") != "ear" or receipt.get("side") != side:
        return False
    if receipt.get("generation") != report["generation"] or receipt.get("source_sha256") != digest:
        return False
    source, output = receipt.get("source_identity"), receipt.get("output_identity")
    if not isinstance(source, dict) or not isinstance(output, dict):
        return False
    return mac_matches_stamp(os.path.join(folder, f"{side.title()}.stl"), source) and mac_matches_stamp(path, output)


def mac_pipeline_ear(record, side):
    _, _, _, scan = mac_settings(record)
    if scan["enabled"]:
        if not scan["prepareLeft" if side == "left" else "prepareRight"]:
            return ""
        if mac_review_is_current(record, side) and mac_ear_edit(scan, side):
            return mac_ear_edit(scan, side)
        return os.path.join(record["saveLocation"], "Prepared", f"{side.title()}.stl")
    path = record["leftEar" if side == "left" else "rightEar"]
    if not path:
        return ""
    if mac_review_is_current(record, side) and mac_ear_edit(scan, side) is not None:
        return mac_ear_edit(scan, side)
    return path


def mac_mesh_identity_matches(saved, path):
    info = mac_attributes(path)
    if info is None:
        return False
    current = f"{os.path.normpath(path)}|{info.st_size}|{info.st_mtime!r}"
    if saved == current:
        return True
    old, new = saved.split("|"), current.split("|")
    if len(old) < 3 or old[:-2] != new[:-2] or old[-2] != new[-2]:
        return False
    first, second = swift_double(old[-1]), swift_double(new[-1])
    return first is not None and second is not None and abs(first - second) < 0.000001


def mac_manual_mesh(record, side):
    _, manual, _, _ = mac_settings(record)
    mesh, source_path, identity = manual.get(side + "MeshPath"), manual.get(side + "SourcePath"), manual.get(side + "SourceIdentity")
    parameters = manual.get(side + "ParametersPath")
    source = mac_pipeline_ear(record, side)
    if mesh is None or source_path is None or identity is None or not source or parameters is None:
        return None
    if os.path.normpath(os.path.abspath(source)) != os.path.normpath(os.path.abspath(source_path)):
        return None
    if not mac_mesh_identity_matches(identity, os.path.normpath(os.path.abspath(source))):
        return None
    return mesh if os.path.exists(mesh) and os.path.exists(parameters) else None


def mac_preprocessing_mesh(record, side):
    inference, manual, _, _ = mac_settings(record)
    if manual.get("useForPreprocessing"):
        return mac_manual_mesh(record, side)
    source = mac_pipeline_ear(record, side)
    if not source:
        return None
    if not inference["usePredictionsForPreprocessing"]:
        return source if os.path.exists(source) else None
    folder = inference["predictionLeftFolder" if side == "left" else "predictionRightFolder"]
    prediction = predicted_stl(Path(record["saveLocation"]) / folder, Path(source).stem)
    return str(prediction) if prediction is not None else None


def mac_grid_path(value, config):
    name = (value or "").strip() or DEFAULT_EVALUATION_GRID
    if name == DEFAULT_EVALUATION_GRID:
        return str(BUNDLED_EVALUATION_GRID_PATH)
    if "/" not in name:
        return str(config.paths.mesh2hrtf_path / "Mesh2Input" / "EvaluationGrids" / "Data" / name)
    return name


def mac_normalized(value):
    if isinstance(value, dict):
        return {key: mac_normalized(item) for key, item in value.items()}
    if isinstance(value, list):
        return [mac_normalized(item) for item in value]
    if isinstance(value, str):
        number = swift_double(value)
        if number is not None and math.isfinite(number):
            return number
    return value


MAC_OWNED_PREPROCESSING_KEYS = (
    "title", "enabled", "write_intermediates", "pictures", "material_search_paths", "min_frequency", "max_frequency", "frequency_step_count",
    "mesh_min_edge_length", "mesh_max_edge_length", "mesh_max_error", "mesh_gamma", "mesh_gamma_opposite", "head_radius", "skip_mesh_grading",
    "source_assignment_face_count", "source_position_input_left", "source_position_input_right")


def mac_configuration(preprocessing, manual, predictions, preserved, scan):
    settings = {key: value for key, value in preprocessing.items() if key != "evaluationGrid"}
    settings["skipMeshGrading"] = preprocessing.get("skipMeshGrading", False)
    settings["sourceAssignmentFaceCount"] = preprocessing.get("sourceAssignmentFaceCount", "6")
    for name in ("sourcePositionInputLeft", "sourcePositionInputRight"):
        position = settings.pop(name, None)
        if position is not None:
            settings[name] = [position["x"], position["y"], position["z"]]
    result = {"preprocessing": settings, "inputMode": "manual" if manual else "inference" if predictions else "original"}
    document = json_object(preserved) if isinstance(preserved, str) else None
    hidden = document.get("preprocessing") if document is not None else None
    if isinstance(hidden, dict):
        hidden = {key: value for key, value in hidden.items() if key not in MAC_OWNED_PREPROCESSING_KEYS}
        if hidden:
            result["importedPreprocessing"] = hidden
    if scan is not None and scan["enabled"]:
        result["scanPreparation"] = {key: value for key, value in scan.items()
                                     if key not in ("scanPath", "originalScanPath", "reviewedLeftPath", "reviewedRightPath", "requireManualReview")}
    return mac_normalized(result)


def mac_record_configuration(record):
    inference, manual, preprocessing, _ = mac_settings(record)
    return mac_configuration(preprocessing, manual.get("useForPreprocessing", False), inference["usePredictionsForPreprocessing"],
                             record.get("preservedConfigJSON"), record["settings"].get("scanPreparation"))


def mac_capture(record, config):
    inference, manual, preprocessing, scan = mac_settings(record)
    value = mac_record_configuration(record)
    value["format"] = "pinna2hrtf-preprocessing-v2"
    inputs = {}
    for side in ("left", "right"):
        inputs[side] = mac_fingerprint(mac_pipeline_ear(record, side))
        if manual.get("useForPreprocessing"):
            inputs["fitted_" + side] = mac_fingerprint(manual.get(side + "MeshPath") or "")
        elif inference["usePredictionsForPreprocessing"]:
            inputs["predicted_" + side] = mac_fingerprint(mac_preprocessing_mesh(record, side) or "")
    if inference["usePredictionsForPreprocessing"] and not manual.get("useForPreprocessing"):
        inputs["model_config"] = mac_fingerprint(inference["modelConfig"])
        inputs["model_checkpoint"] = mac_checkpoint_fingerprint(inference["modelCheckpoint"])
    if scan["enabled"]:
        inputs["scan"] = mac_fingerprint(scan["scanPath"])
    grid = mac_grid_path(preprocessing.get("evaluationGrid"), config)
    for name in ("Nodes.txt", "Elements.txt"):
        inputs["grid_" + name] = mac_fingerprint(os.path.join(grid, name))
    value["inputs"] = inputs
    return darwin_json(value)


def mac_stage_signature(stage, record, config):
    inference, _, _, _ = mac_settings(record)
    value = {}
    if stage == "inference":
        settings = dict(inference)
        settings["modelCheckpoint"] = mac_source_checkpoint_path(settings["modelCheckpoint"])
        value["settings"] = base64.b64encode(darwin_pretty(settings).encode()).decode()
        for side in ("left", "right"):
            value[side] = mac_fingerprint(mac_pipeline_ear(record, side))
            value["prediction_" + side] = mac_fingerprint(mac_preprocessing_mesh(record, side) or "")
        value["model"] = mac_fingerprint(inference["modelConfig"])
        value["checkpoint"] = mac_checkpoint_fingerprint(inference["modelCheckpoint"])
    else:
        settings = record["settings"].get("postprocessing")
        if settings is None:
            settings = {"normalize": True, "levelOffsetDB": "-30", "resampleHrirs": False, "samplingRate": "48000",
                        "spatialUpsampling": False, "spatialSubdivisions": 3, "spatialNormalize": False}
        value["settings"] = base64.b64encode(darwin_pretty(settings).encode()).decode()
        value["preprocessing"] = mac_capture(record, config)
        folder = settings.get("outputFolder")
        exported = os.path.abspath(folder) if folder is not None else os.path.join(record["saveLocation"], "HRTF")
        value["exports"] = mac_sofa_stamps(exported)
        for side in ("left", "right"):
            if mac_pipeline_ear(record, side):
                value[side] = mac_sofa_stamps(os.path.join(record["saveLocation"], "Projects", side.title(), "Output2HRTF"))
    return hashlib.sha256(darwin_json(value).encode()).hexdigest()


def mac_sofa_stamps(folder):
    try:
        names = os.listdir(folder)
    except OSError:
        return {}
    return {name: mac_fingerprint(os.path.join(folder, name)) for name in names if os.path.splitext(name)[1] == ".sofa"}


def mac_preprocessing_matches(saved, record, config):
    current = mac_capture(record, config)
    if saved == current:
        return True
    if mac_scan_selection_matches(saved, current, record):
        return True
    return mac_line_receipt_matches(saved, record, config)


def mac_scan_selection_matches(saved, current, record):
    previous, selected = json_object(saved), json_object(current)
    if previous is None or selected is None:
        return False
    old_scan, new_scan = previous.get("scanPreparation"), selected.get("scanPreparation")
    if not isinstance(old_scan, dict) or not isinstance(new_scan, dict):
        return False
    _, _, _, scan = mac_settings(record)
    for side in ("left", "right"):
        key = "prepareLeft" if side == "left" else "prepareRight"
        enabled = scan[key]
        flag = old_scan.get(key)
        if enabled != (flag is True or (is_number(flag) and flag == 1)):
            return False
        old_scan.pop(key, None)
        new_scan.pop(key, None)
        if not enabled:
            for name in ("inputs", "preprocessing"):
                old_values = previous.get(name) if isinstance(previous.get(name), dict) else {}
                new_values = selected.get(name) if isinstance(selected.get(name), dict) else {}
                keys = [side, "fitted_" + side, "predicted_" + side] if name == "inputs" else [
                    "sourcePositionInputLeft" if side == "left" else "sourcePositionInputRight"]
                for key in keys:
                    old_values.pop(key, None)
                    new_values.pop(key, None)
                previous[name], selected[name] = old_values, new_values
    previous["scanPreparation"], selected["scanPreparation"] = old_scan, new_scan
    return darwin_json(previous) == darwin_json(selected)


def mac_line_receipt_matches(saved, record, config):
    fields = saved.split("\n")
    if len(fields) == 7:
        fields += ["", "", ""]
    if len(fields) not in (10, 11):
        return False
    inference = swift_decode_text(MAC_INFERENCE, fields[5])
    preprocessing = swift_decode_text(MAC_PREPROCESSING, fields[6])
    if inference is None or preprocessing is None:
        return False
    manual = {"useForPreprocessing": False} if not fields[7] else swift_decode_text(MAC_MANUAL, fields[7])
    if manual is None:
        return False
    previous_scan = None
    if len(fields) == 11:
        previous_scan = swift_decode_text(MAC_SCAN, fields[10])
        if previous_scan is None:
            return False
    previous_configuration = mac_configuration(preprocessing, manual["useForPreprocessing"], inference["usePredictionsForPreprocessing"],
                                               record.get("preservedConfigJSON"), previous_scan)
    if darwin_json(previous_configuration) != darwin_json(mac_record_configuration(record)):
        return False
    relocations = []
    for old, new in ((fields[0], record["leftEar"]), (fields[1], record["rightEar"])):
        if not old or not new:
            continue
        a, b = PurePosixPath(os.path.abspath(old)).parts, PurePosixPath(os.path.abspath(new)).parts
        count = 0
        while count < min(len(a), len(b)) and a[len(a) - count - 1] == b[len(b) - count - 1]:
            count += 1
        if 0 < count < min(len(a), len(b)):
            origin, destination = str(PurePosixPath(*a[:-count])), str(PurePosixPath(*b[:-count]))
            if origin != "/" and destination != "/":
                relocations.append((origin, destination))
    for old, side, stamp in ((fields[0], "left", fields[3]), (fields[1], "right", fields[4])):
        if not mac_legacy_input_matches(old, mac_pipeline_ear(record, side), stamp):
            return False
    current_inference, current_manual, current_preprocessing, current_scan = mac_settings(record)
    if current_manual.get("useForPreprocessing"):
        for side, index in (("left", 8), ("right", 9)):
            if not mac_legacy_input_matches(manual.get(side + "MeshPath") or "", current_manual.get(side + "MeshPath") or "", fields[index]):
                return False
    elif current_inference["usePredictionsForPreprocessing"]:
        if not mac_resource_matches(inference["modelConfig"], current_inference["modelConfig"], relocations):
            return False
        if not mac_resource_matches(inference["modelCheckpoint"], mac_source_checkpoint_path(current_inference["modelCheckpoint"]), relocations):
            return False
    if current_scan["enabled"]:
        old_scan_path = (previous_scan or MAC_SCAN_DEFAULTS)["scanPath"]
        if not mac_resource_matches(old_scan_path, current_scan["scanPath"], relocations):
            return False
    return mac_resource_matches(mac_grid_path(preprocessing.get("evaluationGrid"), config),
                                mac_grid_path(current_preprocessing.get("evaluationGrid"), config), relocations, directory=True)


def mac_legacy_input_matches(old, new, stamp):
    if not old or not new:
        return not old and not new
    fields = stamp.split("|")
    if len(fields) >= 3:
        size, modified = swift_int(fields[-2]), swift_double(fields[-1])
        info = mac_attributes(new)
        if size is not None and modified is not None and info is not None and info.st_size == size and abs(info.st_mtime - modified) < 0.00001:
            return True
    if old == new:
        return stamp == "" and mac_attributes(new) is None
    digest = mac_fingerprint(old)
    return digest.startswith("sha256:") and digest == mac_fingerprint(new)


def mac_resource_matches(old, new, relocations, directory=False):
    if old == new:
        return True
    if any((old == origin or old.startswith(origin + "/")) and destination + old[len(origin):] == new for origin, destination in relocations):
        return True
    if directory:
        return all(mac_resource_matches(os.path.join(old, name), os.path.join(new, name), []) for name in ("Nodes.txt", "Elements.txt"))
    digest = mac_fingerprint(old)
    return digest.startswith("sha256:") and digest == mac_fingerprint(new)


DOTNET_ESCAPES = {'"': "\\u0022", "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\b": "\\b", "\f": "\\f"}


def dotnet_string(text):
    escaped = []
    for unit in text:
        code = ord(unit)
        if unit in DOTNET_ESCAPES:
            escaped.append(DOTNET_ESCAPES[unit])
        elif code < 0x20 or code == 0x7F or unit in "&'+<>`" or code > 0x7E:
            if code > 0xFFFF:
                code -= 0x10000
                escaped.append(f"\\u{0xD800 + (code >> 10):04X}\\u{0xDC00 + (code & 0x3FF):04X}")
            else:
                escaped.append(f"\\u{code:04X}")
        else:
            escaped.append(unit)
    return '"' + "".join(escaped) + '"'


def dotnet_number(value):
    if isinstance(value, int):
        return str(value)
    if value == 0:
        return "-0" if math.copysign(1, value) < 0 else "0"
    sign, digits, exponent = Decimal(repr(value)).normalize().as_tuple()
    text = "".join(map(str, digits))
    scientific = len(text) + exponent - 1
    prefix = "-" if sign else ""
    if -5 < scientific < 15:
        return prefix + format(Decimal((0, digits, exponent)), "f")
    mantissa = text[0] + ("." + text[1:] if len(text) > 1 else "")
    return f"{prefix}{mantissa}E{'+' if scientific >= 0 else '-'}{abs(scientific):02d}"


def dotnet_json(value):
    if isinstance(value, dict):
        return "{" + ",".join(dotnet_string(key) + ":" + dotnet_json(item) for key, item in value.items()) + "}"
    if isinstance(value, list):
        return "[" + ",".join(dotnet_json(item) for item in value) + "]"
    if isinstance(value, str):
        return dotnet_string(value)
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    return dotnet_number(value)


def dotnet_hash(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest().upper()


def read_windows_text(path):
    try:
        return path.read_bytes().decode("utf-8-sig", errors="replace")
    except FileNotFoundError:
        return None


def blank(value):
    return value is None or not str(value).strip()


def windows_file_exists(path):
    return not blank(path) and os.path.isfile(path)


def windows_full_path(path):
    return os.path.abspath(path)


def windows_same_path(left, right):
    return not blank(left) and not blank(right) and windows_full_path(left).casefold() == windows_full_path(right).casefold()


def windows_mesh_identity(path):
    try:
        info = os.stat(path)
        if not stat.S_ISREG(info.st_mode):
            return ""
        ticks = info.st_mtime_ns // 100 + 621355968000000000
        return f"{windows_full_path(path).lower()}:{info.st_size}:{ticks}:{sha256(path)}"
    except (OSError, ValueError, TypeError):
        return ""


def windows_digest(path):
    try:
        return sha256(path)
    except (OSError, ValueError, TypeError):
        return None


def windows_document(path):
    try:
        return json.loads(Path(path).read_bytes().decode("utf-8-sig"))
    except (OSError, UnicodeError, ValueError):
        return None


def same_json(left, right):
    if is_number(left) and is_number(right):
        return float(left) == float(right)
    if isinstance(left, bool) or isinstance(right, bool) or left is None or right is None:
        return left is right
    if isinstance(left, dict) and isinstance(right, dict):
        return len(left) == len(right) and all(key in right and same_json(item, right[key]) for key, item in left.items())
    if isinstance(left, list) and isinstance(right, list):
        return len(left) == len(right) and all(same_json(a, b) for a, b in zip(left, right))
    return type(left) is type(right) and left == right


def windows_scan_outputs_current(record, command_config):
    try:
        return windows_scan_report_matches(record, command_config)
    except CHECK_ERRORS:
        return False


def windows_scan_report_matches(record, command_config):
    scan = record["Settings"]["ScanPreparation"]
    report = windows_document(os.path.join(record["SaveLocation"], "Prepared", "mesh_preparation.json"))
    if not isinstance(report, dict) or report.get("status") != "completed":
        return False
    signature = report.get("signature")
    if not isinstance(signature, dict) or signature.get("source_sha256") != windows_digest(scan["ScanPath"]):
        return False
    recorded = dict(signature.get("settings") or {})
    expected = dict(command_config["scan_preparation"])
    for key in ("require_manual_review", "reviewed_left", "reviewed_right", "scan_path", "original_scan_path", "prepare_left", "prepare_right"):
        recorded.pop(key, None)
        expected.pop(key, None)
    if "crop_polygon_xz" not in expected:
        recorded.pop("crop_polygon_xz", None)
    if not same_json(recorded, expected):
        return False
    for side, selected in (("left", scan["PrepareLeft"]), ("right", scan["PrepareRight"])):
        if selected and report["ears"][side]["sha256"] != windows_digest(os.path.join(record["SaveLocation"], "Prepared", f"{side.title()}.stl")):
            return False
    return True


def windows_ear_edit(scan, side):
    if scan["Enabled"]:
        return scan.get("ReviewedLeft" if side == "left" else "ReviewedRight")
    return scan.get("IndividualLeftEdit" if side == "left" else "IndividualRightEdit")


def windows_review_is_current(record, side):
    try:
        return windows_review_receipt_matches(record, side)
    except CHECK_ERRORS:
        return False


def windows_review_receipt_matches(record, side):
    scan = record["Settings"]["ScanPreparation"]
    reviewed = windows_ear_edit(scan, side)
    if not windows_file_exists(reviewed):
        return False
    receipt = windows_document(os.path.splitext(reviewed)[0] + ".json")
    if not isinstance(receipt, dict) or receipt.get("kind") != "ear" or receipt.get("side") != side:
        return False
    if not scan["Enabled"]:
        original = record["LeftEar" if side == "left" else "RightEar"]
        return (windows_file_exists(original) and "generation" not in receipt and receipt.get("source_sha256") == windows_digest(original)
                and receipt.get("output_sha256") == windows_digest(reviewed))
    folder = os.path.join(record["SaveLocation"], "Prepared")
    report = windows_document(os.path.join(folder, "mesh_preparation.json"))
    if not isinstance(report, dict) or "generation" not in report or "generation" not in receipt:
        return False
    return (receipt["generation"] == report["generation"] and receipt.get("source_sha256") == windows_digest(os.path.join(folder, f"{side.title()}.stl"))
            and receipt.get("output_sha256") == windows_digest(reviewed))


def windows_source_ear(record, side, command_config):
    scan = record["Settings"]["ScanPreparation"]
    if not scan["Enabled"]:
        path = record["LeftEar" if side == "left" else "RightEar"]
        if not windows_file_exists(path):
            return None
        return windows_ear_edit(scan, side) if windows_review_is_current(record, side) else path
    if not scan["PrepareLeft" if side == "left" else "PrepareRight"] or not windows_scan_outputs_current(record, command_config):
        return None
    reviewed = windows_ear_edit(scan, side)
    if windows_review_is_current(record, side):
        return reviewed
    if not blank(reviewed):
        return None
    prepared = os.path.join(record["SaveLocation"], "Prepared", f"{side.title()}.stl")
    return prepared if os.path.isfile(prepared) else None


def windows_prediction_mesh(record, side, command_config):
    raw = windows_source_ear(record, side, command_config)
    if blank(raw) or blank(record["SaveLocation"]):
        return None
    inference = record["Settings"]["Inference"]
    folder = os.path.join(record["SaveLocation"], inference["PredictionLeftFolder" if side == "left" else "PredictionRightFolder"])
    if not os.path.isdir(folder):
        return None
    stem = os.path.splitext(os.path.basename(raw))[0]
    for name in (f"Prediction_{stem}.stl", f"{stem}.stl"):
        if os.path.isfile(os.path.join(folder, name)):
            return os.path.join(folder, name)
    candidates = [name for name in os.listdir(folder) if os.path.isfile(os.path.join(folder, name)) and os.path.splitext(name)[1].lower() == ".stl"]
    if len(candidates) == 1 and candidates[0].lower().startswith("prediction_"):
        return os.path.join(folder, candidates[0])
    return None


def windows_preprocessing_mesh(record, side, command_config):
    settings = record["Settings"]
    manual = settings["ManualPPM"]
    if manual["Enabled"]:
        fit = manual.get("Left" if side == "left" else "Right")
        source = windows_source_ear(record, side, command_config)
        if (fit is None or source is None or not windows_same_path(source, fit["Source"]) or windows_mesh_identity(source) != fit["SourceIdentity"]
                or not windows_file_exists(fit["Mesh"]) or not windows_file_exists(fit["Parameters"])):
            return None
        return fit["Mesh"]
    if settings["Inference"]["UsePredictionsForPreprocessing"]:
        return windows_prediction_mesh(record, side, command_config)
    return windows_source_ear(record, side, command_config)


def windows_sides(record):
    scan = record["Settings"]["ScanPreparation"]
    if scan["Enabled"]:
        return [side for side, selected in (("left", scan["PrepareLeft"]), ("right", scan["PrepareRight"])) if selected]
    return [side for side in ("left", "right") if not blank(record["LeftEar" if side == "left" else "RightEar"])]


def windows_preprocessing_stamp(record, command_config):
    config = PipelineConfig.model_validate(command_config).resolved()
    preprocessing = copy.deepcopy(command_config["preprocessing"])
    for key in ("enabled", "title", "pictures", "write_intermediates"):
        preprocessing.pop(key, None)
    grid = Path(config.paths.evaluation_grid)
    if config.paths.evaluation_grid == DEFAULT_EVALUATION_GRID:
        grid = BUNDLED_EVALUATION_GRID_PATH
    elif not grid.is_absolute():
        grid = config.paths.mesh2hrtf_path / "Mesh2Input" / "EvaluationGrids" / "Data" / grid
    ears = {}
    for side in windows_sides(record):
        settings = copy.deepcopy(preprocessing)
        settings.pop("source_position_input_" + ("right" if side == "left" else "left"), None)
        mesh = windows_preprocessing_mesh(record, side, command_config)
        ears[side] = {"settings": settings, "mesh_sha256": "" if mesh is None else sha256(mesh),
                      "grid_nodes": sha256(grid / "Nodes.txt") if (grid / "Nodes.txt").is_file() else "unavailable",
                      "grid_elements": sha256(grid / "Elements.txt") if (grid / "Elements.txt").is_file() else "unavailable"}
    return {"format": "pinna2hrtf-preprocessing-windows-v3", "ears": ears}


def windows_preprocessing_receipt_matches(path, record, command_config):
    recorded = json.loads(path.read_bytes().decode("utf-8-sig"))
    if recorded.get("format") != "pinna2hrtf-preprocessing-windows-v3":
        return False
    return same_json(recorded["ears"], windows_preprocessing_stamp(record, command_config)["ears"])


def windows_legacy_preprocessing_stamp(record, command_config):
    settings = record["Settings"]
    inputs = []
    for side in ("left", "right"):
        mesh = windows_preprocessing_mesh(record, side, command_config)
        inputs.append("" if mesh is None else windows_mesh_identity(mesh))
    return dotnet_hash(dotnet_json({"Preprocessing": settings["Preprocessing"], "Inference": settings["Inference"], "ManualPPM": settings["ManualPPM"],
                                    "ScanPreparation": settings["ScanPreparation"], "inputs": inputs}))


def windows_inference_stamp(record, command_config):
    inference = record["Settings"]["Inference"]
    paths = [windows_source_ear(record, "left", command_config), windows_source_ear(record, "right", command_config), inference["ModelConfig"], inference["ModelCheckpoint"]]
    return dotnet_hash(dotnet_json({"Inference": inference, "inputs": [windows_mesh_identity(path) if windows_file_exists(path) else "" for path in paths]}))


def windows_sofa_directory(record):
    folder = (record["Settings"].get("Postprocessing") or {}).get("OutputFolder")
    if blank(folder):
        return os.path.join(record["SaveLocation"], "HRTF")
    if os.path.isabs(folder):
        return windows_full_path(folder)
    if blank(record["SaveLocation"]) or not os.path.isabs(record["SaveLocation"]):
        return ""
    return windows_full_path(os.path.join(record["SaveLocation"], folder))


def windows_is_link(path):
    info = os.lstat(path)
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & 0x400)


def windows_files(folder, accept):
    return [os.path.join(folder, name) for name in os.listdir(folder) if os.path.isfile(os.path.join(folder, name)) and accept(name)]


def windows_postprocessing_stamp(record, command_config):
    paths = []
    destination = windows_sofa_directory(record)
    if destination and os.path.isdir(destination):
        paths += windows_files(destination, lambda name: name.lower().endswith(".sofa"))
        upsampled = os.path.join(destination, "Upsampled")
        if os.path.isdir(upsampled) and not windows_is_link(upsampled):
            for name in os.listdir(upsampled):
                folder = os.path.join(upsampled, name)
                if os.path.isdir(folder) and name.upper().startswith("HRIR_") and not windows_is_link(folder):
                    paths += windows_files(folder, lambda item: os.path.splitext(item)[1] == ".sofa" or item == "upsampling.json")
        if any(windows_is_link(path) for path in paths):
            raise OSError("Linked SOFA outputs require review.")
    for side in ("Left", "Right"):
        folder = os.path.join(record["SaveLocation"], "Projects", side, "Output2HRTF")
        if os.path.isdir(folder):
            paths += windows_files(folder, lambda name: name.lower().endswith(".sofa"))
    inputs = dotnet_hash(dotnet_json({"Postprocessing": record["Settings"].get("Postprocessing"),
                                      "preprocessing": dotnet_json(windows_preprocessing_stamp(record, command_config))}))
    return dotnet_hash(inputs + "\n".join(f"{path}:{sha256(path)}" for path in sorted(paths, key=str.upper)))
