import json
from pathlib import Path
import tempfile
import unittest

import numpy as np
import trimesh

from HRTFCalculation.Config import PipelineConfig, ScanPreparationConfig
from HRTFCalculation.MeshEditing import (cut_plane, delete_faces, digest, execute,
    nose_ear_transform, load, reviewed_inputs, topology, validate_ear)
from HRTFCalculation.ScanPreparation import preparation_signature, record_stage, validate_stage


class MeshEditingTests(unittest.TestCase):
    def ear(self):
        mesh = trimesh.creation.icosphere(subdivisions=3, radius=10)
        mesh.apply_translation([0,70,0])
        return cut_plane(mesh, [0,1,0], [0,65,0])

    def test_nose_ear_alignment_is_rigid_and_right_handed(self):
        reference = np.array([[60,35,0], [0,70,0], [0,-70,0]], dtype=float)
        matrix = trimesh.transformations.euler_matrix(.3,-.7,1.1)
        matrix[:3,3] = [10,-25,55]
        points = trimesh.transform_points(reference, matrix)
        transform = nose_ear_transform(points)
        aligned = trimesh.transform_points(points, transform)
        np.testing.assert_allclose(aligned, reference, atol=1e-10)
        np.testing.assert_allclose((aligned[1] + aligned[2]) / 2, [0,0,0], atol=1e-10)
        np.testing.assert_allclose(aligned[:,2], 0, atol=1e-10)
        self.assertGreater(aligned[0,0], 0)
        self.assertGreater(aligned[1,1], aligned[2,1])
        np.testing.assert_allclose(transform[:3,:3] @ transform[:3,:3].T, np.eye(3), atol=1e-12)
        self.assertAlmostEqual(np.linalg.det(transform[:3,:3]), 1)

    def test_alignment_records_nose_ear_method_and_preserves_original(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            reference = np.array([[60,35,0], [0,70,0], [0,-70,0]], dtype=float)
            rotation = trimesh.transformations.euler_matrix(.3,-.7,1.1)
            rotation[:3,3] = [10,-25,55]
            points = trimesh.transform_points(reference, rotation)
            mesh = trimesh.Trimesh(vertices=np.vstack([reference, [0,0,80]]),
                                   faces=[[0,1,2], [0,3,1], [0,2,3], [1,3,2]], process=False)
            mesh.apply_transform(rotation)
            source = folder/'scan.ply'; mesh.export(source)
            original = digest(source)
            working = folder/'aligned.ply'
            result = execute(dict(action='align', source=str(source), output=str(working),
                                  frame=str(folder/'frame'), points=points.tolist()))
            self.assertEqual(result['alignment_method'], 'nose_and_ear_entrances')
            self.assertEqual(result['landmark_labels'],
                             ['nose_tip', 'left_ear_canal_entrance', 'right_ear_canal_entrance'])
            np.testing.assert_allclose(load(working).vertices[:3], reference, atol=1e-5)
            operation = dict(action='align', points=points.tolist(), **{
                key: result[key] for key in ('transform', 'alignment_method', 'landmark_labels')})
            destination = folder/'MeshEdits'/'AlignedScan.ply'
            execute(dict(action='save', kind='alignment', source=str(working),
                         original_source=str(source), original_sha256=original,
                         destination=str(destination), operations=[operation]))
            receipt = json.loads(destination.with_suffix('.json').read_text())
            self.assertEqual(receipt['operations'], [operation])
            self.assertEqual(receipt['output_sha256'], digest(destination))
            self.assertEqual(digest(source), original)

    def test_degenerate_landmarks_rejected(self):
        for points in [[[0,0,0]]*3, [[0,1,0],[0,-1,0],[0,0,0]], [[0,1,0],[0,-1,0],[float('nan'),0,0]]]:
            with self.assertRaises(ValueError): nose_ear_transform(points)

    def test_opening_canal_and_trimming_attachment_preserves_two_open_loops(self):
        original = self.ear()
        self.assertEqual(validate_ear(original)['boundary_components'], 1)
        removed = np.flatnonzero(original.triangles_center[:,1] > 79)
        opened = delete_faces(original, removed)
        self.assertEqual(validate_ear(opened)['boundary_components'], 2)
        trimmed = cut_plane(opened, [0,1,0], [0,67,0])
        checks = validate_ear(trimmed)
        self.assertEqual(checks['boundary_components'], 2)
        self.assertTrue(np.all(trimmed.vertices[:,1] >= 67-1e-6))
        self.assertEqual(topology(original)['boundary_components'], 1)  # No in-place edit.

    def test_empty_edits_rejected(self):
        mesh = self.ear()
        with self.assertRaises(ValueError): delete_faces(mesh, list(range(len(mesh.faces))))
        with self.assertRaises(ValueError): cut_plane(mesh, [0,1,0], [0,90,0])
        with self.assertRaises(ValueError): cut_plane(mesh, [0,0,0], [0,0,0])

    def test_binary_viewer_indices_match_backend_face_indices(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary); source=folder/'ear.stl'; original=self.ear(); original.export(source)
            working=folder/'working.ply'
            result=execute(dict(action='open',source=str(source),output=str(working),frame=str(folder/'frame')))
            vertices=np.fromfile(result['vertices'],dtype='<f4').reshape(-1,3)
            faces=np.fromfile(result['faces'],dtype='<u4').reshape(-1,3)
            mesh=load(working)
            np.testing.assert_array_equal(faces,mesh.faces)
            np.testing.assert_allclose(vertices[faces],mesh.triangles,rtol=0,atol=1e-5)
            face_ids=np.flatnonzero(mesh.triangles_center[:,1]>79).tolist()
            execute(dict(action='delete',source=str(working),output=str(folder/'edited.ply'),frame=str(folder/'frame'),faces=face_ids))
            self.assertEqual(validate_ear(load(folder/'edited.ply'))['boundary_components'],2)
            self.assertEqual(digest(source),result['source_sha256'])

    def test_review_receipt_routes_edits_and_invalidates_later_stages(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary); prepared=folder/'Prepared';prepared.mkdir()
            source=prepared/'Left.stl';self.ear().export(source)
            report=prepared/'mesh_preparation.json';report.write_text(json.dumps(dict(generation='g1')))
            mesh=load(source,merge=True)
            opened=delete_faces(mesh,np.flatnonzero(mesh.triangles_center[:,1]>79))
            working=folder/'working.ply';opened.export(working)
            destination=folder/'MeshEdits'/'Left.stl'
            note=execute(dict(action='save',kind='ear',source=str(working),original_source=str(source),original_sha256=digest(source),destination=str(destination),side='left',prepared_report=str(report),prepared_generation='g1'))
            self.assertEqual(note['metrics']['boundary_components'],2)
            self.assertEqual(validate_ear(load(destination,merge=True))['boundary_components'],2)
            config=PipelineConfig(scan_preparation=ScanPreparationConfig(enabled=True,prepare_right=False,reviewed_left=destination))
            config.paths.output_dir=folder
            self.assertEqual(reviewed_inputs(config),(destination,None))
            output=folder/'prediction.stl';output.write_text('prediction')
            record_stage(config,'inference',[output]);validate_stage(config,'inference')
            # A new saved geometry edit has the same preparation generation, but a different hash.
            new_mesh=cut_plane(opened,[0,1,0],[0,67,0]);new_mesh.export(working)
            execute(dict(action='save',kind='ear',source=str(working),original_source=str(source),original_sha256=digest(source),destination=str(destination),side='left',prepared_report=str(report),prepared_generation='g1'))
            with self.assertRaisesRegex(ValueError,'ear edits changed'): validate_stage(config,'inference')
            report.write_text(json.dumps(dict(generation='g2')))
            with self.assertRaisesRegex(ValueError,'out of date'): reviewed_inputs(config)

    def test_optional_review_does_not_change_preparation_signature(self):
        with tempfile.TemporaryDirectory() as temporary:
            source=Path(temporary)/'scan.stl';source.write_text('scan')
            settings=ScanPreparationConfig(scan_path=source)
            original=preparation_signature(settings)
            settings.require_manual_review=True;settings.reviewed_left=Path('/tmp/edited.stl')
            self.assertEqual(preparation_signature(settings),original)
            config=PipelineConfig(scan_preparation=ScanPreparationConfig(enabled=True,prepare_right=False))
            config.paths.output_dir=Path(temporary)
            self.assertEqual(reviewed_inputs(config),(Path(temporary)/'Prepared/Left.stl',None))
            config.scan_preparation.require_manual_review=True
            with self.assertRaisesRegex(ValueError,'Review and save'): reviewed_inputs(config)

    def test_save_rejects_changed_source_and_preserves_prior_saved_ear(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);source=folder/'source.stl';self.ear().export(source)
            digest_before=digest(source);destination=folder/'saved.stl';destination.write_bytes(b'prior manual work')
            source.write_bytes(b'changed externally')
            with self.assertRaisesRegex(ValueError,'source mesh changed'):
                execute(dict(action='save',kind='ear',source=str(source),original_source=str(source),original_sha256=digest_before,destination=str(destination)))
            self.assertEqual(destination.read_bytes(),b'prior manual work')


if __name__ == '__main__': unittest.main()
