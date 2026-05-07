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


def head(left_ear, right_ear, export_path, radius_scale=1.01, width_scale=1.5, height_scale=1.5, y_deformation=0.0, adaptive_ovalness=True, ovalness_strength=0.08, min_width_scale=1.48, max_height_scale=1.53):

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

    radius = np.mean([left_radius, right_radius]) * radius_scale
    if adaptive_ovalness:
        left_extent = np.ptp(left_outline, axis=0)
        right_extent = np.ptp(right_outline, axis=0)
        flare = np.mean([left_extent[0] / max(left_extent[2], np.finfo(float).eps), right_extent[0] / max(right_extent[2], np.finfo(float).eps)])
        ovalness = np.clip((flare - 0.45) / 0.55, 0, 1) * ovalness_strength
        width_scale = max(min_width_scale, width_scale - ovalness)
        height_scale = min(max_height_scale, height_scale + ovalness)

    print(f"radius: {radius:.2f}")
    print(f"head scale x/y/z: {width_scale:.3f}/1.000/{height_scale:.3f}")
    dummy_head = trimesh.creation.icosphere(7, radius)

    if y_deformation != 0:
        dummy_head.vertices[:, 1] *= dummy_head.vertices[:, 2] * y_deformation + 1

    dummy_head.apply_scale((width_scale, 1, height_scale))

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
