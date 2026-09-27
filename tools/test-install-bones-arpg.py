#!/usr/bin/env python3
"""Exercise the offline installer and real MotionPackageStore in temporary directories.

Usage: python3 tools/test-install-bones-arpg.py --fixture-catalog /abs/catalog.json
The fixture must contain actual BONES VMD and VRMA files; nothing is installed live.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().with_name("install-bones-resident.swift")
FIXTURE = None


class BonesInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="gmgn-bones-installer-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.destination = self.root / "MotionPackages"
        self.destination.mkdir()
        self.selection = self.destination / ".selection.json"
        self.selection.write_bytes(b'{"version":3,"activeID":"keep-this-choice"}\n')
        self.selection_before = self.selection.read_bytes()
        self.catalog_path = self.root / "catalog.json"
        self.manifest_path = self.root / "bones-arpg.json"
        self.manifest = {"schemaVersion": 1, "motions": [{
            "key": "attack-test", "displayName": "Test attack", "category": "attack",
            "filename": "fixture.npz", "sourceCategory": "test", "activityIDs": []}]}
        fixture = json.loads(FIXTURE.read_text())
        self.catalog = {"schemaVersion": 1, "motions": []}
        for format_name, suffix in [("vmd", "pmx"), ("vrma", "vrm")]:
            entry = copy.deepcopy(next(e for e in fixture["motions"] if e["format"] == format_name))
            self.assertEqual(entry["source"]["generator"]["engine"], "bones-seed")
            data_path = FIXTURE.parent / entry["path"]
            self.assertEqual(hashlib.sha256(data_path.read_bytes()).hexdigest(), entry["sha256"])
            target = self.root / f"fixture.{format_name}"
            shutil.copyfile(data_path, target)
            entry.update(id=f"gmgn.motion.bones.arpg.attack-test-{suffix}",
                         path=target.name, loop=False, inPlace=False)
            self.catalog["motions"].append(entry)

    def invoke(self, arpg=True):
        self.catalog_path.write_text(json.dumps(self.catalog))
        self.manifest_path.write_text(json.dumps(self.manifest))
        args = ["/usr/bin/swift", str(INSTALLER), "--catalog", str(self.catalog_path),
                "--destination", str(self.destination)]
        if arpg:
            args += ["--manifest", str(self.manifest_path)]
        result = subprocess.run(args, capture_output=True, text=True, timeout=120)
        self.assertEqual(self.selection.read_bytes(), self.selection_before)
        return result

    def assert_refused(self, message, arpg=True):
        before = {str(p.relative_to(self.destination)): p.read_bytes()
                  for p in self.destination.rglob("*") if p.is_file()}
        result = self.invoke(arpg)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        after = {str(p.relative_to(self.destination)): p.read_bytes()
                 for p in self.destination.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_one_shot_pair_installs_and_repeats_without_replacement(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BONES verified: 2; installed: 2", result.stdout)
        before = {}
        for entry in self.catalog["motions"]:
            package = self.destination / entry["id"]
            manifest = json.loads((package / "manifest.json").read_text())
            self.assertFalse(manifest["loop"])
            self.assertFalse(manifest["inPlace"])
            asset = package / f'{entry["id"]}.{entry["format"]}'
            self.assertEqual(hashlib.sha256(asset.read_bytes()).hexdigest(), entry["sha256"])
            before[entry["id"]] = (asset.stat().st_ino, asset.stat().st_mtime_ns)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("installed: 0; already present: 2", result.stdout)
        for entry in self.catalog["motions"]:
            asset = self.destination / entry["id"] / f'{entry["id"]}.{entry["format"]}'
            self.assertEqual(before[entry["id"]], (asset.stat().st_ino, asset.stat().st_mtime_ns))
        self.catalog["motions"][0]["version"] = "99.0.0"
        self.assert_refused("Existing package differs")

    def test_exact_manifest_pair_required(self):
        self.catalog["motions"].pop()
        self.assert_refused("exactly the manifest ARPG motion IDs")

    def test_arpg_requires_one_shot_full_root_and_normal_speed(self):
        original = copy.deepcopy(self.catalog["motions"][1])
        for field, value in [("loop", True), ("inPlace", True), ("inPlace", None),
                             ("playbackRate", 2)]:
            with self.subTest(field=field, value=value):
                self.destination = self.root / f"{field}-{value}" / "MotionPackages"
                self.destination.mkdir(parents=True)
                self.selection = self.destination / ".selection.json"
                self.selection.write_bytes(self.selection_before)
                self.catalog["motions"][1] = {**original, field: value}
                self.assert_refused("Invalid BONES ARPG playback settings")

    def test_arpg_accepts_default_playback_rate(self):
        for entry in self.catalog["motions"]:
            entry.pop("playbackRate", None)
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BONES verified: 2; installed: 2", result.stdout)

    def test_arpg_refuses_existing_package_with_different_playback_settings(self):
        result = self.invoke()
        self.assertEqual(result.returncode, 0, result.stderr)
        entry = self.catalog["motions"][0]
        path = self.destination / entry["id"] / "manifest.json"
        original = json.loads(path.read_text())
        for field, value in [("inPlace", True), ("inPlace", None), ("playbackRate", 2)]:
            with self.subTest(field=field, value=value):
                path.write_text(json.dumps({**original, field: value}))
                self.assert_refused("Existing package differs")

    def test_duplicate_catalog_id_rejected(self):
        self.catalog["motions"][1] = copy.deepcopy(self.catalog["motions"][0])
        self.assert_refused("exactly the manifest ARPG motion IDs")

    def test_foreign_id_rejected(self):
        self.catalog["motions"][0]["id"] = "gmgn.motion.bones.foreign-pmx"
        self.assert_refused("exactly the manifest ARPG motion IDs")

    def test_invalid_manifest_rejected(self):
        for motions in [[], self.manifest["motions"] * 2, [{"key": "../escape"}]]:
            with self.subTest(motions=motions):
                self.manifest["motions"] = motions
                self.assert_refused("Invalid BONES ARPG manifest")

    def test_invalid_manifest_schema_rejected(self):
        self.manifest["schemaVersion"] = 2
        self.assert_refused("Invalid BONES ARPG manifest")

    def test_provenance_rejected_before_installation(self):
        self.catalog["motions"][1]["source"]["generator"]["engine"] = "other"
        self.assert_refused("Non-BONES or missing source digest")
        self.catalog["motions"][1]["source"]["generator"]["engine"] = "bones-seed"
        self.catalog["motions"][1]["source"]["generator"]["sourceSHA256"] = "invalid"
        self.assert_refused("Non-BONES or missing source digest")

    def test_hash_and_bytes_rejected_before_installation(self):
        self.catalog["motions"][1]["sha256"] = "0" * 64
        self.assert_refused("BONES source bytes/hash mismatch")
        self.catalog["motions"][1]["sha256"] = hashlib.sha256((self.root / "fixture.vrma").read_bytes()).hexdigest()
        self.catalog["motions"][1]["bytes"] += 1
        self.assert_refused("BONES source bytes/hash mismatch")

    def test_unsafe_path_and_wrong_format_rejected(self):
        entry = self.catalog["motions"][1]
        entry["path"] = "../fixture.vrma"
        self.assert_refused("Invalid BONES source path, format, or loop")
        entry["path"] = "fixture.vrma"
        entry["format"] = "vmd"
        self.assert_refused("Invalid BONES source path, format, or loop")

    def test_symlink_source_rejected(self):
        (self.root / "linked.vrma").symlink_to(self.root / "fixture.vrma")
        self.catalog["motions"][1]["path"] = "linked.vrma"
        self.assert_refused("BONES source bytes/hash mismatch")

    def test_legacy_mode_rejects_arpg(self):
        self.assert_refused("exactly the eight permitted resident motion IDs", arpg=False)

    def test_legacy_mode_still_requires_eight_loops(self):
        pair = self.catalog["motions"]
        self.catalog["motions"] = []
        for role in ["thinking-loop", "idle-loop", "hold-display", "jumping-jacks"]:
            for original, suffix in zip(pair, ["pmx", "vrm"]):
                entry = copy.deepcopy(original)
                entry.update(id=f"gmgn.motion.bones.{role}-{suffix}", loop=True)
                self.catalog["motions"].append(entry)
        self.catalog["motions"][-1]["loop"] = False
        self.assert_refused("Invalid BONES source path, format, or loop", arpg=False)
        self.catalog["motions"][-1]["loop"] = True
        result = self.invoke(arpg=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("BONES verified: 8; installed: 8", result.stdout)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture-catalog", required=True, type=Path)
    args, remaining = parser.parse_known_args()
    FIXTURE = args.fixture_catalog.resolve(strict=True)
    unittest.main(argv=[__file__, *remaining])
