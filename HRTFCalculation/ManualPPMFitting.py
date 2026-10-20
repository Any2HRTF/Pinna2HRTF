"""Create and export parameterized BezierPPM fits for the native editor."""
from __future__ import annotations

import json
import math
import struct
import sys
from contextlib import redirect_stdout
from pathlib import Path

from bezierppm import BezierPPM
import bpy
from mathutils import Euler, Quaternion, Vector
import numpy as np
from scipy.spatial import cKDTree
import trimesh
from trimesh.transformations import reflection_matrix


_blender_scene_ready = False
_reference_tree: cKDTree | None = None

# Weight bounds from Perfler et al. (2025), Table 1. Only the two Crus
# helicis dent keys are restricted to nonnegative weights.
_SHAPE_KEY_RANGES = {
    "Antitragus-Crease": (-1.0, 1.0),
    "Cavum conchae-Depth": (-1.0, 1.0),
    "Cymba conchae-Depth": (-1.0, 1.0),
    "Crus helicis-Prominence": (-1.0, 1.0),
    "Upper helix-Depth": (-1.0, 1.0),
    "Middle helix-Depth": (-1.0, 1.0),
    "Lower helix-Depth": (-1.0, 1.0),
    "Scapha-Depth": (-1.0, 1.0),
    "Fossa triangularis-Depth": (-1.0, 1.0),
    "Crus inferius anthelicis-Lower crease": (-1.0, 1.0),
    "Crus inferius anthelicis-Upper crease": (-1.0, 1.0),
    "Crus superius anthelicis-Lower crease": (-1.0, 1.0),
    "Crus superius anthelicis-Upper crease": (-1.0, 1.0),
    "Tragus-Upper dent": (-1.0, 1.0),
    "Crus helicis-Upper dent": (0.0, 1.0),
    "Crus helicis-Lower dent": (0.0, 1.0),
    "Ear canal-Diameter": (-1.0, 1.0),
}


def _read_parameters(path: str | None) -> tuple[dict[str, float] | None, str | None]:
    if not path:
        return None, None
    document = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(document, dict) or not isinstance(document.get("parameters"), dict):
        raise ValueError("The saved manual PPM parameters are invalid.")
    parameters = {str(key): float(value) for key, value in document["parameters"].items()}
    return parameters, document.get("template_blend")


def _initial_parameters(template_blend: str | None) -> dict[str, float]:
    model = BezierPPM(from_blender_file=template_blend) if template_blend else BezierPPM()
    return {str(key): float(value) for key, value in model.get_parameter_dict().items()}


def _range(value: float, lower: float, upper: float) -> tuple[float, float]:
    return min(lower, value), max(upper, value)


def _control(identifier: str, section: str, group: str, label: str, value: float,
             lower: float, upper: float, unit: str = "",
             expand_range_to_value: bool = True) -> dict:
    if expand_range_to_value:
        lower, upper = _range(value, lower, upper)
    return {"id": identifier, "section": section, "group": group, "label": label,
            "value": value, "minimum": lower, "maximum": upper, "unit": unit}


def _parent_location_basis():
    """Map Parent-Bendy bone-local translations into world-space axes."""
    armature = bpy.data.objects["Armature"]
    bone = armature.pose.bones["Parent-Bendy"].bone
    return armature.matrix_world.to_3x3() @ bone.matrix_local.to_3x3()


def _parent_location_in_world(parameters: dict[str, float]) -> Vector:
    local = Vector(tuple(float(parameters.get(f"Bendy bone-Parent-Location {axis}", 0.0))
                         for axis in "XYZ"))
    return _parent_location_basis() @ local


