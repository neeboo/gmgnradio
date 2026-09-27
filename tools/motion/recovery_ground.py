#!/usr/bin/env python3
"""Offline ground-contact engine for one-shot PMX recovery clips.

Scope (read-only product assets, no installed-package writes):
  * decodes the actual target PMX (na_2b_0414) geometry with skin weights and
    evaluates the *skinned mesh* low-height envelope per frame under the
    runtime (MMDSceneKit) deformation model: identity bone rest frames, VMD
    quaternion keys as parent-space deltas, センター translation keys applied
    as the only root translation.
  * provides the ground-contact metrics (penetration depth, low-contact gap)
    and the runtime foot-sole reference emulation used by the calibration.

The runtime places the model so the *bind-pose* lowest contact of the feet
rests on the stage floor and then scales the bind bounds to a 1.7 m
normalisation.  In model units the ground plane therefore is the bind
foot-sole reference Y (``rest_foot_reference_y``), computed the same way as
PMXSoleGrounding.referenceY in PMXStageAvatarRenderer (foot-influenced low
vertices, min Y), with the whole-mesh bind minimum reported alongside.

This file is pure measurement/decoding; calibration lives in
``recovery_ground_calib.py`` and tests in ``tests/test_recovery_ground_calib.py``.
"""

from __future__ import annotations

import math
import struct
from pathlib import Path

import numpy as np

STAGE_NORMALIZED_HEIGHT = 1.7

APPLICATION_SUPPORT = Path.home() / "Library/Application Support/gmgn radio"
PMX = (
    APPLICATION_SUPPORT
    / "PresencePackages"
    / "pmx.2b-miss-0414-standard"
    / "na_2b_0414.pmx"
)
MOTION_PACKAGES = APPLICATION_SUPPORT / "MotionPackages"


def decode_name(raw: bytes) -> str:
    raw = raw.split(b"\0", 1)[0]
    for enc in ("shift_jis", "utf-8"):
        try:
            return raw.decode(enc)
        except UnicodeDecodeError:
            continue
    return raw.decode("utf-8", "replace")


class Reader:
    def __init__(self, data: bytes):
        self.d = data
        self.o = 0

    def u8(self) -> int:
        value = self.d[self.o]
        self.o += 1
        return value

    def i32(self) -> int:
        value = struct.unpack_from("<i", self.d, self.o)[0]
        self.o += 4
        return value

    def u32(self) -> int:
        value = struct.unpack_from("<I", self.d, self.o)[0]
        self.o += 4
        return value

    def u16(self) -> int:
        value = struct.unpack_from("<H", self.d, self.o)[0]
        self.o += 2
        return value

    def f32(self) -> float:
        value = struct.unpack_from("<f", self.d, self.o)[0]
        self.o += 4
        return value

    def vec3(self):
        return (self.f32(), self.f32(), self.f32())

    def skip(self, n: int) -> None:
        self.o += n

    def index(self, size: int) -> int:
        raw = self.d[self.o : self.o + size]
        self.o += size
        return int.from_bytes(raw, "little", signed=(size == 4))

    def text(self) -> str:
        length = self.i32()
        raw = self.d[self.o : self.o + length]
        self.o += length
        if self.encoding == 0:
            try:
                return raw.decode("utf-16-le")
            except UnicodeDecodeError:
                return raw.decode("utf-16-le", "replace")
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            return raw.decode("utf-8", "replace")


