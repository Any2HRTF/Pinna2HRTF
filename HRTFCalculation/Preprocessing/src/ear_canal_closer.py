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
import trimesh
import shapely


def ear_canal_closer(ear):
    boundaries = [bound.discrete(ear.vertices) for bound in ear.outline().entities]
    boundaries = sorted(boundaries, key=len, reverse=True)

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
    args = parser.parse_args()

    ear_path = args.ear_path
    export_path = args.export_path

    ear = trimesh.load(ear_path)
    ear = ear_canal_closer(ear)
    ear.export(export_path)
