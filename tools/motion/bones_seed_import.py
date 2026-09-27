#!/usr/bin/env python3
"""Fetch and retarget individual BONES-SEED SOMA BVH motions.

The BONES BVH rotations are absolute joint orientations.  They must be
converted with the official SOMA T-pose orientations before entering gmgn's
humanoid-local motion format.  Raw BONES files are intentionally not vendored.
"""

from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Mapping
from urllib.parse import urlencode
from urllib.request import Request, urlopen

import numpy as np
from scipy.spatial.transform import Rotation

from tools.motion.gmgn_motion_factory import SKELETON, validate_motion_spec


class BonesSeedError(ValueError):
    """A BONES motion cannot be fetched, parsed, or safely retargeted."""


@dataclass(frozen=True)
class BVHJoint:
    name: str
    parent: str | None
    offset: tuple[float, float, float]
    channels: tuple[str, ...]
    channel_offset: int


@dataclass(frozen=True)
class BVHMotion:
    joints: tuple[BVHJoint, ...]
    frames: np.ndarray
    frame_time: float

    def values(
        self,
        frame: int,
        joint_name: str,
        channels: Iterable[str],
    ) -> tuple[float, ...]:
        joint = next((item for item in self.joints if item.name == joint_name), None)
        if joint is None:
            raise BonesSeedError(f"BVH joint is missing: {joint_name}")
        channel_indices = {name: index for index, name in enumerate(joint.channels)}
        result: list[float] = []
        for channel in channels:
            if channel not in channel_indices:
                raise BonesSeedError(f"{joint_name} has no {channel} channel")
            result.append(
                float(self.frames[frame, joint.channel_offset + channel_indices[channel]])
            )
        return tuple(result)


DEFAULT_HUMANOID_MAP: dict[str, str] = {
    "hips": "Hips",
    "spine": "Spine1",
    "chest": "Spine2",
    "upperChest": "Chest",
    "neck": "Neck1",
    "head": "Head",
    "leftShoulder": "LeftShoulder",
    "leftUpperArm": "LeftArm",
    "leftLowerArm": "LeftForeArm",
    "leftHand": "LeftHand",
    "rightShoulder": "RightShoulder",
    "rightUpperArm": "RightArm",
    "rightLowerArm": "RightForeArm",
    "rightHand": "RightHand",
    "leftUpperLeg": "LeftLeg",
    "leftLowerLeg": "LeftShin",
    "leftFoot": "LeftFoot",
    "rightUpperLeg": "RightLeg",
    "rightLowerLeg": "RightShin",
    "rightFoot": "RightFoot",
}

DEFAULT_PROFILE_PATH = Path(__file__).with_name("profiles") / "bones-seed-soma-v1.json"
_SAFE_MOTION_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
_CHANNEL_NAME = re.compile(r"^[XYZ](?:position|rotation)$")


class BonesSeedViewerClient:
    """Download one gated BONES-SEED BVH through the official viewer API."""

    BASE_URL = "https://seed-viewer.bones.studio/api/storage_local/somabvh/"
    MAX_RESPONSE_BYTES = 64 * 1024 * 1024

    def __init__(
        self,
        *,
        fetch: Callable[[str, float], bytes] | None = None,
        timeout: float = 30.0,
    ) -> None:
        self._fetch = fetch or self._default_fetch
        self.timeout = timeout

    @staticmethod
    def _default_fetch(url: str, timeout: float) -> bytes:
        request = Request(url, headers={"Accept": "application/json"})
        with urlopen(request, timeout=timeout) as response:
            body = response.read(BonesSeedViewerClient.MAX_RESPONSE_BYTES + 1)
        return body

    def fetch_bvh(self, motion_name: str) -> str:
        if not isinstance(motion_name, str) or not _SAFE_MOTION_NAME.fullmatch(motion_name):
            raise BonesSeedError("BONES motion name is unsafe")
        url = f"{self.BASE_URL}?{urlencode({'bvhpath': motion_name})}"
        try:
            body = self._fetch(url, self.timeout)
        except Exception as error:
            raise BonesSeedError(f"BONES viewer request failed: {error}") from error
        if not isinstance(body, bytes) or len(body) > self.MAX_RESPONSE_BYTES:
            raise BonesSeedError("BONES viewer response is invalid or too large")
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise BonesSeedError("BONES viewer returned invalid JSON") from error
        if not isinstance(payload, dict) or payload.get("name") != motion_name:
            raise BonesSeedError("BONES viewer returned a mismatched motion")
        tree = payload.get("tree")
        if not isinstance(tree, str) or not tree.lstrip().startswith("HIERARCHY"):
            raise BonesSeedError("BONES viewer response has no BVH hierarchy")
        return tree


