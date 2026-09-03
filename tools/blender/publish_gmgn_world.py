#!/usr/bin/env python3
"""Publish a verified generated navigation graph as a bundled world package.

The navigation baker exports a round-trip package that still carries the
original manual routes. This publisher is the explicit promotion gate between
the verified authoring graph and the bundled ``world.json`` the macOS app
ships with: it re-validates the input, requires a semantic package version,
proves that the auto graph alone (``route.auto.*`` routes) reaches every
activity entry from ``wp.spawn``, stamps the new ``packageVersion``, and
switches the package to auto navigation by preserving but disabling every
route whose id does not start with ``route.auto.``.

The output is written canonically (sorted keys, two-space indent, trailing
newline) and atomically (temp file in the destination directory plus
``os.replace``), so a partially written package is never observable and the
bytes are deterministic. If the sibling temp file cannot be created or
replaced, publishing fails without falling back to a partial direct write. An
existing output is refused without ``--force`` and is left byte-identical on
refusal.

CLI::

    python3 tools/blender/publish_gmgn_world.py \\
        --source authoring/worlds/warm-kitchen-canary/roundtrip/world.json \\
        --output apps/macos/Resources/Worlds/warm-kitchen-canary/world.json \\
        --package-version 1.2.0 \\
        --force

``--source`` accepts either a ``world.json`` file or a package directory that
contains one. ``--package-version`` must be a semantic version
(``major.minor.patch`` with optional ``-prerelease`` and ``+build``).
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    from validate_gmgn_world import validate_manifest
except ImportError:  # pragma: no cover - sibling lookup fallback
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from validate_gmgn_world import validate_manifest


#: Strict semver 2.0.0 grammar: X.Y.Z with optional -prerelease and +build.
SEMVER_PATTERN = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"
)

AUTO_ROUTE_PREFIX = "route.auto."
SPAWN_WAYPOINT_ID = "wp.spawn"


class PublishError(ValueError):
    """Raised when the source cannot be promoted into a bundled package."""


def is_semantic_version(version: str) -> bool:
    return bool(SEMVER_PATTERN.match(version))


def _waypoint_ids(manifest: dict[str, Any]) -> set[str]:
    waypoints = manifest.get("waypoints")
    if not isinstance(waypoints, list):
        return set()
    return {
        item.get("id")
        for item in waypoints
        if isinstance(item.get("id"), str)
        and item.get("enabled", True) is not False
    }


def _auto_adjacency(manifest: dict[str, Any]) -> dict[str, list[str]]:
    """Undirected adjacency over enabled waypoints using auto routes only."""
    waypoint_ids = _waypoint_ids(manifest)
    adjacency: dict[str, list[str]] = {waypoint_id: [] for waypoint_id in waypoint_ids}
    routes = manifest.get("routes")
    if not isinstance(routes, list):
        return adjacency
    for route in routes:
        if not isinstance(route, dict):
            continue
        if route.get("enabled", True) is False:
            continue
        if not isinstance(route.get("id"), str) or not route["id"].startswith(
            AUTO_ROUTE_PREFIX
        ):
            continue
        references = route.get("waypointIDs")
        if not isinstance(references, list):
            continue
        bidirectional = route.get("bidirectional", True) is not False
        for first, second in zip(references, references[1:]):
            if first not in waypoint_ids or second not in waypoint_ids:
                continue
            adjacency.setdefault(first, []).append(second)
            if bidirectional:
                adjacency.setdefault(second, []).append(first)
    return adjacency


def auto_only_reachability_findings(
    manifest: dict[str, Any],
) -> list[str]:
    """Require every activity entry to be reachable from spawn using only
    enabled ``route.auto.*`` edges."""
    waypoint_ids = _waypoint_ids(manifest)
    adjacency = _auto_adjacency(manifest)
    if SPAWN_WAYPOINT_ID not in waypoint_ids:
        return ["spawn waypoint wp.spawn is missing or disabled"]

    reachable: set[str] = set()
    queue = [SPAWN_WAYPOINT_ID]
    while queue:
        current = queue.pop(0)
        if current in reachable:
            continue
        reachable.add(current)
        for neighbor in adjacency.get(current, []):
            if neighbor not in reachable:
                queue.append(neighbor)

    activities = manifest.get("activities")
    entries: set[str] = set()
    if isinstance(activities, list):
        entries = {
            activity.get("entryWaypointID")
            for activity in activities
            if isinstance(activity, dict)
            and isinstance(activity.get("entryWaypointID"), str)
        }
    return [
        f"activity entry {entry} is unreachable from {SPAWN_WAYPOINT_ID} "
        "through auto routes only"
        for entry in sorted(entries)
        if entry not in reachable
    ]


def prepare_published_manifest(
    manifest: dict[str, Any],
    package_version: str,
) -> dict[str, Any]:
    """Deep-copy the manifest, stamp the new version and switch routes to the
    auto graph: auto routes stay enabled, every legacy route is preserved but
    disabled."""
    published = json.loads(json.dumps(manifest, ensure_ascii=False))
    published["packageVersion"] = package_version
    routes = published.get("routes")
    if isinstance(routes, list):
        for route in routes:
            if not isinstance(route, dict):
                continue
            route_id = route.get("id", "")
            if isinstance(route_id, str) and route_id.startswith(AUTO_ROUTE_PREFIX):
                route["enabled"] = True
            else:
                route["enabled"] = False
    return published


def write_manifest_atomically(manifest: dict[str, Any], output_path: Path) -> None:
    """Write canonical JSON to a sibling temp file and atomically replace the
    destination, matching the exporter's stable bytes.

    Failure to create or replace the sibling temp file is propagated. Directly
    overwriting the destination would make a truncated package observable.
    """
    output_path.parent.mkdir(parents=True, exist_ok=True)
    payload = (
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    file_descriptor, temporary_name = tempfile.mkstemp(
        dir=output_path.parent,
        prefix=".world.json.",
        suffix=".tmp",
    )
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as file:
            file.write(payload)
            file.flush()
            os.fsync(file.fileno())
        os.replace(temporary_name, output_path)
    except OSError:
        try:
            os.unlink(temporary_name)
        except OSError:
            pass
        raise


def _load_manifest(source: Path) -> tuple[dict[str, Any], Path]:
    source_path = source
    if source.is_dir():
        source_path = source / "world.json"
    if not source_path.is_file():
        raise PublishError(f"source manifest does not exist: {source_path}")
    try:
        manifest = json.loads(source_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PublishError(f"source manifest cannot be decoded: {error}") from error
    if not isinstance(manifest, dict):
        raise PublishError("source manifest root must be an object")
    return manifest, source_path


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="publish_gmgn_world.py",
        description=(
            "Promote a verified generated navigation graph into a bundled "
            "world.json package."
        ),
    )
    parser.add_argument(
        "--source",
        required=True,
        help="source world.json file or package directory",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="world.json file to write",
    )
    parser.add_argument(
        "--package-version",
        required=True,
        help="semantic package version to stamp on the published package",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing output file",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    try:
        parsed_arguments = list(arguments) if arguments is not None else sys.argv[1:]
        args = _parse_args(parsed_arguments)
    except SystemExit:
        return 2

    output_path = Path(args.output)
    if output_path.exists() and not args.force:
        print(
            f"ERROR output already exists: {args.output}; "
            "pass --force to overwrite",
            file=sys.stderr,
        )
        return 1

    if not is_semantic_version(args.package_version):
        print(
            f"ERROR --package-version {args.package_version!r} is not a "
            "semantic version (expected X.Y.Z with optional -prerelease/+build)",
            file=sys.stderr,
        )
        return 1

    try:
        manifest, source_path = _load_manifest(Path(args.source))
    except PublishError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1

    findings = validate_manifest(manifest, source_path.parent)
    if findings:
        for finding in findings:
            print(f"FAIL {finding}", file=sys.stderr)
        return 1

    reachability_findings = auto_only_reachability_findings(manifest)
    if reachability_findings:
        for finding in reachability_findings:
            print(f"FAIL {finding}", file=sys.stderr)
        return 1

    published = prepare_published_manifest(manifest, args.package_version)

    # The transformed package must still validate: disabling legacy routes and
    # re-versioning must never produce an invalid bundled package.
    final_findings = validate_manifest(published, source_path.parent)
    if final_findings:
        for finding in final_findings:
            print(f"FAIL {finding}", file=sys.stderr)
        return 1

    try:
        write_manifest_atomically(published, output_path)
    except OSError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1
    print(
        f"PUBLISHED {published['packageID']}@{published['packageVersion']} "
        f"-> {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
