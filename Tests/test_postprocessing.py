import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import pandas as pd

from HRTFCalculation.Postprocessing import postprocessing


class PostprocessingFailureTests(unittest.TestCase):
    def test_report_issues_skips_merge_and_marks_project_failed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for scan_type in ["Target", "Prediction"]:
                for direction in ["Left", "Right"]:
                    (root / f"{scan_type} {direction}" / "sample").mkdir(parents=True)

            def output2hrtf(project):
                if "Target Left" in project:
                    output = Path(project) / "Output2HRTF"
                    output.mkdir()
                    (output / "report_issues.txt").write_text("non convergence")

            with patch.object(postprocessing.m2h, "output2hrtf", side_effect=output2hrtf), patch.object(postprocessing.m2h, "merge_sofa_files") as merge, patch.object(postprocessing.m2h, "inspect_sofa_files"):
                postprocessing.main(SimpleNamespace(data_dir=str(root), normalize=False, level_offset_db=-30))

            self.assertEqual(merge.call_count, 1)
            self.assertIn("Prediction Left", merge.call_args.args[0][0])
            failed = pd.read_csv(root / "failed.csv")
            self.assertEqual(failed.loc[0, "id"], "sample")
            self.assertNotIn("sample", (root / "successfull.csv").read_text())

    def test_merge_exception_marks_project_failed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for scan_type in ["Target", "Prediction"]:
                for direction in ["Left", "Right"]:
                    (root / f"{scan_type} {direction}" / "sample").mkdir(parents=True)

            with patch.object(postprocessing.m2h, "output2hrtf"), patch.object(postprocessing.m2h, "merge_sofa_files", side_effect=RuntimeError("merge failed")), patch.object(postprocessing.m2h, "inspect_sofa_files"):
                postprocessing.main(SimpleNamespace(data_dir=str(root), normalize=False, level_offset_db=-30))

            failed = pd.read_csv(root / "failed.csv")
            self.assertEqual(set(failed["id"]), {"sample"})
            self.assertEqual(set(failed["direction"]), {"Binaural"})
            self.assertNotIn("sample", (root / "successfull.csv").read_text())


if __name__ == "__main__":
    unittest.main()
