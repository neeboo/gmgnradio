import hashlib
import io
import json
import math
import struct
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

from tools.motion.gmgn_motion_factory import (
    ArdyClient,
    MotionSpecError,
    WorkerCapacity,
    assess_worker_capacity,
    build_vmd,
    build_vrma,
    main,
    publish_motion,
    validate_motion_spec,
)


def sample_spec() -> dict:
    return {
        "name": "kitchen-groove",
        "duration": 2.0,
        "loop": True,
        "tracks": {
            "hips": [
                {"t": 0.0, "r": [0.0, 0.0, 0.0]},
                {"t": 2.0, "r": [0.0, 0.0, 0.0]},
            ],
            "leftUpperArm": [
                {"t": 0.0, "r": [0.0, 0.0, -20.0]},
                {"t": 1.0, "r": [5.0, 0.0, 15.0]},
                {"t": 2.0, "r": [0.0, 0.0, -20.0]},
            ],
        },
        "hips": [
            {"t": 0.0, "p": [0.0, 0.0, 0.0]},
            {"t": 2.0, "p": [0.0, 0.0, 0.0]},
        ],
    }


def glb_json(data: bytes) -> dict:
    magic, version, total_length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF" or version != 2 or total_length != len(data):
        raise AssertionError("invalid GLB header")
    json_length, json_kind = struct.unpack_from("<II", data, 12)
    if json_kind != 0x4E4F534A:
        raise AssertionError("missing JSON chunk")
    return json.loads(data[20 : 20 + json_length].decode("utf-8").rstrip(" "))


