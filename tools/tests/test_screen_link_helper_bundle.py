#!/usr/bin/env python3
"""Gates for the screen-link helper bundler and the helper-manifest verifier.

These cover the 2026-10-03 rejection item "complete the yt-dlp packaging script and
hash-pinned reproducible path; do not deliver an empty hash":

  * an empty / malformed sha256 in the lock is refused **before** anything is
    installed (no silent fail-closed delivery);
  * a source file whose digest does not match the pin is refused;
  * a matching source installs, writes `<name>.sha256`, and re-verifies;
  * the `zip_member` format pins the archive digest and the extracted member;
  * `verify-helper-manifest.py` treats an absent screen-link helper as "not
    present" by default, but fails with `--require-screen-link`, and fails on a
    byte-tampered installed helper.

No network is used: `--source-dir` provides pre-downloaded bytes.
"""
from __future__ import annotations

import hashlib
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
BUNDLER = REPO_ROOT / "tools/bundle-screen-link-helper.py"
VERIFIER = REPO_ROOT / "tools/verify-helper-manifest.py"


def sha256_of(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_verifier():
    spec = importlib.util.spec_from_file_location("gmgn_verify_helper_manifest", VERIFIER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class BundlerTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.source_dir = self.root / "source"
        self.source_dir.mkdir()
        self.lock_path = self.root / "lock.json"

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def write_lock(self, helper: dict) -> None:
        self.lock_path.write_text(
            json.dumps({
                "schema": 1,
                "notices_path": "apps/macos/Resources/Helpers/THIRD_PARTY_LICENSES.txt",
                "helpers": [helper],
                "source_components": [],
            }),
            encoding="utf-8",
        )

    def raw_lock(self, digest: str) -> dict:
        return {
            "name": "yt-dlp", "required": True, "version": "2026.06.09",
            "distribution": "pyinstaller_standalone", "format": "raw_binary",
            "source_url": "https://example.invalid/yt-dlp_macos", "sha256": digest,
            "upstream_license_spdx": "Unlicense",
            "combined_work_license_spdx": "GPL-3.0-or-later",
            "license_note": "fixture",
        }

    def run_bundler(self, destination: Path, *extra: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(BUNDLER), "--destination", str(destination),
             "--lock", str(self.lock_path), "--cache-dir", str(self.root / "cache"),
             "--source-dir", str(self.source_dir), *extra],
            capture_output=True, text=True,
        )

    def test_installs_and_reverifies_a_pinned_raw_binary(self) -> None:
        payload = self.source_dir / "yt-dlp"
        payload.write_bytes(b"pinned-helper-fixture")
        self.write_lock(self.raw_lock(sha256_of(payload)))
        destination = self.root / "helpers"
        result = self.run_bundler(destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        installed = destination / "yt-dlp"
        self.assertTrue(installed.is_file())
        self.assertTrue(installed.stat().st_mode & 0o111)
        self.assertEqual(sha256_of(installed), sha256_of(payload))
        manifest = (destination / "yt-dlp.sha256").read_text().split()
        self.assertEqual(manifest[0], sha256_of(installed))
        self.assertEqual(manifest[-1].lstrip("*"), "yt-dlp")
        self.assertTrue((destination / "THIRD_PARTY_LICENSES.txt").is_file())
        verify = self.run_bundler(destination, "--verify-only")
        self.assertEqual(verify.returncode, 0, verify.stderr)

    def test_empty_hash_is_refused_before_install(self) -> None:
        payload = self.source_dir / "yt-dlp"
        payload.write_bytes(b"pinned-helper-fixture")
        self.write_lock(self.raw_lock(""))
        destination = self.root / "helpers"
        result = self.run_bundler(destination)
        self.assertEqual(result.returncode, 1)
        self.assertIn("拒绝交付未钉哈希", result.stderr)
        self.assertFalse(destination.exists())

    def test_tampered_source_is_refused(self) -> None:
        payload = self.source_dir / "yt-dlp"
        payload.write_bytes(b"pinned-helper-fixture")
        self.write_lock(self.raw_lock(sha256_of(payload)))
        payload.write_bytes(b"something-else-entirely")
        destination = self.root / "helpers"
        result = self.run_bundler(destination)
        self.assertEqual(result.returncode, 1)
        self.assertIn("与钉死哈希不一致", result.stderr)

    def test_zip_member_pins_archive_and_member(self) -> None:
        member_bytes = b"deno-fixture-binary"
        archive = self.source_dir / "deno.zip"
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("deno", member_bytes)
        self.write_lock({
            "name": "deno", "required": True, "version": "2.9.7",
            "distribution": "javascript_runtime", "format": "zip_member",
            "arch": "arm64",
            "source_url": "https://example.invalid/deno.zip",
            "archive_sha256": sha256_of(archive),
            "member": "deno",
            "sha256": hashlib.sha256(member_bytes).hexdigest(),
            "upstream_license_spdx": "MIT",
            "combined_work_license_spdx": "MIT",
            "license_note": "fixture",
        })
        # The source-dir path reads `deno`, the extracted member name.
        (self.source_dir / "deno").write_bytes(member_bytes)
        destination = self.root / "helpers"
        result = self.run_bundler(destination)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((destination / "deno").read_bytes(), member_bytes)

    def test_verify_only_detects_tampering(self) -> None:
        payload = self.source_dir / "yt-dlp"
        payload.write_bytes(b"pinned-helper-fixture")
        self.write_lock(self.raw_lock(sha256_of(payload)))
        destination = self.root / "helpers"
        self.assertEqual(self.run_bundler(destination).returncode, 0)
        installed = destination / "yt-dlp"
        installed.write_bytes(installed.read_bytes() + b"x")
        result = self.run_bundler(destination, "--verify-only")
        self.assertEqual(result.returncode, 1)
        self.assertIn("哈希不一致", result.stderr)


class VerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self._temporary = tempfile.TemporaryDirectory()
        self.root = Path(self._temporary.name)
        self.app = self.root / "gmgn radio.app"
        self.helpers_dir = self.app / "Contents" / "Helpers"
        self.helpers_dir.mkdir(parents=True)
        for name in ("gmgn-taskd", "gmgn-mcpd"):
            binary = self.helpers_dir / name
            binary.write_bytes(f"#!/bin/sh\necho {name}\n".encode())
            binary.chmod(0o755)
            (self.helpers_dir / f"{name}.sha256").write_text(
                f"{sha256_of(binary)}  {name}\n", encoding="utf-8"
            )
        # A fake pinned lock for the optional screen-link helper.
        self.payload = self.root / "yt-dlp"
        self.payload.write_bytes(b"pinned-yt-dlp-fixture")
        self.lock_path = self.root / "lock.json"
        self.lock_path.write_text(json.dumps({
            "helpers": [{
                "name": "yt-dlp", "required": True, "sha256": sha256_of(self.payload),
            }],
        }), encoding="utf-8")

    def tearDown(self) -> None:
        self._temporary.cleanup()

    def verify(self, require: bool) -> tuple[int, dict]:
        module = load_verifier()
        module.SCREEN_LINK_LOCK = self.lock_path
        report = module.verify(self.app, require_screen_link=require)
        return (0 if report["ok"] else 1), report

    def install_screen_link(self) -> None:
        target = self.helpers_dir / "yt-dlp"
        target.write_bytes(self.payload.read_bytes())
        target.chmod(0o755)
        (self.helpers_dir / "yt-dlp.sha256").write_text(
            f"{sha256_of(target)}  yt-dlp\n", encoding="utf-8"
        )
        (self.helpers_dir / "THIRD_PARTY_LICENSES.txt").write_text(
            "fixture notices\n", encoding="utf-8"
        )

    def test_absent_screen_link_is_not_a_failure_by_default(self) -> None:
        code, report = self.verify(require=False)
        self.assertEqual(code, 0, report["errors"])
        status = report["screen_link"]["helpers"][0]["status"]
        self.assertEqual(status, "absent")

    def test_require_screen_link_fails_when_absent(self) -> None:
        code, report = self.verify(require=True)
        self.assertEqual(code, 1)
        self.assertTrue(any("require-screen-link" in e for e in report["errors"]))

    def test_present_and_matching_screen_link_passes(self) -> None:
        self.install_screen_link()
        code, report = self.verify(require=True)
        self.assertEqual(code, 0, report["errors"])
        self.assertEqual(report["screen_link"]["helpers"][0]["status"], "ok")

    def test_missing_notices_fails_when_helper_present(self) -> None:
        self.install_screen_link()
        (self.helpers_dir / "THIRD_PARTY_LICENSES.txt").unlink()
        code, report = self.verify(require=True)
        self.assertEqual(code, 1)
        self.assertTrue(any("第三方许可声明" in e for e in report["errors"]))

    def test_tampered_screen_link_fails(self) -> None:
        self.install_screen_link()
        target = self.helpers_dir / "yt-dlp"
        target.write_bytes(target.read_bytes() + b"x")
        code, report = self.verify(require=True)
        self.assertEqual(code, 1)
        self.assertEqual(report["screen_link"]["helpers"][0]["status"], "manifest_mismatch")


if __name__ == "__main__":
    unittest.main()
