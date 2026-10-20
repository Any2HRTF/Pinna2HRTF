"""Single-distance placement, compatibility, and output-safety regressions."""
import json
from pathlib import Path
import tempfile
import unittest
import warnings
from unittest.mock import patch
import numpy as np
import trimesh
from pydantic import ValidationError
from HRTFCalculation.Config import PipelineConfig, PreprocessingConfig, load_config, save_config
from HRTFCalculation.Geometry import boundary_y, resolve_geometry, needs_distance_warning
from HRTFCalculation.Compatibility import DEPRECATION
from HRTFCalculation.Preprocessing import reposition_ears_laterally, run_preprocessing_pipeline, preprocess
from HRTFCalculation.Preprocessing.src.create_head import head
from HRTFCalculation.RunConfig import preprocessing_input_paths

def ear_at(y):
    angles = np.arange(24) * 2 * np.pi / 24
    vertices = [[10*np.cos(a), y, 30*np.sin(a)] for a in angles]
    vertices.append([0, y + (20 if y >= 0 else -20), 0])
    return trimesh.Trimesh(vertices, [[i, (i+1) % 24, 24] for i in range(24)])

class EarDistanceTests(unittest.TestCase):
    def setUp(self): self.ears = {"left": ear_at(80), "right": ear_at(-70)}
    def test_automatic_preserves_original_meshes(self):
        before = {s:e.vertices.copy() for s,e in self.ears.items()}
        values = resolve_geometry(self.ears, PreprocessingConfig())
        self.assertEqual(values["ear_distance"], 75)
        reposition_ears_laterally(self.ears, values["translations"])
        for side in before: np.testing.assert_array_equal(before[side], self.ears[side].vertices)
    def test_manual_target_preserves_asymmetry(self):
        values = resolve_geometry(self.ears, PreprocessingConfig(ear_distance=85))
        self.assertEqual(values["ear_distance_left"], 90)
        self.assertEqual(values["ear_distance_right"], 80)
        self.assertEqual(values["translations"], {"left":(0,10,0),"right":(0,-10,0)})
    def test_multiple_boundary_loops(self):
        mesh=trimesh.util.concatenate([ear_at(80),ear_at(90)])
        self.assertTrue(np.isfinite(boundary_y(mesh)))
    def test_single_ears(self):
        for side,ear in self.ears.items():
            values=resolve_geometry({side:ear}, PreprocessingConfig(ear_distance=90))
            self.assertEqual(values[f"ear_distance_{side}"],90)
            self.assertIsNone(values[f'ear_distance_{"right" if side=="left" else "left"}'])
    def test_invalid_edit_is_atomic(self):
        before={s:e.vertices.copy() for s,e in self.ears.items()}
        with self.assertRaises(ValueError): resolve_geometry(self.ears,PreprocessingConfig(ear_distance=1))
        for s in before: np.testing.assert_array_equal(before[s],self.ears[s].vertices)
    def test_invalid_numbers(self):
        for value in [0,-1,float("nan"),float("inf")]:
            with self.subTest(value=value), self.assertRaises(ValidationError): PreprocessingConfig(ear_distance=value)
    def test_warning_boundaries(self):
        for distance,expected in [(49.9,True),(50,True),(50.1,False)]:
            self.assertEqual(needs_distance_warning(distance),expected)
    def test_head_uses_original_automatic_algorithm(self):
        values=resolve_geometry(self.ears,PreprocessingConfig(ear_distance=90))
        reposition_ears_laterally(self.ears,values["translations"])
        with tempfile.TemporaryDirectory() as folder:
            output=Path(folder)/"head.stl"
            radius=head(self.ears["left"],self.ears["right"],output)
            self.assertAlmostEqual(radius,90.9)
            self.assertAlmostEqual(trimesh.load(output).extents[1],181.8,places=4)
    def test_validation_before_output_cleanup(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);ear_at(0).export(root/"ear.stl")
            protected=root/"output/Intermediates/Left/input_ear.stl";protected.parent.mkdir(parents=True);protected.write_text("prior")
            with self.assertRaisesRegex(ValueError,"Ear distance"):
                run_preprocessing_pipeline(root/"ear.stl",None,None,None,None,output_dir=root/"output")
            self.assertEqual(protected.read_text(),"prior")
    def test_manual_microphone_follows_ear(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);self.ears["left"].export(root/"ear.stl")
            settings=PreprocessingConfig(ear_distance=85,source_position_input_left=(1,80,2))
            with patch("HRTFCalculation.Preprocessing.head",side_effect=RuntimeError("stop")):
                with self.assertRaisesRegex(RuntimeError,"stop"):
                    run_preprocessing_pipeline(root/"ear.stl",None,None,None,None,preprocessing=settings,output_dir=root/"output")
            landmark=json.loads((root/"output/Intermediates/Left/source_landmark.json").read_text())
            self.assertEqual(landmark["position"],[1,85,2])
    def test_inferred_input_routing(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);self.ears["left"].export(root/"ear.stl")
            predicted=root/"Intermediates/Left/Prediction_ear.stl";predicted.parent.mkdir(parents=True);ear_at(90).export(predicted)
            config=PipelineConfig();config.paths.output_dir=root;config.paths.left_ear=root/"ear.stl";config.paths.right_ear=None
            selected,_=preprocessing_input_paths(config,lambda _:None)
            self.assertEqual(selected,predicted)
            self.assertEqual(resolve_geometry({"left":trimesh.load(selected)},config.preprocessing)["ear_distance"],90)
    def test_cli_new_and_deprecated_alias(self):
        base=["preprocessing","--left-path","ear.stl","--export-path","output","--mesh-grading-executable","grading","--Mesh2HRTF-path","mesh2hrtf"]
        for flag in ["--ear-distance","--head-radius"]:
            with patch("sys.argv",base+[flag,"80"]),patch("HRTFCalculation.Preprocessing.run_preprocessing_pipeline") as run:
                preprocess();self.assertEqual(run.call_args.kwargs["preprocessing"].ear_distance,80)
        with patch("sys.argv",base+["--head-radius","80","--ear-distance","90"]),self.assertRaises(SystemExit):preprocess()

