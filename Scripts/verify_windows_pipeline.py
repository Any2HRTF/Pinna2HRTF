"""Run a small real Windows simulation without changing existing projects."""
import argparse
import json
from pathlib import Path
import time
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import mesh2hrtf
import numpy as np
import sofar
import trimesh

from HRTFCalculation.Config import PipelineConfig, save_config
from HRTFCalculation.RunConfig import run_from_config


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--side", choices=["left", "right", "both"], default="both")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    output = Path(args.output).resolve()
    if output.exists():
        raise FileExistsError("Use a new output folder for each verification run.")
    output.mkdir(parents=True)
    grid = output / "Small evaluation grid"
    mesh2hrtf.write_evaluation_grid(trimesh.creation.icosphere(subdivisions=0, radius=1.5).vertices, str(grid))
    config = PipelineConfig()
    config.paths.left_ear = root / "Test Data/Input/Left/Left.stl" if args.side != "right" else None
    config.paths.right_ear = root / "Test Data/Input/Right/Right.stl" if args.side != "left" else None
    config.paths.output_dir = output
    config.paths.external_deps_dir = root / "External"
    config.paths.mesh_grading_executable = root / "External/bin/hrtf_mesh_grading.exe"
    config.paths.numcalc_executable = root / "External/bin/NumCalc.exe"
    config.paths.evaluation_grid = str(grid)
    config.preprocessing.min_frequency = 1000
    config.preprocessing.max_frequency = 2000
    config.preprocessing.frequency_step_count = 2
    config.preprocessing.mesh_min_edge_length = 1.5
    config.preprocessing.mesh_max_edge_length = 20
    config.preprocessing.mesh_max_error = 0.8
    config.numcalc.enabled = True
    config.numcalc.max_instances = 1
    config.numcalc.wait_time = 1
    config.postprocessing.enabled = True
    config.postprocessing.resample_hrirs = True
    config.postprocessing.sampling_rate = 16000
    config.postprocessing.output_sofa_dir = output / "Custom SOFA output"
    config = config.resolved()
    save_config(config, output / "Project Settings.yaml")
    started = time.monotonic()
    run_from_config(config)
    results = []
    for path in config.postprocessing.output_sofa_dir.glob("*.sofa"):
        sofa = sofar.read_sofa(str(path), verify=True, verbose=False)
        arrays = [np.asarray(getattr(sofa, name)) for name in ("Data_IR", "Data_Real", "Data_Imag") if hasattr(sofa, name)]
        assert arrays and all(data.size and np.isfinite(data).all() for data in arrays)
        if path.name.startswith("HRIR"):
            assert np.all(np.asarray(sofa.Data_SamplingRate) == 16000)
        results.append({"file": path.name, "shapes": [list(data.shape) for data in arrays]})
    assert any(result["file"].startswith("HRIR") for result in results)
    assert any(result["file"].startswith("HRTF") for result in results)
    report = {"side": args.side, "duration_seconds": time.monotonic() - started, "files": results}
    (output / "verification.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2), flush=True)


if __name__ == "__main__":
    main()
