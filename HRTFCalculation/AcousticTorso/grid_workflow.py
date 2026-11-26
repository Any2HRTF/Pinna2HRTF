from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

import numpy as np
from scipy.spatial import ConvexHull, cKDTree

from .torso_reflection_model import algazi_reflection
from .sofa_subset import _copy_subset


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _unit(xyz: np.ndarray) -> np.ndarray:
    return xyz / np.linalg.norm(xyz, axis=-1, keepdims=True)


def _sofa_angles(xyz: np.ndarray) -> tuple[float, float]:
    return (float(np.rad2deg(np.arctan2(xyz[1], xyz[0])) % 360.0),
            float(np.rad2deg(np.arctan2(xyz[2], np.hypot(xyz[0], xyz[1])))))


def _query_directions(original_unit: np.ndarray,
                      min_source_elevation_deg: float | None) -> np.ndarray:
    queries = []
    for xyz in original_unit:
        az_sofa, elevation = _sofa_angles(xyz)
        if (min_source_elevation_deg is not None
                and elevation < min_source_elevation_deg):
            continue
        for ear in ("left", "right"):
            estimate = algazi_reflection(-az_sofa, elevation, ear=ear)
            if estimate.has_reflection and estimate.delay_ms > 0:
                direction = estimate.direction_xyz
                assert direction is not None
                queries.append([direction[1], -direction[0], direction[2]])
    return np.asarray(queries, dtype=float).reshape(-1, 3)


def _angular_gaps(queries: np.ndarray, grid: np.ndarray) -> np.ndarray:
    if len(queries) == 0:
        return np.empty(0)
    chord, _ = cKDTree(grid).query(queries)
    return np.rad2deg(2.0 * np.arcsin(np.clip(chord / 2.0, 0.0, 1.0)))


def _is_left_right_symmetric(directions: np.ndarray,
                             tolerance_deg: float = 0.05) -> bool:

    reflected = directions.copy()
    reflected[:, 1] *= -1.0
    return bool(np.all(_angular_gaps(reflected, directions) <= tolerance_deg))


def _reference_coverage(original: np.ndarray, hard_cap_deg: float,
                        azimuth_samples: int = 360,
                        sinelevation_samples: int = 240) -> dict:

    elevations = np.rad2deg(np.arcsin(np.clip(original[:, 2], -1, 1)))
    low, high = float(np.min(elevations)), float(np.max(elevations))
    az = np.deg2rad(-90 + (np.arange(azimuth_samples) + 0.5)
                    * 180 / azimuth_samples)
    zlow, zhigh = np.sin(np.deg2rad([low, high]))
    if zhigh - zlow < 1e-8:
        return {"elevation_min_deg": low, "elevation_max_deg": high,
                "azimuth_min_deg": -90.0, "azimuth_max_deg": 90.0,
                "median_gap_deg": None, "p95_gap_deg": None,
                "target_gap_deg": hard_cap_deg, "sample_count": 0,
                "sampling": "degenerate elevation span; used hard cap"}
    z = zlow + (np.arange(sinelevation_samples) + 0.5) * (
        zhigh - zlow) / sinelevation_samples
    az_grid, z_grid = np.meshgrid(az, z)
    horizontal = np.sqrt(np.maximum(0.0, 1 - z_grid**2))
    samples = np.column_stack((horizontal.ravel() * np.cos(az_grid).ravel(),
                               horizontal.ravel() * np.sin(az_grid).ravel(),
                               z_grid.ravel()))
    gaps = _angular_gaps(samples, original)
    median, p95 = np.percentile(gaps, [50, 95])
    return {"elevation_min_deg": low, "elevation_max_deg": high,
            "azimuth_min_deg": -90.0, "azimuth_max_deg": 90.0,
            "median_gap_deg": float(median), "p95_gap_deg": float(p95),
            "target_gap_deg": float(min(hard_cap_deg, p95)),
            "sample_count": len(samples),
            "sampling": "midpoints uniform in azimuth and sin(elevation)"}


