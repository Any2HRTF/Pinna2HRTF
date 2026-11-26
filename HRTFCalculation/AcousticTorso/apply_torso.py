from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import tempfile

import numpy as np
from scipy.fft import irfft, next_fast_len, rfft, rfftfreq
from scipy.signal import lfilter
from scipy.spatial import cKDTree

from .torso_reflection_model import (
    ALG, C, AlgaziGeometry, estimate_torso_reflection, source_unit,
)


def torso_shadow_filter_coefficients(
    azimuth_deg: float,
    elevation_deg: float,
    ear: str,
    sample_rate_hz: float,
    geom: AlgaziGeometry = ALG,
    alpha_min: float = 0.1,
    theta_min_deg: float = 150.0,
) -> tuple[np.ndarray, np.ndarray] | None:


    if ear not in ("left", "right"):
        raise ValueError("ear must be left or right")
    if not np.isfinite(sample_rate_hz) or sample_rate_hz <= 0:
        raise ValueError("sample_rate_hz must be positive and finite")
    if not 0 < alpha_min < 1 or not 0 < theta_min_deg <= 180:
        raise ValueError("invalid shadow filter parameters")
    side = 1.0 if ear == "right" else -1.0
    dvec = np.array([side * geom.a, 0.0, geom.b + geom.h + geom.a])
    d = float(np.linalg.norm(dvec))
    s = source_unit(azimuth_deg, elevation_deg)
    cos_zeta = float(np.clip(np.dot(dvec, s) / d, -1.0, 1.0))
    cos_grazing = -np.sqrt(d * d - geom.b * geom.b) / d
    if cos_zeta >= cos_grazing:
        return None

    zeta = float(np.arccos(cos_zeta))
    zeta_min = float(np.arccos(cos_grazing))
    theta_min = np.deg2rad(theta_min_deg)
    theta_flat = theta_min * (0.5 + np.arcsin(
        alpha_min / (2.0 - alpha_min)) / np.pi)
    theta_t = ((np.pi * (zeta - zeta_min)
                - theta_flat * (zeta - np.pi)) / (np.pi - zeta_min))
    alpha = (1.0 + alpha_min / 2.0
             + (1.0 - alpha_min / 2.0)
             * np.cos(np.pi * theta_t / theta_min))
    tau = 2.0 * geom.b / C
    k = 2.0 * sample_rate_hz * tau
    b = np.array([(1.0 + alpha * k) / (1.0 + k),
                  (1.0 - alpha * k) / (1.0 + k)])
    a = np.array([1.0, (1.0 - k) / (1.0 + k)])
    return b, a


def _text(value: object) -> str:
    if isinstance(value, bytes):
        return value.decode("utf-8")
    return str(value)


def _unit_directions(azimuth_deg: np.ndarray,
                     elevation_deg: np.ndarray) -> np.ndarray:

    az = np.deg2rad(azimuth_deg)
    el = np.deg2rad(elevation_deg)
    return np.column_stack((np.cos(el) * np.cos(az),
                            np.cos(el) * np.sin(az), np.sin(el)))


def _constant_three_vector(variable: object, label: str,
                           expected: np.ndarray) -> None:
    values = np.asarray(variable[:], dtype=float).reshape(-1, 3)
    if not np.allclose(values, expected, atol=1e-8, rtol=0):
        raise ValueError(f"{label} must be the standard fixed SOFA vector "
                         f"{expected.tolist()}; rotated/translated listeners "
                         "are not supported")


def _receiver_ears(variable: object, receiver_count: int) -> list[str]:
    if _text(variable.getncattr("Type")).lower() != "cartesian":
        raise ValueError("ReceiverPosition must be Cartesian")
    positions = np.asarray(variable[:], dtype=float)
    if positions.ndim == 3 and positions.shape[-1] == 1:
        positions = positions[..., 0]
    if positions.shape != (receiver_count, 3) or receiver_count not in (1, 2) or not np.all(np.isfinite(positions)):
        raise ValueError("Expected one or two fixed Cartesian receiver positions")
    if np.any(np.abs(positions[:, 1]) < 1e-6) or (receiver_count == 2 and positions[0, 1] * positions[1, 1] >= 0):
        raise ValueError("Cannot identify one left and one right receiver from their SOFA y coordinates")
    return ["left" if y > 0 else "right" for y in positions[:, 1]]


