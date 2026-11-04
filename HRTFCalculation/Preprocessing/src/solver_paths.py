"""Keep NumCalc's whitespace-delimited mesh paths portable."""
import hashlib
from pathlib import Path
import re


def normalize_solver_grid_paths(project):
    project = Path(project)
    grids = project / "EvaluationGrids"
    if not grids.is_dir():
        return
    for folder in list(grids.iterdir()):
        if not folder.is_dir() or re.fullmatch(r"[A-Za-z0-9_.-]+", folder.name):
            continue
        original = folder.name
        alias = "Grid_" + hashlib.sha256(original.encode("utf-8")).hexdigest()[:12]
        destination = grids / alias
        if destination.exists():
            raise FileExistsError(f"Evaluation-grid alias already exists: {destination}")
        folder.rename(destination)
        for source in project.glob("NumCalc/source_*/NC.inp"):
            text = source.read_text(encoding="utf-8")
            text = text.replace("EvaluationGrids/" + original + "/", "EvaluationGrids/" + alias + "/")
            text = text.replace("EvaluationGrids\\" + original + "\\", "EvaluationGrids/" + alias + "/")
            source.write_text(text, encoding="utf-8")
        parameters = project / "parameters.json"
        if parameters.is_file():
            # Mesh2HRTF uses this label to locate and name the output grid.
            import json
            data = json.loads(parameters.read_text(encoding="utf-8"))
            def replace(value):
                if isinstance(value, dict):
                    return {key: replace(item) for key, item in value.items()}
                if isinstance(value, list):
                    return [replace(item) for item in value]
                return alias if value == original else value
            parameters.write_text(json.dumps(replace(data), indent=4), encoding="utf-8")
