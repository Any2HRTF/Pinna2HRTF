import argparse
import hashlib
import json
import os
import re
import sys
import trimesh
import tempfile
import subprocess
import shutil
from datetime import datetime
from pathlib import Path

from .src.create_head import head
from .src.ear_canal_closer import ear_canal_closer, estimate_ear_canal_position
from .src.cut_eararea import cut_eararea, cut_eararea_projected_footprint
from HRTFCalculation.Config import PreprocessingConfig
from HRTFCalculation.Geometry import resolve_geometry, boundary_y, needs_distance_warning
from HRTFCalculation.LiveEvents import emit_live_event



def pinna_y_center(ear):
    return boundary_y(ear)


def _is_generated_project(path, protected_paths):
    """True if path looks like a Mesh2HRTF project written by this step and holds no user input."""
    path = Path(path).resolve()
    if any(path == protected or path in protected.parents for protected in protected_paths):
        return False
    return path.is_dir() and (path / "parameters.json").is_file()


EXPORT_RECORD = ".pinna2hrtf-export.json"
# Exact names of files NumCalc, Pinna2HRTF's NumCalc runner and Mesh2HRTF's
# Output2HRTF add to a project after export (see NC_Main.cpp, NumCalc.py,
# output2hrtf.py, write_output_report.py, inspect_sofa_files.py, export_vtk.py).
# Any other unrecorded file means the backup is kept.
_NUMCALC_OUTPUT = re.compile(
    r"^NumCalc/source_\d+/("
    r"be\.out/be\.\d+/(pBoundary|pBoundaryVTK\.vtk|pEvalGrid|vBoundary|vEvalGrid)"
    r"|NC\d+-\d+\.out|NCfrom\d+\.out|NCuntil\d+\.out|NC\.out|Memory\.txt|NC\d+-\d+_log\.txt"
    r")$"
)
_OUTPUT2HRTF_FIXED = re.compile(r"^Output2HRTF/(report_source_\d+\.csv|report_issues\.txt|vtk/[^/]+/frequency_step_\d+\.vtk)$")


def _is_solver_output(name, grids):
    """True only for the exact file names the solver tools write; grids are the project's recorded evaluation grids."""
    if _NUMCALC_OUTPUT.match(name) or _OUTPUT2HRTF_FIXED.match(name):
        return True
    for grid in grids:
        for kind in ("HRTF", "HRIR"):
            stem = re.escape(f"{kind}_{grid}")
            if re.match(rf"^Output2HRTF/{stem}(\.sofa|_2D\.pdf|_3D_(horizontal|median|frontal)_plane\.jpeg)$", name):
                return True
    return False


def _backup_fingerprint(backup):
    """Identity of a backup's contents: every file's path, size and modification time."""
    digest = hashlib.sha256()
    files, other = _project_files(backup)
    for name in sorted(files + other):
        info = (Path(backup) / name).lstat()
        digest.update(f"{name}\0{info.st_size}\0{info.st_mtime_ns}\0{info.st_mode}\n".encode())
    return digest.hexdigest()


def _project_files(root):
    """Relative POSIX paths of everything below root; links and special files are reported as such."""
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


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def _write_export_record(project):
    """Record every file of a freshly generated project so a later backup can be checked for changes."""
    files, _ = _project_files(project)
    record = {"version": 1, "files": {name: _sha256(project / name) for name in sorted(files) if name != EXPORT_RECORD}}
    temporary = project / (EXPORT_RECORD + ".tmp")
    temporary.write_text(json.dumps(record, indent=1), encoding="utf-8")
    os.replace(temporary, project / EXPORT_RECORD)


