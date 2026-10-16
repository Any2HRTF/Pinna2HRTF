"""Regression checks for preparation routing, geometry, and stale-output guards.

Run: .venv/bin/python -m unittest discover -s Tests -p 'test_*.py'
"""
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import trimesh
from pydantic import ValidationError

from HRTFCalculation.Config import PipelineConfig, ScanPreparationConfig, load_config, save_config
from HRTFCalculation import RunConfig
from HRTFCalculation.ScanPreparation import (
    boundary_loop_sizes, cap_non_attachment_boundaries, clip_mesh_to_plane,
    record_stage, validate_stage,
)


class ScanPreparationTests(unittest.TestCase):
    def test_existing_projects_keep_explicit_ears(self):
        config = PipelineConfig()
        self.assertFalse(config.scan_preparation.enabled)
        self.assertEqual(RunConfig.input_paths(config), (config.paths.left_ear, config.paths.right_ear))

    def test_single_ear_preparation_routes_all_downstream_projects(self):
        config = PipelineConfig(scan_preparation=ScanPreparationConfig(enabled=True, prepare_left=False))
        config.paths.output_dir = Path('/tmp/example')
        self.assertEqual(RunConfig.input_paths(config), (None, Path('/tmp/example/Prepared/Right.stl')))
        self.assertEqual(RunConfig.project_dirs(config), [Path('/tmp/example/Projects/Right')])
        config.scan_preparation.prepare_right = False
        with self.assertRaisesRegex(ValueError, 'at least one'):
            RunConfig.input_paths(config)

    def test_relative_scan_paths_and_settings_roundtrip(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            config = PipelineConfig(scan_preparation=ScanPreparationConfig(enabled=True, scan_path=Path('scan.stl'), rotation_degrees=270))
            save_config(config, folder / 'project.yaml')
            loaded = load_config(folder / 'project.yaml')
            self.assertEqual(loaded.scan_preparation.scan_path, (folder / 'scan.stl').resolve())
            self.assertEqual(loaded.scan_preparation.rotation_degrees, 270)

    def test_invalid_crop_settings_rejected(self):
        for values in [dict(target_edge_mm=0), dict(rotation_degrees=float('nan')),
                       dict(side_min_mm=110, side_max_mm=30), dict(crop_polygon_xz=[(0,0),(1,0),(0,0)])]:
            with self.subTest(values=values), self.assertRaises(ValidationError):
                ScanPreparationConfig(**values)

    def test_all_runs_preparation_before_inference_and_preprocessing(self):
        config = PipelineConfig()
        config.scan_preparation.enabled = True
        config.inference.enabled = True
        events = []
        with patch.object(RunConfig, 'run_scan_preparation', side_effect=lambda *a: events.append('scan')), \
             patch.object(RunConfig, 'run_inference', side_effect=lambda *a: events.append('inference')), \
             patch.object(RunConfig, 'run_preprocessing', side_effect=lambda *a: events.append('preprocessing')):
            RunConfig.run_from_config(config)
        self.assertEqual(events, ['scan', 'inference', 'preprocessing'])

    def test_inference_dry_run_resolves_prepared_inputs_without_loading_geometry(self):
        config = PipelineConfig(scan_preparation=ScanPreparationConfig(enabled=True, prepare_right=False))
        messages = []
        RunConfig.run_inference(config, True, messages.append)
        self.assertTrue(any('Prepared/Left.stl' in message for message in messages))
        self.assertIsNotNone(config.paths.right_ear)  # The caller's settings remain intact.

    def test_clip_preserves_intersections_and_produces_finite_mesh(self):
        mesh = trimesh.creation.box(extents=(2, 2, 2))
        cut = clip_mesh_to_plane(mesh, np.array([1.,0,0]), np.zeros(3))
        cut.merge_vertices()
        self.assertTrue(np.all(cut.vertices[:,0] >= -1e-9))
        self.assertTrue(np.isfinite(cut.vertices).all())
        self.assertEqual(len(boundary_loop_sizes(cut)), 1)

    def test_fan_caps_defect_but_preserves_attachment_boundary(self):
        # Two holes in a triangulated plane: a larger outside boundary and a square defect.
        vertices = np.array([[-2,-2,0],[2,-2,0],[2,2,0],[-2,2,0],
                             [-1,-1,0],[1,-1,0],[1,1,0],[-1,1,0]],dtype=float)
        # Split an outside edge so the outer boundary is strictly larger.
        vertices = np.vstack([vertices,[0,-2,0]])
        faces = [[0,8,4],[8,5,4],[8,1,5],[1,2,6],[1,6,5],
                 [2,3,7],[2,7,6],[3,0,4],[3,4,7]]
        mesh = trimesh.Trimesh(vertices=vertices, faces=faces, process=False)
        self.assertEqual(boundary_loop_sizes(mesh), [5,4])
        closed = cap_non_attachment_boundaries(mesh)
        self.assertEqual(boundary_loop_sizes(closed), [5])
        self.assertTrue(closed.is_winding_consistent)

    def test_receipts_reject_prior_generation_and_edited_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            config = PipelineConfig()
            config.paths.output_dir = Path(temporary)
            folder = Path(temporary) / 'Prepared'
            folder.mkdir()
            report = folder / 'mesh_preparation.json'
            report.write_text(json.dumps(dict(generation='first')))
            output = Path(temporary) / 'prediction.stl'
            output.write_text('mesh')
            record_stage(config, 'inference', [output])
            validate_stage(config, 'inference')
            output.write_text('edited')
            with self.assertRaisesRegex(ValueError, 'output changed'):
                validate_stage(config, 'inference')
            output.write_text('mesh')
            report.write_text(json.dumps(dict(generation='second')))
            with self.assertRaisesRegex(ValueError, 'again after'):
                validate_stage(config, 'inference')


if __name__ == '__main__':
    unittest.main()
