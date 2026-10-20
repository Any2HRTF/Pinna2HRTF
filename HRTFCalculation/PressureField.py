"""Read NumCalc pressure fields for the native artifact viewer.

Boundary pressure is constant per element; evaluation pressure is nodal.
Geometry and results are joined by IDs, never by file row order.
"""
from pathlib import Path
import math
import re


def _number(value):
    number = float(value.replace("D", "E").replace("d", "e"))
    if not math.isfinite(number):
        raise ValueError("Pressure data contains a non-finite value")
    return number


def _records(path):
    lines = [line.split("#", 1)[0].strip() for line in path.read_text().splitlines()]
    return [line.split() for line in lines if line]


def _geometry(source):
    sections = {"NODES": [], "ELEMENTS": []}
    section = None
    for line in source.read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line in sections:
            section = line
        elif line == "BOUNDARY":
            break
        elif section:
            sections[section].append(source.parent / line.strip('"'))
    nodes, elements = {}, []
    for path in sections["NODES"]:
        records = _records(path)
        if not records or len(records) - 1 != int(records[0][0]):
            raise ValueError(f"Incomplete node file: {path.name}")
        for row in records[1:]:
            if len(row) != 4:
                raise ValueError(f"Invalid node record in {path.name}")
            identifier = int(row[0])
            if identifier in nodes:
                raise ValueError(f"Duplicate node ID: {identifier}")
            nodes[identifier] = [_number(value) for value in row[1:]]
    ids = set()
    for path in sections["ELEMENTS"]:
        records = _records(path)
        if not records or len(records) - 1 != int(records[0][0]):
            raise ValueError(f"Incomplete element file: {path.name}")
        for row in records[1:]:
            if len(row) not in (7, 8):
                raise ValueError("Only triangular and quadrilateral NumCalc elements are supported")
            values = [int(value) for value in row]
            identifier, corners, kind = values[0], values[1:-3], values[-3]
            if identifier in ids:
                raise ValueError(f"Duplicate element ID: {identifier}")
            if any(corner not in nodes for corner in corners):
                raise ValueError(f"Element {identifier} refers to a missing node")
            ids.add(identifier)
            elements.append((identifier, corners, kind))
    if not nodes or not elements:
        raise ValueError("NC.inp does not reference usable mesh geometry")
    return nodes, elements


def _pressure(path):
    records = _records(path)
    # NumCalc: version, number of groups, then group ID/count and complex rows.
    if len(records) < 3:
        raise ValueError(f"Incomplete pressure file: {path.name}")
    values = {}
    remaining = 0
    for row in records[2:]:
        if len(row) == 2:
            if remaining:
                raise ValueError(f"Incomplete pressure group in {path.name}")
            remaining = int(row[1])
        elif len(row) == 3 and remaining > 0:
            identifier = int(row[0])
            if identifier in values:
                raise ValueError(f"Duplicate pressure ID: {identifier}")
            values[identifier] = [_number(row[1]), _number(row[2])]
            remaining -= 1
        else:
            raise ValueError(f"Invalid pressure record in {path.name}")
    if remaining or not values:
        raise ValueError(f"Incomplete pressure file: {path.name}")
    return values


def _frequencies(source):
    # Use the solver's frequency curve, not a reconstructed linspace.
    text = source.read_text()
    match = re.search(r"^\s*##?\s*Load Frequency Curve[^\n]*\n", text, re.M | re.I)
    if not match:
        return {}
    lines = [line.split() for line in text[match.end():].splitlines() if line.strip() and not line.lstrip().startswith("#")]
    count = int(lines[0][1])
    curve = lines[1:count + 1]
    if len(curve) != count or any(len(row) != 3 for row in curve):
        raise ValueError("Incomplete NumCalc frequency curve")
    return {index: _number(row[1]) for index, row in enumerate(curve) if index > 0}


def inspect(source):
    source = Path(source)
    frequencies = _frequencies(source)
    steps = []
    for folder in source.parent.joinpath("be.out").glob("be.*"):
        match = re.fullmatch(r"be\.(\d+)", folder.name)
        if not match or not folder.is_dir():
            continue
        surfaces = [name for name, filename in [("Boundary", "pBoundary"), ("Evaluation Grid", "pEvalGrid")]
                    if folder.joinpath(filename).is_file()]
        if surfaces:
            step = int(match[1])
            steps.append({"id": step, "frequency": frequencies.get(step), "surfaces": surfaces})
    if not steps:
        raise ValueError("No pressure results found. Run NumCalc first.")
    return {"steps": sorted(steps, key=lambda item: item["id"])}


def frame(source, step, surface):
    source = Path(source)
    if surface not in ("Boundary", "Evaluation Grid") or int(step) < 1:
        raise ValueError("Invalid pressure field selection")
    nodes, elements = _geometry(source)
    is_boundary = surface == "Boundary"
    pressures = _pressure(source.parent / "be.out" / f"be.{int(step)}" / ("pBoundary" if is_boundary else "pEvalGrid"))
    selected = [element for element in elements if (element[2] != 2) == is_boundary]
    if not selected:
        raise ValueError(f"No {surface.lower()} elements in NC.inp")
    used = sorted({node for _, corners, _ in selected for node in corners})
    indices = {identifier: index for index, identifier in enumerate(used)}
    triangles, value_ids = [], []
    for identifier, corners, _ in selected:
        for index in range(1, len(corners) - 1):
            triangles.append([indices[corners[0]], indices[corners[index]], indices[corners[index + 1]]])
            value_ids.append(identifier)
    required = value_ids if is_boundary else used
    missing = set(required) - pressures.keys()
    if missing:
        raise ValueError(f"Pressure results are incomplete: {len(missing)} IDs missing for {surface.lower()}")
    return {"vertices": [nodes[identifier] for identifier in used], "triangles": triangles,
            "association": "cell" if is_boundary else "point",
            "real": [pressures[identifier][0] for identifier in required],
            "imaginary": [pressures[identifier][1] for identifier in required]}


def execute(command):
    if command.get("action") == "inspect":
        return inspect(command["source"])
    if command.get("action") == "frame":
        return frame(command["source"], command["step"], command["surface"])
    raise ValueError("Unknown pressure viewer command")