def snapshot_generated_outputs(project):
    """State before Output2HRTF writes into a recorded project, or None if it has no record.

    Returns (record, existing names, recorded Output2HRTF files still unchanged).
    """
    project = Path(project)
    try:
        record = json.loads((project / EXPORT_RECORD).read_text(encoding="utf-8"))
        recorded = record["files"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    files, _ = _project_files(project)
    unchanged = {name for name in files if name.startswith("Output2HRTF/") and name in recorded and _sha256(project / name) == recorded[name]}
    return record, set(files), unchanged


def claim_generated_outputs(project, snapshot):
    """Record Output2HRTF files this run wrote, so an unchanged backup can later be replaced.

    Only new files, or files that were recorded and unchanged before the run, are
    claimed; pre-existing unrecorded or edited files stay unrecorded and keep the backup.
    """
    if snapshot is None:
        return
    project = Path(project)
    record, existing, unchanged = snapshot
    recorded = record["files"]
    grids = {name.split("/")[1] for name in recorded if name.startswith("EvaluationGrids/") and name.count("/") >= 2}
    files, _ = _project_files(project)
    for name in files:
        if _is_solver_output(name, grids) and (name not in existing or name in unchanged):
            recorded[name] = _sha256(project / name)
    temporary = project / (EXPORT_RECORD + ".tmp")
    temporary.write_text(json.dumps(record, indent=1), encoding="utf-8")
    os.replace(temporary, project / EXPORT_RECORD)


PREVIOUS_RECORD = ".pinna2hrtf-previous.json"


def _read_previous_record(folder):
    """Fingerprints of the <name>.previous intermediate copies as Pinna2HRTF made them."""
    try:
        record = json.loads((Path(folder) / PREVIOUS_RECORD).read_text(encoding="utf-8"))
        return {str(name): str(digest) for name, digest in record["files"].items()}
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}


def _write_previous_record(folder, record):
    temporary = Path(folder) / (PREVIOUS_RECORD + ".tmp")
    temporary.write_text(json.dumps({"version": 1, "files": record}, indent=1), encoding="utf-8")
    os.replace(temporary, Path(folder) / PREVIOUS_RECORD)


def previous_backup_path(destination):
    return Path(f"{destination}.previous")


def _folder_size(root):
    total = 0
    for dirpath, _, filenames in os.walk(root):
        for name in filenames:
            try:
                total += (Path(dirpath) / name).lstat().st_size
            except OSError:
                pass
    return total


def _format_size(size):
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024 or unit == "GB":
            return f"{size:.0f} {unit}" if unit == "B" else f"{size:.1f} {unit}"
        size /= 1024


def inspect_previous_backup(backup, protected_paths=()):
    """Whether an older export backup holds only unchanged generated files and may be deleted.

    Returns (deletable, reason). Unknown files, changed or missing recorded files,
    links, a missing record, or an input mesh inside the folder all keep it.
    """
    backup = Path(backup)
    if backup.is_symlink() or not backup.is_dir():
        return False, "it is not a regular folder"
    resolved = backup.resolve()
    if any(resolved == path or resolved in path.parents for path in protected_paths):
        return False, "it contains an input mesh"
    try:
        recorded = json.loads((backup / EXPORT_RECORD).read_text(encoding="utf-8"))["files"]
    except (OSError, ValueError, KeyError, TypeError):
        return False, "it has no Pinna2HRTF export record"
    files, other = _project_files(backup)
    if other:
        return False, f"it contains links or special files ({other[0]})"
    present = set(files) - {EXPORT_RECORD}
    for name, digest in recorded.items():
        if name not in present:
            return False, f"a generated file was removed ({name})"
        if _sha256(backup / name) != digest:
            return False, f"a generated file was changed ({name})"
    unknown = sorted(present - set(recorded))
    if unknown:
        return False, f"it contains files Pinna2HRTF did not generate ({unknown[0]})"
    return True, "only unchanged generated files"


def _kept_backup_path(destination):
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    candidate = Path(f"{destination}.previous-{stamp}")
    counter = 1
    while candidate.exists() or candidate.is_symlink():
        counter += 1
        candidate = Path(f"{destination}.previous-{stamp}-{counter}")
    return candidate


