from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "validate_gmgn_world.py"


def load_validator():
    spec = importlib.util.spec_from_file_location("validate_gmgn_world", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def valid_manifest():
    transform = {
        "position": {"x": 0.0, "y": 0.0, "z": 0.0},
        "rotation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
        "scale": {"x": 1.0, "y": 1.0, "z": 1.0},
    }
    return {
        "schemaVersion": 1,
        "packageID": "test-world",
        "packageVersion": "1.0.0",
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
                "id": "wp.a",
                "position": {"x": 0.0, "y": 0.0, "z": 0.0},
                "arrivalRadius": 0.2,
                "enabled": True,
            }
        ],
        "routes": [
            {
                "id": "route.a",
                "waypointIDs": ["wp.a"],
                "bidirectional": True,
                "enabled": True,
            }
        ],
        "activities": [
            {
                "id": "idle.a",
                "action": "idle",
                "entryWaypointID": "wp.a",
                "transform": transform,
                "motionID": "idle.natural",
                "propIDs": [],
                "interruptible": True,
            }
        ],
        "cameras": [
            {
                "id": "camera.a",
                "transform": transform,
                "fieldOfViewDegrees": 66.0,
                "nearPlane": 0.05,
                "farPlane": 250.0,
            }
        ],
        "capabilities": ["activity:idle.a", "camera:camera.a"],
        "resources": [],
    }


def complete_activity_definition(
    activity_id="idle.a",
    activity=None,
    phases=None,
):
    return {
        "id": activity_id,
        "activity": activity or {"type": "idle"},
        "phases": phases
        or [
            {"phase": phase}
            for phase in ("approach", "enter", "loop", "exit", "interrupt", "failed")
        ],
        "interruptible": True,
        "cooldownSeconds": 0.0,
    }


