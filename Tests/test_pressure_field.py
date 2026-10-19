from pathlib import Path
import tempfile
import unittest

from HRTFCalculation.PressureField import frame, inspect


class PressureFieldTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "NC.inp"
        self.source.write_text("""## Load Frequency Curve
0 3
0 0 0
1 500 0
2 1750 0
NODES
Nodes.txt
ELEMENTS
Elements.txt
BOUNDARY
END
""")
        (self.root / "Nodes.txt").write_text("""7
90 0 1 0
10 0 0 0
30 1 0 0
70 1 1 0
900 0 0 2
500 1 0 2
800 0 1 2
""")
        (self.root / "Elements.txt").write_text("""3
7 10 30 70 0 0 0
40 10 30 70 90 0 0 0
100 500 800 900 2 0 1
""")
        self.output = self.root / "be.out" / "be.2"
        self.output.mkdir(parents=True)
        (self.output / "pBoundary").write_text("Mesh2HRTF 1.3.0\n2\n0 2\n40 0 2\n7 3 4\n")
        (self.output / "pEvalGrid").write_text("Mesh2HRTF 1.3.0\n1\n1 3\n900 0 1\n500 1 0\n800 -1 0\n")

    def test_sparse_frequency_steps_use_solver_curve(self):
        data = inspect(self.source)
        self.assertEqual(data["steps"], [{"id": 2, "frequency": 1750, "surfaces": ["Boundary", "Evaluation Grid"]}])

    def test_boundary_ids_and_quad_split_keep_cell_values(self):
        data = frame(self.source, 2, "Boundary")
        self.assertEqual(data["vertices"], [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]])
        self.assertEqual(data["triangles"], [[0, 1, 2], [0, 1, 2], [0, 2, 3]])
        self.assertEqual(data["association"], "cell")
        self.assertEqual(data["real"], [3, 0, 0])
        self.assertEqual(data["imaginary"], [4, 2, 2])

    def test_evaluation_pressure_matches_nodes_not_elements(self):
        data = frame(self.source, 2, "Evaluation Grid")
        self.assertEqual(data["association"], "point")
        self.assertEqual(data["real"], [1, -1, 0])
        self.assertEqual(data["imaginary"], [0, 0, 1])
        self.assertEqual(data["triangles"], [[0, 1, 2]])

    def test_incomplete_results_fail_instead_of_coloring_wrong_faces(self):
        (self.output / "pBoundary").write_text("Mesh2HRTF 1.3.0\n2\n0 2\n40 0 2\n")
        with self.assertRaisesRegex(ValueError, "Incomplete"):
            frame(self.source, 2, "Boundary")
        (self.output / "pBoundary").write_text("Mesh2HRTF 1.3.0\n2\n0 1\n40 0 2\n")
        with self.assertRaisesRegex(ValueError, "IDs missing"):
            frame(self.source, 2, "Boundary")

    def test_duplicate_and_nonfinite_values_rejected(self):
        for rows, message in [("40 0 2\n40 3 4\n", "Duplicate"), ("40 nan 2\n7 3 4\n", "non-finite")]:
            (self.output / "pBoundary").write_text("Mesh2HRTF 1.3.0\n2\n0 2\n" + rows)
            with self.assertRaisesRegex(ValueError, message):
                frame(self.source, 2, "Boundary")

    def test_multiple_result_groups_and_fortran_exponents(self):
        (self.output / "pBoundary").write_text("Mesh2HRTF 1.3.0\n2\n0 1\n40 0 2D+0\n1 1\n7 3 4\n")
        self.assertEqual(frame(self.source, 2, "Boundary")["imaginary"], [4, 2, 2])

    def test_missing_frequency_label_is_not_invented(self):
        self.source.write_text(self.source.read_text().replace("## Load Frequency Curve", "## Unknown curve"))
        self.assertIsNone(inspect(self.source)["steps"][0]["frequency"])

    def test_invalid_geometry_is_reported(self):
        (self.root / "Elements.txt").write_text("1\n7 10 30 999 0 0 0\n")
        with self.assertRaisesRegex(ValueError, "missing node"):
            frame(self.source, 2, "Boundary")

    def test_no_results_explains_prerequisite(self):
        (self.output / "pBoundary").unlink()
        (self.output / "pEvalGrid").unlink()
        with self.assertRaisesRegex(ValueError, "Run NumCalc"):
            inspect(self.source)


if __name__ == "__main__":
    unittest.main()
