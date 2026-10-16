"""Full-head scan preparation ported from EvaPPM Scripts/_support/prepare_meshes.py.

Geometry follows the archived crop/remesh/Screened Poisson/boundary method.
Crop rotations are explicit per project; there is no subject-name calibration.
"""
from pathlib import Path
import hashlib
import json
import shutil
import tempfile
import uuid
import numpy as np
import networkx as nx
import pymeshlab as ml
import trimesh

TARGET_FACES = 150_000
POISSON = dict(depth=7, fulldepth=5, scale=1.1, samplespernode=3.0,
               pointweight=1.0, iters=8, threads=1)

def load_mesh(path, process=False):
    mesh = trimesh.load_mesh(path, process=process)
    if isinstance(mesh, trimesh.Scene):
        mesh = trimesh.util.concatenate(tuple(mesh.geometry.values()))
    mesh.merge_vertices()
    mesh.remove_unreferenced_vertices()
    return mesh


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def mesh_metrics(mesh):
    edges = np.asarray(mesh.edges_sorted)
    if len(edges):
        unique_edges, counts = np.unique(edges, axis=0, return_counts=True)
        boundary_edges = unique_edges[counts == 1]
        boundary_components = nx.number_connected_components(
            nx.Graph(boundary_edges.tolist())
        ) if len(boundary_edges) else 0
    else:
        boundary_edges = []
        boundary_components = 0
    return {
        "vertices": int(len(mesh.vertices)),
        "faces": int(len(mesh.faces)),
        "bounds_mm": np.asarray(mesh.bounds).tolist(),
        "components": int(len(mesh.split(only_watertight=False, repair=False))),
        "watertight": bool(mesh.is_watertight),
        "winding_consistent": bool(mesh.is_winding_consistent),
        "finite": bool(np.isfinite(mesh.vertices).all()),
        "positive_volume": bool(mesh.volume > 0),
        "euler_number": int(mesh.euler_number),
        "boundary_edges": int(len(boundary_edges)),
        "boundary_components": int(boundary_components),
    }


def boundary_loop_sizes(mesh):
    edges = np.asarray(mesh.edges_sorted)
    if not len(edges):
        return []
    unique_edges, counts = np.unique(edges, axis=0, return_counts=True)
    boundary_edges = unique_edges[counts == 1]
    if not len(boundary_edges):
        return []
    graph = nx.Graph(boundary_edges.tolist())
    return sorted((len(component) for component in nx.connected_components(graph)), reverse=True)


def cap_non_attachment_boundaries(mesh):
    """Fan-cap residual small loops while preserving the largest outer loop."""
    edges = np.asarray(mesh.edges_sorted)
    unique_edges, counts = np.unique(edges, axis=0, return_counts=True)
    boundary_edges = unique_edges[counts == 1]
    if not len(boundary_edges):
        return mesh
    graph = nx.Graph(boundary_edges.tolist())
    loops = sorted(nx.connected_components(graph), key=len, reverse=True)
    if len(loops) <= 1:
        return mesh
    vertices = np.asarray(mesh.vertices).tolist()
    faces = np.asarray(mesh.faces).tolist()
    directed = {
        (int(face[index]), int(face[(index + 1) % 3]))
        for face in np.asarray(mesh.faces)
        for index in range(3)
    }
    for component in loops[1:]:
        subgraph = graph.subgraph(component)
        cycles = nx.cycle_basis(subgraph)
        cycle_edges = {
            tuple(sorted((cycle[index], cycle[(index + 1) % len(cycle)])))
            for cycle in cycles
            for index in range(len(cycle))
        }
        subgraph_edges = {tuple(sorted(edge)) for edge in subgraph.edges}
        if cycle_edges != subgraph_edges:
            raise ValueError("Residual boundary contains an open branch")
        for ordered in cycles:
            center_index = len(vertices)
            vertices.append(np.asarray(mesh.vertices)[ordered].mean(axis=0).tolist())
            for index, first in enumerate(ordered):
                second = ordered[(index + 1) % len(ordered)]
                if (first, second) in directed:
                    faces.append([second, first, center_index])
                else:
                    faces.append([first, second, center_index])
    result = trimesh.Trimesh(
        vertices=np.asarray(vertices, dtype=float),
        faces=np.asarray(faces, dtype=int),
        process=False,
    )
    result.remove_unreferenced_vertices()
    result.fix_normals()
    return result


