import json
import os
import re
import sys
import shutil
import uuid
from contextlib import contextmanager
from pathlib import Path

from .FileIdentity import sha256
from .RunConfig import MANIFEST_RELATIVE, SLURM_RECORD, _DOTNET_EPOCH_TICKS, _output_manifest_lock, _read_output_manifest, release_finished_slurm_jobs, slurm_busy_message


EDITOR_FOLDERS = {"meshedits", "manual ppm"}
STAGES = ("Scan-Preparation", "Inference", "Preprocessing", "Numcalc", "Postprocessing")
FILES = (
    ("Postprocessing", re.compile(r"^HRTF/Upsampled/HRIR_[^/]+/(hrtf_Nd=[0-5](_dense)?\.sofa|upsampling_report\.(txt|mat)|upsampling\.json)$", re.IGNORECASE)),
    ("Postprocessing", re.compile(r"^HRTF/\.pinna2hrtf-upsampling-[a-z0-9_]{8}/(plan\.json|Upsampled/HRIR_[^/]+/(hrtf_Nd=[0-5](_dense)?\.sofa|upsampling_report\.(txt|mat)|upsampling\.json))$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Manual PPM/((Left|Right)\.(stl|json|blend[0-9]*)|PPM\.blend[0-9]*|Templates/[0-9a-f-]{36}-PPM\.blend[0-9]*)$", re.IGNORECASE)),
    ("Scan-Preparation", re.compile(r"^MeshEdits/((Individual)?(Left|Right)\.(stl|json)|AlignedScan\.(ply|json))$", re.IGNORECASE)),
    ("Inference", re.compile(r"^Prepared/inference\.json$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Prepared/preprocessing\.json$", re.IGNORECASE)),
    ("Scan-Preparation", re.compile(r"^Prepared/(Left\.stl|Right\.stl|mesh_preparation\.json)$", re.IGNORECASE)),
    ("Inference", re.compile(r"^\.pinna2hrtf_native_run\.yaml$", re.IGNORECASE)),
    ("Inference", re.compile(r"^(Intermediates/)?Results Inference\.csv$", re.IGNORECASE)),
    ("Inference", re.compile(r"^Intermediates/(Left|Right)/(ICP_[^/]+\.stl|Prediction_[^/]+\.stl|Prediction_Parameters_[^/]+\.csv)$", re.IGNORECASE)),
    ("Inference", re.compile(r"^(Intermediates/)?(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)/[^/]+\.(stl|csv)$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Intermediates/(Left|Right)/(input_ear\.stl|source_landmark\.json|closed_ear\.stl|cut_head\.stl|stitched_head\.stl|graded_head\.ply|dummy_head\.stl)$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Intermediates/dummy_head\.stl$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Projects/(Left|Right)/(parameters\.json|3d Model\.blend[0-9]*|NumCalc/source_[0-9]+/NC\.inp|(ObjectMeshes|EvaluationGrids)/[^/]+/(Nodes|Elements)\.txt)$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^\.pinna2hrtf-preprocessing-(signature|(mac-v2|windows-v3|inputs-v1)\.json)$", re.IGNORECASE)),
    ("Numcalc", re.compile(r"^Projects/(Left|Right)/NumCalc/source_[0-9]+/(NC[0-9]+-[0-9]+_log\.txt|NC([0-9]+-[0-9]+|from[0-9]+|until[0-9]+)?\.out|Memory\.txt|be\.out/be\.[0-9]+/(pBoundary|pEvalGrid|vBoundary|vEvalGrid))$", re.IGNORECASE)),
    ("Postprocessing", re.compile(r"^(HRTF|Projects/(Left|Right)/Output2HRTF)/(HRIR|HRTF)_[^/]+\.(sofa|png|jpg|jpeg|pdf)$", re.IGNORECASE)),
    ("Postprocessing", re.compile(r"^Projects/(Left|Right)/Output2HRTF/(report_source_[0-9]+\.csv|report_issues\.(txt|csv))$", re.IGNORECASE)),
    ("Inference", re.compile(r"^\.pinna2hrtf-inference-(signature|receipt\.json)$", re.IGNORECASE)),
    ("Postprocessing", re.compile(r"^\.pinna2hrtf-postprocessing-receipt\.json$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Projects/(Left|Right)/\.pinna2hrtf-export\.json$", re.IGNORECASE)),
)