class MotionSpecValidationTests(unittest.TestCase):
    def test_builds_vrm_animation_glb_from_ardy_compatible_spec(self) -> None:
        data = build_vrma(sample_spec())
        document = glb_json(data)

        self.assertIn("VRMC_vrm_animation", document["extensionsUsed"])
        self.assertEqual(
            document["extensions"]["VRMC_vrm_animation"]["specVersion"],
            "1.0",
        )
        self.assertEqual(document["animations"][0]["name"], "kitchen-groove")
        self.assertGreaterEqual(len(document["animations"][0]["channels"]), 3)
        self.assertEqual(document["extras"]["gmgn"]["loop"], True)

    def test_builds_pmx_safe_vmd_without_finger_tracks(self) -> None:
        data = build_vmd(sample_spec())

        self.assertEqual(data[:30].rstrip(b"\0"), b"Vocaloid Motion Data 0002")
        bone_count = struct.unpack_from("<I", data, 50)[0]
        self.assertGreaterEqual(bone_count, 5)
        names = []
        offset = 54
        for _ in range(bone_count):
            names.append(data[offset : offset + 15].split(b"\0", 1)[0].decode("shift_jis"))
            offset += 111
        self.assertNotIn("下半身", names)
        self.assertIn("左腕", names)
        self.assertIn("センター", names)
        self.assertFalse(any("指" in name for name in names))

    def test_pmx_vmd_preserves_all_ardy_hips_motion_after_scene_kit_conversion(self) -> None:
        spec = sample_spec()
        spec["hips"] = [
            {"t": 0.0, "p": [0.0, 0.0, 0.0]},
            {"t": 0.5, "p": [0.4, 0.32, -0.6]},
            {"t": 1.0, "p": [0.0, 0.0, 0.0]},
        ]

        data = build_vmd(spec)
        bone_count = struct.unpack_from("<I", data, 50)[0]
        center_positions = []
        offset = 54
        for _ in range(bone_count):
            name = data[offset : offset + 15].split(b"\0", 1)[0].decode("shift_jis")
            frame = struct.unpack_from("<I", data, offset + 15)[0]
            position = struct.unpack_from("<3f", data, offset + 19)
            if name == "センター":
                center_positions.append((frame, position))
            offset += 111

        self.assertEqual([frame for frame, _ in center_positions], [0, 15, 30, 60])
        scene_kit_positions = [
            (position[0], position[1], -position[2])
            for _, position in center_positions
        ]
        self.assertAlmostEqual(scene_kit_positions[1][0], 0.4 / 0.08, places=5)
        self.assertAlmostEqual(scene_kit_positions[1][1], 0.32 / 0.08, places=5)
        self.assertAlmostEqual(scene_kit_positions[1][2], -0.6 / 0.08, places=5)

    def test_pmx_vmd_preserves_ardy_rotation_after_scene_kit_conversion(self) -> None:
        spec = sample_spec()
        spec["tracks"]["hips"] = [
            {"t": 0.0, "r": [90.0, 0.0, 0.0]},
            {"t": 2.0, "r": [90.0, 0.0, 0.0]},
        ]

        data = build_vmd(spec)
        bone_count = struct.unpack_from("<I", data, 50)[0]
        offset = 54
        scene_kit_rotation = None
        for _ in range(bone_count):
            name = data[offset : offset + 15].split(b"\0", 1)[0].decode("shift_jis")
            frame = struct.unpack_from("<I", data, offset + 15)[0]
            rotation = struct.unpack_from("<4f", data, offset + 31)
            if name == "センター" and frame == 0:
                scene_kit_rotation = (
                    -rotation[0],
                    -rotation[1],
                    rotation[2],
                    rotation[3],
                )
                break
            offset += 111

        expected = math.sqrt(0.5)
        self.assertIsNotNone(scene_kit_rotation)
        self.assertAlmostEqual(scene_kit_rotation[0], expected, places=5)
        self.assertAlmostEqual(scene_kit_rotation[1], 0.0, places=5)
        self.assertAlmostEqual(scene_kit_rotation[2], 0.0, places=5)
        self.assertAlmostEqual(scene_kit_rotation[3], expected, places=5)

    def test_pmx_vmd_composes_upper_chest_into_the_available_torso_bone(self) -> None:
        spec = sample_spec()
        spec["tracks"] = {
            "chest": [
                {"t": 0.0, "r": [10.0, 0.0, 0.0]},
                {"t": 2.0, "r": [10.0, 0.0, 0.0]},
            ],
            "upperChest": [
                {"t": 0.0, "r": [20.0, 0.0, 0.0]},
                {"t": 2.0, "r": [20.0, 0.0, 0.0]},
            ],
        }

        data = build_vmd(spec)
        bone_count = struct.unpack_from("<I", data, 50)[0]
        offset = 54
        scene_kit_rotation = None
        for _ in range(bone_count):
            name = data[offset : offset + 15].split(b"\0", 1)[0].decode("shift_jis")
            frame = struct.unpack_from("<I", data, offset + 15)[0]
            rotation = struct.unpack_from("<4f", data, offset + 31)
            if name == "上半身2" and frame == 0:
                scene_kit_rotation = (-rotation[0], -rotation[1], rotation[2], rotation[3])
                break
            offset += 111

        self.assertIsNotNone(scene_kit_rotation)
        half_angle = math.radians(30.0) / 2.0
        expected = (math.sin(half_angle), 0.0, 0.0, math.cos(half_angle))
        self.assertGreater(
            abs(sum(actual * wanted for actual, wanted in zip(scene_kit_rotation, expected))),
            0.99999,
        )

    def test_rejects_unknown_bones_non_finite_values_and_unsafe_root_motion(self) -> None:
        cases = []

        unknown = sample_spec()
        unknown["tracks"]["tail"] = [{"t": 0.0, "r": [0.0, 0.0, 0.0]}]
        cases.append(unknown)

        non_finite = sample_spec()
        non_finite["tracks"]["hips"][0]["r"][1] = math.nan
        cases.append(non_finite)

        unsafe_root = sample_spec()
        unsafe_root["hips"][1]["p"] = [30.0, 0.0, 0.0]
        cases.append(unsafe_root)

        for spec in cases:
            with self.subTest(spec=spec):
                with self.assertRaises(MotionSpecError):
                    validate_motion_spec(spec)


