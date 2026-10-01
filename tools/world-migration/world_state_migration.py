#!/usr/bin/env python3
"""World-state migration tooling (S0: read-only reconnaissance + export + equivalence).

This tool exists for exactly one migration: taking the Swift-written
``state.json`` world state out of the app's Application Support tree and making
`gmgn-taskd` (Rust) the only writer.

It is **read-only with respect to the live install**: `export` copies bytes out,
it never rewrites or deletes a ``state.json``. The only thing it ever writes is
a new bundle directory (default ``backups/world-state-migration/<stamp>/``),
which is a gitignored local output directory.

Three subcommands:

``export``
    Discover every ``state.json`` under a LivingWorld root, resolve which file
    is *current* for each world (the app writes
    ``<packageID>/<packageVersion>/state.json``, and ``packageVersion`` comes
    from the bundled ``world.json``), copy every file byte-for-byte into the
    bundle, and record sha256 + byte count + worldID for each. Also writes
    ``rollback.sh`` (one command back to the ``state.json`` authority) and
    ``README.md``.

``canonicalize``
    Turn the bundle into the single self-contained ``worlds.json`` payload the
    Rust importer consumes. Only the *current* file per ``worldID`` is a
    migration input; the historical files are listed but not imported.

``compare``
    Field-by-field equivalence between the source ``state.json`` files and a
    snapshot dumped by the Rust authority (``gmgn-taskd world-dump``). Any
    difference is reported with its JSON path and exits non-zero.

The comparison is deliberately *not* byte comparison of the whole file: JSON
object key order is not semantics. Two documented normalizations:

1. object key order is ignored everywhere;
2. the opaque JSON-in-string blobs under ``gmgn.generated-prop.v1`` are compared
   as parsed JSON (their key order inside the string is also not semantics),
   and the report says when that fallback was needed.

Everything else is strict equality, leaf by leaf.
"""

from __future__ import annotations

import argparse
import datetime as _datetime
import hashlib
import json
import os
import shutil
import stat
import sys
import tempfile

SCHEMA_VERSION = 1
STATE_FILE_NAME = "state.json"

# Metadata values that are themselves serialized JSON objects. Swift stores the
# generated-prop record as a JSON string inside `metadata`; its key order is not
# stable across writers, so equality is decided on the parsed value.
OPAQUE_JSON_METADATA_KEYS = ("gmgn.generated-prop.v1",)

# Keys the Rust authority adds to its records that are *not* part of the
# `state.json` document. They are dropped before comparison so that the
# comparison is exactly the Swift document's field set.
RUST_ONLY_TOP_LEVEL_KEYS = ("__authority",)

MISSING = object()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: str):
    with open(path, "rb") as handle:
        return json.loads(handle.read().decode("utf-8"))


def dump_json(path: str, value) -> None:
    data = json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(data)
        handle.write("\n")


# --------------------------------------------------------------------------
# discovery / planning
# --------------------------------------------------------------------------

def discover_state_files(living_world_root: str):
    """Return every ``state.json`` under ``root`` as (packageID, versionLabel, path).

    ``versionLabel`` is the directory between the package directory and the file,
    or ``None`` for a legacy file written directly under the package directory
    (before versioned state files existed).
    """
    found = []
    if not os.path.isdir(living_world_root):
        return found
    for package_id in sorted(os.listdir(living_world_root)):
        package_dir = os.path.join(living_world_root, package_id)
        if not os.path.isdir(package_dir):
            continue
        direct = os.path.join(package_dir, STATE_FILE_NAME)
        if os.path.isfile(direct):
            found.append((package_id, None, direct))
        for entry in sorted(os.listdir(package_dir)):
            candidate = os.path.join(package_dir, entry, STATE_FILE_NAME)
            if os.path.isdir(os.path.join(package_dir, entry)) and os.path.isfile(candidate):
                found.append((package_id, entry, candidate))
    return found


