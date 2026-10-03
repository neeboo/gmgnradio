#!/usr/bin/env python3
"""Package the pinned screen-link helper (yt-dlp, optionally deno) into an app bundle.

This is the **only** writer of `Contents/Helpers/yt-dlp` and its `<name>.sha256`
manifest. It refuses to run unless every required helper has a real, pinned
sha256 in `tools/helpers/screen-link-helpers.lock.json` — an empty hash is a hard
error, never a "skip and continue". The lock is also mirrored field-for-field by
`BundledHelperManifest.pinned` (the runtime authority); the two are kept honest
by `tools/test-screen-link-helper-lock.swift`.

Reproducibility:
  * the version, source URL and sha256 are pinned in the lock file;
  * an already-verified download is reused from the cache (`--cache-dir`);
  * the installed file's digest is re-computed and written next to it, and
    `tools/verify-helper-manifest.py` independently re-checks it.

Usage::

    # bundle yt-dlp into a test app built by tools/e2e-app-build.sh
    python3 tools/bundle-screen-link-helper.py --app "/path/to/gmgn radio.app"

    # bundle into a bare Helpers directory (offline / staging)
    python3 tools/bundle-screen-link-helper.py --destination /tmp/Helpers

    # add the JavaScript runtime too (only needed for YouTube nsig solving)
    python3 tools/bundle-screen-link-helper.py --app ... --include deno

    # verify only (no download, no write)
    python3 tools/bundle-screen-link-helper.py --app ... --verify-only

Exit code 0 = every required helper installed and hash-matching.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import stat
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCK = REPO_ROOT / "tools/helpers/screen-link-helpers.lock.json"
DEFAULT_CACHE = REPO_ROOT / "tmp/screen-link-helper-cache"
HEX_DIGITS = set("0123456789abcdef")
MAX_DOWNLOAD_BYTES = 256 * 1024 * 1024


class BundleError(RuntimeError):
    pass


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def is_pinned(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in HEX_DIGITS for character in value.lower())
    )


def load_lock(path: Path) -> dict:
    if not path.is_file():
        raise BundleError(f"缺少打包钉死清单：{path}")
    try:
        lock = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise BundleError(f"打包钉死清单不是合法 JSON：{error}") from error
    if lock.get("schema") != 1:
        raise BundleError(f"不支持的清单 schema：{lock.get('schema')!r}")
    helpers = lock.get("helpers")
    if not isinstance(helpers, list) or not helpers:
        raise BundleError("打包钉死清单里没有任何 helper")
    names = set()
    for helper in helpers:
        name = helper.get("name")
        if not isinstance(name, str) or not name or "/" in name:
            raise BundleError(f"helper 名字非法：{name!r}")
        if name in names:
            raise BundleError(f"helper 名字重复：{name}")
        names.add(name)
        if not isinstance(helper.get("version"), str) or not helper["version"]:
            raise BundleError(f"helper {name} 没有钉死版本")
        if not is_pinned(helper.get("sha256")):
            # This is the whole point of the script: no empty-hash delivery.
            raise BundleError(
                f"helper {name} 的 sha256 是空的或不是 64 位十六进制："
                f"{helper.get('sha256')!r} —— 拒绝交付未钉哈希的 helper"
            )
        source = helper.get("source_url")
        if not isinstance(source, str) or not source.startswith("https://"):
            raise BundleError(f"helper {name} 的 source_url 必须是 https：{source!r}")
        if helper.get("format") not in ("raw_binary", "zip_member"):
            raise BundleError(f"helper {name} 的 format 未知：{helper.get('format')!r}")
        if helper.get("format") == "zip_member":
            if not isinstance(helper.get("member"), str) or not helper["member"]:
                raise BundleError(f"helper {name} 是 zip_member 但没有 member")
            if not is_pinned(helper.get("archive_sha256")):
                raise BundleError(f"helper {name} 的 archive_sha256 不是有效摘要")
    return lock


def download(url: str, destination: Path) -> None:
    request = urllib.request.Request(
        url, headers={"User-Agent": "gmgn-radio-helper-bundler/1.0"}
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        if response.status != 200:
            raise BundleError(f"下载失败 HTTP {response.status}：{url}")
        total = 0
        with destination.open("wb") as stream:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_DOWNLOAD_BYTES:
                    raise BundleError(f"下载超过上限 {MAX_DOWNLOAD_BYTES} 字节：{url}")
                stream.write(chunk)


def fetch_verified(helper: dict, cache: Path, source_dir: Path | None) -> Path:
    """Return a local file whose content matches the locked sha256."""
    name = helper["name"]
    expected = helper["sha256"].lower()
    if helper["format"] == "raw_binary":
        cached = cache / f"{name}-{expected}"
    else:
        cached = cache / f"{name}-{expected}-{helper['member']}"
    if source_dir is not None:
        candidate = source_dir / name
        if not candidate.is_file():
            raise BundleError(f"--source-dir 下找不到 {candidate}")
        actual = sha256_of(candidate)
        if actual != expected:
            raise BundleError(
                f"{name} 与钉死哈希不一致（期望 {expected}，实际 {actual}）"
            )
        return candidate
    if cached.is_file() and cached.stat().st_size > 0 and sha256_of(cached) == expected:
        return cached
    cached.parent.mkdir(parents=True, exist_ok=True)
    archive = cached.with_suffix(cached.suffix + ".download")
    print(f"[bundle-screen-link-helper] 下载 {name} {helper['version']} …")
    try:
        download(helper["source_url"], archive)
        if helper["format"] == "zip_member":
            archive_expected = helper["archive_sha256"].lower()
            archive_actual = sha256_of(archive)
            if archive_actual != archive_expected:
                raise BundleError(
                    f"{name} 归档与钉死哈希不一致（期望 {archive_expected}，"
                    f"实际 {archive_actual}）"
                )
            with zipfile.ZipFile(archive) as bundle:
                member = helper["member"]
                if member not in bundle.namelist():
                    raise BundleError(f"{name} 归档里没有 {member}")
                with bundle.open(member) as source, cached.open("wb") as target:
                    shutil.copyfileobj(source, target)
        else:
            shutil.move(archive, cached)
    finally:
        archive.unlink(missing_ok=True)
    actual = sha256_of(cached)
    if actual != expected:
        cached.unlink(missing_ok=True)
        raise BundleError(f"{name} 与钉死哈希不一致（期望 {expected}，实际 {actual}）")
    return cached


def install(source: Path, destination_dir: Path, name: str) -> Path:
    destination_dir.mkdir(parents=True, exist_ok=True)
    target = destination_dir / name
    shutil.copyfile(source, target)
    target.chmod(
        target.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH
    )
    digest = sha256_of(target)
    (destination_dir / f"{name}.sha256").write_text(
        f"{digest}  {name}\n", encoding="utf-8"
    )
    return target


def verify_installed(helper: dict, destination_dir: Path) -> str:
    name = helper["name"]
    target = destination_dir / name
    if not target.is_file():
        raise BundleError(f"缺少内置 helper：{target}")
    if not target.stat().st_mode & stat.S_IXUSR:
        raise BundleError(f"内置 helper 不可执行：{target}")
    actual = sha256_of(target)
    expected = helper["sha256"].lower()
    if actual != expected:
        raise BundleError(f"{name} 哈希不一致（期望 {expected}，实际 {actual}）")
    manifest = destination_dir / f"{name}.sha256"
    if not manifest.is_file():
        raise BundleError(f"缺少完整性清单：{manifest}")
    listed = manifest.read_text(encoding="utf-8").split()
    if not listed or listed[0].lower() != actual:
        raise BundleError(f"完整性清单与文件不一致：{manifest}")
    return actual


def copy_notices(lock: dict, destination_dir: Path) -> Path:
    source = REPO_ROOT / lock["notices_path"]
    if not source.is_file():
        raise BundleError(f"缺少第三方许可声明：{source}")
    destination_dir.mkdir(parents=True, exist_ok=True)
    target = destination_dir / source.name
    shutil.copyfile(source, target)
    return target


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, help="app bundle; installs into Contents/Helpers")
    parser.add_argument("--destination", type=Path, help="bare Helpers directory")
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE)
    parser.add_argument(
        "--include",
        action="append",
        default=[],
        help="additionally bundle an optional helper by name (e.g. deno)",
    )
    parser.add_argument(
        "--source-dir",
        type=Path,
        help="offline: read already-downloaded files from here instead of the network",
    )
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    if bool(args.app) == bool(args.destination):
        raise SystemExit("需要且只需要 --app 或 --destination 之一")

    try:
        lock = load_lock(args.lock)
    except BundleError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    if args.destination:
        destination_dir = args.destination
    else:
        app = args.app.resolve()
        if not (app / "Contents/MacOS/gmgn radio").is_file():
            print(f"error: 不是可运行的 app 产物：{app}", file=sys.stderr)
            return 1
        destination_dir = app / "Contents/Helpers"

    helpers = list(lock["helpers"])
    optional = {helper["name"] for helper in helpers if not helper.get("required")}
    selected = [
        helper
        for helper in helpers
        if helper.get("required") or helper["name"] in set(args.include)
    ]
    unknown = set(args.include) - {helper["name"] for helper in helpers}
    if unknown:
        print(f"error: --include 里有未知 helper：{sorted(unknown)}", file=sys.stderr)
        return 1

    report: dict = {
        "destination": str(destination_dir),
        "lock": str(args.lock),
        "helpers": [],
        "notices": None,
        "ok": True,
    }
    try:
        for helper in selected:
            if args.verify_only:
                digest = verify_installed(helper, destination_dir)
            else:
                source = fetch_verified(helper, args.cache_dir, args.source_dir)
                install(source, destination_dir, helper["name"])
                digest = verify_installed(helper, destination_dir)
            report["helpers"].append(
                {
                    "name": helper["name"],
                    "version": helper["version"],
                    "sha256": digest,
                    "distribution": helper["distribution"],
                    "combined_work_license_spdx": helper["combined_work_license_spdx"],
                }
            )
        if args.verify_only:
            notices = destination_dir / Path(lock["notices_path"]).name
            if not notices.is_file():
                raise BundleError(f"缺少第三方许可声明：{notices}")
            report["notices"] = str(notices)
        else:
            report["notices"] = str(copy_notices(lock, destination_dir))
    except BundleError as error:
        report["ok"] = False
        report["error"] = str(error)
        if args.json:
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            print(f"error: {error}", file=sys.stderr)
        return 1

    report["skipped_optional"] = sorted(optional - set(args.include))
    report["unused_lock_helpers"] = sorted(
        helper["name"] for helper in helpers if helper not in selected
    )
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        action = "已校验" if args.verify_only else "已内置"
        for entry in report["helpers"]:
            print(
                f"[{action}] {entry['name']} {entry['version']} "
                f"sha256={entry['sha256']} license={entry['combined_work_license_spdx']}"
            )
        if report["skipped_optional"]:
            print(f"未内置（可选）：{', '.join(report['skipped_optional'])}")
        print(
            "许可义务：内置的 PyInstaller yt-dlp 是 GPLv3+ 组合作品，"
            f"已随包复制 {Path(report['notices']).name}。"
        )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