def plan_export_backups(destinations, protected_paths, logger=print):
    """Describe what publishing will do with existing backups, before any work starts.

    Returns the backups that will be deleted as (path, size, fingerprint); the caller
    must confirm those and pass {str(path): fingerprint} to _publish_export_projects.
    """
    replace = []
    for destination in destinations.values():
        for old in sorted(destination.parent.glob(f".{destination.name}.pinna2hrtf-backup-*")):
            logger(f"Note: an export backup from an earlier version is kept at {old}. Remove it yourself when it is no longer needed.")
        if not destination.exists():
            continue
        backup = previous_backup_path(destination)
        if not (backup.exists() or backup.is_symlink()):
            logger(f"The current project {destination} will be kept as {backup}.")
            continue
        deletable, reason = inspect_previous_backup(backup, protected_paths)
        if deletable:
            replace.append((backup, _folder_size(backup), _backup_fingerprint(backup)))
        else:
            logger(f"Warning: the older backup {backup} will be kept because {reason}. "
                   f"It will be moved to {destination}.previous-<date> so the current project can become the new backup.")
    return replace


def _publish_export_projects(staged, destinations, protected_paths, logger=print, approved_backups=None):
    """Swap freshly generated projects into place, keeping one previous export per ear.

    Each replaced project becomes <destination>.previous. An older .previous is
    deleted only if the user confirmed exactly that folder (same fingerprint as in
    approved_backups) and it still holds just unchanged generated files; otherwise
    it is kept as <destination>.previous-<date>. If any move fails, every move is undone,
    so both ears stay on the same export.
    """
    for destination in destinations.values():
        if destination.exists() and not _is_generated_project(destination, protected_paths):
            raise FileExistsError(f"Refusing to replace {destination}: it is not a Mesh2HRTF project generated by Pinna2HRTF or it contains input files.")
    approved_backups = approved_backups or {}
    moves = []
    retired = {}

    def move(source, target):
        source.rename(target)
        moves.append((source, target))

    try:
        for side, destination in destinations.items():
            source = staged.get(side)
            if destination.exists():
                backup = previous_backup_path(destination)
                if backup.exists() or backup.is_symlink():
                    holder = Path(tempfile.mkdtemp(prefix=f".{backup.name}-retiring-", dir=backup.parent))
                    retired[side] = holder / backup.name
                    move(backup, retired[side])
                move(destination, backup)
            if source is not None:
                move(source, destination)
    except BaseException:
        for source, target in reversed(moves):
            target.rename(source)
        for retiring in retired.values():
            try:
                retiring.parent.rmdir()
            except OSError:
                pass
        raise
    for side, retiring in retired.items():
        destination = destinations[side]
        # Check again: the folder may have changed or been replaced while the
        # projects were built. Only the exact folder the user confirmed is deleted.
        approved = approved_backups.get(str(previous_backup_path(destination)))
        if approved is None:
            deletable, reason = False, "it was not among the backups you confirmed for deletion"
        elif _backup_fingerprint(retiring) != approved:
            deletable, reason = False, "it changed after you confirmed its deletion"
        else:
            deletable, reason = inspect_previous_backup(retiring, protected_paths)
        if deletable:
            shutil.rmtree(retiring.parent)
            logger(f"Deleted the older backup of {destination}; {previous_backup_path(destination)} now holds the previous export.")
        else:
            kept = _kept_backup_path(destination)
            retiring.rename(kept)
            retiring.parent.rmdir()
            logger(f"Warning: kept the older backup at {kept} because {reason}.")


def reposition_ears_laterally(ears, translations):
    for side, ear in ears.items():
        if ear is not None:
            ear.apply_translation(translations[side])


