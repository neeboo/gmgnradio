import importlib.util
import copy
import tempfile
import unittest
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

from tools.motion.gmgn_motion_factory import SKELETON


class BonesWalkVRMTests(unittest.TestCase):
    def module(self):
        path = Path(__file__).parents[1] / "build_bones_walk_vrm.py"
        self.assertTrue(path.exists(), "offline walk seam/speed verifier is missing")
        spec = importlib.util.spec_from_file_location("walk_vrm", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_loop_evidence_measures_original_horizontal_speed_and_vertical_seam(self):
        module = self.module()
        spec = {"tracks": {bone: [{"t": 0, "r": [0, 0, 0]}, {"t": 1, "r": [0, 0, 0]}]
                           for bone in SKELETON},
                "hips": [{"t": 0, "p": [0, 0, 0]}, {"t": 1, "p": [0, .01, 1.2]}]}
        arrays = module.motion_arrays(spec)
        evidence = module.interval_metrics(arrays, 0, 1, fps=1)
        self.assertAlmostEqual(evidence["strideSpeed"], 1.2)
        self.assertAlmostEqual(evidence["rootVerticalSeamMeters"], .01)
        self.assertAlmostEqual(evidence["footSeamMaxMeters"], .01)
        self.assertEqual(evidence["seamMaxDegrees"], 0)

    def test_source_cache_never_downloads_and_rejects_digest_mismatch(self):
        module = self.module()
        with self.assertRaises(FileNotFoundError):
            module.read_local_source(Path("/offline-missing-bones-walk.json"))
        with self.assertRaisesRegex(ValueError, "digest"):
            module.validate_source({"name": "walk", "tree": "bvh", "sha256": "0" * 64})

    def test_stationary_tail_does_not_hide_a_real_continuous_cycle(self):
        module = self.module()
        time = np.arange(600) / 120
        angle = np.where(time < 2.5, np.sin(time * np.pi * 2) * 30 + time * .5, 0)
        quaternions = Rotation.from_euler("x", angle[:, None], degrees=True).as_quat()[:, None, :]
        roots = np.zeros((600, 3)); roots[:, 2] = np.minimum(time, 2.5)
        feet = np.zeros((600, 2, 3))
        feet[:, 0, 0] = roots[:, 2] * .01
        candidates = module.select_candidates({"quaternions": quaternions, "roots": roots, "feet": feet}, fps=120)
        self.assertTrue(candidates, "stationary ending must not conceal earlier recorded gait")
        self.assertGreater(candidates[0]["strideSpeed"], .1)

    def test_publish_preserves_continuous_keys_and_records_real_stride(self):
        module = self.module()
        self.assertTrue(hasattr(module, "publish_walk"), "selected walk has no guarded VRMA publisher")
        times = np.arange(137) / 120
        spec = {"name": "test walk", "duration": float(times[-1]), "loop": True,
                "tracks": {bone: [{"t": float(t), "r": [float(np.sin(t / times[-1] * 2 * np.pi) * 30), 0, 0]}
                                   for t in times] for bone in SKELETON},
                "hips": [{"t": float(t), "p": [0, float(np.sin(t / times[-1] * 2 * np.pi) * .02), float(t * 1.4)]} for t in times]}
        before = copy.deepcopy(spec)
        fixture = {"sourceSHA256": "a" * 64, "filename": "offline-test", "startFrame": 61, "endFrame": 197, "outputFPS": 120,
                   "maxSeamDegrees": 4, "maxFootSeamMeters": .018, "maxVerticalSeamMeters": .002}
        with tempfile.TemporaryDirectory() as temporary:
            result = module.publish_walk(spec, fixture, Path(temporary))
            self.assertEqual(result["entry"]["id"], "gmgn.motion.bones.walk-loop-vrm")
            self.assertTrue(result["entry"]["loop"] and result["entry"]["inPlace"])
            self.assertAlmostEqual(result["entry"]["strideSpeed"], 1.4)
            self.assertEqual(result["entry"]["playbackRate"], 1)
            self.assertEqual(spec, before, "publisher must not rewrite root or rotation curves")
            self.assertEqual(result["sourceFrameCount"], 137)


if __name__ == "__main__":
    unittest.main()
