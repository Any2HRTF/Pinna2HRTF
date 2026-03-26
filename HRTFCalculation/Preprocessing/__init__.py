import argparse
import trimesh
import tempfile
import subprocess

from .src.create_head import head
from .src.ear_canal_closer import ear_canal_closer
from .src.cut_eararea import cut_eararea
from .src.head_stitcher import head_stitcher
from .src.material_assign_and_mesh2input import main

def preprocess():
    parser = argparse.ArgumentParser(description="Run preprocessing from ears to Mesh2HRTF project folders.")

    parser.add_argument('--left-path', type=str, required=True, help='Path to left ear mesh.')
    parser.add_argument('--right-path', type=str, required=True, help='Path to right ear mesh.')
    parser.add_argument('--export-path', type=str, required=True,  help='Path to exported Mesh2HRTF Project.')
    parser.add_argument('--mesh-grading-executable', type=str, required=True, help='Path to the mesh_grading executable.')
    parser.add_argument('--Mesh2HRTF-path', type=str, required=True, help='Path to the location of the mesh2hrtf directory.')
    parser.add_argument('--Mesh2HRTF-Evaluation-Grid', type=str, default='Default', help='Path to the evaluation grid to be used for Mesh2HRTF.')
    args = parser.parse_args()

    with tempfile.TemporaryDirectory() as temp_dir:
        left_ear = trimesh.load(args.left_path)
        right_ear = trimesh.load(args.right_path)

        ear_canal_closer(trimesh.load(args.left_path)).export(f"{temp_dir}/left_ear.stl")
        ear_canal_closer(trimesh.load(args.right_path)).export(f"{temp_dir}/right_ear.stl")

        head(left_ear, right_ear, f"{temp_dir}/head.stl")
        
        cut_eararea(trimesh.load(f"{temp_dir}/head.stl"), trimesh.load(f"{temp_dir}/left_ear.stl")).export(f"{temp_dir}/head_cut_left.stl")
        cut_eararea(trimesh.load(f"{temp_dir}/head.stl"), trimesh.load(f"{temp_dir}/right_ear.stl")).export(f"{temp_dir}/head_cut_right.stl")

        head_stitcher(head_path=f"{temp_dir}/head_cut_left.stl", ear_path=f"{temp_dir}/left_ear.stl", export_path=f"{temp_dir}/head_left.stl")
        head_stitcher(head_path=f"{temp_dir}/head_cut_right.stl", ear_path=f"{temp_dir}/right_ear.stl", export_path=f"{temp_dir}/head_right.stl")
        
        subprocess.run([args.mesh_grading_executable, '-x', '0.5', '-y', '10', '-v', '-g', '0.15', '-h', '0.2', '-s', 'left', '-i', f"{temp_dir}/head_left.stl", '-o', f"{temp_dir}/head_left_graded.ply"])

        subprocess.run([args.mesh_grading_executable, '-x', '0.5', '-y', '10', '-v', '-g', '0.15', '-h', '0.2', '-s', 'right', '-i', f"{temp_dir}/head_right.stl", '-o', f"{temp_dir}/head_right_graded.ply"])
        
        main(head=f"{temp_dir}/head_left_graded.ply", title="HRTF Simulation",sourceType="Left ear", filepath=f"{args.export_path}-Left", programPath=args.Mesh2HRTF_path, evaluationGrids=args.Mesh2HRTF_Evaluation_Grid)
        
        main(head=f"{temp_dir}/head_right_graded.ply", title="HRTF Simulation",sourceType="Right ear", filepath=f"{args.export_path}-Right", programPath=args.Mesh2HRTF_path, evaluationGrids=args.Mesh2HRTF_Evaluation_Grid)