def run_preprocessing_pipeline(left_path, right_path, mesh_grading_executable, mesh2hrtf_path, evaluation_grid, preprocessing=None, output_dir=None, export_path=None, logger=print, confirm_replace_previous=None):
    settings = preprocessing or PreprocessingConfig()
    if output_dir is None and export_path is None:
        raise ValueError("output_dir or export_path is required")
    left_path = Path(left_path) if left_path else None
    right_path = Path(right_path) if right_path else None
    if left_path is None and right_path is None:
        raise ValueError("At least one ear mesh is required")
    # Inspect and validate before cleaning any previous output.
    left_ear = trimesh.load(left_path, force="mesh") if left_path is not None else None
    right_ear = trimesh.load(right_path, force="mesh") if right_path is not None else None
    ears = {"left": left_ear, "right": right_ear}
    geometry = resolve_geometry(ears, settings)
    if needs_distance_warning(geometry["ear_distance"]):
        logger(f"Warning: ear distance from head center is {geometry['ear_distance']:.3f} mm (50 mm or less). This will produce a very small head.")
    if output_dir is not None:
        output_dir = Path(output_dir)
        projects_dir = output_dir / "Projects"
        left_project = projects_dir / "Left"
        right_project = projects_dir / "Right"
        legacy_projects = [projects_dir / "project-Left", projects_dir / "project-Right"]
        intermediates = output_dir / "Intermediates"
        entries = list(output_dir.iterdir()) if output_dir.exists() else []
        legacy_intermediates = next((entry for entry in entries if entry.name == "intermediates"), None)
        current_intermediates = next((entry for entry in entries if entry.name == "Intermediates"), None)
        if legacy_intermediates is not None and current_intermediates is None:
            migration_path = output_dir / ".pinna2hrtf-intermediates-migration"
            legacy_intermediates.rename(migration_path)
            migration_path.rename(intermediates)
        elif legacy_intermediates is not None and current_intermediates is not legacy_intermediates:
            legacy_intermediates.rename(_kept_backup_path(legacy_intermediates))
        # One previous export per ear. The desktop/config route cannot prompt, so
        # an older backup is approved for deletion only when it holds unchanged
        # generated files; it is checked again before deletion. Anything else is
        # kept as <project>.previous-<date>.
        protected = [path.resolve() for path in (left_path, right_path) if path is not None]
        to_replace = plan_export_backups({"left": left_project, "right": right_project}, protected, logger)
        approved_backups = {str(path): fingerprint for path, _, fingerprint in to_replace}
    else:
        export_prefix = Path(export_path)
        left_project = Path(f"{export_prefix}-Left")
        right_project = Path(f"{export_prefix}-Right")
        legacy_projects = []
        intermediates = Path(f"{export_prefix}-Intermediates")
        # Fail before any work if an existing export target is not ours to replace.
        protected = [path.resolve() for path in (left_path, right_path) if path is not None]
        for project in (left_project, right_project):
            if project.exists() and not _is_generated_project(project, protected):
                raise FileExistsError(f"Refusing to replace {project}: it is not a Mesh2HRTF project generated by Pinna2HRTF or it contains input files.")
        to_replace = plan_export_backups({"left": left_project, "right": right_project}, protected, logger)
        if to_replace:
            listing = "\n".join(f"  {path} ({_format_size(size)})" for path, size, _ in to_replace)
            question = ("Only one previous export is kept per ear. These older backups hold only unchanged "
                        f"generated files and will be deleted after the new export succeeds:\n{listing}")
            if confirm_replace_previous is None:
                raise FileExistsError(question + "\nCopy anything you need, then rerun with --replace-previous-backup.")
            if not confirm_replace_previous(question):
                raise RuntimeError("Cancelled: the older export backups were left unchanged.")
        approved_backups = {str(path): fingerprint for path, _, fingerprint in to_replace}
    # Preserve legacy and previous intermediate files; these folders can hold
    # inputs, inference results and files changed outside the app.
    protected = [path.resolve() for path in (left_path, right_path) if path is not None]
    def is_input(path):
        resolved = path.resolve()
        return any(resolved == selected or resolved in selected.parents for selected in protected)

    def archive(path, keep_one=False):
        if not path.exists():
            return
        if is_input(path):
            raise FileExistsError(f"Refusing to replace an input: {path}")
        previous = Path(f"{path}.previous")
        # A .previous that is or holds a selected input is never moved or replaced.
        if keep_one and not path.is_symlink() and path.is_file() and not ((previous.exists() or previous.is_symlink()) and is_input(previous)):
            # Generated intermediate file: keep one previous copy. The older copy
            # is replaced only if it still matches the fingerprint recorded when
            # it was made; an edited, unrecorded or unusual one is kept dated.
            target = previous
            record = _read_previous_record(path.parent)
            if target.exists() or target.is_symlink():
                expected = record.get(target.name)
                unchanged = (expected is not None and not target.is_symlink() and target.is_file()
                             and _sha256(target) == expected)
                if not unchanged:
                    kept = _kept_backup_path(path)
                    target.rename(kept)
                    logger(f"Kept an older or edited copy at {kept}")
            digest = _sha256(path)
            path.replace(target)
            record[target.name] = digest
            _write_previous_record(path.parent, record)
        else:
            target = _kept_backup_path(path)
            path.rename(target)
        logger(f"Kept previous output at {target}")
    side_dirs = {"left": intermediates / "Left", "right": intermediates / "Right"}
    for name in ["Prediction STL Left", "Prediction STL Right", "Prediction Parameters Left", "Prediction Parameters Right", "ICP STL Left", "ICP STL Right"]:
        legacy_path = intermediates / name
        if legacy_path.is_dir():
            archive(legacy_path)
    entries = list(intermediates.iterdir()) if intermediates.exists() else []
    for side in ("left", "right"):
        legacy_side = next((entry for entry in entries if entry.name == side), None)
        current_side = next((entry for entry in entries if entry.name == side.title()), None)
        if legacy_side is not None and current_side is None:
            migration_path = intermediates / f".pinna2hrtf-{side}-migration"
            legacy_side.rename(migration_path)
            migration_path.rename(side_dirs[side])
        elif legacy_side is not None and current_side is not legacy_side:
            archive(legacy_side)
    if settings.write_intermediates:
        work_dir = intermediates
        work_dir.mkdir(parents=True, exist_ok=True)
        generated_names = ["input_ear.stl", "source_landmark.json", "closed_ear.stl", "cut_head.stl", "stitched_head.stl", "graded_head.ply", "dummy_head.stl"]
        for side, path in (("left", left_path), ("right", right_path)):
            side_dir = side_dirs[side]
            if side_dir.exists():
                for name in generated_names:
                    generated_path = side_dir / name
                    if generated_path.exists():
                        archive(generated_path, keep_one=True)
            if path is not None:
                side_dir.mkdir(parents=True, exist_ok=True)
            elif side_dir.exists():
                # Preserve inference results and unfamiliar files. An unused side
                # directory is removed only when no such content remains.
                try:
                    side_dir.rmdir()
                except OSError:
                    pass
        archive(work_dir / "dummy_head.stl", keep_one=True)
        cleanup = None
    else:
        cleanup = tempfile.TemporaryDirectory()
        work_dir = Path(cleanup.name)
        side_dirs = {"left": work_dir / "Left", "right": work_dir / "Right"}
        for side, path in (("left", left_path), ("right", right_path)):
            if path is not None:
                side_dirs[side].mkdir(parents=True, exist_ok=True)
    export_staging = None
    try:
        emit_live_event("Loading selected ear meshes")
        logger("Loading input ear meshes")
        translations = {side: geometry["translations"].get(side, (0., 0., 0.)) for side in ears}
        reposition_ears_laterally(ears, translations)
        logger(f"Ear distance from head center (mm): left={geometry['ear_distance_left']}, right={geometry['ear_distance_right']}")
        for side, ear in ears.items():
            if ear is not None:
                ear.export(side_dirs[side] / "input_ear.stl")
        closed = {side: side_dirs[side] / "closed_ear.stl" for side, ear in ears.items() if ear is not None}
        landmark_paths = {side: side_dirs[side] / "source_landmark.json" for side, ear in ears.items() if ear is not None}
        # The dummy head is shared by both sides. Keeping it at the work root
        # avoids creating an artificial Left folder for a right-only project.
        dummy_head = work_dir / "dummy_head.stl"
        cut = {side: side_dirs[side] / "cut_head.stl" for side, ear in ears.items() if ear is not None}
        stitched = {side: side_dirs[side] / "stitched_head.stl" for side, ear in ears.items() if ear is not None}
        graded = {side: side_dirs[side] / "graded_head.ply" for side, ear in ears.items() if ear is not None}
        landmarks = {}
        for side, ear in ears.items():
            if ear is None:
                continue
            source_position = settings.source_position_left if side == "left" else settings.source_position_right
            source_position_input = settings.source_position_input_left if side == "left" else settings.source_position_input_right
            if source_position is None and source_position_input is not None:
                source_position = tuple(coordinate + translation for coordinate, translation in zip(source_position_input, translations[side]))
            landmarks[side] = {"position": list(source_position), "method": "configured", "confidence": 1.0} if source_position is not None else estimate_ear_canal_position(ear, side=side)
            method = "using the saved position" if landmarks[side]["method"] == "configured" else "estimating the source position"
            emit_live_event(f"{side.title()} ear · {method}")
            with open(landmark_paths[side], "w") as f:
                json.dump(landmarks[side], f, indent=2)
            logger(f"{side.title()} source landmark: {landmarks[side]['method']} at {[round(v, 3) for v in landmarks[side]['position']]}, confidence {landmarks[side]['confidence']:.2f}")
        logger("Closing ear canals")
        for side, ear in ears.items():
            if ear is not None:
                emit_live_event(f"{side.title()} ear · Closing the ear canal")
                ear_canal_closer(ear, mode=settings.ear_canal_closer_mode).export(closed[side])
        emit_live_event("Building the dummy head")
        logger("Creating dummy head mesh")
        head(
            left_ear,
            right_ear,
            dummy_head,
            radius_scale=settings.head_radius_scale,
            width_scale=settings.head_width_scale,
            height_scale=settings.head_height_scale,
            y_deformation=settings.head_y_deformation,
            adaptive_ovalness=settings.head_adaptive_ovalness,
            ovalness_strength=settings.head_ovalness_strength,
            min_width_scale=settings.head_min_width_scale,
            max_height_scale=settings.head_max_height_scale,
        )
        emit_live_event("Cutting ear areas from the head mesh")
        logger("Cutting ear areas from dummy head")
        dummy_head_mesh = trimesh.load(dummy_head, process=False, force="mesh")
        closed_meshes = {
            side: trimesh.load(closed[side], process=False, force="mesh")
            for side, ear in ears.items()
            if ear is not None
        }
        for side, ear in ears.items():
            if ear is None:
                continue
            head_mesh = dummy_head_mesh.copy()
            ear_mesh = closed_meshes[side]
            if settings.ear_cut_mode == "projected_footprint":
                result = cut_eararea_projected_footprint(head_mesh, ear_mesh, projected_cut_margin=settings.projected_cut_margin, side=side)
            else:
                result = cut_eararea(head_mesh, ear_mesh, ear_cut_clearance_scale=settings.ear_cut_clearance_scale, side=side, mode=settings.ear_cut_mode)
            result.export(cut[side])
        from .src.head_stitcher import head_stitcher
        for side, ear in ears.items():
            if ear is None:
                continue
            emit_live_event(f"{side.title()} ear · Joining ear to head")
            logger(f"Stitching {side} ear to head")
            head_stitcher(head_path=str(cut[side]), ear_path=str(closed[side]), export_path=str(stitched[side]), seam_smoothing_iterations=settings.seam_smoothing_iterations, seam_smoothing_factor=settings.seam_smoothing_factor)
            emit_live_event(f"{side.title()} mesh · Grading (this may take several minutes)")
            logger(f"Grading {side} head mesh; this can take several minutes")
            gamma_l = settings.mesh_gamma if side == "left" else settings.mesh_gamma_opposite
            gamma_r = settings.mesh_gamma_opposite if side == "left" else settings.mesh_gamma
            grading_env = os.environ.copy()
            grading_env["DYLD_LIBRARY_PATH"] = os.pathsep.join(filter(None, [str(Path(mesh_grading_executable).parent), grading_env.get("DYLD_LIBRARY_PATH")]))
            subprocess.run([str(mesh_grading_executable), '-x', str(settings.mesh_min_edge_length), '-y', str(settings.mesh_max_edge_length), '-e', str(settings.mesh_max_error), '-v', '-g', str(gamma_l), '-h', str(gamma_r), '-s', side, '-i', str(stitched[side]), '-o', str(graded[side])], check=True, env=grading_env)
        # Both app/config and standalone exports publish only after every side
        # has been generated. Existing projects are retained, including unknown
        # or externally modified files. Older backups are deleted only when
        # approved above and still unchanged at publication.
        export_destinations = {"left": left_project, "right": right_project}
        left_project.parent.mkdir(parents=True, exist_ok=True)
        export_staging = Path(tempfile.mkdtemp(prefix=f".{left_project.name}-staging-", dir=left_project.parent))
        left_project = export_staging / "Left"
        right_project = export_staging / "Right"
        from .src.material_assign_and_mesh2input import main as mesh2input_main
        projects = {"left": left_project, "right": right_project}
        source_types = {"left": settings.source_type_left, "right": settings.source_type_right}
        for side, ear in ears.items():
            if ear is None:
                continue
            emit_live_event(f"{side.title()} ear · Creating Mesh2HRTF project")
            logger(f"Creating {side} Mesh2HRTF project")
            mesh2input_main(
                head=str(graded[side]), title=settings.title, source_type=source_types[side], filepath=str(projects[side]), mesh2hrtf_path=str(mesh2hrtf_path), evaluationGrids=str(evaluation_grid), method=settings.method, pictures=settings.pictures, reference=settings.reference, computeHRIRs=settings.compute_hrirs, unit=settings.unit, speedOfSound=settings.speed_of_sound, densityOfMedium=settings.air_density, materialSearchPaths=settings.material_search_paths, min_frequency=settings.min_frequency, max_frequency=settings.max_frequency, frequency_vector_type=settings.frequency_vector_type, frequency_step_count=settings.frequency_step_count, tolerance=settings.source_assignment_tolerance, source_position=landmarks[side]["position"], source_assignment_mode=settings.source_assignment_mode, source_face_count=settings.source_assignment_face_count,
            )
            if os.name == "nt":
                from .src.solver_paths import normalize_solver_grid_paths
                normalize_solver_grid_paths(projects[side])
            if landmarks[side]["method"] == "configured":
                parameters_path = projects[side] / "parameters.json"
                with parameters_path.open("r", encoding="utf-8") as file:
                    parameters = json.load(file)
                unit_factor = {"m": 1.0, "dm": 0.1, "cm": 0.01, "mm": 0.001}[settings.unit]
                parameters["sourceCenter"] = [coordinate * unit_factor for coordinate in landmarks[side]["position"]]
                with parameters_path.open("w", encoding="utf-8") as file:
                    json.dump(parameters, file, indent=4)
                logger(f"Set {side} receiver position exactly to {parameters['sourceCenter']} m")
        if export_staging is not None:
            protected = [path.resolve() for path in (left_path, right_path) if path is not None]
            for side, ear in ears.items():
                if ear is not None:
                    _write_export_record(projects[side])
            _publish_export_projects({side: projects[side] for side, ear in ears.items() if ear is not None}, export_destinations, protected, logger, approved_backups)
            projects = export_destinations
        emit_live_event("Mesh2HRTF projects are ready")
        logger(f"Preprocessing completed: {', '.join(str(projects[side]) for side, ear in ears.items() if ear is not None)}")
    finally:
        if cleanup is not None:
            cleanup.cleanup()
        if export_staging is not None:
            shutil.rmtree(export_staging, ignore_errors=True)


