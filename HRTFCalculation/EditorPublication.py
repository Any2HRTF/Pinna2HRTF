import json
import os
import shutil
import tempfile
from pathlib import Path

from .FileIdentity import sha256
from .Outputs import Outputs, classify, fingerprint
from .RunConfig import MANIFEST_RELATIVE, _DOTNET_EPOCH_TICKS


def publish(command):
    root = Path(command["root"]).resolve(strict=True)
    if root == root.parent:
        raise ValueError("Choose a project folder")
    store = Outputs({"root": str(root), "inputs": command.get("protected", [])})
    if store.safe(".pinna2hrtf/backups") is None:
        raise ValueError("Linked editor recovery folder")
    with store.locked():
        if store.doc.get("Pending"):
            store.reconcile()
        return _publish_locked(store, command)


def _publish_locked(store, command):
    root = store.root
    document = store.doc
    expected = command.get("expected") or {}
    stamps = command.get("timestamps") or {}
    targets = {}
    for entry in command["files"]:
        supplied = Path(entry["destination"])
        relative = supplied.relative_to(Path(command["root"])).as_posix()
        target = root / relative
        if store.safe(relative) is None or store.protected(target):
            raise ValueError(f"Protected or linked output: {target}")
        if relative.split("/")[0] not in {"Manual PPM", "MeshEdits"} or not classify(relative):
            raise ValueError(f"Unrecognized editor destination: {relative}")
        if target in targets:
            raise ValueError(f"Duplicate editor output: {target}")
        targets[target] = (Path(entry["source"]), stamps.get(str(supplied)))
    if not targets:
        raise ValueError("Specify at least one editor file")

    def validate_inputs():
        for path, digest in expected.items():
            if sha256(path).lower() != digest.lower():
                raise ValueError(f"Editor input changed: {path}")

    validate_inputs()
    backups = root / ".pinna2hrtf" / "backups"
    backups.mkdir(parents=True, exist_ok=True)
    transaction = Path(tempfile.mkdtemp(dir=backups, prefix="editor-"))
    replacements = {}
    previous = {}
    installed = []
    cleanup = True
    try:
        for index, (target, (source, ticks)) in enumerate(targets.items()):
            target.parent.mkdir(parents=True, exist_ok=True)
            staged = transaction / f"{index}.new"
            shutil.copy2(source, staged)
            if ticks is not None:
                os.utime(staged, ns=(staged.stat().st_atime_ns, (int(ticks) - _DOTNET_EPOCH_TICKS) * 100))
            replacements[target] = staged
            relative = target.relative_to(root).as_posix()
            stage = classify(relative)
            entry = fingerprint(staged, stage)
            if relative.startswith("Manual PPM/Templates/") and target.exists():
                prior = document["Files"].get(relative)
                if sha256(target).upper() != entry["Sha256"] or prior and prior["Sha256"].upper() != entry["Sha256"]:
                    raise ValueError(f"Archived template changed: {target}")
            document["Files"][relative] = entry
            for directory in Path(relative).parents:
                if str(directory) != ".":
                    document["Directories"].setdefault(directory.as_posix(), stage)
        manifest = root / MANIFEST_RELATIVE
        replacements[manifest] = transaction / "manifest.new"
        replacements[manifest].write_text(json.dumps(document, indent=2), encoding="utf-8")
        for index, target in enumerate(replacements):
            backup = transaction / f"{index}.bak" if target.exists() else None
            if backup:
                shutil.copy2(target, backup)
            previous[target] = backup
        (transaction / "recovery.json").write_text(json.dumps({str(k): str(v) if v else None for k, v in previous.items()}), encoding="utf-8")
        validate_inputs()
        for target, staged in replacements.items():
            if target.resolve() != target:
                raise ValueError(f"Editor output path changed: {target}")
            os.replace(staged, target)
            installed.append(target)
        validate_inputs()
    except BaseException:
        cleanup = False
        for target in reversed(installed):
            if previous[target]:
                os.replace(previous[target], target)
            else:
                target.unlink(missing_ok=True)
        cleanup = True
        raise
    finally:
        if cleanup:
            shutil.rmtree(transaction)
    return {"files": [str(target) for target in targets]}
