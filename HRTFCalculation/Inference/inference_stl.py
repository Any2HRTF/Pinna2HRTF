import tempfile
import argparse
import os
import torch
import numpy as np
import cv2
os.environ["OPENCV_IO_ENABLE_OPENEXR"]="1"
import trimesh
from trimesh.registration import icp
from trimesh.transformations import reflection_matrix
import csv
import yaml
import pandas as pd
import bpy
from bezierppm import BezierPPM
from bezierppm.render_helpers import render

try:
    from .src.swin_transformer_v2 import SwinTransformerV2
    from .src.math_helpers import get_quaternion_from_rotation_matrix, compute_rotation_matrix_from_ortho6d
except ImportError:
    from src.swin_transformer_v2 import SwinTransformerV2
    from src.math_helpers import get_quaternion_from_rotation_matrix, compute_rotation_matrix_from_ortho6d

__DIR_PATH = os.path.dirname(os.path.realpath(__file__))

def jaccard(P, Q, res=0.5):
    """
    A function to calculate the Jaccard similarity between two point clouds.
    
    Arguments
    -------
    P: np.array
        An array where each entry stores an x, y, z coordinate of the point cloud
    Q: np.array
        An array where each entry stores an x, y, z coordinate of the point cloud
    res: float
        The resolution/step size of each voxel (default: 0.5)
        
    Return: float
        The Jaccard similarity between point clouds P and Q
    """
    # Step 1: Generate meshgrid
    x_min = min(min(P[:, 0]), min(Q[:, 0]))
    x_max = max(max(P[:, 0]), max(Q[:, 0]))
    y_min = min(min(P[:, 1]), min(Q[:, 1]))
    y_max = max(max(P[:, 1]), max(Q[:, 1]))
    z_min = min(min(P[:, 2]), min(Q[:, 2]))
    z_max = max(max(P[:, 2]), max(Q[:, 2]))

    xx = np.arange(x_min, x_max + res / 2 + np.finfo(np.float64).eps, res)
    yy = np.arange(y_min, y_max + res / 2 + np.finfo(np.float64).eps, res)
    zz = np.arange(z_min, z_max + res / 2 + np.finfo(np.float64).eps, res)

    len_x = len(xx)
    len_y = len(yy)

    # Step 2: Binary mask indices for P and Q
    def bin_mask_idx(points):
        discret_x = np.round((points[:, 0] - x_min) / res)
        discret_y = np.round((points[:, 1] - y_min) / res)
        discret_z = np.round((points[:, 2] - z_min) / res)
        return discret_x + discret_y * len_x + discret_z * len_x * len_y

    bin_grid_p = bin_mask_idx(P)
    bin_grid_q = bin_mask_idx(Q)

    # Step 3: Compute Jaccard similarity
    union = len(np.unique(np.append(bin_grid_p, bin_grid_q)))
    intersection = len(np.intersect1d(bin_grid_p, bin_grid_q))
    return intersection / union

def minimal_distances(P, Q,) -> np.ndarray:
    """ Computes the minimal distances between two point clouds P and Q.

    Parameters
    ----------
    P : np.ndarray
    Q : np.ndarray

    Returns
    -------
    np.ndarray
        Minimal distances between P and Q.
    """

    min_distances = np.zeros(P.shape[0], dtype=np.float32)
    for idx_pred in range(min_distances.shape[0]):
        min_distances[idx_pred] = np.sqrt(np.min(np.sum((P[idx_pred, :] - Q)**2, axis=1)))

    return min_distances

def get_camera_position(camera_jitter=False, cam_radius=0.18):

    radius = cam_radius * np.ones(25) if not camera_jitter else cam_radius + np.random.uniform(-0.02, 0.02, 25)
    phi    = np.linspace(np.deg2rad(45),np.deg2rad(135),5)  + (np.random.uniform(-np.deg2rad(10), np.deg2rad(10), 5) if camera_jitter else 0)
    theta  = np.linspace(np.deg2rad(50),np.deg2rad(-50),5)   + (np.random.uniform(-np.deg2rad(10), np.deg2rad(10), 5) if camera_jitter else 0)

    phi_theta = np.array(np.meshgrid(phi, theta)).T.reshape(-1,2)
    theta_m = np.concatenate((radius[:,np.newaxis],phi_theta), axis=1)

    # convert spherical to Cartesian coordinates
    x, y, z = theta_m[:,0] * np.cos(theta_m[:,2]) * np.cos(theta_m[:,1]), \
        theta_m[:,0] * np.cos(theta_m[:,2]) * np.sin(theta_m[:,1]), \
        theta_m[:,0] * np.sin(theta_m[:,2])#

    loc_cam = np.array([x, y, z])
    loc_cam_ref = np.array([0., 0., 0.])

    return loc_cam, loc_cam_ref