def close_non_attachment_boundaries(mesh):
    """Use MeshLab to close every boundary smaller than the outer cut."""
    sizes = boundary_loop_sizes(mesh)
    if len(sizes) <= 1:
        return mesh
    ms = ml.MeshSet()
    ms.add_mesh(ml.Mesh(
        vertex_matrix=np.asarray(mesh.vertices),
        face_matrix=np.asarray(mesh.faces),
    ))
    ms.meshing_close_holes(
        maxholesize=int(sizes[1]), selfintersection=False, refinehole=False
    )
    ms.meshing_repair_non_manifold_edges(method=0)
    ms.meshing_repair_non_manifold_vertices(vertdispratio=0.0)
    ms.meshing_remove_unreferenced_vertices()
    current = ms.current_mesh()
    result = trimesh.Trimesh(
        vertices=current.vertex_matrix().copy(),
        faces=current.face_matrix().copy(),
        process=True,
    )
    components = result.split(only_watertight=False, repair=False)
    if not len(components):
        raise ValueError("Hole closing produced no connected surface")
    result = max(components, key=lambda item: len(item.faces))
    # MeshLab deliberately skips some degenerate three- and four-edge loops.
    # Trimesh's narrow fill handles only those residual micro-holes.
    result.fill_holes()
    result = cap_non_attachment_boundaries(result)
    result.fix_normals()
    return result


def attachment_boundary_is_simple(mesh):
    edges = np.asarray(mesh.edges_sorted)
    if not len(edges):
        return False
    unique_edges, counts = np.unique(edges, axis=0, return_counts=True)
    boundary_edges = unique_edges[counts == 1]
    if not len(boundary_edges):
        return False
    graph = nx.Graph(boundary_edges.tolist())
    outer = max(nx.connected_components(graph), key=len)
    return all(graph.degree(vertex) == 2 for vertex in outer)


def regularize_surface(mesh, target_edge_mm):
    """Regularize triangles near an inset cut for the native HRTF grader."""
    ms = ml.MeshSet()
    ms.add_mesh(ml.Mesh(
        vertex_matrix=np.asarray(mesh.vertices),
        face_matrix=np.asarray(mesh.faces),
    ))
    ms.meshing_isotropic_explicit_remeshing(
        iterations=6,
        adaptive=False,
        targetlen=ml.PureValue(target_edge_mm),
        checksurfdist=True,
    )
    current = ms.current_mesh()
    result = trimesh.Trimesh(
        vertices=current.vertex_matrix().copy(),
        faces=current.face_matrix().copy(),
        process=True,
    )
    components = result.split(only_watertight=False, repair=False)
    if not len(components):
        raise ValueError("Final regularization produced no connected surface")
    result = max(components, key=lambda item: len(item.faces))
    result.fix_normals()
    return result


def clip_polygon_to_plane(points, normal, origin):
    result = []
    distances = [float(np.dot(point - origin, normal)) for point in points]
    for index, current in enumerate(points):
        previous = points[index - 1]
        current_distance = distances[index]
        previous_distance = distances[index - 1]
        current_inside = current_distance >= -1e-9
        previous_inside = previous_distance >= -1e-9
        if current_inside != previous_inside:
            t = previous_distance / (previous_distance - current_distance)
            result.append(previous + t * (current - previous))
        if current_inside:
            result.append(current)
    return result


