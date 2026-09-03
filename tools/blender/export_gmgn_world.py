#!/usr/bin/env python3
"""Export GMGN living-world gameplay metadata from a Blender scene.

The module intentionally imports ``bpy`` only in its command-line entry point so
its deterministic transformation logic can be tested with a small mocked scene.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
COLLECTION_NAMES = (
    "GMGN_COLLISION",
    "GMGN_WAYPOINTS",
    "GMGN_ROUTES",
    "GMGN_ACTIVITIES",
    "GMGN_CAMERAS",
    "GMGN_PROPS",
)
VISUAL_TO_GAMEPLAY = [
    1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
    0.0,
    0.0,
    -1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
]
ACTIVITY_PHASES = ("approach", "enter", "loop", "exit", "interrupt", "failed")
CANONICAL_ACTIONS = {
    "idle", "walk", "turn", "sit", "gaze", "listenMusic", "interact"
}
LEGACY_ACTION_ALIASES = {
    "listen-to-music": "listenMusic",
    "listen_music": "listenMusic",
}

#: Radians of drift tolerated before the exporter considers an authored
#: yaw/pitch still equal to the values recorded at import time. Within this
#: window the exact stored source quaternion (including roll) is reused, so a
#: round trip stays lossless; any real authoring edit exceeds it and falls
#: back to the current authored yaw/pitch conversion.
QUATERNION_SOURCE_MATCH_TOLERANCE = 1e-4


class ExportError(ValueError):
    """Raised when authored metadata cannot produce an unambiguous package."""


def _property(source: Any, key: str, default: Any = None) -> Any:
    if hasattr(source, "get"):
        value = source.get(key, default)
        if value is not default:
            return value
    properties = getattr(source, "properties", None)
    if isinstance(properties, dict):
        return properties.get(key, default)
    return default


def _required_property(source: Any, key: str) -> Any:
    value = _property(source, key)
    if value is None or (isinstance(value, str) and not value.strip()):
        name = getattr(source, "name", "scene")
        raise ExportError(f"{name} is missing required custom property {key}")
    return value


def _objects(scene: Any, collection_name: str) -> list[Any]:
    collection = scene.collections.get(collection_name)
    if collection is None:
        return []
    return list(collection.objects)


def _float(value: Any, *, property_name: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as error:
        raise ExportError(f"{property_name} must be numeric") from error
    if not math.isfinite(result):
        raise ExportError(f"{property_name} must be finite")
    return result


def _bool(value: Any, *, property_name: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in ("true", "1", "yes"):
            return True
        if normalized in ("false", "0", "no"):
            return False
    raise ExportError(f"{property_name} must be a boolean")


def _string_list(value: Any, *, property_name: str) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        items = value.split(",")
    elif isinstance(value, Iterable):
        items = list(value)
    else:
        raise ExportError(f"{property_name} must be a comma-separated string or list")
    result = [str(item).strip() for item in items if str(item).strip()]
    if len(result) != len(set(result)):
        raise ExportError(f"{property_name} contains duplicate values")
    return result


def _vector(vector: Any) -> dict[str, float]:
    """Convert Blender's right-handed Z-up coordinates to Y-up gameplay."""
    return {
        "x": _float(vector.x, property_name="vector.x"),
        "y": _float(vector.z, property_name="vector.z"),
        "z": -_float(vector.y, property_name="vector.y"),
    }


def _scale(vector: Any) -> dict[str, float]:
    return {
        "x": abs(_float(vector.x, property_name="scale.x")),
        "y": abs(_float(vector.z, property_name="scale.z")),
        "z": abs(_float(vector.y, property_name="scale.y")),
    }


