import json
from pathlib import Path

from .FileIdentity import cached_sha256

PLACEMENTS_RELATIVE = Path(".pinna2hrtf") / "microphone-placements.json"
PLACEMENTS_FORMAT = "pinna2hrtf-microphone-placements-v1"
SIDES = ("left", "right")


def placement_key(side: str) -> str:
    return "source_position_input_" + side


def read_placements(output_dir: Path) -> dict:
    try:
        document = json.loads(placements_path(output_dir).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    if not isinstance(document, dict) or document.get("format") != PLACEMENTS_FORMAT:
        return {}
    return {side: document[side] for side in SIDES if isinstance(document.get(side), dict)}


def matching_record(placements: dict, side: str, position) -> dict | None:
    record = placements.get(side)
    if record is None or position is None or [float(value) for value in position] != record.get("position_mm"):
        return None
    return record


def status(placements: dict, side: str, position, mesh: Path | None) -> str:
    record = matching_record(placements, side, position)
    if record is None or not record.get("mesh_sha256"):
        return "unrecorded"
    if mesh is not None and Path(mesh).is_file() and cached_sha256(mesh) == record["mesh_sha256"]:
        return "current"
    return "stale"


def is_stale(placements: dict, side: str, position, mesh: Path | None) -> bool:
    return status(placements, side, position, mesh) == "stale"


def preprocessing_meshes(config) -> dict:
    from .RunConfig import preprocessing_input_paths
    try:
        return dict(zip(SIDES, preprocessing_input_paths(config, lambda _: None)))
    except (OSError, ValueError, KeyError):
        return {}


def statuses(config, placements: dict) -> dict:
    positions = {side: getattr(config.preprocessing, placement_key(side)) for side in SIDES}
    meshes = preprocessing_meshes(config) if placements else {}
    return {side: status(placements, side, position, meshes.get(side)) for side, position in positions.items() if position is not None}


def placements_path(output_dir: Path) -> Path:
    return Path(output_dir) / PLACEMENTS_RELATIVE


def updated_placements(config, edited_preprocessing: dict, previous: dict) -> dict | None:
    confirmed = {side for side in SIDES if edited_preprocessing.get(placement_key(side)) is not None}
    meshes = preprocessing_meshes(config) if confirmed else {}
    document = {"format": PLACEMENTS_FORMAT}
    for side in SIDES:
        if placement_key(side) not in edited_preprocessing:
            if side in previous:
                document[side] = previous[side]
        elif side in confirmed and meshes.get(side) is not None and Path(meshes[side]).is_file():
            position = getattr(config.preprocessing, placement_key(side))
            document[side] = {"position_mm": [float(value) for value in position], "mesh_sha256": cached_sha256(meshes[side])}
    if document == {"format": PLACEMENTS_FORMAT, **previous}:
        return None
    if len(document) == 1 and not placements_path(config.paths.output_dir).exists():
        return None
    return document


def ignore_stale_placements(config, logger, placements: dict | None = None) -> None:
    if placements is None:
        placements = read_placements(config.paths.output_dir)
    if not placements:
        return
    meshes = preprocessing_meshes(config)
    for side in SIDES:
        position = getattr(config.preprocessing, placement_key(side))
        if meshes and meshes.get(side) is None:
            continue
        if is_stale(placements, side, position, meshes.get(side)):
            setattr(config.preprocessing, placement_key(side), None)
            logger(stale_message(side))


def stale_message(side: str) -> str:
    return f"Ignoring the saved {side} microphone position because it does not match the current {side} ear mesh. Place the microphone again to use it."