def _controls_from_parameters(parameters: dict[str, float]) -> list[dict]:
    controls: list[dict] = []
    rotations: dict[tuple[str, str, str], dict[str, float]] = {}
    names: dict[tuple[str, str], str] = {}
    parent_location_world = _parent_location_in_world(parameters)

    for key, raw_value in parameters.items():
        value = float(raw_value)
        if key.startswith("Shape-") and key.endswith("-Weight"):
            shape = key[len("Shape-"):-len("-Weight")]
            title = shape.replace("-", " · ")
            if shape not in _SHAPE_KEY_RANGES:
                raise ValueError(f"No published fitting range is defined for shape key '{shape}'.")
            lower, upper = _SHAPE_KEY_RANGES[shape]
            controls.append(_control(f"Shape|{shape}", "concave", "Concave details", title,
                                     value, lower, upper, "", expand_range_to_value=False))
            continue

        try:
            point_name, bone_name, function = key.split("-", 2)
            kind, axis = function.rsplit(" ", 1)
        except ValueError:
            continue
        point = point_name.removesuffix(" bone")
        bone = bone_name
        if bone == "Parent":
            section, group = "global", "Global fit"
        else:
            section, group = "convex", bone
        names[(bone, point)] = group

        if kind == "Location" and axis in {"X", "Y", "Z"}:
            if bone == "Parent" and point == "Bendy":
                value_mm = float(parent_location_world["XYZ".index(axis)]) * 1000.0
            else:
                value_mm = value * 1000.0
            extent = 100.0 if bone == "Parent" else 35.0
            controls.append(_control(f"{bone}|{point}|Location|{axis}", section, group,
                                     f"{point} · {axis}", value_mm, -extent, extent, "mm"))
        elif kind == "Scale":
            extent = (0.5, 1.5) if bone == "Parent" else (0.5, 1.5)
            label = f"Scale {axis}" if bone == "Parent" else "Scale"
            controls.append(_control(f"{bone}|{point}|Scale|{axis}", section, group, label,
                                     value, extent[0], extent[1], "×"))
        elif kind == "Rotation" and axis in {"W", "X", "Y", "Z"}:
            rotation_key = (bone, point, section)
            rotations.setdefault(rotation_key, {})[axis] = value

    for (bone, point, section), quaternion in rotations.items():
        group = names.get((bone, point), "Global fit" if bone == "Parent" else bone)
        quat = Quaternion((quaternion.get("W", 1.0), quaternion.get("X", 0.0),
                           quaternion.get("Y", 0.0), quaternion.get("Z", 0.0)))
        euler = quat.to_euler("ZYX")
        extent = 180.0 if bone == "Parent" else 90.0
        for axis, radians in zip(("X", "Y", "Z"), euler):
            controls.append(_control(f"{bone}|{point}|Rotation|{axis}", section, group,
                                     f"{point} · {axis}", math.degrees(radians),
                                     -extent, extent, "°"))

    order = {"global": 0, "convex": 1, "concave": 2}
    controls.sort(key=lambda item: (order[item["section"]], item["group"].casefold(), item["id"]))
    return controls


def _apply_controls(parameters: dict[str, float], control_values: dict[str, float]) -> dict[str, float]:
    model = BezierPPM(from_dict=parameters)
    by_group: dict[tuple[str, str, str], dict[str, float]] = {}
    shape_values: list[tuple[str, float]] = []
    for identifier, raw_value in control_values.items():
        value = float(raw_value)
        if not math.isfinite(value):
            raise ValueError("PPM controls must contain finite values.")
        parts = identifier.split("|")
        if parts[0] == "Shape" and len(parts) == 2:
            shape_values.append((parts[1], value))
        elif len(parts) == 4:
            bone, point, kind, axis = parts
            by_group.setdefault((bone, point, kind), {})[axis] = value

    for (bone, point, kind), axes in by_group.items():
        if kind == "Rotation":
            current = {}
            for axis in "WXYZ":
                raw_key = f"{point} bone-{bone}-Rotation {axis}"
                current[axis] = float(parameters.get(raw_key, 1.0 if axis == "W" else 0.0))
            euler = Quaternion((current["W"], current["X"], current["Y"], current["Z"])).to_euler("ZYX")
            degrees = {"X": math.degrees(euler.x), "Y": math.degrees(euler.y), "Z": math.degrees(euler.z)}
            degrees.update(axes)
            # Recompose with Blender's own Euler implementation so the untouched axes
            # remain stable when editing one component of a ZYX rotation.
            rotation = Euler(tuple(math.radians(degrees[axis]) for axis in "XYZ"), "ZYX").to_quaternion()
            model.set_parameter(name=bone, type="Rotation", point=point,
                                value=tuple(float(component) for component in rotation), axis="WXYZ")
        elif kind == "Location":
            if bone == "Parent" and point == "Bendy":
                basis = _parent_location_basis()
                local = Vector(tuple(float(parameters.get(f"{point} bone-{bone}-Location {name}", 0.0))
                                     for name in "XYZ"))
                world = basis @ local
                for name, value in axes.items():
                    world["XYZ".index(name)] = value / 1000.0
                local = basis.inverted() @ world
                model.set_parameter(name=bone, type="Location", point=point,
                                    value=tuple(float(local[index]) for index in range(3)), axis="XYZ")
            else:
                axis = "".join(name for name in "XYZ" if name in axes)
                model.set_parameter(name=bone, type="Location", point=point,
                                    value=tuple(axes[name] / 1000.0 for name in axis), axis=axis)
        elif kind == "Scale":
            if bone == "Parent":
                current = {axis: float(parameters.get(f"Bendy bone-Parent-Scale {axis}", 1.0)) for axis in "XYZ"}
                current.update(axes)
                model.set_parameter(name=bone, type="Scale", value=tuple(current[axis] for axis in "XYZ"), axis="XYZ")
            else:
                model.set_parameter(name=bone, type="Scale", value=(next(iter(axes.values())),))

    for shape, value in shape_values:
        model.set_parameter(name=shape, type="Shape key", value=(value,))
    return {str(key): float(value) for key, value in model.get_parameter_dict().items()}


