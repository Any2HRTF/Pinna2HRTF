from __future__ import annotations

import math

STAGES = ("scan-preparation", "inference", "preprocessing", "numcalc", "postprocessing")
SIMULATION_STAGES = ("preprocessing",)
SCAN_STAGES = ("scan-preparation", "inference", "preprocessing")
MODEL_STAGES = ("inference", "preprocessing", "numcalc", "postprocessing")

FIELDS = (
    {"id": "mesh2hrtf.min_frequency", "config": "preprocessing.min_frequency", "kind": "integer", "minimum": 0, "maximum": 96000,
     "message": "Use 0 to 96000 Hz.", "stages": SIMULATION_STAGES},
    {"id": "mesh2hrtf.max_frequency", "config": "preprocessing.max_frequency", "kind": "integer", "minimum": 1, "maximum": 96000,
     "message": "Use 1 to 96000 Hz.", "stages": SIMULATION_STAGES},
    {"id": "mesh2hrtf.frequency_steps", "config": "preprocessing.frequency_step_count", "kind": "integer", "minimum": 2, "maximum": 8193,
     "message": "Use 2 to 8193 frequency steps.", "stages": SIMULATION_STAGES},
    {"id": "mesh2hrtf.microphone_faces", "config": "preprocessing.source_assignment_face_count", "kind": "integer", "minimum": 1, "maximum": 100,
     "message": "Use 1 to 100 microphone faces.", "stages": SIMULATION_STAGES},
    {"id": "mesh2hrtf.ear_distance", "config": "preprocessing.ear_distance", "kind": "decimal", "exclusive_minimum": 0, "optional": True,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "mesh_grading.min_edge_length", "config": "preprocessing.mesh_min_edge_length", "kind": "decimal", "exclusive_minimum": 0,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "mesh_grading.max_edge_length", "config": "preprocessing.mesh_max_edge_length", "kind": "decimal", "exclusive_minimum": 0,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "mesh_grading.max_error", "config": "preprocessing.mesh_max_error", "kind": "decimal", "minimum": 0,
     "message": "Use 0 or more.", "stages": SIMULATION_STAGES},
    {"id": "mesh_grading.gamma", "config": "preprocessing.mesh_gamma", "kind": "decimal", "exclusive_minimum": 0,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "mesh_grading.gamma_opposite", "config": "preprocessing.mesh_gamma_opposite", "kind": "decimal", "exclusive_minimum": 0,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "head.radius_scale", "config": "preprocessing.head_radius_scale", "kind": "decimal", "exclusive_minimum": 0,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "head.width_scale", "config": "preprocessing.head_width_scale", "kind": "decimal", "exclusive_minimum": 0,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "head.height_scale", "config": "preprocessing.head_height_scale", "kind": "decimal", "exclusive_minimum": 0,
     "message": "Use a number greater than 0.", "stages": SIMULATION_STAGES},
    {"id": "head.taper_percent", "config": "preprocessing.head_taper_percent", "kind": "decimal",
     "message": "Enter a finite head taper strength in percent.", "stages": SIMULATION_STAGES},
    {"id": "numcalc.parallel_instances", "config": "numcalc.max_instances", "kind": "integer", "minimum": 1, "maximum": 1024,
     "message": "Use 1 to 1024 parallel instances.", "stages": ("numcalc",)},
    {"id": "numcalc.cpu_limit", "config": "numcalc.max_cpu_load", "kind": "integer", "minimum": 1, "maximum": 100,
     "message": "Use a CPU limit from 1 to 100%.", "stages": ("numcalc",)},
    {"id": "postprocessing.level_offset", "config": "postprocessing.level_offset_db", "kind": "decimal", "when": "postprocessing.normalize",
     "message": "Enter a finite number.", "stages": ("postprocessing",)},
    {"id": "postprocessing.sampling_rate", "config": "postprocessing.sampling_rate", "kind": "integer", "minimum": 10, "multiple_of": 10,
     "when": "postprocessing.resample_hrirs", "message": "Use a positive rate divisible by 10 Hz.", "stages": ("postprocessing",)},
    {"id": "postprocessing.spatial_subdivisions", "config": "postprocessing.spatial_subdivisions", "kind": "integer", "minimum": 0, "maximum": 5,
     "when": "postprocessing.spatial_upsampling", "message": "Choose a subdivision level from 0 to 5.", "stages": ("postprocessing",)},
    {"id": "scan.path", "config": "scan_preparation.scan_path", "kind": "text", "when": "scan.enabled",
     "message": "Choose a full-head scan.", "stages": SCAN_STAGES},
    {"id": "scan.rotation", "config": "scan_preparation.rotation_degrees", "kind": "decimal", "optional": True, "when": "scan.enabled",
     "message": "Enter a finite rotation.", "stages": SCAN_STAGES},
    {"id": "scan.target_edge", "config": "scan_preparation.target_edge_mm", "kind": "decimal", "exclusive_minimum": 0, "when": "scan.enabled",
     "message": "Use a number greater than 0.", "stages": SCAN_STAGES},
    {"id": "scan.left_margin", "config": "scan_preparation.left_margin_mm", "kind": "decimal", "minimum": 0, "when": "scan.enabled",
     "message": "Use 0 or more.", "stages": SCAN_STAGES},
    {"id": "scan.right_margin", "config": "scan_preparation.right_margin_mm", "kind": "decimal", "minimum": 0, "when": "scan.enabled",
     "message": "Use 0 or more.", "stages": SCAN_STAGES},
    {"id": "scan.side_min", "config": "scan_preparation.side_min_mm", "kind": "decimal", "minimum": 0, "when": "scan.enabled",
     "message": "Use 0 or more.", "stages": SCAN_STAGES},
    {"id": "scan.side_max", "config": "scan_preparation.side_max_mm", "kind": "decimal", "exclusive_minimum": 0, "when": "scan.enabled",
     "message": "Use a number greater than 0.", "stages": SCAN_STAGES},
    {"id": "ear_model.method", "config": "ui.ear_model_method", "kind": "text",
     "message": "Choose an ear modelling method.", "stages": MODEL_STAGES},
)