def bundled_versions(worlds_root: str):
    """packageID -> packageVersion (and worldID) from the bundled world manifests."""
    versions = {}
    if not worlds_root or not os.path.isdir(worlds_root):
        return versions
    for package_id in sorted(os.listdir(worlds_root)):
        manifest = os.path.join(worlds_root, package_id, "world.json")
        if not os.path.isfile(manifest):
            continue
        try:
            document = load_json(manifest)
        except (OSError, ValueError):
            continue
        version = document.get("packageVersion")
        if isinstance(version, str) and version:
            versions[package_id] = {
                "packageVersion": version,
                "worldID": document.get("worldID"),
            }
    return versions


def _version_key(label):
    """Sort key for a version directory label: numeric dotted versions sort by
    number, anything else sorts below a real version and by string."""
    if label is None:
        return (0, (), "")
    parts = label.split(".")
    if parts and all(part.isdigit() for part in parts):
        return (2, tuple(int(part) for part in parts), "")
    return (1, (), label)


def plan_imports(state_files, versions):
    """Group discovered files by worldID and choose the current one per world.

    The app resolves the state file from the *bundled manifest's*
    ``packageVersion``, so that file wins whenever it exists. Otherwise the
    highest version label on disk wins. Legacy files (no version directory) are
    historical unless nothing else exists.
    """
    entries = []
    for package_id, version_label, path in state_files:
        try:
            document = load_json(path)
        except (OSError, ValueError) as error:
            entries.append({
                "packageID": package_id,
                "packageVersion": version_label,
                "sourcePath": path,
                "error": str(error),
            })
            continue
        world_id = document.get("worldID")
        bundled = versions.get(package_id, {})
        declared = bundled.get("packageVersion")
        entry = {
            "packageID": package_id,
            "packageVersion": version_label,
            "worldID": world_id,
            "sourcePath": path,
            "sha256": sha256_file(path),
            "bytes": os.path.getsize(path),
            "objects": len(document.get("objectStates") or {}),
            "layoutRevision": document.get("layoutRevision"),
            "revision": document.get("revision"),
            "declaredPackageVersion": declared,
            "isCurrent": False,
            "currentReason": None,
        }
        entries.append(entry)

    by_world = {}
    for entry in entries:
        if "error" in entry or not entry.get("worldID"):
            continue
        by_world.setdefault(entry["worldID"], []).append(entry)

    for world_id, group in sorted(by_world.items()):
        def rank(entry):
            declared = entry.get("declaredPackageVersion")
            label = entry.get("packageVersion")
            if declared is not None and label == declared:
                return (3, _version_key(label), "")
            if label is None:
                return (0, (), "")
            return (1, _version_key(label), "")

        best = max(group, key=rank)
        best["isCurrent"] = True
        best["currentReason"] = (
            "bundled manifest packageVersion"
            if best.get("packageVersion") == best.get("declaredPackageVersion")
            else "highest version directory on disk"
        )
    return entries, by_world


# --------------------------------------------------------------------------
# export
# --------------------------------------------------------------------------