def _rotation(marker: Any) -> dict[str, float]:
    yaw = _float(getattr(marker.rotation_euler, "z", 0.0), property_name="rotation.z")
    pitch = _float(_property(marker, "gmgn.pitch", 0.0), property_name="gmgn.pitch")

    source_quaternion = _property(marker, "gmgn.source_quaternion")
    source_yaw = _property(marker, "gmgn.source_yaw")
    source_pitch = _property(marker, "gmgn.source_pitch")
    if (
        source_quaternion is not None
        and source_yaw is not None
        and source_pitch is not None
    ):
        source_yaw = _float(source_yaw, property_name="gmgn.source_yaw")
        source_pitch = _float(source_pitch, property_name="gmgn.source_pitch")
        unchanged = math.isclose(
            yaw,
            source_yaw,
            rel_tol=0.0,
            abs_tol=QUATERNION_SOURCE_MATCH_TOLERANCE,
        ) and math.isclose(
            pitch,
            source_pitch,
            rel_tol=0.0,
            abs_tol=QUATERNION_SOURCE_MATCH_TOLERANCE,
        )
        if unchanged:
            try:
                components = [float(value) for value in source_quaternion]
            except (TypeError, ValueError) as error:
                raise ExportError(
                    "gmgn.source_quaternion must contain 4 numbers"
                ) from error
            if len(components) != 4 or not all(
                math.isfinite(value) for value in components
            ):
                raise ExportError(
                    "gmgn.source_quaternion must contain 4 finite numbers"
                )
            return {
                "w": components[0],
                "x": components[1],
                "y": components[2],
                "z": components[3],
            }

    half_yaw = yaw * 0.5
    half_pitch = pitch * 0.5
    return {
        "x": math.sin(half_pitch) * math.cos(half_yaw),
        "y": math.cos(half_pitch) * math.sin(half_yaw),
        "z": math.sin(half_pitch) * math.sin(half_yaw),
        "w": math.cos(half_pitch) * math.cos(half_yaw),
    }


def _transform(marker: Any) -> dict[str, Any]:
    scale = getattr(marker, "scale", None)
    if scale is None:
        scale_value = {"x": 1.0, "y": 1.0, "z": 1.0}
    else:
        scale_value = _scale(scale)
    return {
        "position": _vector(marker.location),
        "rotation": _rotation(marker),
        "scale": scale_value,
    }


def _stable_id(marker: Any) -> str:
    return str(_required_property(marker, "gmgn.id")).strip()


def _sorted_markers(scene: Any, collection_name: str) -> list[Any]:
    return sorted(_objects(scene, collection_name), key=_stable_id)


def _register_ids(scene: Any) -> None:
    seen: dict[str, str] = {}
    for collection_name in COLLECTION_NAMES:
        for marker in _objects(scene, collection_name):
            stable_id = _stable_id(marker)
            if stable_id in seen:
                raise ExportError(
                    f"duplicate gmgn.id '{stable_id}' in {seen[stable_id]} and {collection_name}"
                )
            seen[stable_id] = collection_name


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _collision(marker: Any) -> dict[str, Any]:
    dimensions = _scale(marker.dimensions)
    return {
        "id": _stable_id(marker),
        "center": _vector(marker.location),
        "halfExtents": {axis: value * 0.5 for axis, value in dimensions.items()},
        "rotation": _rotation(marker),
        "isBlocking": _bool(
            _property(marker, "gmgn.blocking", True), property_name="gmgn.blocking"
        ),
    }


def _waypoint(marker: Any) -> dict[str, Any]:
    return {
        "id": _stable_id(marker),
        "position": _vector(marker.location),
        "arrivalRadius": _float(
            _property(marker, "gmgn.arrival_radius", 0.2),
            property_name="gmgn.arrival_radius",
        ),
        "enabled": _bool(
            _property(marker, "gmgn.enabled", True), property_name="gmgn.enabled"
        ),
    }


def _route(marker: Any) -> dict[str, Any]:
    return {
        "id": _stable_id(marker),
        "waypointIDs": _string_list(
            _required_property(marker, "gmgn.waypoints"),
            property_name="gmgn.waypoints",
        ),
        "bidirectional": _bool(
            _property(marker, "gmgn.bidirectional", True),
            property_name="gmgn.bidirectional",
        ),
        "enabled": _bool(
            _property(marker, "gmgn.enabled", True), property_name="gmgn.enabled"
        ),
    }


def _canonical_action(marker: Any) -> str:
    authored = str(_required_property(marker, "gmgn.action")).strip()
    action = LEGACY_ACTION_ALIASES.get(authored, authored)
    if action not in CANONICAL_ACTIONS:
        raise ExportError(
            f"{getattr(marker, 'name', 'activity')} has unsupported gmgn.action '{authored}'"
        )
    return action