def _export(model: BezierPPM, path: str, mirror_y: bool) -> None:
    global _blender_scene_ready
    if _blender_scene_ready:
        # BezierPPM normally reopens its bundled .blend for every export. Keep
        # that scene warm during interactive fitting and just update its rig.
        model._BezierPPM__load_blender_file = lambda _filepath: None
    model.export_stl(file=path)
    _blender_scene_ready = True
    if mirror_y:
        mesh = trimesh.load_mesh(path, process=False)
        mesh.apply_transform(reflection_matrix(np.array([0, 0, 0, 0]), np.array([0, 1, 0])))
        mesh.export(path)


def _prepare_model(model: BezierPPM) -> None:
    """Apply parameters to the already-open Blender scene."""
    global _blender_scene_ready
    if _blender_scene_ready:
        model._BezierPPM__load_blender_file = lambda _filepath: None
    model._BezierPPM__set_parameters_in_blender()
    _blender_scene_ready = True


def _load_reference_tree(path: str) -> None:
    global _reference_tree
    loaded = trimesh.load(path, process=False)
    reference = loaded.dump(concatenate=True) if isinstance(loaded, trimesh.Scene) else loaded
    points = np.asarray(reference.vertices, dtype=np.float64)
    if points.ndim != 2 or points.shape[0] == 0 or points.shape[1] != 3:
        raise ValueError("The target mesh does not contain usable vertices for distance metrics.")
    _reference_tree = cKDTree(points)


def _metric_report(current: dict[str, float]) -> dict[str, dict[str, float]]:
    names = ("ppm_to_target_rmse", "target_to_ppm_rmse", "symmetric_rmse",
             "mean", "median", "max", "min")
    return {name: {"value": current[name]} for name in names}


def _write_preview_mesh(parameters: dict[str, float], path: str, mirror_y: bool = False) -> dict[str, float]:
    """Write evaluated vertices and triangles without exporting/reloading an STL."""
    model = BezierPPM(from_dict=parameters)
    _prepare_model(model)

    obj = bpy.data.objects["Mesh"]
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        mesh.transform(obj.matrix_world)
        mesh.calc_loop_triangles()
        vertices = np.asarray([vertex.co[:] for vertex in mesh.vertices], dtype="<f4")
        triangles = np.asarray([triangle.vertices for triangle in mesh.loop_triangles], dtype="<u4")
    finally:
        evaluated.to_mesh_clear()

    if _reference_tree is None:
        raise ValueError("The target mesh distance index is unavailable.")
    metric_vertices = vertices.copy()
    if mirror_y:
        metric_vertices[:, 1] *= -1
    distances, _ = _reference_tree.query(metric_vertices, k=1, workers=-1)
    target_points = np.asarray(_reference_tree.data, dtype=np.float64)
    reverse_distances, _ = cKDTree(metric_vertices).query(target_points, k=1, workers=-1)
    ppm_to_target_rmse = float(np.sqrt(np.mean(np.square(distances))))
    target_to_ppm_rmse = float(np.sqrt(np.mean(np.square(reverse_distances))))
    symmetric_rmse = float(np.sqrt((ppm_to_target_rmse ** 2 + target_to_ppm_rmse ** 2) / 2))
    metrics = {"mean": float(np.mean(distances)), "median": float(np.median(distances)),
               "max": float(np.max(distances)), "min": float(np.min(distances)),
               "ppm_to_target_rmse": ppm_to_target_rmse,
               "target_to_ppm_rmse": target_to_ppm_rmse,
               "symmetric_rmse": symmetric_rmse}

    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    with temporary.open("wb") as stream:
        stream.write(struct.pack("<II", len(vertices), len(triangles)))
        stream.write(vertices.tobytes())
        stream.write(triangles.tobytes())
        # Keep the per-vertex PPM -> target distances beside the preview geometry
        # so the app can color the surface without another distance pass.
        stream.write(np.asarray(distances, dtype="<f4").tobytes())
    temporary.replace(destination)
    return metrics


