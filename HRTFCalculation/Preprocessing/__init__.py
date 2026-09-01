import argparse
import json
import os
import trimesh
import tempfile
import subprocess
import shutil
from pathlib import Path

from .src.create_head import head
from .src.ear_canal_closer import ear_canal_closer, estimate_ear_canal_position
from .src.cut_eararea import cut_eararea, cut_eararea_projected_footprint
from HRTFCalculation.Config import PreprocessingConfig


def pinna_y_center(ear):
    entities = ear.outline().entities
    if entities:
        outline = max((entity.discrete(ear.vertices) for entity in entities), key=len)
        return float(sum(point[1] for point in outline) / len(outline))
    return float((ear.bounds[0][1] + ear.bounds[1][1]) / 2)


def place_pinnae_at_head_radius(left_ear, right_ear, head_radius):
    translations = {"left": (0.0, 0.0, 0.0), "right": (0.0, 0.0, 0.0)}
    if left_ear is not None:
        translations["left"] = (0.0, head_radius - pinna_y_center(left_ear), 0.0)
        left_ear.apply_translation(translations["left"])
    if right_ear is not None:
        translations["right"] = (0.0, -head_radius - pinna_y_center(right_ear), 0.0)
        right_ear.apply_translation(translations["right"])
    return translations


def run_preprocessing_pipeline(left_path, right_path, mesh_grading_executable, mesh2hrtf_path, evaluation_grid, preprocessing=None, output_dir=None, export_path=None, logger=print):
    settings = preprocessing or PreprocessingConfig()
    if output_dir is None and export_path is None:
        raise ValueError("output_dir or export_path is required")
    left_path = Path(left_path) if left_path else None
    right_path = Path(right_path) if right_path else None
    if left_path is None and right_path is None:
        raise ValueError("At least one ear mesh is required")
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
            shutil.rmtree(legacy_intermediates)
    else:
        export_prefix = Path(export_path)
        left_project = Path(f"{export_prefix}-Left")
        right_project = Path(f"{export_prefix}-Right")
        legacy_projects = []
        intermediates = Path(f"{export_prefix}-Intermediates")
    side_dirs = {"left": intermediates / "Left", "right": intermediates / "Right"}
    for name in ["Prediction STL Left", "Prediction STL Right", "Prediction Parameters Left", "Prediction Parameters Right", "ICP STL Left", "ICP STL Right"]:
        legacy_path = intermediates / name
        if legacy_path.is_dir():
            shutil.rmtree(legacy_path)
    entries = list(intermediates.iterdir()) if intermediates.exists() else []
    for side in ("left", "right"):
        legacy_side = next((entry for entry in entries if entry.name == side), None)
        current_side = next((entry for entry in entries if entry.name == side.title()), None)
        if legacy_side is not None and current_side is None:
            migration_path = intermediates / f".pinna2hrtf-{side}-migration"
            legacy_side.rename(migration_path)
            migration_path.rename(side_dirs[side])
        elif legacy_side is not None and current_side is not legacy_side:
            shutil.rmtree(legacy_side)
    if settings.write_intermediates:
        work_dir = intermediates
        work_dir.mkdir(parents=True, exist_ok=True)
        for side_dir in side_dirs.values():
            side_dir.mkdir(parents=True, exist_ok=True)
            for name in ["input_ear.stl", "source_landmark.json", "closed_ear.stl", "cut_head.stl", "stitched_head.stl", "graded_head.ply", "dummy_head.stl"]:
                path = side_dir / name
                if path.exists():
                    path.unlink()
        for side, path in (("left", left_path), ("right", right_path)):
            if path is not None:
                side_dirs[side].mkdir(parents=True, exist_ok=True)
        cleanup = None
    else:
        cleanup = tempfile.TemporaryDirectory()
        work_dir = Path(cleanup.name)
        side_dirs = {"left": work_dir / "Left", "right": work_dir / "Right"}
        for side, path in (("left", left_path), ("right", right_path)):
            if path is not None:
                side_dirs[side].mkdir(parents=True, exist_ok=True)
    try:
        logger("Loading input ear meshes")
        left_ear = trimesh.load(left_path) if left_path is not None else None
        right_ear = trimesh.load(right_path) if right_path is not None else None
        translations = {"left": (0.0, 0.0, 0.0), "right": (0.0, 0.0, 0.0)}
        if settings.head_radius is not None:
            translations = place_pinnae_at_head_radius(left_ear, right_ear, settings.head_radius)
            logger(f"Placed pinnae at head radius: {settings.head_radius}")
        ears = {"left": left_ear, "right": right_ear}
        for side, ear in ears.items():
            if ear is not None:
                ear.export(side_dirs[side] / "input_ear.stl")
        closed = {side: side_dirs[side] / "closed_ear.stl" for side, ear in ears.items() if ear is not None}
        landmark_paths = {side: side_dirs[side] / "source_landmark.json" for side, ear in ears.items() if ear is not None}
        dummy_head = side_dirs["left"] / "dummy_head.stl"
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
            with open(landmark_paths[side], "w") as f:
                json.dump(landmarks[side], f, indent=2)
            logger(f"{side.title()} source landmark: {landmarks[side]['method']} at {[round(v, 3) for v in landmarks[side]['position']]}, confidence {landmarks[side]['confidence']:.2f}")
        logger("Closing ear canals")
        for side, ear in ears.items():
            if ear is not None:
                ear_canal_closer(ear, mode=settings.ear_canal_closer_mode).export(closed[side])
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
        logger("Cutting ear areas from dummy head")
        dummy_head_mesh = trimesh.load(dummy_head, process=False)
        closed_meshes = {
            side: trimesh.load(closed[side], process=False)
            for side, ear in ears.items()
            if ear is not None
        }
        for side, ear in ears.items():
            if ear is None:
                continue
            head_mesh = dummy_head_mesh.copy()
            ear_mesh = closed_meshes[side]
            if settings.ear_cut_mode == "projected_footprint":
                result = cut_eararea_projected_footprint(head_mesh, ear_mesh, ear_cut_clearance_scale=settings.ear_cut_clearance_scale, projected_cut_margin=settings.projected_cut_margin, side=side)
            else:
                result = cut_eararea(head_mesh, ear_mesh, ear_cut_clearance_scale=settings.ear_cut_clearance_scale, side=side, mode=settings.ear_cut_mode)
            result.export(cut[side])
        from .src.head_stitcher import head_stitcher
        for side, ear in ears.items():
            if ear is None:
                continue
            logger(f"Stitching {side} ear to head")
            head_stitcher(head_path=str(cut[side]), ear_path=str(closed[side]), export_path=str(stitched[side]), seam_smoothing_iterations=settings.seam_smoothing_iterations, seam_smoothing_factor=settings.seam_smoothing_factor)
            logger(f"Grading {side} head mesh; this can take several minutes")
            gamma_l = settings.mesh_gamma if side == "left" else settings.mesh_gamma_opposite
            gamma_r = settings.mesh_gamma_opposite if side == "left" else settings.mesh_gamma
            grading_env = os.environ.copy()
            grading_env["DYLD_LIBRARY_PATH"] = os.pathsep.join(filter(None, [str(Path(mesh_grading_executable).parent), grading_env.get("DYLD_LIBRARY_PATH")]))
            subprocess.run([str(mesh_grading_executable), '-x', str(settings.mesh_min_edge_length), '-y', str(settings.mesh_max_edge_length), '-e', str(settings.mesh_max_error), '-v', '-g', str(gamma_l), '-h', str(gamma_r), '-s', side, '-i', str(stitched[side]), '-o', str(graded[side])], check=True, env=grading_env)
        for project in [projects_dir / "Left", projects_dir / "Right"] if output_dir is not None else []:
            if project.exists():
                shutil.rmtree(project)
        for project in legacy_projects:
            if project.exists():
                shutil.rmtree(project)
        if output_dir is not None:
            projects_dir.mkdir(parents=True, exist_ok=True)
        from .src.material_assign_and_mesh2input import main as mesh2input_main
        projects = {"left": left_project, "right": right_project}
        source_types = {"left": settings.source_type_left, "right": settings.source_type_right}
        for side, ear in ears.items():
            if ear is None:
                continue
            logger(f"Creating {side} Mesh2HRTF project")
            mesh2input_main(
                head=str(graded[side]), title=settings.title, source_type=source_types[side], filepath=str(projects[side]), mesh2hrtf_path=str(mesh2hrtf_path), evaluationGrids=str(evaluation_grid), method=settings.method, pictures=settings.pictures, reference=settings.reference, computeHRIRs=settings.compute_hrirs, unit=settings.unit, speedOfSound=settings.speed_of_sound, densityOfMedium=settings.air_density, materialSearchPaths=settings.material_search_paths, min_frequency=settings.min_frequency, max_frequency=settings.max_frequency, frequency_vector_type=settings.frequency_vector_type, frequency_step_count=settings.frequency_step_count, tolerance=settings.source_assignment_tolerance, source_position=landmarks[side]["position"], source_assignment_mode=settings.source_assignment_mode, source_face_count=settings.source_assignment_face_count,
            )
            if landmarks[side]["method"] == "configured":
                parameters_path = projects[side] / "parameters.json"
                with parameters_path.open("r", encoding="utf-8") as file:
                    parameters = json.load(file)
                unit_factor = {"m": 1.0, "dm": 0.1, "cm": 0.01, "mm": 0.001}[settings.unit]
                parameters["sourceCenter"] = [coordinate * unit_factor for coordinate in landmarks[side]["position"]]
                with parameters_path.open("w", encoding="utf-8") as file:
                    json.dump(parameters, file, indent=4)
                logger(f"Set {side} receiver position exactly to {parameters['sourceCenter']} m")
        logger(f"Preprocessing completed: {', '.join(str(projects[side]) for side, ear in ears.items() if ear is not None)}")
    finally:
        if cleanup is not None:
            cleanup.cleanup()


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
    parser.add_argument('--head-radius', type=float, default=None, help='Optional lateral head radius in millimeters used to place pinnae before preprocessing.')
    parser.add_argument('--min-frequency', type=int, default=1000)
    parser.add_argument('--max-frequency', type=int, default=24000)
    parser.add_argument('--frequency-step-count', type=int, default=129)
    parser.add_argument('--source-face-count', type=int, default=6)
    args = parser.parse_args()
    if not args.left_path and not args.right_path:
        parser.error('At least one ear mesh path is required.')
    settings = PreprocessingConfig(
        ear_cut_clearance_scale=args.ear_cut_clearance_scale,
        ear_cut_mode=args.ear_cut_mode,
        ear_canal_closer_mode=args.ear_canal_closer_mode,
        head_radius=args.head_radius,
        min_frequency=args.min_frequency,
        max_frequency=args.max_frequency,
        frequency_step_count=args.frequency_step_count,
        source_assignment_face_count=args.source_face_count,
    )
    run_preprocessing_pipeline(
        left_path=args.left_path,
        right_path=args.right_path,
        export_path=args.export_path,
        mesh_grading_executable=args.mesh_grading_executable,
        mesh2hrtf_path=args.Mesh2HRTF_path,
        evaluation_grid=args.Mesh2HRTF_Evaluation_Grid,
        preprocessing=settings,
    )
