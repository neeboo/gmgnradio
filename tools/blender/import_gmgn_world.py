#!/usr/bin/env python3
"""Import a world.json manifest into an editable GMGN Blender authoring scene.

This module is the reverse-import slice of the GLB-to-GMGN compiler. It turns
an already-exported ``world.json`` package back into a fresh, editable Blender
scene so an author can tweak markers, proxy surfaces or bake parameters and
re-export the package without the paid Marble collider-mesh download. It is
split into two layers so its deterministic contract can be tested without
Blender:

* Pure-Python layer (no ``bpy`` import at module level):
  - :func:`load_manifest` decodes the JSON package.
  - :func:`validate_manifest` enforces schemaVersion 1, the required
    package/world/display/spawn keys and arrays, rejects malformed and
    non-finite values and duplicate IDs, and verifies cross-references.
  - :func:`gameplay_to_blender` / :func:`gameplay_scale_to_blender` /
    :func:`quaternion_to_yaw_pitch` convert gameplay Y-up coordinates into the
    exact inverse of ``export_gmgn_world.py`` so a round trip preserves
    transforms.
  - :func:`source_quaternion_props` records the original manifest quaternion
    (with any roll the yaw/pitch space cannot represent) plus the restored
    yaw/pitch, so the exporter reproduces the exact source rotation until an
    author edits either angle.
  - :func:`is_floor_volume` / :func:`floor_proxy_corners` derive editable
    walkable proxy surfaces from authored floor collision volumes.
  - :func:`build_markers` turns the manifest into a Blender-independent marker
    model (``MarkerSpec``).

* Blender layer (``main``): when run inside headless Blender it builds the
  frozen GMGN collections, applies every marker, records package/source
  metadata on the scene, saves the ``.blend`` and optionally exports only the
  ``GMGN_NAV_SOURCE`` proxy surfaces as a standard glTF Binary.

The importer always builds a fresh scaffold from Blender factory settings. If
``--output`` or ``--glb-output`` already exists the run is refused unless
``--force`` is passed.

CLI (after ``--`` so Blender leaves the arguments alone)::

    blender --background --factory-startup \\
        --python tools/blender/import_gmgn_world.py -- \\
        --manifest path/to/world.json \\
        --output path/to/editable.blend \\
        --glb-output path/to/proxy.glb \\
        --force
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path
from typing import Any, Iterable

#: Frozen editable-world collection contract created by this importer.
COLLECTION_NAMES = (
    "GMGN_SOURCE",
    "GMGN_NAV_SOURCE",
    "GMGN_COLLISION",
    "GMGN_WAYPOINTS",
    "GMGN_ROUTES",
    "GMGN_ACTIVITIES",
    "GMGN_CAMERAS",
    "GMGN_PROPS",
)

#: Manifest schema this importer understands.
SCHEMA_VERSION = 1

#: Keys the exporter always writes; every one is required on import.
REQUIRED_MANIFEST_KEYS = (
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
    "activityDefinitions",
    "cameras",
    "capabilities",
    "resources",
)

ARRAY_KEYS = (
    "collisionVolumes",
    "waypoints",
    "routes",
    "activities",
    "activityDefinitions",
    "cameras",
    "resources",
    "capabilities",
)

#: The six phase contracts every activity definition carries.
ACTIVITY_PHASES = ("approach", "enter", "loop", "exit", "interrupt", "failed")

#: Version string recorded as scene metadata (``gmgn.importer_version``) and on
#: every proxy/helper object this importer creates.
IMPORTER_VERSION = "world-importer-v1"

# The navigation baker owns these stable manifest ID namespaces. Preserve that
# ownership when reverse-importing a previously baked package so the next bake
# removes the old graph before writing its replacement.
NAVIGATION_BAKER_GENERATED_BY = "navigation-baker-v1"

CANONICAL_ACTIONS = {
    "idle", "walk", "turn", "sit", "gaze", "listenMusic", "interact"
}
LEGACY_ACTION_ALIASES = {
    "listen-to-music": "listenMusic",
    "listen_music": "listenMusic",
}

#: Tolerance (gameplay meters) deciding whether a waypoint position matches the
#: manifest ``spawn`` transform when there is no ``wp.spawn`` marker.
_SPAWN_POSITION_TOLERANCE = 1e-6


class WorldImportError(ValueError):
    """Raised when a manifest cannot be decoded or imported."""


class MarkerSpec:
    """Blender-independent description of one marker or mesh to create."""

    __slots__ = (
        "collection",
        "object_name",
        "location",
        "rotation_euler",
        "scale",
        "properties",
        "mesh_kind",
        "mesh_size",
        "polygon_vertices",
        "hidden",
        "locked",
    )

    def __init__(
        self,
        collection: str,
        object_name: str,
        location: tuple[float, float, float],
        rotation_euler: tuple[float, float, float],
        scale: tuple[float, float, float] | None,
        properties: dict[str, Any],
        *,
        mesh_kind: str = "empty",
        mesh_size: tuple[float, float, float] | None = None,
        polygon_vertices: list[tuple[float, float, float]] | None = None,
        hidden: bool = False,
        locked: bool = False,
    ) -> None:
        self.collection = collection
        self.object_name = object_name
        self.location = location
        self.rotation_euler = rotation_euler
        self.scale = scale
        self.properties = properties
        self.mesh_kind = mesh_kind
        self.mesh_size = mesh_size
        self.polygon_vertices = polygon_vertices
        self.hidden = hidden
        self.locked = locked


# ---------------------------------------------------------------------------
# Pure validation layer
# ---------------------------------------------------------------------------


def _finite_number(value: Any, name: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as error:
        raise WorldImportError(f"{name} must be numeric") from error
    if not math.isfinite(result):
        raise WorldImportError(f"{name} must be finite")
    return result


def _vector(value: Any, name: str) -> tuple[float, float, float]:
    if not isinstance(value, dict):
        raise WorldImportError(f"{name} must be an object")
    return (
        _finite_number(value.get("x"), f"{name}.x"),
        _finite_number(value.get("y"), f"{name}.y"),
        _finite_number(value.get("z"), f"{name}.z"),
    )


def _quaternion(value: Any, name: str) -> tuple[float, float, float, float]:
    if not isinstance(value, dict):
        raise WorldImportError(f"{name} must be an object")
    w = _finite_number(value.get("w"), f"{name}.w")
    x = _finite_number(value.get("x"), f"{name}.x")
    y = _finite_number(value.get("y"), f"{name}.y")
    z = _finite_number(value.get("z"), f"{name}.z")
    norm_squared = w * w + x * x + y * y + z * z
    if not math.isclose(norm_squared, 1.0, rel_tol=0.0, abs_tol=1e-2):
        raise WorldImportError(f"{name} must be a unit quaternion")
    return (w, x, y, z)


def _bool_value(value: Any, name: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)) and value in (0, 1):
        return bool(value)
    raise WorldImportError(f"{name} must be a boolean")


def _string_list(value: Any, name: str) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        items = value.split(",")
    elif isinstance(value, Iterable):
        items = list(value)
    else:
        raise WorldImportError(f"{name} must be an array or string")
    result = [str(item).strip() for item in items if str(item).strip()]
    if len(result) != len(set(result)):
        raise WorldImportError(f"{name} contains duplicate values")
    return result


def _check_transform(value: Any, name: str) -> None:
    if not isinstance(value, dict):
        raise WorldImportError(f"{name} must be an object")
    _vector(value.get("position", {}), f"{name}.position")
    _quaternion(value.get("rotation", {}), f"{name}.rotation")
    _vector(value.get("scale", {}), f"{name}.scale")


def load_manifest(path: str | Path) -> dict[str, Any]:
    """Decode a world.json package and require a JSON object root."""
    source = Path(path)
    try:
        text = source.read_text(encoding="utf-8")
    except OSError as error:
        raise WorldImportError(f"cannot read manifest {source}: {error}") from error
    try:
        manifest = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise WorldImportError(f"manifest {source} cannot be decoded: {error}") from error
    if not isinstance(manifest, dict):
        raise WorldImportError("manifest root must be an object")
    return manifest


def validate_manifest(manifest: dict[str, Any]) -> None:
    """Validate schemaVersion 1 and every required package field.

    Raises :class:`WorldImportError` on the first malformed construct:
    unsupported schema, missing keys, malformed or non-finite values, duplicate
    IDs, and dangling waypoint/definition references.
    """

    missing = sorted(set(REQUIRED_MANIFEST_KEYS) - set(manifest))
    if missing:
        raise WorldImportError(
            "manifest is missing required key(s): " + ", ".join(missing)
        )
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise WorldImportError(
            f"unsupported schemaVersion {manifest.get('schemaVersion')!r}; "
            f"expected {SCHEMA_VERSION}"
        )

    calibration = manifest["calibration"]
    if not isinstance(calibration, dict):
        raise WorldImportError("calibration must be an object")
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
        raise WorldImportError(
            "calibration.visualToGameplay must contain 16 finite numbers"
        )
    meters = _finite_number(calibration.get("metersPerUnit"), "calibration.metersPerUnit")
    if meters <= 0.0:
        raise WorldImportError("calibration.metersPerUnit must be positive")

    _check_transform(manifest["spawn"], "spawn")

    for key in ARRAY_KEYS:
        value = manifest[key]
        if not isinstance(value, list):
            raise WorldImportError(f"{key} must be an array")

    id_counts: dict[str, int] = {}
    for key in (
        "collisionVolumes",
        "waypoints",
        "routes",
        "activities",
        "cameras",
        "resources",
    ):
        for item in manifest[key]:
            if not isinstance(item, dict):
                raise WorldImportError(f"{key} entries must be objects")
            stable_id = item.get("id")
            if not isinstance(stable_id, str) or not stable_id.strip():
                raise WorldImportError(f"{key} has an invalid or missing id")
            stable_id = stable_id.strip()
            id_counts[stable_id] = id_counts.get(stable_id, 0) + 1
            if id_counts[stable_id] > 1:
                raise WorldImportError(f"duplicate id {stable_id!r}")

    # Activity definitions are the same logical entity as their activity anchor,
    # so they share the id instead of being duplicates. They must pair 1:1.
    activity_ids = {item["id"] for item in manifest["activities"]}
    definition_ids = [item["id"] for item in manifest["activityDefinitions"]]
    seen_definitions: set[str] = set()
    for definition_id in definition_ids:
        if definition_id not in activity_ids:
            raise WorldImportError(
                f"activity definition {definition_id!r} has no matching activity"
            )
        if definition_id in seen_definitions:
            raise WorldImportError(f"duplicate activity definition {definition_id!r}")
        seen_definitions.add(definition_id)

    for volume in manifest["collisionVolumes"]:
        name = f"collision {volume['id']}"
        _vector(volume.get("center", {}), f"{name} center")
        half = _vector(volume.get("halfExtents", {}), f"{name} halfExtents")
        if any(axis <= 0.0 for axis in half):
            raise WorldImportError(f"{name} halfExtents must be positive")
        _quaternion(volume.get("rotation", {}), f"{name} rotation")
        _bool_value(volume.get("isBlocking"), f"{name} isBlocking")

    waypoint_ids: set[str] = set()
    for waypoint in manifest["waypoints"]:
        name = f"waypoint {waypoint['id']}"
        _vector(waypoint.get("position", {}), f"{name} position")
        _finite_number(waypoint.get("arrivalRadius"), f"{name} arrivalRadius")
        _bool_value(waypoint.get("enabled"), f"{name} enabled")
        waypoint_ids.add(waypoint["id"])

    for route in manifest["routes"]:
        name = f"route {route['id']}"
        _string_list(route.get("waypointIDs"), f"{name} waypointIDs")
        _bool_value(route.get("bidirectional"), f"{name} bidirectional")
        _bool_value(route.get("enabled"), f"{name} enabled")
        for waypoint_id in _string_list(
            route.get("waypointIDs"), f"{name} waypointIDs"
        ):
            if waypoint_id not in waypoint_ids:
                raise WorldImportError(
                    f"{name} references missing waypoint {waypoint_id!r}"
                )

    definitions_by_id: dict[str, dict[str, Any]] = {}
    for definition in manifest["activityDefinitions"]:
        name = f"activity definition {definition['id']}"
        activity = definition.get("activity")
        if not isinstance(activity, dict) or not isinstance(activity.get("type"), str):
            raise WorldImportError(f"{name} must define activity.type")
        phases = definition.get("phases")
        if not isinstance(phases, list):
            raise WorldImportError(f"{name} must define a phases array")
        for contract in phases:
            if not isinstance(contract, dict) or not isinstance(
                contract.get("phase"), str
            ):
                raise WorldImportError(f"{name} phases must be objects")
            _string_list(
                contract.get("requiredAnchorIDs"), f"{name} phase anchors"
            )
            _string_list(contract.get("motionIDs"), f"{name} phase motions")
            _string_list(contract.get("propIDs"), f"{name} phase props")
            duration = contract.get("durationSeconds")
            if duration is not None:
                _finite_number(duration, f"{name} durationSeconds")
        _bool_value(definition.get("interruptible"), f"{name} interruptible")
        _finite_number(definition.get("cooldownSeconds"), f"{name} cooldownSeconds")
        definitions_by_id[definition["id"]] = definition

    for activity in manifest["activities"]:
        name = f"activity {activity['id']}"
        action = activity.get("action")
        canonical = LEGACY_ACTION_ALIASES.get(action, action)
        if canonical not in CANONICAL_ACTIONS:
            raise WorldImportError(f"{name} has unsupported action {action!r}")
        entry = activity.get("entryWaypointID")
        if entry not in waypoint_ids:
            raise WorldImportError(f"{name} references missing entry waypoint {entry!r}")
        _check_transform(activity.get("transform", {}), f"{name} transform")
        _bool_value(activity.get("interruptible"), f"{name} interruptible")
        for prop_id in _string_list(activity.get("propIDs"), f"{name} propIDs"):
            if prop_id not in {
                resource["id"] for resource in manifest["resources"]
            }:
                raise WorldImportError(f"{name} references missing prop {prop_id!r}")
        if activity["id"] not in definitions_by_id:
            raise WorldImportError(f"{name} has no matching activityDefinition")

    for camera in manifest["cameras"]:
        name = f"camera {camera['id']}"
        _check_transform(camera.get("transform", {}), f"{name} transform")
        _finite_number(camera.get("fieldOfViewDegrees"), f"{name} fieldOfViewDegrees")
        near = _finite_number(camera.get("nearPlane"), f"{name} nearPlane")
        far = _finite_number(camera.get("farPlane"), f"{name} farPlane")
        if not 0.0 < near < far:
            raise WorldImportError(f"{name} must satisfy 0 < nearPlane < farPlane")

    for resource in manifest["resources"]:
        name = f"resource {resource['id']}"
        for key in ("kind", "path", "sha256"):
            if not isinstance(resource.get(key), str):
                raise WorldImportError(f"{name} {key} must be a string")

    for capability in manifest["capabilities"]:
        if not isinstance(capability, str) or not capability:
            raise WorldImportError("capabilities must contain non-empty strings")


# ---------------------------------------------------------------------------
# Pure coordinate conversion layer
# ---------------------------------------------------------------------------


def gameplay_to_blender(
    position: tuple[float, float, float] | Any,
) -> tuple[float, float, float]:
    """Convert gameplay Y-up (x, y, z) to Blender Z-up (x, -z, y).

    This is the exact inverse of ``export_gmgn_world._vector``.
    """

    x, y, z = position
    return (x, -z, y)


def blender_to_gameplay(
    position: tuple[float, float, float] | Any,
) -> tuple[float, float, float]:
    """Convert Blender Z-up back to gameplay Y-up (matches the exporter)."""
    x, y, z = position
    return (x, z, -y)


def gameplay_scale_to_blender(
    scale: tuple[float, float, float] | Any,
) -> tuple[float, float, float]:
    """Convert gameplay scale (sx, sy, sz) to Blender (sx, sz, sy)."""
    sx, sy, sz = scale
    return (sx, sz, sy)


def blender_scale_to_gameplay(
    scale: tuple[float, float, float] | Any,
) -> tuple[float, float, float]:
    """Convert Blender scale back to gameplay (matches the exporter)."""
    sx, sy, sz = scale
    return (sx, sz, sy)


def quaternion_to_yaw_pitch(
    quaternion: tuple[float, float, float, float],
) -> tuple[float, float]:
    """Recover the exporter yaw/pitch pair that produced a gameplay quaternion.

    ``export_gmgn_world._rotation`` builds a quaternion
    ``(sin(p/2)cos(y/2), cos(p/2)sin(y/2), sin(p/2)sin(y/2), cos(p/2)cos(y/2))``
    from a Blender Z-euler yaw and ``gmgn.pitch``. The exact inverse is::

        yaw   = 2 * atan2(q.y, q.w)
        pitch = 2 * atan2(q.x, q.w)

    Setting the marker's Z-euler to the restored yaw and ``gmgn.pitch`` to the
    restored pitch makes a re-export reproduce the original transform. Because
    this inverse loses any roll component (the quaternion ``z`` term), the
    importer also stores the original quaternion via
    :func:`source_quaternion_props`; the exporter reuses it verbatim while the
    authored yaw/pitch still match, so camera and marker quaternions round-trip
    losslessly.
    """

    w, x, y, z = quaternion
    return (2.0 * math.atan2(y, w), 2.0 * math.atan2(x, w))



def source_quaternion_props(
    quaternion: tuple[float, float, float, float],
    yaw: float,
    pitch: float,
) -> dict[str, Any]:
    """Record the original manifest quaternion plus the restored yaw/pitch.

    The exporter reuses these to reproduce the exact source quaternion
    (including any roll component that the two-degree-of-freedom yaw/pitch
    space cannot represent) while the authored yaw/pitch still match the
    stored source values; once the author edits either angle the exporter
    falls back to the current authored conversion.
    """

    return {
        "gmgn.source_quaternion": list(quaternion),
        "gmgn.source_yaw": yaw,
        "gmgn.source_pitch": pitch,
    }


def is_floor_volume(marker_id: str) -> bool:
    """True when a collision volume id marks an authored walkable floor."""
    return "floor" in str(marker_id).lower()


def floor_proxy_corners(volume: dict[str, Any]) -> list[tuple[float, float, float]]:
    """Return the Blender-space corners of a floor volume's top surface.

    The top surface is the gameplay-Y-up face of the oriented box; its four
    corners are yaw-rotated around the volume center and converted to Blender.
    Countertops and other non-floor volumes are never passed here.
    """

    center = _vector(volume.get("center", {}), "floor center")
    half = _vector(volume.get("halfExtents", {}), "floor halfExtents")
    rotation = _quaternion(volume.get("rotation", {}), "floor rotation")
    yaw, _pitch = quaternion_to_yaw_pitch(rotation)
    cx, cy, cz = center
    hx, hy, hz = half
    top_y = cy + hy
    cosine = math.cos(yaw)
    sine = math.sin(yaw)
    corners = []
    for sx, sz in ((1.0, 1.0), (1.0, -1.0), (-1.0, -1.0), (-1.0, 1.0)):
        gx = cx + sx * hx
        gz = cz + sz * hz
        rotated_x = gx * cosine + gz * sine
        rotated_z = -gx * sine + gz * cosine
        corners.append(gameplay_to_blender((rotated_x, top_y, rotated_z)))
    return corners


# ---------------------------------------------------------------------------
# Pure scene model layer
# ---------------------------------------------------------------------------


def _canonical_action(action: Any, activity_id: str) -> str:
    authored = str(action).strip()
    canonical = LEGACY_ACTION_ALIASES.get(authored, authored)
    if canonical not in CANONICAL_ACTIONS:
        raise WorldImportError(
            f"activity {activity_id} has unsupported action {authored!r}"
        )
    return canonical


def _list_property(values: list[str]) -> Any:
    """Store a list so the exporter can read it back as an empty list.

    Blender turns an assigned empty Python list into an empty array custom
    property that is not recognized as iterable by the exporter, so empty
    lists are stored as an empty comma-separated string instead
    (``_string_list("")`` yields ``[]``).
    """
    return list(values) if values else ""


def _find_spawn_index(
    waypoints: list[dict[str, Any]], spawn_transform: dict[str, Any]
) -> int | None:
    for index, waypoint in enumerate(waypoints):
        if waypoint["id"] == "wp.spawn":
            return index
    spawn_position = _vector(spawn_transform["position"], "spawn position")
    for index, waypoint in enumerate(waypoints):
        position = _vector(waypoint["position"], f"waypoint {waypoint['id']} position")
        if all(
            math.isclose(
                left, right, rel_tol=0.0, abs_tol=_SPAWN_POSITION_TOLERANCE
            )
            for left, right in zip(position, spawn_position)
        ):
            return index
    return None


def build_markers(manifest: dict[str, Any]) -> list[MarkerSpec]:
    """Convert a validated manifest into a Blender-independent marker model."""
    specs: list[MarkerSpec] = []

    # --- GMGN_COLLISION: oriented box volumes (object dimensions define box) ---
    for volume in manifest["collisionVolumes"]:
        volume_id = volume["id"]
        center = _vector(volume["center"], f"collision {volume_id} center")
        half = _vector(volume["halfExtents"], f"collision {volume_id} halfExtents")
        rotation = _quaternion(volume["rotation"], f"collision {volume_id} rotation")
        yaw, pitch = quaternion_to_yaw_pitch(rotation)
        # Exporter reads world-space dimensions and maps (sx, sz, sy) to
        # gameplay half-extents, so the cube is sized (2hx, 2hz, 2hy).
        size = (2.0 * half[0], 2.0 * half[2], 2.0 * half[1])
        specs.append(
            MarkerSpec(
                "GMGN_COLLISION",
                volume_id,
                gameplay_to_blender(center),
                (0.0, 0.0, yaw),
                None,
                {
                    "gmgn.id": volume_id,
                    "gmgn.blocking": _bool_value(
                        volume["isBlocking"], f"collision {volume_id} isBlocking"
                    ),
                    "gmgn.pitch": pitch,
                    **source_quaternion_props(rotation, yaw, pitch),
                },
                mesh_kind="cube",
                mesh_size=size,
            )
        )

    # --- GMGN_WAYPOINTS: navigation points plus the single spawn ---
    spawn_index = _find_spawn_index(manifest["waypoints"], manifest["spawn"])
    waypoint_locations: dict[str, tuple[float, float, float]] = {}
    for index, waypoint in enumerate(manifest["waypoints"]):
        waypoint_id = waypoint["id"]
        position = _vector(
            waypoint["position"], f"waypoint {waypoint_id} position"
        )
        props: dict[str, Any] = {
            "gmgn.id": waypoint_id,
            "gmgn.arrival_radius": _finite_number(
                waypoint.get("arrivalRadius"), f"waypoint {waypoint_id} arrivalRadius"
            ),
            "gmgn.enabled": _bool_value(
                waypoint.get("enabled"), f"waypoint {waypoint_id} enabled"
            ),
        }
        if waypoint_id.startswith("wp.auto."):
            props["gmgn.generated_by"] = NAVIGATION_BAKER_GENERATED_BY
        scale = None
        if index == spawn_index:
            props["gmgn.spawn"] = True
            spawn_rotation = _quaternion(
                manifest["spawn"]["rotation"], "spawn rotation"
            )
            yaw, pitch = quaternion_to_yaw_pitch(spawn_rotation)
            props["gmgn.pitch"] = pitch
            props.update(source_quaternion_props(spawn_rotation, yaw, pitch))
            spawn_position = _vector(manifest["spawn"]["position"], "spawn position")
            position = gameplay_to_blender(spawn_position)
            scale = gameplay_scale_to_blender(
                _vector(manifest["spawn"]["scale"], "spawn scale")
            )
            rotation_euler = (0.0, 0.0, yaw)
        else:
            position = gameplay_to_blender(position)
            rotation_euler = (0.0, 0.0, 0.0)
        specs.append(
            MarkerSpec(
                "GMGN_WAYPOINTS",
                waypoint_id,
                position,
                rotation_euler,
                scale,
                props,
            )
        )
        waypoint_locations[waypoint_id] = position

    if spawn_index is None:
        spawn_transform = manifest["spawn"]
        spawn_position = _vector(spawn_transform["position"], "spawn position")
        spawn_rotation = _quaternion(spawn_transform["rotation"], "spawn rotation")
        yaw, pitch = quaternion_to_yaw_pitch(spawn_rotation)
        spawn_id = "wp.spawn"
        specs.append(
            MarkerSpec(
                "GMGN_WAYPOINTS",
                spawn_id,
                gameplay_to_blender(spawn_position),
                (0.0, 0.0, yaw),
                gameplay_scale_to_blender(
                    _vector(spawn_transform["scale"], "spawn scale")
                ),
                {
                    "gmgn.id": spawn_id,
                    "gmgn.spawn": True,
                    "gmgn.pitch": pitch,
                    **source_quaternion_props(spawn_rotation, yaw, pitch),
                    "gmgn.arrival_radius": 0.2,
                    "gmgn.enabled": True,
                },
            )
        )
        waypoint_locations[spawn_id] = gameplay_to_blender(spawn_position)

    # --- GMGN_ROUTES: ordered waypoint paths ---
    for route in manifest["routes"]:
        route_id = route["id"]
        waypoint_ids = _string_list(
            route.get("waypointIDs"), f"route {route_id} waypointIDs"
        )
        referenced = [
            waypoint_locations[waypoint_id]
            for waypoint_id in waypoint_ids
            if waypoint_id in waypoint_locations
        ]
        if referenced:
            centroid = tuple(
                sum(position[axis] for position in referenced) / len(referenced)
                for axis in range(3)
            )
        else:
            centroid = (0.0, 0.0, 0.0)
        route_props: dict[str, Any] = {
            "gmgn.id": route_id,
            "gmgn.waypoints": _list_property(waypoint_ids),
            "gmgn.bidirectional": _bool_value(
                route.get("bidirectional"), f"route {route_id} bidirectional"
            ),
            "gmgn.enabled": _bool_value(
                route.get("enabled"), f"route {route_id} enabled"
            ),
        }
        if route_id.startswith("route.auto."):
            route_props["gmgn.generated_by"] = NAVIGATION_BAKER_GENERATED_BY
        specs.append(
            MarkerSpec(
                "GMGN_ROUTES",
                route_id,
                centroid,
                (0.0, 0.0, 0.0),
                None,
                route_props,
            )
        )

    # --- GMGN_ACTIVITIES: activity anchors with full six-phase definitions ---
    definitions_by_id = {
        definition["id"]: definition
        for definition in manifest["activityDefinitions"]
    }
    for activity in manifest["activities"]:
        activity_id = activity["id"]
        definition = definitions_by_id.get(activity_id)
        if definition is None:
            raise WorldImportError(
                f"activity {activity_id} has no matching activityDefinition"
            )
        activity_type = str(definition["activity"].get("type", "")).strip()
        transform = activity["transform"]
        position = _vector(transform["position"], f"activity {activity_id} position")
        rotation = _quaternion(transform["rotation"], f"activity {activity_id} rotation")
        yaw, pitch = quaternion_to_yaw_pitch(rotation)
        scale = _vector(transform["scale"], f"activity {activity_id} scale")
        props: dict[str, Any] = {
            "gmgn.id": activity_id,
            "gmgn.action": _canonical_action(activity["action"], activity_id),
            "gmgn.entry": str(activity["entryWaypointID"]),
            "gmgn.interruptible": _bool_value(
                activity.get("interruptible"), f"activity {activity_id} interruptible"
            ),
            "gmgn.pitch": pitch,
            **source_quaternion_props(rotation, yaw, pitch),
            "gmgn.cooldown": _finite_number(
                definition.get("cooldownSeconds"),
                f"activity {activity_id} cooldownSeconds",
            ),
        }
        if activity.get("motionID"):
            props["gmgn.motion"] = str(activity["motionID"])
        props["gmgn.props"] = _list_property(
            _string_list(activity.get("propIDs"), f"activity {activity_id} propIDs")
        )
        if activity_type == "walk":
            props["gmgn.destination"] = str(
                definition["activity"].get(
                    "destinationID", activity["entryWaypointID"]
                )
            )
        elif activity_type == "turn":
            props["gmgn.target_yaw"] = _finite_number(
                definition["activity"].get("targetYaw", yaw),
                f"activity {activity_id} targetYaw",
            )
        elif activity_type in ("sit", "listenMusic", "interact"):
            props["gmgn.anchor"] = str(
                definition["activity"].get("anchorID", activity_id)
            )
        elif activity_type == "gaze":
            props["gmgn.target"] = str(
                definition["activity"].get("targetID", activity_id)
            )
        phases = definition.get("phases", [])
        phase_by_name = {
            contract.get("phase"): contract for contract in phases
        }
        for phase in ACTIVITY_PHASES:
            contract = phase_by_name.get(phase, {})
            props[f"gmgn.{phase}_anchors"] = _list_property(
                _string_list(
                    contract.get("requiredAnchorIDs"),
                    f"activity {activity_id} {phase} anchors",
                )
            )
            props[f"gmgn.{phase}_motions"] = _list_property(
                _string_list(
                    contract.get("motionIDs"),
                    f"activity {activity_id} {phase} motions",
                )
            )
            props[f"gmgn.{phase}_props"] = _list_property(
                _string_list(
                    contract.get("propIDs"),
                    f"activity {activity_id} {phase} props",
                )
            )
            duration = contract.get("durationSeconds")
            if duration is not None:
                props[f"gmgn.{phase}_duration"] = _finite_number(
                    duration, f"activity {activity_id} {phase} durationSeconds"
                )
        if definition.get("displayName"):
            props["gmgn.display_name"] = str(definition["displayName"])
        specs.append(
            MarkerSpec(
                "GMGN_ACTIVITIES",
                activity_id,
                gameplay_to_blender(position),
                (0.0, 0.0, yaw),
                gameplay_scale_to_blender(scale),
                props,
            )
        )

    # --- GMGN_CAMERAS: authored camera anchors ---
    for camera in manifest["cameras"]:
        camera_id = camera["id"]
        transform = camera["transform"]
        position = _vector(transform["position"], f"camera {camera_id} position")
        rotation = _quaternion(transform["rotation"], f"camera {camera_id} rotation")
        yaw, pitch = quaternion_to_yaw_pitch(rotation)
        scale = _vector(transform["scale"], f"camera {camera_id} scale")
        specs.append(
            MarkerSpec(
                "GMGN_CAMERAS",
                camera_id,
                gameplay_to_blender(position),
                (0.0, 0.0, yaw),
                gameplay_scale_to_blender(scale),
                {
                    "gmgn.id": camera_id,
                    "gmgn.fov": _finite_number(
                        camera.get("fieldOfViewDegrees"),
                        f"camera {camera_id} fieldOfViewDegrees",
                    ),
                    "gmgn.near": _finite_number(
                        camera.get("nearPlane"), f"camera {camera_id} nearPlane"
                    ),
                    "gmgn.far": _finite_number(
                        camera.get("farPlane"), f"camera {camera_id} farPlane"
                    ),
                    "gmgn.pitch": pitch,
                    **source_quaternion_props(rotation, yaw, pitch),
                },
            )
        )

    # --- GMGN_PROPS: package-local resource records ---
    for resource in manifest["resources"]:
        resource_id = resource["id"]
        resource_path = str(resource.get("path", ""))
        specs.append(
            MarkerSpec(
                "GMGN_PROPS",
                resource_id,
                (0.0, 0.0, 0.0),
                (0.0, 0.0, 0.0),
                None,
                {
                    "gmgn.id": resource_id,
                    "gmgn.kind": str(resource.get("kind", "")),
                    "gmgn.path": resource_path,
                    "gmgn.package_path": resource_path,
                },
            )
        )

    # --- Editable walkable proxy surfaces + hidden source helpers ---
    for volume in manifest["collisionVolumes"]:
        volume_id = volume["id"]
        if not is_floor_volume(volume_id):
            continue
        center = _vector(volume["center"], f"collision {volume_id} center")
        half = _vector(volume["halfExtents"], f"collision {volume_id} halfExtents")
        rotation = _quaternion(volume["rotation"], f"collision {volume_id} rotation")
        yaw, _pitch = quaternion_to_yaw_pitch(rotation)
        size = (2.0 * half[0], 2.0 * half[2], 2.0 * half[1])
        proxy_props = {
            "gmgn.proxy_of": volume_id,
            "gmgn.generated_by": IMPORTER_VERSION,
        }
        specs.append(
            MarkerSpec(
                "GMGN_NAV_SOURCE",
                f"{volume_id}.proxy",
                (0.0, 0.0, 0.0),
                (0.0, 0.0, 0.0),
                None,
                proxy_props,
                mesh_kind="polygon",
                polygon_vertices=floor_proxy_corners(volume),
            )
        )
        specs.append(
            MarkerSpec(
                "GMGN_SOURCE",
                f"{volume_id}.source_box",
                gameplay_to_blender(center),
                (0.0, 0.0, yaw),
                None,
                {
                    "gmgn.proxy_of": volume_id,
                    "gmgn.generated_by": IMPORTER_VERSION,
                },
                mesh_kind="cube",
                mesh_size=size,
                hidden=True,
                locked=True,
            )
        )

    return specs


# ---------------------------------------------------------------------------
# Blender layer
# ---------------------------------------------------------------------------


def _fill_cube_mesh(mesh: Any, size: tuple[float, float, float]) -> None:
    dx, dy, dz = size
    hx, hy, hz = dx * 0.5, dy * 0.5, dz * 0.5
    vertices = [
        (-hx, -hy, -hz),
        (hx, -hy, -hz),
        (hx, hy, -hz),
        (-hx, hy, -hz),
        (-hx, -hy, hz),
        (hx, -hy, hz),
        (hx, hy, hz),
        (-hx, hy, hz),
    ]
    faces = [
        (0, 1, 2, 3),
        (4, 7, 6, 5),
        (0, 4, 5, 1),
        (1, 5, 6, 2),
        (2, 6, 7, 3),
        (3, 7, 4, 0),
    ]
    mesh.from_pydata(vertices, [], faces)
    mesh.update()


def _fill_polygon_mesh(
    mesh: Any, vertices: list[tuple[float, float, float]]
) -> None:
    mesh.from_pydata([list(vertex) for vertex in vertices], [], [list(range(len(vertices)))])
    mesh.update()


def _apply_spec(bpy: Any, spec: MarkerSpec) -> None:
    collection = bpy.data.collections[spec.collection]
    if spec.mesh_kind == "cube":
        mesh = bpy.data.meshes.new(f"{spec.object_name}.mesh")
        _fill_cube_mesh(mesh, spec.mesh_size)
        obj = bpy.data.objects.new(spec.object_name, mesh)
    elif spec.mesh_kind == "polygon":
        mesh = bpy.data.meshes.new(f"{spec.object_name}.mesh")
        _fill_polygon_mesh(mesh, spec.polygon_vertices)
        obj = bpy.data.objects.new(spec.object_name, mesh)
    else:
        obj = bpy.data.objects.new(spec.object_name, None)
    obj.location = spec.location
    obj.rotation_euler = spec.rotation_euler
    if spec.scale is not None:
        obj.scale = spec.scale
    for key, value in spec.properties.items():
        obj[key] = value
    collection.objects.link(obj)
    if spec.hidden:
        obj.hide_viewport = True
        obj.hide_render = True
    if spec.locked:
        obj.lock_location = (True, True, True)
        obj.lock_rotation = (True, True, True)
        obj.lock_scale = (True, True, True)


def _record_scene_metadata(
    bpy: Any, manifest: dict[str, Any], manifest_path: Path
) -> None:
    scene = bpy.context.scene
    scene["gmgn.package_id"] = manifest["packageID"]
    scene["gmgn.package_version"] = manifest["packageVersion"]
    scene["gmgn.world_id"] = manifest["worldID"]
    scene["gmgn.display_name"] = manifest["displayName"]
    scene["gmgn.meters_per_unit"] = manifest["calibration"]["metersPerUnit"]
    scene["gmgn.importer_version"] = IMPORTER_VERSION
    scene["gmgn.source_manifest"] = str(manifest_path)
    scene["gmgn.source_manifest_sha256"] = hashlib.sha256(
        manifest_path.read_bytes()
    ).hexdigest()
    scene["gmgn.source_manifest_schema_version"] = SCHEMA_VERSION
    scene["gmgn.calibration_visual_to_gameplay"] = list(
        manifest["calibration"]["visualToGameplay"]
    )


def _export_nav_source_glb(bpy: Any, glb_path: Path) -> None:
    """Export only the editable GMGN_NAV_SOURCE proxy surfaces as glTF Binary."""
    nav_collection = bpy.data.collections["GMGN_NAV_SOURCE"]
    for obj in bpy.data.objects:
        obj.select_set(False)
    for obj in nav_collection.objects:
        obj.select_set(True)
    bpy.ops.export_scene.gltf(
        filepath=str(glb_path),
        export_format="GLB",
        use_selection=True,
    )


def _build_scene(
    bpy: Any,
    manifest: dict[str, Any],
    specs: list[MarkerSpec],
    manifest_path: Path,
    output_path: Path,
    glb_path: Path | None,
) -> None:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    master = scene.collection
    for name in COLLECTION_NAMES:
        master.children.link(bpy.data.collections.new(name))
    for spec in specs:
        _apply_spec(bpy, spec)
    _record_scene_metadata(bpy, manifest, manifest_path)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output_path))
    if glb_path is not None:
        _export_nav_source_glb(bpy, glb_path)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _arguments_after_double_dash(arguments: list[str]) -> list[str]:
    if "--" in arguments:
        return arguments[arguments.index("--") + 1 :]
    if arguments and not arguments[0].startswith("-"):
        return arguments[1:]
    return arguments


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="import_gmgn_world.py",
        description=(
            "Reverse-import a world.json manifest into a fresh editable GMGN "
            "Blender authoring scene with the frozen GMGN collection contract."
        ),
    )
    parser.add_argument("--manifest", required=True, help="input world.json package")
    parser.add_argument("--output", required=True, help=".blend file to write")
    parser.add_argument(
        "--glb-output",
        default=None,
        help="optional glTF Binary export of the GMGN_NAV_SOURCE proxy surfaces",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing output .blend or .glb (replaces the whole file)",
    )
    return parser.parse_args(arguments)


def main(arguments: list[str] | None = None) -> int:
    args = _parse_args(_arguments_after_double_dash(arguments or sys.argv))

    manifest_path = Path(args.manifest)
    output_path = Path(args.output)
    glb_path = Path(args.glb_output) if args.glb_output else None

    if not manifest_path.is_file():
        print(f"ERROR input manifest does not exist: {manifest_path}", file=sys.stderr)
        return 1
    if output_path.exists() and not args.force:
        print(
            f"ERROR output already exists: {args.output}; "
            "pass --force to overwrite the whole .blend",
            file=sys.stderr,
        )
        return 1
    if glb_path is not None and glb_path.exists() and not args.force:
        print(
            f"ERROR glb output already exists: {args.glb_output}; "
            "pass --force to overwrite",
            file=sys.stderr,
        )
        return 1

    try:
        manifest = load_manifest(manifest_path)
        validate_manifest(manifest)
    except WorldImportError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1

    try:
        import bpy  # type: ignore
    except ImportError:
        print("ERROR this command must run inside Blender", file=sys.stderr)
        return 2

    try:
        specs = build_markers(manifest)
        _build_scene(
            bpy, manifest, specs, manifest_path, output_path, glb_path
        )
    except WorldImportError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1

    glb_note = f", glb -> {args.glb_output}" if glb_path is not None else ""
    print(
        f"IMPORTED {len(specs)} marker(s) from {args.manifest} "
        f"-> {args.output}{glb_note}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