def cmd_export(args) -> int:
    living_world_root = os.path.expanduser(args.living_world_root)
    if not os.path.isdir(living_world_root):
        print("FAIL: no LivingWorld root at %s" % living_world_root)
        return 2
    stamp = args.stamp or _datetime.datetime.now(_datetime.timezone.utc).strftime(
        "%Y%m%dT%H%M%SZ"
    )
    out_dir = os.path.abspath(os.path.expanduser(args.out)) if args.out else os.path.join(
        args.repo_root, "backups", "world-state-migration", stamp
    )
    if os.path.exists(out_dir) and os.listdir(out_dir):
        print("FAIL: export directory already exists and is not empty: %s" % out_dir)
        return 2
    os.makedirs(out_dir, exist_ok=True)

    state_files = discover_state_files(living_world_root)
    versions = bundled_versions(args.worlds_root)
    entries, by_world = plan_imports(state_files, versions)

    for entry in entries:
        if "error" in entry:
            continue
        relative = os.path.join(
            "state",
            entry["packageID"],
            entry["packageVersion"] or "unversioned",
            STATE_FILE_NAME,
        )
        target = os.path.join(out_dir, relative)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(entry["sourcePath"], target)
        copied = sha256_file(target)
        if copied != entry["sha256"]:
            print("FAIL: copy of %s changed bytes" % entry["sourcePath"])
            return 2
        entry["bundlePath"] = relative

    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "gmgn-living-world-state-export",
        "exportedAt": _datetime.datetime.now(_datetime.timezone.utc).isoformat(),
        "sourceRoot": living_world_root,
        "worldsRoot": os.path.abspath(args.worlds_root) if args.worlds_root else None,
        "bundleSha256": bundle_digest(entries),
        "files": sorted(
            (entry for entry in entries if "error" not in entry),
            key=lambda entry: entry["bundlePath"],
        ),
        "unreadable": [entry for entry in entries if "error" in entry],
        "worlds": [
            {
                "worldID": world_id,
                "current": next(
                    (entry["bundlePath"] for entry in group if entry.get("isCurrent")),
                    None,
                ),
                "historical": sorted(
                    entry["bundlePath"] for entry in group if not entry.get("isCurrent")
                ),
            }
            for world_id, group in sorted(by_world.items())
        ],
    }
    dump_json(os.path.join(out_dir, "manifest.json"), manifest)
    write_rollback_script(out_dir, manifest)
    write_bundle_readme(out_dir, manifest)

    print("EXPORT %s" % out_dir)
    print("bundleSha256 %s" % manifest["bundleSha256"])
    print("files %d worlds %d unreadable %d" % (
        len(manifest["files"]), len(manifest["worlds"]), len(manifest["unreadable"])
    ))
    for world in manifest["worlds"]:
        current = next(
            entry for entry in manifest["files"] if entry["bundlePath"] == world["current"]
        )
        print("world %s current=%s sha256=%s objects=%d layoutRevision=%s revision=%s historical=%d" % (
            world["worldID"], current["bundlePath"], current["sha256"],
            current["objects"], current["layoutRevision"], current["revision"],
            len(world["historical"]),
        ))
    return 0


def bundle_digest(entries) -> str:
    lines = []
    for entry in sorted(
        (item for item in entries if "error" not in item),
        key=lambda item: item.get("bundlePath") or item["sourcePath"],
    ):
        lines.append("%s  %s" % (
            entry["sha256"], entry.get("bundlePath") or entry["sourcePath"]
        ))
    return sha256_bytes("\n".join(lines).encode("utf-8"))


def write_rollback_script(out_dir, manifest) -> None:
    path = os.path.join(out_dir, "rollback.sh")
    body = """#!/bin/sh
# One command back to the `state.json` world-state authority (incident only).
#
# Restores the exported bytes over the live files. It saves the current bytes
# into ./rollback-preimage/<stamp>/ first, refuses to run without --confirm and
# never deletes anything.
set -eu
BUNDLE_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ "${1:-}" != "--confirm" ]; then
  echo "usage: rollback.sh --confirm"
  echo "Restores state.json from this export (the pre-migration authority)."
  exit 2
fi
LIVING_WORLD_ROOT="${LIVING_WORLD_ROOT:-$HOME/Library/Application Support/ai.gmgn.radio/LivingWorld}"
export BUNDLE_DIR LIVING_WORLD_ROOT
exec python3 "$BUNDLE_DIR/rollback.py"
"""
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    python_body = '''#!/usr/bin/env python3
"""Restore this export over the live state.json files (incident rollback).

Reads ``manifest.json``, copies every exported file back to the app's
``<packageID>/<packageVersion>/state.json`` path, and saves the current bytes
into ``rollback-preimage/<stamp>/`` before overwriting. Never deletes.
"""
import datetime, json, os, shutil, sys

bundle = os.environ["BUNDLE_DIR"]
root = os.environ["LIVING_WORLD_ROOT"]
manifest = json.load(open(os.path.join(bundle, "manifest.json")))
stamp = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
preimage = os.path.join(bundle, "rollback-preimage", stamp)
restored = 0
for entry in manifest["files"]:
    parts = [root, entry["packageID"]]
    if entry["packageVersion"] not in (None, "unversioned"):
        parts.append(entry["packageVersion"])
    parts.append("state.json")
    destination = os.path.join(*parts)
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    if os.path.exists(destination):
        os.makedirs(preimage, exist_ok=True)
        shutil.copyfile(destination, os.path.join(preimage, entry["bundlePath"].replace("/", "__")))
    shutil.copyfile(os.path.join(bundle, entry["bundlePath"]), destination)
    restored += 1
print("restored %d files from %s; pre-image in %s" % (restored, bundle, preimage))
'''
    with open(os.path.join(out_dir, "rollback.py"), "w", encoding="utf-8") as handle:
        handle.write(python_body)


