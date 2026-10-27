"""Run the original EvaPPM LocaDyn spatial interpolation in MATLAB.

The scientific implementation is bundled unchanged in upsample_hrtf.m, including
its ExpSuite/LocaDyn revision 1948 provenance and EUPL/BSD license notices.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def resolve_dependencies(settings):
    """Find MATLAB and AMT before postprocessing replaces any existing exports."""
    if settings.matlab_executable is not None:
        matlab = Path(settings.matlab_executable).expanduser()
    else:
        candidates = ([Path(shutil.which("matlab"))] if shutil.which("matlab") else [])
        candidates += sorted(Path("/Applications").glob("MATLAB*.app/bin/matlab"), reverse=True)
        matlab = next((path for path in candidates if path.is_file() and os.access(path, os.X_OK)), None)
    if matlab is None or not matlab.is_file() or not os.access(matlab, os.X_OK):
        raise ValueError("Spatial HRTF upsampling requires MATLAB. Choose its executable in Postprocessing settings.")
    candidates = [Path(settings.amt_path).expanduser()] if settings.amt_path is not None else [
        Path.home() / "Documents/Uni/MATLAB/amtoolbox", Path.home() / "Documents/MATLAB/amtoolbox",
    ]
    amt = next((path for path in candidates if (path / "amt_start.m").is_file()), None)
    if amt is None:
        raise ValueError("Spatial HRTF upsampling requires the Auditory Modeling Toolbox (AMT). Choose the folder containing amt_start.m in Postprocessing settings.")
    return matlab.resolve(), amt.resolve()


def dense_name(subdivisions):
    return f"hrtf_Nd={subdivisions}{'_dense' if subdivisions == 0 else ''}.sofa"


def _matlab_string(path):
    return "'" + str(path).replace("'", "''") + "'"


def upsample_hrtf_files(output_dir, settings, logger=print):
    import numpy as np
    import sofar as sf
    from ..FileIdentity import file_identity

    matlab, amt = resolve_dependencies(settings)
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
    # Publish the dense exports together only after MATLAB and SOFA validation succeed.
    with tempfile.TemporaryDirectory(prefix=".pinna2hrtf-upsampling-", dir=root) as temporary:
        stage = Path(temporary)
        dense_root = stage / "Upsampled"
        jobs = [{"input": str(path.resolve()), "output": str((dense_root / path.stem).resolve())} for path in sources]
        plan = stage / "plan.json"
        plan.write_text(json.dumps({"jobs": jobs, "subdivisions": settings.spatial_subdivisions,
                                    "normalize": settings.spatial_normalize, "amt_path": str(amt)}), encoding="utf-8")
        scripts = Path(__file__).resolve().parent
        command = f"addpath({_matlab_string(scripts)}); pinna_upsample_batch({_matlab_string(plan.resolve())});"
        logger(f"LocaDyn spatial upsampling: subdivision level {settings.spatial_subdivisions}; {len(jobs)} HRIR export(s).")
        environment = os.environ.copy()
        # The packaged Python runtime must not affect MATLAB's own Python discovery.
        environment.pop("PYTHONHOME", None)
        environment.pop("PYTHONPATH", None)
        subprocess.run([str(matlab), "-batch", command], check=True, env=environment)
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
            receipt = {"method": "LocaDyn-1948", "subdivisions": settings.spatial_subdivisions,
                       "normalize": settings.spatial_normalize, "input": identity,
                       "output": file_identity(target), "input_directions": shape[0], "output_directions": ir.shape[0]}
            (folder / "upsampling.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        dense_root.replace(destination)
    logger(f"Wrote spatially upsampled HRIRs into {destination}")
    return destination