def _fractional_shift(hrir: np.ndarray, shift_samples: float,
                      output_length: int) -> np.ndarray:

    nfft = next_fast_len(output_length + hrir.size
                         + int(np.ceil(abs(shift_samples))) + 64)
    bins = rfftfreq(nfft)
    phase = np.exp(-2j * np.pi * bins * shift_samples)
    return irfft(rfft(hrir, nfft) * phase, nfft)[:output_length]


def _copy_sofa_with_ir(source: object, destination_path: Path,
                       output_ir: np.ndarray, history_line: str) -> None:

    from netCDF4 import Dataset

    with Dataset(destination_path, "w", format=source.data_model) as dest:
        dest.setncatts({name: source.getncattr(name)
                        for name in source.ncattrs()})
        dest.setncattr("Pinna2HRTF_TorsoModel", "acoustic")
        previous = _text(source.getncattr("History")) if "History" in source.ncattrs() else ""
        dest.setncattr("History", (previous + "\n" + history_line).strip())
        if "DateModified" in source.ncattrs():
            dest.setncattr("DateModified", datetime.now(timezone.utc).isoformat())
        for name, dim in source.dimensions.items():
            length = output_ir.shape[-1] if name == "N" else len(dim)
            dest.createDimension(name, None if dim.isunlimited() else length)
        for name, variable in source.variables.items():
            fill = (variable.getncattr("_FillValue")
                    if "_FillValue" in variable.ncattrs() else None)
            filters = variable.filters()
            kwargs: dict[str, object] = {}
            if fill is not None:
                kwargs["fill_value"] = fill
            if filters and filters.get("zlib"):
                kwargs.update(zlib=True,
                              complevel=int(filters.get("complevel", 4)),
                              shuffle=bool(filters.get("shuffle", True)))
            copied = dest.createVariable(name, variable.datatype,
                                         variable.dimensions, **kwargs)
            copied.setncatts({attr: variable.getncattr(attr)
                              for attr in variable.ncattrs()
                              if attr != "_FillValue"})
            copied[:] = output_ir if name == "Data.IR" else variable[:]


