#!/usr/bin/env python3
"""Validate ARDY-compatible motion specs, build VRMA, and publish artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import struct
import subprocess
import sys
from pathlib import Path
from dataclasses import dataclass
from typing import Any, Iterable, TextIO
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))


class MotionSpecError(ValueError):
    """The generated motion cannot safely enter the published catalog."""


@dataclass(frozen=True)
class WorkerCapacity:
    status: str
    max_concurrency: int
    reasons: tuple[str, ...]


def assess_worker_capacity(
    *,
    memory_gib: float,
    swap_gib: float,
    vram_gib: float,
) -> WorkerCapacity:
    """Classify a CUDA worker without allocating model memory."""
    values = (memory_gib, swap_gib, vram_gib)
    if any(not math.isfinite(value) or value < 0 for value in values):
        return WorkerCapacity("blocked", 0, ("Capacity values must be finite and non-negative.",))
    if vram_gib < 4.0:
        return WorkerCapacity("blocked", 0, ("At least 4 GiB of NVIDIA VRAM is required.",))
    if memory_gib >= 32.0:
        return WorkerCapacity("ready", 1, ())
    if memory_gib >= 16.0 and memory_gib + swap_gib >= 32.0:
        return WorkerCapacity(
            "constrained",
            1,
            ("System memory is below 32 GiB; keep one job active and retain swap headroom.",),
        )
    return WorkerCapacity(
        "blocked",
        0,
        ("A 16 GiB machine needs enough swap to provide at least 32 GiB combined capacity.",),
    )


class ArdyClient:
    """Small synchronous client for the persistent text-to-vrma ARDY server."""

    def __init__(self, base_url: str, *, timeout: float = 600.0):
        parsed = urlparse(base_url)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError("ARDY base URL must be HTTP or HTTPS")
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout

    def generate(
        self,
        *,
        text: str,
        duration: float | None = None,
        seed: int | None = None,
        waypoints: Any = None,
    ) -> dict[str, Any]:
        if not isinstance(text, str) or not text.strip():
            raise MotionSpecError("generation prompt must not be empty")
        payload: dict[str, Any] = {"text": text.strip()}
        if duration is not None:
            payload["duration"] = _finite_number(duration, "duration")
        if seed is not None:
            if isinstance(seed, bool) or not isinstance(seed, int):
                raise MotionSpecError("seed must be an integer")
            payload["seed"] = seed
        normalized_waypoints = normalize_waypoints(waypoints)
        if normalized_waypoints:
            payload["waypoints"] = normalized_waypoints
        request = Request(
            f"{self.base_url}/generate",
            data=json.dumps(payload, separators=(",", ":")).encode("utf-8"),
            headers={"Content-Type": "application/json", "Accept": "application/json"},
            method="POST",
        )
        try:
            with urlopen(request, timeout=self.timeout) as response:
                body = response.read()
        except HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            raise MotionSpecError(f"ARDY returned HTTP {error.code}: {detail}") from error
        except URLError as error:
            raise MotionSpecError(f"ARDY is unavailable: {error.reason}") from error
        try:
            decoded = json.loads(body)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MotionSpecError("ARDY returned invalid JSON") from error
        if isinstance(decoded, dict) and decoded.get("error"):
            raise MotionSpecError(f"ARDY generation failed: {decoded['error']}")
        return validate_motion_spec(decoded)


def normalize_waypoints(value: Any) -> list[dict[str, float]]:
    """Validate the ARDY ground-plane route accepted by the generation server."""
    if value is None:
        return []
    if not isinstance(value, list):
        raise MotionSpecError("waypoints must be a list")
    if len(value) > 128:
        raise MotionSpecError("waypoints must contain at most 128 points")
    result: list[dict[str, float]] = []
    for index, raw in enumerate(value):
        if not isinstance(raw, dict):
            raise MotionSpecError(f"waypoints[{index}] must be an object")
        x = _finite_number(raw.get("x"), f"waypoints[{index}].x")
        z = _finite_number(raw.get("z"), f"waypoints[{index}].z")
        if abs(x) > 25.0 or abs(z) > 25.0:
            raise MotionSpecError(f"waypoints[{index}] exceeds the 25 meter safety bound")
        result.append({"x": x, "z": z})
    return result


SKELETON: dict[str, tuple[str | None, tuple[float, float, float]]] = {
    "hips": (None, (0.0, 0.9, 0.0)),
    "spine": ("hips", (0.0, 0.08, 0.0)),
    "chest": ("spine", (0.0, 0.12, 0.0)),
    "upperChest": ("chest", (0.0, 0.12, 0.0)),
    "neck": ("upperChest", (0.0, 0.13, 0.0)),
    "head": ("neck", (0.0, 0.08, 0.0)),
    "leftShoulder": ("upperChest", (0.03, 0.10, 0.0)),
    "leftUpperArm": ("leftShoulder", (0.06, 0.0, 0.0)),
    "leftLowerArm": ("leftUpperArm", (0.24, 0.0, 0.0)),
    "leftHand": ("leftLowerArm", (0.22, 0.0, 0.0)),
    "rightShoulder": ("upperChest", (-0.03, 0.10, 0.0)),
    "rightUpperArm": ("rightShoulder", (-0.06, 0.0, 0.0)),
    "rightLowerArm": ("rightUpperArm", (-0.24, 0.0, 0.0)),
    "rightHand": ("rightLowerArm", (-0.22, 0.0, 0.0)),
    "leftUpperLeg": ("hips", (0.09, -0.02, 0.0)),
    "leftLowerLeg": ("leftUpperLeg", (0.0, -0.38, 0.0)),
    "leftFoot": ("leftLowerLeg", (0.0, -0.42, 0.0)),
    "rightUpperLeg": ("hips", (-0.09, -0.02, 0.0)),
    "rightLowerLeg": ("rightUpperLeg", (0.0, -0.38, 0.0)),
    "rightFoot": ("rightLowerLeg", (0.0, -0.42, 0.0)),
}

_MOTION_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{2,127}$")
_VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")


def _finite_number(value: Any, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise MotionSpecError(f"{field} must be a number")
    result = float(value)
    if not math.isfinite(result):
        raise MotionSpecError(f"{field} must be finite")
    return result


def _keyframes(
    value: Any,
    *,
    field: str,
    vector_key: str,
    duration: float,
    max_component: float,
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or not value:
        raise MotionSpecError(f"{field} must contain keyframes")
    result: list[dict[str, Any]] = []
    previous_time = -math.inf
    for index, raw in enumerate(value):
        if not isinstance(raw, dict):
            raise MotionSpecError(f"{field}[{index}] must be an object")
        time = _finite_number(raw.get("t"), f"{field}[{index}].t")
        if time < 0.0 or time > duration + 1e-4:
            raise MotionSpecError(f"{field}[{index}].t is outside the duration")
        if time <= previous_time:
            raise MotionSpecError(f"{field} times must be strictly increasing")
        previous_time = time
        raw_vector = raw.get(vector_key)
        if not isinstance(raw_vector, list) or len(raw_vector) != 3:
            raise MotionSpecError(f"{field}[{index}].{vector_key} must have 3 values")
        vector = [
            _finite_number(component, f"{field}[{index}].{vector_key}[{axis}]")
            for axis, component in enumerate(raw_vector)
        ]
        if any(abs(component) > max_component for component in vector):
            raise MotionSpecError(f"{field}[{index}].{vector_key} exceeds its safety bound")
        result.append({"t": time, vector_key: vector})
    return result


def validate_motion_spec(spec: Any) -> dict[str, Any]:
    """Return a normalized, JSON-safe motion spec or raise MotionSpecError."""
    if not isinstance(spec, dict):
        raise MotionSpecError("motion spec must be an object")
    name = spec.get("name")
    if not isinstance(name, str) or not name.strip():
        raise MotionSpecError("name must be a non-empty string")
    duration = _finite_number(spec.get("duration"), "duration")
    if duration < 0.1 or duration > 300.0:
        raise MotionSpecError("duration must be between 0.1 and 300 seconds")
    loop = spec.get("loop", False)
    if not isinstance(loop, bool):
        raise MotionSpecError("loop must be a boolean")

    raw_tracks = spec.get("tracks", {})
    if not isinstance(raw_tracks, dict):
        raise MotionSpecError("tracks must be an object")
    tracks: dict[str, list[dict[str, Any]]] = {}
    for bone in sorted(raw_tracks):
        if bone not in SKELETON:
            raise MotionSpecError(f"unsupported humanoid bone: {bone}")
        tracks[bone] = _keyframes(
            raw_tracks[bone],
            field=f"tracks.{bone}",
            vector_key="r",
            duration=duration,
            max_component=360.0,
        )

    hips: list[dict[str, Any]] = []
    if "hips" in spec:
        hips = _keyframes(
            spec["hips"],
            field="hips",
            vector_key="p",
            duration=duration,
            max_component=25.0,
        )
        for index, keyframe in enumerate(hips):
            x, y, z = keyframe["p"]
            if abs(y) > 5.0 or math.hypot(x, z) > 25.0:
                raise MotionSpecError(f"hips[{index}].p exceeds the root-motion safety bound")
    if not tracks and not hips:
        raise MotionSpecError("motion spec has no animation tracks")

    normalized: dict[str, Any] = {
        "name": name.strip(),
        "duration": duration,
        "loop": loop,
        "tracks": tracks,
    }
    if hips:
        normalized["hips"] = hips
    return normalized


def _euler_xyz_quaternion(degrees: Iterable[float]) -> tuple[float, float, float, float]:
    x, y, z = (math.radians(component) * 0.5 for component in degrees)
    sx, cx = math.sin(x), math.cos(x)
    sy, cy = math.sin(y), math.cos(y)
    sz, cz = math.sin(z), math.cos(z)
    return (
        sx * cy * cz + cx * sy * sz,
        cx * sy * cz - sx * cy * sz,
        cx * cy * sz + sx * sy * cz,
        cx * cy * cz - sx * sy * sz,
    )


def _scene_to_vmd_quaternion(
    quaternion: tuple[float, float, float, float],
) -> tuple[float, float, float, float]:
    """Mirror a right-handed SceneKit rotation into VMD's handedness."""
    x, y, z, w = quaternion
    return (-x, -y, z, w)


