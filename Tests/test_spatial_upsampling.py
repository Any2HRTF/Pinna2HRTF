import json
from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import numpy as np
from pydantic import ValidationError
from HRTFCalculation.Config import PipelineConfig, PostprocessingConfig
from HRTFCalculation import RunConfig
from HRTFCalculation.Postprocessing import spatial_upsampling as up


class SpatialUpsamplingChecks(unittest.TestCase):
    def test_defaults_validation_and_matlab_quoting(self):
        self.assertFalse(PostprocessingConfig().spatial_upsampling)
        self.assertEqual(PostprocessingConfig().spatial_subdivisions, 3)
        for value in [-1, 6]:
            with self.assertRaises(ValidationError):
                PostprocessingConfig(spatial_subdivisions=value)
        self.assertEqual(up.dense_name(0), 'hrtf_Nd=0_dense.sofa')
        self.assertEqual(up._matlab_string(Path("/a space/don't.m")), "'/a space/don''t.m'")

    def test_missing_matlab_is_reported(self):
        with TemporaryDirectory() as directory:
            with self.assertRaisesRegex(ValueError, 'requires MATLAB'):
                up.resolve_dependencies(PostprocessingConfig(matlab_executable=Path(directory)/'missing'))

    def test_preflight_preserves_exports_if_dependency_missing(self):
        with TemporaryDirectory() as directory:
            config = PipelineConfig().resolved()
            config.postprocessing.output_sofa_dir = Path(directory)
            config.postprocessing.spatial_upsampling = True
            sentinel = Path(directory)/'existing.sofa'
            sentinel.write_bytes(b'keep')
            with patch.dict('sys.modules', {'mesh2hrtf': Mock()}), patch.object(up, 'resolve_dependencies', side_effect=ValueError('MATLAB missing')):
                with self.assertRaisesRegex(ValueError, 'MATLAB missing'):
                    RunConfig.run_postprocessing(config, False, lambda _: None)
            self.assertEqual(sentinel.read_bytes(), b'keep')

    def test_pipeline_upsamples_after_binaural_merge(self):
        with TemporaryDirectory() as directory:
            config = PipelineConfig().resolved()
            config.paths.output_dir = Path(directory)
            config.postprocessing.output_sofa_dir = Path(directory)/'HRTF'
            config.postprocessing.spatial_upsampling = True
            events = []
            m2h = Mock()
            m2h.output2hrtf.side_effect = lambda _: events.append('convert')
            m2h.merge_sofa_files.side_effect = lambda *a, **k: events.append('merge')
            m2h.inspect_sofa_files.side_effect = lambda *a, **k: events.append('plot')
            with patch.dict('sys.modules', {'mesh2hrtf': m2h, 'HRTFCalculation.Postprocessing.postprocessing': Mock()}), patch.object(up, 'resolve_dependencies'), patch.object(up, 'upsample_hrtf_files', side_effect=lambda *a: events.append('upsample')):
                RunConfig.run_postprocessing(config, False, lambda _: None)
            self.assertEqual(events, ['convert', 'convert', 'merge', 'upsample', 'plot', 'plot'])

    def test_publish_and_failure_are_atomic_and_preserve_input(self):
        for fail in [False, True]:
            with self.subTest(fail=fail), TemporaryDirectory(prefix="pinna quote's ") as directory:
                root = Path(directory)
                source = root/'HRIR_test.sofa'
                source.write_bytes(b'original')
                original = SimpleNamespace(Data_IR=np.ones((8, 2, 16)), Data_SamplingRate=48000)
                dense = SimpleNamespace(Data_IR=np.ones((16, 2, 16)), Data_SamplingRate=48000, Data_Delay=np.zeros((1, 2)))
                sofa = Mock()
                sofa.read_sofa.side_effect = lambda path, **kw: original if Path(path) == source else dense
                def run(command, **kwargs):
                    self.assertEqual(command[1], '-batch')
                    self.assertIn("quote''s", command[2])
                    self.assertTrue(kwargs['check'])
                    plan = json.loads(next(root.glob('.pinna*/plan.json')).read_text())
                    self.assertEqual(plan['subdivisions'], 3)
                    job = plan['jobs'][0]
                    output = Path(job['output'])
                    output.mkdir(parents=True)
                    (output/'hrtf_Nd=3.sofa').write_bytes(b'dense')
                    if fail:
                        raise subprocess.CalledProcessError(1, command)
                with patch.dict('sys.modules', {'sofar': sofa}), patch.object(up, 'resolve_dependencies', return_value=(Path('/matlab'), Path('/amt'))), patch.object(up.subprocess, 'run', side_effect=run):
                    if fail:
                        with self.assertRaises(subprocess.CalledProcessError):
                            up.upsample_hrtf_files(root, PostprocessingConfig(), lambda _: None)
                        self.assertFalse((root/'Upsampled').exists())
                    else:
                        up.upsample_hrtf_files(root, PostprocessingConfig(), lambda _: None)
                        receipt = json.loads((root/'Upsampled/HRIR_test/upsampling.json').read_text())
                        self.assertEqual(receipt['output_directions'], 16)
                        self.assertEqual(receipt['input']['size'], len(b'original'))
                self.assertEqual(source.read_bytes(), b'original')
                self.assertEqual(list(root.glob('.pinna*')), [])