def write_bundle_readme(out_dir, manifest) -> None:
    lines = [
        "# world-state migration export",
        "",
        "Exported: %s" % manifest["exportedAt"],
        "Source root: `%s`" % manifest["sourceRoot"],
        "Bundle digest (sha256 over `sha256  path` lines): `%s`" % manifest["bundleSha256"],
        "",
        "Every file below is a byte-for-byte copy of a live `state.json`. Nothing in the",
        "live tree was modified, moved or deleted by the export.",
        "",
        "| bundle path | sha256 | bytes | worldID | objects | layoutRevision | current |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for entry in manifest["files"]:
        lines.append("| `%s` | `%s` | %d | `%s` | %d | %s | %s |" % (
            entry["bundlePath"], entry["sha256"], entry["bytes"], entry["worldID"],
            entry["objects"], entry["layoutRevision"], "yes" if entry["isCurrent"] else "historical",
        ))
    lines += [
        "",
        "## Rollback (incident only)",
        "",
        "```sh",
        "%s/rollback.sh --confirm" % out_dir,
        "```",
        "",
        "Restores the exported bytes over the live files (pre-imaging whatever is there",
        "now). It never deletes. Only needed while `gmgn-taskd` is not the world-state",
        "authority yet, or if the authority must be abandoned.",
        "",
        "## Equivalence",
        "",
        "```sh",
        "python3 tools/world-migration/world_state_migration.py canonicalize \\",
        "  --bundle %s --out %s/worlds.json" % (out_dir, out_dir),
        "python3 tools/world-migration/world_state_migration.py compare \\",
        "  --bundle %s --snapshot <rust world-dump.json>" % out_dir,
        "```",
        "",
        "Historical files (older package versions of the same world) are exported but are",
        "**not** migration inputs: the authority takes the current file per `worldID`.",
        "",
    ]
    with open(os.path.join(out_dir, "README.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines))


# --------------------------------------------------------------------------
# canonicalize
# --------------------------------------------------------------------------

def cmd_canonicalize(args) -> int:
    bundle = os.path.abspath(args.bundle)
    manifest = load_json(os.path.join(bundle, "manifest.json"))
    worlds = []
    for world in manifest["worlds"]:
        current = next(
            (entry for entry in manifest["files"] if entry["bundlePath"] == world["current"]),
            None,
        )
        if current is None:
            continue
        path = os.path.join(bundle, world["current"])
        with open(path, "rb") as handle:
            raw = handle.read()
        # The bundle is the byte-identical pre-image; the payload carries the
        # *raw text* plus its sha256 so the Rust importer can verify that the
        # bytes it is about to adopt are exactly the exported ones. Rust then
        # stores its own canonical form, and the comparator proves the stored
        # document equals the original file field by field.
        digest = sha256_bytes(raw)
        if digest != current["sha256"]:
            print("FAIL: %s changed since the export (manifest %s, disk %s)"
                  % (world["current"], current["sha256"], digest))
            return 1
        # The payload carries the pre-image text *verbatim*: any re-serialization
        # would change the bytes the sha256 describes.
        document = json.loads(raw.decode("utf-8"))
        worlds.append({
            "worldID": world["worldID"],
            "packageID": current["packageID"],
            "packageVersion": current["packageVersion"] or "unversioned",
            "stateFile": world["current"],
            "stateSha256": digest,
            "stateJson": raw.decode("utf-8"),
        })
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "kind": "gmgn-world-authority-import",
        "bundleSha256": manifest["bundleSha256"],
        "worlds": sorted(worlds, key=lambda item: item["worldID"]),
    }
    dump_json(args.out, payload)
    print("CANONICAL %s worlds=%d bundleSha256=%s" % (
        args.out, len(payload["worlds"]), payload["bundleSha256"]
    ))
    for world in payload["worlds"]:
        document = json.loads(world["stateJson"])
        print("world %s package=%s/%s stateSha256=%s objects=%d layoutRevision=%s revision=%s" % (
            world["worldID"], world["packageID"], world["packageVersion"],
            world["stateSha256"], len(document.get("objectStates") or {}),
            document.get("layoutRevision"), document.get("revision"),
        ))
    return 0


# --------------------------------------------------------------------------
# compare
# --------------------------------------------------------------------------

class Diff(object):
    def __init__(self):
        self.paths = []
        self.leaves = 0
        self.normalized_opaque = 0
        self.missing_worlds = []

    def add(self, path, expected, actual, note=""):
        self.paths.append({
            "path": path,
            "expected": expected,
            "actual": actual,
            "note": note,
        })


def canonical_projection(value, path="$"):
    """Canonical, comparison-stable projection of a document.

    Sorted object keys, and opaque JSON-in-string blobs replaced by their parsed
    value (also canonicalized). The sha256 of this projection is the equivalence
    witness: equal hashes mean the two documents are field-by-field identical
    under the two documented normalizations.
    """
    if isinstance(value, dict):
        out = {}
        for key in sorted(value):
            child = value[key]
            if key in OPAQUE_JSON_METADATA_KEYS and isinstance(child, str):
                try:
                    child = json.loads(child)
                except ValueError:
                    pass
            out[key] = canonical_projection(child, "%s.%s" % (path, key))
        return out
    if isinstance(value, list):
        return [canonical_projection(item, "%s[%d]" % (path, index))
                for index, item in enumerate(value)]
    if isinstance(value, float) and value == int(value) and abs(value) < 1e15:
        # `1.0` and `1` are the same JSON number for a world transform; keep the
        # projection blind to that difference (both encoders are free to pick).
        return int(value)
    return value


def projection_sha256(value) -> str:
    text = json.dumps(canonical_projection(value), ensure_ascii=False,
                      sort_keys=True, separators=(",", ":"))
    return sha256_bytes(text.encode("utf-8"))


def compare_value(expected, actual, path, diff, opaque_parent=False):
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(set(expected) | set(actual)):
            child_path = "%s.%s" % (path, key) if path else key
            if key not in expected:
                diff.add(child_path, "<absent>", actual[key], "unexpected key")
            elif key not in actual:
                diff.add(child_path, expected[key], "<absent>", "missing key")
            else:
                compare_value(expected[key], actual[key], child_path, diff)
        return
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            diff.add("%s.length" % path, len(expected), len(actual))
            return
        for index, (left, right) in enumerate(zip(expected, actual)):
            compare_value(left, right, "%s[%d]" % (path, index), diff)
        return
    if isinstance(expected, str) and isinstance(actual, str) and not opaque_parent:
        # A metadata blob that is itself JSON: compare as parsed JSON when the
        # key is one of the declared opaque-JSON keys. The keys contain dots
        # themselves, so match on the path suffix rather than on the last
        # dot-separated segment.
        is_opaque = any(path == key or path.endswith("." + key)
                        for key in OPAQUE_JSON_METADATA_KEYS)
        if is_opaque:
            diff.leaves += 1
            try:
                left = json.loads(expected)
                right = json.loads(actual)
            except ValueError:
                if expected != actual:
                    diff.add(path, expected, actual, "opaque blob not parseable")
                return
            before = len(diff.paths)
            compare_value(left, right, path, diff, opaque_parent=True)
            if len(diff.paths) == before and expected != actual:
                diff.normalized_opaque += 1
            return
    diff.leaves += 1
    if isinstance(expected, bool) or isinstance(actual, bool):
        if expected is not actual:
            diff.add(path, expected, actual)
        return
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        if float(expected) != float(actual):
            diff.add(path, expected, actual)
        return
    if expected != actual:
        diff.add(path, expected, actual)


def cmd_compare(args) -> int:
    bundle = os.path.abspath(args.bundle)
    manifest = load_json(os.path.join(bundle, "manifest.json"))
    snapshot = load_json(args.snapshot)
    by_world = {}
    for world in snapshot.get("worlds", []):
        by_world[world.get("worldID")] = world

    failures = 0
    checked = 0
    for world in manifest["worlds"]:
        current = next(
            (entry for entry in manifest["files"] if entry["bundlePath"] == world["current"]),
            None,
        )
        if current is None:
            continue
        source = load_json(os.path.join(bundle, world["current"]))
        source = {key: value for key, value in source.items()
                  if key not in RUST_ONLY_TOP_LEVEL_KEYS}
        record = by_world.get(world["worldID"])
        if record is None:
            print("FAIL world=%s: no record in the authoritative snapshot" % world["worldID"])
            failures += 1
            continue
        checked += 1
        authority_state = record.get("state")
        if authority_state is None:
            print("FAIL world=%s: snapshot entry has no `state`" % world["worldID"])
            failures += 1
            continue
        authority_state = {key: value for key, value in authority_state.items()
                           if key not in RUST_ONLY_TOP_LEVEL_KEYS}

        diff = Diff()
        compare_value(source, authority_state, "", diff)
        source_hash = projection_sha256(source)
        authority_hash = projection_sha256(authority_state)
        objects = len(source.get("objectStates") or {})
        displayed = args.max_differences
        if diff.paths:
            failures += 1
            print("FAIL world=%s objects=%d differences=%d leaves=%d" % (
                world["worldID"], objects, len(diff.paths), diff.leaves))
            for item in diff.paths[:displayed]:
                print("  path=%s expected=%r actual=%r %s" % (
                    item["path"], item["expected"], item["actual"], item["note"]))
            if len(diff.paths) > displayed:
                print("  ... %d more" % (len(diff.paths) - displayed))
            print("  source sha256=%s authority sha256=%s" % (source_hash, authority_hash))
        else:
            print("PASS world=%s objects=%d layoutRevision=%s revision=%s fields=%d "
                  "sha256=%s authorityRecordRevision=%s boundarySeq=%s" % (
                      world["worldID"], objects, source.get("layoutRevision"),
                      source.get("revision"), diff.leaves, source_hash,
                      record.get("recordRevision"), record.get("boundarySeq")))
            if diff.normalized_opaque:
                print("  normalized opaque JSON metadata blobs=%d (key order inside the "
                      "string differs; parsed content equal)" % diff.normalized_opaque)

    if args.expect is not None and checked != args.expect:
        print("FAIL expected %d worlds, compared %d" % (args.expect, checked))
        failures += 1
    if failures:
        print("COMPARE FAIL worlds=%d failures=%d" % (checked, failures))
        return 1
    print("COMPARE PASS worlds=%d failures=0" % checked)
    return 0


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------

def repo_root() -> str:
    return os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    export = sub.add_parser("export", help="copy every live state.json into a bundle")
    export.add_argument("--living-world-root", default=os.path.join(
        "~", "Library", "Application Support", "ai.gmgn.radio", "LivingWorld"))
    export.add_argument("--out", default=None)
    export.add_argument("--stamp", default=None)
    export.add_argument("--worlds-root", default=None,
                        help="bundled Resources/Worlds directory, used to resolve which "
                             "package version is current")
    export.add_argument("--repo-root", default=repo_root())
    export.set_defaults(func=cmd_export)

    canonical = sub.add_parser("canonicalize", help="bundle -> worlds.json import payload")
    canonical.add_argument("--bundle", required=True)
    canonical.add_argument("--out", required=True)
    canonical.set_defaults(func=cmd_canonicalize)

    compare = sub.add_parser("compare", help="source state.json vs Rust authority snapshot")
    compare.add_argument("--bundle", required=True)
    compare.add_argument("--snapshot", required=True)
    compare.add_argument("--expect", type=int, default=None)
    compare.add_argument("--max-differences", type=int, default=20)
    compare.set_defaults(func=cmd_compare)

    args = parser.parse_args(argv)
    if args.command == "export" and not args.worlds_root:
        args.worlds_root = os.path.join(args.repo_root, "apps", "macos", "Resources", "Worlds")
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
