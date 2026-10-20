"""Non-destructive mesh editing backend for the macOS preparation workspace.

Alignment landmarks: nose tip, left ear-canal entrance, right ear-canal entrance.
The rigid frame uses +X toward the nose, +Y left, +Z superior, with the ear
midpoint at the origin. This reference plane is not the anatomical Frankfort plane.
Face deletion and plane cuts deliberately leave open edges; no hole filling or
reconstruction runs after a manual edit.
"""
from __future__ import annotations

from .FileIdentity import sha256 as digest, file_identity as identity
import json
from pathlib import Path
import uuid

import networkx as nx
import numpy as np
import trimesh


def load(path, merge=False):
    mesh = trimesh.load_mesh(path, process=False)
    if isinstance(mesh, trimesh.Scene):
        mesh = trimesh.util.concatenate(tuple(mesh.geometry.values()))
    if merge:
        mesh.merge_vertices()
        mesh.remove_unreferenced_vertices()
    if not len(mesh.faces) or not np.isfinite(mesh.vertices).all():
        raise ValueError('The mesh must contain finite, nonempty triangle geometry.')
    return mesh


def nose_ear_transform(points):
    points = np.asarray(points, dtype=float)
    if points.shape != (3, 3) or not np.isfinite(points).all():
        raise ValueError('Pick the nose tip, left ear-canal entrance, and right ear-canal entrance.')
    nose, left, right = points
    origin = (left + right) / 2
    lateral = left - right
    if np.linalg.norm(lateral) < 1e-6:
        raise ValueError('The two ear-canal entrance landmarks must be distinct.')
    lateral /= np.linalg.norm(lateral)
    anterior = nose - origin
    anterior -= np.dot(anterior, lateral) * lateral
    if np.linalg.norm(anterior) < 1e-6:
        raise ValueError('The three landmarks must not lie on one line.')
    anterior /= np.linalg.norm(anterior)
    superior = np.cross(anterior, lateral)
    rotation = np.stack([anterior, lateral, superior])
    matrix = np.eye(4)
    matrix[:3, :3] = rotation
    matrix[:3, 3] = -rotation @ origin
    return matrix


def cut_plane(mesh, normal, origin):
    normal, origin = np.asarray(normal, dtype=float), np.asarray(origin, dtype=float)
    if normal.shape != (3,) or origin.shape != (3,) or not np.isfinite([normal, origin]).all() or np.linalg.norm(normal) < 1e-9:
        raise ValueError('Enter a finite, nonzero cutting-plane normal and origin.')
    result = trimesh.intersections.slice_mesh_plane(mesh, normal / np.linalg.norm(normal), origin, cap=False)
    if not len(result.faces):
        raise ValueError('This cut removes the entire mesh. Flip the kept side or move the plane.')
    result.merge_vertices()
    result.remove_unreferenced_vertices()
    return result


def delete_faces(mesh, indices):
    indices = np.asarray(indices, dtype=int)
    if not len(indices) or np.any(indices < 0) or np.any(indices >= len(mesh.faces)):
        raise ValueError('Select valid mesh faces before deleting.')
    keep = np.ones(len(mesh.faces), dtype=bool)
    keep[indices] = False
    if not np.any(keep):
        raise ValueError('The selection removes the entire mesh.')
    result = mesh.submesh([np.flatnonzero(keep)], append=True, repair=False)
    result.remove_unreferenced_vertices()
    return result


def topology(mesh):
    edges, counts = np.unique(mesh.edges_sorted, axis=0, return_counts=True)
    boundary = nx.Graph(edges[counts == 1].tolist())
    loops = list(nx.connected_components(boundary))
    return dict(vertices=len(mesh.vertices), faces=len(mesh.faces),
                components=len(mesh.split(only_watertight=False, repair=False)),
                boundary_components=len(loops),
                simple_boundaries=all(degree == 2 for _, degree in boundary.degree),
                manifold=bool(np.all(counts <= 2)),
                finite=bool(np.isfinite(mesh.vertices).all()),
                winding_consistent=bool(mesh.is_winding_consistent))


def validate_ear(mesh):
    checks = topology(mesh)
    if not checks['finite'] or not checks['winding_consistent'] or not checks['manifold']:
        raise ValueError('The edited ear has invalid geometry or inconsistent winding. Undo the last edit.')
    if checks['components'] != 1:
        raise ValueError('The edited ear has disconnected pieces. Undo the edit or use Keep Largest Component.')
    if not checks['simple_boundaries'] or checks['boundary_components'] not in (1, 2):
        raise ValueError('Keep one simple attachment boundary and, optionally, one ear-canal opening. Undo stray cuts or selections.')
    return checks


