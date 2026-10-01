#!/usr/bin/env python3
"""Unit tests for tools/world-migration/world_state_migration.py.

Run::

    python3 -m unittest discover -s tools/world-migration/tests -v

Every test builds a throwaway tree under the system temp directory. The live
Application Support tree is never touched.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL_DIR = os.path.dirname(HERE)
sys.path.insert(0, TOOL_DIR)

import world_state_migration as migration  # noqa: E402


def world_document(world_id, revision=10, objects=1, layout_revision=2):
    document = {
        "agentTransform": {
            "position": {"x": 0.5, "y": 0.1, "z": -1.25},
            "rotation": {"w": 1, "x": 0, "y": 0, "z": 0},
            "scale": {"x": 1, "y": 1, "z": 1},
        },
        "completedGoals": {},
        "lastObservedWallTime": 1700000000000.5,
        "layoutRevision": layout_revision,
        "revision": revision,
        "weather": "clear",
        "worldID": world_id,
        "worldTime": 1700000001000.25,
        "objectStates": {},
    }
    if objects:
        document["objectStates"]["wish-prop-1"] = {
            "isEnabled": True,
            "metadata": {
                # deliberately *not* key-sorted: key order inside the blob is not
                # semantics and must not decide equivalence
                "gmgn.generated-prop.v1": json.dumps({
                    "objectID": "wish-prop-1", "displayName": "斧头",
                    "sourceWishID": "W1", "assetID": "sha256:aa", "sourceHeight": 0.79,
                    "size": {"x": 0.88, "y": 0.7, "z": 0.086},
                }, sort_keys=False, ensure_ascii=False),
                "gmgn.support-surface.v1": "grid.layerPropSupportLayer(layer: 0)",
            },
            "transform": {
                "position": {"x": -2.6, "y": -0.05, "z": -2.3},
                "rotation": {"w": 0.7071, "x": 0, "y": 0.7071, "z": 0},
                "scale": {"x": 0.88, "y": 0.88, "z": 0.88},
            },
        }
    document["layoutReceipts"] = {
        "R1": {"place": {"objectID": "wish-prop-1",
                         "placement": {"position": {"x": 0, "y": 0, "z": 0},
                                       "surfaceID": "resident.display_table", "yaw": 0}}}
    }
    return document


class Fixture(object):
    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="gmgn-world-migration-test-")
        self.living_world = os.path.join(self.root, "LivingWorld")
        self.worlds_root = os.path.join(self.root, "Worlds")
        os.makedirs(self.living_world)
        os.makedirs(self.worlds_root)

    def write_manifest(self, package_id, version, world_id):
        directory = os.path.join(self.worlds_root, package_id)
        os.makedirs(directory, exist_ok=True)
        with open(os.path.join(directory, "world.json"), "w") as handle:
            json.dump({"packageID": package_id, "packageVersion": version,
                       "worldID": world_id}, handle)

    def write_state(self, package_id, version, document):
        parts = [self.living_world, package_id]
        if version is not None:
            parts.append(version)
        directory = os.path.join(*parts)
        os.makedirs(directory, exist_ok=True)
        path = os.path.join(directory, "state.json")
        with open(path, "w") as handle:
            json.dump(document, handle, sort_keys=True, indent=2)
        return path

    def cleanup(self):
        shutil.rmtree(self.root, ignore_errors=True)


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)
        self.fixture.write_manifest("marble", "1.2.0", "W-marble")
        self.current = self.fixture.write_state("marble", "1.2.0",
                                                world_document("W-marble"))
        self.historical = self.fixture.write_state("marble", "1.1.0",
                                                   world_document("W-marble", revision=5, objects=0))
        self.legacy = self.fixture.write_state("warm", None, world_document("W-warm", objects=0))
        self.out = os.path.join(self.fixture.root, "bundle")

    def export(self, stamp="20261002T000000Z"):
        code = migration.main([
            "export", "--living-world-root", self.fixture.living_world,
            "--worlds-root", self.fixture.worlds_root, "--out", self.out,
            "--stamp", stamp, "--repo-root", self.fixture.root,
        ])
        self.assertEqual(code, 0)
        return json.load(open(os.path.join(self.out, "manifest.json")))

    def test_manifest_records_sha256_and_current_file(self):
        manifest = self.export()
        self.assertEqual(manifest["kind"], "gmgn-living-world-state-export")
        self.assertEqual(len(manifest["files"]), 3)
        world = next(item for item in manifest["worlds"] if item["worldID"] == "W-marble")
        self.assertEqual(world["current"], "state/marble/1.2.0/state.json")
        self.assertEqual(world["historical"], ["state/marble/1.1.0/state.json"])
        entry = next(item for item in manifest["files"] if item["bundlePath"] == world["current"])
        self.assertEqual(entry["sha256"], migration.sha256_file(self.current))
        self.assertEqual(entry["bytes"], os.path.getsize(self.current))
        self.assertTrue(entry["isCurrent"])

    def test_export_bytes_are_identical_and_source_untouched(self):
        before = migration.sha256_file(self.current)
        stat_before = os.stat(self.current)
        self.export()
        copied = os.path.join(self.out, "state/marble/1.2.0/state.json")
        self.assertEqual(migration.sha256_file(copied), before)
        stat_after = os.stat(self.current)
        self.assertEqual(stat_before.st_mtime_ns, stat_after.st_mtime_ns)
        self.assertEqual(stat_before.st_size, stat_after.st_size)

    def test_export_is_deterministic_in_content(self):
        first = self.export("20261002T000000Z")
        second_dir = os.path.join(self.fixture.root, "bundle2")
        code = migration.main([
            "export", "--living-world-root", self.fixture.living_world,
            "--worlds-root", self.fixture.worlds_root, "--out", second_dir,
            "--stamp", "20261002T010000Z", "--repo-root", self.fixture.root,
        ])
        self.assertEqual(code, 0)
        second = json.load(open(os.path.join(second_dir, "manifest.json")))
        self.assertEqual(first["bundleSha256"], second["bundleSha256"])

    def test_rollback_script_and_readme_exist(self):
        self.export()
        script = os.path.join(self.out, "rollback.sh")
        self.assertTrue(os.path.exists(script))
        self.assertTrue(os.access(script, os.X_OK))
        text = open(script).read()
        self.assertIn("--confirm", text)
        readme = open(os.path.join(self.out, "README.md")).read()
        self.assertIn("Rollback", readme)

    def test_export_refuses_to_overwrite_a_non_empty_bundle(self):
        self.export()
        code = migration.main([
            "export", "--living-world-root", self.fixture.living_world,
            "--worlds-root", self.fixture.worlds_root, "--out", self.out,
            "--stamp", "20261002T000000Z", "--repo-root", self.fixture.root,
        ])
        self.assertEqual(code, 2)

    def test_legacy_file_is_used_when_it_is_the_only_one(self):
        manifest = self.export()
        world = next(item for item in manifest["worlds"] if item["worldID"] == "W-warm")
        self.assertEqual(world["current"], "state/warm/unversioned/state.json")
        self.assertEqual(world["historical"], [])


class CanonicalizeTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)
        self.fixture.write_manifest("marble", "1.2.0", "W-marble")
        self.fixture.write_state("marble", "1.2.0", world_document("W-marble"))
        self.fixture.write_state("marble", "1.1.0", world_document("W-marble", revision=5, objects=0))
        self.out = os.path.join(self.fixture.root, "bundle")
        migration.main(["export", "--living-world-root", self.fixture.living_world,
                        "--worlds-root", self.fixture.worlds_root, "--out", self.out,
                        "--stamp", "20261002T000000Z", "--repo-root", self.fixture.root])
        self.payload_path = os.path.join(self.out, "worlds.json")
        code = migration.main(["canonicalize", "--bundle", self.out, "--out", self.payload_path])
        self.assertEqual(code, 0)

    def test_payload_has_only_the_current_file_per_world(self):
        payload = json.load(open(self.payload_path))
        self.assertEqual(len(payload["worlds"]), 1)
        world = payload["worlds"][0]
        self.assertEqual(world["worldID"], "W-marble")
        self.assertEqual(world["packageVersion"], "1.2.0")
        document = json.loads(world["stateJson"])
        self.assertEqual(document["revision"], 10)
        self.assertEqual(len(document["objectStates"]), 1)
        # the payload's hash is the raw pre-image bytes, so Rust can verify them
        self.assertEqual(world["stateSha256"],
                         migration.sha256_file(os.path.join(self.out, world["stateFile"])))

    def test_canonicalize_is_idempotent(self):
        first = open(self.payload_path).read()
        migration.main(["canonicalize", "--bundle", self.out, "--out", self.payload_path])
        self.assertEqual(first, open(self.payload_path).read())


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()
        self.addCleanup(self.fixture.cleanup)
        self.fixture.write_manifest("marble", "1.2.0", "W-marble")
        self.source = world_document("W-marble")
        self.fixture.write_state("marble", "1.2.0", self.source)
        self.out = os.path.join(self.fixture.root, "bundle")
        migration.main(["export", "--living-world-root", self.fixture.living_world,
                        "--worlds-root", self.fixture.worlds_root, "--out", self.out,
                        "--stamp", "20261002T000000Z", "--repo-root", self.fixture.root])
        self.snapshot = os.path.join(self.fixture.root, "snapshot.json")

    def write_snapshot(self, state, world_id="W-marble", record_revision=1, boundary_seq=1):
        with open(self.snapshot, "w") as handle:
            json.dump({"worlds": [{"worldID": world_id, "recordRevision": record_revision,
                                   "boundarySeq": boundary_seq, "state": state}]}, handle)

    def compare(self):
        return migration.main(["compare", "--bundle", self.out, "--snapshot", self.snapshot,
                               "--expect", "1"])

    def test_identical_state_passes(self):
        self.write_snapshot(json.loads(json.dumps(self.source)))
        self.assertEqual(self.compare(), 0)

    def test_key_order_inside_metadata_blob_is_normalized(self):
        state = json.loads(json.dumps(self.source))
        blob = state["objectStates"]["wish-prop-1"]["metadata"]["gmgn.generated-prop.v1"]
        state["objectStates"]["wish-prop-1"]["metadata"]["gmgn.generated-prop.v1"] = json.dumps(
            json.loads(blob), sort_keys=True)
        self.assertNotEqual(
            blob,
            state["objectStates"]["wish-prop-1"]["metadata"]["gmgn.generated-prop.v1"])
        self.write_snapshot(state)
        self.assertEqual(self.compare(), 0)
        self.assertEqual(migration.projection_sha256(self.source),
                         migration.projection_sha256(state))

    def test_changed_size_fails_with_path(self):
        state = json.loads(json.dumps(self.source))
        blob = json.loads(state["objectStates"]["wish-prop-1"]["metadata"]["gmgn.generated-prop.v1"])
        blob["size"]["x"] = 0.99
        state["objectStates"]["wish-prop-1"]["metadata"]["gmgn.generated-prop.v1"] = json.dumps(blob)
        self.write_snapshot(state)
        self.assertEqual(self.compare(), 1)

    def test_changed_transform_fails(self):
        state = json.loads(json.dumps(self.source))
        state["objectStates"]["wish-prop-1"]["transform"]["position"]["y"] = 0.52
        self.write_snapshot(state)
        self.assertEqual(self.compare(), 1)

    def test_changed_layout_revision_fails(self):
        state = json.loads(json.dumps(self.source))
        state["layoutRevision"] = 3
        self.write_snapshot(state)
        self.assertEqual(self.compare(), 1)

    def test_missing_object_fails(self):
        state = json.loads(json.dumps(self.source))
        state["objectStates"] = {}
        self.write_snapshot(state)
        self.assertEqual(self.compare(), 1)

    def test_missing_world_fails(self):
        self.write_snapshot(json.loads(json.dumps(self.source)), world_id="W-other")
        self.assertEqual(self.compare(), 1)

    def test_disabled_flag_difference_fails(self):
        state = json.loads(json.dumps(self.source))
        state["objectStates"]["wish-prop-1"]["isEnabled"] = False
        self.write_snapshot(state)
        self.assertEqual(self.compare(), 1)


class VersionGroupingTests(unittest.TestCase):
    def test_worlds_without_a_bundled_manifest_use_the_highest_version(self):
        fixture = Fixture()
        self.addCleanup(fixture.cleanup)
        fixture.write_state("mystery", "1.9.0", world_document("W-mystery", revision=1, objects=0))
        fixture.write_state("mystery", "1.10.0", world_document("W-mystery", revision=2, objects=0))
        files = migration.discover_state_files(fixture.living_world)
        entries, by_world = migration.plan_imports(files, {})
        current = next(entry for entry in by_world["W-mystery"] if entry["isCurrent"])
        # numeric version ordering: "1.10.0" is newer than "1.9.0" even though
        # it sorts earlier as a string
        self.assertEqual(current["packageVersion"], "1.10.0")
        self.assertEqual(current["revision"], 2)


if __name__ == "__main__":
    unittest.main()
