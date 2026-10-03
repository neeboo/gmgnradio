import importlib.util
import json
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("world_backup.py")
spec = importlib.util.spec_from_file_location("world_backup", SCRIPT)
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


class WorldBackupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.assets = self.source / "WorldPackage"
        self.assets.mkdir()
        (self.assets / "scene.spz").write_bytes(b"fixture-spz-original-bytes")
        (self.assets / "world.json").write_text('{"packageVersion":"1"}')
        self.blob = self.source / "prop.glb"
        self.blob.write_bytes(b"fixture-glb-original-bytes")
        self.db = self.source / "tasks.sqlite3"
        conn = sqlite3.connect(self.db)
        conn.executescript("""
          CREATE TABLE world_records(world_id TEXT,domain TEXT,key TEXT,revision INTEGER,updated_at_ms INTEGER,updated_by TEXT,tombstone INTEGER,hash TEXT,value TEXT);
          CREATE TABLE world_imports(world_id TEXT,source_hash TEXT,package_id TEXT,package_version TEXT,revision INTEGER);
          CREATE TABLE world_blobs(sha256 TEXT,bytes INTEGER,mime TEXT,local_path TEXT,remote_key TEXT);
          CREATE TABLE credentials(secret TEXT);
          INSERT INTO credentials VALUES('NEVER_EXPORT_THIS_CREDENTIAL');
        """)
        self.value = {"position": [1, 2, 3], "asset": str(self.blob), "scene": str(self.assets / "scene.spz")}
        for domain in ("worlds", "objects", "resident-state"):
            conn.execute("INSERT INTO world_records VALUES(?,?,?,?,?,?,?,?,?)", ("home", domain, "test", 3, 10, "fixture", 0, "opaque-authority-hash", json.dumps(self.value)))
        conn.execute("INSERT INTO world_imports VALUES(?,?,?,?,?)", ("home", "sourcehash", "package", "1", 3))
        conn.execute("INSERT INTO world_blobs VALUES(?,?,?,?,?)", (backup.digest(self.blob), self.blob.stat().st_size, "model/gltf-binary", str(self.blob), "secret-remote-key"))
        conn.commit()
        conn.close()
        self.bundle = self.root / "bundle"

    def tearDown(self):
        self.temp.cleanup()

    def make(self):
        return backup.backup(self.db, self.bundle, [f"world={self.assets}"])

    def cli(self, *args):
        return subprocess.run([sys.executable, str(SCRIPT), *map(str, args)], capture_output=True, text=True)

    def test_real_cli_roundtrip_after_source_deleted_and_new_root(self):
        result = self.cli("backup", "--database", self.db, "--out", self.bundle, "--asset-root", f"world={self.assets}")
        self.assertEqual(result.returncode, 0, result.stderr)
        original = backup.load(self.bundle / "worlds.json")
        expected = {item["path"]: item["sha256"] for item in backup.verify(self.bundle)["files"]}
        shutil.rmtree(self.source)  # Only test-owned fixture; old paths disappear.
        relocated = self.root / "another-machine"
        relocated.mkdir()
        recovered = relocated / "recovered-world"
        result = self.cli("recover", "--bundle", self.bundle, "--out", recovered)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(backup.load(recovered / "worlds.json"), original)
        self.assertEqual(len(original["records"]), 3)
        self.assertEqual(original["records"][0]["value"], self.value)
        for path, sha in expected.items():
            self.assertEqual(backup.digest(recovered / path), sha)
        for old_path, portable in original["referenceBindings"].items():
            self.assertFalse(Path(old_path).exists())
            self.assertTrue((recovered / portable).is_file())
        all_bytes = b"".join(p.read_bytes() for p in backup.files(recovered))
        self.assertNotIn(b"NEVER_EXPORT_THIS_CREDENTIAL", all_bytes)
        self.assertNotIn(b"secret-remote-key", all_bytes)
        self.assertFalse(any(p.suffix == ".sqlite3" for p in backup.files(recovered)))

    def test_corruption_rejected_before_destination_created(self):
        self.make()
        (self.bundle / "assets/world/scene.spz").write_bytes(b"corrupted")
        out = self.root / "recover"
        with self.assertRaises(ValueError):
            backup.recover(self.bundle, out)
        self.assertFalse(out.exists())

    def test_missing_payload_rejected(self):
        self.make()
        (self.bundle / "assets/world/scene.spz").unlink()
        self.assertNotEqual(self.cli("verify", "--bundle", self.bundle).returncode, 0)

    def test_manifest_traversal_rejected(self):
        self.make()
        manifest = backup.load(self.bundle / "manifest.json")
        for malicious in ("../outside", "/absolute", "assets/../outside", "C:/windows", "assets\\escape"):
            manifest["files"][0]["path"] = malicious
            backup.dump(self.bundle / "manifest.json", manifest)
            with self.assertRaises(ValueError):
                backup.verify(self.bundle)

    def test_symlink_asset_rejected(self):
        (self.assets / "escape.glb").symlink_to(self.blob)
        with self.assertRaises(ValueError):
            self.make()
        self.assertFalse(self.bundle.exists())

    def test_symlink_bundle_rejected(self):
        self.make()
        payload = self.bundle / "assets/world/scene.spz"
        payload.unlink()
        payload.symlink_to(self.blob)
        with self.assertRaises(ValueError):
            backup.verify(self.bundle)

    def test_missing_blob_and_uncovered_path_fail(self):
        self.blob.unlink()
        with self.assertRaises(ValueError):
            self.make()
        self.assertFalse(self.bundle.exists())

    def test_uncovered_metadata_path_fail(self):
        with self.assertRaises(ValueError):
            backup.backup(self.db, self.bundle)

    def test_sensitive_asset_rejected(self):
        for name in (".env", "private.pem", "private.key"):
            file = self.assets / name
            file.write_text("secret")
            with self.assertRaises(ValueError):
                self.make()
            file.unlink()

    def test_broad_root_and_existing_destination_rejected(self):
        with self.assertRaises(ValueError):
            backup.backup(self.db, self.bundle, [f"bad={Path.home()}"])
        self.make()
        with self.assertRaises(ValueError):
            self.make()
        with self.assertRaises(ValueError):
            backup.recover(self.bundle, self.source)

    def test_unlisted_payload_rejected(self):
        self.make()
        (self.bundle / "unexpected.txt").write_text("surprise")
        with self.assertRaises(ValueError):
            backup.verify(self.bundle)

    def test_unsupported_version_rejected(self):
        self.make()
        manifest = backup.load(self.bundle / "manifest.json")
        manifest["formatVersion"] = 999
        backup.dump(self.bundle / "manifest.json", manifest)
        with self.assertRaises(ValueError):
            backup.verify(self.bundle)

    def test_malformed_manifest_returns_json_error(self):
        self.make()
        backup.dump(self.bundle / "manifest.json", [])
        result = self.cli("verify", "--bundle", self.bundle)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stderr)["ok"])
        self.assertNotIn("Traceback", result.stderr)

    def test_committed_wal_records_included_without_writing_source(self):
        conn = sqlite3.connect(self.db)
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("UPDATE world_records SET revision=4")
        conn.commit()
        self.make()
        self.assertTrue(all(r["revision"] == 4 for r in backup.load(self.bundle / "worlds.json")["records"]))
        self.assertEqual(conn.execute("SELECT COUNT(*) FROM credentials").fetchone()[0], 1)
        self.assertTrue(all(row[0] == 4 for row in conn.execute("SELECT revision FROM world_records")))
        conn.close()


if __name__ == "__main__":
    unittest.main()
