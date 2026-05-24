"""
Takes a head and an ear mesh and cuts an elliptical area with some extra space around the ear into the head.
Exports the result as a .stl to export_path.

Inputs:
head_path - path to head mesh as .stl file
ear_path - path to ear mesh as .stl file. Used to adapt the size of the ellipse
export_path
ear_cut_clearance_scale - a factor for the spacing around the ear. Default ist 1.3

Lukas Thalhammer, Acoustics Research Institute
September 2024
"""

import argparse
import numpy as np
import trimesh
from matplotlib.path import Path as MplPath
#import pyglet  # necessary for .show to work! Used for debugging only


def cut_eararea(head, ear, ear_cut_clearance_scale=1.3, side='auto', mode='ellipse'):
    """Cut an opening in `head` for the ear mesh.

    Parameters
    ----------
    head, ear : trimesh.Trimesh
    ear_cut_clearance_scale : float
        Only used when ``mode='ellipse'`` — multiplicative spacing around the
        ear's bounding box.
    side : {"auto", "left", "right"}
    mode : {"ellipse", "exact"}
        ``"ellipse"`` (default) preserves the original behaviour: cut along an
        axis-aligned elliptical cylinder sized from the ear's bounding box.
        ``"exact"`` projects the largest ear boundary loop onto the head and
        cuts along that silhouette in the XZ plane, giving a hole that follows
        the actual ear outline. Useful when the elliptical box is too large to
        leave a clean stitching boundary.
    """
    if mode not in ('ellipse', 'exact'):
        raise Exception(f"Unknown mode {mode!r}. Use 'ellipse' or 'exact'.")

    # Resolve side once, then dispatch.
    if side == 'auto':
        if ear.vertices[0, 1] > 0:
            side = 'left'
        else:
            side = 'right'
    elif side not in ('left', 'right'):
        raise Exception("Inconclusive side parameter. Please use 'auto', 'left' or 'right'.")

    if mode == 'ellipse':
        return _ellipse_cut(head, ear, ear_cut_clearance_scale, side)
    return _exact_cut(head, ear, side)


def _ellipse_cut(head, ear, ear_cut_clearance_scale, side):
    """Original behaviour: remove faces inside an axis-aligned elliptical cylinder."""
    a = ( np.abs(np.max(ear.vertices[:,2]) - np.min(ear.vertices[:,2])) / 2 ) * ear_cut_clearance_scale
    b = ( np.abs(np.max(ear.vertices[:,0]) - np.min(ear.vertices[:,0])) / 2 ) * ear_cut_clearance_scale*ear_cut_clearance_scale

    # compute center of the ear
    offset = ( (np.max(ear.vertices[:,0])+np.min(ear.vertices[:,0]))/2, (np.max(ear.vertices[:,2])+np.min(ear.vertices[:,2]))/2)

    # check if cylinder covers the whole ear
    ear_mask = elliptical_cylinder_mask(ear, a, b, offset, side=side)
    if not ear_mask.all():
       import warnings
       warnings.warn('Not all of the ear was removed. Try again with a bigger ear_cut_clearance_scale.')

    # compute the vertex mask
    vert_mask = elliptical_cylinder_mask(head, a, b, offset, side=side)


    # select the faces to remove
    n = len(head.vertices)
    vert_ind = np.argwhere(vert_mask)
    mask = np.ones(n, dtype=bool)
    mask[vert_ind] = False
    face_mask = mask[head.faces].any(axis=1)

    # remove faces and update verticess
    head.update_faces(face_mask)
    head.remove_unreferenced_vertices()  # automatically removes all vertices not used by faces

    return head


def cut_eararea_projected_footprint(head, ear, ear_cut_clearance_scale=1.3, projected_cut_margin=10.0, side='auto'):
    if side == 'auto':
        side = 'left' if np.mean(ear.vertices[:, 1]) >= 0 else 'right'
    elif side not in ('left', 'right'):
        raise Exception("Inconclusive side parameter. Please use 'auto', 'left' or 'right'.")

    margin = max(float(projected_cut_margin), 0.0)
    centers = np.asarray(head.triangles_center)
    ear_vertices = np.asarray(ear.vertices)
    x_min = np.min(ear_vertices[:, 0]) - margin
    x_max = np.max(ear_vertices[:, 0]) + margin
    z_min = np.min(ear_vertices[:, 2]) - margin
    z_max = np.max(ear_vertices[:, 2]) + margin
    if side == 'left':
        side_mask = centers[:, 1] >= 0
    else:
        side_mask = centers[:, 1] <= 0
    inside = (centers[:, 0] >= x_min) & (centers[:, 0] <= x_max) & (centers[:, 2] >= z_min) & (centers[:, 2] <= z_max)
    face_mask = ~(inside & side_mask)
    head.update_faces(face_mask)
    head.remove_unreferenced_vertices()
    return head


def _exact_cut(head, ear, side, contains_radius=0.5):
    entities = ear.outline().entities
    if len(entities) == 0:
        raise Exception("The ear mesh has no boundary loop. Check for non-manifolds!")
    boundary = max((entity.discrete(ear.vertices) for entity in entities), key=len)
    closest_points, _, _ = trimesh.proximity.closest_point(head, boundary)
    boundary_xz = np.column_stack([closest_points[:, 0], closest_points[:, 2]])
    cutting_path = MplPath(boundary_xz)
    face_centroids = head.triangles_center
    centroids_xz = np.column_stack([face_centroids[:, 0], face_centroids[:, 2]])
    inside_mask = cutting_path.contains_points(centroids_xz, radius=contains_radius)
    if side == 'left':
        y_mask = face_centroids[:, 1] >= 0
    else:
        y_mask = face_centroids[:, 1] <= 0
    head.update_faces(~(inside_mask & y_mask))
    head.remove_unreferenced_vertices()
    components = head.split(only_watertight=False)
    if len(components) > 1:
        head = max(components, key=lambda c: len(c.faces))
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
        raise Exception('Inconclusive side parameter. Please use \'left\' or \'right\'.')

    # Both conditions must be satisfied for a vertex to be inside the cylinder
    mask = ellipse_condition & y_condition
    return mask


if __name__ == "__main__":
    # Argument parsing
    parser = argparse.ArgumentParser()
    parser.add_argument('--head_path', type=str, required=True, help='Path to the head mesh')
    parser.add_argument('--ear_path', type=str, required=True, help='Path to the ear mesh')
    parser.add_argument('--export_path', type=str, required=True, help='Path to save the cut head to')
    parser.add_argument('--ear-cut-clearance-scale', type=float, required=False, default=1.3, help='Factor for spacing around the ear. Default is 1.3')
    parser.add_argument('--cut-mode', type=str, required=False, default='ellipse')
    parser.add_argument('--projected-cut-margin', type=float, required=False, default=10.0)
    parser.add_argument('--spazi', type=float, required=False, default=None, help=argparse.SUPPRESS)
    args = parser.parse_args()

    head_path = args.head_path
    ear_path = args.ear_path
    export_path = args.export_path
    ear_cut_clearance_scale = args.spazi if args.spazi is not None else args.ear_cut_clearance_scale

    # File loadup and function call
    head = trimesh.load(head_path)
    ear = trimesh.load(ear_path)

    if args.cut_mode == 'projected_footprint':
        head = cut_eararea_projected_footprint(head, ear, ear_cut_clearance_scale=ear_cut_clearance_scale, projected_cut_margin=args.projected_cut_margin)
    else:
        head = cut_eararea(head, ear, ear_cut_clearance_scale=ear_cut_clearance_scale)

    # Export
    head.export(export_path)


# For debugging only
#head.show(viewer='gl')