def parse_bvh(text: str) -> BVHMotion:
    if not isinstance(text, str):
        raise BonesSeedError("BVH must be text")
    lines = [line.strip() for line in text.replace("\r", "").splitlines() if line.strip()]
    if not lines or lines[0] != "HIERARCHY":
        raise BonesSeedError("BVH hierarchy header is missing")
    try:
        motion_index = lines.index("MOTION")
    except ValueError as error:
        raise BonesSeedError("BVH motion section is missing") from error

    joints: list[dict[str, object]] = []
    joint_by_name: dict[str, dict[str, object]] = {}
    stack: list[str | None] = []
    pending: str | None = None
    channel_count = 0
    index = 1
    while index < motion_index:
        line = lines[index]
        pieces = line.split()
        if pieces[0] in {"ROOT", "JOINT"}:
            if len(pieces) != 2 or pieces[1] in joint_by_name:
                raise BonesSeedError(f"Invalid or duplicate BVH joint: {line}")
            parent = next((name for name in reversed(stack) if name is not None), None)
            record: dict[str, object] = {
                "name": pieces[1],
                "parent": parent,
                "offset": (0.0, 0.0, 0.0),
                "channels": (),
                "channel_offset": channel_count,
            }
            joints.append(record)
            joint_by_name[pieces[1]] = record
            pending = pieces[1]
        elif line == "End Site":
            pending = None
        elif line == "{":
            stack.append(pending)
            pending = None
        elif line == "}":
            if not stack:
                raise BonesSeedError("BVH hierarchy has an unmatched brace")
            stack.pop()
        elif pieces[0] == "OFFSET":
            if len(pieces) != 4 or not stack:
                raise BonesSeedError(f"Invalid BVH offset: {line}")
            current = stack[-1]
            if current is not None:
                try:
                    joint_by_name[current]["offset"] = tuple(float(value) for value in pieces[1:])
                except ValueError as error:
                    raise BonesSeedError(f"Invalid BVH offset: {line}") from error
        elif pieces[0] == "CHANNELS":
            if len(pieces) < 2 or not stack or stack[-1] is None:
                raise BonesSeedError(f"Invalid BVH channels: {line}")
            try:
                declared = int(pieces[1])
            except ValueError as error:
                raise BonesSeedError(f"Invalid BVH channel count: {line}") from error
            channels = tuple(pieces[2:])
            if declared != len(channels) or any(not _CHANNEL_NAME.fullmatch(item) for item in channels):
                raise BonesSeedError(f"Invalid BVH channels: {line}")
            current = joint_by_name[stack[-1]]
            current["channels"] = channels
            current["channel_offset"] = channel_count
            channel_count += declared
        else:
            raise BonesSeedError(f"Unsupported BVH hierarchy line: {line}")
        index += 1
    if stack or not joints or channel_count == 0:
        raise BonesSeedError("BVH hierarchy is incomplete")

    if motion_index + 2 >= len(lines):
        raise BonesSeedError("BVH frame metadata is incomplete")
    frames_match = re.fullmatch(r"Frames:\s*(\d+)", lines[motion_index + 1])
    time_match = re.fullmatch(
        r"Frame\s+Time:\s*([+\-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+\-]?\d+)?)",
        lines[motion_index + 2],
    )
    if not frames_match or not time_match:
        raise BonesSeedError("BVH frame metadata is invalid")
    frame_count = int(frames_match.group(1))
    frame_time = float(time_match.group(1))
    frame_lines = lines[motion_index + 3 :]
    if frame_count <= 0 or not math.isfinite(frame_time) or frame_time <= 0 or len(frame_lines) != frame_count:
        raise BonesSeedError("BVH frame count or frame time is invalid")
    rows: list[list[float]] = []
    for frame_index, line in enumerate(frame_lines):
        try:
            row = [float(value) for value in line.split()]
        except ValueError as error:
            raise BonesSeedError(f"BVH frame {frame_index} contains invalid numbers") from error
        if len(row) != channel_count or not all(math.isfinite(value) for value in row):
            raise BonesSeedError(f"BVH frame {frame_index} has the wrong channel count")
        rows.append(row)

    return BVHMotion(
        joints=tuple(
            BVHJoint(
                name=str(item["name"]),
                parent=item["parent"] if isinstance(item["parent"], str) else None,
                offset=tuple(item["offset"]),  # type: ignore[arg-type]
                channels=tuple(item["channels"]),  # type: ignore[arg-type]
                channel_offset=int(item["channel_offset"]),
            )
            for item in joints
        ),
        frames=np.asarray(rows, dtype=np.float64),
        frame_time=frame_time,
    )