def _quaternion_multiply(
    left: tuple[float, float, float, float],
    right: tuple[float, float, float, float],
) -> tuple[float, float, float, float]:
    lx, ly, lz, lw = left
    rx, ry, rz, rw = right
    result = (
        lw * rx + lx * rw + ly * rz - lz * ry,
        lw * ry - lx * rz + ly * rw + lz * rx,
        lw * rz + lx * ry - ly * rx + lz * rw,
        lw * rw - lx * rx - ly * ry - lz * rz,
    )
    length = math.sqrt(sum(component * component for component in result))
    if length <= 1e-8:
        raise MotionSpecError("motion contains an invalid zero-length rotation")
    return tuple(component / length for component in result)


def build_vrma(spec: Any) -> bytes:
    """Build a deterministic VRM Animation GLB from an ARDY-compatible spec."""
    motion = validate_motion_spec(spec)
    node_indices = {name: index for index, name in enumerate(SKELETON)}
    nodes: list[dict[str, Any]] = []
    for name, (parent, translation) in SKELETON.items():
        node: dict[str, Any] = {"name": name, "translation": list(translation)}
        children = [node_indices[child] for child, (owner, _) in SKELETON.items() if owner == name]
        if children:
            node["children"] = children
        nodes.append(node)

    binary = bytearray()
    buffer_views: list[dict[str, Any]] = []
    accessors: list[dict[str, Any]] = []

    def add_accessor(values: Iterable[float], kind: str, width: int, *, time: bool = False) -> int:
        flattened = [float(value) for value in values]
        while len(binary) % 4:
            binary.append(0)
        offset = len(binary)
        binary.extend(struct.pack(f"<{len(flattened)}f", *flattened))
        buffer_views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(flattened) * 4})
        accessor: dict[str, Any] = {
            "bufferView": len(buffer_views) - 1,
            "componentType": 5126,
            "count": len(flattened) // width,
            "type": kind,
        }
        if time and flattened:
            accessor["min"] = [min(flattened)]
            accessor["max"] = [max(flattened)]
        accessors.append(accessor)
        return len(accessors) - 1

    samplers: list[dict[str, Any]] = []
    channels: list[dict[str, Any]] = []
    for bone, keyframes in motion["tracks"].items():
        input_accessor = add_accessor((keyframe["t"] for keyframe in keyframes), "SCALAR", 1, time=True)
        rotations: list[float] = []
        for keyframe in keyframes:
            rotations.extend(_euler_xyz_quaternion(keyframe["r"]))
        output_accessor = add_accessor(rotations, "VEC4", 4)
        samplers.append({"input": input_accessor, "output": output_accessor, "interpolation": "LINEAR"})
        channels.append({
            "sampler": len(samplers) - 1,
            "target": {"node": node_indices[bone], "path": "rotation"},
        })

    if motion.get("hips"):
        keyframes = motion["hips"]
        input_accessor = add_accessor((keyframe["t"] for keyframe in keyframes), "SCALAR", 1, time=True)
        positions: list[float] = []
        for keyframe in keyframes:
            x, y, z = keyframe["p"]
            positions.extend((x, 0.9 + y, z))
        output_accessor = add_accessor(positions, "VEC3", 3)
        samplers.append({"input": input_accessor, "output": output_accessor, "interpolation": "LINEAR"})
        channels.append({
            "sampler": len(samplers) - 1,
            "target": {"node": node_indices["hips"], "path": "translation"},
        })

    human_bones = {name: {"node": index} for name, index in node_indices.items()}
    document = {
        "asset": {"version": "2.0", "generator": "gmgn-motion-factory/1"},
        "extensionsUsed": ["VRMC_vrm_animation"],
        "extensions": {
            "VRMC_vrm_animation": {
                "specVersion": "1.0",
                "humanoid": {"humanBones": human_bones},
            }
        },
        "scene": 0,
        "scenes": [{"nodes": [node_indices["hips"]]}],
        "nodes": nodes,
        "animations": [{"name": motion["name"], "channels": channels, "samplers": samplers}],
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{"byteLength": len(binary)}],
        "extras": {"gmgn": {"duration": motion["duration"], "loop": motion["loop"]}},
    }
    json_bytes = json.dumps(document, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    json_bytes += b" " * ((4 - len(json_bytes) % 4) % 4)
    binary.extend(b"\x00" * ((4 - len(binary) % 4) % 4))
    total_length = 12 + 8 + len(json_bytes) + 8 + len(binary)
    return b"".join(
        (
            struct.pack("<4sII", b"glTF", 2, total_length),
            struct.pack("<II", len(json_bytes), 0x4E4F534A),
            json_bytes,
            struct.pack("<II", len(binary), 0x004E4942),
            bytes(binary),
        )
    )


VMD_BONE_NAMES: dict[str, str] = {
    # ARDY's humanoid hips is the common parent of both the torso and legs.
    # MMD's 下半身 only owns the leg chain, so mapping hips there makes flips
    # rotate the legs while the upper body stays upright. センター is the
    # shared body root and preserves the authored whole-body rotation.
    "hips": "センター",
    "spine": "上半身",
    "chest": "上半身2",
    "neck": "首",
    "head": "頭",
    "leftShoulder": "左肩",
    "leftUpperArm": "左腕",
    "leftLowerArm": "左ひじ",
    "leftHand": "左手首",
    "rightShoulder": "右肩",
    "rightUpperArm": "右腕",
    "rightLowerArm": "右ひじ",
    "rightHand": "右手首",
    "leftUpperLeg": "左足",
    "leftLowerLeg": "左ひざ",
    "leftFoot": "左足首",
    "rightUpperLeg": "右足",
    "rightLowerLeg": "右ひざ",
    "rightFoot": "右足首",
}

VMD_METERS_PER_UNIT = 0.08


def _vmd_fixed(value: str, length: int) -> bytes:
    encoded = value.encode("shift_jis")
    if len(encoded) > length:
        raise MotionSpecError(f"VMD string exceeds {length} bytes: {value}")
    return encoded + b"\0" * (length - len(encoded))


def _vmd_frame_index(seconds: float) -> int:
    return min(round(seconds * 30.0), 0xFFFFFFFF)


def build_vmd(spec: Any) -> bytes:
    """Build a finger-free VMD while preserving ARDY root translation."""
    motion = validate_motion_spec(spec)
    frames: dict[tuple[str, int], tuple[tuple[float, float, float], tuple[float, float, float, float]]] = {}
    for bone, keyframes in motion["tracks"].items():
        target_name = VMD_BONE_NAMES.get(bone)
        if target_name is None:
            continue
        for keyframe in keyframes:
            frame = _vmd_frame_index(keyframe["t"])
            frames[(target_name, frame)] = (
                (0.0, 0.0, 0.0),
                _scene_to_vmd_quaternion(
                    _euler_xyz_quaternion(keyframe["r"])
                ),
            )

    # Common PMX rigs expose only two torso bones. Preserve the extra humanoid
    # upper-chest segment by composing it after chest on 上半身2 instead of
    # silently dropping that part of the captured motion.
    for keyframe in motion["tracks"].get("upperChest", []):
        frame = _vmd_frame_index(keyframe["t"])
        translation, chest_rotation = frames.get(
            ("上半身2", frame),
            ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0)),
        )
        upper_chest_rotation = _scene_to_vmd_quaternion(
            _euler_xyz_quaternion(keyframe["r"])
        )
        frames[("上半身2", frame)] = (
            translation,
            _quaternion_multiply(chest_rotation, upper_chest_rotation),
        )

    # Preserve every root component authored by ARDY. The VMD stores movement in
    # conventional MMD units, while the shared motion spec stores metres.
    for keyframe in motion.get("hips", []):
        frame = _vmd_frame_index(keyframe["t"])
        x, y, z = keyframe["p"]
        existing_rotation = frames.get(
            ("センター", frame),
            ((0.0, 0.0, 0.0), (0.0, 0.0, 0.0, 1.0)),
        )[1]
        frames[("センター", frame)] = (
            (
                x / VMD_METERS_PER_UNIT,
                y / VMD_METERS_PER_UNIT,
                -z / VMD_METERS_PER_UNIT,
            ),
            existing_rotation,
        )

    if not frames:
        raise MotionSpecError("motion has no PMX-compatible tracks")

    interpolation = bytearray(64)
    linear = (20, 20, 107, 107)
    for control_point_index, value in enumerate(linear):
        for channel_index in range(4):
            interpolation[control_point_index * 4 + channel_index] = value

    body = bytearray()
    body.extend(_vmd_fixed("Vocaloid Motion Data 0002", 30))
    body.extend(_vmd_fixed("gmgn PMX", 20))
    ordered = sorted(frames.items(), key=lambda item: (item[0][0].encode("shift_jis"), item[0][1]))
    body.extend(struct.pack("<I", len(ordered)))
    for (bone_name, frame), (translation, rotation) in ordered:
        body.extend(_vmd_fixed(bone_name, 15))
        body.extend(struct.pack("<I3f4f", frame, *translation, *rotation))
        body.extend(interpolation)

    # Morph, camera, light, self-shadow and model/IK tracks are empty.
    body.extend(struct.pack("<IIIII", 0, 0, 0, 0, 0))
    return bytes(body)


