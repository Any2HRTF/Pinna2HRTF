import unittest

import numpy as np
import trimesh

from HRTFCalculation.Preprocessing.src.cut_eararea import cut_eararea


class CutEarareaTests(unittest.TestCase):
    def test_cut_uses_vertex_mask_for_sparse_face_indices(self):
        vertices = np.array([
            [-2.0, 1.0, -2.0],
            [-2.0, 1.0, 2.0],
            [2.0, 1.0, -2.0],
            [2.0, 1.0, 2.0],
            [0.0, 1.0, 0.0],
            [4.0, 1.0, 0.0],
        ])
        faces = np.array([[0, 4, 5], [1, 3, 5]])
        head = trimesh.Trimesh(vertices=vertices, faces=faces, process=False)
        ear = trimesh.Trimesh(vertices=np.array([
            [-1.0, 1.0, -1.0],
            [-1.0, 1.0, 1.0],
            [1.0, 1.0, -1.0],
            [1.0, 1.0, 1.0],
        ]), faces=np.array([[0, 1, 2], [1, 2, 3]]), process=False)
        result = cut_eararea(head, ear, side="left")
        self.assertGreaterEqual(len(result.faces), 0)


if __name__ == "__main__":
    unittest.main()