def _activity(marker: Any) -> dict[str, Any]:
    motion = _property(marker, "gmgn.motion")
    return {
        "id": _stable_id(marker),
        "action": _canonical_action(marker),
        "entryWaypointID": str(_required_property(marker, "gmgn.entry")).strip(),
        "transform": _transform(marker),
        "motionID": str(motion).strip() if motion else None,
        "propIDs": _string_list(
            _property(marker, "gmgn.props", []), property_name="gmgn.props"
        ),
        "interruptible": _bool(
            _property(marker, "gmgn.interruptible", True),
            property_name="gmgn.interruptible",
        ),
    }


def _life_activity(marker: Any, action: str) -> dict[str, Any]:
    activity: dict[str, Any] = {"type": action}
    anchor_id = _stable_id(marker)
    entry_id = str(_required_property(marker, "gmgn.entry")).strip()

    if action == "walk":
        activity["destinationID"] = str(
            _property(marker, "gmgn.destination", entry_id)
        ).strip()
    elif action == "turn":
        activity["targetYaw"] = _float(
            _property(marker, "gmgn.target_yaw", marker.rotation_euler.z),
            property_name="gmgn.target_yaw",
        )
    elif action in ("sit", "listenMusic", "interact"):
        activity["anchorID"] = str(
            _property(marker, "gmgn.anchor", anchor_id)
        ).strip()
    elif action == "gaze":
        activity["targetID"] = str(
            _property(marker, "gmgn.target", anchor_id)
        ).strip()
    return activity


def _activity_phase(
    marker: Any,
    phase: str,
    *,
    action: str,
    motion_id: str | None,
    prop_ids: list[str],
) -> dict[str, Any]:
    default_anchors = (
        [_stable_id(marker)]
        if phase == "approach"
        and action in ("walk", "sit", "listenMusic", "interact")
        else []
    )
    default_motions = [motion_id] if phase == "loop" and motion_id else []
    default_props = prop_ids if phase == "loop" else []
    duration = _property(marker, f"gmgn.{phase}_duration")
    return {
        "phase": phase,
        "requiredAnchorIDs": _string_list(
            _property(marker, f"gmgn.{phase}_anchors", default_anchors),
            property_name=f"gmgn.{phase}_anchors",
        ),
        "motionIDs": _string_list(
            _property(marker, f"gmgn.{phase}_motions", default_motions),
            property_name=f"gmgn.{phase}_motions",
        ),
        "propIDs": _string_list(
            _property(marker, f"gmgn.{phase}_props", default_props),
            property_name=f"gmgn.{phase}_props",
        ),
        "durationSeconds": (
            _float(duration, property_name=f"gmgn.{phase}_duration")
            if duration is not None
            else None
        ),
    }


def _activity_definition(marker: Any) -> dict[str, Any]:
    action = _canonical_action(marker)
    motion = _property(marker, "gmgn.motion")
    motion_id = str(motion).strip() if motion else None
    prop_ids = _string_list(
        _property(marker, "gmgn.props", []), property_name="gmgn.props"
    )
    definition: dict[str, Any] = {
        "id": _stable_id(marker),
        "activity": _life_activity(marker, action),
        "phases": [
            _activity_phase(
                marker,
                phase,
                action=action,
                motion_id=motion_id,
                prop_ids=prop_ids,
            )
            for phase in ACTIVITY_PHASES
        ],
        "interruptible": _bool(
            _property(marker, "gmgn.interruptible", True),
            property_name="gmgn.interruptible",
        ),
        "cooldownSeconds": _float(
            _property(marker, "gmgn.cooldown", 0.0),
            property_name="gmgn.cooldown",
        ),
    }
    display_name = _property(marker, "gmgn.display_name")
    if display_name is not None and str(display_name).strip():
        definition["displayName"] = str(display_name).strip()
    return definition


def _camera(marker: Any) -> dict[str, Any]:
    return {
        "id": _stable_id(marker),
        "transform": _transform(marker),
        "fieldOfViewDegrees": _float(
            _property(marker, "gmgn.fov", 66.0), property_name="gmgn.fov"
        ),
        "nearPlane": _float(
            _property(marker, "gmgn.near", 0.05), property_name="gmgn.near"
        ),
        "farPlane": _float(
            _property(marker, "gmgn.far", 250.0), property_name="gmgn.far"
        ),
    }


