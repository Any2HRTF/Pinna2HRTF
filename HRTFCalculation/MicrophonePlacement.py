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
        document = json.loads((Path(output_dir) / PLACEMENTS_RELATIVE).read_text(encoding="utf-8"))
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
    if record is None:
        return "unrecorded"
    if record.get("mesh_sha256") and mesh is not None and Path(mesh).is_file() and cached_sha256(mesh) == record["mesh_sha256"]:
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


def statuses(config) -> dict:
    placements = read_placements(config.paths.output_dir)
    positions = {side: getattr(config.preprocessing, placement_key(side)) for side in SIDES}
    meshes = preprocessing_meshes(config) if placements else {}
    return {side: status(placements, side, position, meshes.get(side)) for side, position in positions.items() if position is not None}


def record_placements(config, confirmed_sides) -> None:
    previous = read_placements(config.paths.output_dir)
    meshes = preprocessing_meshes(config) if confirmed_sides else {}
    document = {"format": PLACEMENTS_FORMAT}
    for side in SIDES:
        position = getattr(config.preprocessing, placement_key(side))
        if position is None:
            continue
        position_mm = [float(value) for value in position]
        record = matching_record(previous, side, position)
        if side not in confirmed_sides:
            document[side] = {"position_mm": position_mm, "mesh_sha256": None}
        elif record is not None and record.get("mesh_sha256"):
            document[side] = record
        elif meshes.get(side) is not None and Path(meshes[side]).is_file():
            document[side] = {"position_mm": position_mm, "mesh_sha256": cached_sha256(meshes[side])}
    path = Path(config.paths.output_dir) / PLACEMENTS_RELATIVE
    if document == {"format": PLACEMENTS_FORMAT, **previous} or (len(document) == 1 and not path.exists()):
        return
    from .Outputs import write_json
    path.parent.mkdir(parents=True, exist_ok=True)
    write_json(path, document)


def ignore_stale_placements(config, logger) -> None:
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