def get_model_input(path_to_mesh, views, depth, mirror, initial_transforms=None, transformed_output_path=None) -> tuple[np.ndarray, np.ndarray, np.ndarray, dict[str, float | str]]:
    camera_positions, camera_position_reference = get_camera_position(cam_radius=0.2)

    tempdir = tempfile.mkdtemp()

    BezierPPM().points
    bpy.ops.object.select_all(action='DESELECT')
    bpy.data.objects['Mesh'].select_set(True)
    bpy.ops.object.delete()
    if path_to_mesh:
        original_cloud = trimesh.load_mesh(path_to_mesh)
        if mirror:
            mirror_matrix = reflection_matrix(np.array([0,0, 0,0]), np.array([0,1,0]))
            original_cloud = original_cloud.apply_transform(mirror_matrix)

        target_cloud = trimesh.load_mesh(f"{__DIR_PATH}/resources/PPM Default.stl")
        initializations = []
        candidate_diagnostics = []
        if initial_transforms:
            initializations.extend((method, matrix, np.nan) for method, matrix in initial_transforms)
        else:
            points = target_cloud.vertices
            points_pit = trimesh.bounds.oriented_bounds(points)[0]
            search_pit = original_cloud.principal_inertia_transform if original_cloud.is_volume else original_cloud.bounding_box_oriented.principal_inertia_transform
            search_to_points = np.linalg.inv(points_pit) @ search_pit
            cubes = np.array([np.eye(4) * np.append(diag, 1) for diag in [[1, 1, 1], [1, 1, -1], [1, -1, 1], [-1, 1, 1], [-1, -1, 1], [-1, 1, -1], [1, -1, -1], [-1, -1, -1]]])
            for index, flip in enumerate(cubes):
                target_to_mesh = trimesh.transformations.transform_around(flip, original_cloud.centroid) @ np.linalg.inv(search_to_points)
                target_to_mesh, _, cost = icp(points, original_cloud, initial=target_to_mesh, max_iterations=10, scale=False, reflection=False)
                mesh_to_target = np.linalg.inv(target_to_mesh)
                determinant = np.linalg.det(mesh_to_target[:3, :3])
                candidate_diagnostics.append(f"axis_{index}:{cost:.6f}:{determinant:.6f}")
                if determinant > 1e-8:
                    initializations.append((f"proper_global_{index}", mesh_to_target, cost))
            if not initializations:
                raise RuntimeError(f"Could not find a proper global initialization for {path_to_mesh}")
            initializations = [min(initializations, key=lambda initialization: initialization[2])]
        alignments = []
        for method, initial, candidate_initial_cost in initializations:
            matrix, _, _ = icp(
                original_cloud.vertices,
                target_cloud,
                initial=initial,
                max_iterations=50,
                scale=True,
                reflection=False,
            )
            aligned_cloud = original_cloud.copy()
            aligned_cloud.apply_transform(matrix)
            source_height = np.ptp(aligned_cloud.vertices[:, 2])
            target_height = np.ptp(target_cloud.vertices[:, 2])
            height_correction = target_height / source_height
            height_matrix = np.eye(4)
            height_matrix[2, 2] = height_correction
            height_matrix = trimesh.transformations.transform_around(height_matrix, aligned_cloud.centroid)
            matrix = height_matrix @ matrix
            aligned_cloud.apply_transform(height_matrix)
            vertical_offset = np.mean(target_cloud.bounds[:, 2]) - np.mean(aligned_cloud.bounds[:, 2])
            matrix = trimesh.transformations.translation_matrix([0, 0, vertical_offset]) @ matrix
            aligned_cloud.apply_translation([0, 0, vertical_offset])
            _, distances, _ = target_cloud.nearest.on_surface(aligned_cloud.vertices)
            cost = np.mean(distances ** 2)
            determinant = np.linalg.det(matrix[:3, :3])
            height_scale = height_correction
            if determinant > 1e-8:
                alignments.append((cost, method, determinant, matrix, candidate_initial_cost, height_scale))
        if not alignments:
            raise RuntimeError(f"Could not find a proper alignment for {path_to_mesh}")
        alignment_cost, alignment_method, alignment_determinant, matrix_scale, alignment_initial_cost, alignment_height_scale = min(alignments, key=lambda alignment: alignment[0])
        candidate_diagnostics.extend(f"{method}:{cost:.6f}:{determinant:.6f}:{height_scale:.6f}" for cost, method, determinant, _, _, height_scale in alignments)
        alignment_candidates = "|".join(candidate_diagnostics)

        new = original_cloud.apply_transform(matrix_scale)

        # open ear canal
        vert_ind = np.argwhere((new.vertices[:, 1] <= 0))
        mask = np.ones(len(new.faces), dtype=bool)
        mask[vert_ind] = False
        legit_mask = mask[new.faces].any(axis=1)
        new.update_faces(legit_mask)
        new.remove_unreferenced_vertices()

        new.export(f"{tempdir}/transformed.stl")
        if transformed_output_path:
            os.makedirs(os.path.dirname(transformed_output_path) or ".", exist_ok=True)
            new.export(transformed_output_path)
        bpy.ops.wm.stl_import(filepath=f"{tempdir}/transformed.stl")
    else:
        BezierPPM().points

    data = []
    depth_data = []

    if views == 1:
        views_list = [12]
    elif views == 3:
        views_list = [2, 12, 23]
    elif views == 9:
        views_list = [0, 2, 4, 10, 12, 14, 20, 22, 24]
    elif views == 25:
        views_list = list(range(25))

    for i in range(camera_positions.shape[1]):

        if i in views_list:
            # bpy.context.scene.cycles.device = "GPU"
            render(
                dirpath=tempdir,
                filename="img",
                camera_location=camera_positions[:,i],
                camera_location_reference=camera_position_reference,
                light_shape='SQUARE',
                light_power=350000,
                # light_power=200000,
                light_location=[-0.01*1000, 0.15*1000, 0.1*1000],
                depth=depth
            )

            data.append(cv2.imread(tempdir+'/img.png', 0))
            if depth:
                depth_data.append(cv2.imread(tempdir+'/img.exr', 0))

    if depth:
        for i in depth_data:
            data.append(i)
    return (
        np.stack(data).astype(np.float32) / 255.0,
        matrix_scale,
        np.array(new.vertices),
        {
            "method": alignment_method,
            "initial_cost": alignment_initial_cost,
            "cost": alignment_cost,
            "determinant": alignment_determinant,
            "height_scale": alignment_height_scale,
            "candidates": alignment_candidates,
        },
    )

