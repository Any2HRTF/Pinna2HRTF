import importlib
import sys


STEPS = {
    "scan-preparation": ("HRTFCalculation.RunConfig", "scan_preparation_cli"),
    "inference": ("HRTFCalculation.Inference.inference_stl", "cli"),
    "preprocessing": ("HRTFCalculation.Preprocessing", "preprocess"),
    "numcalc": ("HRTFCalculation.RunConfig", "numcalc_cli"),
    "sofa": ("HRTFCalculation.RunConfig", "sofa_cli"),
    "postprocessing": ("HRTFCalculation.Postprocessing.postprocessing", "cli"),
    "run-config": ("HRTFCalculation.RunConfig", "cli"),
}


def cli() -> None:
    arguments = sys.argv[1:]
    if not arguments or arguments[0] in {"-h", "--help"}:
        print("usage: Pinna2HRTF {scan-preparation|inference|preprocessing|numcalc|sofa|postprocessing|run-config} [options]")
        return
    step = arguments[0]
    if step not in STEPS:
        raise SystemExit(f"Unknown Pinna2HRTF step: {step}")
    step_arguments = arguments[1:]
    if step in {"scan-preparation", "inference", "preprocessing", "numcalc", "sofa", "postprocessing"} and "--config" in step_arguments:
        config_index = step_arguments.index("--config")
        if config_index + 1 >= len(step_arguments):
            raise SystemExit("--config requires a path")
        config_path = step_arguments[config_index + 1]
        remaining = step_arguments[:config_index] + step_arguments[config_index + 2:]
        config_step = "postprocessing" if step == "sofa" else step
        sys.argv = [f"Pinna2HRTF {step}", "--config", config_path, "--stage", config_step, *remaining]
        module_name, function_name = STEPS["run-config"]
    else:
        sys.argv = [f"Pinna2HRTF {step}", *step_arguments]
        module_name, function_name = STEPS[step]
    getattr(importlib.import_module(module_name), function_name)()


if __name__ == "__main__":
    cli()
