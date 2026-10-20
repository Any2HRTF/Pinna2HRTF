"""Ear-distance measurement and placement, shared by native apps and preprocessing."""
from __future__ import annotations
import argparse
import json
import math
import numpy as np
import trimesh


def boundary(ear):
    entities = ear.outline().entities
    if entities is None or len(entities) == 0:
        raise ValueError("The ear mesh has no attachment boundary. Check the input mesh.")
    return max((entity.discrete(ear.vertices) for entity in entities), key=len)


def boundary_y(ear):
    return float(np.mean(boundary(ear), axis=0)[1])


def positive(value, name="Ear distance", allow_zero=False):
    value = float(value)
    if not math.isfinite(value) or value < 0 or (value == 0 and not allow_zero):
        raise ValueError(f"{name} must be finite and {'nonnegative' if allow_zero else 'positive'}, in millimetres.")
    return value


def resolve_geometry(ears, settings, validate=True):
    centers = {side: boundary_y(ear) for side, ear in ears.items() if ear is not None}
    if not centers:
        raise ValueError("Load at least one ear mesh to calculate its distance.")
    distances = {side: abs(center) for side, center in centers.items()}
    mean = float(np.mean(list(distances.values())))
    target = settings.ear_distance
    delta = 0. if target is None else positive(target) - mean
    translations = {}
    for side, center in centers.items():
        distance = distances[side] + delta
        positive(distance, f"{side.title()} ear distance", allow_zero=True)
        distances[side] = distance
        translations[side] = (0., 0. if target is None else (1 if side == "left" else -1) * distance - center, 0.)
    mean = float(np.mean(list(distances.values())))
    if validate:
        positive(mean)
    return {"ear_distance_left": distances.get("left"), "ear_distance_right": distances.get("right"),
            "ear_distance": mean, "translations": translations}


def needs_distance_warning(distance):
    return distance <= 50.


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config")
    parser.add_argument("--left")
    parser.add_argument("--right")
    args = parser.parse_args()
    from .Config import PreprocessingConfig, load_config
    if args.config:
        from .RunConfig import preprocessing_input_paths
        config = load_config(args.config)
        left, right = preprocessing_input_paths(config, lambda _: None)
        settings = config.preprocessing
    else:
        left, right, settings = args.left, args.right, PreprocessingConfig()
    ears = {"left": trimesh.load(left) if left else None, "right": trimesh.load(right) if right else None}
    print(json.dumps(resolve_geometry(ears, settings, validate=False), allow_nan=False))


if __name__ == "__main__":
    main()
