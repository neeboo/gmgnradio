from __future__ import annotations

import hashlib
import importlib.util
import math
import json
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "export_gmgn_world.py"


def load_exporter():
    spec = importlib.util.spec_from_file_location("export_gmgn_world", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeVector:
    def __init__(self, x: float, y: float, z: float) -> None:
        self.x = x
        self.y = y
        self.z = z


class FakeEuler:
    def __init__(self, z: float = 0.0) -> None:
        self.z = z


class FakeObject(dict):
    def __init__(
        self,
        name: str,
        *,
        location=(0.0, 0.0, 0.0),
        dimensions=(0.0, 0.0, 0.0),
        rotation_z=0.0,
        **properties,
    ) -> None:
        super().__init__(properties)
        self.name = name
        self.location = FakeVector(*location)
        self.dimensions = FakeVector(*dimensions)
        self.rotation_euler = FakeEuler(rotation_z)


class FakeCollection:
    def __init__(self, objects=()) -> None:
        self.objects = list(objects)


class FakeCollections(dict):
    def get(self, key, default=None):
        return super().get(key, default)


class FakeScene:
    def __init__(self, collections, **properties) -> None:
        self.collections = FakeCollections(collections)
        self.properties = properties


class ExportGMGNWorldTests(unittest.TestCase):
    def setUp(self) -> None:
        self.exporter = load_exporter()

    def make_scene(self, resource_path: Path | None = None):
        props = []
        if resource_path is not None:
            props.append(
                FakeObject(
                    "Visual",
                    **{
                        "gmgn.id": "visual.spz",
                        "gmgn.kind": "spz",
                        "gmgn.path": str(resource_path),
                        "gmgn.package_path": "visual/world.spz",
                    },
                )
            )

        return FakeScene(
            {
                "GMGN_COLLISION": FakeCollection(
                    [
                        FakeObject(
                            "Wall B",
                            location=(2.0, 3.0, 1.0),
                            dimensions=(2.0, 4.0, 6.0),
                            **{"gmgn.id": "collision.z-wall"},
                        ),
                        FakeObject(
                            "Wall A",
                            location=(0.0, 0.0, 1.0),
                            dimensions=(4.0, 6.0, 2.0),
                            **{"gmgn.id": "collision.a-wall"},
                        ),
                    ]
                ),
                "GMGN_WAYPOINTS": FakeCollection(
                    [
                        FakeObject(
                            "Window",
                            location=(1.0, 2.0, 3.0),
                            **{"gmgn.id": "wp.window"},
                        ),
                        FakeObject(
                            "Spawn",
                            location=(0.0, -1.0, 0.0),
                            rotation_z=0.5,
                            **{"gmgn.id": "wp.spawn", "gmgn.spawn": True},
                        ),
                    ]
                ),
                "GMGN_ROUTES": FakeCollection(
                    [
                        FakeObject(
                            "Window Route",
                            **{
                                "gmgn.id": "route.window",
                                "gmgn.waypoints": "wp.spawn, wp.window",
                                "gmgn.loop": False,
                            },
                        )
                    ]
                ),
                "GMGN_ACTIVITIES": FakeCollection(
                    [
                        FakeObject(
                            "Window Gaze",
                            **{
                                "gmgn.id": "window.gaze",
                                "gmgn.action": "gaze",
                                "gmgn.entry": "wp.window",
                                "gmgn.motion": "gaze.window",
                                "gmgn.interruptible": True,
                                "gmgn.cooldown": 45,
                                "gmgn.loop_duration": 30,
                            },
                        ),
                        FakeObject(
                            "Listen Music",
                            **{
                                "gmgn.id": "music.listen",
                                "gmgn.action": "listen-to-music",
                                "gmgn.entry": "wp.window",
                                "gmgn.motion": "listen.loop",
                                "gmgn.props": "speaker",
                            },
                        ),
                    ]
                ),
                "GMGN_CAMERAS": FakeCollection(
                    [
                        FakeObject(
                            "Establishing",
                            location=(4.0, -5.0, 2.0),
                            rotation_z=1.0,
                            **{
                                "gmgn.id": "living.establishing",
                                "gmgn.fov": 66.0,
                                "gmgn.near": 0.05,
                                "gmgn.far": 250.0,
                            },
                        )
                    ]
                ),
                "GMGN_PROPS": FakeCollection(props),
            },
            **{
                "gmgn.package_id": "warm-kitchen-canary",
                "gmgn.package_version": "1.0.0",
                "gmgn.world_id": "world-labs-example-warm-kitchen",
                "gmgn.display_name": "Warm Kitchen Canary",
            },
        )

    def test_export_is_stably_ordered_and_converts_blender_coordinates(self) -> None:
        manifest = self.exporter.build_manifest(self.make_scene())

        self.assertEqual(
            [item["id"] for item in manifest["collisionVolumes"]],
            ["collision.a-wall", "collision.z-wall"],
        )
        self.assertEqual(
            [item["id"] for item in manifest["waypoints"]],
            ["wp.spawn", "wp.window"],
        )
        self.assertEqual(
            manifest["calibration"]["visualToGameplay"],
            [
                1.0,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                1.0,
                0.0,
                0.0,
                -1.0,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
                1.0,
            ],
        )
        self.assertEqual(
            manifest["waypoints"][1]["position"],
            {"x": 1.0, "y": 3.0, "z": -2.0},
        )
        self.assertEqual(
            manifest["collisionVolumes"][0]["halfExtents"],
            {"x": 2.0, "y": 1.0, "z": 3.0},
        )

    def test_activity_definitions_are_self_contained_and_use_canonical_actions(self) -> None:
        manifest = self.exporter.build_manifest(self.make_scene())

        anchors = {item["id"]: item for item in manifest["activities"]}
        definitions = {item["id"]: item for item in manifest["activityDefinitions"]}

        self.assertEqual(anchors["music.listen"]["action"], "listenMusic")
        self.assertEqual(
            definitions["music.listen"]["activity"],
            {"type": "listenMusic", "anchorID": "music.listen"},
        )
        self.assertEqual(
            [phase["phase"] for phase in definitions["window.gaze"]["phases"]],
            ["approach", "enter", "loop", "exit", "interrupt", "failed"],
        )
        self.assertEqual(
            definitions["window.gaze"]["phases"][2],
            {
                "phase": "loop",
                "requiredAnchorIDs": [],
                "motionIDs": ["gaze.window"],
                "propIDs": [],
                "durationSeconds": 30.0,
            },
        )
        self.assertEqual(definitions["window.gaze"]["cooldownSeconds"], 45.0)

    def test_rotation_reuses_stored_source_quaternion_when_unchanged(self) -> None:
        exporter = self.exporter
        marker = FakeObject(
            "Cam",
            rotation_z=0.5,
            **{
                "gmgn.id": "camera.roll",
                "gmgn.pitch": 0.2,
                "gmgn.source_quaternion": [0.9, -0.1, -0.2, -0.05],
                "gmgn.source_yaw": 0.5,
                "gmgn.source_pitch": 0.2,
            },
        )
        self.assertEqual(
            exporter._rotation(marker),
            {"w": 0.9, "x": -0.1, "y": -0.2, "z": -0.05},
        )

    def test_rotation_falls_back_when_yaw_or_pitch_is_edited(self) -> None:
        exporter = self.exporter
        stored = [0.9, -0.1, -0.2, -0.05]

        def rotation_from(z: float, pitch: float) -> dict:
            half_yaw = z * 0.5
            half_pitch = pitch * 0.5
            return {
                "x": math.sin(half_pitch) * math.cos(half_yaw),
                "y": math.cos(half_pitch) * math.sin(half_yaw),
                "z": math.sin(half_pitch) * math.sin(half_yaw),
                "w": math.cos(half_pitch) * math.cos(half_yaw),
            }

        edited_yaw = FakeObject(
            "Cam",
            rotation_z=0.6,
            **{
                "gmgn.id": "camera.roll",
                "gmgn.pitch": 0.2,
                "gmgn.source_quaternion": stored,
                "gmgn.source_yaw": 0.5,
                "gmgn.source_pitch": 0.2,
            },
        )
        self.assertEqual(exporter._rotation(edited_yaw), rotation_from(0.6, 0.2))
        self.assertNotEqual(
            list(exporter._rotation(edited_yaw).values()), stored
        )

        edited_pitch = FakeObject(
            "Cam",
            rotation_z=0.5,
            **{
                "gmgn.id": "camera.roll",
                "gmgn.pitch": 0.3,
                "gmgn.source_quaternion": stored,
                "gmgn.source_yaw": 0.5,
                "gmgn.source_pitch": 0.2,
            },
        )
        self.assertEqual(exporter._rotation(edited_pitch), rotation_from(0.5, 0.3))

        # Missing source metadata always falls back to authored conversion.
        no_source = FakeObject(
            "Cam",
            rotation_z=0.5,
            **{"gmgn.id": "camera.roll", "gmgn.pitch": 0.2},
        )
        self.assertEqual(exporter._rotation(no_source), rotation_from(0.5, 0.2))

    def test_rotation_rejects_invalid_source_quaternion(self) -> None:
        exporter = self.exporter
        for bad in ([0.9, -0.1], [0.9, -0.1, -0.2, float("nan")], "junk"):
            marker = FakeObject(
                "Cam",
                rotation_z=0.5,
                **{
                    "gmgn.id": "camera.roll",
                    "gmgn.pitch": 0.2,
                    "gmgn.source_quaternion": bad,
                    "gmgn.source_yaw": 0.5,
                    "gmgn.source_pitch": 0.2,
                },
            )
            with self.assertRaisesRegex(exporter.ExportError, "source_quaternion"):
                exporter._rotation(marker)

    def test_activity_definition_exports_display_name_only_when_present(self) -> None:
        exporter = self.exporter
        with_display = FakeObject(
            "Kitchen Walk",
            **{
                "gmgn.id": "kitchen.walk",
                "gmgn.action": "walk",
                "gmgn.entry": "wp.kitchen.counter",
                "gmgn.motion": "walk.forward",
                "gmgn.cooldown": 0,
                "gmgn.display_name": "走到厨房操作台",
            },
        )
        definition = exporter._activity_definition(with_display)
        self.assertEqual(definition["displayName"], "走到厨房操作台")

        without_display = FakeObject(
            "Home Walk",
            **{
                "gmgn.id": "home.walk",
                "gmgn.action": "walk",
                "gmgn.entry": "wp.center",
                "gmgn.motion": "walk.forward",
                "gmgn.cooldown": 0,
            },
        )
        self.assertNotIn("displayName", exporter._activity_definition(without_display))

        blank_display = FakeObject(
            "Blank",
            **{
                "gmgn.id": "blank.walk",
                "gmgn.action": "walk",
                "gmgn.entry": "wp.center",
                "gmgn.cooldown": 0,
                "gmgn.display_name": "   ",
            },
        )
        self.assertNotIn("displayName", exporter._activity_definition(blank_display))

    def test_main_refuses_existing_output_without_force(self) -> None:
        exporter = self.exporter
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "world.json"
            original = b"keep-me-byte-identical"
            output.write_bytes(original)

            refused = exporter.main(["--", str(output)])
            self.assertEqual(refused, 1)
            self.assertEqual(output.read_bytes(), original)

            # With --force the existence guard is skipped; without bpy in this
            # pure environment the run then stops at the bpy import stage.
            forced = exporter.main(["--", "--force", str(output)])
            self.assertEqual(forced, 2)
            self.assertEqual(output.read_bytes(), original)

    def test_duplicate_stable_ids_are_rejected_across_collections(self) -> None:
        scene = self.make_scene()
        scene.collections["GMGN_CAMERAS"].objects[0]["gmgn.id"] = "wp.window"

        with self.assertRaisesRegex(self.exporter.ExportError, "duplicate gmgn.id 'wp.window'"):
            self.exporter.build_manifest(scene)

    def test_resource_hash_uses_file_contents(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory) / "world.spz"
            payload = b"deterministic-spz-fixture"
            asset.write_bytes(payload)

            manifest = self.exporter.build_manifest(self.make_scene(asset))

        self.assertEqual(
            manifest["resources"],
            [
                {
                    "id": "visual.spz",
                    "kind": "spz",
                    "path": "visual/world.spz",
                    "sha256": hashlib.sha256(payload).hexdigest(),
                }
            ],
        )

    def test_write_manifest_is_canonical_and_repeatable(self) -> None:
        manifest = self.exporter.build_manifest(self.make_scene())
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "world.json"
            self.exporter.write_manifest(manifest, output)
            first = output.read_bytes()
            self.exporter.write_manifest(manifest, output)
            second = output.read_bytes()

        self.assertEqual(first, second)
        self.assertEqual(json.loads(first), manifest)
        self.assertTrue(first.endswith(b"\n"))


if __name__ == "__main__":
    unittest.main()
