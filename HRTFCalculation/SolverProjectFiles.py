import json
import os
import re
from pathlib import Path

from .FileIdentity import cached_sha256, sha256


EXPORT_RECORD = ".pinna2hrtf-export.json"
_NUMCALC_OUTPUT = re.compile(
    r"^NumCalc/source_\d+/("
    r"be\.out/be\.\d+/(pBoundary|pBoundaryVTK\.vtk|pEvalGrid|vBoundary|vEvalGrid)"
    r"|NC\d+-\d+\.out|NCfrom\d+\.out|NCuntil\d+\.out|NC\.out|Memory\.txt|NC\d+-\d+_log\.txt"
    r")$"
)
_OUTPUT2HRTF_FIXED = re.compile(r"^Output2HRTF/(report_source_\d+\.csv|report_issues\.txt|vtk/[^/]+/frequency_step_\d+\.vtk)$")


def is_solver_output(name, grids):
    if _NUMCALC_OUTPUT.match(name) or _OUTPUT2HRTF_FIXED.match(name):
        return True
    for grid in grids:
        for kind in ("HRTF", "HRIR"):
            stem = re.escape(f"{kind}_{grid}")
            if re.match(rf"^Output2HRTF/{stem}(\.sofa|_2D\.pdf|_3D_(horizontal|median|frontal)_plane\.jpeg)$", name):
                return True
    return False


def project_files(root):
    files, other = [], []
    for dirpath, dirnames, filenames in os.walk(root):
        for name in dirnames + filenames:
            path = Path(dirpath) / name
            relative = path.relative_to(root).as_posix()
            if path.is_symlink():
                other.append(relative)
            elif name in filenames:
                (files if path.is_file() else other).append(relative)
        dirnames[:] = [name for name in dirnames if not (Path(dirpath) / name).is_symlink()]
    return files, other


def write_export_record(project):
    files, _ = project_files(project)
    record = {"version": 1, "files": {name: sha256(project / name) for name in sorted(files) if name != EXPORT_RECORD}}
    temporary = project / (EXPORT_RECORD + ".tmp")
    temporary.write_text(json.dumps(record, indent=1), encoding="utf-8")
    os.replace(temporary, project / EXPORT_RECORD)


_PREPROCESSING_OUTPUT = re.compile(r"^(parameters\.json|NumCalc/source_\d+/NC\.inp|ObjectMeshes/.+|EvaluationGrids/.+)$")
_REQUIRED_PREPROCESSING_OUTPUTS = (
    ("parameters.json", re.compile(r"^parameters\.json$")),
    ("solver input", re.compile(r"^NumCalc/source_\d+/NC\.inp$")),
    ("object mesh", re.compile(r"^ObjectMeshes/")),
    ("evaluation grid", re.compile(r"^EvaluationGrids/")),
)


def preprocessing_outputs(project):
    project = Path(project)
    parameters = project / "parameters.json"
    names = [parameters.name] if not parameters.is_symlink() and parameters.is_file() else []
    solver = project / "NumCalc"
    if not solver.is_symlink():
        for source in solver.glob("source_*"):
            deck = source / "NC.inp"
            relative = deck.relative_to(project).as_posix()
            if _PREPROCESSING_OUTPUT.match(relative) and not source.is_symlink() and not deck.is_symlink() and deck.is_file():
                names.append(relative)
    for name in ("ObjectMeshes", "EvaluationGrids"):
        folder = project / name
        if not folder.is_symlink():
            files, _ = project_files(folder)
            names.extend(f"{name}/{file}" for file in files)
    missing = [label for label, pattern in _REQUIRED_PREPROCESSING_OUTPUTS if not any(pattern.match(name) for name in names)]
    if missing:
        raise FileNotFoundError(f"The Mesh2HRTF project {project} is missing its {', '.join(missing)}. Run preprocessing again.")
    return {name: cached_sha256(project / name) for name in sorted(names)}


def recorded_preprocessing_outputs(project):
    try:
        files = json.loads((Path(project) / EXPORT_RECORD).read_text(encoding="utf-8"))["files"]
        return {name: digest for name, digest in files.items() if _PREPROCESSING_OUTPUT.match(name)}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None


def snapshot_generated_outputs(project):
    project = Path(project)
    try:
        record = json.loads((project / EXPORT_RECORD).read_text(encoding="utf-8"))
        recorded = record["files"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    files, _ = project_files(project)
    unchanged = {name for name in files if name.startswith("Output2HRTF/") and name in recorded and sha256(project / name) == recorded[name]}
    return record, set(files), unchanged


def claim_generated_outputs(project, snapshot):
    if snapshot is None:
        return
    project = Path(project)
    record, existing, unchanged = snapshot
    recorded = record["files"]
    grids = {name.split("/")[1] for name in recorded if name.startswith("EvaluationGrids/") and name.count("/") >= 2}
    files, _ = project_files(project)
    for name in files:
        if is_solver_output(name, grids) and (name not in existing or name in unchanged):
            recorded[name] = sha256(project / name)
    temporary = project / (EXPORT_RECORD + ".tmp")
    temporary.write_text(json.dumps(record, indent=1), encoding="utf-8")
    os.replace(temporary, project / EXPORT_RECORD)