def preprocess():
    parser = argparse.ArgumentParser(description="Run preprocessing from ears to Mesh2HRTF project folders.")
    parser.add_argument('--left-path', type=str, help='Path to left ear mesh.')
    parser.add_argument('--right-path', type=str, help='Path to right ear mesh.')
    parser.add_argument('--export-path', type=str, required=True,  help='Path to exported Mesh2HRTF Project.')
    parser.add_argument('--mesh-grading-executable', type=str, required=True, help='Path to the mesh_grading executable.')
    parser.add_argument('--Mesh2HRTF-path', type=str, required=True, help='Path to the location of the mesh2hrtf directory.')
    parser.add_argument('--Mesh2HRTF-Evaluation-Grid', type=str, default='Default', help='Name or path of the evaluation grid to be used for Mesh2HRTF.')
    parser.add_argument('--ear-cut-clearance-scale', type=float, default=1.3)
    parser.add_argument('--ear-cut-mode', choices=['ellipse', 'projected_footprint', 'exact'], default='ellipse')
    parser.add_argument('--ear-canal-closer-mode', choices=['legacy', 'interpolated'], default='legacy')
    parser.add_argument('--head-radius', type=float, default=None, help='Deprecated alias for --ear-distance; removed in a future release.')
    parser.add_argument('--ear-distance', type=float, help='Mean ear distance from head center in mm; preserves left/right asymmetry.')
    parser.add_argument('--min-frequency', type=int, default=0)
    parser.add_argument('--max-frequency', type=int, default=24000)
    parser.add_argument('--frequency-step-count', type=int, default=129)
    parser.add_argument('--source-face-count', type=int, default=6)
    parser.add_argument('--replace-previous-backup', action='store_true',
                        help='Allow deleting an older export backup that holds only unchanged generated files. Without it you are asked interactively.')
    args = parser.parse_args()
    if args.head_radius is not None and args.ear_distance is not None:
        parser.error('--head-radius cannot be combined with --ear-distance.')
    if not args.left_path and not args.right_path:
        parser.error('At least one ear mesh path is required.')
    settings = PreprocessingConfig(
        ear_cut_clearance_scale=args.ear_cut_clearance_scale,
        ear_cut_mode=args.ear_cut_mode,
        ear_canal_closer_mode=args.ear_canal_closer_mode,
        ear_distance=args.ear_distance if args.ear_distance is not None else args.head_radius,
        min_frequency=args.min_frequency,
        max_frequency=args.max_frequency,
        frequency_step_count=args.frequency_step_count,
        source_assignment_face_count=args.source_face_count,
    )
    # Version compatibility only; remove in a future release.
    if args.head_radius is not None:
        print("Warning: --head-radius is deprecated; use --ear-distance. Removed in a future release.")
    run_preprocessing_pipeline(
        left_path=args.left_path,
        right_path=args.right_path,
        export_path=args.export_path,
        mesh_grading_executable=args.mesh_grading_executable,
        mesh2hrtf_path=args.Mesh2HRTF_path,
        evaluation_grid=args.Mesh2HRTF_Evaluation_Grid,
        preprocessing=settings,
        confirm_replace_previous=_cli_confirmation(args.replace_previous_backup),
    )


def _cli_confirmation(preapproved):
    if preapproved:
        return lambda question: True
    if not sys.stdin.isatty():
        return None

    def ask(question):
        print(question)
        return input("Delete these older backups? [y/N] ").strip().lower() in {"y", "yes"}
    return ask