DIRECTORIES = (
    ("Preprocessing", re.compile(r"^Manual PPM(/Templates)?$", re.IGNORECASE)),
    ("Scan-Preparation", re.compile(r"^MeshEdits$", re.IGNORECASE)),
    ("Scan-Preparation", re.compile(r"^Prepared$", re.IGNORECASE)),
    ("Inference", re.compile(r"^Intermediates$", re.IGNORECASE)),
    ("Inference", re.compile(r"^(Prediction STL|Prediction Parameters|ICP STL) (Left|Right)$", re.IGNORECASE)),
    ("Numcalc", re.compile(r"^Projects/(Left|Right)/NumCalc/source_[0-9]+/be\.out(/be\.[0-9]+)?$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Intermediates/(Left|Right)$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Projects$", re.IGNORECASE)),
    ("Preprocessing", re.compile(r"^Projects/(Left|Right)(/(ObjectMeshes|EvaluationGrids|NumCalc)(/.*)?)?$", re.IGNORECASE)),
    ("Postprocessing", re.compile(r"^HRTF(/.*)?$", re.IGNORECASE)),
    ("Postprocessing", re.compile(r"^Projects/(Left|Right)/Output2HRTF(/.*)?$", re.IGNORECASE)),
)


def stage_name(value):
    if isinstance(value, int) and -1 <= value <= 3:
        return STAGES[value + 1]
    for stage in STAGES:
        if stage.replace("-", "").lower() == str(value).replace("-", "").lower():
            return stage
    raise ValueError(f"Unknown stage: {value}")


def classify(relative, patterns=FILES):
    return next((stage for stage, pattern in patterns if pattern.fullmatch(relative)), None)


