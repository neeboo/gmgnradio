#!/usr/bin/env python3
"""Verify the bundling and integrity of the helpers inside the app.

`gmgn-taskd` and `gmgn-mcpd` are compiled from this repository by the Xcode
post-build scripts (`tools/build-taskd-helper.sh`, `tools/build-mcpd-helper.sh`).
Each script writes a `<name>.sha256` next to the installed binary and fails
closed if it cannot compute a digest, so a bundle can never ship with a
placeholder hash. This tool re-computes those digests at verification time — it
is the independent check, not a copy of the writer.

The screen-link helper (`yt-dlp`, optionally `deno`) is downloaded rather than
compiled, so it is **optional per bundle** but never unverified: when present it
must match the pinned sha256 from `tools/helpers/screen-link-helpers.lock.json`.
`--require-screen-link` turns "present" into a hard requirement (used by E2E
runs that must play a real site link).

Usage::

    python3 tools/verify-helper-manifest.py --app "/path/to/gmgn radio.app"
    python3 tools/verify-helper-manifest.py --app ... --require-screen-link
    python3 tools/verify-helper-manifest.py --app ... --json

Exit code 0 = every required helper is present, executable and hash-matching.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import sys
from pathlib import Path

HELPERS = ("gmgn-taskd", "gmgn-mcpd")
SCREEN_LINK_LOCK = Path(__file__).resolve().parent / "helpers/screen-link-helpers.lock.json"


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_manifest(text: str) -> tuple[str, str] | None:
    """Accept the standard `<hash>  <name>` shasum line format."""
    parts = text.strip().split()
    if len(parts) < 2:
        return None
    return parts[0].lower(), parts[-1].lstrip("*")


def verify(app: Path, require_screen_link: bool = False) -> dict:
    helpers_dir = app / "Contents" / "Helpers"
    report: dict = {"app": str(app), "helpers": [], "ok": True, "errors": []}
    for name in HELPERS:
        binary = helpers_dir / name
        entry: dict = {"name": name, "path": str(binary)}
        if not binary.is_file():
            entry["status"] = "missing"
            report["errors"].append(f"缺少内置 helper：{binary}")
            report["ok"] = False
            report["helpers"].append(entry)
            continue
        mode = binary.stat().st_mode
        if not mode & stat.S_IXUSR:
            entry["status"] = "not_executable"
            report["errors"].append(f"helper 不可执行：{binary}")
            report["ok"] = False
            report["helpers"].append(entry)
            continue
        actual = sha256_of(binary)
        entry["actual_sha256"] = actual
        manifest = helpers_dir / f"{name}.sha256"
        entry["manifest"] = str(manifest)
        if not manifest.is_file():
            entry["status"] = "missing_manifest"
            report["errors"].append(f"缺少完整性清单：{manifest}")
            report["ok"] = False
            report["helpers"].append(entry)
            continue
        parsed = parse_manifest(manifest.read_text(encoding="utf-8"))
        if parsed is None:
            entry["status"] = "malformed_manifest"
            report["errors"].append(f"完整性清单格式不正确：{manifest}")
            report["ok"] = False
            report["helpers"].append(entry)
            continue
        expected, listed_name = parsed
        entry["expected_sha256"] = expected
        entry["listed_name"] = listed_name
        if expected != actual:
            entry["status"] = "hash_mismatch"
            report["errors"].append(
                f"helper 摘要不匹配：{binary}（清单 {expected}，实际 {actual}）"
            )
            report["ok"] = False
        else:
            entry["status"] = "ok"
        report["helpers"].append(entry)
    report["screen_link"] = verify_screen_link(helpers_dir, require=require_screen_link)
    if not report["screen_link"]["ok"]:
        report["ok"] = False
        report["errors"].extend(report["screen_link"]["errors"])
    return report


def verify_screen_link(helpers_dir: Path, require: bool) -> dict:
    """Verify the downloaded screen-link helper when present.

    Absent is not a failure by default (the E2E build does not download during
    the build). When the file exists, however, it must match the pinned sha256
    and carry a matching `<name>.sha256` — an unverified helper is never a
    silent pass. `require=True` makes presence mandatory.
    """
    link: dict = {"ok": True, "helpers": [], "errors": []}
    if not SCREEN_LINK_LOCK.is_file():
        link["ok"] = False
        link["errors"].append(f"缺少打包钉死清单：{SCREEN_LINK_LOCK}")
        return link
    lock = json.loads(SCREEN_LINK_LOCK.read_text(encoding="utf-8"))
    for helper in lock.get("helpers", []):
        name = helper["name"]
        expected = str(helper.get("sha256", "")).lower()
        pinned = len(expected) == 64 and all(c in "0123456789abcdef" for c in expected)
        binary = helpers_dir / name
        entry: dict = {"name": name, "path": str(binary), "pinned_sha256": expected}
        if not binary.is_file():
            if require and helper.get("required", False):
                entry["status"] = "missing"
                link["errors"].append(f"缺少内置 helper（--require-screen-link）：{binary}")
                link["ok"] = False
            else:
                entry["status"] = "absent"
            link["helpers"].append(entry)
            continue
        if not pinned:
            entry["status"] = "unpinned"
            link["errors"].append(f"{name} 已随包但锁里没有有效 sha256")
            link["ok"] = False
            link["helpers"].append(entry)
            continue
        actual = sha256_of(binary)
        entry["actual_sha256"] = actual
        manifest = helpers_dir / f"{name}.sha256"
        entry["manifest"] = str(manifest)
        if not manifest.is_file():
            entry["status"] = "missing_manifest"
            link["errors"].append(f"缺少完整性清单：{manifest}")
            link["ok"] = False
            link["helpers"].append(entry)
            continue
        parsed = parse_manifest(manifest.read_text(encoding="utf-8"))
        if parsed is None or parsed[0] != actual:
            entry["status"] = "manifest_mismatch"
            link["errors"].append(f"{name} 的 <name>.sha256 与文件不一致：{manifest}")
            link["ok"] = False
            link["helpers"].append(entry)
            continue
        if actual != expected:
            entry["status"] = "hash_mismatch"
            link["errors"].append(
                f"{name} 摘要与钉死清单不一致（期望 {expected}，实际 {actual}）"
            )
            link["ok"] = False
            link["helpers"].append(entry)
            continue
        entry["status"] = "ok"
        link["helpers"].append(entry)
    installed = any(entry["status"] == "ok" for entry in link["helpers"])
    if installed:
        notices_name = Path(lock.get("notices_path", "THIRD_PARTY_LICENSES.txt")).name
        if not (helpers_dir / notices_name).is_file():
            link["errors"].append(
                f"内置了屏幕链接 helper 但没有第三方许可声明：{helpers_dir / notices_name}"
            )
            link["ok"] = False
    return link


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--require-screen-link",
        action="store_true",
        help="fail when the pinned yt-dlp is not bundled (E2E runs that play a real link)",
    )
    args = parser.parse_args()
    report = verify(args.app, require_screen_link=args.require_screen_link)
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        for entry in report["helpers"]:
            mark = "PASS" if entry["status"] == "ok" else "FAIL"
            print(f"[{mark}] {entry['name']}: {entry['status']}")
        for entry in report.get("screen_link", {}).get("helpers", []):
            if entry["status"] == "ok":
                mark = "PASS"
            elif entry["status"] == "absent":
                mark = "--"
            else:
                mark = "FAIL"
            print(f"[{mark}] {entry['name']}: {entry['status']}")
        for error in report["errors"]:
            print(f"  error: {error}")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