def clip_mesh_to_plane(mesh, normal, origin):
    vertices = np.asarray(mesh.vertices, dtype=float)
    faces = np.asarray(mesh.faces, dtype=int)
    distances = np.dot(vertices - origin, normal)
    new_vertices = vertices.tolist()
    new_faces = []
    for face in faces:
        face_distances = distances[face]
        if np.all(face_distances >= -1e-9):
            new_faces.append(face.tolist())
        elif np.all(face_distances < -1e-9):
            continue
        else:
            clipped = clip_polygon_to_plane(
                [vertices[face[0]], vertices[face[1]], vertices[face[2]]], normal, origin
            )
            if len(clipped) < 3:
                continue
            indices = []
            for point in clipped:
                indices.append(len(new_vertices))
                new_vertices.append(point.tolist())
            for index in range(1, len(indices) - 1):
                new_faces.append([indices[0], indices[index], indices[index + 1]])
    clipped_mesh = trimesh.Trimesh(
        vertices=np.asarray(new_vertices, dtype=float),
        faces=np.asarray(new_faces, dtype=int),
        process=False,
    )
    clipped_mesh.remove_unreferenced_vertices()
    return clipped_mesh


def rotated_scan(path, degrees):
    mesh = load_mesh(path)
    angle = np.deg2rad(degrees)
    transform = np.eye(4)
    transform[:3, :3] = np.array(
        [[np.cos(angle), -np.sin(angle), 0],
         [np.sin(angle), np.cos(angle), 0], [0, 0, 1]], dtype=float
    )
    mesh.apply_transform(transform)
    mesh.apply_translation([0.0, -float((mesh.bounds[0, 1] + mesh.bounds[1, 1]) / 2), 0.0])
    return mesh, degrees


def cut_planes(mesh, side, settings):
    sign = 1 if side == "left" else -1
    margin = settings.left_margin_mm if side == "left" else settings.right_margin_mm
    y_mid = float((mesh.bounds[0, 1] + mesh.bounds[1, 1]) / 2)
    planes = [
        (np.asarray([0.0, sign, 0.0]), np.asarray([0.0, y_mid + sign * (settings.side_min_mm - margin), 0.0])),
        (np.asarray([0.0, -sign, 0.0]), np.asarray([0.0, y_mid + sign * (settings.side_max_mm + margin), 0.0])),
    ]
    polygon = np.asarray(settings.crop_polygon_xz, dtype=float)
    polygon_center = polygon.mean(axis=0)
    center_3d = np.asarray([polygon_center[0], 0.0, polygon_center[1]])
    for index in range(len(polygon)):
        start = polygon[index]
        end = polygon[(index + 1) % len(polygon)]
        direction = end - start
        normal = np.asarray([-direction[1], 0.0, direction[0]], dtype=float)
        origin = np.asarray([start[0], 0.0, start[1]], dtype=float)
        if np.dot(center_3d - origin, normal) < 0:
            normal *= -1.0
        origin -= normal / np.linalg.norm(normal) * margin
        planes.append((normal, origin))
    return planes


def cut_side(mesh, side, settings):
    cut = mesh.copy()
    for normal, origin in cut_planes(mesh, side, settings):
        if len(cut.faces) == 0:
            break
        cut = clip_mesh_to_plane(cut, normal, origin)
    if not len(cut.faces):
        raise ValueError(f"{side} crop is empty")
    cut.merge_vertices()
    cut.remove_unreferenced_vertices()
    return cut


def inverse_rotate(mesh, degrees):
    angle = np.deg2rad(-degrees)
    transform = np.eye(4)
    transform[:3, :3] = np.array(
        [[np.cos(angle), -np.sin(angle), 0],
         [np.sin(angle), np.cos(angle), 0], [0, 0, 1]], dtype=float
    )
    mesh.apply_transform(transform)
    return mesh


