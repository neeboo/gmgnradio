import json
import io
import math
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

from tools.motion.bones_seed_import import (
    BonesSeedError,
    BonesSeedViewerClient,
    parse_bvh,
    retarget_bvh_to_motion_spec,
    retarget_frame,
)
from tools.motion.gmgn_motion_factory import validate_motion_spec
from tools.motion.gmgn_motion_factory import main as motion_factory_main


def minimal_bvh(*, hips_rotations: list[tuple[float, float, float]] | None = None) -> str:
    rotations = hips_rotations or [(0.0, 0.0, 0.0)] * 13
    frames = []
    for index, (rz, ry, rx) in enumerate(rotations):
        frames.append(
            " ".join(
                str(value)
                for value in (
                    0.0,
                    0.0,
                    0.0,
                    0.0,
                    0.0,
                    0.0,
                    index * 10.0,
                    100.0 + index * 5.0,
                    index * 20.0,
                    rz,
                    ry,
                    rx,
                    0.0,
                    0.0,
                    0.0,
                )
            )
        )
    return "\n".join(
        (
            "HIERARCHY",
            "ROOT Root",
            "{",
            "  OFFSET 0 0 0",
            "  CHANNELS 6 Xposition Yposition Zposition Zrotation Yrotation Xrotation",
            "  JOINT Hips",
            "  {",
            "    OFFSET 0 100 0",
            "    CHANNELS 6 Xposition Yposition Zposition Zrotation Yrotation Xrotation",
            "    JOINT Spine1",
            "    {",
            "      OFFSET 0 10 0",
            "      CHANNELS 3 Zrotation Yrotation Xrotation",
            "    }",
            "  }",
            "}",
            "MOTION",
            f"Frames: {len(frames)}",
            "Frame Time: 0.008333333333333333",
            *frames,
        )
    )


class BVHParsingTests(unittest.TestCase):
    def test_parses_native_channel_order_and_frame_values(self) -> None:
        motion = parse_bvh(minimal_bvh())

        self.assertEqual([joint.name for joint in motion.joints], ["Root", "Hips", "Spine1"])
        self.assertEqual(motion.joints[1].parent, "Root")
        self.assertEqual(
            motion.joints[1].channels,
            (
                "Xposition",
                "Yposition",
                "Zposition",
                "Zrotation",
                "Yrotation",
                "Xrotation",
            ),
        )
        self.assertEqual(motion.frames.shape, (13, 15))
        self.assertAlmostEqual(motion.frame_time, 1 / 120)
        self.assertEqual(motion.values(12, "Hips", ("Xposition", "Yposition", "Zposition")), (120.0, 160.0, 240.0))

    def test_rejects_malformed_or_inconsistent_bvh(self) -> None:
        with self.assertRaises(BonesSeedError):
            parse_bvh("not a BVH")
        with self.assertRaises(BonesSeedError):
            parse_bvh(minimal_bvh().replace("Frames: 13", "Frames: 14"))


class BonesSeedRetargetingTests(unittest.TestCase):
    def test_composes_skipped_source_joints_in_target_local_rotation(self) -> None:
        identity = np.eye(3)
        absolute = {
            "Root": identity,
            "Hips": identity,
            "Spine1": Rotation.from_euler("X", 10, degrees=True).as_matrix(),
            "Spine2": Rotation.from_euler("X", 20, degrees=True).as_matrix(),
            "Chest": Rotation.from_euler("X", 30, degrees=True).as_matrix(),
        }
        parents = {
            "Root": None,
            "Hips": "Root",
            "Spine1": "Hips",
            "Spine2": "Spine1",
            "Chest": "Spine2",
        }
        target_map = {"hips": "Hips", "spine": "Spine1", "chest": "Chest"}

        target = retarget_frame(
            absolute,
            parents=parents,
            t_pose_orientations={name: identity for name in parents},
            humanoid_map=target_map,
            heading_correction=identity,
        )

        chest = Rotation.from_matrix(target["chest"]).as_euler("XYZ", degrees=True)
        self.assertAlmostEqual(chest[0], 50.0, places=5)
        self.assertAlmostEqual(chest[1], 0.0, places=5)
        self.assertAlmostEqual(chest[2], 0.0, places=5)

    def test_converts_120_fps_and_preserves_all_root_position_axes(self) -> None:
        identity = np.eye(3)
        spec = retarget_bvh_to_motion_spec(
            minimal_bvh(),
            name="synthetic walk",
            loop=False,
            output_fps=30,
            t_pose_orientations={"Root": identity, "Hips": identity, "Spine1": identity},
            humanoid_map={"hips": "Hips", "spine": "Spine1"},
        )

        validate_motion_spec(spec)
        self.assertEqual([keyframe["t"] for keyframe in spec["hips"]], [0.0, 1 / 30, 2 / 30, 0.1])
        self.assertEqual(spec["hips"][0]["p"], [0.0, 0.0, 0.0])
        self.assertEqual(spec["hips"][-1]["p"], [1.2, 0.6, 2.4])
        self.assertEqual(len(spec["tracks"]["hips"]), 4)
        self.assertEqual(len(spec["tracks"]["spine"]), 4)

    def test_accepts_the_rounded_120_fps_frame_time_used_by_bones_seed(self) -> None:
        identity = np.eye(3)
        rounded_frame_time = minimal_bvh().replace(
            "Frame Time: 0.008333333333333333",
            "Frame Time: 0.008333",
        )

        spec = retarget_bvh_to_motion_spec(
            rounded_frame_time,
            name="rounded frame rate",
            loop=False,
            output_fps=30,
            t_pose_orientations={"Root": identity, "Hips": identity, "Spine1": identity},
            humanoid_map={"hips": "Hips", "spine": "Spine1"},
        )

        self.assertEqual(len(spec["tracks"]["hips"]), 4)

    def test_ignores_unmapped_auxiliary_joints_without_profile_entries(self) -> None:
        identity = np.eye(3)

        spec = retarget_bvh_to_motion_spec(
            minimal_bvh(),
            name="hips only",
            loop=False,
            output_fps=30,
            t_pose_orientations={"Root": identity, "Hips": identity},
            humanoid_map={"hips": "Hips"},
        )

        self.assertEqual(set(spec["tracks"]), {"hips"})

    def test_crops_a_source_range_and_can_keep_only_vertical_root_motion(self) -> None:
        identity = np.eye(3)
        source = minimal_bvh(hips_rotations=[(0.0, 0.0, 0.0)] * 17)

        spec = retarget_bvh_to_motion_spec(
            source,
            name="in-place walk cycle",
            loop=True,
            output_fps=30,
            start_frame=4,
            end_frame=16,
            root_motion="vertical-only",
            t_pose_orientations={"Root": identity, "Hips": identity, "Spine1": identity},
            humanoid_map={"hips": "Hips", "spine": "Spine1"},
        )

        self.assertEqual([keyframe["t"] for keyframe in spec["hips"]], [0.0, 1 / 30, 2 / 30, 0.1])
        self.assertEqual(spec["hips"][0]["p"], [0.0, 0.0, 0.0])
        self.assertEqual(spec["hips"][-1]["p"], [0.0, 0.6, 0.0])

    def test_official_soma_t_pose_profile_removes_initial_backward_heading(self) -> None:
        profile_path = Path(__file__).parents[1] / "profiles" / "bones-seed-soma-v1.json"
        rotations = [(269.606509, -178.627071, 90.318385)] * 13

        spec = retarget_bvh_to_motion_spec(
            minimal_bvh(hips_rotations=rotations),
            name="heading regression",
            loop=False,
            output_fps=30,
            profile_path=profile_path,
            humanoid_map={"hips": "Hips"},
        )

        first = spec["tracks"]["hips"][0]["r"]
        self.assertLess(abs(first[1]), 0.01)
        self.assertLess(abs(first[0]), 1.0)
        self.assertLess(abs(first[2]), 1.0)


