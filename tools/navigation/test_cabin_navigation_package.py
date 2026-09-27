"""Build only temporary package fixtures; never copy or overwrite live app assets."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class CabinNavigationPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gmgn-cabin-package-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "authoring/worlds/marble-living-cabin"
        self.source.mkdir(parents=True)
        for filename in ["layout.json", "operation.json", "build-package.mjs"]:
            shutil.copyfile(ROOT / "authoring/worlds/marble-living-cabin" / filename, self.source / filename)
        old = self.root / "apps/macos/Resources/Worlds/living-pod-v1"
        old.mkdir(parents=True)
        shutil.copyfile(ROOT / "apps/macos/Resources/Worlds/living-pod-v1/world.json", old / "world.json")
        (self.source / "assets").mkdir()
        for name in ["collider.glb", "world-500k.spz"]:
            (self.source / "assets" / name).write_bytes(b"temporary build fixture")
        self.layout = json.loads((self.source / "layout.json").read_text())
        self.layout.pop("navigation", None)
        self.write_layout()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.baseline = self.read_manifest()
        waypoint = {"id":"wp.auto.fixture", "position":{"x":-1,"y":0,"z":-4.5}, "arrivalRadius":0.2,"enabled":True}
        self.navigation = {
            "schemaVersion":1, "generator":"production-capsule-grid-v1",
            "waypoints":[*self.baseline["waypoints"], waypoint],
            "routes":[*self.baseline["routes"], {"id":"route.auto.fixture", "waypointIDs":["wp.spawn",waypoint["id"]],"bidirectional":True,"enabled":True}],
            "source":{"worldID":self.layout["worldID"], "framing":copy.deepcopy(self.layout["framing"]),
                "collisionVolumes":copy.deepcopy(self.layout["collisionVolumes"]),
                "manualWaypoints":self.baseline["waypoints"],
                "colliderSHA256":hashlib.sha256(b"temporary build fixture").hexdigest()}}
        self.layout["navigation"] = self.navigation

    def write_layout(self):
        (self.source / "layout.json").write_text(json.dumps(self.layout))

    def build(self):
        return subprocess.run(["node", str(self.source / "build-package.mjs")], cwd=self.root, capture_output=True, text=True)

    def read_manifest(self):
        return json.loads((self.root / "apps/macos/Resources/Worlds/marble-living-cabin/world.json").read_text())

    def test_rebuild_preserves_baked_navigation_and_other_world_content(self):
        self.write_layout()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.read_manifest()
        self.assertEqual(manifest["waypoints"], self.navigation["waypoints"])
        self.assertEqual(manifest["routes"], self.navigation["routes"])
        self.assertEqual({k:v for k,v in manifest.items() if k not in ("waypoints","routes")},
                         {k:v for k,v in self.baseline.items() if k not in ("waypoints","routes")})

    def test_rebuild_refuses_navigation_with_stale_physics_or_anchors(self):
        for key,value in [("colliderSHA256","0"*64), ("framing",{}), ("collisionVolumes",[]), ("manualWaypoints",[])]:
            with self.subTest(key=key):
                saved = self.navigation["source"][key]
                self.navigation["source"][key] = value
                self.write_layout()
                result = self.build()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Baked navigation is stale", result.stderr)
                self.navigation["source"][key] = saved

    def test_current_authored_navigation_rebuilds_from_real_source_assets(self):
        self.layout = json.loads((ROOT / "authoring/worlds/marble-living-cabin/layout.json").read_text())
        self.assertIn("navigation", self.layout)
        for name in ["collider.glb", "world-500k.spz"]:
            path = self.source / "assets" / name
            path.unlink()
            path.symlink_to(ROOT / "authoring/worlds/marble-living-cabin/assets" / name)
        self.write_layout()
        result = self.build()
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = json.loads((ROOT / "apps/macos/Resources/Worlds/marble-living-cabin/world.json").read_text())
        actual = self.read_manifest()
        self.assertEqual(actual["waypoints"], expected["waypoints"])
        self.assertEqual(actual["routes"], expected["routes"])


if __name__ == "__main__":
    unittest.main()