def _atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    temporary.write_bytes(data)
    os.replace(temporary, path)


def publish_motion(
    *,
    spec: Any,
    output_root: Path,
    motion_id: str,
    display_name: str,
    version: str,
    activity_ids: Iterable[str],
    prompt: str,
    seed: int | None,
    generator: dict[str, Any],
    motion_format: str = "vrma",
    stride_speed: float | None = None,
    playback_rate: float | None = None,
    in_place: bool | None = None,
) -> dict[str, Any]:
    """Publish one immutable motion artifact and atomically update catalog.json."""
    if not _MOTION_ID.fullmatch(motion_id):
        raise MotionSpecError("motion id must be a stable lowercase identifier")
    if not _VERSION.fullmatch(version):
        raise MotionSpecError("version must be semantic versioning")
    if not display_name.strip():
        raise MotionSpecError("display name must not be empty")
    if motion_format not in {"vrma", "vmd"}:
        raise MotionSpecError("motion format must be vrma or vmd")
    motion = validate_motion_spec(spec)
    if stride_speed is not None and (not math.isfinite(stride_speed) or stride_speed <= 0):
        raise MotionSpecError("stride speed must be a positive finite number")
    if playback_rate is not None and (
        not math.isfinite(playback_rate) or playback_rate <= 0 or playback_rate > 8
    ):
        raise MotionSpecError("playback rate must be within (0, 8]")
    data = build_vrma(motion) if motion_format == "vrma" else build_vmd(motion)
    relative_path = Path("motions") / motion_id / version / f"{motion_id}.{motion_format}"
    artifact_path = output_root / relative_path
    if artifact_path.exists() and artifact_path.read_bytes() != data:
        raise MotionSpecError("published motion version is immutable")
    _atomic_write(artifact_path, data)
    entry = {
        "id": motion_id,
        "name": display_name.strip(),
        "version": version,
        "format": motion_format,
        "path": relative_path.as_posix(),
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
        "duration": motion["duration"],
        "loop": motion["loop"],
        "avatarFormats": ["vrm"] if motion_format == "vrma" else ["pmx"],
        "activityIDs": sorted(set(activity_ids)),
        "source": {
            "prompt": prompt,
            "seed": seed,
            "generator": generator,
        },
    }
    if stride_speed is not None:
        entry["strideSpeed"] = stride_speed
    if playback_rate is not None:
        entry["playbackRate"] = playback_rate
    if in_place is not None:
        entry["inPlace"] = in_place
    catalog_path = output_root / "catalog.json"
    if catalog_path.exists():
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
        if catalog.get("schemaVersion") != 1 or not isinstance(catalog.get("motions"), list):
            raise MotionSpecError("existing catalog has an unsupported schema")
    else:
        catalog = {"schemaVersion": 1, "motions": []}
    catalog["motions"] = [
        item
        for item in catalog["motions"]
        if not (item.get("id") == motion_id and item.get("version") == version)
    ] + [entry]
    catalog["motions"].sort(key=lambda item: (item["id"], item["version"]))
    _atomic_write(
        catalog_path,
        (json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8"),
    )
    return entry


def _linux_capacity() -> tuple[float, float, float]:
    values: dict[str, float] = {}
    meminfo = Path("/proc/meminfo")
    if meminfo.is_file():
        for line in meminfo.read_text(encoding="utf-8").splitlines():
            key, _, raw = line.partition(":")
            if key in {"MemTotal", "SwapFree"}:
                values[key] = float(raw.strip().split()[0]) / 1024.0 / 1024.0
    try:
        completed = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=memory.total",
                "--format=csv,noheader,nounits",
            ],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        vram = max(float(line.strip()) for line in completed.stdout.splitlines() if line.strip()) / 1024.0
    except (FileNotFoundError, subprocess.SubprocessError, ValueError):
        vram = 0.0
    return values.get("MemTotal", 0.0), values.get("SwapFree", 0.0), vram


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="GMGN offline motion factory")
    commands = parser.add_subparsers(dest="command", required=True)

    preflight = commands.add_parser("preflight", help="check whether this Linux worker can load ARDY")
    preflight.add_argument("--memory-gib", type=float)
    preflight.add_argument("--swap-gib", type=float)
    preflight.add_argument("--vram-gib", type=float)

    generate = commands.add_parser("generate", help="generate with ARDY and publish an avatar motion")
    generate.add_argument("--ardy-url", required=True)
    generate.add_argument("--prompt", required=True)
    generate.add_argument("--duration", type=float)
    generate.add_argument("--seed", type=int)
    generate.add_argument("--id", required=True)
    generate.add_argument("--name", required=True)
    generate.add_argument("--version", required=True)
    generate.add_argument("--activity", action="append", default=[])
    generate.add_argument("--output-root", type=Path, required=True)
    generate.add_argument("--model", default="ARDY-Core-RP-20FPS-Horizon40")
    generate.add_argument("--revision", default="unknown")
    generate.add_argument("--timeout", type=float, default=600.0)
    generate.add_argument("--format", choices=("vrma", "vmd"), default="vrma")
    generate.add_argument("--stride-speed", type=float)
    generate.add_argument("--playback-rate", type=float)
    generate.add_argument("--in-place", action="store_true", default=None)

    publish_spec = commands.add_parser(
        "publish-spec",
        help="publish an existing motion spec without contacting ARDY",
    )
    publish_spec.add_argument("--spec", type=Path, required=True)
    publish_spec.add_argument("--id", required=True)
    publish_spec.add_argument("--name", required=True)
    publish_spec.add_argument("--version", required=True)
    publish_spec.add_argument("--activity", action="append", default=[])
    publish_spec.add_argument("--prompt", required=True)
    publish_spec.add_argument("--seed", type=int)
    publish_spec.add_argument("--output-root", type=Path, required=True)
    publish_spec.add_argument("--engine", default="motion-spec")
    publish_spec.add_argument("--model", default="manual-preview")
    publish_spec.add_argument("--revision", default="local")
    publish_spec.add_argument("--format", choices=("vrma", "vmd"), default="vrma")
    publish_spec.add_argument("--stride-speed", type=float)
    publish_spec.add_argument("--playback-rate", type=float)
    publish_spec.add_argument("--in-place", action="store_true", default=None)

    import_bones = commands.add_parser(
        "import-bones",
        help="retarget one BONES-SEED SOMA BVH and publish it",
    )
    source = import_bones.add_mutually_exclusive_group(required=True)
    source.add_argument("--motion", help="exact motion name from the BONES-SEED viewer")
    source.add_argument("--bvh", type=Path, help="already downloaded BONES-SEED BVH")
    import_bones.add_argument(
        "--profile",
        type=Path,
        default=Path(__file__).with_name("profiles") / "bones-seed-soma-v1.json",
    )
    import_bones.add_argument("--id", required=True)
    import_bones.add_argument("--name", required=True)
    import_bones.add_argument("--version", required=True)
    import_bones.add_argument("--activity", action="append", default=[])
    import_bones.add_argument("--output-root", type=Path, required=True)
    import_bones.add_argument("--format", choices=("vrma", "vmd"), default="vrma")
    import_bones.add_argument("--output-fps", type=int, default=30)
    import_bones.add_argument("--start-frame", type=int)
    import_bones.add_argument("--end-frame", type=int)
    import_bones.add_argument(
        "--root-motion",
        choices=("full", "vertical-only", "none"),
        default="full",
    )
    import_bones.add_argument("--loop", action="store_true")
    import_bones.add_argument("--timeout", type=float, default=30.0)
    import_bones.add_argument("--revision", default="seed_metadata_v004")
    return parser