def stamp(path):
    info = path.stat()
    return {"Size": info.st_size, "ModifiedUtcTicks": info.st_mtime_ns // 100 + _DOTNET_EPOCH_TICKS}


def fingerprint(path, stage):
    before = stamp(path)
    digest = sha256(path)
    if before != stamp(path):
        raise OSError(f"Output changed during inspection: {path}")
    return dict(before, Stage=stage, Sha256=digest.upper())


def replace_text(path, text):
    path = Path(path)
    staged = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(text)
        if path.exists():
            shutil.copymode(path, staged)
        os.replace(staged, path)
    finally:
        staged.unlink(missing_ok=True)


def write_json(path, document):
    replace_text(path, json.dumps(document, indent=2))


class Outputs:
    def __init__(self, request):
        if not request.get("root"):
            raise ValueError("Choose a project folder")
        self.root = Path(request["root"]).resolve()
        if self.root == self.root.parent:
            raise ValueError("A filesystem root cannot be a project")
        self.inputs = {Path(p).resolve() for p in request.get("inputs", []) if p}
        if request.get("action") == "reset":
            from .Compatibility import read_settings
            import yaml
            for filename in ("Project Settings.yaml", ".pinna2hrtf_native_run.yaml", "pipeline.yaml"):
                settings = self.root / filename
                if settings.is_file():
                    _, text, _ = read_settings(settings)
                    mapping = yaml.safe_load(text) or {}
                    for section, fields in {"paths": ("left_ear", "right_ear", "edited_left_ear", "edited_right_ear", "evaluation_grid"),
                                            "scan_preparation": ("scan_path", "original_scan_path", "reviewed_left", "reviewed_right"),
                                            "manual_ppm": ("left_source", "right_source", "template_blend"),
                                            "inference": ("model_checkpoint", "model_config_file")}.items():
                        for field in fields:
                            value = mapping.get(section, {}).get(field)
                            if value:
                                self.inputs.add((self.root / value).resolve())
                    break
        folder = request.get("output_folder")
        self.destination = Path(folder).resolve() if folder else None
        self.prefix = None
        if folder:
            output = Path(folder).resolve()
            if output.is_relative_to(self.root):
                relative = output.relative_to(self.root)
                if not relative.parts or relative.parts[0].casefold() in {".pinna2hrtf", "input", "prepared", "meshedits", "manual ppm", "projects", "intermediates"}:
                    raise ValueError("Choose a separate output folder")
                if any(p.is_relative_to(output) or output.is_relative_to(p) for p in self.inputs):
                    raise ValueError("The output folder overlaps a protected input")
                self.prefix = relative.as_posix()

    def normalized(self, relative):
        if self.prefix and (relative == self.prefix or relative.startswith(self.prefix + "/")):
            return "HRTF" + relative[len(self.prefix):]
        return relative

    def safe(self, relative):
        if not relative or any(part in {"", ".", ".."} or part.endswith((" ", ".")) for part in relative.split("/")) or ":" in relative or "\\" in relative:
            return None
        path = self.root / relative
        if path.resolve() != path:
            return None
        return path

    def protected(self, path):
        return any(path.is_relative_to(input_path) for input_path in self.inputs)

    @contextmanager
    def locked(self):
        for relative in (".pinna2hrtf", MANIFEST_RELATIVE.as_posix(), ".pinna2hrtf/outputs.lock", SLURM_RECORD.as_posix(), ".pinna2hrtf/slurm"):
            if self.safe(relative) is None:
                raise ValueError("Linked project metadata")
        with _output_manifest_lock(self.root) as held:
            if not held:
                raise RuntimeError("Project outputs are busy")
            self.doc = _read_output_manifest(self.root)
            for entry in self.doc["Files"].values():
                if not re.fullmatch("[a-fA-F0-9]{64}", entry["Sha256"]):
                    raise ValueError("Invalid ownership fingerprint")
                entry["Stage"] = stage_name(entry["Stage"])
            for relative, stage in self.doc["Directories"].items():
                self.doc["Directories"][relative] = stage_name(stage)
            yield

    def scan(self):
        files, directories = {}, set()
        def visit(parent):
            for path in parent.iterdir():
                relative = path.relative_to(self.root).as_posix()
                name = self.normalized(relative)
                if self.safe(relative) is None or self.protected(path):
                    continue
                if path.is_dir():
                    if classify(name, DIRECTORIES) or name.split("/")[0] in {"Projects", "Prepared", "Intermediates", "HRTF", "MeshEdits", "Manual PPM"} or (self.prefix and self.prefix.startswith(relative + "/")):
                        directories.add(relative)
                        visit(path)
                elif classify(name) and path.is_file():
                    files[relative] = stamp(path)
        visit(self.root)
        return files, directories

    def reconcile(self):
        self.slurm_jobs = release_finished_slurm_jobs(self.root)
        files, directories = self.scan()
        owned = self.doc["Files"]
        known = self.doc["Directories"]
        pending = self.doc.get("Pending")
        if pending:
            stage = stage_name(pending["Stage"])
            awaiting_slurm = stage == "Numcalc" and bool(self.slurm_jobs)
            for relative, now in files.items():
                before = pending["Before"].get(relative)
                if before and (all(before[k] == now[k] for k in now) or any(owned.get(relative, {}).get(k) != before[k] for k in now)):
                    continue
                producer = classify(self.normalized(relative))
                if stage in ("Scan-Preparation", "Inference", "Postprocessing") and producer != stage:
                    continue
                current = owned.get(relative)
                if current and current["Stage"] == producer and all(current[k] == now[k] for k in now):
                    continue
                try:
                    owned[relative] = fingerprint(self.root / relative, producer)
                except OSError:
                    if not awaiting_slurm:
                        raise
            if not awaiting_slurm:
                self.doc["Pending"] = None
        for mapping in (owned, known):
            for relative in list(mapping):
                path = self.safe(relative)
                if path and not self.protected(path) and not path.exists():
                    del mapping[relative]
        for relative, entry in owned.items():
            for parent in Path(relative).parents:
                key = parent.as_posix()
                if key in directories and (key not in known or STAGES.index(entry["Stage"]) < STAGES.index(known[key])):
                    known[key] = entry["Stage"]
        for relative in directories - known.keys():
            stage = classify(self.normalized(relative), DIRECTORIES)
            if stage and not any((self.root / relative).iterdir()):
                known[relative] = stage
        return files, directories

    def begin(self, stage):
        files, directories = self.reconcile()
        if self.slurm_jobs and stage != "Numcalc":
            raise RuntimeError(slurm_busy_message(self.slurm_jobs))
        for path in self.inputs:
            if path.is_relative_to(self.root):
                name = self.normalized(path.relative_to(self.root).as_posix())
                if name.split("/")[0].casefold() in EDITOR_FOLDERS:
                    continue
                if classify(name) == stage or classify(name, DIRECTORIES) == stage or (stage == "Preprocessing" and name.startswith("Projects/")):
                    raise ValueError(f"Stage would overwrite an input: {path}")
        if not self.doc.get("Pending"):
            self.doc["Pending"] = {"Token": uuid.uuid4().hex, "Stage": stage, "Before": {k: dict(v, Stage=stage, Sha256="") for k, v in files.items()}, "Directories": sorted(directories)}
        write_json(self.root / MANIFEST_RELATIVE, self.doc)

    def reset(self, boundary):
        result = dict(deleted=0, protectedInputs=0, modified=0, nonEmpty=0, errors=0)
        files = self.doc["Files"]
        known = self.doc["Directories"]
        for directory, entries in ((False, files), (True, known)):
            for relative in sorted(entries, key=len, reverse=True):
                entry = entries[relative]
                stage = entry if directory else entry["Stage"]
                if boundary and STAGES.index(stage) < STAGES.index(boundary):
                    continue
                name = self.normalized(relative)
                if name.split("/")[0].casefold() in EDITOR_FOLDERS:
                    continue
                path = self.safe(relative)
                if not path or not classify(name, DIRECTORIES if directory else FILES):
                    continue
                if self.protected(path) or directory and any(p.is_relative_to(path) for p in self.inputs):
                    result["nonEmpty" if directory else "protectedInputs"] += 1
                    continue
                try:
                    if path.exists():
                        if directory:
                            if any(path.iterdir()):
                                result["nonEmpty"] += 1
                                continue
                            path.rmdir()
                        else:
                            actual = fingerprint(path, stage)
                            if actual["Sha256"] != entry["Sha256"].upper():
                                result["modified"] += 1
                                continue
                            if self.safe(relative) is None or stamp(path)["ModifiedUtcTicks"] != actual["ModifiedUtcTicks"]:
                                raise OSError("Output changed during reset")
                            path.unlink()
                            result["deleted"] += 1
                    del entries[relative]
                except OSError:
                    result["errors"] += 1
        external = self.root / ".pinna2hrtf/external-sofa-outputs.json"
        if external.is_file() and self.destination:
            if external.is_symlink():
                raise ValueError("Linked SOFA ownership file")
            entries = json.loads(external.read_text(encoding="utf-8-sig"))
            for filename, digest in list(entries.items()):
                path = Path(filename)
                if not path.is_absolute() or not path.is_relative_to(self.destination):
                    result["protectedInputs"] += 1
                    continue
                relative = path.relative_to(self.destination).as_posix()
                if path.resolve() != path or classify("HRTF/" + relative) != "Postprocessing":
                    result["errors"] += 1
                    continue
                if self.protected(path):
                    result["protectedInputs"] += 1
                    continue
                if path.exists():
                    if fingerprint(path, "Postprocessing")["Sha256"] != digest.upper():
                        result["modified"] += 1
                        continue
                    path.unlink()
                    result["deleted"] += 1
                del entries[filename]
            write_json(external, entries)
        return result


@contextmanager
def stage_outputs(config, stage, dry_run):
    if dry_run:
        yield
        return
    stage = stage_name(stage)
    root = config.paths.output_dir
    token = os.environ.get("PINNA2HRTF_OUTPUT_TOKEN")
    if token:
        pending = _read_output_manifest(root).get("Pending") or {}
        if pending.get("Token") != token or pending.get("Stage") != stage:
            raise RuntimeError("The stage output reservation has expired")
        yield
        return
    inputs = [p for p in (config.paths.left_ear, config.paths.right_ear, config.scan_preparation.scan_path, config.scan_preparation.original_scan_path,
                          config.inference.model_config_file, config.inference.model_checkpoint) if p]
    store = Outputs({"root": str(root), "inputs": inputs, "output_folder": config.postprocessing.output_sofa_dir})
    with store.locked():
        store.begin(stage)
        try:
            yield
        finally:
            store.reconcile()
            write_json(root / MANIFEST_RELATIVE, store.doc)


def execute(command):
    action = command["action"]
    if action not in {"record", "status", "reset"}:
        raise ValueError("Unknown output operation")
    store = Outputs(command)
    with store.locked():
        store.reconcile()
        if action == "record":
            for entry in command["paths"]:
                path = Path(entry).resolve()
                if not path.is_relative_to(store.root):
                    continue
                relative = path.relative_to(store.root).as_posix()
                stage = classify(store.normalized(relative))
                if not stage or not store.safe(relative) or store.protected(path) or not path.is_file():
                    continue
                if relative.startswith("Manual PPM/Templates/") and relative in store.doc["Files"]:
                    continue
                store.doc["Files"][relative] = fingerprint(path, stage)
            store.reconcile()
        write_json(store.root / MANIFEST_RELATIVE, store.doc)
        if action == "reset":
            boundary = stage_name(command["stage"]) if command.get("stage") else None
            if store.slurm_jobs and boundary != "Postprocessing":
                raise RuntimeError(slurm_busy_message(store.slurm_jobs))
            result = store.reset(boundary)
            write_json(store.root / MANIFEST_RELATIVE, store.doc)
            return result
        return {"stages": sorted({entry["Stage"] for entry in store.doc["Files"].values()}),
                "slurmJobs": [{"side": job["Side"], "jobId": job["JobId"], "state": job["State"], "submitted": job.get("SubmittedUtc")} for job in store.slurm_jobs]}


def serve():
    request = json.loads(sys.stdin.readline())
    store = Outputs(request)
    with store.locked():
        store.begin(stage_name(request["stage"]))
        print(json.dumps({"ready": True, "token": store.doc["Pending"]["Token"]}), flush=True)
        line = sys.stdin.readline()
        if line and json.loads(line).get("action") == "complete":
            store.reconcile()
            write_json(store.root / MANIFEST_RELATIVE, store.doc)
            print('{"complete": true}', flush=True)