class CompatibilityTests(unittest.TestCase):
    def fixture(self,folder,text,encoding="utf-8"):
        path=Path(folder)/"settings.yaml";path.write_bytes(text.encode(encoding));return path
    def test_old_load_adds_canonical_and_deprecation_once(self):
        with tempfile.TemporaryDirectory() as folder:
            original="# preserve\npreprocessing:\n  head_radius: 80 # user's note\n  head_radius_scale: 1.02\n"
            path=self.fixture(folder,original)
            self.assertEqual(load_config(path).preprocessing.ear_distance,80)
            self.assertEqual(path.with_name(path.name+".head-radius-compat.bak").read_text(),original)
            self.assertIn("head_radius: 80 # user's note; "+DEPRECATION,path.read_text())
            self.assertIn("  ear_distance: 80\n",path.read_text())
            updated=path.read_bytes();load_config(path)
            self.assertEqual(path.read_bytes(),updated)
            self.assertEqual(len(list(Path(folder).glob("*.bak"))),1)
            self.assertEqual(path.read_text().count(DEPRECATION),1)
    def test_canonical_precedence_and_null(self):
        for value,expected in [("90",90),("null",None)]:
            with tempfile.TemporaryDirectory() as folder:
                path=self.fixture(folder,f"preprocessing:\n  head_radius: 80\n  ear_distance: {value}\n")
                self.assertEqual(load_config(path).preprocessing.ear_distance,expected)
                self.assertEqual(path.read_text().count("ear_distance:"),1)
                self.assertIn(DEPRECATION,path.read_text())
    def test_canonical_file_is_not_rewritten(self):
        with tempfile.TemporaryDirectory() as folder:
            path=self.fixture(folder,"preprocessing:\n  ear_distance: 80\n")
            original=path.read_bytes();load_config(path)
            self.assertEqual(path.read_bytes(),original);self.assertFalse(list(Path(folder).glob("*.bak")))
    def test_save_only_canonical_field(self):
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/"new.yaml";save_config({"preprocessing":{"head_radius":80}},path)
            self.assertEqual(load_config(path).preprocessing.ear_distance,80)
            self.assertNotIn("  head_radius:",path.read_text())
    def test_invalid_legacy_does_not_touch_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path=self.fixture(folder,"preprocessing:\n  head_radius: .nan\n");original=path.read_bytes()
            with self.assertRaises(ValidationError):load_config(path)
            self.assertEqual(path.read_bytes(),original);self.assertFalse(list(Path(folder).glob("*.bak")))
    def test_unwritable_file_imports_in_memory_and_reports(self):
        with tempfile.TemporaryDirectory() as folder:
            path=self.fixture(folder,"preprocessing:\n  head_radius: 80\n");original=path.read_bytes()
            with patch("HRTFCalculation.Compatibility.os.replace",side_effect=PermissionError("read only")),warnings.catch_warnings(record=True) as notices:
                warnings.simplefilter("always");self.assertEqual(load_config(path).preprocessing.ear_distance,80)
            self.assertTrue(any("could not be updated" in str(n.message) for n in notices))
            self.assertEqual(path.read_bytes(),original);self.assertFalse(list(Path(folder).glob("*.tmp")))
    def test_encoding_and_line_endings_preserved(self):
        for encoding in ["utf-8-sig","utf-16","cp1252"]:
            with self.subTest(encoding=encoding),tempfile.TemporaryDirectory() as folder:
                path=self.fixture(folder,"# café\r\npreprocessing:\r\n  head_radius: 80\r\n",encoding);load_config(path)
                updated=path.read_bytes().decode(encoding)
                self.assertIn("# café\r\n",updated)
                self.assertNotIn("\n",updated.replace("\r\n",""))
                self.assertIn("ear_distance: 80",updated)
    def test_flow_mapping(self):
        with tempfile.TemporaryDirectory() as folder:
            path=self.fixture(folder,"# preserve\npreprocessing: {head_radius: 80, head_radius_scale: 1.02}\n")
            with warnings.catch_warnings(record=True) as notices:self.assertEqual(load_config(path).preprocessing.ear_distance,80)
            self.assertEqual(notices,[]);self.assertIn(DEPRECATION,path.read_text())
            self.assertEqual(load_config(path).preprocessing.head_radius_scale,1.02)

if __name__=="__main__":unittest.main()
