"""
Takes a 3D mesh of an ear (without head) and closes the ear canal opening with a triangulated surface.
It will be mainly used and tested with PPM predicted ears.

Exports an .stl of the closed ear to export_path

Attention: The correction of the face orientation is not fully tested and might only work for a concave ear canal cover
as it just flips the faces without check for orientation


Lukas Thalhammer, Acoustics Research Institute
August 2024
"""

import argparse
import json
import numpy as np
import trimesh
import shapely


def _side_sign(side, vertices):
    if side == "left":
        return 1
    if side == "right":
        return -1
    return 1 if np.mean(vertices[:, 1]) >= 0 else -1


def _mesh_boundaries(ear):
    try:
        return sorted([bound.discrete(ear.vertices) for bound in ear.outline().entities], key=len, reverse=True)
    except Exception:
        return []


def estimate_ear_canal_position(ear, side="auto"):
    vertices = np.asarray(ear.vertices)
    boundaries = _mesh_boundaries(ear)
    sign = _side_sign(side, vertices)

    if len(boundaries) > 1:
        loop = max(boundaries[1:], key=len)
        center = np.mean(loop, axis=0)
        radius = float(np.mean(np.linalg.norm(loop - center, axis=1)))
        return {
            "position": center.tolist(),
            "method": "open_boundary",
            "confidence": 1.0,
            "radius": radius,
            "boundary_count": len(boundaries),
        }

    if len(boundaries) == 1:
        local_center = np.mean(boundaries[0], axis=0)
        local_extent = np.ptp(boundaries[0], axis=0)
    else:
        local_center = np.median(vertices, axis=0)
        local_extent = np.ptp(vertices, axis=0)

    centers = np.asarray(ear.triangles_center)
    x_radius = max(float(local_extent[0]) * 0.2, 1.0)
    z_radius = max(float(local_extent[2]) * 0.2, 1.0)
    normalized = ((centers[:, 0] - local_center[0]) / x_radius) ** 2 + ((centers[:, 2] - local_center[2]) / z_radius) ** 2
    candidates = np.flatnonzero(normalized <= 1)
    if len(candidates) < 10:
        candidates = np.flatnonzero(normalized <= 4)
    if len(candidates) == 0:
        candidates = np.arange(len(centers))

    score = sign * centers[candidates, 1] + 8.0 * normalized[candidates]
    index = candidates[np.argmin(score)]
    position = centers[index]
    spread = np.linalg.norm(position[[0, 2]] - local_center[[0, 2]])
    confidence = float(max(0.0, min(0.8, 0.8 * (1 - spread / max(x_radius, z_radius)))))
    return {
        "position": position.tolist(),
        "method": "closed_boundary_medial",
        "confidence": confidence,
        "radius": float(np.sqrt(x_radius * z_radius)),
        "boundary_count": len(boundaries),
    }


def _legacy_caps(loops):
    """Original cap construction: triangulate the boundary loop directly using its 3D coordinates.

    Note that ``shapely.Polygon`` only consumes the first two coordinates, so this
    effectively projects to the XY plane. For typical ear meshes (canal axis ~Y)
    that projection is degenerate, which is why interpolated mode below is usually
    a better choice for predicted ears.
    """
    patches = []
    for loop in loops:
        if len(loop) < 3:
            continue
        polygon = shapely.Polygon(loop)
        if not polygon.is_valid or polygon.area <= 0:
            continue
        _, triangulated_faces = trimesh.creation.triangulate_polygon(polygon, engine='triangle')
        canal = trimesh.Trimesh(vertices=loop, faces=triangulated_faces)
        canal.faces = canal.faces[:, ::-1]
        patches.append(canal)
    return patches


def _interpolated_caps(loops, n_neighbors=5):
    """Project each canal loop onto the XZ plane, triangulate there, and lift the
    new interior vertices back into 3D with an inverse-distance-weighted Y from
    the boundary. Produces a smoother, less self-intersecting cap when the canal
    opening is non-planar.
    """
    patches = []
    for loop in loops:
        if len(loop) < 3:
            continue

        # Push the cap slightly inward (toward the head) rather than outward.
        if np.mean(loop[:, 1]) > 0:
            flat_y = float(np.min(loop[:, 1]))
        else:
            flat_y = float(np.max(loop[:, 1]))

        loop_2d = loop[:, [0, 2]]
        polygon = shapely.Polygon(loop_2d)
        if not polygon.is_valid or polygon.area <= 0:
            polygon = polygon.buffer(0)
        if polygon.is_empty or not polygon.is_valid or polygon.area <= 0:
            continue

        verts_2d, triangulated_faces = trimesh.creation.triangulate_polygon(
            polygon, engine='triangle'
        )
        verts_3d = np.column_stack([
            verts_2d[:, 0],
            np.full(len(verts_2d), flat_y),
            verts_2d[:, 1],
        ])

        k = min(n_neighbors, len(loop))
        for i, vert in enumerate(verts_3d):
            dists = np.linalg.norm(loop_2d - vert[[0, 2]], axis=1)
            nearest = np.argsort(dists)[:k]
            weights = 1.0 / (dists[nearest] + 1e-10)
            weights /= weights.sum()
            verts_3d[i, 1] = float(np.sum(weights * loop[nearest, 1]))

        canal = trimesh.Trimesh(vertices=verts_3d, faces=triangulated_faces)
        canal.faces = canal.faces[:, ::-1]
        patches.append(canal)
    return patches


def ear_canal_closer(ear, mode="legacy"):
    """Close all non-largest boundary loops on ``ear`` with triangulated caps.

    Parameters
    ----------
    ear : trimesh.Trimesh
        Ear mesh, expected to have at least one extra boundary loop besides the
        outer cut where the ear meets the head.
    mode : {"legacy", "interpolated"}
        ``"legacy"`` (default) preserves the original behaviour for reproducibility.
        ``"interpolated"`` projects each canal loop onto the XZ plane, triangulates
        in 2D, and interpolates the cap's Y coordinates from the boundary using
        inverse-distance weighting. The latter is generally more robust on
        non-planar openings such as PPM-predicted ears.
    """
    if mode not in ("legacy", "interpolated"):
        raise ValueError(f"Unknown mode {mode!r}; expected 'legacy' or 'interpolated'.")

    boundaries = _mesh_boundaries(ear)

    if len(boundaries) <= 1:
        print("The ear mesh has one or fewer holes. I assume the ear canal is already closed and skip this step.")
        return ear

    if mode == "legacy":
        patches = _legacy_caps(boundaries[1:])
    else:
        patches = _interpolated_caps(boundaries[1:])

    if not patches:
        return ear

    ear = trimesh.util.concatenate([ear, *patches])
    return ear


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--ear_path', type=str, required=True, help='Path to the ear mesh')
    parser.add_argument('--export_path', type=str, required=True, help='Path to save the closed up ear to')
    parser.add_argument('--landmark_path', type=str, required=False, default=None, help='Path to save the estimated ear canal landmark')
    parser.add_argument('--side', type=str, required=False, default='auto', help='Ear side')
    parser.add_argument('--mode', type=str, required=False, default='legacy',
                        choices=['legacy', 'interpolated'],
                        help='Cap construction mode (see ear_canal_closer docstring). Default: legacy.')
    args = parser.parse_args()

    ear_path = args.ear_path
    export_path = args.export_path

    ear = trimesh.load(ear_path)
    if args.landmark_path:
        with open(args.landmark_path, "w") as f:
            json.dump(estimate_ear_canal_position(ear, side=args.side), f, indent=2)
    ear = ear_canal_closer(ear, mode=args.mode)
    ear.export(export_path)