def _equal_area_cells(upper_elevation_deg: float, target_gap_deg: float
                      ) -> tuple[np.ndarray, np.ndarray, np.ndarray, np.ndarray]:


    zmax = float(np.sin(np.deg2rad(upper_elevation_deg)))
    span = upper_elevation_deg + 90.0
    rings = max(2, int(np.ceil(span / (target_gap_deg / 2))))
    target_half = target_gap_deg / 2
    for _ in range(100):
        provisional_step = np.deg2rad(span / rings)
        counts = [1]
        for i in range(1, rings):
            mid_el = -90 + (i + 0.5) * span / rings
            count = max(2, 2 * int(np.round(
                np.pi * np.cos(np.deg2rad(mid_el)) / provisional_step)))
            counts.append(count)
        if sum(counts) > 50000:
            raise ValueError("Adaptive grid requires over 50,000 equal-area "
                             "candidate cells; loosen the hard cap")
        offsets = np.concatenate(([0], np.cumsum(counts)))
        z_edges = -1 + (zmax + 1) * offsets / offsets[-1]
        centers: list[np.ndarray] = []
        radii: list[np.ndarray] = []
        for i, count in enumerate(counts):
            z0, z1 = z_edges[i:i+2]
            if i == 0:
                centers.append(np.array([[0.0, 0.0, -1.0]]))
                radii.append(np.array([np.rad2deg(np.arccos(-z1))]))
                continue
            zmid = (z0 + z1) / 2
            az = -np.pi + (np.arange(count) + 0.5) * 2*np.pi/count
            horizontal = np.sqrt(1 - zmid*zmid)
            centers.append(np.column_stack((horizontal*np.cos(az),
                                            horizontal*np.sin(az),
                                            np.full(count, zmid))))
            corner_cos = [zmid*ze + horizontal*np.sqrt(max(0, 1-ze*ze))
                          * np.cos(np.pi/count) for ze in (z0, z1)]
            radius = np.rad2deg(np.arccos(np.clip(min(corner_cos), -1, 1)))
            radii.append(np.full(count, radius))
        cell_centers = np.vstack(centers)
        cell_radii = np.concatenate(radii)
        if np.max(cell_radii) <= target_half + 1e-10:
            return cell_centers, cell_radii, z_edges, np.asarray(counts)
        rings = int(np.ceil(rings * 1.15)) + 1
    raise ArithmeticError("Unable to construct suitably small equal-area cells")


def _select_candidate_centres(targets: np.ndarray, allowances_deg: np.ndarray,
                              original: np.ndarray, candidates: np.ndarray,
                              use_symmetry: bool) -> np.ndarray:

    uncovered = _angular_gaps(targets, original) > allowances_deg + 1e-9
    if not np.any(uncovered):
        return np.empty((0, 3))
    tree = cKDTree(targets)
    chord = 2*np.sin(np.deg2rad(np.max(allowances_deg))/2)
    orbits: list[np.ndarray] = []
    neighborhoods: list[np.ndarray] = []
    for candidate in candidates:
        if use_symmetry and candidate[1] < -1e-10:
            continue
        if use_symmetry and candidate[1] > 1e-10:
            mirror = candidate.copy()
            mirror[1] *= -1
            orbit = np.vstack((candidate, mirror))
        else:
            orbit = candidate.reshape(1, 3)
        covered: set[int] = set()
        for point in orbit:
            nearby = tree.query_ball_point(point, chord)
            if nearby:
                nearby = np.asarray(nearby, dtype=int)
                angles = np.rad2deg(np.arccos(np.clip(targets[nearby] @ point,
                                                      -1, 1)))
                covered.update(nearby[angles <= allowances_deg[nearby] + 1e-9])
        if covered:
            orbits.append(orbit)
            neighborhoods.append(np.asarray(sorted(covered), dtype=int))
    reverse: list[list[int]] = [[] for _ in range(len(targets))]
    scores = np.empty(len(orbits), dtype=int)
    costs = np.asarray([len(orbit) for orbit in orbits])
    for i, neighborhood in enumerate(neighborhoods):
        scores[i] = np.count_nonzero(uncovered[neighborhood])
        for j in neighborhood:
            reverse[j].append(i)
    selected: list[np.ndarray] = []
    while np.any(uncovered):
        index = int(np.argmax(scores / costs))
        if scores[index] <= 0:
            raise ArithmeticError("Equal-area candidates cannot cover reflection queries")
        selected.append(orbits[index])
        new = neighborhoods[index][uncovered[neighborhoods[index]]]
        uncovered[new] = False
        for j in new:
            scores[reverse[j]] -= 1
    return np.vstack(selected)