def _resource(marker: Any) -> dict[str, str]:
    source_path = Path(str(_required_property(marker, "gmgn.path"))).expanduser()
    if not source_path.is_file():
        raise ExportError(f"resource {_stable_id(marker)} does not exist: {source_path}")
    package_path = str(_required_property(marker, "gmgn.package_path")).strip()
    return {
        "id": _stable_id(marker),
        "kind": str(_required_property(marker, "gmgn.kind")).strip(),
        "path": package_path,
        "sha256": _sha256(source_path),
    }


def build_manifest(scene: Any) -> dict[str, Any]:
    """Build a canonical WorldManifest-compatible dictionary from a scene."""
    _register_ids(scene)

    waypoints = [_waypoint(item) for item in _sorted_markers(scene, "GMGN_WAYPOINTS")]
    spawn_markers = [
        marker
        for marker in _objects(scene, "GMGN_WAYPOINTS")
        if _bool(_property(marker, "gmgn.spawn", False), property_name="gmgn.spawn")
    ]
    if len(spawn_markers) != 1:
        raise ExportError("exactly one GMGN_WAYPOINTS marker must set gmgn.spawn=true")

    activity_markers = _sorted_markers(scene, "GMGN_ACTIVITIES")
    activities = [_activity(item) for item in activity_markers]
    activity_definitions = [_activity_definition(item) for item in activity_markers]
    cameras = [_camera(item) for item in _sorted_markers(scene, "GMGN_CAMERAS")]
    capabilities = [f"activity:{item['id']}" for item in activities]
    capabilities.extend(f"camera:{item['id']}" for item in cameras)
    capabilities.extend(
        _string_list(
            _property(scene, "gmgn.capabilities", []),
            property_name="gmgn.capabilities",
        )
    )

    return {
        "schemaVersion": SCHEMA_VERSION,
        "packageID": str(_required_property(scene, "gmgn.package_id")).strip(),
        "packageVersion": str(_required_property(scene, "gmgn.package_version")).strip(),
        "worldID": str(_required_property(scene, "gmgn.world_id")).strip(),
        "displayName": str(_required_property(scene, "gmgn.display_name")).strip(),
        "calibration": {
            "visualToGameplay": VISUAL_TO_GAMEPLAY,
            "metersPerUnit": _float(
                _property(scene, "gmgn.meters_per_unit", 1.0),
                property_name="gmgn.meters_per_unit",
            ),
        },
        "spawn": _transform(spawn_markers[0]),
        "collisionVolumes": [
            _collision(item) for item in _sorted_markers(scene, "GMGN_COLLISION")
        ],
        "waypoints": waypoints,
        "routes": [_route(item) for item in _sorted_markers(scene, "GMGN_ROUTES")],
        "activities": activities,
        "activityDefinitions": activity_definitions,
        "cameras": cameras,
        "capabilities": sorted(set(capabilities)),
        "resources": [
            _resource(item) for item in _sorted_markers(scene, "GMGN_PROPS")
        ],
    }


def write_manifest(manifest: dict[str, Any], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _arguments_after_double_dash(arguments: list[str]) -> list[str]:
    if "--" in arguments:
        return arguments[arguments.index("--") + 1 :]
    if arguments and not arguments[0].startswith("-"):
        # Plain interpreter invocation: drop the script path, keep flags.
        return arguments[1:]
    return arguments


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="export_gmgn_world.py",
        description=(
            "Export GMGN living-world gameplay metadata from a Blender scene "
            "into a world.json package."
        ),
    )
    parser.add_argument("output", help="world.json file to write")
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing output file",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    try:
        args = _parse_args(_arguments_after_double_dash(arguments or sys.argv))
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
    try:
        import bpy  # type: ignore
    except ImportError:
        print("ERROR this command must run inside Blender", file=sys.stderr)
        return 2

    class BlenderSceneAdapter:
        def __init__(self, scene: Any, collections: Any) -> None:
            self._scene = scene
            self.collections = collections

        def get(self, key: str, default: Any = None) -> Any:
            return self._scene.get(key, default)

    scene = BlenderSceneAdapter(bpy.context.scene, bpy.data.collections)
    try:
        manifest = build_manifest(scene)
        write_manifest(manifest, output_path)
    except (ExportError, OSError) as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1
    print(f"EXPORTED {manifest['packageID']}@{manifest['packageVersion']} -> {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
