"""
Takes a head and an ear mesh and cuts an elliptical area with some extra space around the ear into the head.
Exports the result as a .stl to export_path.

Inputs:
head_path - path to head mesh as .stl file
ear_path - path to ear mesh as .stl file. Used to adapt the size of the ellipse
export_path
spazi - a factor for the spacing around the ear. Default ist 1.3

Lukas Thalhammer, Acoustics Research Institute
September 2024
"""

import argparse
import numpy as np
import trimesh
#import pyglet  # necessary for .show to work! Used for debugging only


def cut_eararea(head, ear, spazi=1.3, side='auto'):
    # compute size of the ellipse
    a = ( np.abs(np.max(ear.vertices[:,2]) - np.min(ear.vertices[:,2])) / 2 ) * spazi  # length 1st axis of the ellipse along the z-axis
    b = ( np.abs(np.max(ear.vertices[:,0]) - np.min(ear.vertices[:,0])) / 2 ) * spazi*spazi  # length 2nd axis of the ellipse along the x-axis
    
    # compute center of the ear
    offset = ( (np.max(ear.vertices[:,0])+np.min(ear.vertices[:,0]))/2, (np.max(ear.vertices[:,2])+np.min(ear.vertices[:,2]))/2)

    # check on which side of the y axis the ear mesh is located
    if side == 'auto':
        if ear.vertices[0,1] > 0:
            side = 'left'
        else:
            side = 'right'
    elif side not in ('left', 'right'):
        raise Exception("Inconclusive LorR parameter. Please use 'auto', 'left' or 'right'.")

    # check if cylinder covers the whole ear
    ear_mask = elliptical_cylinder_mask(ear, a, b, offset, side=side)
    if not ear_mask.all():
       import warnings
       warnings.simplefilter(f'Not all of the ear was removed. Try again with a bigger spazi.')

    # compute the vertex mask
    vert_mask = elliptical_cylinder_mask(head, a, b, offset, side=side)


    # select the faces to remove
    n = len(head.faces)
    vert_ind = np.argwhere(vert_mask)
    mask = np.ones(n, dtype=bool)
    mask[vert_ind] = False
    face_mask = mask[head.faces].any(axis=1)

    # remove faces and update verticess
    head.update_faces(face_mask)
    head.remove_unreferenced_vertices()  # automatically removes all vertices not used by faces

    return head


# Create elliptical cylindermask
def elliptical_cylinder_mask(mesh, a, b, offset, side='left'):
    # Ellipse condition in the xz-plane (since the cylinder is along the y-axis)
    x_cond = ((mesh.vertices[:, 0] - offset[0])/ b) ** 2
    z_cond = ((mesh.vertices[:, 2] - offset[1])/ a) ** 2
    ellipse_condition = x_cond + z_cond <= 1

    # Left or Right ear cut
    if side == 'left':  # if ear is on left side
        y_condition = (mesh.vertices[:, 1] >= 0)
    elif side == 'right':  # right side
        y_condition = (mesh.vertices[:, 1] <= 0) 
    else:
        raise Exception('Inconclusive LorR parameter. Please use \'left\' or \'right\'.')

    # Both conditions must be satisfied for a vertex to be inside the cylinder
    mask = ellipse_condition & y_condition
    return mask


if __name__ == "__main__":
    # Argument parsing
    parser = argparse.ArgumentParser()
    parser.add_argument('--head_path', type=str, required=True, help='Path to the head mesh')
    parser.add_argument('--ear_path', type=str, required=True, help='Path to the ear mesh')
    parser.add_argument('--export_path', type=str, required=True, help='Path to save the cut head to')
    parser.add_argument('--spazi', type=float, required=False, default=1.3, help='Factor for spacing around the ear. Default is 1.3')
    args = parser.parse_args()

    head_path = args.head_path
    ear_path = args.ear_path
    export_path = args.export_path
    spazi = args.spazi

    # File loadup and function call
    head = trimesh.load(head_path)
    ear = trimesh.load(ear_path)

    head = cut_eararea(head, ear, spazi=spazi)

    # Export
    head.export(export_path)


# For debugging only
#head.show(viewer='gl')