def frame(mesh, folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    np.asarray(mesh.vertices, dtype='<f4').tofile(folder / 'vertices.bin')
    np.asarray(mesh.vertex_normals, dtype='<f4').tofile(folder / 'normals.bin')
    np.asarray(mesh.faces, dtype='<u4').tofile(folder / 'faces.bin')
    return dict(vertices=str(folder / 'vertices.bin'), normals=str(folder / 'normals.bin'),
                faces=str(folder / 'faces.bin'), bounds=mesh.bounds.tolist(),
                vertex_count=len(mesh.vertices), face_count=len(mesh.faces))


def execute(request):
    action = request['action']
    if action == 'open':
        mesh = load(request['source'], merge=True)
        path = Path(request['output'])
        path.parent.mkdir(parents=True, exist_ok=True)
        mesh.export(path)
        return dict(frame(mesh, request['frame']), source_sha256=digest(request.get('original_source', request['source'])))
    if action == 'inspect':
        return frame(load(request['source']), request['frame'])
    if action == 'save':
        source = Path(request['original_source'])
        if digest(source) != request['original_sha256']:
            raise ValueError('The source mesh changed while editing. Reopen the editor before saving.')
        mesh = load(request['source'], merge=True)
        mesh.fix_normals()
        if mesh.volume < 0:
            mesh.invert()
        checks = validate_ear(mesh) if request['kind'] == 'ear' else topology(mesh)
        report = dict(source_path=str(source.resolve()), source_sha256=request['original_sha256'], source_identity=identity(source),
                      kind=request['kind'], operations=request.get('operations', []), metrics=checks)
        if request['kind'] == 'ear':
            prepared = json.loads(Path(request['prepared_report']).read_text())
            if prepared['generation'] != request['prepared_generation']:
                raise ValueError('Scan preparation changed while editing. Reopen the prepared ear.')
            report['generation'] = prepared['generation']
            report['side'] = request['side']
        destination = Path(request['destination'])
        if destination.resolve() == source.resolve():
            raise ValueError('Save edits as a separate mesh; the source is read only.')
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(f'.{destination.stem}-{uuid.uuid4().hex}{destination.suffix}')
        try:
            mesh.export(temporary)
            exported = load(temporary, merge=True)
            if request['kind'] == 'ear':
                validate_ear(exported)
            temporary.replace(destination)
        finally:
            temporary.unlink(missing_ok=True)
        report['output_sha256'] = digest(destination)
        report['output_identity'] = identity(destination)
        report['edit_generation'] = uuid.uuid4().hex
        note = destination.with_suffix('.json')
        temp_note = note.with_name('.' + note.name + '.tmp')
        temp_note.write_text(json.dumps(report, indent=2) + '\n')
        temp_note.replace(note)
        return report
    mesh = load(request['source'])
    if action == 'align':
        matrix = nose_ear_transform(request['points'])
        mesh.apply_transform(matrix)
    elif action == 'delete':
        mesh = delete_faces(mesh, request['faces'])
    elif action == 'cut':
        mesh = cut_plane(mesh, request['normal'], request['origin'])
    elif action == 'largest':
        components = mesh.split(only_watertight=False, repair=False)
        mesh = max(components, key=lambda item: len(item.faces))
    else:
        raise ValueError(f'Unknown mesh edit: {action}')
    mesh.export(request['output'])
    result = frame(mesh, request['frame'])
    if action == 'align':
        result['transform'] = matrix.tolist()
        result['alignment_method'] = 'nose_and_ear_entrances'
        result['landmark_labels'] = ['nose_tip', 'left_ear_canal_entrance', 'right_ear_canal_entrance']
    return result


def reviewed_inputs(config, validate=True):
    """Use current manual ear edits when available; otherwise use prepared meshes."""
    folder = config.paths.output_dir / 'Prepared'
    settings = config.scan_preparation
    report = None
    results = []
    for side, selected, reviewed_attr in (
        ('left', settings.prepare_left, 'reviewed_left'),
        ('right', settings.prepare_right, 'reviewed_right'),
    ):
        if not selected:
            results.append(None)
            continue
        reviewed = getattr(settings, reviewed_attr)
        base = folder / f'{side.title()}.stl'
        if reviewed is None:
            results.append(base)
            continue
        path = Path(reviewed)
        if validate:
            try:
                if report is None:
                    report = json.loads((folder / 'mesh_preparation.json').read_text())
                receipt = json.loads(path.with_suffix('.json').read_text())
                current = (receipt.get('kind') == 'ear' and receipt.get('side') == side and
                           receipt.get('generation') == report['generation'] and
                           receipt.get('source_sha256') == digest(base) and
                           receipt.get('output_sha256') == digest(path))
            except (OSError, ValueError, KeyError, TypeError):
                current = False
            if not current:
                print(f'Saved {side} ear review is out of date; using the current prepared mesh.', flush=True)
                setattr(settings, reviewed_attr, None)
                results.append(base)
                continue
            validate_ear(load(path, merge=True))
        results.append(path)
    return tuple(results)