def remesh(cut, output, rotation_degrees, target_edge_mm):
    output.parent.mkdir(parents=True, exist_ok=True)
    inverse_rotate(cut, rotation_degrees)
    temp = output.with_suffix(".cut.tmp.stl")
    cut.export(temp)
    try:
        ms = ml.MeshSet()
        ms.load_new_mesh(str(temp))
        ms.meshing_remove_duplicate_faces()
        ms.meshing_remove_duplicate_vertices()
        ms.meshing_remove_unreferenced_vertices()
        ms.meshing_merge_close_vertices(threshold=ml.PercentageValue(0.05))
        ms.meshing_remove_duplicate_faces()
        ms.meshing_remove_duplicate_vertices()
        ms.meshing_remove_unreferenced_vertices()
        ms.meshing_remove_connected_component_by_face_number(mincomponentsize=60, removeunref=True)
        ms.meshing_remove_unreferenced_vertices()
        ms.meshing_isotropic_explicit_remeshing(
            iterations=6, adaptive=False, targetlen=ml.PureValue(target_edge_mm),
            checksurfdist=True,
        )
        if ms.current_mesh().face_number() > TARGET_FACES:
            ms.meshing_decimation_quadric_edge_collapse(
                targetfacenum=TARGET_FACES, preserveboundary=True, boundaryweight=8.0,
                preservenormal=True, optimalplacement=True, autoclean=True,
            )
        ms.save_current_mesh(str(output))
        result = load_mesh(output, process=True)
        components = result.split(only_watertight=False, repair=False)
        if not len(components):
            raise ValueError("Remeshing produced no connected surface")
        result = max(components, key=lambda item: len(item.faces))
        result.fix_normals()
        result.export(output)
        return result
    finally:
        temp.unlink(missing_ok=True)


def screened_poisson(mesh, output):
    output.parent.mkdir(parents=True, exist_ok=True)
    mesh.fix_normals(multibody=True)
    ms = ml.MeshSet()
    ms.add_mesh(ml.Mesh(
        vertex_matrix=np.asarray(mesh.vertices),
        face_matrix=np.asarray(mesh.faces),
        v_normals_matrix=np.asarray(mesh.vertex_normals),
    ))
    ms.generate_surface_reconstruction_screened_poisson(preclean=True, **POISSON)
    current = ms.current_mesh()
    result = trimesh.Trimesh(
        vertices=current.vertex_matrix().copy(),
        faces=current.face_matrix().copy(),
        process=True,
    )
    result.fix_normals(multibody=True)
    result.export(output)
    return result


