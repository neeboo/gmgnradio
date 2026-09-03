from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

import validate_gmgn_world as validator  # noqa: E402

MODULE_PATH = Path(__file__).parents[1] / "publish_gmgn_world.py"


def load_publisher():
    spec = importlib.util.spec_from_file_location("publish_gmgn_world", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def valid_manifest(package_version="1.1.0"):
    transform = {
        "position": {"x": 0.0, "y": 0.0, "z": 0.0},
        "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
        "scale": {"x": 1.0, "y": 1.0, "z": 1.0},
    }
    return {
        "schemaVersion": 1,
        "packageID": "test-world",
        "packageVersion": package_version,
        "worldID": "world.test",
        "displayName": "Test World",
        "calibration": {
            "metersPerUnit": 1.0,
            "visualToGameplay": [1.0, 0.0, 0.0, 0.0] * 4,
        },
        "spawn": transform,
        "collisionVolumes": [],
        "waypoints": [
            {
                "id": "wp.spawn",
                "position": {"x": 0.0, "y": 0.0, "z": 0.0},
                "arrivalRadius": 0.2,
                "enabled": True,
            },
            {
                "id": "wp.a",
                "position": {"x": 1.0, "y": 0.0, "z": 0.0},
                "arrivalRadius": 0.2,
                "enabled": True,
            },
            {
                "id": "wp.b",
                "position": {"x": 2.0, "y": 0.0, "z": 0.0},
                "arrivalRadius": 0.2,
                "enabled": True,
            },
            {
                "id": "wp.entry",
                "position": {"x": 3.0, "y": 0.0, "z": 0.0},
                "arrivalRadius": 0.2,
                "enabled": True,
            },
        ],
        "routes": [
            {
                "id": "route.auto.spawn",
                "waypointIDs": ["wp.spawn", "wp.a"],
                "bidirectional": True,
                "enabled": True,
            },
            {
                "id": "route.auto.a",
                "waypointIDs": ["wp.a", "wp.b"],
                "bidirectional": True,
                "enabled": True,
            },
            {
                "id": "route.auto.b",
                "waypointIDs": ["wp.b", "wp.entry"],
                "bidirectional": True,
                "enabled": True,
            },
            {
                "id": "route.manual",
                "waypointIDs": ["wp.spawn", "wp.entry"],
                "bidirectional": True,
                "enabled": True,
            },
        ],
        "activities": [
            {
                "id": "walk.entry",
                "action": "walk",
                "entryWaypointID": "wp.entry",
                "transform": {
                    "position": {"x": 3.0, "y": 0.0, "z": 0.0},
                    "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                    "scale": {"x": 1.0, "y": 1.0, "z": 1.0},
                },
                "motionID": "walk.forward",
                "propIDs": [],
                "interruptible": True,
            }
        ],
        "cameras": [],
        "capabilities": ["activity:walk.entry"],
        "resources": [],
    }


class PublishGMGNWorldSemanticsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.publish = load_publisher()

    def test_valid_semantic_versions_are_accepted(self) -> None:
        for version in ("1.2.0", "0.1.0", "1.2.3-rc.1", "1.2.3+build.5", "10.20.30"):
            with self.subTest(version=version):
                self.assertTrue(self.publish.is_semantic_version(version))

    def test_invalid_versions_are_rejected(self) -> None:
        for version in ("", "1.2", "1", "v1.2.0", "1.2.x", "1.2.3.4", "1..2.3", "1.2.3-"):
            with self.subTest(version=version):
                self.assertFalse(self.publish.is_semantic_version(version))

    def test_reachability_uses_only_enabled_auto_routes(self) -> None:
        manifest = valid_manifest()
        self.assertEqual(self.publish.auto_only_reachability_findings(manifest), [])

    def test_reachability_ignores_manual_routes(self) -> None:
        manifest = valid_manifest()
        # The only path to the entry goes through the manual route.
        manifest["routes"] = [
            {
                "id": "route.manual",
                "waypointIDs": ["wp.spawn", "wp.entry"],
                "bidirectional": True,
                "enabled": True,
            }
        ]
        findings = self.publish.auto_only_reachability_findings(manifest)
        self.assertEqual(
            findings,
            ["activity entry wp.entry is unreachable from wp.spawn through auto routes only"],
        )

    def test_reachability_reports_every_unreachable_entry(self) -> None:
        manifest = valid_manifest()
        manifest["activities"].append(
            {
                "id": "idle.far",
                "action": "idle",
                "entryWaypointID": "wp.b",
                "transform": {
                    "position": {"x": 2.0, "y": 0.0, "z": 0.0},
                    "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
                    "scale": {"x": 1.0, "y": 1.0, "z": 1.0},
                },
                "motionID": "idle.natural",
                "propIDs": [],
                "interruptible": True,
            }
        )
        manifest["routes"] = [
            route
            for route in manifest["routes"]
            if route["id"] not in ("route.auto.a", "route.auto.b")
        ]
        findings = self.publish.auto_only_reachability_findings(manifest)
        self.assertEqual(
            findings,
            [
                "activity entry wp.b is unreachable from wp.spawn through auto routes only",
                "activity entry wp.entry is unreachable from wp.spawn through auto routes only",
            ],
        )

    def test_missing_spawn_is_a_reachability_failure(self) -> None:
        manifest = valid_manifest()
        manifest["waypoints"] = [
            waypoint
            for waypoint in manifest["waypoints"]
            if waypoint["id"] != "wp.spawn"
        ]
        self.assertEqual(
            self.publish.auto_only_reachability_findings(manifest),
            ["spawn waypoint wp.spawn is missing or disabled"],
        )


class PublishGMGNWorldMainTests(unittest.TestCase):
    def setUp(self) -> None:
        self.publish = load_publisher()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.source = Path(self.temporary.name) / "source"
        self.source.mkdir()
        self.output = Path(self.temporary.name) / "published" / "world.json"

    def _write_source(self, manifest=None) -> Path:
        source_path = self.source / "world.json"
        source_path.write_text(
            json.dumps(manifest or valid_manifest(), ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        return source_path

    def test_publish_stamps_version_and_switches_route_states(self) -> None:
        self._write_source()
        exit_code = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
            ]
        )
        self.assertEqual(exit_code, 0)
        published = json.loads(self.output.read_text(encoding="utf-8"))
        self.assertEqual(published["packageVersion"], "1.2.0")
        states = {route["id"]: route["enabled"] for route in published["routes"]}
        self.assertTrue(states["route.auto.spawn"])
        self.assertTrue(states["route.auto.a"])
        self.assertTrue(states["route.auto.b"])
        self.assertFalse(states["route.manual"])

    def test_publish_accepts_a_world_json_file_source(self) -> None:
        source_path = self._write_source()
        exit_code = self.publish.main(
            [
                "--source",
                str(source_path),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
            ]
        )
        self.assertEqual(exit_code, 0)

    def test_publish_rejects_invalid_input_manifest(self) -> None:
        manifest = valid_manifest()
        manifest["calibration"]["metersPerUnit"] = 0.0
        self._write_source(manifest)
        exit_code = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
            ]
        )
        self.assertEqual(exit_code, 1)
        self.assertFalse(self.output.exists())

    def test_publish_rejects_unreachable_auto_graph(self) -> None:
        manifest = valid_manifest()
        manifest["routes"] = [
            route
            for route in manifest["routes"]
            if route["id"] != "route.auto.b"
        ]
        self._write_source(manifest)
        exit_code = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
            ]
        )
        self.assertEqual(exit_code, 1)
        self.assertFalse(self.output.exists())

    def test_publish_rejects_non_semantic_package_version(self) -> None:
        self._write_source()
        exit_code = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "not.a.version",
            ]
        )
        self.assertEqual(exit_code, 1)
        self.assertFalse(self.output.exists())

    def test_publish_refuses_existing_output_without_force_and_preserves_bytes(self) -> None:
        self._write_source()
        self.output.parent.mkdir(parents=True, exist_ok=True)
        original_bytes = b"sentinel bytes that must survive a refused overwrite"
        self.output.write_bytes(original_bytes)
        exit_code = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
            ]
        )
        self.assertEqual(exit_code, 1)
        self.assertEqual(self.output.read_bytes(), original_bytes)

    def test_publish_force_overwrites_and_is_repeatable(self) -> None:
        self._write_source()
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.output.write_bytes(b"old")
        first_exit = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
                "--force",
            ]
        )
        self.assertEqual(first_exit, 0)
        first_bytes = self.output.read_bytes()
        json.loads(first_bytes)  # must be valid JSON
        second_exit = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
                "--force",
            ]
        )
        self.assertEqual(second_exit, 0)
        self.assertEqual(self.output.read_bytes(), first_bytes)

    def test_publish_refuses_non_atomic_write_when_temp_is_refused(self) -> None:
        original_mkstemp = self.publish.tempfile.mkstemp

        def refusing_mkstemp(*args, **kwargs):
            raise OSError("Operation not permitted")

        self.publish.tempfile.mkstemp = refusing_mkstemp
        self.addCleanup(setattr, self.publish.tempfile, "mkstemp", original_mkstemp)
        self._write_source()
        exit_code = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
            ]
        )
        self.assertEqual(exit_code, 1)
        self.assertFalse(self.output.exists())
        self.assertFalse(list(self.output.parent.glob(".world.json.*.tmp")))

    def test_publish_output_is_canonical_sorted_json(self) -> None:
        manifest = valid_manifest()
        # Input keys are deliberately unsorted; the output must be canonical.
        manifest = dict(reversed(list(manifest.items())))
        self._write_source(manifest)
        exit_code = self.publish.main(
            [
                "--source",
                str(self.source),
                "--output",
                str(self.output),
                "--package-version",
                "1.2.0",
            ]
        )
        self.assertEqual(exit_code, 0)
        raw = self.output.read_text(encoding="utf-8")
        self.assertTrue(raw.endswith("\n"))
        keys = list(json.loads(raw).keys())
        self.assertEqual(keys, sorted(keys))