class BonesSeedViewerClientTests(unittest.TestCase):
    def test_fetches_one_named_bvh_from_the_official_viewer_contract(self) -> None:
        captured = {}

        def fetch(url: str, timeout: float) -> bytes:
            captured.update(url=url, timeout=timeout)
            return json.dumps({"name": "sit_loop_001__A1", "tree": minimal_bvh()}).encode()

        client = BonesSeedViewerClient(fetch=fetch, timeout=12.5)
        result = client.fetch_bvh("sit_loop_001__A1")

        self.assertEqual(result, minimal_bvh())
        self.assertIn("seed-viewer.bones.studio/api/storage_local/somabvh/", captured["url"])
        self.assertIn("bvhpath=sit_loop_001__A1", captured["url"])
        self.assertEqual(captured["timeout"], 12.5)

    def test_rejects_unsafe_names_and_mismatched_payloads(self) -> None:
        client = BonesSeedViewerClient(
            fetch=lambda _url, _timeout: json.dumps(
                {"name": "different", "tree": minimal_bvh()}
            ).encode()
        )

        for name in ("../secret", "name/bad", "", "a" * 200):
            with self.subTest(name=name), self.assertRaises(BonesSeedError):
                client.fetch_bvh(name)
        with self.assertRaises(BonesSeedError):
            client.fetch_bvh("sit_loop_001__A1")


class BonesSeedCommandTests(unittest.TestCase):
    def test_import_bones_publishes_a_local_bvh_to_the_download_catalog(self) -> None:
        identity = [1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "sit-loop.bvh"
            source.write_text(minimal_bvh(), encoding="utf-8")
            profile = root / "profile.json"
            profile.write_text(
                json.dumps(
                    {"tPoseOrientations": {"Root": identity, "Hips": identity, "Spine1": identity}}
                ),
                encoding="utf-8",
            )
            output = io.StringIO()

            with mock.patch.dict(
                "tools.motion.bones_seed_import.DEFAULT_HUMANOID_MAP",
                {"hips": "Hips", "spine": "Spine1"},
                clear=True,
            ):
                result = motion_factory_main(
                    [
                        "import-bones",
                        "--bvh",
                        str(source),
                        "--profile",
                        str(profile),
                        "--id",
                        "gmgn.motion.bones.sit-loop-pmx",
                        "--name",
                        "BONES Sit Loop PMX",
                        "--version",
                        "1.0.0",
                        "--activity",
                        "living.sit.chair",
                        "--loop",
                        "--format",
                        "vmd",
                        "--output-root",
                        str(root / "published"),
                    ],
                    stdout=output,
                )

            entry = json.loads(output.getvalue())
            self.assertEqual(result, 0)
            self.assertEqual(entry["format"], "vmd")
            self.assertEqual(entry["source"]["generator"]["engine"], "bones-seed")
            self.assertTrue((root / "published" / entry["path"]).is_file())

    def test_import_bones_is_available_through_the_documented_script_entrypoint(self) -> None:
        factory = Path(__file__).parents[1] / "gmgn_motion_factory.py"

        completed = subprocess.run(
            [sys.executable, str(factory), "import-bones", "--help"],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("--motion", completed.stdout)
        self.assertIn("--bvh", completed.stdout)


if __name__ == "__main__":
    unittest.main()
