"""PyTorch-free decoding of the shipped 188-output PPM head."""

import csv
from pathlib import Path

import numpy as np


def groups(csv_path):
    with Path(csv_path).open() as file:
        names = [row[0] for row in csv.reader(file)]
    return tuple(
        [name for name in names if group in name and "Parent" not in name]
        for group in ("Location", "Rotation", "Scale", "Shape")
    )


def rotation_matrix(poses):
    def normalize(values):
        magnitude = np.sqrt(np.sum(values * values, axis=-1, keepdims=True))
        return values / np.maximum(magnitude, np.float32(1e-8))

    x = normalize(poses[..., 0:3])
    z = normalize(np.cross(x, poses[..., 3:6]))
    y = np.cross(z, x)
    return np.stack((x, y, z), axis=-1)


def quaternion(matrix):
    r00, r11, r22 = matrix[..., 0, 0], matrix[..., 1, 1], matrix[..., 2, 2]
    trace = r00 + r11 + r22
    pivot = np.argmax(np.stack((trace, r00, r11, r22), axis=-1), axis=-1)
    from_w = np.stack((1 + trace, matrix[..., 2, 1] - matrix[..., 1, 2],
                       matrix[..., 0, 2] - matrix[..., 2, 0], matrix[..., 1, 0] - matrix[..., 0, 1]), axis=-1)
    from_x = np.stack((matrix[..., 2, 1] - matrix[..., 1, 2], 1 + r00 - r11 - r22,
                       matrix[..., 0, 1] + matrix[..., 1, 0], matrix[..., 0, 2] + matrix[..., 2, 0]), axis=-1)
    from_y = np.stack((matrix[..., 0, 2] - matrix[..., 2, 0], matrix[..., 0, 1] + matrix[..., 1, 0],
                       1 - r00 + r11 - r22, matrix[..., 1, 2] + matrix[..., 2, 1]), axis=-1)
    from_z = np.stack((matrix[..., 1, 0] - matrix[..., 0, 1], matrix[..., 0, 2] + matrix[..., 2, 0],
                       matrix[..., 1, 2] + matrix[..., 2, 1], 1 - r00 - r11 + r22), axis=-1)
    rows = np.stack((from_w, from_x, from_y, from_z), axis=-2)
    chosen = np.take_along_axis(rows, pivot[..., None, None], axis=-2)[..., 0, :]
    denominator = np.take_along_axis(chosen, pivot[..., None], axis=-1)
    result = chosen / (2 * np.sqrt(denominator))
    return np.where(result[..., :1] < 0, -result, result)


def decode(raw, csv_path):
    locations, rotations, scales, shapes = groups(csv_path)
    raw = np.asarray(raw, dtype=np.float32).reshape(1, -1)
    location_end = len(locations)
    scale_end = location_end + len(scales)
    shape_end = scale_end + len(shapes)
    rotations_raw = raw[:, shape_end:].reshape(1, -1, 6)
    quaternions = quaternion(rotation_matrix(rotations_raw)).reshape(-1)
    result = {name: float(value) / 1000 for name, value in zip(locations, raw[0, :location_end])}
    result.update({name: float(value) for name, value in zip(rotations, quaternions)})
    result.update({name: float(value) for name, value in zip(scales, raw[0, location_end:scale_end])})
    result.update({name: float(value) for name, value in zip(shapes, raw[0, scale_end:shape_end])})
    return result