class Rig:
    """Decoded target PMX: bones, vertices, skin influences."""

    def __init__(self, path: Path = PMX):
        data = Path(path).read_bytes()
        if data[:4] != b"PMX ":
            raise ValueError(f"not a PMX file: {path}")
        r = Reader(data)
        r.skip(4)  # magic
        r.o += 4 + 1  # version float, header length byte
        r.encoding = r.u8()
        additional_uv = r.u8()
        idx_sizes = [r.u8() for _ in range(6)]
        for _ in range(4):
            r.text()  # model/comment names

        n_vtx = r.u32()
        positions = np.empty((n_vtx, 3), dtype=np.float32)
        # skin slots (up to 4, padded): bone index (int16, -1 = none), weight
        skin_idx = np.full((n_vtx, 4), -1, dtype=np.int16)
        skin_w = np.zeros((n_vtx, 4), dtype=np.float32)
        for vertex in range(n_vtx):
            pos = r.vec3()
            positions[vertex] = pos
            r.skip(12 + 8 + 16 * additional_uv)  # normal + uv (+extra uv)
            deform = r.u8()
            if deform == 0:  # BDEF1
                skin_idx[vertex, 0] = r.index(idx_sizes[0])
                skin_w[vertex, 0] = 1.0
            elif deform == 1:  # BDEF2
                b0 = r.index(idx_sizes[0])
                b1 = r.index(idx_sizes[0])
                w0 = r.f32()
                skin_idx[vertex, 0] = b0
                skin_idx[vertex, 1] = b1
                skin_w[vertex, 0] = w0
                skin_w[vertex, 1] = 1.0 - w0
            elif deform == 2:  # BDEF4
                for slot in range(4):
                    skin_idx[vertex, slot] = r.index(idx_sizes[0])
                for slot in range(4):
                    skin_w[vertex, slot] = r.f32()
            elif deform == 3:  # SDEF -> BDEF2 approximation (positions only)
                b0 = r.index(idx_sizes[0])
                b1 = r.index(idx_sizes[0])
                w0 = r.f32()
                r.skip(3 * 4 * 3)  # C, R0, R1
                skin_idx[vertex, 0] = b0
                skin_idx[vertex, 1] = b1
                skin_w[vertex, 0] = w0
                skin_w[vertex, 1] = 1.0 - w0
            else:  # deform == 4 (QDEF) shares BDEF4 layout
                for slot in range(4):
                    skin_idx[vertex, slot] = r.index(idx_sizes[0])
                for slot in range(4):
                    skin_w[vertex, slot] = r.f32()
            r.skip(4)  # edge scale
        r.skip(r.u32() * idx_sizes[0])  # surfaces
        for _ in range(r.u32()):
            r.text()  # texture names
        for _ in range(r.u32()):  # materials
            r.text()
            r.text()
            r.skip(4 * 4 + 3 * 4 + 4 + 3 * 4 + 1 + 4 * 4 + 4)
            r.index(idx_sizes[1])
            r.index(idx_sizes[1])
            r.u8()
            toon_flag = r.u8()
            if toon_flag == 0:
                r.index(idx_sizes[1])
            else:
                r.u8()
            r.text()
            r.u32()

        n_bone = r.u32()
        bones = []
        for _ in range(n_bone):
            name = r.text()
            r.text()
            pos = r.vec3()
            parent = r.index(idx_sizes[3])
            r.skip(4)  # layer
            flags = r.u16()
            if flags & 0x0001:
                r.index(idx_sizes[3])
            else:
                r.skip(12)
            if flags & (0x0100 | 0x0200):
                r.index(idx_sizes[3])
                r.skip(4)
            if flags & 0x0400:
                r.skip(12)
            if flags & 0x0800:
                r.skip(24)
            if flags & 0x2000:
                r.index(idx_sizes[3])
            if flags & 0x0020:
                r.index(idx_sizes[3])
                r.skip(8)
                for _ in range(r.i32()):
                    r.index(idx_sizes[3])
                    if r.u8():
                        r.skip(24)
            bones.append(
                {"name": name, "pos": pos, "parent": parent, "flags": flags}
            )

        # ---- static per-vertex bind data for vectorised skinning ----
        n_bone_total = len(bones) + 1  # + synthetic identity root
        root = n_bone_total - 1
        self.bones = bones
        self.root = root
        for bone in bones:
            if bone["parent"] in (0xFFFF, -1):
                bone["parent"] = root
        self.bone_name_index = {bone["name"]: i for i, bone in enumerate(bones)}
        bind_pos = np.empty((n_bone_total, 3), dtype=np.float32)
        for i, bone in enumerate(bones):
            bind_pos[i] = bone["pos"]
        bind_pos[root] = (0.0, 0.0, 0.0)
        self.bind_pos = bind_pos

        # depth order
        depth = np.zeros(n_bone_total, dtype=np.int32)

        def dep(i: int) -> int:
            if depth[i] == 0:
                parent = bones[i]["parent"] if i != root else root
                if parent != i and parent != root:
                    depth[i] = dep(parent) + 1
            return int(depth[i])

        for i in range(n_bone_total):
            dep(i)
        self.order = sorted(range(n_bone_total), key=lambda i: int(depth[i]))
        self.parent = np.asarray(
            [bones[i]["parent"] if i != root else root for i in range(n_bone_total)],
            dtype=np.int32,
        )

        # vertices: (v, slot) -> bone index; weights already per-slot
        valid = skin_idx >= 0
        self.skin_idx = skin_idx
        self.skin_w = skin_w
        self.skin_valid = valid
        self.positions = positions
        self.bind_min_y = float(positions[:, 1].min())
        self.height_units = float(positions[:, 1].max() - self.bind_min_y)

        # foot-influenced low vertices (runtime PMXSoleGrounding probe set)
        foot_bone_ids = [
            i
            for name, i in self.bone_name_index.items()
            if _is_foot_bone_name(name)
        ]
        influence = np.zeros(n_vtx, dtype=bool)
        for slot in range(4):
            in_foot = np.isin(skin_idx[:, slot], foot_bone_ids)
            influence |= in_foot & (skin_w[:, slot] > 0.05)
        self.foot_vertex_mask = influence
        sole_band = max(self.height_units * 0.005, 0.001)
        foot_min_y = float(positions[influence, 1].min())
        low_foot = influence & (positions[:, 1] <= foot_min_y + sole_band)
        self.rest_foot_reference_y = float(positions[low_foot, 1].min())
        self.mpu = STAGE_NORMALIZED_HEIGHT / self.height_units

        # bone bind heads per vertex/slot for fast skinning (N,4,3)
        n_v = n_vtx
        heads = np.zeros((n_v, 4, 3), dtype=np.float32)
        for slot in range(4):
            idx = np.clip(skin_idx[:, slot], 0, n_bone_total - 1)
            heads[:, slot] = bind_pos[idx]
        self.heads = heads  # bone head world bind position per slot
        self.diff = positions[:, None, :] - heads  # (N,4,3)

    def quat_to_y_row(self, qx, qy, qz, qw):
        """Second row of the rotation matrix for quaternion (x,y,z,w)."""
        return (
            2.0 * (qx * qy + qz * qw),
            1.0 - 2.0 * (qx * qx + qz * qz),
            2.0 * (qy * qz - qx * qw),
        )

    def skinned_min_profile(self, q, p) -> np.ndarray:
        """Return per-vertex skinned Y for one frame.

        q: (B,4) world quaternions; p: (B,3) world bone positions (root at
        origin/identity when not moved).  Vectorised linear-blend skinning.
        """
        n = len(self.positions)
        ys = np.empty((n, 4), dtype=np.float32)
        for slot in range(4):
            idx = self.skin_idx[:, slot].copy()
            idx[idx < 0] = 0
            qs = q[idx]
            qx, qy, qz, qw = qs[:, 0], qs[:, 1], qs[:, 2], qs[:, 3]
            diff = self.diff[:, slot]
            contrib = (
                (2.0 * (qx * qy + qz * qw)) * diff[:, 0]
                + (1.0 - 2.0 * (qx * qx + qz * qz)) * diff[:, 1]
                + (2.0 * (qy * qz - qx * qw)) * diff[:, 2]
                + p[idx, 1]
            )
            ys[:, slot] = contrib
        return (ys * self.skin_w).sum(axis=1)


