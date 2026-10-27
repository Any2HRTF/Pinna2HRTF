import json
from pathlib import Path
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
    def test_defaults_and_validation(self):
        self.assertFalse(PostprocessingConfig().spatial_upsampling)
        self.assertEqual(PostprocessingConfig().spatial_subdivisions, 3)
        for value in [-1, 6]:
            with self.assertRaises(ValidationError):
                PostprocessingConfig(spatial_subdivisions=value)
        self.assertEqual(up.dense_name(0), 'hrtf_Nd=0_dense.sofa')
    def test_preflight_preserves_exports_if_dependency_missing(self):
        with TemporaryDirectory() as directory:
            config = PipelineConfig().resolved()
            config.postprocessing.output_sofa_dir = Path(directory)
            config.postprocessing.spatial_upsampling = True
            sentinel = Path(directory)/'existing.sofa'
            sentinel.write_bytes(b'keep')
            with patch.dict('sys.modules', {'mesh2hrtf': Mock()}), patch.object(up, 'resolve_dependencies', side_effect=ValueError('Python dependency missing')):
                with self.assertRaisesRegex(ValueError, 'Python dependency missing'):
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
                def run(source_path, output, subdivisions, normalize, logger):
                    self.assertEqual(subdivisions, 3)
                    output.mkdir(parents=True)
                    (output/'hrtf_Nd=3.sofa').write_bytes(b'dense')
                    if fail:
                        raise ValueError('interpolation failed')
                with patch.dict('sys.modules', {'sofar': sofa}), patch.object(up, 'resolve_dependencies'), patch.object(up, 'upsample_file', side_effect=run):
                    if fail:
                        with self.assertRaisesRegex(ValueError, 'interpolation failed'):
                            up.upsample_hrtf_files(root, PostprocessingConfig(), lambda _: None)
                        self.assertFalse((root/'Upsampled').exists())
                    else:
                        up.upsample_hrtf_files(root, PostprocessingConfig(), lambda _: None)
                        receipt = json.loads((root/'Upsampled/HRIR_test/upsampling.json').read_text())
                        self.assertEqual(receipt['output_directions'], 16)
                        self.assertEqual(receipt['implementation'], 'python-1')
                        self.assertEqual(receipt['input']['size'], len(b'original'))
                self.assertEqual(source.read_bytes(), b'original')
                self.assertEqual(list(root.glob('.pinna*')), [])


class MatlabReferenceChecks(unittest.TestCase):
    def test_original_matlab_reference_even_odd_normalized_and_subdivided(self):
        from HRTFCalculation.Postprocessing.locadyn import interpolate
        reference = np.load(Path(__file__).parent/'fixtures/locadyn_matlab_reference.npz')
        import hashlib
        source = Path(__file__).parents[1]/'HRTFCalculation/Postprocessing/upsample_hrtf.m'
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), str(reference['reference_sha256']))
        for i in range(8):
            get = lambda key: reference[f'case{i}_{key}']
            with self.subTest(case=i, level=int(get('level')), normalize=bool(get('normalize'))):
                values, positions, delays, _ = interpolate(get('ir'), reference['positions'],
                    float(get('fs')), int(get('level')), bool(get('normalize')), lambda _: None)
                np.testing.assert_allclose(positions, get('positions'), rtol=0, atol=2e-12)
                np.testing.assert_allclose(delays, get('delay'), rtol=0, atol=2e-10)
                np.testing.assert_allclose(values, get('output'), rtol=0, atol=2e-11)

    def test_matlab_halfway_rounding(self):
        from HRTFCalculation.Postprocessing.locadyn import matlab_round
        np.testing.assert_array_equal(matlab_round([-2.5,-1.5,-.5,.5,1.5,2.5]),[-3,-2,-1,1,2,3])
        self.assertEqual(matlab_round(np.nextafter(.5, 0)), 0)

    def test_roundtrip_export_and_reject_external_delay(self):
        import sofar as sf
        reference = np.load(Path(__file__).parent/'fixtures/locadyn_matlab_reference.npz')
        s = sf.Sofa('SimpleFreeFieldHRIR', version='1.0')
        s.Data_IR = reference['case0_ir']
        s.SourcePosition = reference['positions']
        s.Data_SamplingRate = float(reference['case0_fs'])
        s.ReceiverPosition = np.array([[0,.09,0],[0,-.09,0]])
        with TemporaryDirectory() as directory:
            source=Path(directory)/'HRIR_test.sofa'
            sf.write_sofa(str(source),s)
            original=source.read_bytes()
            target=up.upsample_file(source,Path(directory)/'dense',0,False,lambda _:None)
            result=sf.read_sofa(str(target),verify=True)
            np.testing.assert_allclose(result.Data_IR, reference['case0_output'],rtol=0,atol=2e-11)
            self.assertEqual(source.read_bytes(),original)
            s.Data_Delay=np.ones((1,2))
            with self.assertRaisesRegex(ValueError,'external Data.Delay'):
                up.validate_input(s)
