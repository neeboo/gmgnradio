import importlib.util
import inspect
import unittest
from pathlib import Path

import numpy as np


class BonesResidentTests(unittest.TestCase):
    def module(self):
        path = Path(__file__).parents[1] / "build_bones_resident.py"
        self.assertTrue(path.is_file(), "BONES resident build/loop verifier is missing")
        spec = importlib.util.spec_from_file_location("build_bones_resident", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_loop_metrics_measure_actual_rotation_and_root_discontinuity(self):
        module = self.module()
        spec = {"duration": 2, "loop": True,
                "tracks": {"head": [{"t": t, "r": [0, r, 0]} for t, r in [(0, 0), (1, 30), (2, 2)]]},
                "hips": [{"t": 0, "p": [0, 0, 0]}, {"t": 1, "p": [0, .02, 0]}, {"t": 2, "p": [0, .01, 0]}]}
        metrics = module.motion_metrics(spec)
        self.assertAlmostEqual(metrics["seamMaxDegrees"], 2)
        self.assertAlmostEqual(metrics["motionMaxDegrees"], 30)
        self.assertAlmostEqual(metrics["rootSeamMeters"], .01)

    def test_loop_selector_keeps_contiguous_frames_and_rejects_frozen_motion(self):
        module = self.module()
        angles = np.zeros((121, 1, 3))
        angles[:, 0, 1] = np.sin(np.arange(121) / 30 * np.pi) * 20
        start, end = module.select_loop(angles, np.zeros((121, 3)), fps=30, min_seconds=2, max_seconds=3)
        self.assertGreaterEqual(end - start, 60)
        self.assertLessEqual(end - start, 90)
        with self.assertRaisesRegex(ValueError, "stationary"):
            module.select_loop(np.zeros_like(angles), np.zeros((121, 3)), fps=30, min_seconds=2, max_seconds=3)

    def test_loop_selector_can_require_visible_gesture_amplitude(self):
        module = self.module()
        self.assertIn("min_motion_degrees", inspect.signature(module.select_loop).parameters)
        angles = np.zeros((181, 1, 3))
        angles[:61, 0, 1] = np.sin(np.arange(61) / 30 * np.pi)
        angles[61:, 0, 1] = np.sin(np.arange(120) / 30 * np.pi) * 25
        start, end = module.select_loop(angles, np.zeros((181, 3)), fps=30, min_seconds=2, max_seconds=2, min_motion_degrees=20)
        self.assertGreater(np.ptp(angles[start:end+1, 0, 1]), 20)


if __name__ == "__main__":
    unittest.main()
