"""Spatial HRTF upsampling using the bundled Python LocaDyn translation.

The original MATLAB reference and its license notices remain bundled for
reproducible comparisons. No MATLAB or AMT installation is used at runtime.
"""
from __future__ import annotations

import json
from pathlib import Path
import tempfile


def resolve_dependencies(settings):
    """Check bundled Python dependencies before replacing existing exports."""
    import numpy
    import scipy
    import sofar


def dense_name(subdivisions):
    return f"hrtf_Nd={subdivisions}{'_dense' if subdivisions == 0 else ''}.sofa"


def upsample_hrtf_files(output_dir, settings, logger=print):
    import numpy as np
    import sofar as sf
    from ..FileIdentity import file_identity

    resolve_dependencies(settings)
    root = Path(output_dir)
    sources = sorted(root.glob("HRIR_*.sofa"))
    if not sources:
        raise ValueError("Spatial upsampling requires at least one exported HRIR SOFA file.")
    destination = root / "Upsampled"
    if destination.exists():
        raise FileExistsError(f"Spatial upsampling output already exists: {destination}. Enable overwrite or choose another output folder.")
    originals = []
    for path in sources:
        sofa = sf.read_sofa(str(path))
        ir = np.asarray(sofa.Data_IR)
        if ir.ndim != 3 or ir.shape[1] != 2:
            raise ValueError("LocaDyn spatial upsampling requires a binaural HRIR export. Select both left and right ears.")
        originals.append((path, ir.shape, np.asarray(sofa.Data_SamplingRate), file_identity(path)))
    # Publish the dense exports together only after interpolation and SOFA validation succeed.
    with tempfile.TemporaryDirectory(prefix=".pinna2hrtf-upsampling-", dir=root) as temporary:
        stage = Path(temporary)
        dense_root = stage / "Upsampled"
        logger(f"Python LocaDyn spatial upsampling: subdivision level {settings.spatial_subdivisions}; {len(sources)} HRIR export(s).")
        for index, path in enumerate(sources):
            logger(f"Spatially upsampling {index+1}/{len(sources)}: {path.name}")
            upsample_file(path, dense_root / path.stem, settings.spatial_subdivisions,
                          settings.spatial_normalize, logger)
        for path, shape, rate, identity in originals:
            folder = dense_root / path.stem
            target = folder / dense_name(settings.spatial_subdivisions)
            dense = sf.read_sofa(str(target), verify=True, verbose=False)
            ir = np.asarray(dense.Data_IR)
            if (ir.ndim != 3 or ir.shape[1:] != shape[1:] or ir.shape[0] < shape[0]
                    or not np.all(np.isfinite(ir)) or not np.all(np.isfinite(dense.Data_Delay))
                    or not np.array_equal(np.asarray(dense.Data_SamplingRate), rate)):
                raise ValueError(f"Spatial upsampling produced invalid or incompatible HRIRs: {target}")
            if file_identity(path) != identity:
                raise ValueError(f"Input changed during spatial upsampling: {path}")
            receipt = {"method": "LocaDyn-1948", "implementation": "python-1", "subdivisions": settings.spatial_subdivisions,
                       "normalize": settings.spatial_normalize, "input": identity,
                       "output": file_identity(target), "input_directions": shape[0], "output_directions": ir.shape[0]}
            (folder / "upsampling.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        dense_root.replace(destination)
    logger(f"Wrote spatially upsampled HRIRs into {destination}")
    return destination


def validate_input(sofa):
    import numpy as np
    from .locadyn import spherical_to_cartesian
    ir = np.asarray(sofa.Data_IR, dtype=float)
    pos = np.asarray(sofa.SourcePosition, dtype=float)
    rate = np.asarray(sofa.Data_SamplingRate)
    if (ir.ndim != 3 or ir.shape[1] != 2 or not 8 <= ir.shape[2] <= 16384
            or pos.shape != (ir.shape[0], 3)):
        raise ValueError("LocaDyn requires binaural HRIRs, with 8..16384 samples and one position per direction.")
    if rate.size != 1 or not np.isfinite(rate).all() or float(rate.squeeze()) <= 0:
        raise ValueError("Expected one positive sampling rate.")
    if not np.isfinite(ir).all() or not np.isfinite(pos).all():
        raise ValueError("HRIRs and source positions must be finite.")
    if np.any(np.asarray(sofa.Data_Delay) != 0):
        raise ValueError("Embed external Data.Delay in the IRs before spatial upsampling.")
    if (str(sofa.SourcePosition_Type).lower() != 'spherical'
            or 'degree' not in sofa.SourcePosition_Units.lower()
            or not any(u in sofa.SourcePosition_Units.lower() for u in ('metre', 'meter'))):
        raise ValueError("Expected spherical source positions in degrees and metres.")
    radius = pos[:, 2]
    if np.any(radius <= 0) or np.ptp(radius) > 1e-6*np.mean(radius):
        raise ValueError("LocaDyn requires a single positive source radius.")
    xyz = spherical_to_cartesian(np.column_stack((pos[:, :2], np.ones(len(pos)))))
    if len(np.unique(np.round(xyz, 10), axis=0)) != len(pos):
        raise ValueError("Input contains duplicate directions.")
    if len(pos) < 8 or np.linalg.matrix_rank(xyz-np.mean(xyz, axis=0)) < 3:
        raise ValueError("Input needs at least eight directions with 3-D coverage.")
    if np.any(np.sum(ir**2, axis=-1) == 0):
        raise ValueError("Input contains a silent IR; TOA fitting requires non-silent HRIRs.")
    receivers = np.asarray(sofa.ReceiverPosition).squeeze()
    if (receivers.shape != (2, 3) or not np.isfinite(receivers).all()
            or receivers[0, 1] <= 0 or receivers[1, 1] >= 0
            or sofa.ReceiverPosition_Type.lower() != 'cartesian'
            or sofa.ReceiverPosition_Units.lower().strip() not in ('metre', 'meter')):
        raise ValueError("Expected fixed Cartesian left (+y) and right (-y) receivers in metres.")
    convention = sofa.GLOBAL_SOFAConventions
    if convention not in ('GeneralFIR', 'SimpleFreeFieldHRIR'):
        raise ValueError("Expected GeneralFIR or SimpleFreeFieldHRIR input.")
    if convention == 'GeneralFIR':
        if sofa.GLOBAL_DataType != 'FIR' or sofa.GLOBAL_RoomType.lower() != 'free field':
            raise ValueError("Expected free-field FIR data.")
        for name, expected in [('ListenerPosition', [0,0,0]), ('ListenerView', [1,0,0]),
                               ('ListenerUp', [0,0,1]), ('EmitterPosition', [0,0,0])]:
            if name == 'ListenerUp' and not hasattr(sofa, name) and sofa.GLOBAL_ApplicationName == 'Mesh2HRTF':
                continue
            value = np.asarray(getattr(sofa, name, []))
            if value.size != 3 or not np.all(np.abs(value.reshape(-1)-expected) <= 1e-12):
                raise ValueError(f"Expected fixed standard {name}.")
            if name != 'ListenerUp' and (getattr(sofa, name+'_Type').lower() != 'cartesian'
                    or getattr(sofa, name+'_Units').lower().strip() not in ('metre','meter')):
                raise ValueError(f"Expected Cartesian metres for {name}.")
    return ir, pos, float(rate.squeeze()), receivers


def upsample_file(source, folder, subdivisions=3, normalize=True, logger=print):
    import numpy as np
    import sofar as sf
    from scipy.io import savemat
    import scipy
    import platform
    from .locadyn import interpolate
    original = sf.read_sofa(str(source))
    ir, positions, fs, receivers = validate_input(original)
    values, positions, delays, diagnostics = interpolate(ir, positions, fs, subdivisions, normalize, logger)
    output = sf.Sofa('SimpleFreeFieldHRIR', version='1.0')
    # Preserve descriptive metadata; convention-specific fields use HRIR defaults.
    for name, value in vars(original).items():
        if name.startswith('GLOBAL_') and hasattr(output, name) and name not in output._read_only_attr:
            setattr(output, name, value)
    output.Data_IR = values
    output.Data_SamplingRate = fs
    output.Data_Delay = delays  # Original LocaDyn convention: TOA in seconds, unchanged.
    output.SourcePosition = positions
    distance = np.mean(np.abs(receivers[:, 1]))
    output.ReceiverPosition = np.array([[0,distance,0],[0,-distance,0]])
    output.GLOBAL_History = original.GLOBAL_History + ' Python translation of ExpSuite LocaDyn revision 1948.'
    folder = Path(folder)
    folder.mkdir(parents=True)
    target = folder / dense_name(subdivisions)
    sf.write_sofa(str(target), output)
    report = {"implementation": "python-1", "upstreamRevision": 1948,
              "numpyVersion": np.__version__, "scipyVersion": scipy.__version__,
              "pythonVersion": platform.python_version(),
              "inputDirections": len(ir), "outputDirections": len(values),
              "samplingRate": fs, "irSamples": ir.shape[-1],
              "normalizationGain": diagnostics['normalization_gain']}
    savemat(folder / 'upsampling_report.mat', dict(result=report, **diagnostics))
    (folder / 'upsampling_report.txt').write_text(
        '\n'.join(f'{key}: {value}' for key, value in report.items()) + '\n', encoding='utf-8')
    return target
