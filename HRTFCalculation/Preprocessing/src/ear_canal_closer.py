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


def ear_canal_closer(ear):
    boundaries = _mesh_boundaries(ear)

    if len(boundaries) <= 1:
        print("The ear mesh has one or fewer holes. I assume the ear canal is already closed and skip this step.")
        return ear

    patches = []
    for loop in boundaries[1:]:
        if len(loop) < 3:
            continue
        polygon = shapely.Polygon(loop)
        if not polygon.is_valid or polygon.area <= 0:
            continue
        _, triangulated_faces = trimesh.creation.triangulate_polygon(polygon, engine='triangle')
        canal = trimesh.Trimesh(vertices=loop, faces=triangulated_faces)
        canal.faces = canal.faces[:, ::-1]
        patches.append(canal)

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
    args = parser.parse_args()

    ear_path = args.ear_path
    export_path = args.export_path

    ear = trimesh.load(ear_path)
    if args.landmark_path:
        with open(args.landmark_path, "w") as f:
            json.dump(estimate_ear_canal_position(ear, side=args.side), f, indent=2)
    ear = ear_canal_closer(ear)
    ear.export(export_path)