def restore_attachment_boundary(poisson, planes, rotation_degrees, output, target_edge_mm):
    """Trim Poisson's exterior domain and restore the pinna/head cut boundary."""
    angle = np.deg2rad(rotation_degrees)
    transform = np.eye(4)
    transform[:3, :3] = np.array(
        [[np.cos(angle), -np.sin(angle), 0],
         [np.sin(angle), np.cos(angle), 0], [0, 0, 1]], dtype=float
    )
    poisson.apply_transform(transform)
    vertices = np.asarray(poisson.vertices)
    faces = np.asarray(poisson.faces)
    trimmed = None
    crop_offset_mm = None
    for candidate_offset in (0.0, 0.2, 0.5, 1.0, 1.5):
        keep = np.ones(len(faces), dtype=bool)
        for normal, origin in planes:
            # Retain whole Poisson triangles. Cutting triangles independently
            # duplicates intersection vertices and creates hairline cracks.
            unit_normal = normal / np.linalg.norm(normal)
            shifted_origin = origin + candidate_offset * unit_normal
            keep &= np.all(
                np.dot(vertices[faces] - shifted_origin, normal) >= 0.0, axis=1
            )
        if not np.any(keep):
            continue
        candidate = poisson.submesh(
            [np.flatnonzero(keep)], append=True, repair=False
        )
        candidate.remove_unreferenced_vertices()
        candidate.merge_vertices()
        components = candidate.split(only_watertight=False, repair=False)
        if not len(components):
            continue
        candidate = max(components, key=lambda item: len(item.faces))
        if attachment_boundary_is_simple(candidate):
            trimmed = candidate
            crop_offset_mm = candidate_offset
            break
    if trimmed is None:
        raise ValueError("Could not restore a simple Pinna2HRTF attachment boundary")
    trimmed.fix_normals()
    trimmed = close_non_attachment_boundaries(trimmed)
    if crop_offset_mm > 0:
        trimmed = regularize_surface(trimmed, target_edge_mm)
    if trimmed.volume < 0:
        trimmed.invert()
    output.parent.mkdir(parents=True, exist_ok=True)
    trimmed.export(output.with_suffix(".ply"))
    trimmed.export(output)
    verified = load_mesh(output, process=True)
    components = verified.split(only_watertight=False, repair=False)
    if len(components) > 1:
        components = sorted(components, key=lambda item: len(item.faces), reverse=True)
        stray_faces = sum(len(item.faces) for item in components[1:])
        if stray_faces <= max(10, int(len(components[0].faces) * 0.001)):
            verified = components[0]
            verified.fix_normals()
            verified.export(output.with_suffix(".ply"))
            verified.export(output)
            verified = load_mesh(output, process=True)
    checks = mesh_metrics(verified)
    if not all(checks[k] for k in ("winding_consistent", "finite", "positive_volume")):
        raise ValueError(f"Final ear topology failed: {checks}")
    if checks["components"] != 1:
        raise ValueError(f"Final ear has {checks['components']} connected components")
    if checks["boundary_components"] != 1:
        raise ValueError(
            f"Final ear needs exactly one Pinna2HRTF attachment boundary, found "
            f"{checks['boundary_components']}: {checks}"
        )
    if not attachment_boundary_is_simple(verified):
        raise ValueError("Final Pinna2HRTF attachment boundary is self-touching")
    return verified, crop_offset_mm



def file_identity(path):
    stat = Path(path).stat()
    return {"size": stat.st_size, "mtime": stat.st_mtime}


def preparation_signature(settings):
    source = Path(settings.scan_path)
    return {"settings": settings.model_dump(mode="json"), "source_sha256": sha256(source)}


def prepared_paths(config):
    folder = config.paths.output_dir / "Prepared"
    settings = config.scan_preparation
    return (folder / "Left.stl" if settings.prepare_left else None,
            folder / "Right.stl" if settings.prepare_right else None)


def validate_prepared(config):
    """Check provenance and actual serialized topology before consuming outputs."""
    folder = config.paths.output_dir / "Prepared"
    report = json.loads((folder / "mesh_preparation.json").read_text())
    if report.get("status") != "completed" or report.get("signature") != preparation_signature(config.scan_preparation):
        raise ValueError("Scan preparation is out of date; run Scan Preparation again.")
    for side, path in zip(("left", "right"), prepared_paths(config)):
        if path is None:
            continue
        if report["ears"][side]["sha256"] != sha256(path):
            raise ValueError(f"Prepared {side} ear was changed; run Scan Preparation again.")
        mesh = load_mesh(path, process=True)
        checks = mesh_metrics(mesh)
        if not all(checks[k] for k in ("finite", "winding_consistent", "positive_volume")) or checks["components"] != 1 or checks["boundary_components"] != 1 or not attachment_boundary_is_simple(mesh):
            raise ValueError(f"Prepared {side} ear is unsuitable for stitching: {checks}")
    return report