def _rotation_matrix(values: Mapping[str, float]) -> np.ndarray:
    rotation_channels = [name for name in values if name.endswith("rotation")]
    if not rotation_channels:
        return np.eye(3)
    sequence = "".join(name[0] for name in rotation_channels)
    angles = [values[name] for name in rotation_channels]
    return Rotation.from_euler(sequence, angles, degrees=True).as_matrix()


def _orthonormal(matrix: np.ndarray) -> np.ndarray:
    try:
        return Rotation.from_matrix(np.asarray(matrix, dtype=np.float64).reshape(3, 3)).as_matrix()
    except (ValueError, TypeError) as error:
        raise BonesSeedError("SOMA T-pose profile contains an invalid matrix") from error


def load_t_pose_profile(path: Path = DEFAULT_PROFILE_PATH) -> dict[str, np.ndarray]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise BonesSeedError(f"Cannot load SOMA T-pose profile: {path}") from error
    raw = payload.get("tPoseOrientations") if isinstance(payload, dict) else None
    if not isinstance(raw, dict) or not raw:
        raise BonesSeedError("SOMA T-pose profile has no orientations")
    result: dict[str, np.ndarray] = {}
    for name, flattened in raw.items():
        if not isinstance(name, str) or not isinstance(flattened, list) or len(flattened) != 9:
            raise BonesSeedError("SOMA T-pose profile entry is invalid")
        result[name] = _orthonormal(np.asarray(flattened, dtype=np.float64))
    return result