class ValidateGMGNWorldTests(unittest.TestCase):
    def setUp(self) -> None:
        self.validator = load_validator()

    def test_valid_manifest_has_no_findings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "world.json").write_text(json.dumps(valid_manifest()))
            findings = self.validator.validate_package(root)

        self.assertEqual(findings, [])

    def test_shared_invalid_package_fixture(self) -> None:
        manifest = valid_manifest()
        manifest["calibration"]["visualToGameplay"] = [0.0] * 15
        manifest["calibration"]["metersPerUnit"] = 0.0
        manifest["waypoints"][0]["id"] = "shared.anchor"
        manifest["routes"][0]["waypointIDs"] = ["shared.anchor"]
        manifest["activities"][0]["entryWaypointID"] = "shared.anchor"
        manifest["activities"][0]["propIDs"] = ["prop.missing"]
        manifest["cameras"][0]["id"] = "shared.anchor"
        manifest["capabilities"] = [
            "activity:idle.a",
            "camera:shared.anchor",
        ]

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(manifest, Path(directory))

        self.assertEqual(
            findings,
            [
                "calibration.visualToGameplay must contain 16 finite numbers",
                "calibration.metersPerUnit must be positive and finite",
                "duplicate id shared.anchor in waypoints,cameras",
                "activity idle.a references missing prop prop.missing",
            ],
        )

    def test_non_finite_calibration_values_are_rejected(self) -> None:
        manifest = valid_manifest()
        manifest["calibration"]["visualToGameplay"][7] = float("nan")
        manifest["calibration"]["metersPerUnit"] = float("inf")

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(manifest, Path(directory))

        self.assertEqual(
            findings,
            [
                "calibration.visualToGameplay must contain 16 finite numbers",
                "calibration.metersPerUnit must be positive and finite",
            ],
        )

    def test_partial_activity_definitions_report_missing_anchor(self) -> None:
        manifest = valid_manifest()
        second = dict(manifest["activities"][0])
        second["id"] = "idle.b"
        manifest["activities"].append(second)
        manifest["capabilities"].append("activity:idle.b")
        manifest["activityDefinitions"] = [complete_activity_definition()]

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(manifest, Path(directory))

        self.assertEqual(findings, ["activity idle.b has no definition"])

    def test_explicitly_empty_activity_definitions_are_authored(self) -> None:
        manifest = valid_manifest()
        manifest["activityDefinitions"] = []

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(manifest, Path(directory))

        self.assertEqual(findings, ["activity idle.a has no definition"])

    def test_duplicate_and_orphan_activity_definitions_are_rejected(self) -> None:
        manifest = valid_manifest()
        manifest["activityDefinitions"] = [
            complete_activity_definition(),
            complete_activity_definition(),
            complete_activity_definition("orphan.idle"),
        ]

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(manifest, Path(directory))

        self.assertEqual(
            findings,
            [
                "activity idle.a has duplicate definitions",
                "activity definition orphan.idle has no anchor",
            ],
        )

    def test_activity_definition_action_mismatch_is_rejected(self) -> None:
        manifest = valid_manifest()
        manifest["activityDefinitions"] = [
            complete_activity_definition(activity={"type": "gaze", "targetID": "idle.a"})
        ]

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(manifest, Path(directory))

        self.assertEqual(
            findings,
            ["activity idle.a action idle does not match definition gaze"],
        )

    def test_walk_anchor_must_enter_at_its_destination(self) -> None:
        manifest = valid_manifest()
        manifest["activities"][0]["action"] = "walk"
        manifest["waypoints"].append(
            {
                "id": "wp.center",
                "position": {"x": 0.0, "y": 0.0, "z": 1.0},
                "arrivalRadius": 0.2,
                "enabled": True,
            }
        )
        manifest["activityDefinitions"] = [
            complete_activity_definition(
                activity={"type": "walk", "destinationID": "wp.center"}
            )
        ]

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(
                manifest,
                Path(directory),
            )

        self.assertEqual(
            findings,
            [
                "activity idle.a walk destination wp.center does not match "
                "entry waypoint wp.a"
            ],
        )

    def test_missing_then_duplicate_phases_have_stable_order(self) -> None:
        manifest = valid_manifest()
        phases = [
            {"phase": "approach"},
            {"phase": "enter"},
            {"phase": "loop"},
            {"phase": "exit"},
            {"phase": "interrupt"},
            {"phase": "loop"},
        ]
        manifest["activityDefinitions"] = [
            complete_activity_definition(phases=phases)
        ]

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(manifest, Path(directory))

        self.assertEqual(
            findings,
            [
                "activity definition idle.a is missing phase failed",
                "activity definition idle.a has duplicate phase loop",
            ],
        )

    def test_missing_references_and_bad_camera_are_reported_in_stable_order(self) -> None:
        manifest = valid_manifest()
        manifest["routes"][0]["waypointIDs"] = ["wp.missing"]
        manifest["activities"][0]["entryWaypointID"] = "wp.other"
        manifest["cameras"][0]["nearPlane"] = 10.0
        manifest["cameras"][0]["farPlane"] = 1.0

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "world.json").write_text(json.dumps(manifest))
            findings = self.validator.validate_package(root)

        self.assertEqual(
            findings,
            [
                "route route.a references missing waypoint wp.missing",
                "activity idle.a references missing entry waypoint wp.other",
                "camera camera.a must satisfy 0 < nearPlane < farPlane",
            ],
        )

    def test_activity_transform_must_stay_within_entry_tolerance(self) -> None:
        manifest = valid_manifest()
        manifest["activities"][0]["transform"]["position"]["x"] = 0.2

        with tempfile.TemporaryDirectory() as directory:
            findings = self.validator.validate_manifest(
                manifest,
                Path(directory),
            )

        self.assertEqual(
            findings,
            [
                "activity idle.a transform is 0.200m from entry waypoint "
                "wp.a; maximum is 0.080m"
            ],
        )

    def test_resource_escape_and_hash_mismatch_are_rejected(self) -> None:
        manifest = valid_manifest()
        manifest["resources"] = [
            {"id": "outside", "kind": "spz", "path": "../outside.spz", "sha256": "0" * 64},
            {"id": "inside", "kind": "json", "path": "asset.json", "sha256": "0" * 64},
        ]

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "world.json").write_text(json.dumps(manifest))
            (root / "asset.json").write_text("{}")
            findings = self.validator.validate_package(root)

        self.assertEqual(
            findings,
            [
                "resource inside SHA-256 mismatch",
                "resource outside path escapes package root",
            ],
        )


if __name__ == "__main__":
    unittest.main()