def prepare_scan(config, logger=print):
    settings = config.scan_preparation
    if settings.scan_path is None or settings.rotation_degrees is None:
        raise ValueError("Choose a full-head scan and an explicit crop rotation before scan preparation.")
    if not settings.prepare_left and not settings.prepare_right:
        raise ValueError("Select at least one ear to prepare.")
    source = Path(settings.scan_path)
    output = config.paths.output_dir / "Prepared"
    # Never overwrite an input even if a project has been pointed at generated output.
    if source.resolve() == output.resolve() or output.resolve() in source.resolve().parents:
        raise ValueError("The source scan must be outside the generated Prepared folder.")
    signature = preparation_signature(settings)
    report = {"status": "completed", "generation": uuid.uuid4().hex, "source_identity": file_identity(source), "signature": signature, "poisson": POISSON,
              "method_source": "EvaPPM/Scripts/_support/prepare_meshes.py", "ears": {}}
    with tempfile.TemporaryDirectory(prefix="pinna-scan-") as temporary:
        work = Path(temporary)
        mesh, degrees = rotated_scan(source, settings.rotation_degrees)
        if not np.isfinite(mesh.vertices).all() or not len(mesh.faces):
            raise ValueError("The full-head scan must contain finite, nonempty geometry.")
        for side, enabled in (("left", settings.prepare_left), ("right", settings.prepare_right)):
            if not enabled:
                continue
            logger(f"Scan preparation: cropping and remeshing {side} ear")
            planes = cut_planes(mesh, side, settings)
            remeshed = remesh(cut_side(mesh, side, settings), work / f"{side}_remeshed.stl", degrees, settings.target_edge_mm)
            logger(f"Scan preparation: Screened Poisson hole closing, {side} ear")
            poisson = screened_poisson(remeshed, work / f"{side}_poisson.ply")
            ready_path = work / f"{side.title()}.stl"
            logger(f"Scan preparation: restoring and validating {side} attachment boundary")
            ready, inset = restore_attachment_boundary(poisson, planes, degrees, ready_path, settings.target_edge_mm)
            if np.sign(np.mean(ready.vertices[:, 1])) != (1 if side == "left" else -1):
                raise ValueError(f"Prepared {side} ear is on the wrong side. Review the scan's crop rotation and alignment.")
            report["ears"][side] = {"sha256": sha256(ready_path), "identity": file_identity(ready_path), "crop_boundary_inset_mm": inset,
                                    "metrics": mesh_metrics(ready)}
        if signature != preparation_signature(settings):
            raise ValueError("The source scan changed during preparation; outputs were not published.")
        # No prepared meshes are published until all selected ears pass validation.
        output.mkdir(parents=True, exist_ok=True)
        for side in report["ears"]:
            shutil.copy2(work / f"{side.title()}.stl", output / f"{side.title()}.stl")
            report["ears"][side]["identity"] = file_identity(output / f"{side.title()}.stl")
        report_temp = output / ".mesh_preparation.json.tmp"
        report_temp.write_text(json.dumps(report, indent=2) + "\n")
        report_temp.replace(output / "mesh_preparation.json")
    validate_prepared(config)
    logger(f"Scan preparation completed: {output}")


def record_stage(config, stage, outputs):
    folder = config.paths.output_dir / "Prepared"
    report = json.loads((folder / "mesh_preparation.json").read_text())
    receipt = {"generation": report["generation"],
               "outputs": {str(path): sha256(path) for path in outputs}}
    if stage == "inference":
        receipt["settings"] = config.inference.model_dump(mode="json")
    (folder / f"{stage}.json").write_text(json.dumps(receipt, indent=2) + "\n")


def validate_stage(config, stage):
    folder = config.paths.output_dir / "Prepared"
    report = json.loads((folder / "mesh_preparation.json").read_text())
    path = folder / f"{stage}.json"
    if not path.exists():
        raise ValueError(f"Run {stage} again after Scan Preparation.")
    receipt = json.loads(path.read_text())
    if receipt.get("generation") != report["generation"]:
        raise ValueError(f"Run {stage} again after Scan Preparation.")
    if stage == "inference" and receipt.get("settings") != config.inference.model_dump(mode="json"):
        raise ValueError("Inference settings changed; run inference again.")
    for output, digest in receipt["outputs"].items():
        if sha256(output) != digest:
            raise ValueError(f"{stage} output changed: {output}. Run {stage} again.")