def main(argv: list[str] | None = None, *, stdout: TextIO | None = None) -> int:
    args = _parser().parse_args(argv)
    destination = stdout or sys.stdout
    if args.command == "preflight":
        discovered = _linux_capacity()
        memory = args.memory_gib if args.memory_gib is not None else discovered[0]
        swap = args.swap_gib if args.swap_gib is not None else discovered[1]
        vram = args.vram_gib if args.vram_gib is not None else discovered[2]
        capacity = assess_worker_capacity(memory_gib=memory, swap_gib=swap, vram_gib=vram)
        print(
            json.dumps(
                {
                    "status": capacity.status,
                    "maxConcurrency": capacity.max_concurrency,
                    "memoryGiB": round(memory, 2),
                    "swapGiB": round(swap, 2),
                    "vramGiB": round(vram, 2),
                    "reasons": list(capacity.reasons),
                },
                ensure_ascii=False,
                sort_keys=True,
            ),
            file=destination,
        )
        return 2 if capacity.status == "blocked" else 0

    if args.command == "generate":
        client = ArdyClient(args.ardy_url, timeout=args.timeout)
        spec = client.generate(text=args.prompt, duration=args.duration, seed=args.seed)
        entry = publish_motion(
            spec=spec,
            output_root=args.output_root,
            motion_id=args.id,
            display_name=args.name,
            version=args.version,
            activity_ids=args.activity,
            prompt=args.prompt,
            seed=args.seed,
            generator={
                "engine": "ardy",
                "model": args.model,
                "revision": args.revision,
            },
            motion_format=args.format,
            stride_speed=args.stride_speed,
            playback_rate=args.playback_rate,
            in_place=args.in_place,
        )
        print(json.dumps(entry, ensure_ascii=False, sort_keys=True), file=destination)
        return 0
    if args.command == "publish-spec":
        try:
            spec = json.loads(args.spec.read_text(encoding="utf-8"))
        except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise MotionSpecError(f"cannot read motion spec: {error}") from error
        entry = publish_motion(
            spec=spec,
            output_root=args.output_root,
            motion_id=args.id,
            display_name=args.name,
            version=args.version,
            activity_ids=args.activity,
            prompt=args.prompt,
            seed=args.seed,
            generator={
                "engine": args.engine,
                "model": args.model,
                "revision": args.revision,
            },
            motion_format=args.format,
            stride_speed=args.stride_speed,
            playback_rate=args.playback_rate,
            in_place=args.in_place,
        )
        print(json.dumps(entry, ensure_ascii=False, sort_keys=True), file=destination)
        return 0
    if args.command == "import-bones":
        from tools.motion.bones_seed_import import (
            BonesSeedError,
            BonesSeedViewerClient,
            retarget_bvh_to_motion_spec,
        )

        source_name: str
        if args.motion is not None:
            source_name = args.motion
            bvh = BonesSeedViewerClient(timeout=args.timeout).fetch_bvh(args.motion)
        else:
            source_name = args.bvh.stem
            try:
                bvh = args.bvh.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as error:
                raise BonesSeedError(f"cannot read BONES BVH: {error}") from error
        spec = retarget_bvh_to_motion_spec(
            bvh,
            name=args.name,
            loop=args.loop,
            output_fps=args.output_fps,
            start_frame=args.start_frame,
            end_frame=args.end_frame,
            root_motion=args.root_motion,
            profile_path=args.profile,
        )
        entry = publish_motion(
            spec=spec,
            output_root=args.output_root,
            motion_id=args.id,
            display_name=args.name,
            version=args.version,
            activity_ids=args.activity,
            prompt=f"BONES-SEED:{source_name}",
            seed=None,
            generator={
                "engine": "bones-seed",
                "model": "SOMA-BVH",
                "revision": args.revision,
            },
            motion_format=args.format,
        )
        print(json.dumps(entry, ensure_ascii=False, sort_keys=True), file=destination)
        return 0
    raise AssertionError(f"unhandled command: {args.command}")


if __name__ == "__main__":
    raise SystemExit(main())
