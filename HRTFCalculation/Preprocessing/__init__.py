import argparse
import json
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
    left_ear.apply_translation((0, head_radius - pinna_y_center(left_ear), 0))
    right_ear.apply_translation((0, -head_radius - pinna_y_center(right_ear), 0))


def run_preprocessing_pipeline(left_path, right_path, mesh_grading_executable, mesh2hrtf_path, evaluation_grid, preprocessing=None, output_dir=None, export_path=None, logger=print):
    settings = preprocessing or PreprocessingConfig()
    if output_dir is None and export_path is None:
        raise ValueError("output_dir or export_path is required")
    left_path = Path(left_path)
    right_path = Path(right_path)
    if output_dir is not None:
        output_dir = Path(output_dir)
        projects_dir = output_dir / "Projects"
        left_project = projects_dir / "Left"
        right_project = projects_dir / "Right"
        legacy_projects = [projects_dir / "project-Left", projects_dir / "project-Right"]
        intermediates = output_dir / "intermediates"
    else:
        export_prefix = Path(export_path)
        left_project = Path(f"{export_prefix}-Left")
        right_project = Path(f"{export_prefix}-Right")
        legacy_projects = []
        intermediates = Path(f"{export_prefix}-intermediates")
    if settings.write_intermediates:
        work_dir = intermediates
        if work_dir.exists():
            shutil.rmtree(work_dir)
        (work_dir / "left").mkdir(parents=True, exist_ok=True)
        (work_dir / "right").mkdir(parents=True, exist_ok=True)
        cleanup = None
    else:
        cleanup = tempfile.TemporaryDirectory()
        work_dir = Path(cleanup.name)
        (work_dir / "left").mkdir(parents=True, exist_ok=True)
        (work_dir / "right").mkdir(parents=True, exist_ok=True)
    try:
        left_ear = trimesh.load(left_path)
        right_ear = trimesh.load(right_path)
        if settings.head_radius is not None:
            place_pinnae_at_head_radius(left_ear, right_ear, settings.head_radius)
            logger(f"Placed pinnae at head radius: {settings.head_radius}")
        left_ear.export(work_dir / "left" / "input_ear.stl")
        right_ear.export(work_dir / "right" / "input_ear.stl")
        left_closed = work_dir / "left" / "closed_ear.stl"
        right_closed = work_dir / "right" / "closed_ear.stl"
        left_landmark_path = work_dir / "left" / "source_landmark.json"
        right_landmark_path = work_dir / "right" / "source_landmark.json"
        dummy_head = work_dir / "dummy_head.stl"
        left_cut = work_dir / "left" / "cut_head.stl"
        right_cut = work_dir / "right" / "cut_head.stl"
        left_stitched = work_dir / "left" / "stitched_head.stl"
        right_stitched = work_dir / "right" / "stitched_head.stl"
        left_graded = work_dir / "left" / "graded_head.ply"
        right_graded = work_dir / "right" / "graded_head.ply"
        left_landmark = estimate_ear_canal_position(left_ear, side="left")
        right_landmark = estimate_ear_canal_position(right_ear, side="right")
        with open(left_landmark_path, "w") as f:
            json.dump(left_landmark, f, indent=2)
        with open(right_landmark_path, "w") as f:
            json.dump(right_landmark, f, indent=2)
        logger(f"Left source landmark: {left_landmark['method']} at {[round(v, 3) for v in left_landmark['position']]}, confidence {left_landmark['confidence']:.2f}")
        logger(f"Right source landmark: {right_landmark['method']} at {[round(v, 3) for v in right_landmark['position']]}, confidence {right_landmark['confidence']:.2f}")
        ear_canal_closer(left_ear).export(left_closed)
        ear_canal_closer(right_ear).export(right_closed)
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
        if settings.ear_cut_mode == "projected_footprint":
            cut_eararea_projected_footprint(trimesh.load(dummy_head, process=False), trimesh.load(left_closed, process=False), ear_cut_clearance_scale=settings.ear_cut_clearance_scale, projected_cut_margin=settings.projected_cut_margin, side="left").export(left_cut)
            cut_eararea_projected_footprint(trimesh.load(dummy_head, process=False), trimesh.load(right_closed, process=False), ear_cut_clearance_scale=settings.ear_cut_clearance_scale, projected_cut_margin=settings.projected_cut_margin, side="right").export(right_cut)
        else:
            cut_eararea(trimesh.load(dummy_head, process=False), trimesh.load(left_closed, process=False), ear_cut_clearance_scale=settings.ear_cut_clearance_scale, side="left").export(left_cut)
            cut_eararea(trimesh.load(dummy_head, process=False), trimesh.load(right_closed, process=False), ear_cut_clearance_scale=settings.ear_cut_clearance_scale, side="right").export(right_cut)
        from .src.head_stitcher import head_stitcher
        head_stitcher(head_path=str(left_cut), ear_path=str(left_closed), export_path=str(left_stitched), seam_smoothing_iterations=settings.seam_smoothing_iterations, seam_smoothing_factor=settings.seam_smoothing_factor)
        head_stitcher(head_path=str(right_cut), ear_path=str(right_closed), export_path=str(right_stitched), seam_smoothing_iterations=settings.seam_smoothing_iterations, seam_smoothing_factor=settings.seam_smoothing_factor)
        subprocess.run([str(mesh_grading_executable), '-x', str(settings.mesh_min_edge_length), '-y', str(settings.mesh_max_edge_length), '-v', '-g', str(settings.mesh_gamma_left), '-h', str(settings.mesh_hole_size), '-s', 'left', '-i', str(left_stitched), '-o', str(left_graded)], check=True)
        subprocess.run([str(mesh_grading_executable), '-x', str(settings.mesh_min_edge_length), '-y', str(settings.mesh_max_edge_length), '-v', '-g', str(settings.mesh_gamma_right), '-h', str(settings.mesh_hole_size), '-s', 'right', '-i', str(right_stitched), '-o', str(right_graded)], check=True)
        if left_project.exists():
            shutil.rmtree(left_project)
        if right_project.exists():
            shutil.rmtree(right_project)
        for project in legacy_projects:
            if project.exists():
                shutil.rmtree(project)
        left_project.parent.mkdir(parents=True, exist_ok=True)
        from .src.material_assign_and_mesh2input import main as mesh2input_main
        mesh2input_main(
            head=str(left_graded),
            title=settings.title,
            source_type=settings.source_type_left,
            filepath=str(left_project),
            mesh2hrtf_path=str(mesh2hrtf_path),
            evaluationGrids=str(evaluation_grid),
            method=settings.method,
            pictures=settings.pictures,
            reference=settings.reference,
            computeHRIRs=settings.compute_hrirs,
            unit=settings.unit,
            speedOfSound=settings.speed_of_sound,
            densityOfMedium=settings.air_density,
            materialSearchPaths=settings.material_search_paths,
            min_frequency=settings.min_frequency,
            max_frequency=settings.max_frequency,
            frequency_vector_type=settings.frequency_vector_type,
            frequency_step_count=settings.frequency_step_count,
            tolerance=settings.source_assignment_tolerance,
            source_position=left_landmark["position"],
            source_assignment_mode=settings.source_assignment_mode,
        )
        mesh2input_main(
            head=str(right_graded),
            title=settings.title,
            source_type=settings.source_type_right,
            filepath=str(right_project),
            mesh2hrtf_path=str(mesh2hrtf_path),
            evaluationGrids=str(evaluation_grid),
            method=settings.method,
            pictures=settings.pictures,
            reference=settings.reference,
            computeHRIRs=settings.compute_hrirs,
            unit=settings.unit,
            speedOfSound=settings.speed_of_sound,
            densityOfMedium=settings.air_density,
            materialSearchPaths=settings.material_search_paths,
            min_frequency=settings.min_frequency,
            max_frequency=settings.max_frequency,
            frequency_vector_type=settings.frequency_vector_type,
            frequency_step_count=settings.frequency_step_count,
            tolerance=settings.source_assignment_tolerance,
            source_position=right_landmark["position"],
            source_assignment_mode=settings.source_assignment_mode,
        )
        logger(f"Preprocessing completed: {left_project} and {right_project}")
    finally:
        if cleanup is not None:
            cleanup.cleanup()


