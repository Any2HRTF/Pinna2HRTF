from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import TestCase
from unittest.mock import patch

from HRTFCalculation.Config import PipelineConfig, worktree_root
from HRTFCalculation.RunConfig import run_numcalc_local


class WindowsCompatTests(TestCase):
    def test_windows_executable_defaults_use_exe_suffix(self):
        with patch("HRTFCalculation.Config.platform.system", return_value="Windows"):
            config = PipelineConfig().resolved(Path("C:/Pinna2HRTF"))
        self.assertEqual(config.paths.numcalc_executable.name, "NumCalc.exe")
        self.assertEqual(config.paths.mesh_grading_executable.name, "hrtf_mesh_grading.exe")

    def test_windows_numcalc_dry_run_accepts_executable_path_with_spaces(self):
        with TemporaryDirectory(prefix="pinna2hrtf windows ") as temp:
            root = Path(temp)
            output = root / "Output"
            for side in ("Left", "Right"):
                project = output / "Projects" / side
                project.mkdir(parents=True)
                (project / "parameters.json").write_text('{"numFrequencies": 1}', encoding="utf-8")
            exe = root / "External Tools" / "bin" / "NumCalc.exe"
            exe.parent.mkdir(parents=True)
            exe.write_text("", encoding="utf-8")
            config = PipelineConfig()
            config.paths.output_dir = output
            config.paths.numcalc_executable = exe
            with patch("HRTFCalculation.RunConfig.platform.system", return_value="Windows"):
                run_numcalc_local(config.resolved(root), dry_run=True, logger=lambda _: None)

    def test_portable_package_root_can_be_discovered_without_paper_folder(self):
        with TemporaryDirectory() as temp:
            root = Path(temp) / "Pinna2HRTF"
            (root / "HRTFCalculation").mkdir(parents=True)
            (root / "pyproject.toml").write_text("", encoding="utf-8")
            with patch.dict("os.environ", {"PINNA2HRTF_ROOT": str(root)}, clear=False):
                self.assertEqual(worktree_root(), root)
