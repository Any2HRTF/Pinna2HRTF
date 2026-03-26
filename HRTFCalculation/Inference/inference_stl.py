import tempfile
import argparse
import os
import torch
import numpy as np
import cv2
os.environ["OPENCV_IO_ENABLE_OPENEXR"]="1"
import trimesh
from trimesh.registration import icp, mesh_other
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

def get_model_input(path_to_mesh, views, depth, mirror) -> np.ndarray:
    camera_positions, camera_position_reference = get_camera_position(cam_radius=0.2)

    tempdir = tempfile.TemporaryDirectory().name
    if not os.path.exists(tempdir): 
        os.makedirs(tempdir) 

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
        matrix_trans, _ = mesh_other(original_cloud, target_cloud.vertices, scale=False)
        matrix_scale, _, _ = icp(original_cloud.vertices, target_cloud, initial=matrix_trans, scale=True)

        new = original_cloud.apply_transform(matrix_scale)

        # open ear canal
        vert_ind = np.argwhere((new.vertices[:, 1] <= 0))
        mask = np.ones(len(new.faces), dtype=bool)
        mask[vert_ind] = False
        legit_mask = mask[new.faces].any(axis=1)
        new.update_faces(legit_mask)
        new.remove_unreferenced_vertices()

        new.export(f"{tempdir}/transformed.stl")
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
        return np.stack(data).astype(np.float32) / 255.0, matrix_scale, np.array(new.vertices)
    else:
        return np.stack(data).astype(np.float32) / 255.0, matrix_scale, np.array(new.vertices)

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

    for direction in ["Left", "Right"]:
        data_dir = f"{args.data_dir}/Target STL {direction}"

        for stl_file in os.listdir(data_dir):
            if stl_file[-4:] != ".stl":
                continue
            print(f"{data_dir}/{stl_file}")

            data, transform_matrix, transformed_input = get_model_input(
                path_to_mesh=f"{data_dir}/{stl_file}",
                views=CONFIGURATION['model']['number_of_camera_views'],
                depth=CONFIGURATION['model']['depth'],
                mirror=True if direction == "Right" else False)
            target_cloud = np.array(trimesh.load_mesh(f"{data_dir}/{stl_file}").vertices)

            prediction_ppm = get_model_prediction(model, data)

            tempdir = tempfile.TemporaryDirectory().name
            if not os.path.exists(tempdir): 
                os.makedirs(tempdir) 
            BezierPPM(from_dict=prediction_ppm).export_stl(file=f"{tempdir}/{stl_file[:-4]}.stl")

            if not os.path.isdir(f"{args.data_dir}/Prediction Parameters {direction}/"):
                os.mkdir(f"{args.data_dir}/Prediction Parameters {direction}/")
            BezierPPM(from_dict=prediction_ppm).export_csv(file=f"{args.data_dir}/Prediction Parameters {direction}/{stl_file[:-4]}.csv")

            predicted_cloud = trimesh.load_mesh(f"{tempdir}/{stl_file[:-4]}.stl")
            predicted_cloud = predicted_cloud.apply_transform(np.linalg.inv(transform_matrix))

            if direction == "Right":
                mirror_matrix = reflection_matrix(np.array([0,0,0,0]), np.array([0,1,0]))
                predicted_cloud = predicted_cloud.apply_transform(mirror_matrix)

            if not os.path.isdir(f"{args.data_dir}/Prediction STL {direction}/"):
                os.mkdir(f"{args.data_dir}/Prediction STL {direction}/")
            predicted_cloud.export(f"{args.data_dir}/Prediction STL {direction}/{stl_file[:-4]}.stl")
            predicted_cloud = np.array(predicted_cloud.vertices)

            minimal_distances_direction_1 = minimal_distances(predicted_cloud, target_cloud)
            minimal_distances_direction_2 = minimal_distances(target_cloud, predicted_cloud)

            out = {}
                        
            out["File Path"] = f"{data_dir}/{stl_file}"
            out["ID"] = stl_file[:-4]
            out["Direction"] = direction
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
    parser.add_argument('--configuration', required=False, default=f'{__DIR_PATH}/resources/Local 9 Views.yaml', help='Path to configuration file.')
    parser.add_argument('--data_dir', required=True, help='Path to directory containg the stl files.')
    parser.add_argument('--model_checkpoint', required=False, default=f'{__DIR_PATH}/resources/Local 9 Views.pth', help='Path to model checkpoint file.')
    return parser.parse_args()

def cli():
    args = parse_args()
    main(args)

if __name__ == '__main__':
    cli()
