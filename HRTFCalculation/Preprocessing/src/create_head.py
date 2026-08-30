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


def head(left_ear, right_ear, export_path, radius_scale=1.01, width_scale=1.5, height_scale=1.5, y_deformation=0.0, adaptive_ovalness=True, ovalness_strength=0.08, min_width_scale=1.48, max_height_scale=1.53):
    ears = [("left", left_ear), ("right", right_ear)]
    ears = [(side, ear) for side, ear in ears if ear is not None]
    if not ears:
        raise ValueError("At least one ear mesh is required")
    outlines = {}
    for side, ear in ears:
        entities = ear.outline().entities
        if len(entities) == 0:
            raise Exception(f"The {side} ear mesh has no boundary loop. Check for non-manifolds!")
        outlines[side] = max((entity.discrete(ear.vertices) for entity in entities), key=len)
    radii = {side: np.abs(np.mean(outline, axis=0)[1]) for side, outline in outlines.items()}
    if len(radii) == 2 and np.abs(radii["left"] - radii["right"]) > 4:
        print("Warning: left and right ear radius are quite asymmetrical.")
    radius = np.mean(list(radii.values())) * radius_scale
    if adaptive_ovalness:
        extents = [np.ptp(outline, axis=0) for outline in outlines.values()]
        flare = np.mean([extent[0] / max(extent[2], np.finfo(float).eps) for extent in extents])
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

    parser.add_argument('--left_path', type=str, help='Path to the left ear mesh')
    parser.add_argument('--right_path', type=str, help='Path to the right ear mesh')
    parser.add_argument('--export_path', type=str, required=True, help='Export path for the head mesh')

    args = parser.parse_args()

    if not args.left_path and not args.right_path:
        parser.error('At least one ear mesh path is required')
    left_ear = trimesh.load(args.left_path) if args.left_path else None
    right_ear = trimesh.load(args.right_path) if args.right_path else None
    export_path = args.export_path

    radius = head(left_ear, right_ear, export_path)
