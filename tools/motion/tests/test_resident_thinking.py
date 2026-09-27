"""Small local data checks: no inference, remote fetches, or host UI."""
import json
from pathlib import Path
import unittest

from tools.motion.gmgn_motion_factory import build_vmd, build_vrma, validate_motion_spec

ROOT = Path(__file__).resolve().parents[3]


class ResidentThinkingTests(unittest.TestCase):
    def test_owned_pose_moves_head_and_arms_without_world_displacement(self):
        source = ROOT / "tools/motion/fixtures/resident-thinking.json"
        self.assertTrue(source.is_file(), "missing authored resident thinking pose")
        spec = validate_motion_spec(json.loads(source.read_text()))
        self.assertTrue(spec["loop"])
        self.assertIn("head", spec["tracks"])
        self.assertIn("rightLowerArm", spec["tracks"])
        self.assertTrue(all(frame["p"] == [0, 0, 0] for frame in spec.get("hips", [])))
        for bone in ("hips", "leftUpperLeg", "rightUpperLeg", "leftLowerLeg", "rightLowerLeg"):
            for frame in spec["tracks"].get(bone, []):
                self.assertEqual(frame["r"], [0, 0, 0])

    def test_bundled_formats_are_factory_outputs(self):
        source = ROOT / "tools/motion/fixtures/resident-thinking.json"
        self.assertTrue(source.is_file(), "missing authored resident thinking pose")
        spec = json.loads(source.read_text())
        folder = ROOT / "apps/macos/Resources/ResidentMotions"
        for extension, builder in (("vmd", build_vmd), ("vrma", build_vrma)):
            artifact = folder / f"gmgn.motion.resident-thinking.{extension}"
            self.assertTrue(artifact.is_file(), f"missing {extension} thinking motion")
            self.assertEqual(artifact.read_bytes(), builder(spec))


if __name__ == "__main__":
    unittest.main()
