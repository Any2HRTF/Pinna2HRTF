from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
from collections import deque
from pathlib import Path

import mesh2hrtf as m2h
import psutil
from .LiveEvents import emit_live_event


def frequency_step_complete(source_dir: Path, step: int) -> bool:
    output_dir = source_dir / "be.out" / f"be.{step}"
    required_outputs = {"pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid"}
    if not output_dir.is_dir() or not all((output_dir / name).is_file() and (output_dir / name).stat().st_size > 0 for name in required_outputs):
        return False
    log_path = source_dir / f"NC{step}-{step}_log.txt"
    if not log_path.is_file():
        return False
    return "---------- NumCalc ended:" in log_path.read_text(encoding="utf-8", errors="replace")


def resolve_numcalc_executable(numcalc_path: Path) -> Path:
    """Return the NumCalc binary for a file path, or for a folder containing NumCalc.

    Custom executable file names are honoured on every platform.
    """
    path = Path(numcalc_path).expanduser().resolve()
    if path.is_dir():
        candidate = path / ("NumCalc.exe" if os.name == "nt" else "NumCalc")
        if not candidate.is_file():
            raise FileNotFoundError(f"The NumCalc folder {path} does not contain {candidate.name}. Choose the NumCalc executable itself.")
        return candidate
    if not path.is_file():
        raise FileNotFoundError(f"Missing NumCalc executable: {path}")
    return path


def _estimate_ram(executable: Path, adaptive_arguments: list[str], source_dir: Path) -> None:
    # Keep NumCalc's output outside the project tree; it is only needed to explain failures.
    with tempfile.TemporaryFile(mode="w+", encoding="utf-8", errors="replace", prefix="pinna2hrtf-estimate-ram-") as log:
        return_code = subprocess.run([str(executable), *adaptive_arguments, "-estimate_ram"], cwd=source_dir, stdout=log, stderr=subprocess.STDOUT).returncode
        if return_code != 0 or not (source_dir / "Memory.txt").is_file():
            log.seek(0)
            output = log.read()[-4000:].strip()
            raise RuntimeError(f"NumCalc -estimate_ram failed in {source_dir} (exit code {return_code}).\n{output or 'NumCalc printed no output.'}")


def _terminate(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    try:
        if os.name == "nt":
            process.terminate()
        else:
            os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=10)
    except ProcessLookupError:
        pass
    except subprocess.TimeoutExpired:
        if os.name == "nt":
            process.kill()
        else:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass


