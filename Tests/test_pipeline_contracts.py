"""Behavior shared by the direct CLI and config-driven pipeline."""
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from HRTFCalculation.Config import PipelineConfig, load_config, save_config
from HRTFCalculation import RunConfig
from HRTFCalculation.FileIdentity import file_identity, sha256


class PipelineContracts(unittest.TestCase):
    def test_config_paths_nulls_and_unexposed_settings_roundtrip(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'settings.yaml'
            config = PipelineConfig()
            config.paths.left_ear = None
            config.paths.right_ear = Path('ear with spaces.stl')
            config.preprocessing.head_width_scale = 1.7
            config.preprocessing.source_position_input_right = (1, -2, 3)
            config.manual_ppm.right_parameters = Path('fit.json')
            # Keep explicit nulls when serializing a single-ear project.
            mapping = config.model_dump(mode='json')
            save_config(mapping, path)
            loaded = load_config(path)
            self.assertIsNone(loaded.paths.left_ear)
            self.assertEqual(loaded.paths.right_ear, Path(directory).resolve() / 'ear with spaces.stl')
            self.assertEqual(loaded.manual_ppm.right_parameters, Path(directory).resolve() / 'fit.json')
            self.assertEqual(loaded.preprocessing.head_width_scale, 1.7)
            self.assertEqual(loaded.preprocessing.source_position_input_right, (1, -2, 3))

    def test_file_fingerprints_match_existing_receipt_format(self):
        with TemporaryDirectory() as directory:
            path = Path(directory) / 'mesh'
            path.write_bytes(b'abc')
            self.assertEqual(sha256(path), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
            self.assertEqual(file_identity(path), {'size': 3, 'mtime': path.stat().st_mtime})

    def test_sofa_entry_points_preserve_defaults_and_plot_failure_policy(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / 'HRTF'
            output.mkdir()
            sentinel = output / 'existing.txt'
            project = root / 'Projects' / 'Right'
            (project / 'Output2HRTF').mkdir(parents=True)
            (project / 'Output2HRTF' / 'HRIR_test.sofa').write_bytes(b'sofa')
            m2h = Mock()
            m2h.inspect_sofa_files.side_effect = RuntimeError('plot failed')
            post = Mock()
            args = SimpleNamespace(left_project=None, right_project=str(project), output_dir=str(output), overwrite=False)
            with patch.dict('sys.modules', {'mesh2hrtf': m2h, 'HRTFCalculation.Postprocessing.postprocessing': post}), patch.object(RunConfig, 'parse_sofa_args', return_value=args):
                sentinel.touch()
                with self.assertRaisesRegex(RuntimeError, 'plot failed'):
                    RunConfig.sofa_cli()
                self.assertTrue(sentinel.exists())
                post.normalize_sofa_files.assert_not_called()
                post.resample_hrir_files.assert_not_called()
                self.assertEqual((output / 'HRIR_test.sofa').read_bytes(), b'sofa')
                config = PipelineConfig()
                config.paths.output_dir = root
                config.paths.left_ear = None
                config.paths.right_ear = root / 'ear.stl'
                config = config.resolved()
                messages = []
                RunConfig.run_postprocessing(config, False, messages.append)
                self.assertFalse(sentinel.exists())
                post.normalize_sofa_files.assert_called_once_with(project / 'Output2HRTF', -30)
                post.resample_hrir_files.assert_not_called()
                self.assertTrue(any('plot failed' in message for message in messages))
                m2h.merge_sofa_files.assert_not_called()

    def test_both_ears_convert_then_resample_normalize_and_merge(self):
        with TemporaryDirectory() as directory:
            config = PipelineConfig().resolved()
            config.paths.output_dir = Path(directory)
            config.postprocessing.output_sofa_dir = Path(directory) / 'HRTF'
            config.postprocessing.resample_hrirs = True
            projects = RunConfig.project_dirs(config)
            events = []
            m2h = Mock()
            m2h.output2hrtf.side_effect = lambda path: events.append(('convert', Path(path).name))
            m2h.merge_sofa_files.side_effect = lambda paths, savedir: events.append(('merge', paths))
            post = Mock()
            post.resample_hrir_files.side_effect = lambda path, rate: events.append(('resample', path.parent.name))
            post.normalize_sofa_files.side_effect = lambda path, offset: events.append(('normalize', path.parent.name))
            with patch.dict('sys.modules', {'mesh2hrtf': m2h, 'HRTFCalculation.Postprocessing.postprocessing': post}):
                RunConfig.run_postprocessing(config, False, lambda _: None)
            self.assertEqual(events, [('convert', 'Left'), ('convert', 'Right'), ('resample', 'Left'), ('resample', 'Right'), ('normalize', 'Left'), ('normalize', 'Right'), ('merge', [str(p) for p in projects])])
            self.assertEqual([call.kwargs['plane'] for call in m2h.inspect_sofa_files.call_args_list], ['horizontal', 'median'])

    def test_solver_resumption_requires_all_outputs_and_completion_marker(self):
        with patch.dict('sys.modules', {'mesh2hrtf': Mock()}):
            from HRTFCalculation.NumCalc import frequency_step_complete
        with TemporaryDirectory() as directory:
            source = Path(directory)
            output = source / 'be.out' / 'be.1'
            output.mkdir(parents=True)
            for name in ['pBoundary', 'pEvalGrid', 'vBoundary', 'vEvalGrid']:
                (output / name).write_text('result')
            log = source / 'NC1-1_log.txt'
            log.write_text('started')
            self.assertFalse(frequency_step_complete(source, 1))
            log.write_text('---------- NumCalc ended:')
            self.assertTrue(frequency_step_complete(source, 1))
            (output / 'vEvalGrid').write_text('')
            self.assertFalse(frequency_step_complete(source, 1))


if __name__ == '__main__':
    unittest.main()