def _is_foot_bone_name(name: str) -> bool:
    normalized = name.lower()
    if "足首" in normalized or "つま先" in normalized:
        return True
    if "ankle" in normalized or "toe" in normalized:
        return True
    return normalized in {"bone017", "bone018", "bone021", "bone022"}


def quat_normalized(q):
    length = math.sqrt(sum(c * c for c in q))
    if length < 1e-12:
        return (0.0, 0.0, 0.0, 1.0)
    return tuple(c / length for c in q)


def qmul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def qrot(q, v):
    x, y, z, w = q
    dot = x * v[0] + y * v[1] + z * v[2]
    q2 = x * x + y * y + z * z
    cross = (y * v[2] - z * v[1], z * v[0] - x * v[2], x * v[1] - y * v[0])
    return tuple(
        2 * dot * q[i] + (w * w - q2) * v[i] + 2 * w * cross[i] for i in range(3)
    )


class VMDClip:
    """Bone-keyframe VMD reader with per-record offsets for Y-only patching."""

    HEADER = 50  # model name (30) + motion name (20)

    def __init__(self, path: Path):
        self.path = Path(path)
        self.data = bytearray(Path(path).read_bytes())
        off = self.HEADER
        n_bone = struct.unpack_from("<I", self.data, off)[0]
        off += 4
        self.keys = {}
        self.records = []
        for _ in range(n_bone):
            record_offset = off
            name = decode_name(bytes(self.data[off : off + 15]))
            off += 15
            frame = struct.unpack_from("<I", self.data, off)[0]
            off += 4
            translation = struct.unpack_from("<3f", self.data, off)
            off += 12
            rotation = struct.unpack_from("<4f", self.data, off)
            off += 16
            off += 64  # interpolation
            record = {
                "name": name,
                "frame": frame,
                "offset": record_offset,
                "y_offset": record_offset + 15 + 4 + 4,
            }
            self.records.append(record)
            self.keys.setdefault(name, []).append(
                (frame, translation, rotation, record)
            )
        self.keys_tail_offset = off
        for name in self.keys:
            self.keys[name].sort(key=lambda item: item[0])
        self.all_frames = sorted(
            {item[0] for values in self.keys.values() for item in values}
        )

    @property
    def last_frame(self) -> int:
        return self.all_frames[-1]

    def center_y(self, frame: int) -> float:
        for name, key_list in self.keys.items():
            if name != "センター":
                continue
            for (f, translation, _rotation, _record) in key_list:
                if f == frame:
                    return translation[1]
            return translation[1]  # post-hold by sorted last
        raise KeyError("センター keys missing")

    def patch_center_y(self, corrections: dict[int, float], out_path: Path) -> int:
        """Add per-frame Y *corrections* (deltas) to existing センター keys.

        ``corrections[frame]`` is added to the original key translation Y,
        matching the build_correction contract (delta on the raw センター Y).
        Writing deltas verbatim as absolute Y was a real bug (a terminal
        get-up key of 11.8668 + delta -12.0455 must land at ~ -0.179, not at
        -12.0455).  Every corrected frame must have an existing センター key;
        sparse keying is refused, never silently widened.
        """
        data = bytearray(self.data)
        changed = 0
        for record in self.records:
            if record["name"] != "センター":
                continue
            frame = record["frame"]
            if frame not in corrections:
                continue
            original = struct.unpack_from("<f", data, record["y_offset"])[0]
            struct.pack_into(
                "<f", data, record["y_offset"], original + float(corrections[frame])
            )
            changed += 1
        if changed == 0:
            raise ValueError("no センター keys patched")
        if changed != len(corrections):
            raise ValueError(
                f"センター key grid sparse: {changed}/{len(corrections)} frames "
                "patched; refusing to emit a partially corrected candidate"
            )
        Path(out_path).write_bytes(bytes(data))
        return changed


