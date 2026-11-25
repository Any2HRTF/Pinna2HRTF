import numpy as np
import trimesh


def geometric_torso(head_mesh, head_radius, width_mm=459.0, depth_mm=238.68, height_mm=134.2):
    import pymeshlab
    dimensions = np.array([width_mm, depth_mm, height_mm, head_radius], dtype=float)
    if not np.isfinite(dimensions).all() or np.any(dimensions <= 0):
        raise ValueError("Torso dimensions and head radius must be finite and positive.")
    top_z = -139.6
    torso = trimesh.creation.icosphere(subdivisions=4, radius=1.0)
    torso.apply_scale([depth_mm / 2, width_mm / 2, height_mm])
    torso = torso.slice_plane([0, 0, 0], [0, 0, 1], cap=True, engine="triangle")
    torso.apply_translation([0, 0, top_z - height_mm])
    neck_radius = 0.77 * head_radius
    bottom_z = top_z - height_mm / 2
    neck = trimesh.creation.cylinder(radius=neck_radius, height=-bottom_z, sections=64)
    neck.apply_translation([0, 0, bottom_z / 2])
    combined = head_mesh
    for name, part in (("neck", neck), ("torso", torso)):
        mesh_set = pymeshlab.MeshSet()
        for mesh in (combined, part):
            if not mesh.is_volume:
                raise ValueError("Head, neck and torso must be closed, consistently oriented solids.")
            mesh_set.add_mesh(pymeshlab.Mesh(vertex_matrix=mesh.vertices, face_matrix=mesh.faces))
        mesh_set.generate_boolean_union(first_mesh=0, second_mesh=1)
        result = mesh_set.current_mesh()
        combined = trimesh.Trimesh(vertices=result.vertex_matrix(), faces=result.face_matrix(), process=True, validate=True)
        if not combined.is_volume or combined.body_count != 1:
            raise ValueError(f"The {name} could not be joined to the head as one closed surface. Check the head and torso dimensions.")
    return combined