def retarget_frame(
    absolute_rotations: Mapping[str, np.ndarray],
    *,
    parents: Mapping[str, str | None],
    t_pose_orientations: Mapping[str, np.ndarray],
    humanoid_map: Mapping[str, str],
    heading_correction: np.ndarray,
) -> dict[str, np.ndarray]:
    """Convert one SOMA absolute-orientation frame to target local rotations."""
    local: dict[str, np.ndarray] = {}
    for name, absolute in absolute_rotations.items():
        if name not in t_pose_orientations:
            raise BonesSeedError(f"SOMA T-pose orientation is missing: {name}")
        parent = parents.get(name)
        parent_orientation = (
            np.eye(3) if parent is None else t_pose_orientations.get(parent)
        )
        if parent_orientation is None:
            raise BonesSeedError(f"SOMA parent T-pose orientation is missing: {parent}")
        local[name] = _orthonormal(
            np.asarray(parent_orientation) @ np.asarray(absolute) @ np.asarray(t_pose_orientations[name]).T
        )

    global_rotations: dict[str, np.ndarray] = {}

    def resolve_global(name: str) -> np.ndarray:
        if name in global_rotations:
            return global_rotations[name]
        if name not in local:
            raise BonesSeedError(f"SOMA rotation is missing: {name}")
        parent = parents.get(name)
        result = local[name] if parent is None else resolve_global(parent) @ local[name]
        global_rotations[name] = _orthonormal(result)
        return global_rotations[name]

    correction = _orthonormal(heading_correction)
    result: dict[str, np.ndarray] = {}
    for target_name, source_name in humanoid_map.items():
        if target_name not in SKELETON:
            raise BonesSeedError(f"Unsupported target humanoid bone: {target_name}")
        source_global = correction @ resolve_global(source_name)
        target_parent = SKELETON[target_name][0]
        if target_parent is None or target_parent not in humanoid_map:
            result[target_name] = _orthonormal(source_global)
        else:
            parent_source = humanoid_map[target_parent]
            parent_global = correction @ resolve_global(parent_source)
            result[target_name] = _orthonormal(parent_global.T @ source_global)
    return result


def _absolute_rotations(motion: BVHMotion, frame_index: int) -> dict[str, np.ndarray]:
    result: dict[str, np.ndarray] = {}
    for joint in motion.joints:
        values = {
            channel: float(motion.frames[frame_index, joint.channel_offset + index])
            for index, channel in enumerate(joint.channels)
        }
        result[joint.name] = _rotation_matrix(values)
    return result


def _heading_correction(
    absolute: Mapping[str, np.ndarray],
    *,
    parents: Mapping[str, str | None],
    t_pose_orientations: Mapping[str, np.ndarray],
    hips_source: str,
) -> np.ndarray:
    hips_only = retarget_frame(
        absolute,
        parents=parents,
        t_pose_orientations=t_pose_orientations,
        humanoid_map={"hips": hips_source},
        heading_correction=np.eye(3),
    )["hips"]
    forward = hips_only @ np.asarray((0.0, 0.0, 1.0))
    horizontal_length = math.hypot(float(forward[0]), float(forward[2]))
    if horizontal_length < 1e-6:
        return np.eye(3)
    heading = math.atan2(float(forward[0]), float(forward[2]))
    return Rotation.from_euler("Y", -heading).as_matrix()


