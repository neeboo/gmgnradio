from __future__ import annotations

import importlib.util
import hashlib
import json
import math
import shutil
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "import_gmgn_glb.py"


def load_importer():
    spec = importlib.util.spec_from_file_location("import_gmgn_glb", MODULE_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_triangle_glb(path: Path, *, nested_transform: bool = False) -> None:
    positions = struct.pack(
        "<9f",
        -1.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        0.0,
        0.0,
        1.0,
    )
    indices = struct.pack("<3H", 0, 1, 2)
    binary = positions + indices
    binary += b"\x00" * ((-len(binary)) % 4)
    nodes = [{"mesh": 0, "name": "ColliderTriangle"}]
    scene_nodes = [0]
    if nested_transform:
        nodes = [
            {
                "name": "ColliderRoot",
                "translation": [1.0, 2.0, 3.0],
                "children": [1],
            },
            {
                "mesh": 0,
                "name": "ColliderTriangle",
                "translation": [0.5, 0.25, -0.75],
            },
        ]
        scene_nodes = [0]
    document = {
        "asset": {"version": "2.0", "generator": "gmgn-test"},
        "scene": 0,
        "scenes": [{"nodes": scene_nodes}],
        "nodes": nodes,
        "meshes": [
            {
                "name": "ColliderTriangle",
                "primitives": [
                    {"attributes": {"POSITION": 0}, "indices": 1, "mode": 4}
                ],
            }
        ],
        "buffers": [{"byteLength": len(binary)}],
        "bufferViews": [
            {"buffer": 0, "byteOffset": 0, "byteLength": len(positions), "target": 34962},
            {"buffer": 0, "byteOffset": len(positions), "byteLength": 6, "target": 34963},
        ],
        "accessors": [
            {
                "bufferView": 0,
                "componentType": 5126,
                "count": 3,
                "type": "VEC3",
                "min": [-1.0, 0.0, 0.0],
                "max": [1.0, 0.0, 1.0],
            },
            {
                "bufferView": 1,
                "componentType": 5123,
                "count": 3,
                "type": "SCALAR",
            },
        ],
    }
    json_payload = json.dumps(document, separators=(",", ":")).encode("utf-8")
    json_payload += b" " * ((-len(json_payload)) % 4)
    total_length = 12 + 8 + len(json_payload) + 8 + len(binary)
    path.write_bytes(
        struct.pack("<4sII", b"glTF", 2, total_length)
        + struct.pack("<II", len(json_payload), 0x4E4F534A)
        + json_payload
        + struct.pack("<II", len(binary), 0x004E4942)
        + binary
    )


class ImportGMGNGLBTests(unittest.TestCase):
    def setUp(self) -> None:
        self.importer = load_importer()

    def test_inspects_binary_gltf_and_counts_triangle_primitives(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "collider.glb"
            write_triangle_glb(source)

            info = self.importer.inspect_glb(source)

        self.assertEqual(info.version, 2)
        self.assertEqual(info.generator, "gmgn-test")
        self.assertEqual(info.mesh_count, 1)
        self.assertEqual(info.primitive_count, 1)
        self.assertEqual(info.triangle_count, 1)

    def test_rejects_a_file_that_is_not_binary_gltf(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "broken.glb"
            source.write_bytes(b"not-a-glb")

            with self.assertRaisesRegex(self.importer.GLBImportError, "header"):
                self.importer.inspect_glb(source)

    def test_world_labs_transform_is_explicit_and_places_ground_at_zero(self) -> None:
        transform = self.importer.source_transform(
            source_coordinates="world-labs-opencv",
            metric_scale=1.75,
            ground_plane_offset=0.4,
        )

        self.assertAlmostEqual(transform.rotation_x_radians, math.pi)
        self.assertEqual(transform.uniform_scale, 1.75)
        self.assertAlmostEqual(transform.translation_z, -0.7)

    def test_standard_gltf_does_not_receive_world_labs_axis_correction(self) -> None:
        transform = self.importer.source_transform(
            source_coordinates="gltf",
            metric_scale=1.0,
            ground_plane_offset=0.0,
        )

        self.assertEqual(transform.rotation_x_radians, 0.0)
        self.assertEqual(transform.uniform_scale, 1.0)
        self.assertEqual(transform.translation_z, 0.0)

    @unittest.skipUnless(shutil.which("blender"), "Blender is required")
    def test_creates_editable_blend_with_source_and_authoring_collections(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "collider.glb"
            output = root / "warm-kitchen.blend"
            write_triangle_glb(source, nested_transform=True)
            expected_source_hash = hashlib.sha256(source.read_bytes()).hexdigest()

            completed = subprocess.run(
                [
                    shutil.which("blender") or "blender",
                    "--background",
                    "--factory-startup",
                    "--python",
                    str(MODULE_PATH),
                    "--",
                    "--input",
                    str(source),
                    "--output",
                    str(output),
                    "--package-id",
                    "warm-kitchen-edit",
                    "--world-id",
                    "world-labs-example-warm-kitchen",
                    "--display-name",
                    "Warm Kitchen Edit",
                    "--metric-scale",
                    "1.75",
                    "--ground-plane-offset",
                    "0.4",
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
            self.assertTrue(output.is_file())

            expression = """
import bpy, json
collections = sorted(collection.name for collection in bpy.data.collections)
payload = {
    "collections": collections,
    "package_id": bpy.context.scene.get("gmgn.package_id"),
    "world_id": bpy.context.scene.get("gmgn.world_id"),
    "source_coordinates": bpy.context.scene.get("gmgn.source_coordinates"),
    "source_sha256": bpy.context.scene.get("gmgn.source_glb_sha256"),
    "importer_version": bpy.context.scene.get("gmgn.importer_version"),
    "source_count": len(bpy.data.collections["GMGN_SOURCE"].objects),
    "editable_count": len(bpy.data.collections["GMGN_NAV_SOURCE"].objects),
    "editable_parents": sorted(
        obj.parent.name if obj.parent else ""
        for obj in bpy.data.collections["GMGN_NAV_SOURCE"].objects
    ),
    "editable_hidden": [
        obj.hide_viewport
        for obj in bpy.data.collections["GMGN_NAV_SOURCE"].objects
    ],
    "editable_transform_locks": [
        list(obj.lock_location) + list(obj.lock_rotation) + list(obj.lock_scale)
        for obj in bpy.data.collections["GMGN_NAV_SOURCE"].objects
    ],
    "spawn_count": len(bpy.data.collections["GMGN_WAYPOINTS"].objects),
}
print("GMGN_INSPECT " + json.dumps(payload, sort_keys=True))
"""
            inspected = subprocess.run(
                [
                    shutil.which("blender") or "blender",
                    "--background",
                    str(output),
                    "--python-expr",
                    expression,
                ],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(inspected.returncode, 0, inspected.stdout + inspected.stderr)
            line = next(
                line for line in inspected.stdout.splitlines() if line.startswith("GMGN_INSPECT ")
            )
            payload = json.loads(line.removeprefix("GMGN_INSPECT "))

        self.assertEqual(
            payload["collections"],
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
        self.assertEqual(payload["package_id"], "warm-kitchen-edit")
        self.assertEqual(payload["world_id"], "world-labs-example-warm-kitchen")
        self.assertEqual(payload["source_coordinates"], "world-labs-opencv")
        self.assertEqual(payload["source_sha256"], expected_source_hash)
        self.assertEqual(payload["importer_version"], "1")
        self.assertEqual(payload["source_count"], 2)
        self.assertEqual(payload["editable_count"], 2)
        self.assertEqual(payload["editable_parents"], ["", ""])
        self.assertEqual(payload["editable_hidden"], [False, False])
        self.assertTrue(
            all(not locked for locks in payload["editable_transform_locks"] for locked in locks)
        )
        self.assertEqual(payload["spawn_count"], 1)

    @unittest.skipUnless(shutil.which("blender"), "Blender is required")
    def test_refuses_to_overwrite_an_authored_blend_without_force(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "collider.glb"
            output = root / "authored.blend"
            write_triangle_glb(source)
            command = [
                shutil.which("blender") or "blender",
                "--background",
                "--factory-startup",
                "--python",
                str(MODULE_PATH),
                "--",
                "--input",
                str(source),
                "--output",
                str(output),
                "--package-id",
                "safe-output",
                "--world-id",
                "world.safe-output",
            ]
            first = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            original = output.read_bytes()

            second = subprocess.run(
                command,
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )

            self.assertNotEqual(second.returncode, 0)
            self.assertIn("already exists", second.stdout + second.stderr)
            self.assertEqual(output.read_bytes(), original)

            forced = subprocess.run(
                command + ["--force"],
                check=False,
                capture_output=True,
                text=True,
                timeout=60,
            )
            self.assertEqual(forced.returncode, 0, forced.stdout + forced.stderr)


if __name__ == "__main__":
    unittest.main()
