"""
Stitches the given ear mesh to a head mesh with a hole instead of an ear and exports the result as a .stl.

Required input arguments:
head_path
ear_path
export_path

Lukas Thalhammer, Acoustics Research Institute
September 2024
"""

import argparse
import os
import bpy
import bmesh
import trimesh


def load_stl(file_path, name):
    bpy.ops.wm.stl_import(filepath=file_path)
    imported_obj = bpy.context.selected_objects[0]
    imported_obj.name = name
    return imported_obj


def join_meshes(objects):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = objects[0]
    bpy.ops.object.join()


def boundary_components(bm):
    bm.edges.ensure_lookup_table()
    visited = set()
    components = []
    for edge in bm.edges:
        if not edge.is_boundary or edge.index in visited:
            continue
        stack = [edge]
        visited.add(edge.index)
        component = []
        while stack:
            current = stack.pop()
            component.append(current)
            for vert in current.verts:
                for next_edge in vert.link_edges:
                    if next_edge.is_boundary and next_edge.index not in visited:
                        visited.add(next_edge.index)
                        stack.append(next_edge)
        components.append(component)
    return components


def fill_boundaries(seam_smoothing_iterations=0, seam_smoothing_factor=0.35):
    obj = bpy.context.active_object
    if obj.type != 'MESH':
        raise TypeError("Active object is not a mesh")

    bpy.ops.object.mode_set(mode='EDIT')
    bm = bmesh.from_edit_mesh(obj.data)

    components = sorted(boundary_components(bm), key=len, reverse=True)
    bridge_faces = []
    if len(components) >= 2:
        try:
            result = bmesh.ops.bridge_loops(bm, edges=components[0] + components[1])
            bridge_faces = [face for face in result.get('faces', []) if isinstance(face, bmesh.types.BMFace)]
        except Exception:
            pass

    if bridge_faces and seam_smoothing_iterations > 0:
        seam_verts = sorted({vert for face in bridge_faces for vert in face.verts}, key=lambda vert: vert.index)
        for _ in range(seam_smoothing_iterations):
            bmesh.ops.smooth_vert(bm, verts=seam_verts, factor=seam_smoothing_factor, use_axis_x=True, use_axis_y=True, use_axis_z=True)

    components = boundary_components(bm)
    for component in components:
        try:
            bmesh.ops.holes_fill(bm, edges=component, sides=0)
        except Exception:
            pass

    loose = [vert for vert in bm.verts if len(vert.link_faces) == 0]
    if len(loose) > 0:
        bmesh.ops.delete(bm, geom=loose, context='VERTS')

    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)

    bmesh.update_edit_mesh(obj.data)
    bpy.ops.object.mode_set(mode='OBJECT')


def head_stitcher(head_path, ear_path, export_path, seam_smoothing_iterations=0, seam_smoothing_factor=0.35):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    head = load_stl(head_path, 'head')
    ear = load_stl(ear_path, 'ear')
    join_meshes([head, ear])
    fill_boundaries(seam_smoothing_iterations=seam_smoothing_iterations, seam_smoothing_factor=seam_smoothing_factor)
    bpy.ops.wm.stl_export(filepath=export_path)

    mesh = trimesh.load(export_path)
    components = mesh.split(only_watertight=False)
    if len(components) > 1:
        largest = max(components, key=lambda component: len(component.faces))
        stray_faces = sum(len(component.faces) for component in components if component is not largest)
        if stray_faces <= max(10, int(len(largest.faces) * 0.001)):
            mesh = largest
        else:
            if os.path.exists(export_path):
                os.remove(export_path)
            raise RuntimeError(f"Stitching failed: expected a single connected component, found {len(components)}.")
    mesh.remove_unreferenced_vertices()
    mesh.export(export_path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument('--head_path', type=str, required=True, help='Path to the head mesh with cut out ears')
    parser.add_argument('--ear_path', type=str, required=True, help='Path to the ear mesh')
    parser.add_argument('--export_path', type=str, required=True, help='Path to save the stitched head to')
    parser.add_argument('--seam-smoothing-iterations', type=int, default=0)
    parser.add_argument('--seam-smoothing-factor', type=float, default=0.35)
    args = parser.parse_args()

    head_path = args.head_path
    ear_path = args.ear_path
    export_path = args.export_path

    head_stitcher(head_path=head_path, ear_path=ear_path, export_path=export_path, seam_smoothing_iterations=args.seam_smoothing_iterations, seam_smoothing_factor=args.seam_smoothing_factor)
