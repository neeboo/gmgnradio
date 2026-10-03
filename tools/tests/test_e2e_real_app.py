#!/usr/bin/env python3
"""Gates for the real-App E2E driver's isolation and motion-grounding rules.

These cover the 2026-10-03 reacceptance items:

  * the default test root is canonical and taskd uses an endpoint JSON file;
    long isolated roots are accepted without the removed Unix socket limit;
  * an existing root is refused by default (explicit `--reuse-root` /
    `--overwrite-root` are required);
  * `--avatar-source` / `--motion-source` **copy** packages into the test root
    (never symlink production), reject symlinked sources, and write the
    selection into the test root only;
  * the production fingerprint watches the presence/motion selection files, so a
    leaked selection write cannot pass the isolation check;
  * continuous-motion grounding rejects a zeroed renderer offset even when the
    derived `contactLiftY` is non-zero (the old, self-consistent check would let
    a computed-but-not-applied offset through).

No app, network, or Metal is used.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import shutil
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
DRIVER = REPO_ROOT / "tools/e2e-real-app.py"


def load_driver():
    spec = importlib.util.spec_from_file_location("gmgn_e2e_real_app", DRIVER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class RootSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def test_default_root_is_canonical_and_uses_tcp_endpoint_file(self) -> None:
        root = self.driver.default_e2e_root()
        self.assertEqual(root.parent, Path(tempfile.gettempdir()).resolve())
        self.assertEqual(root, root.resolve())
        endpoint = self.driver.taskd_endpoint_path(root)
        self.assertEqual(endpoint.name,"taskd.endpoint.json")

    def test_long_root_is_not_subject_to_unix_socket_limit(self) -> None:
        deep = Path("/Users/someone/dev/gmgnradio/tmp/e2e-real-app/20261003-171000")
        self.driver.assert_test_root_is_not_production(deep)
        endpoint = self.driver.taskd_endpoint_path(deep)
        self.assertGreater(len(str(endpoint).encode())+1,104)
        self.assertEqual(endpoint.name,"taskd.endpoint.json")

    def test_production_roots_are_refused(self) -> None:
        home = Path.home()
        candidates = [
            home / "Library/Application Support",
            home / "Library/Application Support/ai.gmgn.radio",
            home / "Library/Application Support/gmgn radio",
            home,
        ]
        for candidate in candidates:
            with self.assertRaises(self.driver.E2ERealAppError):
                self.driver.assert_test_root_is_not_production(candidate)

    def test_short_tmp_root_is_accepted(self) -> None:
        temporary = Path(tempfile.mkdtemp(prefix="gmgn-t-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, temporary, ignore_errors=True)
        self.driver.assert_test_root_is_not_production(temporary)
        self.assertEqual(self.driver.taskd_endpoint_path(temporary).name,"taskd.endpoint.json")


class PackageCopyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix="gmgn-t-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.temporary, ignore_errors=True)

    def make_package(self, container: Path, name: str) -> Path:
        package = container / name
        package.mkdir(parents=True)
        (package / "manifest.json").write_text("{}", encoding="utf-8")
        (package / "model.pmx").write_bytes(b"pmx")
        return package

    def test_container_copies_packages_and_selection(self) -> None:
        source = self.temporary / "source"
        self.make_package(source, "pmx.demo")
        self.make_package(source, "pmx.other")
        (source / ".selection.json").write_text(
            json.dumps({"activeID": "pmx.other"}), encoding="utf-8"
        )
        destination = self.temporary / "dest"
        copied = self.driver.copy_package_source(source, destination)
        self.assertEqual(sorted(copied), ["pmx.demo", "pmx.other"])
        self.assertTrue((destination / "pmx.demo" / "model.pmx").is_file())
        # copied, not symlinked
        self.assertFalse((destination / "pmx.demo").is_symlink())
        self.assertEqual(
            json.loads((destination / ".selection.json").read_text())["activeID"],
            "pmx.other",
        )

    def test_single_package_source(self) -> None:
        package = self.make_package(self.temporary, "pmx.single")
        destination = self.temporary / "dest"
        copied = self.driver.copy_package_source(package, destination)
        self.assertEqual(copied, ["pmx.single"])
        self.assertEqual(
            json.loads((destination / ".selection.json").read_text())["activeID"],
            "pmx.single",
        )

    def test_symlinked_source_is_rejected(self) -> None:
        real = self.temporary / "real"
        self.make_package(real, "pmx.demo")
        linked = self.temporary / "linked"
        linked.mkdir()
        (linked / "pmx.demo").symlink_to(real / "pmx.demo", target_is_directory=True)
        with self.assertRaises(self.driver.E2ERealAppError):
            self.driver.copy_package_source(linked, self.temporary / "dest")

    def test_missing_source_is_rejected(self) -> None:
        with self.assertRaises(self.driver.E2ERealAppError):
            self.driver.copy_package_source(
                self.temporary / "nope", self.temporary / "dest"
            )

    def test_container_without_packages_is_rejected(self) -> None:
        empty = self.temporary / "empty"
        empty.mkdir()
        with self.assertRaises(self.driver.E2ERealAppError):
            self.driver.copy_package_source(empty, self.temporary / "dest")

    def test_existing_destination_is_not_overwritten(self) -> None:
        source = self.temporary / "source"
        self.make_package(source, "pmx.demo")
        destination = self.temporary / "dest"
        (destination / "pmx.demo").mkdir(parents=True)
        with self.assertRaises(self.driver.E2ERealAppError):
            self.driver.copy_package_source(source, destination)

    def test_reuse_allows_existing_package_and_rewrites_selection(self) -> None:
        source = self.temporary / "source"
        self.make_package(source, "pmx.demo")
        destination = self.temporary / "dest"
        (destination / "pmx.demo").mkdir(parents=True)
        copied = self.driver.copy_package_source(source, destination, allow_existing=True)
        self.assertEqual(copied, ["pmx.demo"])
        self.assertEqual(
            json.loads((destination / ".selection.json").read_text())["activeID"],
            "pmx.demo",
        )


class PrepareRootTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def setUp(self) -> None:
        self.temporary = Path(tempfile.mkdtemp(prefix="gmgn-t-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, self.temporary, ignore_errors=True)
        self.root = self.temporary / "root"

    def driver_for(self, root: Path, **overrides):
        defaults = dict(
            app=None,
            build=False,
            configuration="Release",
            root=str(root),
            reuse_root=False,
            overwrite_root=False,
            prop_config=str(self.temporary / "absent.json"),
            avatar_source=None,
            motion_source=None,
            asset_image="",
            prop_name="E2E",
            video_url="",
            timeout=1,
            generation_timeout=1,
            chat_timeout=1,
            skip_chat_turn=True,
        )
        defaults.update(overrides)
        return self.driver.RealAppE2E(argparse.Namespace(**defaults))

    def test_existing_root_is_refused_by_default(self) -> None:
        self.root.mkdir()
        sentinel = self.root / "sentinel"
        sentinel.write_text("keep", encoding="utf-8")
        runner = self.driver_for(self.root)
        with self.assertRaises(SystemExit):
            runner.prepare_root()
        self.assertTrue(sentinel.is_file())

    def test_reuse_root_keeps_contents(self) -> None:
        self.root.mkdir()
        sentinel = self.root / "sentinel"
        sentinel.write_text("keep", encoding="utf-8")
        runner = self.driver_for(self.root, reuse_root=True)
        runner.prepare_root()
        self.assertTrue(sentinel.is_file())

    def test_overwrite_root_rebuilds(self) -> None:
        self.root.mkdir()
        sentinel = self.root / "sentinel"
        sentinel.write_text("gone", encoding="utf-8")
        runner = self.driver_for(self.root, overwrite_root=True)
        runner.prepare_root()
        self.assertFalse(sentinel.exists())
        self.assertTrue(self.root.is_dir())

    def test_fresh_root_is_created(self) -> None:
        runner = self.driver_for(self.root)
        runner.prepare_root()
        self.assertTrue((self.root / "Library/Application Support").is_dir())

    def test_long_isolated_root_is_prepared_without_socket_length_gate(self) -> None:
        deep = self.root / ("long-isolated-directory-" * 4) / "business"
        runner = self.driver_for(deep)
        self.assertGreater(len(str(self.driver.taskd_endpoint_path(deep)).encode())+1,104)
        runner.prepare_root()
        self.assertTrue((deep / "Library/Application Support").is_dir())


class FingerprintTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def test_fingerprint_watches_selection_files(self) -> None:
        fingerprint = self.driver.RealAppE2E.production_fingerprint()
        for key in (
            "gmgn radio/PresencePackages",
            "gmgn radio/PresencePackages/.selection.json",
            "gmgn radio/MotionPackages",
            "gmgn radio/MotionPackages/.selection.json",
        ):
            self.assertIn(key, fingerprint)


class GroundingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def good(self) -> dict:
        return {
            "minimumContactY": -0.20,
            "restGlobalReferenceY": 0.0,
            "groundingOffsetY": 0.21,
            "appliedGroundingOffsetY": 0.21,
            "contactLiftY": 0.20,
            "uncompensatedPenetrationY": 0.20,
        }

    def test_valid_frame_passes(self) -> None:
        self.assertTrue(self.driver.motion_grounding_ok(self.good(), [0.0, 0.0, 0.0]))

    def test_zeroed_renderer_offset_fails_even_with_lift(self) -> None:
        frame = dict(self.good(), groundingOffsetY=0.0, appliedGroundingOffsetY=0.0)
        self.assertFalse(self.driver.motion_grounding_ok(frame, [0.0, 0.0, 0.0]))

    def test_zeroed_applied_offset_fails_even_when_raw_offset_is_fine(self) -> None:
        # 原始值算对了但**没有真的施加**（applied=0）必须红：这正是重启那次的字段语义。
        frame = dict(self.good(), groundingOffsetY=0.21, appliedGroundingOffsetY=0.0)
        self.assertFalse(self.driver.motion_grounding_ok(frame, [0.0, 0.0, 0.0]))

    def test_negative_lift_fails(self) -> None:
        frame = dict(self.good(), contactLiftY=-0.1)
        self.assertFalse(self.driver.motion_grounding_ok(frame, [0.0, 0.0, 0.0]))

    def test_missing_fields_fail(self) -> None:
        self.assertFalse(self.driver.motion_grounding_ok({}, [0.0, 0.0, 0.0]))

    def test_non_finite_position_fails(self) -> None:
        self.assertFalse(
            self.driver.motion_grounding_ok(self.good(), [0.0, float("nan"), 0.0])
        )

    def test_position_span(self) -> None:
        span = self.driver.position_span([[0, 0, 0], [0, 0, 1.5], [0.5, 0, 1.5]])
        self.assertAlmostEqual(span, 1.5811388300841898, places=6)
        self.assertEqual(self.driver.position_span([[0, 0, 0]]), 0.0)


class WorldToolParsingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def response(self, result: dict, control_ok: bool = True, is_error: bool = False) -> dict:
        return {
            "ok": control_ok,
            "result": {"result": result, "isError": is_error},
        }

    def test_extract_available_activities(self) -> None:
        response = self.response({
            "ok": True,
            "snapshot": {"activities": [{"id": "home.walk", "action": "walk"}]},
        })
        activities = self.driver.extract_available_activities(response)
        self.assertEqual([a["id"] for a in activities], ["home.walk"])

    def test_extract_available_activities_empty_on_error(self) -> None:
        response = self.response({"code": "unknown_activity"}, is_error=True)
        self.assertEqual(self.driver.extract_available_activities(response), [])

    def test_world_tool_code(self) -> None:
        response = self.response({"code": "unknown_activity", "ok": False}, is_error=True)
        self.assertEqual(self.driver.extract_world_tool_code(response), "unknown_activity")

    def test_world_tool_code_survives_tool_error_flattening(self) -> None:
        # `tool()` sets the control-level ok to False on a world-tool error; the code
        # must still be extractable from result.result for named diagnostics.
        response = self.response({"code": "activity_unavailable", "ok": False}, is_error=True)
        response["ok"] = False
        self.assertEqual(self.driver.extract_world_tool_code(response), "activity_unavailable")

    def test_world_tool_succeeded(self) -> None:
        self.assertTrue(self.driver.world_tool_succeeded(self.response({"ok": True})))
        self.assertFalse(
            self.driver.world_tool_succeeded(self.response({"ok": False}, is_error=True))
        )
        self.assertFalse(
            self.driver.world_tool_succeeded(
                {"ok": False, "result": {"isError": False}}
            )
        )

    def test_choose_activity(self) -> None:
        available = {"home.walk", "performance.jumping_jacks"}
        self.assertEqual(
            self.driver.choose_activity(["home.walk", "dining.walk"], available), "home.walk"
        )
        self.assertEqual(
            self.driver.choose_activity(["performance.jumping_jacks"], available),
            "performance.jumping_jacks",
        )
        self.assertIsNone(self.driver.choose_activity(["bunk.rest"], available))


class MotionTrackTests(unittest.TestCase):
    """`check_motion_track` must not let a static (idle) capture pass as motion."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def runner(self):
        return self.driver.RealAppE2E(argparse.Namespace(
            app=None, build=False, configuration="Release",
            root="/tmp/gmgn-t-motion", reuse_root=False, overwrite_root=False,
            prop_config=None, avatar_source=None, motion_source=None,
            asset_image="", prop_name="E2E", video_url="", timeout=1,
            generation_timeout=1, chat_timeout=1, skip_chat_turn=True,
        ))

    def frame(self, index: int, activity: str, x: float, grounding: dict,
              motion: dict | None = None) -> dict:
        return {
            "index": index,
            "sha256": f"sha-{index}",
            "avatarFrameRevision": 100 + index,
            "activeActivity": activity,
            "avatarGrounding": grounding,
            "residentPosition": [x, 0.0, 0.0],
            "avatarMotion": motion if motion is not None else self.motion(index),
        }

    def motion(self, index: int, clip: str = "gmgn.motion.bones.walk-loop-pmx",
               frozen: bool = False) -> dict:
        angle = 10.0 if frozen else 10.0 + index
        return {
            "clip": clip,
            "hasPlayer": True,
            "speed": 1.0,
            "sceneTime": index * 0.08,
            "renderedAvatarFrameCount": 1000 + index,
            "boneAnglesDegrees": {"左腕": angle, "右ひざ": 5.0 * (1 if frozen else index + 1)},
            "maximumBoneAngleDegrees": angle,
            "poseDigest": (15.0 if frozen else 15.0 + 6.0 * index),
            "restBoneCount": 6,
        }

    def good_grounding(self) -> dict:
        return {
            "minimumContactY": -0.2, "restGlobalReferenceY": 0.0,
            "groundingOffsetY": 0.2, "appliedGroundingOffsetY": 0.2,
            "contactLiftY": 0.2,
            "uncompensatedPenetrationY": 0.2,
        }

    def test_moving_walk_passes(self) -> None:
        runner = self.runner()
        frames = [
            self.frame(i, "home.walk", i * 0.1, self.good_grounding())
            for i in range(6)
        ]
        runner.check_motion_track("行走", "walk", "home.walk", frames)
        self.assertEqual(runner.ledger.failed, 0, runner.ledger.entries)

    def test_static_walk_fails_movement_check(self) -> None:
        runner = self.runner()
        frames = [
            self.frame(i, "home.walk", 0.0, self.good_grounding())
            for i in range(6)
        ]
        runner.check_motion_track("行走", "walk", "home.walk", frames)
        self.assertGreater(runner.ledger.failed, 0)

    def test_zeroed_offset_fails_per_frame_grounding(self) -> None:
        runner = self.runner()
        grounding = dict(self.good_grounding(), groundingOffsetY=0.0,
                         appliedGroundingOffsetY=0.0)
        frames = [self.frame(i, "home.walk", i * 0.1, grounding) for i in range(6)]
        runner.check_motion_track("行走", "walk", "home.walk", frames)
        self.assertGreater(runner.ledger.failed, 0)

    def test_activity_absent_fails(self) -> None:
        runner = self.runner()
        frames = [
            self.frame(i, "", i * 0.1, self.good_grounding()) for i in range(6)
        ]
        runner.check_motion_track("行走", "walk", "home.walk", frames)
        self.assertGreater(runner.ledger.failed, 0)

    def test_identical_frames_fail_motion_check(self) -> None:
        runner = self.runner()
        frames = [self.frame(0, "home.walk", 0.0, self.good_grounding())]
        runner.check_motion_track("行走", "walk", "home.walk", frames)
        self.assertGreater(runner.ledger.failed, 0)

    def test_missing_avatar_revision_is_diagnostic_only(self) -> None:
        # 资源 revision 已不再是动作验收指标：缺了它、只要真实骨骼姿态在变，就不该红。
        runner = self.runner()
        frames = [
            self.frame(i, "home.walk", i * 0.1, self.good_grounding())
            for i in range(6)
        ]
        for frame in frames:
            frame.pop("avatarFrameRevision")
        runner.check_motion_track("行走", "walk", "home.walk", frames)
        self.assertEqual(runner.ledger.failed, 0, runner.ledger.entries)

    def test_frozen_bone_pose_fails_even_with_live_camera_frames(self) -> None:
        # 旧的 `avatarFrameRevision` 在涨、GPU 帧号也在涨，但骨头一动不动 ⇒ 必须红。
        # 这条就是"禁止只换 GPU frameIndex / 资源 revision 冒充动作"的门禁。
        runner = self.runner()
        frames = [
            self.frame(i, "home.walk", i * 0.1, self.good_grounding(),
                       motion=self.motion(i, frozen=True))
            for i in range(6)
        ]
        runner.check_motion_track("行走", "walk", "home.walk", frames)
        self.assertGreater(runner.ledger.failed, 0)


