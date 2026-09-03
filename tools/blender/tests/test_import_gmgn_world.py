from __future__ import annotations

import importlib.util
import json
import math
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


IMPORTER_PATH = Path(__file__).parents[1] / "import_gmgn_world.py"
EXPORTER_PATH = Path(__file__).parents[1] / "export_gmgn_world.py"
CANARY_MANIFEST = (
    Path(__file__).parents[3]
    / "apps"
    / "macos"
    / "Resources"
    / "Worlds"
    / "warm-kitchen-canary"
    / "world.json"
)


def load_importer():
    spec = importlib.util.spec_from_file_location("import_gmgn_world", IMPORTER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_exporter():
    spec = importlib.util.spec_from_file_location("export_gmgn_world", EXPORTER_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def yaw_pitch_to_quaternion(yaw: float, pitch: float) -> dict:
    """Reproduce export_gmgn_world._rotation exactly for a yaw/pitch pair."""
    half_yaw = yaw * 0.5
    half_pitch = pitch * 0.5
    return {
        "x": math.sin(half_pitch) * math.cos(half_yaw),
        "y": math.cos(half_pitch) * math.sin(half_yaw),
        "z": math.sin(half_pitch) * math.sin(half_yaw),
        "w": math.cos(half_pitch) * math.cos(half_yaw),
    }


def quaternion_to_yaw_pitch(rotation: dict) -> tuple[float, float]:
    w = rotation["w"]
    x = rotation["x"]
    y = rotation["y"]
    return 2.0 * math.atan2(y, w), 2.0 * math.atan2(x, w)


def transform(position=(0.0, 0.0, 0.0), yaw=0.0, pitch=0.0, scale=(1.0, 1.0, 1.0)):
    return {
        "position": {"x": position[0], "y": position[1], "z": position[2]},
        "rotation": yaw_pitch_to_quaternion(yaw, pitch),
        "scale": {"x": scale[0], "y": scale[1], "z": scale[2]},
    }


def identity_rotation():
    return {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0}


def six_phases(
    *,
    approach_anchors=(),
    approach_motions=(),
    approach_duration=None,
    enter_duration=None,
    loop_motions=(),
    loop_duration=None,
    exit_duration=None,
):
    def phase(name, anchors, motions, duration):
        return {
            "phase": name,
            "requiredAnchorIDs": list(anchors),
            "motionIDs": list(motions),
            "propIDs": [],
            "durationSeconds": duration,
        }

    return [
        phase("approach", approach_anchors, approach_motions, approach_duration),
        phase("enter", (), (), enter_duration),
        phase("loop", (), loop_motions, loop_duration),
        phase("exit", (), (), exit_duration),
        phase("interrupt", (), (), None),
        phase("failed", (), (), None),
    ]


def fixture_manifest() -> dict:
    return {
        "schemaVersion": 1,
        "packageID": "roundtrip-fixture",
        "packageVersion": "1.0.0",
        "worldID": "world.roundtrip-fixture",
        "displayName": "Roundtrip Fixture",
        "calibration": {
            "metersPerUnit": 1.0,
            "visualToGameplay": [
                1.0, 0.0, 0.0, 0.0,
                0.0, 0.0, 1.0, 0.0,
                0.0, -1.0, 0.0, 0.0,
                0.0, 0.0, 0.0, 1.0,
            ],
        },
        "spawn": transform((0.0, 0.0, 1.1), yaw=0.4),
        "collisionVolumes": [
            {
                "id": "collision.floor",
                "center": {"x": 0.0, "y": -0.05, "z": 0.0},
                "halfExtents": {"x": 1.9, "y": 0.05, "z": 1.65},
                "rotation": identity_rotation(),
                "isBlocking": True,
            },
            {
                "id": "collision.worktop",
                "center": {"x": 1.35, "y": 0.45, "z": 0.55},
                "halfExtents": {"x": 0.35, "y": 0.45, "z": 0.35},
                "rotation": identity_rotation(),
                "isBlocking": True,
            },
        ],
        "waypoints": [
            {
                "id": "wp.spawn",
                "position": {"x": 0.0, "y": 0.0, "z": 1.1},
                "arrivalRadius": 0.2,
                "enabled": True,
            },
            {
                "id": "wp.chair",
                "position": {"x": 0.75, "y": 0.0, "z": -0.2},
                "arrivalRadius": 0.18,
                "enabled": True,
            },
            {
                "id": "wp.center",
                "position": {"x": 0.0, "y": 0.0, "z": 0.2},
                "arrivalRadius": 0.22,
                "enabled": True,
            },
        ],
        "routes": [
            {
                "id": "route.home-loop",
                "waypointIDs": ["wp.spawn", "wp.center", "wp.chair"],
                "bidirectional": True,
                "enabled": True,
            }
        ],
        "activities": [
            {
                "id": "chair.sit",
                "action": "sit",
                "entryWaypointID": "wp.chair",
                "transform": transform((0.75, 0.0, -0.2), yaw=-0.6),
                "motionID": "sit.chair",
                "propIDs": [],
                "interruptible": True,
            },
            {
                "id": "home.walk",
                "action": "walk",
                "entryWaypointID": "wp.center",
                "transform": transform((0.0, 0.0, 0.2), yaw=1.2),
                "motionID": "walk.forward",
                "propIDs": [],
                "interruptible": True,
            },
        ],
        "activityDefinitions": [
            {
                "id": "chair.sit",
                "activity": {"type": "sit", "anchorID": "chair.sit"},
                "phases": six_phases(
                    approach_anchors=["chair.sit"],
                    approach_motions=["walk.forward"],
                    approach_duration=1.5,
                    loop_motions=["sit.chair"],
                ),
                "interruptible": True,
                "cooldownSeconds": 30.0,
            },
            {
                "id": "home.walk",
                "activity": {"type": "walk", "destinationID": "wp.center"},
                "phases": six_phases(
                    approach_anchors=["home.walk"],
                    approach_motions=["walk.forward"],
                    enter_duration=0.0,
                    loop_motions=["walk.forward"],
                    loop_duration=0.0,
                    exit_duration=0.0,
                ),
                "interruptible": True,
                "cooldownSeconds": 5.0,
            },
        ],
        "cameras": [
            {
                "id": "camera.main",
                "transform": transform((0.0, 0.8, 1.5), yaw=0.2, pitch=0.1),
                "fieldOfViewDegrees": 60.0,
                "nearPlane": 0.05,
                "farPlane": 200.0,
            },
            {
                "id": "camera.scaled",
                "transform": transform((-1.0, 0.5, 0.0), yaw=-0.5, scale=(2.0, 3.0, 4.0)),
                "fieldOfViewDegrees": 66.0,
                "nearPlane": 0.1,
                "farPlane": 100.0,
            },
        ],
        "capabilities": [
            "activity:chair.sit",
            "activity:home.walk",
            "camera:camera.main",
            "camera:camera.scaled",
        ],
        "resources": [],
    }


def sort_arrays(manifest: dict) -> dict:
    for key in (
        "collisionVolumes",
        "waypoints",
        "routes",
        "activities",
        "activityDefinitions",
        "cameras",
        "resources",
    ):
        manifest[key] = sorted(manifest[key], key=lambda item: item["id"])
    manifest["capabilities"] = sorted(manifest["capabilities"])
    return manifest


def assert_tolerant_equal(test, expected, actual, abs_tol=1e-4, path="root"):
    if isinstance(expected, dict) and isinstance(actual, dict):
        test.assertEqual(set(expected.keys()), set(actual.keys()), f"{path} keys")
        for key in expected:
            assert_tolerant_equal(
                test, expected[key], actual[key], abs_tol, f"{path}.{key}"
            )
    elif isinstance(expected, list) and isinstance(actual, list):
        test.assertEqual(len(expected), len(actual), f"{path} length")
        for index, (expected_item, actual_item) in enumerate(
            zip(expected, actual)
        ):
            assert_tolerant_equal(
                test, expected_item, actual_item, abs_tol, f"{path}[{index}]"
            )
    elif (
        isinstance(expected, (int, float))
        and not isinstance(expected, bool)
        and isinstance(actual, (int, float))
        and not isinstance(actual, bool)
    ):
        test.assertTrue(
            math.isclose(expected, actual, rel_tol=0.0, abs_tol=abs_tol),
            f"{path}: expected {expected!r}, got {actual!r}",
        )
    else:
        test.assertEqual(expected, actual, path)


def rotations_to_yaw_pitch(manifest: dict) -> dict:
    """Replace every gameplay quaternion with the (yaw, pitch) pair the
    importer restores, so round-trip comparisons survive the exporter's
    two-degree-of-freedom yaw/pitch rotation space."""
    clone = json.loads(json.dumps(manifest))

    def convert(transform_dict):
        transform_dict["rotation"] = list(
            quaternion_to_yaw_pitch(transform_dict["rotation"])
        )

    convert(clone["spawn"])
    for volume in clone["collisionVolumes"]:
        volume["rotation"] = list(quaternion_to_yaw_pitch(volume["rotation"]))
    for activity in clone["activities"]:
        convert(activity["transform"])
    for camera in clone["cameras"]:
        convert(camera["transform"])
    return clone


class PureImportGMGNWorldTests(unittest.TestCase):
    def setUp(self) -> None:
        self.importer = load_importer()

    def test_validates_the_canary_manifest(self) -> None:
        manifest = json.loads(CANARY_MANIFEST.read_text(encoding="utf-8"))
        self.importer.validate_manifest(manifest)

    def test_rejects_unsupported_schema_version(self) -> None:
        manifest = fixture_manifest()
        manifest["schemaVersion"] = 2
        with self.assertRaisesRegex(self.importer.WorldImportError, "schemaVersion"):
            self.importer.validate_manifest(manifest)

    def test_rejects_missing_required_keys(self) -> None:
        manifest = fixture_manifest()
        del manifest["displayName"]
        with self.assertRaisesRegex(self.importer.WorldImportError, "displayName"):
            self.importer.validate_manifest(manifest)

    def test_rejects_non_finite_positions(self) -> None:
        manifest = fixture_manifest()
        manifest["waypoints"][0]["position"]["z"] = float("nan")
        with self.assertRaisesRegex(self.importer.WorldImportError, "finite"):
            self.importer.validate_manifest(manifest)

    def test_rejects_duplicate_ids_across_collections(self) -> None:
        manifest = fixture_manifest()
        manifest["cameras"][0]["id"] = "wp.chair"
        with self.assertRaisesRegex(self.importer.WorldImportError, "duplicate"):
            self.importer.validate_manifest(manifest)

    def test_rejects_route_referencing_missing_waypoint(self) -> None:
        manifest = fixture_manifest()
        manifest["routes"][0]["waypointIDs"] = ["wp.missing"]
        with self.assertRaisesRegex(self.importer.WorldImportError, "missing waypoint"):
            self.importer.validate_manifest(manifest)

    def test_gameplay_to_blender_is_the_exact_inverse_of_export(self) -> None:
        sample = (1.0, 2.0, 3.0)
        blender = self.importer.gameplay_to_blender(sample)
        self.assertEqual(blender, (1.0, -3.0, 2.0))
        self.assertEqual(self.importer.blender_to_gameplay(blender), sample)
        negative = (-1.5, -2.5, 4.25)
        self.assertEqual(self.importer.blender_to_gameplay(self.importer.gameplay_to_blender(negative)), negative)

    def test_scale_conversion_is_the_inverse_of_export(self) -> None:
        sample = (1.0, 2.0, 3.0)
        blender = self.importer.gameplay_scale_to_blender(sample)
        self.assertEqual(blender, (1.0, 3.0, 2.0))
        self.assertEqual(self.importer.blender_scale_to_gameplay(blender), sample)

    def test_yaw_pitch_round_trips_through_exporter_formula(self) -> None:
        for yaw, pitch in (
            (0.0, 0.0),
            (0.4, 0.0),
            (0.0, 0.25),
            (-0.6, 0.0),
            (1.2, -0.3),
            (2.9, 0.0),
            (-2.5, 0.1),
            (0.8, 2.2),
        ):
            quaternion = yaw_pitch_to_quaternion(yaw, pitch)
            restored_yaw, restored_pitch = self.importer.quaternion_to_yaw_pitch(
                (
                    quaternion["w"],
                    quaternion["x"],
                    quaternion["y"],
                    quaternion["z"],
                )
            )
            self.assertAlmostEqual(restored_yaw, yaw, places=9)
            self.assertAlmostEqual(restored_pitch, pitch, places=9)

    def test_floor_ids_are_proxy_surfaces_but_countertops_are_not(self) -> None:
        self.assertTrue(self.importer.is_floor_volume("collision.floor"))
        self.assertTrue(self.importer.is_floor_volume("floor.main"))
        self.assertFalse(self.importer.is_floor_volume("collision.worktop"))
        self.assertFalse(self.importer.is_floor_volume("collision.counter"))

    def test_floor_proxy_corners_sit_at_gameplay_ground(self) -> None:
        manifest = fixture_manifest()
        volume = manifest["collisionVolumes"][0]
        corners = self.importer.floor_proxy_corners(volume)
        self.assertEqual(len(corners), 4)
        for corner in corners:
            self.assertAlmostEqual(corner[2], 0.0, places=9)  # Blender z = ground
        xs = sorted(corner[0] for corner in corners)
        ys = sorted(corner[1] for corner in corners)
        self.assertAlmostEqual(xs[0], -1.9, places=9)
        self.assertAlmostEqual(xs[-1], 1.9, places=9)
        self.assertAlmostEqual(ys[0], -1.65, places=9)
        self.assertAlmostEqual(ys[-1], 1.65, places=9)

    def test_build_markers_marks_exactly_one_spawn(self) -> None:
        manifest = fixture_manifest()
        specs = self.importer.build_markers(manifest)
        spawn_markers = [
            spec
            for spec in specs
            if spec.collection == "GMGN_WAYPOINTS"
            and spec.properties.get("gmgn.spawn") is True
        ]
        self.assertEqual(len(spawn_markers), 1)
        self.assertEqual(spawn_markers[0].object_name, "wp.spawn")
        self.assertEqual(
            spawn_markers[0].location,
            self.importer.gameplay_to_blender((0.0, 0.0, 1.1)),
        )

    def test_build_markers_restores_activity_phases_and_cooldown(self) -> None:
        manifest = fixture_manifest()
        specs = self.importer.build_markers(manifest)
        sit = next(
            spec
            for spec in specs
            if spec.collection == "GMGN_ACTIVITIES" and spec.object_name == "chair.sit"
        )
        props = sit.properties
        self.assertEqual(props["gmgn.action"], "sit")
        self.assertEqual(props["gmgn.entry"], "wp.chair")
        self.assertEqual(props["gmgn.anchor"], "chair.sit")
        self.assertEqual(props["gmgn.cooldown"], 30.0)
        self.assertEqual(props["gmgn.approach_anchors"], ["chair.sit"])
        self.assertEqual(props["gmgn.approach_motions"], ["walk.forward"])
        self.assertEqual(props["gmgn.approach_duration"], 1.5)
        self.assertEqual(props["gmgn.loop_motions"], ["sit.chair"])
        walk = next(
            spec
            for spec in specs
            if spec.collection == "GMGN_ACTIVITIES" and spec.object_name == "home.walk"
        )
        self.assertEqual(walk.properties["gmgn.destination"], "wp.center")
        self.assertEqual(walk.properties["gmgn.enter_duration"], 0.0)

    def test_build_markers_rejects_activity_without_definition(self) -> None:
        manifest = fixture_manifest()
        del manifest["activityDefinitions"][1]
        with self.assertRaisesRegex(self.importer.WorldImportError, "activityDefinition"):
            self.importer.build_markers(manifest)

    def test_build_markers_puts_only_floor_volumes_into_nav_source(self) -> None:
        manifest = fixture_manifest()
        specs = self.importer.build_markers(manifest)
        nav_specs = [spec for spec in specs if spec.collection == "GMGN_NAV_SOURCE"]
        source_specs = [spec for spec in specs if spec.collection == "GMGN_SOURCE"]
        self.assertEqual(len(nav_specs), 1)
        self.assertEqual(nav_specs[0].properties["gmgn.proxy_of"], "collision.floor")
        self.assertEqual(len(source_specs), 1)
        self.assertTrue(source_specs[0].hidden)

    def test_build_markers_preserves_generated_navigation_ownership(self) -> None:
        manifest = fixture_manifest()
        manifest["waypoints"].append(
            {
                "id": "wp.auto.00",
                "position": {"x": 0.25, "y": 0.0, "z": 0.25},
                "arrivalRadius": 0.2,
                "enabled": True,
            }
        )
        manifest["routes"].append(
            {
                "id": "route.auto.00",
                "waypointIDs": ["wp.center", "wp.auto.00"],
                "bidirectional": True,
                "enabled": True,
            }
        )

        specs = self.importer.build_markers(manifest)
        waypoint = next(spec for spec in specs if spec.object_name == "wp.auto.00")
        route = next(spec for spec in specs if spec.object_name == "route.auto.00")
        self.assertEqual(
            waypoint.properties["gmgn.generated_by"],
            "navigation-baker-v1",
        )
        self.assertEqual(
            route.properties["gmgn.generated_by"],
            "navigation-baker-v1",
        )

    def test_build_markers_records_source_quaternion_on_transform_markers(self) -> None:
        manifest = fixture_manifest()
        specs = self.importer.build_markers(manifest)
        expected = {
            ("GMGN_COLLISION", "collision.floor"): identity_rotation(),
            ("GMGN_WAYPOINTS", "wp.spawn"): yaw_pitch_to_quaternion(0.4, 0.0),
            ("GMGN_ACTIVITIES", "chair.sit"): yaw_pitch_to_quaternion(-0.6, 0.0),
            ("GMGN_CAMERAS", "camera.main"): yaw_pitch_to_quaternion(0.2, 0.1),
        }
        for spec in specs:
            key = (spec.collection, spec.object_name)
            if key not in expected:
                continue
            stored = spec.properties["gmgn.source_quaternion"]
            self.assertEqual(len(stored), 4, key)
            self.assertEqual(
                list(stored),
                [expected[key]["w"], expected[key]["x"], expected[key]["y"], expected[key]["z"]],
                key,
            )
            self.assertTrue("gmgn.source_yaw" in spec.properties, key)
            self.assertTrue("gmgn.source_pitch" in spec.properties, key)
            # Stored yaw/pitch equal the ones restored by quaternion_to_yaw_pitch.
            restored_yaw, restored_pitch = self.importer.quaternion_to_yaw_pitch(
                tuple(stored)
            )
            self.assertAlmostEqual(
                spec.properties["gmgn.source_yaw"], restored_yaw, places=9, msg=key
            )
            self.assertAlmostEqual(
                spec.properties["gmgn.source_pitch"], restored_pitch, places=9, msg=key
            )
        # Regular (non-spawn) waypoints and routes carry no source quaternion.
        for spec in specs:
            if spec.collection == "GMGN_WAYPOINTS" and spec.properties.get("gmgn.spawn"):
                continue  # spawn is a transform marker and keeps source metadata
            if spec.collection in ("GMGN_WAYPOINTS", "GMGN_ROUTES", "GMGN_PROPS"):
                self.assertNotIn("gmgn.source_quaternion", spec.properties, spec.object_name)


@unittest.skipUnless(shutil.which("blender"), "Blender is required")
class ImportGMGNWorldBlenderTests(unittest.TestCase):
    BLENDER = shutil.which("blender") or "blender"

    def _run_blender(self, *args, timeout=120):
        return subprocess.run(
            [self.BLENDER, "--background"] + list(args),
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def _inspect(self, blend: Path) -> dict:
        expression = """
import bpy, json

def payload_from_objects(collection):
    out = []
    for obj in collection.objects:
        entry = {
            "name": obj.name,
            "type": obj.type,
            "location": [round(float(v), 6) for v in obj.location],
            "dimensions": [round(float(v), 6) for v in obj.dimensions]
            if obj.type == "MESH"
            else None,
        }
        for key in (
            "gmgn.id", "gmgn.spawn", "gmgn.blocking", "gmgn.arrival_radius",
            "gmgn.enabled", "gmgn.waypoints", "gmgn.pitch", "gmgn.action",
            "gmgn.generated_by", "gmgn.proxy_of", "gmgn.entry",
        ):
            if key in obj:
                value = obj[key]
                if isinstance(value, list):
                    value = list(value)
                entry[key] = value
        out.append(entry)
    return sorted(out, key=lambda item: str(item.get("gmgn.id")))

payload = {
    "collections": sorted(collection.name for collection in bpy.data.collections),
    "package_id": bpy.context.scene.get("gmgn.package_id"),
    "world_id": bpy.context.scene.get("gmgn.world_id"),
    "importer_version": bpy.context.scene.get("gmgn.importer_version"),
    "spawn_count": sum(
        1 for obj in bpy.data.collections["GMGN_WAYPOINTS"].objects
        if obj.get("gmgn.spawn") is True
    ),
    "nav_source_meshes": [
        obj.name for obj in bpy.data.collections["GMGN_NAV_SOURCE"].objects
    ],
    "collisions": payload_from_objects(bpy.data.collections["GMGN_COLLISION"]),
    "waypoints": payload_from_objects(bpy.data.collections["GMGN_WAYPOINTS"]),
}
print("GMGN_INSPECT " + json.dumps(payload, sort_keys=True))
"""
        completed = self._run_blender(str(blend), "--python-expr", expression)
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        line = next(
            line
            for line in completed.stdout.splitlines()
            if line.startswith("GMGN_INSPECT ")
        )
        return json.loads(line.removeprefix("GMGN_INSPECT "))

    def test_fixture_round_trips_through_the_existing_exporter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "world.json"
            blend = root / "fixture.blend"
            exported = root / "package" / "world.json"
            manifest_path.write_text(
                json.dumps(fixture_manifest(), indent=2, sort_keys=True),
                encoding="utf-8",
            )

            imported = self._run_blender(
                "--factory-startup",
                "--python",
                str(IMPORTER_PATH),
                "--",
                "--manifest",
                str(manifest_path),
                "--output",
                str(blend),
            )
            self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)
            self.assertTrue(blend.is_file())

            state = self._inspect(blend)
            self.assertEqual(
                state["collections"],
                [
                    "GMGN_ACTIVITIES",
                    "GMGN_CAMERAS",
                    "GMGN_COLLISION",
                    "GMGN_NAV_SOURCE",
                    "GMGN_PROPS",
                    "GMGN_ROUTES",
                    "GMGN_SOURCE",
                    "GMGN_WAYPOINTS",
                ],
            )
            self.assertEqual(state["package_id"], "roundtrip-fixture")
            self.assertEqual(state["spawn_count"], 1)
            self.assertEqual(state["nav_source_meshes"], ["collision.floor.proxy"])
            floor_collision = next(
                item
                for item in state["collisions"]
                if item.get("gmgn.id") == "collision.floor"
            )
            self.assertEqual(floor_collision["dimensions"], [3.8, 3.3, 0.1])

            exported_run = self._run_blender(
                str(blend),
                "--python",
                str(EXPORTER_PATH),
                "--",
                str(exported),
            )
            self.assertEqual(
                exported_run.returncode, 0, exported_run.stdout + exported_run.stderr
            )

            expected = sort_arrays(fixture_manifest())
            actual = sort_arrays(json.loads(exported.read_text(encoding="utf-8")))
            assert_tolerant_equal(self, expected, actual, abs_tol=1e-4)

    def _normalize_canary_phase_defaults(self, manifest: dict) -> dict:
        """The exporter always writes all five phase keys; the hand-authored
        canary omits empty ones, so fill the defaults before comparing."""
        clone = json.loads(json.dumps(manifest))
        for definition in clone["activityDefinitions"]:
            for contract in definition["phases"]:
                contract.setdefault("requiredAnchorIDs", [])
                contract.setdefault("motionIDs", [])
                contract.setdefault("propIDs", [])
                contract.setdefault("durationSeconds", None)
        return clone

    def test_canary_round_trips_yaw_pitch_and_positions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "canary.json"
            blend = root / "canary.blend"
            exported = root / "package" / "world.json"
            manifest_path.write_text(CANARY_MANIFEST.read_text(encoding="utf-8"))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

            imported = self._run_blender(
                "--factory-startup",
                "--python",
                str(IMPORTER_PATH),
                "--",
                "--manifest",
                str(manifest_path),
                "--output",
                str(blend),
            )
            self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)

            exported_run = self._run_blender(
                str(blend),
                "--python",
                str(EXPORTER_PATH),
                "--",
                str(exported),
            )
            self.assertEqual(
                exported_run.returncode, 0, exported_run.stdout + exported_run.stderr
            )
            exported_manifest = json.loads(exported.read_text(encoding="utf-8"))

            expected = sort_arrays(
                rotations_to_yaw_pitch(self._normalize_canary_phase_defaults(manifest))
            )
            actual = sort_arrays(rotations_to_yaw_pitch(exported_manifest))
            assert_tolerant_equal(self, expected, actual, abs_tol=1e-3)

    @staticmethod
    def _quaternion_dot(left: dict, right: dict) -> float:
        left_norm = math.sqrt(
            sum(left[axis] * left[axis] for axis in ("w", "x", "y", "z"))
        )
        right_norm = math.sqrt(
            sum(right[axis] * right[axis] for axis in ("w", "x", "y", "z"))
        )
        return sum(left[axis] * right[axis] for axis in ("w", "x", "y", "z")) / (
            left_norm * right_norm
        )

    def test_canary_round_trips_raw_quaternions_and_display_names(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "canary.json"
            blend = root / "canary.blend"
            exported = root / "package" / "world.json"
            manifest_path.write_text(CANARY_MANIFEST.read_text(encoding="utf-8"))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

            imported = self._run_blender(
                "--factory-startup",
                "--python",
                str(IMPORTER_PATH),
                "--",
                "--manifest",
                str(manifest_path),
                "--output",
                str(blend),
            )
            self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)

            exported_run = self._run_blender(
                str(blend),
                "--python",
                str(EXPORTER_PATH),
                "--",
                str(exported),
            )
            self.assertEqual(
                exported_run.returncode, 0, exported_run.stdout + exported_run.stderr
            )
            exported_manifest = json.loads(exported.read_text(encoding="utf-8"))

            original_cameras = {
                camera["id"]: camera for camera in manifest["cameras"]
            }
            exported_cameras = {
                camera["id"]: camera for camera in exported_manifest["cameras"]
            }
            self.assertEqual(set(exported_cameras), set(original_cameras))
            for camera_id, camera in original_cameras.items():
                exported = exported_cameras[camera_id]
                dot = self._quaternion_dot(
                    camera["transform"]["rotation"],
                    exported["transform"]["rotation"],
                )
                # Full quaternions (including any roll) survive the round trip.
                self.assertGreater(
                    dot,
                    1.0 - 1e-9,
                    f"camera {camera_id} quaternion roll was lost: {dot}",
                )
                self.assertLess(dot, 1.0 + 1e-9, f"camera {camera_id} quaternion changed")

            exported_definitions = {
                definition["id"]: definition
                for definition in exported_manifest["activityDefinitions"]
            }
            self.assertEqual(
                exported_definitions["dining.walk"].get("displayName"), "走到餐桌旁"
            )
            self.assertEqual(
                exported_definitions["kitchen.walk"].get("displayName"), "走到厨房操作台"
            )
            for definition_id in ("chair.sit", "home.idle", "window.gaze"):
                self.assertNotIn("displayName", exported_definitions[definition_id])

    def test_imports_canary_with_nav_proxy_glb(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "canary.json"
            blend = root / "canary.blend"
            glb = root / "canary-proxy.glb"
            manifest_path.write_text(CANARY_MANIFEST.read_text(encoding="utf-8"))

            imported = self._run_blender(
                "--factory-startup",
                "--python",
                str(IMPORTER_PATH),
                "--",
                "--manifest",
                str(manifest_path),
                "--output",
                str(blend),
                "--glb-output",
                str(glb),
            )
            self.assertEqual(imported.returncode, 0, imported.stdout + imported.stderr)
            self.assertTrue(blend.is_file())
            self.assertTrue(glb.is_file())

            importer = load_importer()
            glb_spec = importlib.util.spec_from_file_location(
                "import_gmgn_glb",
                Path(__file__).parents[1] / "import_gmgn_glb.py",
            )
            assert glb_spec is not None and glb_spec.loader is not None
            glb_module = importlib.util.module_from_spec(glb_spec)
            glb_spec.loader.exec_module(glb_module)

            glb_info = glb_module.inspect_glb(glb)
            self.assertEqual(glb_info.version, 2)
            self.assertGreaterEqual(glb_info.triangle_count, 1)
            self.assertGreaterEqual(glb_info.mesh_count, 1)

    def test_refuses_to_overwrite_existing_blend_without_force(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path = root / "world.json"
            blend = root / "existing.blend"
            manifest_path.write_text(
                json.dumps(fixture_manifest()), encoding="utf-8"
            )
            command = [
                self.BLENDER,
                "--background",
                "--factory-startup",
                "--python",
                str(IMPORTER_PATH),
                "--",
                "--manifest",
                str(manifest_path),
                "--output",
                str(blend),
            ]
            first = subprocess.run(
                command, check=False, capture_output=True, text=True, timeout=120
            )
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            original = blend.read_bytes()

            second = subprocess.run(
                command, check=False, capture_output=True, text=True, timeout=120
            )
            self.assertNotEqual(second.returncode, 0)
            self.assertIn("already exists", second.stdout + second.stderr)
            self.assertEqual(blend.read_bytes(), original)

            forced = subprocess.run(
                command + ["--force"],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
            self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)


if __name__ == "__main__":
    unittest.main()
