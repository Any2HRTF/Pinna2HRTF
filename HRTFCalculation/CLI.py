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


MACHINE_COMMANDS = ("project", "mesh", "pressure", "fit-worker", "outputs", "output-worker")


def cli() -> None:
    arguments = sys.argv[1:]
    if not arguments or arguments[0] in {"-h", "--help"}:
        print("usage: Pinna2HRTF {" + "|".join((*STEPS, *MACHINE_COMMANDS, "geometry", "ear-canal")) + "} [options]")
        return
    step = arguments[0]
    if step in MACHINE_COMMANDS or step in {"geometry", "ear-canal"}:
        sys.argv = [f"Pinna2HRTF {step}", *arguments[1:]]
        if step == "ear-canal":
            from .Preprocessing.src.ear_canal_closer import main
            main()
        elif step == "geometry":
            from .Geometry import main
            main()
        else:
            from .Commands import machine_command
            machine_command(step)
        return
    if step not in STEPS:
        raise SystemExit(f"Unknown Pinna2HRTF step: {step}")
    step_arguments = arguments[1:]
    config_index = next((index for index, argument in enumerate(step_arguments)
                         if argument == "--config" or argument.startswith("--config=")), None)
    if step != "run-config" and config_index is not None:
        if step_arguments[config_index] == "--config":
            if config_index + 1 >= len(step_arguments):
                raise SystemExit("--config requires a path")
            config_path = step_arguments[config_index + 1]
            remaining = step_arguments[:config_index] + step_arguments[config_index + 2:]
        else:
            config_path = step_arguments[config_index].split("=", 1)[1]
            if not config_path:
                raise SystemExit("--config requires a path")
            remaining = step_arguments[:config_index] + step_arguments[config_index + 1:]
        config_step = "postprocessing" if step == "sofa" else step
        sys.argv = [f"Pinna2HRTF {step}", "--config", config_path, "--stage", config_step, *remaining]
        module_name, function_name = STEPS["run-config"]
    else:
        sys.argv = [f"Pinna2HRTF {step}", *step_arguments]
        module_name, function_name = STEPS[step]
    getattr(importlib.import_module(module_name), function_name)()


if __name__ == "__main__":
    cli()