def _posed_skeleton() -> list[dict]:
    """Return posed rig points in the same world coordinates as preview.meshbin.

    Segment joint matrices are bone-local; the evaluated pose matrix places the
    curved B-Bone in armature space, then matrix_world places it beside the mesh.
    Mirroring is applied by the native preview to both mesh and rig together.
    """
    depsgraph = bpy.context.evaluated_depsgraph_get()
    armature = bpy.data.objects["Armature"].evaluated_get(depsgraph)
    bones = []
    for bone in armature.pose.bones:
        segments = bone.bone.bbone_segments
        if segments > 1:
            transform = armature.matrix_world @ bone.matrix
            points = [transform @ bone.bbone_segment_matrix(i).translation
                      for i in range(segments + 1)]
        else:
            points = [armature.matrix_world @ bone.head,
                      armature.matrix_world @ bone.tail]
        bones.append({"name": bone.name,
                      "points": [[float(v) for v in point] for point in points]})
    return bones


def execute(command: dict) -> dict:
    action = command.get("action")
    template_blend = command.get("template_blend") or None
    saved_path = command.get("saved_parameters") or None
    saved_parameters, saved_template = _read_parameters(saved_path)
    if saved_template and Path(saved_template).is_file():
        template_blend = saved_template

    if saved_parameters is not None:
        parameters = saved_parameters
    else:
        parameters = _initial_parameters(template_blend)

    if action == "initialize":
        _load_reference_tree(command["target_mesh"])
        metrics = _write_preview_mesh(parameters, command["mesh_data"],
                                      bool(command.get("mirror_y", False)))
        return {"parameters": parameters, "controls": _controls_from_parameters(parameters),
                "template_blend": template_blend or "", "mesh_data": command["mesh_data"],
                "metrics": _metric_report(metrics), "skeleton": _posed_skeleton()}

    if action in {"preview", "preview_mesh", "save"}:
        submitted = command.get("parameters")
        if isinstance(submitted, dict):
            parameters = {str(key): float(value) for key, value in submitted.items()}
        parameters = _apply_controls(parameters, command.get("controls", {}))
        if action == "preview_mesh":
            metrics = _write_preview_mesh(parameters, command["mesh_data"],
                                          bool(command.get("mirror_y", False)))
            return {"parameters": parameters, "controls": _controls_from_parameters(parameters),
                    "template_blend": template_blend or "", "mesh_data": command["mesh_data"],
                    "metrics": _metric_report(metrics), "skeleton": _posed_skeleton()}
        model = BezierPPM(from_dict=parameters)
        _export(model, command["output"], bool(command.get("mirror_y", False)))
        blend_output = command.get("blend_output")
        if blend_output:
            _prepare_model(model)
            if command.get("mirror_y", False):
                bpy.data.objects["Mesh"].scale.y *= -1
            model.export_blend(file=blend_output)
        return {"parameters": parameters, "controls": _controls_from_parameters(parameters),
                "template_blend": template_blend or ""}

    raise ValueError(f"Unknown manual PPM action: {action}")


def serve() -> None:
    """Serve line-delimited preview commands without restarting Blender."""
    response_stream = sys.stdout
    for line in sys.stdin:
        try:
            command = json.loads(line)
            if command.get("action") == "shutdown":
                return
            with redirect_stdout(sys.stderr):
                result = execute(command)
            response = result
        except Exception as error:
            response = {"error": str(error)}
        response_stream.write(json.dumps(response, allow_nan=False) + "\n")
        response_stream.flush()