def run_local_numcalc(project_path: Path, numcalc_path: Path, max_ram_load_gb: float | None, ram_safety_factor: float, max_cpu_load: int, max_instances: int, starting_order: str, wait_time: int, adaptive_fmm_length: bool) -> None:
    executable = resolve_numcalc_executable(numcalc_path)
    adaptive_arguments = ["-adapt_fmmlength"] if adaptive_fmm_length else []
    running = []
    try:
        projects = [project_path] if (project_path / "parameters.json").exists() else [path for path in project_path.iterdir() if (path / "parameters.json").exists()]
        if not projects:
            raise FileNotFoundError(f"No Mesh2HRTF projects found at {project_path}")
        pending = []
        for project in projects:
            source_dirs = sorted(project.glob("NumCalc/source_*"))
            for source_dir in source_dirs:
                memory_file = source_dir / "Memory.txt"
                estimates = list(m2h.read_ram_estimates(str(source_dir))) if memory_file.exists() else []
                if not estimates or (adaptive_fmm_length and not all(frequency_step_complete(source_dir, int(step)) for step, _, _ in estimates)):
                    _estimate_ram(executable, adaptive_arguments, source_dir)
                    estimates = list(m2h.read_ram_estimates(str(source_dir)))
                for step, frequency, ram in estimates:
                    if not frequency_step_complete(source_dir, int(step)):
                        pending.append((float(ram), project, source_dir, int(step), frequency))
        if starting_order == "high":
            pending.sort(key=lambda item: item[0], reverse=True)
        elif starting_order == "low":
            pending.sort(key=lambda item: item[0])
        else:
            pending.sort(key=lambda item: item[0], reverse=True)
            low_to_high = pending[::-1]
            pending = [item for pair in zip(pending, low_to_high) for item in pair]
            pending = list(dict.fromkeys(pending))
        total_steps = len(pending)
        pending = deque(pending)
        if total_steps:
            emit_live_event(f"Running {total_steps} unfinished frequency steps", key="numcalc-overview")
        else:
            emit_live_event("All frequency steps are already complete")
        print(f"Running {len(pending)} unfinished frequency steps with adaptive FMM expansion length={adaptive_fmm_length}", flush=True)
        total_ram = psutil.virtual_memory().total / 1073741824
        ram_budget = max_ram_load_gb or total_ram
        warned_memory_steps: set[tuple[str, int, str]] = set()
        completed_steps = 0
        last_start = float("-inf")
        while pending or running:
            finished = []
            for item in running:
                process, log_file, ram, project, item_source_dir, step, frequency = item
                return_code = process.poll()
                if return_code is not None:
                    log_file.close()
                    if return_code != 0:
                        raise RuntimeError(f"NumCalc failed for {project.name}, step {step}, frequency {frequency} Hz; see {log_file.name}")
                    if not frequency_step_complete(item_source_dir, step):
                        raise RuntimeError(f"NumCalc produced incomplete output for {project.name}, step {step}, frequency {frequency} Hz; see {log_file.name}")
                    finished.append(item)
            for item in finished:
                running.remove(item)
            if finished:
                completed_steps += len(finished)
                emit_live_event(
                    f"Completed {completed_steps} of {total_steps} frequency steps",
                    key="numcalc-progress",
                )
            while pending and len(running) < max_instances:
                ram, project, source_dir, step, frequency = pending[0]
                required_ram = ram * ram_safety_factor
                used_ram = sum(item[2] * ram_safety_factor for item in running)
                if used_ram + required_ram > ram_budget:
                    break
                if running:
                    # wait_time (as in Mesh2HRTF's manage_numcalc) lets a newly started
                    # instance ramp up before CPU load decides whether to start another.
                    if time.monotonic() - last_start < wait_time:
                        break
                    if psutil.cpu_percent(interval=0.1) >= max_cpu_load:
                        break
                pending.popleft()
                available_ram = psutil.virtual_memory().available / 1073741824
                safe_available_ram = available_ram * 0.9
                warning_key = (project.name, step, str(source_dir))
                if required_ram > safe_available_ram and warning_key not in warned_memory_steps:
                    warned_memory_steps.add(warning_key)
                    emit_live_event(
                        f"High memory demand for {project.name} at {frequency:g} Hz; see technical log",
                        level="warning",
                    )
                    print(
                        f"Warning: estimated RAM for {project.name}, {frequency:g} Hz is {required_ram:.2f} GB; "
                        f"only {available_ram:.2f} GB is currently available with a 10% safety margin.",
                        flush=True,
                    )
                log_path = source_dir / f"NC{step}-{step}_log.txt"
                log_file = log_path.open("w", encoding="utf-8")
                process = subprocess.Popen([str(executable), *adaptive_arguments, "-istart", str(step), "-iend", str(step)], cwd=source_dir, stdout=log_file, stderr=subprocess.STDOUT, start_new_session=os.name != "nt")
                running.append((process, log_file, ram, project, source_dir, step, frequency))
                last_start = time.monotonic()
                print(f"Started {project.name}, step {step}, {frequency:g} Hz, estimated {ram:.2f} GB", flush=True)
            if pending and not running and pending[0][0] * ram_safety_factor > ram_budget:
                raise MemoryError(f"The smallest pending NumCalc step requires {pending[0][0] * ram_safety_factor:.2f} GB, above the configured {ram_budget:.2f} GB budget")
            if pending or running:
                # Completion is polled every second; wait_time only throttles new starts.
                time.sleep(1)
    finally:
        for process, log_file, _, _, _, _, _ in running:
            _terminate(process)
            log_file.close()