class PoseSemanticsTests(unittest.TestCase):
    """2026-10-03 更正：站姿与坐姿必须**按已装载的 clip** 分开判。

    旧的"`activeActivity` 为空 ⇒ 站姿 ⇒ 脚必须贴地"把测试根默认选中的 `chair-sit`
    判成悬空缺陷。这里钉住：坐姿脚离地是允许的，站姿只认显式 idle clip。
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def runner(self):
        return make_runner(self.driver, motion_source=["/tmp/motions"],
                           stand_motion_id=self.driver.STAND_MOTION_ID,
                           sit_motion_id=self.driver.SIT_MOTION_ID)

    def status(self, clip: str, activity: str = "", grounding: dict | None = None,
               position: list | None = None) -> dict:
        return {
            "avatarFormat": "pmx",
            "avatarMotion": {"clip": clip},
            "activeActivity": activity,
            "residentPosition": position if position is not None else [0.0, 0.0, 0.0],
            "avatarGrounding": grounding if grounding is not None else self.grounding(),
        }

    def grounding(self, **overrides) -> dict:
        base = {
            "lowestSoleWorldY": 0.02,
            "lowestContactWorldY": 0.01,
            "restFootPlaneWorldY": 0.0,
            "leftSoleWorldY": 0.02,
            "rightSoleWorldY": 0.02,
            "pelvisWorldX": 0.05,
            "pelvisWorldY": 0.55,
            "pelvisWorldZ": -0.05,
        }
        base.update(overrides)
        return base

    def test_motion_role_classifies_sit_and_stand(self) -> None:
        driver = self.driver
        stand = driver.STAND_MOTION_ID
        sit = driver.SIT_MOTION_ID
        self.assertEqual(driver.motion_role(stand, stand, sit), "stand")
        self.assertEqual(driver.motion_role(sit, stand, sit), "sit")
        self.assertEqual(
            driver.motion_role("gmgn.motion.bones.cross-legged-loop-pmx", stand, sit), "sit")
        self.assertEqual(driver.motion_role("", stand, sit), "unknown")
        self.assertEqual(driver.motion_role("weird.clip", stand, sit), "unknown")

    def test_explicit_sit_accepts_sit_activity_without_clip(self) -> None:
        driver = self.driver
        self.assertTrue(driver.motion_is_explicit_sit(
            "", "chair.sit", driver.SIT_MOTION_ID))
        self.assertTrue(driver.motion_is_explicit_sit(
            driver.SIT_MOTION_ID, "", driver.SIT_MOTION_ID))
        self.assertFalse(driver.motion_is_explicit_sit(
            driver.STAND_MOTION_ID, "", driver.SIT_MOTION_ID))

    def test_stand_check_blocks_when_chair_sit_masquerades(self) -> None:
        # 复制包最后选中 chair-sit、activeActivity 为空 —— 不得当成站姿判贴地。
        runner = self.runner()
        runner.check_standing_feet(
            self.status(self.driver.SIT_MOTION_ID), "启动后显式站姿")
        self.assertEqual(runner.ledger.failed, 0)
        self.assertGreater(runner.ledger.blocked_count, 0)

    def test_explicit_stand_passes_with_feet_on_ground(self) -> None:
        runner = self.runner()
        runner.check_standing_feet(
            self.status(self.driver.STAND_MOTION_ID), "启动后显式站姿")
        self.assertEqual(runner.ledger.failed, 0, runner.ledger.entries)
        self.assertEqual(runner.ledger.blocked_count, 0)

    def test_explicit_stand_fails_when_feet_float(self) -> None:
        runner = self.runner()
        runner.check_standing_feet(
            self.status(self.driver.STAND_MOTION_ID,
                        grounding=self.grounding(lowestSoleWorldY=0.30,
                                                 lowestContactWorldY=0.29)),
            "启动后显式站姿")
        self.assertGreater(runner.ledger.failed, 0)

    def test_sit_allows_feet_off_ground_and_checks_support(self) -> None:
        # 脚离地 0.27 m 是坐姿本来的姿态：必须通过，不能当浮地缺陷。
        runner = self.runner()
        ok = runner.check_sit_support(
            "坐下", self.status(self.driver.SIT_MOTION_ID, activity="chair.sit",
                                grounding=self.grounding(lowestSoleWorldY=0.27,
                                                         lowestContactWorldY=0.09)),
            frames=None)
        self.assertTrue(ok)
        self.assertEqual(runner.ledger.failed, 0, runner.ledger.entries)

    def test_sit_fails_when_pelvis_below_feet(self) -> None:
        runner = self.runner()
        runner.check_sit_support(
            "坐下", self.status(self.driver.SIT_MOTION_ID, activity="chair.sit",
                                grounding=self.grounding(lowestSoleWorldY=0.27,
                                                         pelvisWorldY=0.10)),
            frames=None)
        self.assertGreater(runner.ledger.failed, 0)

    def test_sit_fails_when_body_clips_below_floor(self) -> None:
        runner = self.runner()
        runner.check_sit_support(
            "坐下", self.status(self.driver.SIT_MOTION_ID, activity="chair.sit",
                                grounding=self.grounding(lowestSoleWorldY=0.27,
                                                         lowestContactWorldY=-0.08)),
            frames=None)
        self.assertGreater(runner.ledger.failed, 0)

    def test_sit_fails_when_pelvis_leaves_seat(self) -> None:
        runner = self.runner()
        runner.check_sit_support(
            "坐下", self.status(self.driver.SIT_MOTION_ID, activity="chair.sit",
                                grounding=self.grounding(pelvisWorldX=2.0),
                                position=[0.0, 0.0, 0.0]),
            frames=None)
        self.assertGreater(runner.ledger.failed, 0)

    def test_sit_fails_when_pelvis_unstable_across_frames(self) -> None:
        runner = self.runner()
        frames = [
            {
                "avatarMotion": {"clip": self.driver.SIT_MOTION_ID},
                "activeActivity": "chair.sit",
                "avatarGrounding": self.grounding(pelvisWorldY=0.55 + index * 0.2),
            }
            for index in range(4)
        ]
        runner.check_sit_support(
            "坐下", self.status(self.driver.SIT_MOTION_ID, activity="chair.sit"),
            frames=frames)
        self.assertGreater(runner.ledger.failed, 0)

    def test_activate_motion_waits_until_renderer_loads_clip(self) -> None:
        runner = self.runner()
        target = self.driver.STAND_MOTION_ID
        runner.host = FakeHost(statuses=[
            {"avatarMotion": {"clip": self.driver.SIT_MOTION_ID}},
            {"avatarMotion": {"clip": target}},
        ])
        self.assertTrue(runner.activate_motion(target, timeout=5))
        self.assertEqual(runner.ledger.blocked_count, 0)

    def test_activate_motion_blocks_when_clip_never_loads(self) -> None:
        runner = self.runner()
        runner.host = FakeHost(statuses=[{"avatarMotion": {"clip": "other.clip"}}])
        self.assertFalse(
            runner.activate_motion(self.driver.STAND_MOTION_ID, timeout=0.3))
        self.assertGreater(runner.ledger.blocked_count, 0)

    def test_copy_prefers_explicit_stand_over_chair_sit(self) -> None:
        import tempfile
        temporary = Path(tempfile.mkdtemp(prefix="gmgn-t-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, temporary, ignore_errors=True)
        source = temporary / "source"
        for name in ("gmgn.motion.bones.chair-sit-loop-pmx",
                     "gmgn.motion.bones.idle-loop-pmx"):
            package = source / name
            package.mkdir(parents=True)
            (package / "manifest.json").write_text("{}", encoding="utf-8")
        (source / ".selection.json").write_text(
            json.dumps({"activeID": "gmgn.motion.bones.chair-sit-loop-pmx"}),
            encoding="utf-8")
        destination = temporary / "dest"
        self.driver.copy_package_source(
            source, destination,
            preferred_selection="gmgn.motion.bones.idle-loop-pmx")
        self.assertEqual(
            json.loads((destination / ".selection.json").read_text())["activeID"],
            "gmgn.motion.bones.idle-loop-pmx")

    def test_select_explicit_stand_writes_selection(self) -> None:
        import tempfile
        temporary = Path(tempfile.mkdtemp(prefix="gmgn-t-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, temporary, ignore_errors=True)
        runner = self.runner()
        motion_root = temporary / "MotionPackages"
        (motion_root / runner.stand_motion_id).mkdir(parents=True)
        runner.select_explicit_stand_motion(motion_root)
        self.assertEqual(
            json.loads((motion_root / ".selection.json").read_text())["activeID"],
            runner.stand_motion_id)
        self.assertEqual(runner.ledger.blocked_count, 0)

    def test_select_explicit_stand_blocks_when_package_missing(self) -> None:
        import tempfile
        temporary = Path(tempfile.mkdtemp(prefix="gmgn-t-", dir="/tmp"))
        self.addCleanup(shutil.rmtree, temporary, ignore_errors=True)
        runner = self.runner()
        motion_root = temporary / "MotionPackages"
        (motion_root / "gmgn.motion.bones.chair-sit-loop-pmx").mkdir(parents=True)
        runner.select_explicit_stand_motion(motion_root)
        self.assertGreater(runner.ledger.blocked_count, 0)
        # 缺站姿包时绝不写别的动作冒充站姿。
        self.assertFalse((motion_root / ".selection.json").exists())


class FakeHost:
    """Scripted stand-in for `AppHost` so polling logic can be tested without an app."""

    def __init__(self, statuses: list[dict] | None = None,
                 tool_responses: list[dict] | None = None) -> None:
        self.statuses = list(statuses or [])
        self.tool_responses = list(tool_responses or [])
        self.commands: list[tuple[str, dict]] = []

    def command(self, command: str, params: dict | None = None, timeout: float = 120) -> dict:
        self.commands.append((command, params or {}))
        if command == "status":
            if not self.statuses:
                return {"ok": True, "result": {}}
            status = self.statuses.pop(0) if len(self.statuses) > 1 else self.statuses[0]
            return {"ok": True, "result": status}
        if command == "tool_call":
            if not self.tool_responses:
                return {"ok": True, "result": {"isError": False, "ok": True, "result": {}}}
            response = self.tool_responses.pop(0) if len(self.tool_responses) > 1 else self.tool_responses[0]
            return response
        return {"ok": True, "result": {}}


def make_runner(driver, **overrides):
    defaults = dict(
        app=None, build=False, configuration="Release",
        root="/tmp/gmgn-t-claim", reuse_root=True, overwrite_root=False,
        prop_config=None, avatar_source=None, motion_source=None,
        asset_image="", prop_name="E2E", video_url="", timeout=1,
        generation_timeout=1, existing_wish_id=None,
    )
    defaults.update(overrides)
    return driver.RealAppE2E(argparse.Namespace(**defaults))


class DownloadCheckTests(unittest.TestCase):
    """`generated` (service done, download check pending) must never count as ready."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def test_generated_is_not_download_checked(self) -> None:
        self.assertFalse(self.driver.RealAppE2E.wish_download_checked(
            {"stage": "generated", "modelPath": "", "modelFileExists": False}))

    def test_generated_with_model_path_is_still_not_checked(self) -> None:
        self.assertFalse(self.driver.RealAppE2E.wish_download_checked(
            {"stage": "generated", "modelPath": "/tmp/x.glb", "modelFileExists": True}))

    def test_ready_without_local_model_is_not_checked(self) -> None:
        self.assertFalse(self.driver.RealAppE2E.wish_download_checked(
            {"stage": "ready", "modelPath": "", "modelFileExists": False}))

    def test_ready_with_missing_file_is_not_checked(self) -> None:
        self.assertFalse(self.driver.RealAppE2E.wish_download_checked(
            {"stage": "ready", "modelPath": "/tmp/x.glb", "modelFileExists": False}))

    def test_ready_with_existing_model_is_checked(self) -> None:
        self.assertTrue(self.driver.RealAppE2E.wish_download_checked(
            {"stage": "ready", "modelPath": "/tmp/x.glb", "modelFileExists": True}))

    def test_claimed_with_existing_model_is_checked(self) -> None:
        self.assertTrue(self.driver.RealAppE2E.wish_download_checked(
            {"stage": "claimed", "modelPath": "/tmp/x.glb", "modelFileExists": True}))

    def test_wait_wish_ready_skips_generated(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(statuses=[
            {"wishJobs": [{"id": "J", "stage": "generated", "modelPath": "",
                           "modelFileExists": False}]},
            {"wishJobs": [{"id": "J", "stage": "ready", "modelPath": "/tmp/x.glb",
                           "modelFileExists": True}]},
        ])
        job = runner.wait_wish_ready("J", timeout=5)
        self.assertIsNotNone(job)
        self.assertEqual(job["stage"], "ready")

    def test_wait_wish_ready_times_out_on_only_generated(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(statuses=[{"wishJobs": [
            {"id": "J", "stage": "generated", "modelPath": "", "modelFileExists": False}]}])
        self.assertIsNone(runner.wait_wish_ready("J", timeout=0.2))


class ExistingWishModeTests(unittest.TestCase):
    """`--existing-wish-id` is an explicit resume mode, never a fresh-generation pass."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def test_existing_mode_requires_reuse_root(self) -> None:
        runner = make_runner(self.driver, existing_wish_id="ABC", reuse_root=False)
        with self.assertRaises(SystemExit):
            runner.validate_mode()

    def test_existing_mode_rejects_overwrite_root(self) -> None:
        runner = make_runner(self.driver, existing_wish_id="ABC", reuse_root=True,
                             overwrite_root=True)
        with self.assertRaises(SystemExit):
            runner.validate_mode()

    def test_existing_mode_with_reuse_root_is_allowed(self) -> None:
        runner = make_runner(self.driver, existing_wish_id="ABC", reuse_root=True)
        runner.validate_mode()


class ClaimReadinessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def test_wait_tray_ready_requires_live_ready_status(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(statuses=[
            {"wishMachineOutputID": "P", "wishMachineOutputStatus": "loading"},
            {"wishMachineOutputID": "P", "wishMachineOutputStatus": "ready"},
        ])
        self.assertIsNotNone(runner.wait_tray_ready("P", timeout=5))

    def test_wait_tray_ready_rejects_wrong_object(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(statuses=[
            {"wishMachineOutputID": "OTHER", "wishMachineOutputStatus": "ready"}])
        self.assertIsNone(runner.wait_tray_ready("P", timeout=0.2))

    def test_wait_claim_ready_returns_last_named_error(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(statuses=[{"wishJobs": [
            {"id": "J", "claimReady": False, "claimError": "请先走到许愿机领取位置；托盘实际显示物品后才能领取。"}]}])
        ready, error = runner.wait_claim_ready("J", timeout=0.2)
        self.assertIsNone(ready)
        self.assertIn("许愿机", error)

    def test_wait_claim_ready_accepts_released_gate(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(statuses=[{"wishJobs": [
            {"id": "J", "claimReady": True, "claimError": ""}]}])
        ready, error = runner.wait_claim_ready("J", timeout=5)
        self.assertIsNotNone(ready)
        self.assertEqual(error, "")

    def test_wait_owned_prop_needs_object_in_objects(self) -> None:
        runner = make_runner(self.driver)
        owned = {"ok": True, "result": {"isError": False, "ok": True, "result": {
            "objects": [{"object_id": "P"}]}}}
        runner.host = FakeHost(tool_responses=[
            {"ok": True, "result": {"isError": False, "ok": True, "result": {"objects": []}}},
            owned,
        ])
        self.assertIsNotNone(runner.wait_owned_prop("P", timeout=5))

    def test_wait_owned_prop_empty_list_is_not_success(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(tool_responses=[
            {"ok": True, "result": {"isError": False, "ok": True, "result": {"objects": []}}}])
        self.assertIsNone(runner.wait_owned_prop("P", timeout=0.2))

    def test_wait_placement_surfaces_empty_is_not_success(self) -> None:
        runner = make_runner(self.driver)
        empty = {"ok": True, "result": {"isError": False, "ok": True, "result": {"surfaces": []}}}
        runner.host = FakeHost(tool_responses=[empty])
        self.assertEqual(runner.wait_placement_surfaces(timeout=0.2), [])


class PlacementSearchTests(unittest.TestCase):
    """摆放选点必须走生产预检：只有判据放行的格心才会被 apply，绝不退回固定格心。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    @staticmethod
    def surface(sid: str, x: float, z: float) -> dict:
        return {"id": sid, "support_height": -0.08, "center": [x, -0.08, z]}

    def reject(self, code: str = "placement_rejected") -> dict:
        return {"ok": True, "result": {"isError": True, "ok": False,
                                       "result": {"code": code, "ok": False}}}

    def accept(self) -> dict:
        return {"ok": True, "result": {"isError": False, "ok": True, "result": {"ok": True}}}

    def test_rejected_first_cell_is_skipped_for_a_placeable_one(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(tool_responses=[self.reject(), self.accept()])
        surfaces = [self.surface("layer.0", 0.0, 0.0), self.surface("layer.1", 1.0, 0.0)]
        placement, surface, reason = runner.find_placeable_placement("P", surfaces, 7)
        self.assertIsNotNone(placement, reason)
        self.assertEqual(placement["layout_revision"], 7)
        self.assertEqual(placement["object_id"], "P")
        self.assertIn(surface["id"], ("layer.0", "layer.1"))
        # 第二个候选才通过 ⇒ 第一次拒绝真的被跳过，而不是硬提交。
        self.assertEqual(len(runner.host.commands), 2)

    def test_all_candidates_rejected_returns_named_failure(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost(tool_responses=[self.reject("blocked_by_mesh")])
        surfaces = [self.surface("layer.0", 0.0, 0.0), self.surface("layer.1", 1.0, 0.0)]
        placement, surface, reason = runner.find_placeable_placement("P", surfaces, 7)
        self.assertIsNone(placement)
        self.assertIsNone(surface)
        self.assertIn("blocked_by_mesh", reason)

    def test_no_cell_center_is_named_failure(self) -> None:
        runner = make_runner(self.driver)
        runner.host = FakeHost()
        placement, surface, reason = runner.find_placeable_placement("P", [{"id": "x"}], 1)
        self.assertIsNone(placement)
        self.assertIn("格心", reason)


class HelperTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def test_extract_surfaces_reads_layers(self) -> None:
        response = {"ok": True, "result": {"isError": False, "result": {
            "surfaces": [{"id": "layer.0", "support_height": 0.0}]}}}
        self.assertEqual(len(self.driver.extract_surfaces(response)), 1)

    def test_extract_surfaces_empty_on_missing(self) -> None:
        self.assertEqual(self.driver.extract_surfaces({"ok": True, "result": {}}), [])

    def test_same_id_is_case_insensitive(self) -> None:
        self.assertTrue(self.driver.same_id("474AC5DE-3A7D", "474ac5de-3a7d"))
        self.assertFalse(self.driver.same_id("A", "B"))
        self.assertFalse(self.driver.same_id(None, "B"))


class ResidentFailureForTurnTests(unittest.TestCase):
    """失败轮次的内部失败因必须能被 chat 账本按轮取回，哪怕已被后续轮次覆盖。"""

    @classmethod
    def setUpClass(cls) -> None:
        cls.driver = load_driver()

    def test_prefers_latest_resident_failure(self) -> None:
        conversation = {
            "lastResidentFailure": {"stage": "wait", "code": "unauthorized"},
            "recentResidentFailures": [],
        }
        self.assertEqual(
            self.driver.RealAppE2E.resident_failure_for_turn(conversation, {})["code"],
            "unauthorized",
        )

    def test_falls_back_to_history_when_last_is_cleared(self) -> None:
        turn = {"createdAt": 100.0}
        conversation = {
            "lastResidentFailure": {},
            "recentResidentFailures": [
                {"stage": "config", "code": "old", "at": 50.0},
                {"stage": "wait", "code": "turnFailed", "at": 101.0},
            ],
        }
        failure = self.driver.RealAppE2E.resident_failure_for_turn(conversation, turn)
        self.assertEqual(failure["code"], "turnFailed")

    def test_history_without_timestamp_uses_last_record(self) -> None:
        conversation = {
            "lastResidentFailure": {},
            "recentResidentFailures": [{"code": "a"}, {"code": "b"}],
        }
        failure = self.driver.RealAppE2E.resident_failure_for_turn(
            conversation, {"createdAt": 10.0})
        self.assertEqual(failure["code"], "b")

    def test_empty_conversation_returns_empty(self) -> None:
        self.assertEqual(
            self.driver.RealAppE2E.resident_failure_for_turn({}, {"createdAt": 1.0}), {})


if __name__ == "__main__":
    unittest.main()