def get_model_prediction(model, data):
    all_parameters = []
    with open(f'{__DIR_PATH}/resources/PPM Parameters.csv', mode ='r') as file:
        csvFile = csv.reader(file)
        for lines in csvFile:
            all_parameters.append(lines[0])

    location_parameters = [param for param in all_parameters if 'Location' in param and 'Parent' not in param]
    rotation_parameters = [param for param in all_parameters if 'Rotation' in param and 'Parent' not in param]
    scale_parameters = [param for param in all_parameters if 'Scale' in param and 'Parent' not in param]
    shape_parameters = [param for param in all_parameters if 'Shape' in param]

    with torch.no_grad():
        out = model(torch.tensor(data).unsqueeze(0))

        location_prediction=out[:,:len(location_parameters)][0].detach().cpu()
        rotation_prediction=out[:, len(location_parameters)+len(scale_parameters)+len(shape_parameters):][0].detach().cpu()
        scale_prediction=out[:, len(location_parameters):len(location_parameters)+len(scale_parameters)][0].detach().cpu()
        shape_prediction=out[:, len(location_parameters)+len(scale_parameters):len(location_parameters)+len(scale_parameters)+len(shape_parameters)][0].detach().cpu()

        prediction_ppm = {}
        rotation_prediction=get_quaternion_from_rotation_matrix(compute_rotation_matrix_from_ortho6d(rotation_prediction.view(-1,6)[np.newaxis,...]))[0].view(-1)
        
        for i, parameter in enumerate(location_parameters):
            prediction_ppm[parameter] = location_prediction[i].item() / 1000

        for i, parameter in enumerate(rotation_parameters):
            prediction_ppm[parameter] = rotation_prediction[i].item()

        for i, parameter in enumerate(scale_parameters):
            prediction_ppm[parameter] = scale_prediction[i].item()
            
        for i, parameter in enumerate(shape_parameters):
            prediction_ppm[parameter] = shape_prediction[i].item()
        
        return prediction_ppm

