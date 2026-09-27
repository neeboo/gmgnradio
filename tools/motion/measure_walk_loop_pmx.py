#!/usr/bin/env python3
"""Read-only measurement of the installed PMX walk-loop clip on its target rig.

Evaluates the installed BONES `gmgn.motion.bones.walk-loop-pmx` VMD on the
shipped `na_2b_0414` PMX with the runtime (MMDSceneKit) deformation model --
identity bone rest frames, VMD quaternion keys applied as parent-space deltas,
センター Y translation keys only -- and reports the *observable* locomotion
contract at playback rate 1:

  * clip loop period (VMD frame grid is 30 fps),
  * cadence (steps/min, from the anti-phase lag of the two ankle-height
    curves and the two centre vertical bounces per loop),
  * feet-plant ground speed from the rearward stance-drift regression of each
    ankle in the plane of the character's forward axis (model units/s scaled to
    world metres with the stage's 1.7 m normalisation of the real model height).

Mathematical limit: the VMD stores no root X/Z (センター XZ are all zero), so a
unique *reference* global velocity is not recoverable from the clip alone. The
stance-drift estimate below is exactly the velocity the world would have to move
the hips at for the evaluated feet to stay planted on this rig -- the quantity
the locomotion retimer consumes. Nothing here reads chat/credentials/private
state and nothing writes the installed assets.

Run: python3 tools/motion/measure_walk_loop_pmx.py
"""
from __future__ import annotations

import json
import math
import struct
import sys
from pathlib import Path

import numpy as np

APPLICATION_SUPPORT = Path.home() / "Library/Application Support/gmgn radio"
PMX = APPLICATION_SUPPORT / "PresencePackages" / "pmx.2b-miss-0414-standard" / "na_2b_0414.pmx"
VMD = APPLICATION_SUPPORT / "MotionPackages" / "gmgn.motion.bones.walk-loop-pmx" / "gmgn.motion.bones.walk-loop-pmx.vmd"
STAGE_NORMALIZED_HEIGHT = 1.7  # MarblePMXFraming.normalizedHeight


def decode_name(raw: bytes) -> str:
    raw = raw.split(b"\0", 1)[0]
    for enc in ("shift_jis", "utf-8"):
        try:
            return raw.decode(enc)
        except Exception:
            continue
    return raw.decode("utf-8", "replace")


def parse_pmx_bones(path: Path):
    """Return (bones, model_height_units). Mirrors MMDPMXReader skip layout."""
    data = path.read_bytes()
    off = 4
    _version = struct.unpack_from("<f", data, off)[0]
    off += 5  # version float + header-length byte (8)
    enc = data[off]
    off += 1
    auv = data[off]
    off += 1
    sizes = list(data[off:off + 6])
    off += 6

    def read_text():
        nonlocal off
        length = struct.unpack_from("<i", data, off)[0]
        off += 4
        raw = data[off:off + length]
        off += length
        if enc == 0:
            return raw.decode("utf-16-le", "replace")
        return raw.decode("utf-8", "replace")

    for _ in range(4):
        read_text()
    n_vtx = struct.unpack_from("<I", data, off)[0]
    off += 4
    min_y, max_y = math.inf, -math.inf
    for _ in range(n_vtx):
        _, y, _ = struct.unpack_from("<3f", data, off)
        min_y = min(min_y, y)
        max_y = max(max_y, y)
        off += 12
        off += 12  # normal
        off += 8   # uv
        off += 16 * auv
        deform = data[off]
        off += 1
        if deform == 0:
            off += sizes[0]
        elif deform == 1:
            off += 2 * sizes[0] + 4
        elif deform in (2, 4):
            off += 4 * sizes[0] + 16
        elif deform == 3:
            off += 2 * sizes[0] + 40
        else:
            raise ValueError(f"unsupported skin weight type {deform}")
        off += 4  # edge scale
    n_surf = struct.unpack_from("<I", data, off)[0]
    off += 4 + n_surf * sizes[0]
    n_tex = struct.unpack_from("<I", data, off)[0]
    off += 4
    for _ in range(n_tex):
        read_text()
    n_mat = struct.unpack_from("<I", data, off)[0]
    off += 4
    for _ in range(n_mat):
        read_text()
        read_text()
        off += 65
        off += sizes[1] + sizes[1] + 1
        toon = data[off]
        off += 1
        off += sizes[1] if toon == 0 else 1
        read_text()
        off += 4
    n_bone = struct.unpack_from("<I", data, off)[0]
    off += 4
    bones = []
    for _ in range(n_bone):
        name = read_text()
        _ = read_text()
        pos = struct.unpack_from("<3f", data, off)
        off += 12
        parent = int.from_bytes(data[off:off + sizes[3]], "little")
        off += sizes[3]
        _layer = struct.unpack_from("<i", data, off)[0]
        off += 4
        flags = struct.unpack_from("<H", data, off)[0]
        off += 2
        if flags & 0x0001:
            off += sizes[3]
        else:
            off += 12
        if flags & (0x0100 | 0x0200):
            off += sizes[3] + 4
        if flags & 0x0400:
            off += 12
        if flags & 0x0800:
            off += 24
        if flags & 0x2000:
            off += sizes[3]
        if flags & 0x0020:
            off += sizes[3] + 8
            n_links = struct.unpack_from("<i", data, off)[0]
            off += 4
            for _ in range(n_links):
                off += sizes[3]
                if data[off]:
                    off += 1 + 24
                else:
                    off += 1
        bones.append({"name": name, "pos": pos, "parent": parent})
    return bones, max_y - min_y