def preprocess():
    parser = argparse.ArgumentParser(description="Run preprocessing from ears to Mesh2HRTF project folders.")
    parser.add_argument('--left-path', type=str, required=True, help='Path to left ear mesh.')
    parser.add_argument('--right-path', type=str, required=True, help='Path to right ear mesh.')
    parser.add_argument('--export-path', type=str, required=True,  help='Path to exported Mesh2HRTF Project.')
    parser.add_argument('--mesh-grading-executable', type=str, required=True, help='Path to the mesh_grading executable.')
    parser.add_argument('--Mesh2HRTF-path', type=str, required=True, help='Path to the location of the mesh2hrtf directory.')
    parser.add_argument('--Mesh2HRTF-Evaluation-Grid', type=str, default='/Users/felixperfler/Documents/ISF/2026/Pipeline Paper/Data/Resources/EvalGrid', help='Path to the evaluation grid to be used for Mesh2HRTF.')
    parser.add_argument('--ear-cut-clearance-scale', type=float, default=1.3)
    parser.add_argument('--head-radius', type=float, default=None, help='Optional lateral head radius in millimeters used to place pinnae before preprocessing.')
    parser.add_argument('--min-frequency', type=int, default=1000)
    parser.add_argument('--max-frequency', type=int, default=24000)
    parser.add_argument('--frequency-step-count', type=int, default=129)
    args = parser.parse_args()
    settings = PreprocessingConfig(
        ear_cut_clearance_scale=args.ear_cut_clearance_scale,
        head_radius=args.head_radius,
        min_frequency=args.min_frequency,
        max_frequency=args.max_frequency,
        frequency_step_count=args.frequency_step_count,
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