def retarget_bvh_to_motion_spec(
    text: str,
    *,
    name: str,
    loop: bool,
    output_fps: int = 30,
    start_frame: int | None = None,
    end_frame: int | None = None,
    root_motion: str = "full",
    profile_path: Path = DEFAULT_PROFILE_PATH,
    t_pose_orientations: Mapping[str, np.ndarray] | None = None,
    humanoid_map: Mapping[str, str] | None = None,
) -> dict[str, object]:
    motion = parse_bvh(text)
    source_fps = 1.0 / motion.frame_time
    if isinstance(output_fps, bool) or not isinstance(output_fps, int) or output_fps <= 0:
        raise BonesSeedError("Output FPS must be a positive integer")
    ratio = source_fps / output_fps
    rounded_ratio = round(ratio)
    if rounded_ratio < 1 or not math.isclose(ratio, rounded_ratio, rel_tol=0.0, abs_tol=1e-3):
        raise BonesSeedError("BVH frame rate must be an integer multiple of output FPS")
    if root_motion not in {"full", "vertical-only", "none"}:
        raise BonesSeedError("Root motion must be full, vertical-only, or none")
    first_frame = 0 if start_frame is None else start_frame
    last_frame = motion.frames.shape[0] - 1 if end_frame is None else end_frame
    if (
        isinstance(first_frame, bool)
        or isinstance(last_frame, bool)
        or not isinstance(first_frame, int)
        or not isinstance(last_frame, int)
        or first_frame < 0
        or last_frame < first_frame
        or last_frame >= motion.frames.shape[0]
    ):
        raise BonesSeedError("BONES source frame range is invalid")
    frame_indices = list(range(first_frame, last_frame + 1, rounded_ratio))
    if len(frame_indices) < 2:
        raise BonesSeedError("BONES motion is too short after sampling")

    orientations = (
        {key: _orthonormal(value) for key, value in t_pose_orientations.items()}
        if t_pose_orientations is not None
        else load_t_pose_profile(profile_path)
    )
    mapping = dict(humanoid_map or DEFAULT_HUMANOID_MAP)
    joint_names = {joint.name for joint in motion.joints}
    missing_sources = sorted(set(mapping.values()) - joint_names)
    if missing_sources:
        raise BonesSeedError(f"BVH is missing mapped joints: {', '.join(missing_sources)}")
    parents = {joint.name: joint.parent for joint in motion.joints}
    required_sources = set(mapping.values())
    pending_sources = list(required_sources)
    while pending_sources:
        parent = parents.get(pending_sources.pop())
        if parent is not None and parent not in required_sources:
            required_sources.add(parent)
            pending_sources.append(parent)
    missing_profiles = sorted(required_sources - set(orientations))
    if missing_profiles:
        raise BonesSeedError(f"SOMA profile is missing BVH joints: {', '.join(missing_profiles)}")

    first_absolute = {
        key: value
        for key, value in _absolute_rotations(motion, frame_indices[0]).items()
        if key in required_sources
    }
    hips_source = mapping.get("hips")
    if hips_source is None:
        raise BonesSeedError("Humanoid map must include hips")
    correction = _heading_correction(
        first_absolute,
        parents=parents,
        t_pose_orientations=orientations,
        hips_source=hips_source,
    )

    sampled: list[dict[str, np.ndarray]] = []
    for frame_index in frame_indices:
        absolute = {
            key: value
            for key, value in _absolute_rotations(motion, frame_index).items()
            if key in required_sources
        }
        sampled.append(
            retarget_frame(
                absolute,
                parents=parents,
                t_pose_orientations=orientations,
                humanoid_map=mapping,
                heading_correction=correction,
            )
        )

    tracks: dict[str, list[dict[str, object]]] = {}
    for target_name in mapping:
        rotations = Rotation.from_matrix(
            np.stack([frame[target_name] for frame in sampled], axis=0)
        ).as_euler("XYZ", degrees=False)
        rotations = np.unwrap(rotations, axis=0)
        degrees = np.rad2deg(rotations)
        # A 720-degree period preserves quaternion signs across complete rolls.
        # Keep already bounded samples unchanged, including published assets.
        degrees = np.where(np.abs(degrees) > 360.0, (degrees + 360.0) % 720.0 - 360.0, degrees)
        tracks[target_name] = [
            {"t": sample_index / output_fps, "r": [float(value) for value in degrees[sample_index]]}
            for sample_index in range(len(sampled))
        ]

    first_position = np.asarray(
        motion.values(frame_indices[0], hips_source, ("Xposition", "Yposition", "Zposition")),
        dtype=np.float64,
    )
    hips = []
    for sample_index, frame_index in enumerate(frame_indices):
        position = np.asarray(
            motion.values(frame_index, hips_source, ("Xposition", "Yposition", "Zposition")),
            dtype=np.float64,
        )
        meters = correction @ ((position - first_position) * 0.01)
        if root_motion == "vertical-only":
            meters[0] = 0.0
            meters[2] = 0.0
        elif root_motion == "none":
            meters[:] = 0.0
        hips.append(
            {"t": sample_index / output_fps, "p": [float(value) for value in meters]}
        )

    duration = (len(sampled) - 1) / output_fps
    return validate_motion_spec(
        {"name": name, "duration": duration, "loop": loop, "tracks": tracks, "hips": hips}
    )