def add_torso_reflection_to_sofa(
    sofa_path: str | Path,
    *,
    g_t: float = 1 / 3,
    min_source_elevation_deg: float | None = None,
    max_angular_distance_deg: float | None = None,
    interpolation: str = "aligned_idw",
    missing_policy: str = "error",
    delay_model: str = "algazi",
    model_source_distance_m: float = 100.0,
    apply_shadow: bool = True,
    normalize_reflection_mix: bool = True,
    augmented_grid: str | Path | None = None,
    overwrite: bool = False,
) -> Path:


    try:
        from netCDF4 import Dataset
    except ImportError as exc:
        raise ImportError("SOFA writing requires netCDF4: pip install netCDF4") from exc

    source_path = Path(sofa_path).expanduser().resolve(strict=True)
    if source_path.suffix.lower() != ".sofa":
        raise ValueError("Input must be a .sofa file")
    if source_path.stem.endswith("_acTorso"):
        raise ValueError("Input already ends with _acTorso; refusing to add the echo twice")
    output_path = source_path.with_name(source_path.stem + "_acTorso.sofa")
    if output_path.exists() and not overwrite:
        raise FileExistsError(output_path)
    if not np.isfinite(g_t) or g_t < 0:
        raise ValueError("g_t must be finite and nonnegative")
    if (max_angular_distance_deg is not None
            and (not np.isfinite(max_angular_distance_deg)
                 or not 0 < max_angular_distance_deg <= 180)):
        raise ValueError("max_angular_distance_deg must be in (0, 180]")
    if interpolation not in ("nearest", "aligned_idw"):
        raise ValueError("interpolation must be 'nearest' or 'aligned_idw'")
    if missing_policy not in ("error", "skip"):
        raise ValueError("missing_policy must be 'error' or 'skip'")
    if delay_model not in ("algazi", "reijniers"):
        raise ValueError("delay_model must be 'algazi' or 'reijniers'")
    if min_source_elevation_deg is not None and not -90 <= min_source_elevation_deg <= 90:
        raise ValueError("min_source_elevation_deg must lie in [-90, 90] or be None")

    with Dataset(source_path, "r") as source:
        if "Pinna2HRTF_TorsoModel" in source.ncattrs():
            raise ValueError("Input already contains acoustic or geometric torso modelling.")
        if source.data_model != "NETCDF4":
            raise ValueError("Only NetCDF4 SOFA files are supported")
        if _text(source.getncattr("DataType")) != "FIR":
            raise ValueError("This function requires FIR Data.IR; TF SOFA "
                             "files store complex Data.Real/Data.Imag and "
                             "need a separate time-alignment method")
        if _text(source.getncattr("SOFAConventions")) not in (
                "SimpleFreeFieldHRIR", "GeneralFIR"):
            raise ValueError("Supported conventions: SimpleFreeFieldHRIR, GeneralFIR")
        required = ("Data.IR", "Data.SamplingRate", "Data.Delay",
                    "SourcePosition", "ReceiverPosition", "ListenerPosition",
                    "ListenerView")
        if any(name not in source.variables for name in required):
            raise ValueError("Required SOFA variables are missing")
        other_sample_variables = [
            name for name, variable in source.variables.items()
            if name != "Data.IR" and "N" in variable.dimensions]
        if other_sample_variables:
            raise ValueError("Cannot enlarge N while other variables also use "
                             f"it: {other_sample_variables}")
        ir = np.asarray(source.variables["Data.IR"][:], dtype=float)
        if ir.ndim != 3 or ir.shape[1] not in (1, 2) or not np.all(np.isfinite(ir)):
            raise ValueError("Data.IR must be finite real M x R x N data for one or two ears")


        ir.setflags(write=False)
        m_count, r_count, n_count = ir.shape
        fs_values = np.asarray(source.variables["Data.SamplingRate"][:],
                               dtype=float).reshape(-1)
        if fs_values.size == 0 or not np.allclose(fs_values, fs_values[0]) or fs_values[0] <= 0:
            raise ValueError("A single positive Data.SamplingRate is required")
        fs = float(fs_values[0])
        _constant_three_vector(source.variables["ListenerPosition"],
                               "ListenerPosition", np.array([0., 0., 0.]))
        _constant_three_vector(source.variables["ListenerView"],
                               "ListenerView", np.array([1., 0., 0.]))
        if "ListenerUp" in source.variables:
            _constant_three_vector(source.variables["ListenerUp"],
                                   "ListenerUp", np.array([0., 0., 1.]))
        ears = _receiver_ears(source.variables["ReceiverPosition"], r_count)

        source_pos = source.variables["SourcePosition"]
        if _text(source_pos.getncattr("Type")).lower() != "spherical":
            raise ValueError("SourcePosition must be spherical")
        units = _text(source_pos.getncattr("Units")).lower()
        if "degree" not in units or not ("metre" in units or "meter" in units):
            raise ValueError("SourcePosition units must be degrees, degrees, metres")
        positions = np.asarray(source_pos[:], dtype=float)
        if positions.shape != (m_count, 3) or not np.all(np.isfinite(positions)):
            raise ValueError("SourcePosition must be finite M x 3 data")
        if not np.all(positions[:, 2] > 0) or not np.allclose(
                positions[:, 2], positions[0, 2], rtol=0.005, atol=1e-4):
            raise ValueError("A uniform, positive source radius is required")
        unit = _unit_directions(positions[:, 0], positions[:, 1])
        target_indices = np.arange(m_count)
        if augmented_grid is not None:
            grid_dir = Path(augmented_grid).expanduser().resolve(strict=True)
            manifest = json.loads((grid_dir / "torso_grid_manifest.json").read_text(
                encoding="utf-8"))
            if manifest.get("format") not in ("acoustic-torso-grid-v1",
                                              "acoustic-torso-grid-v2",
                                              "acoustic-torso-grid-v3"):
                raise ValueError("Unsupported augmented grid manifest")
            if (hashlib.sha256((grid_dir / "Nodes.txt").read_bytes()).hexdigest()
                    != manifest["augmented_nodes_sha256"]):
                raise ValueError("Augmented grid no longer matches its manifest")
            if np.max(np.abs(positions[:, 2] - manifest["radius_m"])) > 0.001:
                raise ValueError("SOFA radius differs from augmented grid")
            original = np.asarray(manifest["original_unit_xyz_sofa"], dtype=float)
            added = np.asarray(manifest["added_unit_xyz_sofa"], dtype=float).reshape(-1, 3)
            expected = np.vstack((original, added))
            if len(expected) != m_count:
                raise ValueError("SOFA M count differs from augmented grid")
            chord, order = cKDTree(unit).query(expected)
            errors = np.rad2deg(2 * np.arcsin(np.clip(chord / 2, 0, 1)))
            if np.max(errors) > 0.05 or len(np.unique(order)) != m_count:
                raise ValueError("SOFA directions do not match augmented grid")
            target_indices = order[:len(original)]
            manifest_cutoff = manifest["min_source_elevation_deg"]
            if min_source_elevation_deg is None:
                min_source_elevation_deg = manifest_cutoff
            elif min_source_elevation_deg != manifest_cutoff:
                raise ValueError("Source-elevation cutoff differs from grid manifest")
            manifest_gap = manifest.get("target_angular_gap_deg",
                                        manifest["max_angular_gap_deg"])
            if max_angular_distance_deg is None:
                max_angular_distance_deg = manifest_gap
            elif max_angular_distance_deg > manifest_gap + 1e-7:
                raise ValueError("Lookup limit exceeds the grid manifest's "
                                 "adaptive angular target")
        if max_angular_distance_deg is None:
            max_angular_distance_deg = 12.0
        tree = cKDTree(unit)
        peaks = np.argmax(np.abs(ir), axis=2)
        tasks: list[tuple[int, int, np.ndarray, np.ndarray, np.ndarray]] = []
        shadow_tasks: list[tuple[int, int, np.ndarray, np.ndarray]] = []
        missing: list[tuple[int, int, float]] = []
        maximum_shift = 0.0
        for measurement in target_indices:
            elevation = float(positions[measurement, 1])
            if min_source_elevation_deg is not None and elevation < min_source_elevation_deg:
                continue

            az_model = -float(positions[measurement, 0])
            for receiver, ear in enumerate(ears):
                estimate = estimate_torso_reflection(
                    az_model, elevation, ear=ear,
                    delay_model=delay_model,
                    source_distance_m=model_source_distance_m)
                if estimate.has_reflection and (not np.isfinite(estimate.delay_s) or estimate.delay_s <= 0):
                    raise ValueError("Torso model returned a non-finite or nonpositive reflection delay.")
                if not estimate.has_reflection:
                    if apply_shadow:
                        coefficients = torso_shadow_filter_coefficients(
                            az_model, elevation, ear, fs)
                        if coefficients is not None:
                            shadow_tasks.append((measurement, receiver,
                                                 *coefficients))
                    continue
                if g_t == 0:
                    continue
                direction = estimate.direction_xyz
                assert direction is not None

                query = np.array([direction[1], -direction[0], direction[2]])
                query /= np.linalg.norm(query)
                _, indices = tree.query(query, k=min(3, m_count))
                indices = np.atleast_1d(indices).astype(int)
                angular = np.rad2deg(np.arccos(np.clip(unit[indices] @ query, -1, 1)))
                if angular.min() > max_angular_distance_deg:
                    missing.append((measurement, receiver, float(angular.min())))
                    continue
                if interpolation == "nearest" or angular.min() < 1e-7:
                    indices = indices[:1]
                    weights = np.array([1.0])
                else:
                    keep = angular <= max_angular_distance_deg
                    indices = indices[keep]
                    distances = angular[keep]
                    weights = 1.0 / np.maximum(distances, 1e-6) ** 2
                    weights /= weights.sum()
                shifts = (float(peaks[measurement, receiver])
                          + estimate.delay_s * fs - peaks[indices, receiver])
                maximum_shift = max(maximum_shift, float(np.max(shifts)))
                tasks.append((measurement, receiver, indices, weights, shifts))
        if missing and missing_policy == "error":
            examples = ", ".join(f"M={m}, R={r}, gap={gap:.1f}°"
                                 for m, r, gap in missing[:5])
            raise ValueError(
                f"No reflected-direction HRIR within {max_angular_distance_deg:g}° "
                f"for {len(missing)} source/ear pairs ({examples}). "
                "Use a full-sphere input or explicitly set missing_policy='skip'.")

        shadow_tail = (int(np.ceil(12 * (2 * ALG.b / C) * fs))
                       if shadow_tasks else 0)
        output_length = (n_count + int(np.ceil(max(0.0, maximum_shift)))
                         + (32 if tasks else 0) + shadow_tail)
        output_ir = np.zeros((m_count, r_count, output_length), dtype=float)
        output_ir[:, :, :n_count] = ir


        if normalize_reflection_mix and g_t > 0:
            for measurement, receiver, *_ in tasks:
                output_ir[measurement, receiver] /= 1.0 + g_t
        for measurement, receiver, indices, weights, shifts in tasks:
            for index, weight, shift in zip(indices, weights, shifts):
                output_ir[measurement, receiver] += (
                    g_t * weight / (1.0 + g_t if normalize_reflection_mix else 1.0)
                    * _fractional_shift(
                        ir[index, receiver], float(shift), output_length))


        for measurement, receiver, b, a in shadow_tasks:
            output_ir[measurement, receiver] = lfilter(
                b, a, output_ir[measurement, receiver])

        timestamp = datetime.now(timezone.utc).isoformat()
        history_line = (
            f"{timestamp}: Added one torso echo; "
            f"{('Algazi 2002' if delay_model == 'algazi' else 'Reijniers 2023')} delay, "
            f"Algazi 2002 apparent direction, "
            f"model source distance {model_source_distance_m:g} m "
            f"(Reijniers option only), g_t={g_t:g}, "
            f"peak-aligned {interpolation}, min source elevation "
            f"{min_source_elevation_deg}, applied to {len(tasks)} source/ear pairs, "
            f"torso shadow filtered {len(shadow_tasks)} source/ear pairs "
            f"(apply_shadow={apply_shadow}), "
            f"reflection mix normalization={normalize_reflection_mix}, "
            f"target positions {len(target_indices)} of {m_count} "
            f"(augmented_grid={augmented_grid}), "
            f"lookup angular limit {max_angular_distance_deg:.6g} deg, "
            f"missing coverage {len(missing)} (policy={missing_policy}). "
            "Data.Delay preserved unchanged.")
        with tempfile.NamedTemporaryFile(prefix=output_path.stem + ".",
                                         suffix=".sofa", dir=output_path.parent,
                                         delete=False) as tmp:
            temp_path = Path(tmp.name)
        try:
            _copy_sofa_with_ir(source, temp_path, output_ir, history_line)
            if output_path.exists() and not overwrite:
                raise FileExistsError(output_path)
            os.replace(temp_path, output_path)
        finally:
            temp_path.unlink(missing_ok=True)
    return output_path