def vmd_key_at(key_list, frame: int):
    if not key_list:
        return None
    for (f, translation, rotation, _record) in key_list:
        if f == frame:
            return (translation, rotation)
    if frame <= key_list[0][0]:
        return (key_list[0][1], key_list[0][2])
    return (key_list[-1][1], key_list[-1][2])


def require_dense(clip: VMDClip) -> dict[str, object]:
    """Audit per-frame keying density; refuse sparse clips.

    ``vmd_key_at`` falls back to an endpoint on missing keys, which is
    only faithful when every *keyed* bone is keyed on every integer frame of
    the clip (grid gap 1).  With sparse keying the offline FK would silently
    ignore the runtime interpolation, so this raises instead of evaluating —
    we do not widen the implementation to interpolate.
    """
    if not clip.keys:
        raise ValueError("clip has no bone keys; density audit impossible")
    last = clip.last_frame
    report: dict[str, object] = {}
    sparse = []
    for name, key_list in clip.keys.items():
        frames = [item[0] for item in key_list]
        if frames != list(range(last + 1)):
            sparse.append((name, len(frames), frames[0], frames[-1]))
    report["keyedBones"] = len(clip.keys)
    report["frameSpan"] = [0, last]
    report["sparseBones"] = sparse
    if sparse:
        raise ValueError(
            f"VMD keying is sparse (expected every bone keyed 0..{last}): "
            f"{len(sparse)}/{len(clip.keys)} bones {sparse[:6]}"
        )
    return report


