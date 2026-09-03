#!/usr/bin/env python3
"""Validate an exported GMGN world package without Blender or Swift."""

from __future__ import annotations

import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any


REQUIRED_KEYS = {
    "schemaVersion",
    "packageID",
    "packageVersion",
    "worldID",
    "displayName",
    "calibration",
    "spawn",
    "collisionVolumes",
    "waypoints",
    "routes",
    "activities",
    "cameras",
    "capabilities",
    "resources",
}
ID_COLLECTIONS = (
    "collisionVolumes",
    "waypoints",
    "routes",
    "activities",
    "cameras",
    "resources",
)
ACTIVITY_PHASES = (
    "approach",
    "enter",
    "loop",
    "exit",
    "interrupt",
    "failed",
)
ACTIVITY_TYPE_ALIASES = {
    "listen-to-music": "listenMusic",
    "listen_music": "listenMusic",
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _items(manifest: dict[str, Any], key: str, findings: list[str]) -> list[dict[str, Any]]:
    value = manifest.get(key)
    if not isinstance(value, list):
        findings.append(f"{key} must be an array")
        return []
    result = []
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            findings.append(f"{key}[{index}] must be an object")
        else:
            result.append(item)
    return result


def _position(value: Any) -> tuple[float, float, float] | None:
    if not isinstance(value, dict):
        return None
    components = tuple(value.get(axis) for axis in ("x", "y", "z"))
    if any(
        not isinstance(component, (int, float))
        or isinstance(component, bool)
        or not math.isfinite(component)
        for component in components
    ):
        return None
    return components


def validate_manifest(manifest: dict[str, Any], package_root: Path) -> list[str]:
    findings: list[str] = []
    missing_keys = sorted(REQUIRED_KEYS - manifest.keys())
    findings.extend(f"manifest is missing {key}" for key in missing_keys)
    if manifest.get("schemaVersion") != 1:
        findings.append(f"unsupported schemaVersion {manifest.get('schemaVersion')!r}")

    calibration = manifest.get("calibration")
    if not isinstance(calibration, dict):
        findings.append("calibration must be an object")
    else:
        matrix = calibration.get("visualToGameplay")
        if (
            not isinstance(matrix, list)
            or len(matrix) != 16
            or any(
                not isinstance(value, (int, float))
                or isinstance(value, bool)
                or not math.isfinite(value)
                for value in matrix
            )
        ):
            findings.append(
                "calibration.visualToGameplay must contain 16 finite numbers"
            )
        meters = calibration.get("metersPerUnit")
        if (
            not isinstance(meters, (int, float))
            or isinstance(meters, bool)
            or not math.isfinite(meters)
            or meters <= 0
        ):
            findings.append("calibration.metersPerUnit must be positive and finite")

    collections = {key: _items(manifest, key, findings) for key in ID_COLLECTIONS}
    id_counts: dict[str, int] = {}
    id_memberships: dict[str, set[str]] = {}
    for key in ID_COLLECTIONS:
        for index, item in enumerate(collections[key]):
            stable_id = item.get("id")
            if not isinstance(stable_id, str) or not stable_id:
                findings.append(f"{key}[{index}] has invalid id")
                continue
            id_counts[stable_id] = id_counts.get(stable_id, 0) + 1
            id_memberships.setdefault(stable_id, set()).add(key)

    for stable_id in sorted(id_counts):
        if id_counts[stable_id] <= 1:
            continue
        collection_names = ",".join(
            key for key in ID_COLLECTIONS if key in id_memberships[stable_id]
        )
        findings.append(f"duplicate id {stable_id} in {collection_names}")

    waypoint_ids = {
        item["id"] for item in collections["waypoints"] if isinstance(item.get("id"), str)
    }
    waypoints_by_id = {
        item["id"]: item
        for item in collections["waypoints"]
        if isinstance(item.get("id"), str)
    }
    activity_ids = {
        item["id"] for item in collections["activities"] if isinstance(item.get("id"), str)
    }
    camera_ids = {
        item["id"] for item in collections["cameras"] if isinstance(item.get("id"), str)
    }
    resource_ids = {
        item["id"] for item in collections["resources"] if isinstance(item.get("id"), str)
    }

    route_findings: list[str] = []
    for route in collections["routes"]:
        route_id = route.get("id", "<unknown>")
        waypoint_references = route.get("waypointIDs")
        if not isinstance(waypoint_references, list) or not waypoint_references:
            route_findings.append(f"route {route_id} must contain waypointIDs")
            continue
        for waypoint_id in waypoint_references:
            if waypoint_id not in waypoint_ids:
                route_findings.append(
                    f"route {route_id} references missing waypoint {waypoint_id}"
                )
    findings.extend(sorted(set(route_findings)))

    activity_entry_findings: list[str] = []
    activity_transform_findings: list[str] = []
    activity_prop_findings: list[str] = []
    for activity in collections["activities"]:
        activity_id = activity.get("id", "<unknown>")
        entry = activity.get("entryWaypointID")
        if entry not in waypoint_ids:
            activity_entry_findings.append(
                f"activity {activity_id} references missing entry waypoint {entry}"
            )
        else:
            activity_position = _position(
                activity.get("transform", {}).get("position")
                if isinstance(activity.get("transform"), dict)
                else None
            )
            waypoint_position = _position(waypoints_by_id[entry].get("position"))
            if activity_position is not None and waypoint_position is not None:
                distance = math.dist(activity_position, waypoint_position)
                if distance > 0.08:
                    activity_transform_findings.append(
                        f"activity {activity_id} transform is {distance:.3f}m "
                        f"from entry waypoint {entry}; maximum is 0.080m"
                    )
        prop_ids = activity.get("propIDs", [])
        if not isinstance(prop_ids, list):
            activity_prop_findings.append(
                f"activity {activity_id} propIDs must be an array"
            )
        else:
            for prop_id in prop_ids:
                if prop_id not in resource_ids:
                    activity_prop_findings.append(
                        f"activity {activity_id} references missing prop {prop_id}"
                    )
    findings.extend(sorted(set(activity_entry_findings)))
    findings.extend(sorted(set(activity_transform_findings)))
    findings.extend(sorted(set(activity_prop_findings)))

    if "activityDefinitions" in manifest:
        definitions = _items(manifest, "activityDefinitions", findings)
        anchors_by_id = {
            item["id"]: item
            for item in collections["activities"]
            if isinstance(item.get("id"), str)
        }
        definitions_by_id: dict[str, list[dict[str, Any]]] = {}
        for index, definition in enumerate(definitions):
            definition_id = definition.get("id")
            if not isinstance(definition_id, str) or not definition_id:
                findings.append(f"activityDefinitions[{index}] has invalid id")
                continue
            definitions_by_id.setdefault(definition_id, []).append(definition)

        anchor_ids = set(anchors_by_id)
        for activity_id in sorted(anchor_ids):
            matching = definitions_by_id.get(activity_id, [])
            if not matching:
                findings.append(f"activity {activity_id} has no definition")
        for activity_id in sorted(anchor_ids):
            if len(definitions_by_id.get(activity_id, [])) > 1:
                findings.append(f"activity {activity_id} has duplicate definitions")
        for activity_id in sorted(set(definitions_by_id) - anchor_ids):
            findings.append(f"activity definition {activity_id} has no anchor")

        for activity_id in sorted(anchor_ids):
            matching = definitions_by_id.get(activity_id, [])
            if len(matching) != 1:
                continue
            anchor_action = anchors_by_id[activity_id].get("action")
            canonical_action = ACTIVITY_TYPE_ALIASES.get(anchor_action, anchor_action)
            activity = matching[0].get("activity")
            definition_action = (
                activity.get("type") if isinstance(activity, dict) else None
            )
            if canonical_action != definition_action:
                findings.append(
                    f"activity {activity_id} action {anchor_action} "
                    f"does not match definition {definition_action}"
                )
            if definition_action == "walk" and isinstance(activity, dict):
                destination = activity.get("destinationID")
                entry = anchors_by_id[activity_id].get("entryWaypointID")
                if destination != entry:
                    findings.append(
                        f"activity {activity_id} walk destination {destination} "
                        f"does not match entry waypoint {entry}"
                    )

        missing_phases_by_id: dict[str, set[str]] = {}
        duplicate_phases_by_id: dict[str, set[str]] = {}
        for definition in definitions:
            definition_id = definition.get("id")
            if not isinstance(definition_id, str) or not definition_id:
                continue
            phases = definition.get("phases")
            phase_counts: dict[str, int] = {}
            if isinstance(phases, list):
                for phase_contract in phases:
                    if not isinstance(phase_contract, dict):
                        continue
                    phase = phase_contract.get("phase")
                    if isinstance(phase, str):
                        phase_counts[phase] = phase_counts.get(phase, 0) + 1
            for phase in ACTIVITY_PHASES:
                count = phase_counts.get(phase, 0)
                if count == 0:
                    missing_phases_by_id.setdefault(definition_id, set()).add(phase)
                elif count > 1:
                    duplicate_phases_by_id.setdefault(definition_id, set()).add(phase)

        for activity_id in sorted(missing_phases_by_id):
            for phase in ACTIVITY_PHASES:
                if phase in missing_phases_by_id[activity_id]:
                    findings.append(
                        f"activity definition {activity_id} is missing phase {phase}"
                    )
        for activity_id in sorted(duplicate_phases_by_id):
            for phase in ACTIVITY_PHASES:
                if phase in duplicate_phases_by_id[activity_id]:
                    findings.append(
                        f"activity definition {activity_id} has duplicate phase {phase}"
                    )

    camera_findings: list[str] = []
    for camera in collections["cameras"]:
        camera_id = camera.get("id", "<unknown>")
        near = camera.get("nearPlane")
        far = camera.get("farPlane")
        if (
            not isinstance(near, (int, float))
            or isinstance(near, bool)
            or not isinstance(far, (int, float))
            or isinstance(far, bool)
            or not math.isfinite(near)
            or not math.isfinite(far)
            or not 0 < near < far
        ):
            camera_findings.append(
                f"camera {camera_id} must satisfy 0 < nearPlane < farPlane"
            )
    findings.extend(sorted(set(camera_findings)))

    capabilities = manifest.get("capabilities")
    capability_findings: list[str] = []
    if not isinstance(capabilities, list):
        capability_findings.append("capabilities must be an array")
    else:
        for capability in capabilities:
            if not isinstance(capability, str):
                capability_findings.append("capability values must be strings")
            elif capability.startswith("activity:"):
                target = capability.removeprefix("activity:")
                if target not in activity_ids:
                    capability_findings.append(
                        f"capability {capability} has no matching activity"
                    )
            elif capability.startswith("camera:"):
                target = capability.removeprefix("camera:")
                if target not in camera_ids:
                    capability_findings.append(
                        f"capability {capability} has no matching camera"
                    )
            else:
                capability_findings.append(f"unsupported capability {capability}")

    root = package_root.resolve()
    resource_findings: list[str] = []
    for resource in sorted(
        collections["resources"],
        key=lambda value: (
            str(value.get("id", "")),
            str(value.get("path", "")),
            str(value.get("sha256", "")),
            str(value.get("kind", "")),
        ),
    ):
        resource_id = resource.get("id", "<unknown>")
        relative = resource.get("path")
        if not isinstance(relative, str) or not relative:
            resource_findings.append(f"resource {resource_id} has invalid path")
            continue
        candidate = (root / relative).resolve()
        try:
            candidate.relative_to(root)
        except ValueError:
            resource_findings.append(
                f"resource {resource_id} path escapes package root"
            )
            continue
        if not candidate.is_file():
            resource_findings.append(f"resource {resource_id} file is missing")
            continue
        expected_hash = resource.get("sha256")
        if not isinstance(expected_hash, str) or _sha256(candidate) != expected_hash.lower():
            resource_findings.append(f"resource {resource_id} SHA-256 mismatch")
    findings.extend(resource_findings)
    findings.extend(sorted(set(capability_findings)))

    return list(dict.fromkeys(findings))


def validate_package(package_root: Path) -> list[str]:
    manifest_path = package_root / "world.json"
    if not manifest_path.is_file():
        return ["world.json is missing"]
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        return [f"world.json cannot be decoded: {error}"]
    if not isinstance(manifest, dict):
        return ["world.json root must be an object"]
    return validate_manifest(manifest, package_root)


def main(arguments: list[str] | None = None) -> int:
    args = (arguments or sys.argv)[1:]
    if len(args) != 1:
        print("usage: validate_gmgn_world.py PACKAGE_DIRECTORY", file=sys.stderr)
        return 2
    package_root = Path(args[0])
    findings = validate_package(package_root)
    if findings:
        for finding in findings:
            print(f"FAIL {finding}")
        return 1

    manifest = json.loads((package_root / "world.json").read_text(encoding="utf-8"))
    print(f"PASS {manifest['packageID']}@{manifest['packageVersion']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
