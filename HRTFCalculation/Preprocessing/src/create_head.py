import argparse
import numpy as np
import trimesh
from HRTFCalculation.LiveEvents import emit_live_event


def head(left_ear, right_ear, export_path, radius_scale=1.01, width_scale=1.39, height_scale=1.5, taper_percent=0.0, subdivisions=7):
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
        emit_live_event("Left and right ear sizes differ substantially", level="warning")
        print("Warning: left and right ear radius are quite asymmetrical.")
    radius = np.mean(list(radii.values())) * radius_scale
    print(f"radius: {radius:.2f}")
    print(f"head scale x/y/z: {width_scale:.3f}/1.000/{height_scale:.3f}")
    dummy_head = trimesh.creation.icosphere(subdivisions, radius)

    if not np.isfinite(taper_percent):
        raise ValueError("Head taper must be a finite percentage.")
    if taper_percent != 0:
        width_factors = 1 + dummy_head.vertices[:, 2] * taper_percent / 10000
        if np.any(width_factors <= 0):
            raise ValueError("Head taper would collapse or invert the head. Reduce its strength or the head radius.")
        dummy_head.vertices[:, 1] *= width_factors

    dummy_head.apply_scale((width_scale, 1, height_scale))

    dummy_head.export(export_path)
    return radius


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Load ears.")

    parser.add_argument('--left_path', type=str, help='Path to the left ear mesh')
    parser.add_argument('--right_path', type=str, help='Path to the right ear mesh')
    parser.add_argument('--export_path', type=str, required=True, help='Export path for the head mesh')

    parser.add_argument('--radius-scale', type=float, default=1.01)
    parser.add_argument('--width-scale', type=float, default=1.39, help='Front-to-back scale relative to the ear-to-ear radius.')
    parser.add_argument('--height-scale', type=float, default=1.5)
    parser.add_argument('--taper-percent', type=float, default=0.0, help='Head taper strength: +100 equals +0.01 per mm; positive widens above the ear axis.')
    args = parser.parse_args()

    if not args.left_path and not args.right_path:
        parser.error('At least one ear mesh path is required')
    left_ear = trimesh.load(args.left_path, force="mesh") if args.left_path else None
    right_ear = trimesh.load(args.right_path, force="mesh") if args.right_path else None
    export_path = args.export_path

    radius = head(left_ear, right_ear, export_path, radius_scale=args.radius_scale, width_scale=args.width_scale, height_scale=args.height_scale, taper_percent=args.taper_percent)