class MotionPublishingTests(unittest.TestCase):
    def test_publishes_versioned_vrma_and_download_catalog_with_sha256(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_root = Path(temporary)
            entry = publish_motion(
                spec=sample_spec(),
                output_root=output_root,
                motion_id="gmgn.motion.kitchen-groove",
                display_name="Kitchen Groove",
                version="1.0.0",
                activity_ids=["music.dance", "cooking.stir"],
                prompt="dance gently while stirring a pot",
                seed=17,
                generator={
                    "engine": "ardy",
                    "model": "ARDY-Core-RP-20FPS-Horizon40",
                    "revision": "abe6c43",
                },
                stride_speed=0.9,
                playback_rate=1.25,
                in_place=True,
            )

            catalog = json.loads((output_root / "catalog.json").read_text())
            asset_path = output_root / entry["path"]
            digest = hashlib.sha256(asset_path.read_bytes()).hexdigest()

            self.assertEqual(catalog["schemaVersion"], 1)
            self.assertEqual(catalog["motions"], [entry])
            self.assertEqual(entry["id"], "gmgn.motion.kitchen-groove")
            self.assertEqual(entry["version"], "1.0.0")
            self.assertEqual(entry["format"], "vrma")
            self.assertEqual(entry["sha256"], digest)
            self.assertEqual(entry["bytes"], asset_path.stat().st_size)
            self.assertEqual(entry["avatarFormats"], ["vrm"])
            self.assertEqual(entry["activityIDs"], ["cooking.stir", "music.dance"])
            self.assertEqual(entry["strideSpeed"], 0.9)
            self.assertEqual(entry["playbackRate"], 1.25)
            self.assertTrue(entry["inPlace"])
            self.assertEqual(entry["source"]["seed"], 17)
            self.assertEqual(entry["source"]["prompt"], "dance gently while stirring a pot")
            self.assertEqual(glb_json(asset_path.read_bytes())["asset"]["version"], "2.0")

    def test_publishes_pmx_vmd_with_a_separate_catalog_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            output_root = Path(temporary)
            entry = publish_motion(
                spec=sample_spec(),
                output_root=output_root,
                motion_id="gmgn.motion.kitchen-groove-pmx",
                display_name="Kitchen Groove PMX",
                version="1.0.0",
                activity_ids=["music.dance"],
                prompt="dance safely without finger animation",
                seed=17,
                generator={"engine": "ardy", "model": "test", "revision": "test"},
                motion_format="vmd",
            )

            asset_path = output_root / entry["path"]
            self.assertEqual(entry["format"], "vmd")
            self.assertEqual(entry["avatarFormats"], ["pmx"])
            self.assertEqual(asset_path.suffix, ".vmd")
            self.assertTrue(asset_path.read_bytes().startswith(b"Vocaloid Motion Data 0002"))


class WorkerCapacityTests(unittest.TestCase):
    def test_16_gib_memory_and_8_gib_vram_requires_swap_and_one_job(self) -> None:
        blocked = assess_worker_capacity(memory_gib=16.0, swap_gib=0.0, vram_gib=8.0)
        constrained = assess_worker_capacity(memory_gib=16.0, swap_gib=32.0, vram_gib=8.0)

        self.assertEqual(blocked.status, "blocked")
        self.assertIn("swap", blocked.reasons[0].lower())
        self.assertEqual(constrained.status, "constrained")
        self.assertEqual(constrained.max_concurrency, 1)

    def test_32_gib_memory_and_8_gib_vram_is_ready_for_one_worker(self) -> None:
        capacity = assess_worker_capacity(memory_gib=32.0, swap_gib=0.0, vram_gib=8.0)

        self.assertEqual(
            capacity,
            WorkerCapacity(status="ready", max_concurrency=1, reasons=()),
        )


class ArdyClientTests(unittest.TestCase):
    def test_generate_posts_prompt_duration_and_seed_then_validates_response(self) -> None:
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers["Content-Length"])
                requests.append(json.loads(self.rfile.read(length)))
                body = json.dumps(sample_spec()).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            client = ArdyClient(f"http://127.0.0.1:{server.server_port}")
            result = client.generate(
                text="dance while stirring a pot",
                duration=2.0,
                seed=17,
                waypoints=[{"x": 1.25, "z": -0.5}, {"x": 2.0, "z": 0.75}],
            )
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

        self.assertEqual(
            requests,
            [{
                "text": "dance while stirring a pot",
                "duration": 2.0,
                "seed": 17,
                "waypoints": [{"x": 1.25, "z": -0.5}, {"x": 2.0, "z": 0.75}],
            }],
        )
        self.assertEqual(result["name"], "kitchen-groove")

    def test_generate_rejects_invalid_waypoints_before_contacting_ardy(self) -> None:
        client = ArdyClient("http://127.0.0.1:9", timeout=0.1)

        for waypoints in (
            "not-a-list",
            [{}],
            [{"x": True, "z": 0}],
            [{"x": 0, "z": float("inf")}],
            [{"x": 26, "z": 0}],
        ):
            with self.subTest(waypoints=waypoints):
                with self.assertRaises(MotionSpecError):
                    client.generate(text="walk", waypoints=waypoints)

    def test_generate_command_publishes_a_downloadable_motion(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers["Content-Length"])
                self.rfile.read(length)
                body = json.dumps(sample_spec()).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as temporary:
                output = io.StringIO()
                result = main(
                    [
                        "generate",
                        "--ardy-url",
                        f"http://127.0.0.1:{server.server_port}",
                        "--prompt",
                        "dance while stirring a pot",
                        "--duration",
                        "2",
                        "--seed",
                        "17",
                        "--id",
                        "gmgn.motion.kitchen-groove",
                        "--name",
                        "Kitchen Groove",
                        "--version",
                        "1.0.0",
                        "--activity",
                        "cooking.stir",
                        "--output-root",
                        temporary,
                    ],
                    stdout=output,
                )
                entry = json.loads(output.getvalue())
                self.assertEqual(result, 0)
                self.assertTrue((Path(temporary) / entry["path"]).is_file())
                self.assertTrue((Path(temporary) / "catalog.json").is_file())
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()

    def test_generate_rejects_an_invalid_engine_response(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                body = b'{"name":"broken"}'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args) -> None:
                return

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with self.assertRaises(MotionSpecError):
                ArdyClient(f"http://127.0.0.1:{server.server_port}").generate(text="dance")
        finally:
            server.shutdown()
            thread.join(timeout=2)
            server.server_close()


class CommandTests(unittest.TestCase):
    def test_preflight_reports_constrained_16_gib_worker(self) -> None:
        output = io.StringIO()
        result = main(
            [
                "preflight",
                "--memory-gib",
                "16",
                "--swap-gib",
                "32",
                "--vram-gib",
                "8",
            ],
            stdout=output,
        )

        self.assertEqual(result, 0)
        self.assertEqual(json.loads(output.getvalue())["status"], "constrained")

    def test_publish_spec_supports_local_end_to_end_client_testing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            spec_path = root / "motion.json"
            spec_path.write_text(json.dumps(sample_spec()))
            output = io.StringIO()

            result = main(
                [
                    "publish-spec",
                    "--spec",
                    str(spec_path),
                    "--id",
                    "gmgn.motion.local-preview",
                    "--name",
                    "Local Preview",
                    "--version",
                    "1.0.0",
                    "--activity",
                    "music.dance",
                    "--prompt",
                    "local preview",
                    "--output-root",
                    str(root / "published"),
                ],
                stdout=output,
            )

            entry = json.loads(output.getvalue())
            self.assertEqual(result, 0)
            self.assertTrue((root / "published" / entry["path"]).is_file())


if __name__ == "__main__":
    unittest.main()
