from __future__ import annotations

import os
import shlex
import signal
import shutil
import stat
import subprocess
import tempfile
import time
from collections import deque
from pathlib import Path

import mesh2hrtf as m2h
import psutil


def frequency_step_complete(source_dir: Path, step: int) -> bool:
    output_dir = source_dir / "be.out" / f"be.{step}"
    required_outputs = {"pBoundary", "pEvalGrid", "vBoundary", "vEvalGrid"}
    if not output_dir.is_dir() or not required_outputs.issubset({path.name for path in output_dir.iterdir()}):
        return False
    log_path = source_dir / f"NC{step}-{step}_log.txt"
    if not log_path.is_file():
        return False
    return "---------- NumCalc ended:" in log_path.read_text(encoding="utf-8", errors="replace")


def run_local_numcalc(project_path: Path, numcalc_path: Path, max_ram_load_gb: float | None, ram_safety_factor: float, max_cpu_load: int, max_instances: int, starting_order: str, wait_time: int, adaptive_fmm_length: bool) -> None:
    numcalc_path = numcalc_path.expanduser().resolve()
    wrapper_dir: Path | None = None
    executable = numcalc_path
    if executable.is_dir():
        candidate = executable / ("NumCalc.exe" if os.name == "nt" else "NumCalc")
        if candidate.exists():
            executable = candidate
    adaptive_arguments = []
    if adaptive_fmm_length and os.name != "nt":
        wrapper_dir = Path(tempfile.mkdtemp(prefix="pinna2hrtf-numcalc-"))
        executable = wrapper_dir / "NumCalc"
        executable.write_text(f"#!/bin/sh\nexec {shlex.quote(str(numcalc_path))} -adapt_fmmlength \"$@\"\n", encoding="utf-8")
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    elif adaptive_fmm_length:
        adaptive_arguments = ["-adapt_fmmlength"]
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
                    subprocess.run([str(executable), *adaptive_arguments, "-estimate_ram"], cwd=source_dir, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=True)
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
        pending = deque(pending)
        print(f"Running {len(pending)} unfinished frequency steps with adaptive FMM expansion length={adaptive_fmm_length}", flush=True)
        total_ram = psutil.virtual_memory().total / 1073741824
        ram_budget = max_ram_load_gb or total_ram
        warned_memory_steps: set[tuple[str, int, str]] = set()
        running = []
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
            while pending and len(running) < max_instances:
                ram, project, source_dir, step, frequency = pending[0]
                required_ram = ram * ram_safety_factor
                used_ram = sum(item[2] * ram_safety_factor for item in running)
                if used_ram + required_ram > ram_budget:
                    break
                if running and psutil.cpu_percent(interval=0.1) >= max_cpu_load:
                    break
                pending.popleft()
                available_ram = psutil.virtual_memory().available / 1073741824
                safe_available_ram = available_ram * 0.9
                warning_key = (project.name, step, str(source_dir))
                if required_ram > safe_available_ram and warning_key not in warned_memory_steps:
                    warned_memory_steps.add(warning_key)
                    print(
                        f"Warning: estimated RAM for {project.name}, {frequency:g} Hz is {required_ram:.2f} GB; "
                        f"only {available_ram:.2f} GB is currently available with a 10% safety margin.",
                        flush=True,
                    )
                log_path = source_dir / f"NC{step}-{step}_log.txt"
                log_file = log_path.open("w", encoding="utf-8")
                process = subprocess.Popen([str(executable), *adaptive_arguments, "-istart", str(step), "-iend", str(step)], cwd=source_dir, stdout=log_file, stderr=subprocess.STDOUT, start_new_session=os.name != "nt")
                running.append((process, log_file, ram, project, source_dir, step, frequency))
                print(f"Started {project.name}, step {step}, {frequency:g} Hz, estimated {ram:.2f} GB", flush=True)
            if pending and not running and pending[0][0] * ram_safety_factor > ram_budget:
                raise MemoryError(f"The smallest pending NumCalc step requires {pending[0][0] * ram_safety_factor:.2f} GB, above the configured {ram_budget:.2f} GB budget")
            if pending or running:
                time.sleep(max(1, wait_time if running and len(running) == 1 and len(finished) == 0 else 1))
    finally:
        for process, log_file, _, _, _, _, _ in locals().get("running", []):
            if process.poll() is None:
                if os.name == "nt":
                    process.terminate()
                else:
                    try:
                        os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError:
                        pass
            log_file.close()
        if wrapper_dir is not None:
            shutil.rmtree(wrapper_dir, ignore_errors=True)