def main(args):

    print(f"Using config: {args.configuration} with model file: {args.model_checkpoint}")
    
    with open(args.configuration, 'r') as file:
        CONFIGURATION = yaml.safe_load(file)

    model = SwinTransformerV2(
                    img_size=CONFIGURATION['model']['img_size'],
                    in_chans=2*CONFIGURATION['model']['number_of_camera_views'] if CONFIGURATION['model']['depth'] else CONFIGURATION['model']['number_of_camera_views'],
                    num_classes=188,
                    window_size=CONFIGURATION['model']['window_size'],
                    depths=CONFIGURATION['model']['depths'],
                    num_heads=CONFIGURATION['model']['num_heads'],
                    weights = torch.ones(4)
                )

    model.load_state_dict(torch.load(args.model_checkpoint, map_location=torch.device('cpu'), weights_only=False)["model_state_dict"])
    model.eval()

    prediciton_df = []

    folders = {
        "Left": {
            "target": getattr(args, "target_left_folder", "Target STL Left"),
            "prediction": getattr(args, "prediction_left_folder", "Prediction STL Left"),
            "parameters": getattr(args, "prediction_parameters_left_folder", "Prediction Parameters Left"),
        },
        "Right": {
            "target": getattr(args, "target_right_folder", "Target STL Right"),
            "prediction": getattr(args, "prediction_right_folder", "Prediction STL Right"),
            "parameters": getattr(args, "prediction_parameters_right_folder", "Prediction Parameters Right"),
        },
    }

    left_alignments = {}
    for direction in ["Left", "Right"]:
        data_dir = f"{args.data_dir}/{folders[direction]['target']}"
        if not os.path.isdir(data_dir):
            raise FileNotFoundError(f"BezierPPM target folder not found: {data_dir}")

        for stl_file in sorted(os.listdir(data_dir)):
            if stl_file[-4:] != ".stl":
                continue
            print(f"{data_dir}/{stl_file}")

            stem = stl_file[:-4]
            paired_alignment = None
            if direction == "Right":
                paired_alignment = left_alignments.get(stem)
                if paired_alignment is None and len(left_alignments) == 1:
                    paired_alignment = next(iter(left_alignments.values()))
            data, transform_matrix, transformed_input, alignment = get_model_input(
                path_to_mesh=f"{data_dir}/{stl_file}",
                views=CONFIGURATION['model']['number_of_camera_views'],
                depth=CONFIGURATION['model']['depth'],
                mirror=True if direction == "Right" else False,
                initial_transforms=[("paired_left", paired_alignment[0])] if paired_alignment else None,
                transformed_output_path=f"{args.data_dir}/ICP STL {direction}/{stl_file}",
            )
            if direction == "Left":
                left_alignments[stem] = (transform_matrix, alignment["determinant"])
            print(
                f"{direction} alignment: {alignment['method']}, "
                f"cost {alignment['cost']:.6f}, "
                f"determinant {alignment['determinant']:.6f}, "
                f"height scale {alignment['height_scale']:.6f}"
            )
            target_cloud = np.array(trimesh.load_mesh(f"{data_dir}/{stl_file}").vertices)

            prediction_ppm = get_model_prediction(model, data)

            tempdir = tempfile.mkdtemp()
            BezierPPM(from_dict=prediction_ppm).export_stl(file=f"{tempdir}/{stl_file[:-4]}.stl")

            prediction_parameters_dir = f"{args.data_dir}/{folders[direction]['parameters']}"
            if not os.path.isdir(prediction_parameters_dir):
                os.makedirs(prediction_parameters_dir)
            BezierPPM(from_dict=prediction_ppm).export_csv(file=f"{prediction_parameters_dir}/{stl_file[:-4]}.csv")

            predicted_cloud = trimesh.load_mesh(f"{tempdir}/{stl_file[:-4]}.stl")
            predicted_cloud = predicted_cloud.apply_transform(np.linalg.inv(transform_matrix))

            if direction == "Right":
                mirror_matrix = reflection_matrix(np.array([0,0,0,0]), np.array([0,1,0]))
                predicted_cloud = predicted_cloud.apply_transform(mirror_matrix)

            prediction_stl_dir = f"{args.data_dir}/{folders[direction]['prediction']}"
            if not os.path.isdir(prediction_stl_dir):
                os.makedirs(prediction_stl_dir)
            predicted_cloud.export(f"{prediction_stl_dir}/{stl_file[:-4]}.stl")
            predicted_cloud = np.array(predicted_cloud.vertices)

            minimal_distances_direction_1 = minimal_distances(predicted_cloud, target_cloud)
            minimal_distances_direction_2 = minimal_distances(target_cloud, predicted_cloud)

            out = {}
                        
            out["File Path"] = f"{data_dir}/{stl_file}"
            out["ID"] = stl_file[:-4]
            out["Direction"] = direction
            out["Alignment Method"] = alignment["method"]
            out["Alignment Initial Cost"] = alignment["initial_cost"]
            out["Alignment Cost"] = alignment["cost"]
            out["Alignment Determinant"] = alignment["determinant"]
            out["Alignment Height Scale"] = alignment["height_scale"]
            out["Alignment Candidates"] = alignment["candidates"]
            out["RMSE"] = np.sqrt(np.mean(minimal_distances_direction_1**2))
            out["Completeness 1mm"] = np.sum(minimal_distances_direction_1 < 1) / minimal_distances_direction_1.shape[0]
            out["Completeness 2mm"] = np.sum(minimal_distances_direction_1 < 2) / minimal_distances_direction_1.shape[0]
            out["Hausdorff Distance"] = np.max([np.max(minimal_distances_direction_1), np.max(minimal_distances_direction_2)])
            out["Chamfer Distance"] = np.mean(minimal_distances_direction_1) + np.mean(minimal_distances_direction_2)
            
            regions = BezierPPM(from_dict=prediction_ppm).get_region_indices()

            # calculate region specific errors
            points = BezierPPM(from_dict=prediction_ppm).points
            inverse_trasformation_matrix = np.linalg.inv(transform_matrix)
            transformed_point_cloud =  (inverse_trasformation_matrix[:3,:3] @ points.T + inverse_trasformation_matrix[:3,3:]).T
            
            if direction == "Right":
                mirror_matrix = np.array([[ 1.,  0.,  0.],
                                          [ 0., -1.,  0.],
                                          [ 0.,  0.,  1.]])
                transformed_point_cloud = (mirror_matrix @ transformed_point_cloud.T).T

            for region in regions.keys():
                indices = regions[region]

                distances_region = minimal_distances(transformed_point_cloud[indices], target_cloud)

                out[f"RMSE {region}"] = np.sqrt(np.mean(distances_region**2))
            prediciton_df.append(out)

    pd.DataFrame(prediciton_df).to_csv(f"{args.data_dir}/Results Inference.csv")

def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument('--configuration', required=False, default=f'{__DIR_PATH}/resources/Local 3 Views.yaml', help='Path to configuration file.')
    parser.add_argument('--data_dir', required=True, help='Path to directory containg the stl files.')
    parser.add_argument('--model_checkpoint', required=False, default=f'{__DIR_PATH}/resources/Local 3 Views.pth', help='Path to model checkpoint file.')
    parser.add_argument('--target_left_folder', required=False, default='Target STL Left')
    parser.add_argument('--target_right_folder', required=False, default='Target STL Right')
    parser.add_argument('--prediction_left_folder', required=False, default='Prediction STL Left')
    parser.add_argument('--prediction_right_folder', required=False, default='Prediction STL Right')
    parser.add_argument('--prediction_parameters_left_folder', required=False, default='Prediction Parameters Left')
    parser.add_argument('--prediction_parameters_right_folder', required=False, default='Prediction Parameters Right')
    return parser.parse_args()

def cli():
    args = parse_args()
    main(args)

if __name__ == '__main__':
    cli()