def evaluate_clip(
    rig: Rig,
    clip: VMDClip,
    frames=None,
    y_override: dict[int, float] | None = None,
):
    """FK + skinned low-envelope for each integer frame of a clip.

    y_override replaces センター translation Y per frame (calibration preview).
    Returns dict of per-frame arrays and per-frame bone world data needed by
    higher-level metrics.
    """
    if frames is None:
        frames = range(0, clip.last_frame + 1)
    bones = rig.bones
    by_name = rig.bone_name_index
    parent = rig.parent
    order = rig.order

    per_frame = []
    for frame in frames:
        world_q = np.zeros((len(bones) + 1, 4), dtype=np.float64)
        world_p = np.zeros((len(bones) + 1, 3), dtype=np.float64)
        world_q[rig.root] = (0.0, 0.0, 0.0, 1.0)
        for i in order:
            bone = bones[i] if i != rig.root else None
            parent_rot = world_q[parent[i]]
            parent_pos = world_p[parent[i]]
            q = (0.0, 0.0, 0.0, 1.0)
            translation_delta = (0.0, 0.0, 0.0)
            if bone is not None:
                key_list = clip.keys.get(bone["name"])
                kv = vmd_key_at(key_list, frame)
                if kv is not None:
                    q = quat_normalized(kv[1])
                    if bone["name"] == "センター":
                        translation_delta = kv[0]
                        if y_override is not None and frame in y_override:
                            translation_delta = (
                                translation_delta[0],
                                y_override[frame],
                                translation_delta[2],
                            )
            parent_bind = rig.bind_pos[parent[i]]
            bind_self = rig.bind_pos[i]
            offset = tuple(
                bind_self[c] - parent_bind[c] + translation_delta[c] for c in range(3)
            )
            world_p[i] = tuple(
                parent_pos[c] + qrot(parent_rot, offset)[c] for c in range(3)
            )
            world_q[i] = qmul(parent_rot, q)
        # world quats for skinning: convert tuples -> array (B,4)
        q_array = np.asarray(world_q, dtype=np.float64)
        p_array = np.asarray(world_p, dtype=np.float64)
        skinned_y = rig.skinned_min_profile(q_array, p_array)
        per_frame.append(
            {
                "frame": frame,
                "min_y": float(skinned_y.min()),
                "q05": float(np.quantile(skinned_y, 0.05)),
                "q01": float(np.quantile(skinned_y, 0.01)),
                "q005": float(np.quantile(skinned_y, 0.005)),
                "center_y": float(world_p[by_name["センター"]][1])
                if "センター" in by_name
                else float("nan"),
                "pos": world_p,
                "q": q_array,
            }
        )
    return per_frame