def extend_grid(
    source_grid: str | Path,
    output_grid: str | Path,
    *,
    min_source_elevation_deg: float | None = None,
    max_angular_gap_deg: float = 12.0,
    symmetry: str = "auto",
) -> dict:

    source_grid = Path(source_grid).expanduser().resolve(strict=True)
    output_grid = Path(output_grid).expanduser().resolve()
    if output_grid.exists():
        raise FileExistsError(output_grid)
    if not 0 < max_angular_gap_deg < 90:
        raise ValueError("max_angular_gap_deg must be in (0, 90)")
    if symmetry not in ("auto", "require", "off"):
        raise ValueError("symmetry must be 'auto', 'require', or 'off'")
    if (min_source_elevation_deg is not None
            and not -90 <= min_source_elevation_deg <= 90):
        raise ValueError("min_source_elevation_deg must be in [-90,90]")
    nodes_path = source_grid / "Nodes.txt"
    elements_path = source_grid / "Elements.txt"
    original = np.loadtxt(nodes_path, skiprows=1, ndmin=2)
    if (original.shape[1] != 4 or not np.all(np.isfinite(original))
            or int(nodes_path.read_text(encoding="utf-8").splitlines()[0]) != len(original)):
        raise ValueError("Invalid Nodes.txt")
    ids = original[:, 0].astype(np.int64)
    if not np.all(original[:, 0] == ids) or len(np.unique(ids)) != len(ids):
        raise ValueError("Node IDs must be unique integers")
    xyz = original[:, 1:4]
    radii = np.linalg.norm(xyz, axis=1)
    if (np.any(radii <= 0)
            or not np.allclose(radii, radii[0], rtol=0, atol=1e-6)):
        raise ValueError("Evaluation grid must have one spherical radius")
    directions = _unit(xyz)
    original_is_symmetric = _is_left_right_symmetric(directions)
    if symmetry == "require" and not original_is_symmetric:
        raise ValueError("Original grid lacks left/right mirror symmetry")
    use_symmetry = symmetry == "require" or (symmetry == "auto" and original_is_symmetric)
    coverage_reference = _reference_coverage(directions, max_angular_gap_deg)
    target_gap_deg = coverage_reference["target_gap_deg"]
    if not 0 < target_gap_deg <= max_angular_gap_deg:
        raise ValueError("Invalid adaptive angular target")
    queries = _query_directions(directions, min_source_elevation_deg)
    initial_gaps = _angular_gaps(queries, directions)
    if len(queries):
        query_elevations = np.rad2deg(np.arcsin(np.clip(queries[:, 2], -1, 1)))
        upper_elevation = min(0.0, float(np.max(query_elevations) + target_gap_deg))
        centers, cell_radii, _, _ = _equal_area_cells(
            upper_elevation, target_gap_deg)


        additions = _select_candidate_centres(
            queries, np.full(len(queries), target_gap_deg),
            directions, centers, use_symmetry)
    else:
        centers = np.empty((0, 3))
        cell_radii = np.empty(0)
        additions = np.empty((0, 3))
    augmented = np.vstack((directions, additions))
    final_gaps = _angular_gaps(queries, augmented)
    if len(final_gaps) and np.max(final_gaps) > target_gap_deg + 1e-7:
        raise ArithmeticError("Extended grid fails its coverage criterion")
    added_ids = np.arange(ids.max() + 1, ids.max() + 1 + len(additions),
                          dtype=np.int64)
    all_ids = np.concatenate((ids, added_ids))


    hull = ConvexHull(augmented) if len(additions) else None
    if hull is not None and len(hull.vertices) != len(augmented):
        raise ValueError("Cannot form a spherical evaluation mesh")
    element_data = np.loadtxt(elements_path, skiprows=1, ndmin=2)
    if element_data.shape[1] < 4:
        raise ValueError("Invalid Elements.txt")
    next_element_id = int(np.max(element_data[:, 0])) + 1

    output_grid.mkdir(parents=True)
    try:
        if len(additions) == 0:
            shutil.copy2(nodes_path, output_grid / "Nodes.txt")
            shutil.copy2(elements_path, output_grid / "Elements.txt")
        else:
            with (output_grid / "Nodes.txt").open("w", encoding="utf-8", newline="\n") as file:
                file.write(f"{len(augmented)}\n")
                for row in original:
                    file.write(f"{int(row[0])} {row[1]:.17g} {row[2]:.17g} {row[3]:.17g}\n")
                for node_id, direction in zip(added_ids, additions):
                    point = direction * radii[0]
                    file.write(f"{node_id} {point[0]:.17g} {point[1]:.17g} {point[2]:.17g}\n")
            with (output_grid / "Elements.txt").open("w", encoding="utf-8", newline="\n") as file:
                file.write(f"{len(hull.simplices)}\n")
                for number, triangle in enumerate(hull.simplices, next_element_id):
                    vertices = augmented[triangle]
                    normal = np.cross(vertices[1] - vertices[0], vertices[2] - vertices[0])
                    if np.dot(normal, vertices.mean(axis=0)) < 0:
                        triangle = triangle[[0, 2, 1]]
                    v = all_ids[triangle]
                    file.write(f"{number} {v[0]} {v[1]} {v[2]} 2 0 1\n")
        manifest = {
            "format": "acoustic-torso-grid-v3",
            "source_nodes_sha256": _sha256(nodes_path),
            "augmented_nodes_sha256": _sha256(output_grid / "Nodes.txt"),
            "radius_m": float(radii[0]),
            "original_node_ids": ids.tolist(),
            "original_unit_xyz_sofa": directions.tolist(),
            "added_node_ids": added_ids.tolist(),
            "added_unit_xyz_sofa": additions.tolist(),
            "model": "Algazi 2002 Appendix A",
            "min_source_elevation_deg": min_source_elevation_deg,
            "max_angular_gap_deg": max_angular_gap_deg,
            "target_angular_gap_deg": target_gap_deg,
            "coverage_reference": coverage_reference,
            "partition": {
                "method": "equal-area zonal candidate positions",
                "candidate_cell_count": len(centers),
                "max_cell_radius_deg": float(np.max(cell_radii)) if len(cell_radii) else 0.0,
                "coverage_requirement": "reflection_queries_only",
            },
            "left_right_symmetric_original": original_is_symmetric,
            "left_right_symmetric_extension": use_symmetry,
            "query_count": len(queries),
            "initial_max_gap_deg": float(np.max(initial_gaps)) if len(queries) else 0.0,
            "initial_uncovered_count": int(np.count_nonzero(initial_gaps > target_gap_deg)),
            "final_max_gap_deg": float(np.max(final_gaps)) if len(queries) else 0.0,
        }
        (output_grid / "torso_grid_manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    except BaseException:
        shutil.rmtree(output_grid)
        raise
    return manifest


def trim_to_original_grid(
    sofa_path: str | Path,
    augmented_grid: str | Path,
    *,
    angular_tolerance_deg: float = 0.05,
    radius_tolerance_m: float = 0.001,
    overwrite: bool = False,
) -> Path:

    from netCDF4 import Dataset

    sofa_path = Path(sofa_path).expanduser().resolve(strict=True)
    augmented_grid = Path(augmented_grid).expanduser().resolve(strict=True)
    manifest = json.loads((augmented_grid / "torso_grid_manifest.json").read_text(
        encoding="utf-8"))
    if manifest.get("format") not in ("acoustic-torso-grid-v1",
                                      "acoustic-torso-grid-v2",
                                      "acoustic-torso-grid-v3"):
        raise ValueError("Unsupported grid manifest")
    if _sha256(augmented_grid / "Nodes.txt") != manifest["augmented_nodes_sha256"]:
        raise ValueError("Augmented grid no longer matches its manifest")
    original = np.asarray(manifest["original_unit_xyz_sofa"], dtype=float)
    added = np.asarray(manifest["added_unit_xyz_sofa"], dtype=float).reshape(-1, 3)
    expected = np.vstack((original, added))
    output = sofa_path.with_name(sofa_path.stem + "_original.sofa")
    if output.exists() and not overwrite:
        raise FileExistsError(output)
    with Dataset(sofa_path, "r") as source:
        if source.data_model != "NETCDF4" or "M" not in source.dimensions:
            raise ValueError("Expected NetCDF4 SOFA with M dimension")
        if len(source.dimensions["M"]) != len(expected):
            raise ValueError("SOFA M count differs from augmented grid")
        posvar = source.variables["SourcePosition"]
        if (posvar.dimensions != ("M", "C")
                or str(posvar.getncattr("Type")).lower() != "spherical"):
            raise ValueError("Expected spherical SourcePosition(M,C)")
        units = str(posvar.getncattr("Units")).lower()
        if "degree" not in units or not any(x in units for x in ("metre", "meter")):
            raise ValueError("Expected SourcePosition units in degrees and metres")
        positions = np.asarray(posvar[:], dtype=float)
        if positions.shape != (len(expected), 3) or not np.all(np.isfinite(positions)):
            raise ValueError("Invalid source positions")
        if np.max(np.abs(positions[:, 2] - manifest["radius_m"])) > radius_tolerance_m:
            raise ValueError("SOFA radius does not match grid manifest")
        az, el = np.deg2rad(positions[:, 0]), np.deg2rad(positions[:, 1])
        actual = np.column_stack((np.cos(el) * np.cos(az),
                                  np.cos(el) * np.sin(az), np.sin(el)))
        distances, indices = cKDTree(actual).query(expected)
        errors = np.rad2deg(2 * np.arcsin(np.clip(distances / 2, 0, 1)))
        if np.max(errors) > angular_tolerance_deg or len(np.unique(indices)) != len(expected):
            raise ValueError("SOFA directions do not match augmented grid")
        history = (f"{datetime.now(timezone.utc).isoformat()}: Retained "
                   f"{len(original)} original grid positions in manifest order; "
                   f"removed {len(added)} torso-lookup positions. "
                   f"Augmented Nodes.txt SHA-256 {manifest['augmented_nodes_sha256']}.")
        with tempfile.NamedTemporaryFile(prefix=output.stem + ".", suffix=".sofa",
                                         dir=output.parent, delete=False) as tmp:
            temporary = Path(tmp.name)
        try:
            _copy_subset(source, temporary, indices[:len(original)], history)
            if output.exists() and not overwrite:
                raise FileExistsError(output)
            os.replace(temporary, output)
        finally:
            temporary.unlink(missing_ok=True)
    return output