class PublishGMGNWorldRoundtripCanaryTests(unittest.TestCase):
    REPO_ROOT = Path(__file__).parents[3]
    ROUNDTRIP = REPO_ROOT / "authoring/worlds/warm-kitchen-canary/roundtrip/world.json"

    def setUp(self) -> None:
        self.publish = load_publisher()
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)

    def test_real_roundtrip_canary_publishes_as_1_3_0(self) -> None:
        self.assertTrue(self.ROUNDTRIP.is_file())
        output = Path(self.temporary.name) / "world.json"
        exit_code = self.publish.main(
            [
                "--source",
                str(self.ROUNDTRIP),
                "--output",
                str(output),
                "--package-version",
                "1.3.0",
            ]
        )
        self.assertEqual(exit_code, 0)
        published = json.loads(output.read_text(encoding="utf-8"))
        self.assertEqual(published["packageVersion"], "1.3.0")
        auto_waypoints = [
            waypoint["id"]
            for waypoint in published["waypoints"]
            if waypoint["id"].startswith("wp.auto.")
        ]
        self.assertEqual(len(auto_waypoints), 8)
        auto_routes = [
            route for route in published["routes"]
            if route["id"].startswith("route.auto.")
        ]
        legacy_routes = [
            route for route in published["routes"]
            if not route["id"].startswith("route.auto.")
        ]
        self.assertEqual(len(auto_routes), 16)
        self.assertEqual(len(legacy_routes), 3)
        self.assertTrue(all(route["enabled"] for route in auto_routes))
        self.assertTrue(all(not route["enabled"] for route in legacy_routes))
        self.assertEqual(
            {route["id"] for route in legacy_routes},
            {"route.home-loop", "route.kitchen-dining", "route.window"},
        )
        self.assertEqual(
            self.publish.auto_only_reachability_findings(published),
            [],
        )
        self.assertEqual(validator.validate_manifest(published, output.parent), [])


if __name__ == "__main__":
    unittest.main()
