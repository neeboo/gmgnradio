import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

from tools.motion.bones_seed_import import DEFAULT_HUMANOID_MAP


def synthetic_bvh():
    names = [name for name in DEFAULT_HUMANOID_MAP.values() if name != "Hips"]
    lines = ["HIERARCHY", "ROOT Hips", "{", "OFFSET 0 100 0",
             "CHANNELS 6 Xposition Yposition Zposition Zrotation Yrotation Xrotation"]
    for name in names:
        lines += [f"JOINT {name}", "{", "OFFSET 0 1 0",
                  "CHANNELS 3 Zrotation Yrotation Xrotation", "}"]
    lines += ["}", "MOTION", "Frames: 25", "Frame Time: 0.008333333333333333"]
    lines += [" ".join(map(str, [frame * 2, 100 + frame, frame * 3, 0, 0, 0] + [0] * (3 * len(names))))
              for frame in range(25)]
    return "\n".join(lines)


class BonesARPGTests(unittest.TestCase):
    def module(self):
        path = Path(__file__).parents[1] / "build_bones_arpg.py"
        self.assertTrue(path.is_file(), "ARPG source-preserving batch importer is missing")
        spec = importlib.util.spec_from_file_location("build_bones_arpg", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_publishes_both_formats_with_full_root_and_exact_source_digest(self):
        module = self.module()
        source = {"key": "step-forward", "filename": "step_001__A123", "displayName": "前进一步", "category": "移动"}
        bvh = synthetic_bvh()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cached = root / "sources" / (source["filename"] + ".json")
            cached.parent.mkdir()
            digest = hashlib.sha256(bvh.encode()).hexdigest()
            cached.write_text(json.dumps({"name": source["filename"], "tree": bvh, "sha256": digest}))
            evidence = module.build_motion(source, root)
            entries = evidence["entries"]
            self.assertEqual({entry["format"] for entry in entries}, {"vmd", "vrma"})
            self.assertTrue(all(not entry["loop"] and entry["inPlace"] is False for entry in entries))
            self.assertTrue(all(entry["source"]["generator"]["sourceSHA256"] == digest for entry in entries))
            self.assertTrue(all(entry["activityIDs"] == [] for entry in entries))
            self.assertGreater(evidence["rootDisplacementMeters"], .5)
            for entry in entries:
                data = (root / "catalog" / entry["path"]).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), entry["sha256"])
            self.assertEqual(module.build_motion(source, root)["entries"], entries)

    def test_rejects_tampered_source_before_publishing(self):
        module = self.module()
        source = {"key": "step-forward", "filename": "step_001__A123", "displayName": "前进一步"}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "sources").mkdir()
            (root / "sources" / "step_001__A123.json").write_text(json.dumps({
                "name": source["filename"], "tree": synthetic_bvh(), "sha256": "0" * 64}))
            with self.assertRaisesRegex(ValueError, "digest"):
                module.build_motion(source, root)
            self.assertFalse((root / "catalog").exists())

    def test_manifest_rejects_unsafe_or_duplicate_identity(self):
        module = self.module()
        valid = {"key": "step-forward", "filename": "step_001__A123", "displayName": "前进一步"}
        self.assertEqual(module.validate_manifest({"schemaVersion": 1, "motions": [valid]}), [valid])
        for items in [[valid, valid], [{**valid, "filename": "../../bad"}], [{**valid, "key": "../bad"}],
                      [{**valid, "key": "step--forward"}], [{**valid, "key": "step-"}]]:
            with self.assertRaises(ValueError):
                module.validate_manifest({"schemaVersion": 1, "motions": items})


if __name__ == "__main__":
    unittest.main()