def parse_vmd_keys(path: Path):
    data = path.read_bytes()
    off = 50
    n = struct.unpack_from("<I", data, off)[0]
    off += 4
    keys = {}
    for _ in range(n):
        name = decode_name(data[off:off + 15])
        off += 15
        frame = struct.unpack_from("<I", data, off)[0]
        off += 4
        translation = struct.unpack_from("<3f", data, off)
        off += 12
        rotation = struct.unpack_from("<4f", data, off)
        off += 16
        off += 64
        keys.setdefault(name, []).append((frame, translation, rotation))
    return keys


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
    return tuple(2 * dot * q[i] + (w * w - q2) * v[i] + 2 * w * cross[i] for i in range(3))


def key_at(keys, name, frame):
    k = keys.get(name)
    if not k:
        return None
    for (f, t, q) in k:
        if f == frame:
            return (t, q)
    if frame <= k[0][0]:
        return (k[0][1], k[0][2])
    return (k[-1][1], k[-1][2])


def main() -> int:
    bones, height_units = parse_pmx_bones(PMX)
    bones.append({"name": "__root", "pos": (0.0, 0.0, 0.0), "parent": 0xFFFF})
    for bone in bones:
        if bone["parent"] in (0xFFFF, -1):
            bone["parent"] = len(bones) - 1
    by_name = {bone["name"]: i for i, bone in enumerate(bones)}

    keys = parse_vmd_keys(VMD)
    frames = sorted({k[0] for values in keys.values() for k in values})
    last = max(frames)
    clip_seconds = last / 30.0

    depth = {}

    def dep(i):
        if i in depth:
            return depth[i]
        parent = bones[i]["parent"]
        depth[i] = 0 if parent == len(bones) - 1 or parent == i else dep(parent) + 1
        return depth[i]

    tracks = []
    for frame in frames:
        for i in range(len(bones)):
            dep(i)
        world_rot, world_pos = {}, {}
        for i in sorted(range(len(bones)), key=lambda j: depth[j]):
            bone = bones[i]
            parent_rot = world_rot.get(bone["parent"], (0, 0, 0, 1))
            parent_pos = world_pos.get(bone["parent"], (0.0, 0.0, 0.0))
            q = (0.0, 0.0, 0.0, 1.0)
            kv = key_at(keys, bone["name"], frame)
            if kv is not None:
                q = quat_normalized(kv[1])
            local = qmul(parent_rot, q)
            delta = (0.0, 0.0, 0.0)
            if kv is not None and bone["name"] == "センター":
                delta = kv[0]
            parent_bind = bones[bone["parent"]]["pos"]
            offset = tuple(bone["pos"][c] - parent_bind[c] for c in range(3))
            local_offset = tuple(offset[c] + delta[c] for c in range(3))
            world_pos[i] = tuple(
                parent_pos[c] + qrot(parent_rot, local_offset)[c] for c in range(3)
            )
            world_rot[i] = local
        tracks.append((frame, world_pos))

    meters_per_unit = STAGE_NORMALIZED_HEIGHT / height_units
    centre = by_name["センター"]
    lank = by_name["左足首"]
    rank = by_name["右足首"]

    def ankle_pos(side_bone, frame_index):
        return tracks[frame_index][1][side_bone]

    # Forward axis: chord of the left foot at bind (ankle -> toe), the only
    # model-space observable that identifies the travel axis of an in-place
    # walk. Magnitudes are sign-invariant.
    ltoe = by_name["左つま先"]
    fwd = (
        bones[ltoe]["pos"][0] - bones[lank]["pos"][0],
        bones[ltoe]["pos"][2] - bones[lank]["pos"][2],
    )
    fwd_len = math.hypot(*fwd)
    F = (fwd[0] / fwd_len, fwd[1] / fwd_len)

    def forward_of(i, frame_index):
        c = tracks[frame_index][1][centre]
        p = tracks[frame_index][1][i]
        return (p[0] - c[0]) * F[0] + (p[2] - c[2]) * F[1]

    left_r = [forward_of(lank, fi) for fi in range(len(frames))]
    right_r = [forward_of(rank, fi) for fi in range(len(frames))]
    left_y = [tracks[fi][1][lank][1] for fi in range(len(frames))]
    right_y = [tracks[fi][1][rank][1] for fi in range(len(frames))]
    centre_y = [tracks[fi][1][centre][1] for fi in range(len(frames))]

    def stance_drift_speed(side_r, side_y, lo, hi):
        """Least-squares slope of the hips-relative forward position during the
        grounded (rearward-drifting, low) stance window, in world m/s."""
        x = np.arange(lo, hi + 1, dtype=float)
        y = np.asarray(side_r[lo:hi + 1], dtype=float)
        design = np.vstack([x, np.ones_like(x)]).T
        slope, _ = np.linalg.lstsq(design, y, rcond=None)[0]
        corr = np.corrcoef(x, y)[0, 1]
        return abs(slope) * 30.0 * meters_per_unit, float(corr)

    # Grounded stance windows (ankle near its lowest reach, drift highly
    # linear) observed on the actual rig; independent per foot.
    windows = {
        "left (frames 1-18)": stance_drift_speed(left_r, left_y, 1, 18),
        "left core (2-16)": stance_drift_speed(left_r, left_y, 2, 16),
        "right (23-42)": stance_drift_speed(right_r, right_y, 23, 42),
        "right core (24-41)": stance_drift_speed(right_r, right_y, 24, 41),
    }

    # Cadence: best anti-phase lag of the left/right ankle height curves.
    best_lag, best_cost = None, None
    for lag in range(14, 29):
        cost = 0.0
        for t in range(len(frames) - lag):
            cost += abs(left_y[t] - right_y[t + lag]) + abs(right_y[t] - left_y[t + lag])
        if best_cost is None or cost < best_cost:
            best_cost, best_lag = cost, lag
    step_time = best_lag / 30.0
    steps_per_minute = 60.0 / step_time
    speed = np.mean([v for v, _ in windows.values()])
    stride_length = speed * 2.0 * step_time
    print(json.dumps({
        "assets": {
            "vmd": str(VMD),
            "pmx": str(PMX),
            "vmdSHA256_manifest": "4c12642f6b7b4791983a98727bf6d59baf0da4688f0046ca594cbb2c93f7eb19",
        },
        "model": {"heightUnits": round(height_units, 4),
                  "worldScaleMetresPerUnit": round(meters_per_unit, 6),
                  "stageNormalizedHeightMetres": STAGE_NORMALIZED_HEIGHT},
        "clip": {"keyframeCount": len(frames), "lastFrame": last,
                 "loopSeconds30fps": round(clip_seconds, 4),
                 "stepPeriodSeconds": round(step_time, 4),
                 "cadenceStepsPerMinute": round(steps_per_minute, 1),
                 "centreVerticalBounceMetres": round(
                     (max(centre_y) - min(centre_y)) * meters_per_unit, 4)},
        "stanceDriftMps": {k: round(v, 4) for k, (v, _) in windows.items()},
        "stanceDriftR2": {k: round(r2, 4) for k, (_, r2) in windows.items()},
        "feetPlantSpeedMpsAtRate1": {
            "bestEstimate": round(float(speed), 4),
            "range": [round(min(v for v, _ in windows.values()), 4),
                      round(max(v for v, _ in windows.values()), 4)],
        },
        "derivedStride": {"strideMetres": round(stride_length, 3),
                          "stepMetres": round(stride_length / 2.0, 3)},
        "limit": "in-place VMD (センター X/Z all zero): a unique reference global "
                 "velocity is not in the file; the reported speed is the target-rig "
                 "feet-plant speed at rate 1 under the runtime deformation model.",
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