SWITCHES = (
    {"id": "scan.enabled", "config": "scan_preparation.enabled"},
    {"id": "scan.prepare_left", "config": "scan_preparation.prepare_left"},
    {"id": "scan.prepare_right", "config": "scan_preparation.prepare_right"},
    {"id": "postprocessing.normalize", "config": "postprocessing.normalize"},
    {"id": "postprocessing.resample_hrirs", "config": "postprocessing.resample_hrirs"},
    {"id": "postprocessing.spatial_upsampling", "config": "postprocessing.spatial_upsampling"},
)

RELATIONS = (
    {"id": "mesh2hrtf.max_frequency", "kind": "greater", "other": "mesh2hrtf.min_frequency",
     "message": "Max frequency must be greater than min frequency.", "stages": SIMULATION_STAGES},
    {"id": "mesh_grading.max_edge_length", "kind": "at_least", "other": "mesh_grading.min_edge_length",
     "message": "Max edge length must be at least the min edge length.", "stages": SIMULATION_STAGES},
    {"id": "scan.side_max", "kind": "greater", "other": "scan.side_min", "when": "scan.enabled",
     "message": "Outer crop limit must exceed inner crop limit.", "stages": SCAN_STAGES},
    {"id": "scan.sides", "kind": "any", "fields": ("scan.prepare_left", "scan.prepare_right"), "when": "scan.enabled",
     "message": "Select at least one ear.", "stages": SCAN_STAGES},
)

PARSE_MESSAGES = {"integer": "Enter a whole number.", "decimal": "Enter a finite number."}


def rules() -> dict:
    return {"stages": list(STAGES), "fields": [dict(rule, stages=list(rule["stages"])) for rule in FIELDS],
            "switches": [dict(rule) for rule in SWITCHES],
            "relations": [{key: list(value) if isinstance(value, tuple) else value for key, value in rule.items()} for rule in RELATIONS],
            "parse_messages": PARSE_MESSAGES}


def number(text: str, kind: str) -> float | int | None:
    text = text.strip()
    try:
        value = int(text) if kind == "integer" else float(text)
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def field_message(rule: dict, text: str) -> str | None:
    text = text.strip()
    if not text:
        return None if rule.get("optional") else PARSE_MESSAGES.get(rule["kind"], rule["message"])
    if rule["kind"] == "text":
        return None
    value = number(text, rule["kind"])
    if value is None:
        return PARSE_MESSAGES[rule["kind"]]
    if "minimum" in rule and value < rule["minimum"]:
        return rule["message"]
    if "exclusive_minimum" in rule and value <= rule["exclusive_minimum"]:
        return rule["message"]
    if "maximum" in rule and value > rule["maximum"]:
        return rule["message"]
    if "multiple_of" in rule and value % rule["multiple_of"]:
        return rule["message"]
    return None


def enabled(values: dict[str, str], rule: dict) -> bool:
    condition = rule.get("when")
    return condition is None or values.get(condition, "").strip().lower() == "true"


def issues(values: dict[str, str], stage: str | None = None) -> list[dict]:
    found = []
    by_id = {rule["id"]: rule for rule in FIELDS}
    for rule in FIELDS:
        if rule["id"] in values and enabled(values, rule):
            message = field_message(rule, values[rule["id"]])
            if message:
                found.append({"id": rule["id"], "message": message, "stages": rule["stages"]})
    invalid = {issue["id"] for issue in found}
    for rule in RELATIONS:
        if not enabled(values, rule):
            continue
        if rule["kind"] == "any":
            if not any(values.get(field, "").strip().lower() == "true" for field in rule["fields"]):
                found.append({"id": rule["id"], "message": rule["message"], "stages": rule["stages"]})
            continue
        if rule["id"] in invalid or rule["other"] in invalid or rule["id"] not in values or rule["other"] not in values:
            continue
        kind = by_id[rule["id"]]["kind"]
        value, other = number(values[rule["id"]], kind), number(values[rule["other"]], kind)
        if value is None or other is None:
            continue
        if (rule["kind"] == "greater" and value <= other) or (rule["kind"] == "at_least" and value < other):
            found.append({"id": rule["id"], "message": rule["message"], "stages": rule["stages"]})
    return [{"id": issue["id"], "message": issue["message"]} for issue in found if stage is None or stage in issue["stages"]]


def form_values(config: dict) -> dict[str, str]:
    values = {}
    for rule in (*FIELDS, *SWITCHES):
        section, key = rule["config"].split(".")
        mapping = config.get(section)
        if not isinstance(mapping, dict) or key not in mapping:
            continue
        value = mapping[key]
        if isinstance(value, float) and value.is_integer() and rule.get("kind") == "integer":
            value = int(value)
        values[rule["id"]] = "" if value is None else str(value).lower() if isinstance(value, bool) else str(value)
    if not values.get("ear_model.method"):
        manual = (config.get("manual_ppm") or {}).get("enabled")
        inference = config.get("inference") or {}
        values["ear_model.method"] = "manual" if manual else "mesh2ppm" if inference.get("use_predictions_for_preprocessing") or inference.get("enabled") else "none"
    return values


def check(config: dict, stage: str | None = None) -> list[dict]:
    if stage is not None and stage not in STAGES:
        raise ValueError("Unknown stage: " + stage)
    return issues(form_values(config), stage)
