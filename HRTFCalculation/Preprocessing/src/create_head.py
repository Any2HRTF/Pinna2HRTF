"""
Creates a dummy head mesh aligned to the coordinate axes.
The radius with regards to y is retrieved through the average outline of both ear meshes,
wheres the x and z radius are 1.5 times the y radius.

It takes paths to the left_ear and right_ear stl mesh files
and an export_path (including .stl) where the dummy head mesh will be exported to.
Also, the y radius will be returned.


@author: lthalhammer
September 2024
"""

import argparse
import numpy as np
import trimesh
import pyglet  # necessary for .show to work!


def head(left_ear, right_ear, export_path):

    left_entities = left_ear.outline().entities
    right_entities = right_ear.outline().entities
    if len(left_entities) == 0:
        raise Exception("The left ear mesh has no boundary loop. Check for non-manifolds!")
    if len(right_entities) == 0:
        raise Exception("The right ear mesh has no boundary loop. Check for non-manifolds!")

    left_outline = max(
        (entity.discrete(left_ear.vertices) for entity in left_entities),
        key=len
    )
    right_outline = max(
        (entity.discrete(right_ear.vertices) for entity in right_entities),
        key=len
    )

    left_radius = np.abs(np.mean(left_outline, axis=0)[1])
    right_radius = np.abs(np.mean(right_outline, axis=0)[1])

    if np.abs(left_radius - right_radius) > 4:
        print("Warning: left and right ear radius are quite asymmetrical.")

    radius = np.mean([left_radius, right_radius]) * 1.01

    print(f"radius: {radius:.2f}")
    dummy_head = trimesh.creation.icosphere(7, radius)

    for i, vert in enumerate(dummy_head.vertices):
       a = vert[2] * 0.005 + 1
       dummy_head.vertices[i,1] = a*vert[1]

    dummy_head.apply_scale((1.5, 1, 1.5))

    dummy_head.export(export_path)
    return radius


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Load ears.")

    parser.add_argument('--left_path', type=str, required=True, help='Path to the left ear mesh')
    parser.add_argument('--right_path', type=str, required=True, help='Path to the right ear mesh')
    parser.add_argument('--export_path', type=str, required=True, help='Export path for the head mesh')

    args = parser.parse_args()

    left_ear = trimesh.load(args.left_path)
    right_ear = trimesh.load(args.right_path)
    export_path = args.export_path

    radius = head(left_ear, right_ear, export_path)
