#!/usr/bin/env python3
"""Import a binary glTF (GLB) collider mesh into an editable GMGN world scene.

This module is the first slice of the GLB-to-GMGN compiler. It is split into
two layers so its deterministic contract can be tested without Blender:

* Pure-Python layer (no ``bpy`` import at module level):
  - :func:`inspect_glb` validates the GLB 2.0 header and JSON chunk and reports
    the asset version, generator, mesh count, primitive count and triangle count.
  - :func:`source_transform` turns source-coordinate conventions plus a metric
    scale and ground-plane offset into an explicit calibration transform.

* Blender layer (``main``): when run inside headless Blender 5.2 it imports the
  GLB into a fresh file, freezes the eight GMGN authoring collections, keeps the
  raw import in a hidden/read-only ``GMGN_SOURCE`` collection, creates an
  editable calibrated mesh copy in ``GMGN_NAV_SOURCE``, adds the single
  ``wp.spawn`` marker at the calibrated origin, records package/world/source/
  calibration metadata as scene custom properties, and saves the ``.blend``.

The importer always builds a fresh scaffold from Blender factory settings. If
``--output`` already exists the run is refused unless ``--force`` is passed;
with ``--force`` the entire ``.blend`` is replaced, so authored markers are not
preserved. Write to a new ``.blend`` when refreshing source data and migrate
markers deliberately.

CLI (after ``--`` so Blender leaves the arguments alone)::

    blender --background --factory-startup \\
        --python tools/blender/import_gmgn_glb.py -- \\
        --input path/to/collider.glb \\
        --output path/to/editable.blend \\
        --package-id warm-kitchen-edit \\
        --world-id world-labs-example-warm-kitchen \\
        --display-name "Warm Kitchen Edit" \\
        --source-coordinates world-labs-opencv \\
        --metric-scale 1.75 \\
        --ground-plane-offset 0.4
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
import sys
from pathlib import Path
from typing import Any

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

#: Source-coordinate conventions understood by :func:`source_transform`.
SUPPORTED_SOURCE_COORDINATES = ("world-labs-opencv", "gltf")

_GLTF_MAGIC = b"glTF"
_GLB_VERSION = 2
_JSON_CHUNK_TYPE = 0x4E4F534A  # "JSON"
_GLB_HEADER_LENGTH = 12
_CHUNK_HEADER_LENGTH = 8
_TRIANGLES = 4
_TRIANGLE_STRIP = 5
_TRIANGLE_FAN = 6


class GLBImportError(ValueError):
    """Raised when a file cannot be interpreted as binary glTF 2.0."""


class GLBInfo:
    """Deterministic summary of an inspected binary glTF document."""

    __slots__ = (
        "version",
        "generator",
        "mesh_count",
        "primitive_count",
        "triangle_count",
    )

    def __init__(
        self,
        version: int,
        generator: str | None,
        mesh_count: int,
        primitive_count: int,
        triangle_count: int,
    ) -> None:
        self.version = version
        self.generator = generator
        self.mesh_count = mesh_count
        self.primitive_count = primitive_count
        self.triangle_count = triangle_count

    def __repr__(self) -> str:
        return (
            f"GLBInfo(version={self.version}, generator={self.generator!r}, "
            f"mesh_count={self.mesh_count}, primitive_count={self.primitive_count}, "
            f"triangle_count={self.triangle_count})"
        )


class SourceTransform:
    """Explicit source-to-Blender calibration described by named coordinates."""

    __slots__ = (
        "source_coordinates",
        "rotation_x_radians",
        "uniform_scale",
        "translation_z",
    )

    def __init__(
        self,
        source_coordinates: str,
        rotation_x_radians: float,
        uniform_scale: float,
        translation_z: float,
    ) -> None:
        self.source_coordinates = source_coordinates
        self.rotation_x_radians = rotation_x_radians
        self.uniform_scale = uniform_scale
        self.translation_z = translation_z

    def __repr__(self) -> str:
        return (
            f"SourceTransform(source_coordinates={self.source_coordinates!r}, "
            f"rotation_x_radians={self.rotation_x_radians}, "
            f"uniform_scale={self.uniform_scale}, "
            f"translation_z={self.translation_z})"
        )

    def matrix_4x4(self) -> list[list[float]]:
        """Return the row-major 4 x 4 calibration matrix.

        Points are transformed as ``M @ p`` with ``M = T * S * R``: rotate about
        X, scale uniformly, then translate along Z. The world-labs-opencv
        correction is rotation X = pi (OpenCV-to-OpenGL y/z flip), a uniform
        metric scale, and a Z translation of ``-ground_plane_offset * scale`` so
        the source ground plane lands on z = 0. Standard glTF gets the scale and
        ground translation but no extra axis rotation.
        """

        sine = math.sin(self.rotation_x_radians)
        cosine = math.cos(self.rotation_x_radians)
        return [
            [self.uniform_scale, 0.0, 0.0, 0.0],
            [0.0, self.uniform_scale * cosine, -self.uniform_scale * sine, 0.0],
            [0.0, self.uniform_scale * sine, self.uniform_scale * cosine, self.translation_z],
            [0.0, 0.0, 0.0, 1.0],
        ]


def _finite_number(value: Any, name: str) -> float:
    try:
        result = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{name} must be numeric") from error
    if not math.isfinite(result):
        raise ValueError(f"{name} must be finite")
    return result


def source_transform(
    source_coordinates: str,
    metric_scale: float,
    ground_plane_offset: float,
) -> SourceTransform:
    """Describe the calibration that maps source coordinates into Blender meters.

    ``world-labs-opencv`` applies the documented OpenCV-to-OpenGL correction:
    rotation about X by pi, a uniform metric scale, and a Z translation of
    ``-ground_plane_offset * metric_scale``. Standard ``gltf`` receives the same
    uniform metric scale and ground translation but no extra axis rotation.
    """

    if source_coordinates not in SUPPORTED_SOURCE_COORDINATES:
        raise ValueError(
            f"unsupported source_coordinates {source_coordinates!r}; "
            f"expected one of {', '.join(SUPPORTED_SOURCE_COORDINATES)}"
        )
    scale = _finite_number(metric_scale, "metric_scale")
    if scale <= 0.0:
        raise ValueError("metric_scale must be positive")
    offset = _finite_number(ground_plane_offset, "ground_plane_offset")
    rotation = math.pi if source_coordinates == "world-labs-opencv" else 0.0
    return SourceTransform(
        source_coordinates=source_coordinates,
        rotation_x_radians=rotation,
        uniform_scale=scale,
        translation_z=-offset * scale,
    )


def _read_json_chunk(data: bytes) -> dict[str, Any]:
    if len(data) < _GLB_HEADER_LENGTH + _CHUNK_HEADER_LENGTH:
        raise GLBImportError("binary glTF is missing its first chunk header")
    chunk_length, chunk_type = struct.unpack_from("<II", data, _GLB_HEADER_LENGTH)
    if chunk_type != _JSON_CHUNK_TYPE:
        raise GLBImportError(
            f"first chunk must be JSON (0x{_JSON_CHUNK_TYPE:08X}), "
            f"got 0x{chunk_type:08X}"
        )
    chunk_end = _GLB_HEADER_LENGTH + _CHUNK_HEADER_LENGTH + chunk_length
    if chunk_length == 0 or chunk_end > len(data):
        raise GLBImportError("JSON chunk length is invalid")
    payload = data[
        _GLB_HEADER_LENGTH + _CHUNK_HEADER_LENGTH : chunk_end
    ]
    try:
        document = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GLBImportError(f"JSON chunk cannot be decoded: {error}") from error
    if not isinstance(document, dict):
        raise GLBImportError("glTF JSON root must be an object")
    return document


def _validate_remaining_chunks(data: bytes, json_end: int) -> None:
    offset = json_end
    while offset < len(data):
        if offset + _CHUNK_HEADER_LENGTH > len(data):
            raise GLBImportError("truncated chunk header")
        chunk_length, _chunk_type = struct.unpack_from("<II", data, offset)
        if offset + _CHUNK_HEADER_LENGTH + chunk_length > len(data):
            raise GLBImportError("chunk exceeds the declared GLB length")
        offset += _CHUNK_HEADER_LENGTH + chunk_length
    if offset != len(data):
        raise GLBImportError("trailing bytes after the final chunk")


def _accessor_count(accessors: list[Any], index: Any) -> int:
    if not isinstance(index, int) or index < 0 or index >= len(accessors):
        raise GLBImportError(f"accessor index {index!r} is out of range")
    accessor = accessors[index]
    if not isinstance(accessor, dict):
        raise GLBImportError("accessor entries must be objects")
    count = accessor.get("count", 0)
    if not isinstance(count, int) or count < 0:
        raise GLBImportError("accessor count must be a non-negative integer")
    return count


def _primitive_triangle_count(primitive: Any, accessors: list[Any]) -> int:
    if not isinstance(primitive, dict):
        raise GLBImportError("mesh primitives must be objects")
    mode = primitive.get("mode", _TRIANGLES)
    count: int | None = None
    index_accessor = primitive.get("indices")
    if index_accessor is not None:
        count = _accessor_count(accessors, index_accessor)
    else:
        attributes = primitive.get("attributes")
        if isinstance(attributes, dict):
            position = attributes.get("POSITION")
            if position is not None:
                count = _accessor_count(accessors, position)
    if count is None:
        return 0
    if mode == _TRIANGLES:
        return count // 3
    if mode in (_TRIANGLE_STRIP, _TRIANGLE_FAN):
        return max(count - 2, 0)
    return 0


def inspect_glb(path: str | Path) -> GLBInfo:
    """Validate a binary glTF 2.0 file and report deterministic content counts."""

    source = Path(path)
    try:
        data = source.read_bytes()
    except OSError as error:
        raise GLBImportError(f"cannot read {source}: {error}") from error

    if len(data) < _GLB_HEADER_LENGTH or data[:4] != _GLTF_MAGIC:
        raise GLBImportError(
            "not a binary glTF file: missing glTF header magic in the first 12 bytes"
        )
    _magic, version, total_length = struct.unpack_from("<4sII", data, 0)
    if version != _GLB_VERSION:
        raise GLBImportError(
            f"unsupported binary glTF version {version}; expected {_GLB_VERSION}"
        )
    if total_length != len(data):
        raise GLBImportError(
            f"glTF header length {total_length} does not match file size {len(data)}"
        )

    document = _read_json_chunk(data)
    json_length, _json_type = struct.unpack_from("<II", data, _GLB_HEADER_LENGTH)
    _validate_remaining_chunks(
        data, _GLB_HEADER_LENGTH + _CHUNK_HEADER_LENGTH + json_length
    )

    asset = document.get("asset")
    if not isinstance(asset, dict):
        raise GLBImportError("glTF document is missing asset.version")
    asset_version = asset.get("version")
    if asset_version != "2.0":
        raise GLBImportError(
            f"unsupported glTF asset version {asset_version!r}; expected '2.0'"
        )
    generator = asset.get("generator")
    if generator is not None and not isinstance(generator, str):
        raise GLBImportError("asset.generator must be a string when present")

    meshes = document.get("meshes", [])
    if not isinstance(meshes, list):
        raise GLBImportError("meshes must be an array")
    accessors = document.get("accessors", [])
    if not isinstance(accessors, list):
        raise GLBImportError("accessors must be an array")

    mesh_count = len(meshes)
    primitive_count = 0
    triangle_count = 0
    for mesh in meshes:
        if not isinstance(mesh, dict):
            raise GLBImportError("mesh entries must be objects")
        primitives = mesh.get("primitives", [])
        if not isinstance(primitives, list):
            raise GLBImportError("mesh primitives must be an array")
        primitive_count += len(primitives)
        for primitive in primitives:
            triangle_count += _primitive_triangle_count(primitive, accessors)

    return GLBInfo(
        version=version,
        generator=generator,
        mesh_count=mesh_count,
        primitive_count=primitive_count,
        triangle_count=triangle_count,
    )


def _arguments_after_double_dash(arguments: list[str]) -> list[str]:
    return arguments[arguments.index("--") + 1 :] if "--" in arguments else arguments[1:]


def _parse_args(arguments: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="import_gmgn_glb.py",
        description=(
            "Import a GLB collider mesh into a fresh editable GMGN world "
            "Blender file with the frozen GMGN collection contract."
        ),
    )
    parser.add_argument("--input", required=True, help="binary glTF (GLB) collider mesh")
    parser.add_argument("--output", required=True, help=".blend file to write")
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite an existing output .blend (replaces the whole file)",
    )
    parser.add_argument("--package-id", required=True, help="stable package id")
    parser.add_argument("--world-id", required=True, help="stable world id")
    parser.add_argument("--display-name", default=None, help="human display name")
    parser.add_argument("--package-version", default="1.0.0", help="package version")
    parser.add_argument(
        "--source-coordinates",
        default="world-labs-opencv",
        choices=list(SUPPORTED_SOURCE_COORDINATES),
        help="source coordinate convention used for calibration",
    )
    parser.add_argument("--metric-scale", type=float, default=1.0)
    parser.add_argument("--ground-plane-offset", type=float, default=0.0)
    return parser.parse_args(arguments)


def _calibration_matrix(transform: SourceTransform, mathutils: Any) -> Any:
    return mathutils.Matrix(
        tuple(tuple(row) for row in transform.matrix_4x4())
    )


def _build_scene(
    args: argparse.Namespace,
    input_path: Path,
    info: GLBInfo,
    transform: SourceTransform,
    bpy: Any,
    addon_utils: Any,
    mathutils: Any,
) -> None:
    """Construct the frozen editable GMGN scene and save it to ``args.output``."""

    bpy.ops.wm.read_factory_settings(use_empty=True)
    addon_utils.enable("io_scene_gltf2", default_set=True, persistent=True)

    scene = bpy.context.scene
    master = scene.collection
    for name in COLLECTION_NAMES:
        master.children.link(bpy.data.collections.new(name))

    source_collection = bpy.data.collections["GMGN_SOURCE"]
    editable_collection = bpy.data.collections["GMGN_NAV_SOURCE"]
    waypoints_collection = bpy.data.collections["GMGN_WAYPOINTS"]

    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(input_path))
    imported = [obj for obj in bpy.data.objects if obj not in before]
    if not imported:
        print(f"WARNING no objects imported from {input_path}", file=sys.stderr)

    for obj in imported:
        for collection in list(obj.users_collection):
            collection.objects.unlink(obj)
        source_collection.objects.link(obj)
        obj.hide_viewport = True
        obj.hide_render = True
        obj.lock_location = (True, True, True)
        obj.lock_rotation = (True, True, True)
        obj.lock_scale = (True, True, True)
    source_collection.hide_viewport = True
    source_collection.hide_render = True

    calibration = _calibration_matrix(transform, mathutils)
    for obj in list(source_collection.objects):
        editable = obj.copy()
        editable.name = f"{obj.name}_editable"
        # Editable copies must never depend on the hidden GMGN_SOURCE nodes:
        # the source hierarchy stays locked away, and each calibrated world
        # transform is baked into the editable object's own mesh/data.
        editable.parent = None
        editable.hide_viewport = False
        editable.hide_render = False
        editable.lock_location = (False, False, False)
        editable.lock_rotation = (False, False, False)
        editable.lock_scale = (False, False, False)
        if obj.data is not None:
            editable.data = obj.data.copy()
            world_matrix = calibration @ obj.matrix_world
            if hasattr(editable.data, "transform"):
                editable.data.transform(world_matrix)
                editable.data.update()
            editable.matrix_world = mathutils.Matrix.Identity(4)
        else:
            editable.matrix_world = calibration @ obj.matrix_world
        editable_collection.objects.link(editable)

    spawn = bpy.data.objects.new("wp.spawn", None)
    waypoints_collection.objects.link(spawn)
    spawn["gmgn.id"] = "wp.spawn"
    spawn["gmgn.spawn"] = True
    # Calibration maps the source ground plane to z = 0, so the calibrated
    # origin is the authoring spawn ground.
    spawn.location = (0.0, 0.0, 0.0)

    scene["gmgn.package_id"] = args.package_id
    scene["gmgn.package_version"] = args.package_version
    scene["gmgn.world_id"] = args.world_id
    scene["gmgn.display_name"] = args.display_name or args.package_id
    scene["gmgn.source_coordinates"] = args.source_coordinates
    scene["gmgn.source_glb"] = str(input_path)
    scene["gmgn.source_glb_sha256"] = hashlib.sha256(input_path.read_bytes()).hexdigest()
    scene["gmgn.importer_version"] = "1"
    scene["gmgn.source_generator"] = info.generator or ""
    scene["gmgn.source_mesh_count"] = info.mesh_count
    scene["gmgn.source_primitive_count"] = info.primitive_count
    scene["gmgn.source_triangle_count"] = info.triangle_count
    scene["gmgn.calibration_rotation_x_radians"] = transform.rotation_x_radians
    scene["gmgn.calibration_metric_scale"] = transform.uniform_scale
    scene["gmgn.calibration_ground_plane_offset"] = args.ground_plane_offset
    scene["gmgn.calibration_translation_z"] = transform.translation_z
    # After metric scaling, one Blender unit is one meter in the calibrated world.
    scene["gmgn.meters_per_unit"] = 1.0

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=str(output_path))


def main(arguments: list[str] | None = None) -> int:
    args = _parse_args(_arguments_after_double_dash(arguments or sys.argv))

    # Refuse to clobber an authored .blend unless the user explicitly asks with
    # --force. This check runs before read_factory_settings or any import work.
    output_path = Path(args.output)
    if output_path.exists() and not args.force:
        print(
            f"ERROR output already exists: {args.output}; "
            "pass --force to overwrite the whole .blend",
            file=sys.stderr,
        )
        return 1

    try:
        import bpy  # type: ignore
        import addon_utils  # type: ignore
        import mathutils  # type: ignore
    except ImportError:
        print("ERROR this command must run inside Blender", file=sys.stderr)
        return 2

    input_path = Path(args.input)
    if not input_path.is_file():
        print(f"ERROR input GLB does not exist: {input_path}", file=sys.stderr)
        return 1
    try:
        info = inspect_glb(input_path)
    except GLBImportError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1
    try:
        transform = source_transform(
            source_coordinates=args.source_coordinates,
            metric_scale=args.metric_scale,
            ground_plane_offset=args.ground_plane_offset,
        )
    except ValueError as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1

    try:
        _build_scene(args, input_path, info, transform, bpy, addon_utils, mathutils)
    except Exception as error:  # noqa: BLE001 - surface headless Blender failures cleanly
        print(f"ERROR {error}", file=sys.stderr)
        return 1

    print(
        f"IMPORTED {info.mesh_count} mesh(es), {info.primitive_count} primitive(s), "
        f"{info.triangle_count} triangle(s) from {args.input} -> {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
