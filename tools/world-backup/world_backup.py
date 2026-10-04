#!/usr/bin/env python3
"""Portable world-state and asset backup; never writes a live taskd database."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import sys
import tempfile

FORMAT = "gmgn.portable-world-backup"
VERSION = 1


def asset_name_safe(path):
    for part in path.parts:
        name = part.lower()
        if name.startswith(".env") or name in ("keychain", "keychains", "credentials", "sessions", ".git", ".ssh", ".aws", ".codex") or name.endswith((".pem", ".key", ".p12", ".pfx")):
            fail("sensitive path forbidden in assets")


def fail(message):
    raise ValueError(message)


def safe_path(path):
    path = Path(os.path.abspath(path))
    for part in (path, *path.parents):
        if part.is_symlink():
            # macOS standard filesystem aliases are system-owned entry roots;
            # no arbitrary source/payload link is followed.
            if sys.platform == "darwin" and str(part) in ("/var", "/tmp") and part.resolve() == Path("/private") / part.name:
                continue
            fail(f"symlink forbidden: {part}")
    return path.resolve()


def relative(raw):
    if not isinstance(raw, str) or not raw or "\\" in raw or ":" in raw:
        fail(f"invalid relative path: {raw!r}")
    p = PurePosixPath(raw)
    if p.is_absolute() or any(x in ("", ".", "..") for x in raw.split("/")):
        fail(f"unsafe relative path: {raw!r}")
    return p


def digest(path):
    h = hashlib.sha256()
    with safe_path(path).open("rb") as f:
        for data in iter(lambda: f.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def dump(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n", encoding="utf-8")


def load(path):
    return json.loads(safe_path(path).read_text(encoding="utf-8"))


def files(root):
    def walk_error(error):
        raise error
    for current, dirs, names in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirs + names:
            safe_path(Path(current) / name)
        for name in sorted(names):
            path = Path(current) / name
            if not path.is_file():
                fail(f"not a regular file: {path}")
            yield path


def reserve_destination(raw):
    out = safe_path(raw)
    if out.exists():
        fail(f"destination must not exist: {out}")
    if not out.parent.is_dir():
        fail("destination parent must already exist")
    return out


def validate_worlds(data):
    if not isinstance(data, dict) or data.get("schemaVersion") != VERSION or not isinstance(data.get("records"), list):
        fail("invalid worlds schema")
    if not data["records"]:
        fail("no world records")
    seen = set()
    for record in data["records"]:
        if not isinstance(record, dict):
            fail("invalid record")
        identity = tuple(record.get(k) for k in ("world_id", "domain", "key"))
        if any(not isinstance(x, str) or not x for x in identity) or identity in seen:
            fail("invalid or duplicate record identity")
        seen.add(identity)
        if "value" not in record:
            fail("record missing value")
        if type(record.get("revision")) is not int or record["revision"] < 1 or record.get("tombstone") not in (0, 1) or not isinstance(record.get("hash"), str):
            fail("invalid record revision/tombstone/hash")
    return data


def snapshot(database):
    path = safe_path(database)
    if not path.is_file():
        fail("database does not exist")
    # A read transaction gives a consistent snapshot of all selected tables,
    # including WAL commits. No SQLite database is ever copied into the bundle.
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True)
    connection.row_factory = sqlite3.Row
    try:
        connection.execute("BEGIN")
        records = [dict(r) for r in connection.execute(
            "SELECT world_id,domain,key,revision,updated_at_ms,updated_by,tombstone,hash,value "
            "FROM world_records ORDER BY world_id,domain,key")]
        for record in records:
            record["value"] = json.loads(record["value"])
        imports = [dict(r) for r in connection.execute(
            "SELECT world_id,source_hash,package_id,package_version,revision FROM world_imports ORDER BY world_id")]
        blobs = [dict(r) for r in connection.execute(
            "SELECT sha256,bytes,mime,local_path FROM world_blobs ORDER BY sha256")]
        return validate_worlds({"schemaVersion": VERSION, "records": records, "imports": imports}), blobs
    finally:
        connection.close()


def referenced_asset_hashes(value):
    result = set()
    def visit(child):
        if isinstance(child, dict):
            asset = child.get("assetID")
            if isinstance(asset, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", asset):
                result.add(asset[7:])
            for nested in child.values():
                visit(nested)
        elif isinstance(child, list):
            for nested in child:
                visit(nested)
        elif isinstance(child, str) and child.startswith(("{", "[")):
            try:
                visit(json.loads(child))
            except json.JSONDecodeError:
                pass
    visit(value)
    return result


def backup(database, destination, asset_roots=(), blob_files=()):
    out = reserve_destination(destination)
    worlds, blobs = snapshot(database)
    sources = {}
    bindings = []
    roots = {}
    for specification in asset_roots:
        name, separator, raw = specification.partition("=")
        if not separator or not re.fullmatch(r"[A-Za-z0-9_-]+", name) or name in roots:
            fail("asset root must be unique NAME=PATH")
        root = safe_path(raw)
        if not root.is_dir():
            fail(f"missing asset root: {root}")
        if root in (Path("/"), Path.home(), Path.home() / "Library", Path.home() / "Library/Application Support") or root.name.lower() in ("application support", "library", "users", "home", "taskservice"):
            fail("broad asset root forbidden; select a world or asset package directory")
        roots[name] = root
        for source in files(root):
            rel = source.relative_to(root)
            asset_name_safe(source)
            target = f"assets/{name}/{rel.as_posix()}"
            relative(target)
            sources[target] = source
        bindings.append({"name": name, "path": f"assets/{name}"})
    blob_entries = []
    for blob in blobs:
        sha = blob["sha256"]
        if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
            fail("invalid world blob hash")
        if not blob["local_path"]:
            fail(f"missing local asset for blob {sha}; remote-only assets must be downloaded first")
        source = safe_path(blob["local_path"])
        asset_name_safe(source)
        if not source.is_file() or source.stat().st_size != blob["bytes"] or digest(source) != sha:
            fail(f"missing or corrupt world blob {sha}")
        target = f"blobs/{sha}"
        sources[target] = source
        blob_entries.append({"sha256": sha, "bytes": blob["bytes"], "mime": blob["mime"], "path": target})
    # Legacy generated props may carry a verified content ID without a
    # world_blobs registry entry. Explicit GLB files bridge that gap without
    # enumerating/exporting the operational TaskService directory.
    references = referenced_asset_hashes(worlds)
    indexed = {entry["sha256"] for entry in blob_entries}
    for raw in blob_files:
        source = safe_path(raw)
        # A file in TaskService is allowed, but credential-like file names are
        # still forbidden. Do not treat its parent as an asset directory.
        asset_name_safe(source)
        if not source.is_file() or source.suffix.lower() != ".glb":
            fail("explicit blob file must be a regular GLB file")
        size = source.stat().st_size
        with source.open("rb") as stream:
            header = stream.read(12)
        if size < 20 or len(header) != 12 or header[:4] != b"glTF" or int.from_bytes(header[4:8], "little") != 2 or int.from_bytes(header[8:12], "little") != size:
            fail("explicit blob file is not a GLB 2.0 container")
        sha = digest(source)
        if sha not in references:
            fail("explicit blob hash is not referenced by any world assetID")
        target = f"blobs/{sha}"
        sources[target] = source
        if sha not in indexed:
            blob_entries.append({"sha256": sha, "bytes": size, "mime": "model/gltf-binary", "path": target})
            indexed.add(sha)
    # Missing paths inside metadata cannot be silently accepted. Absolute paths
    # remain unchanged in the neutral records; adapters use referenceBindings.
    source_map = {str(source): target for target, source in sources.items()}
    reference_bindings = {}

    def visit(value):
        if isinstance(value, dict):
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
        elif isinstance(value, str):
            if value.startswith("{") or value.startswith("["):
                try:
                    visit(json.loads(value))
                except json.JSONDecodeError:
                    pass
            elif value.startswith("/") or value.startswith("file://"):
                raw = value[7:] if value.startswith("file://") else value
                normalized = str(safe_path(raw))
                if normalized not in source_map:
                    fail(f"uncovered local reference: {raw}; supply its world asset root")
                reference_bindings[value] = source_map[normalized]

    visit(worlds)
    worlds["assetRoots"] = bindings
    worlds["blobs"] = blob_entries
    worlds["referenceBindings"] = reference_bindings
    worlds["recoveryWarnings"] = [
        "Portable staging only: raw record values are unchanged and may contain old absolute paths. Resolve referenceBindings against the recovered directory in a future engine adapter.",
        "No taskd operational history, requests, cursors, jobs, sessions or credentials are exported. World metadata may contain private URLs; protect this backup as private user data.",
    ]
    stage = Path(tempfile.mkdtemp(prefix=".world-backup-", dir=out.parent))
    try:
        dump(stage / "worlds.json", worlds)
        for target, source in sources.items():
            dest = stage / target
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, dest)
        manifest = {"format": FORMAT, "formatVersion": VERSION, "files": []}
        for file in sorted(files(stage)):
            manifest["files"].append({"path": file.relative_to(stage).as_posix(), "bytes": file.stat().st_size, "sha256": digest(file)})
        dump(stage / "manifest.json", manifest)
        verify(stage)
        reserve_destination(out)
        stage.rename(out)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return out


def verify(directory):
    root = safe_path(directory)
    manifest = load(root / "manifest.json")
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT or manifest.get("formatVersion") != VERSION:
        fail("unsupported backup format/version")
    entries = manifest.get("files")
    if not isinstance(entries, list):
        fail("manifest missing files")
    expected = {"manifest.json"}
    for entry in entries:
        if not isinstance(entry, dict):
            fail("invalid manifest file entry")
        rel = str(relative(entry["path"]))
        if rel in expected:
            fail("duplicate/reserved manifest path")
        if rel != "worlds.json" and not rel.startswith(("assets/", "blobs/")):
            fail("unexpected payload path")
        expected.add(rel)
        source = safe_path(root / rel)
        if not source.is_file() or source.stat().st_size != entry["bytes"] or digest(source) != entry["sha256"]:
            fail(f"missing/corrupt payload: {rel}")
    actual = {p.relative_to(root).as_posix() for p in files(root)}
    if actual != expected or "worlds.json" not in expected:
        fail("unlisted/missing bundle files")
    worlds = validate_worlds(load(root / "worlds.json"))
    blobs = worlds.get("blobs")
    bindings = worlds.get("referenceBindings")
    if not isinstance(blobs, list) or not isinstance(bindings, dict):
        fail("invalid asset indexes")
    for blob in blobs:
        if not isinstance(blob, dict):
            fail("invalid blob entry")
        path = str(relative(blob["path"]))
        if path not in expected or digest(root / path) != blob["sha256"] or (root / path).stat().st_size != blob["bytes"]:
            fail("invalid blob reference")
    for target in bindings.values():
        if str(relative(target)) not in expected:
            fail("missing reference binding")
    return manifest


def recover(bundle, destination):
    out = reserve_destination(destination)
    verify(bundle)  # Entire bundle preflight before even creating a destination.
    stage = Path(tempfile.mkdtemp(prefix=".world-recover-", dir=out.parent))
    try:
        for source in files(safe_path(bundle)):
            dest = stage / source.relative_to(safe_path(bundle))
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, dest)
        verify(stage)  # Detect source changes during copy as well.
        reserve_destination(out)
        stage.rename(out)
    finally:
        if stage.exists():
            shutil.rmtree(stage)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="command", required=True)
    b = subs.add_parser("backup")
    b.add_argument("--database", required=True)
    b.add_argument("--out", required=True)
    b.add_argument("--asset-root", action="append", default=[])
    b.add_argument("--blob-file", action="append", default=[], help="Explicit GLB file whose SHA256 matches a world assetID; repeat per file")
    v = subs.add_parser("verify")
    v.add_argument("--bundle", required=True)
    r = subs.add_parser("recover")
    r.add_argument("--bundle", required=True)
    r.add_argument("--out", required=True)
    args = parser.parse_args()
    try:
        if args.command == "backup":
            result = str(backup(args.database, args.out, args.asset_root, args.blob_file))
        elif args.command == "recover":
            result = str(recover(args.bundle, args.out))
        else:
            result = {"files": len(verify(args.bundle)["files"])}
        print(json.dumps({"ok": True, "command": args.command, "result": result}))
        return 0
    except (ValueError, OSError, sqlite3.Error, KeyError, TypeError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
