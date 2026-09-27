#!/usr/bin/env python3
"""Inspect/export one already-downloaded BONES walk; no download or installation.

Loop candidates retain a continuous source interval. Foot seam measurements
use the existing exporter's reference humanoid proportions, not a live avatar.
No blending, endpoint replacement, key insertion or root-Y removal is used.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

from tools.motion.bones_seed_import import parse_bvh, retarget_bvh_to_motion_spec
from tools.motion.gmgn_motion_factory import SKELETON, publish_motion


def validate_source(payload):
    digest = hashlib.sha256(payload["tree"].encode()).hexdigest()
    if payload.get("sha256") != digest:
        raise ValueError("cached BONES source digest mismatch")
    return payload["name"], payload["tree"], digest


def read_local_source(path):
    return validate_source(json.loads(Path(path).read_text()))


def motion_arrays(spec):
    bones = list(SKELETON)
    angles = np.asarray([[key["r"] for key in spec["tracks"][bone]] for bone in bones]).transpose(1, 0, 2)
    rotations = Rotation.from_euler("XYZ", angles.reshape(-1, 3), degrees=True)
    quaternions = rotations.as_quat().reshape(*angles.shape[:2], 4)
    local_rotations = rotations.as_matrix().reshape(*angles.shape[:2], 3, 3)
    roots = np.asarray([key["p"] for key in spec["hips"]])
    global_rotations, positions = {}, {}
    for index, bone in enumerate(bones):
        parent, offset = SKELETON[bone]
        if parent is None:
            global_rotations[bone] = local_rotations[:, index]
            positions[bone] = np.tile(offset, (len(roots), 1))
            positions[bone][:, 1] += roots[:, 1]
        else:
            global_rotations[bone] = global_rotations[parent] @ local_rotations[:, index]
            positions[bone] = positions[parent] + np.einsum("nij,j->ni", global_rotations[parent], offset)
    return {"quaternions": quaternions, "roots": roots,
            "feet": np.stack([positions["leftFoot"], positions["rightFoot"]], axis=1)}


def interval_metrics(arrays, start, end, *, fps):
    quaternions, roots, feet = (arrays[key] for key in ("quaternions", "roots", "feet"))
    seam = np.rad2deg(2 * np.arccos(np.clip(np.abs(np.sum(quaternions[start] * quaternions[end], axis=-1)), 0, 1)))
    elapsed = (end - start) / fps
    root_delta = roots[end] - roots[start]
    foot_seam = np.linalg.norm(feet[end] - feet[start], axis=-1)
    foot_velocity_delta = ((feet[end] - feet[end-1]) - (feet[start+1] - feet[start])) * fps
    excursion = np.rad2deg(2 * np.arccos(np.clip(np.abs(np.sum(quaternions[start:end+1] * quaternions[start], axis=-1)), 0, 1)))
    return {"startFrame": int(start), "endFrame": int(end), "durationSeconds": elapsed,
            "seamMaxDegrees": float(seam.max()), "seamMeanDegrees": float(seam.mean()),
            "motionMaxDegrees": float(excursion.max()),
            "rootVerticalSeamMeters": float(abs(root_delta[1])),
            "rootVerticalRangeMeters": float(np.ptp(roots[start:end+1, 1])),
            "rootDisplacementMeters": root_delta.tolist(),
            "strideSpeed": float(np.linalg.norm(root_delta[[0, 2]]) / elapsed),
            "horizontalPathSpeed": float(np.linalg.norm(np.diff(roots[start:end+1][:, [0, 2]], axis=0), axis=1).sum() / elapsed),
            "leftFootSeamMeters": float(foot_seam[0]), "rightFootSeamMeters": float(foot_seam[1]),
            "footSeamMaxMeters": float(foot_seam.max()),
            "footVelocitySeamMaxMetersPerSecond": float(np.linalg.norm(foot_velocity_delta, axis=-1).max())}


def select_candidates(arrays, *, fps, limit=5):
    quaternions, roots, feet = (arrays[key] for key in ("quaternions", "roots", "feet"))
    ranked = []
    for start in range(0, len(roots) - round(.8 * fps), 4):
        ends = np.arange(start + round(.8 * fps), min(len(roots), start + round(3 * fps)), 4)
        if not len(ends):
            continue
        seams = np.rad2deg(2 * np.arccos(np.clip(np.abs(np.sum(quaternions[ends] * quaternions[start], axis=-1)), 0, 1)))
        foot_seams = np.linalg.norm(feet[ends] - feet[start], axis=-1).max(axis=1)
        costs = seams.max(axis=1) + seams.mean(axis=1) + foot_seams * 100 + abs(roots[ends, 1] - roots[start, 1]) * 100
        speeds = np.linalg.norm(roots[ends][:, [0, 2]] - roots[start, [0, 2]], axis=1) / ((ends - start) / fps)
        costs[speeds < .1] = np.inf
        for index in np.argsort(costs)[:3]:
            if not np.isfinite(costs[index]):
                continue
            ranked.append((float(costs[index]), start, int(ends[index])))
    refined = {}
    for _, coarse_start, coarse_end in sorted(ranked)[:10]:
        for start in range(max(0, coarse_start-3), coarse_start+4):
            for end in range(coarse_end-3, min(len(roots), coarse_end+4)):
                if (start, end) in refined:
                    continue
                metrics = interval_metrics(arrays, start, end, fps=fps)
                if metrics["motionMaxDegrees"] < 20 or metrics["strideSpeed"] < .1:
                    continue
                metrics["cost"] = (metrics["seamMaxDegrees"] + metrics["seamMeanDegrees"]
                                   + metrics["footSeamMaxMeters"] * 100 + metrics["rootVerticalSeamMeters"] * 100)
                refined[(start, end)] = metrics
    return sorted(refined.values(), key=lambda item: item["cost"])[:limit]


def publish_walk(spec, fixture, output_root):
    count = fixture["endFrame"] - fixture["startFrame"] + 1
    if not spec["loop"] or len(spec["hips"]) != count or any(len(track) != count for track in spec["tracks"].values()):
        raise ValueError("walk must retain every frame in the selected continuous source interval")
    metrics = interval_metrics(motion_arrays(spec), 0, count-1, fps=fixture["outputFPS"])
    if (metrics["seamMaxDegrees"] > fixture["maxSeamDegrees"]
            or metrics["footSeamMaxMeters"] > fixture["maxFootSeamMeters"]
            or metrics["rootVerticalSeamMeters"] > fixture["maxVerticalSeamMeters"]
            or metrics["motionMaxDegrees"] < 20 or metrics["strideSpeed"] < .1):
        raise ValueError(f"selected walk violates recorded loop acceptance bounds: {metrics}")
    entry = publish_motion(
        spec=spec, output_root=output_root, motion_id="gmgn.motion.bones.walk-loop-vrm",
        display_name="BONES 前向行走循环（VRM）", version="1.0.0", activity_ids=["home.walk"],
        prompt=f"BONES-SEED:{fixture['filename']}", seed=None,
        generator={"engine": "bones-seed", "model": "SOMA-BVH", "revision": "seed_metadata_v004",
                   "sourceSHA256": fixture["sourceSHA256"], "startFrame": fixture["startFrame"],
                   "endFrame": fixture["endFrame"], "outputFPS": fixture["outputFPS"],
                   "rootMotion": "full", "sampling": "every original continuous source frame"},
        motion_format="vrma", stride_speed=metrics["strideSpeed"], playback_rate=1, in_place=True)
    return {"sourceFrameCount": count, "fixture": fixture, "metrics": metrics, "entry": entry,
            "rootPolicy": "artifact retains XYZ; runtime inPlace locks XZ only and retains full Y",
            "visualAcceptance": "not-performed"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--publish-selected", type=Path, help="Output catalog root; only publishes the checked-in accepted interval")
    args = parser.parse_args()
    name, bvh, digest = read_local_source(args.source)
    source = parse_bvh(bvh)
    fps = round(1 / source.frame_time)
    if args.publish_selected:
        fixture = json.loads(Path(__file__).with_name("fixtures").joinpath("bones-walk-vrm.json").read_text())
        if name != fixture["filename"] or digest != fixture["sourceSHA256"] or fps != fixture["outputFPS"]:
            raise ValueError("source does not match the approved walk fixture")
        spec = retarget_bvh_to_motion_spec(bvh, name=name, loop=True, output_fps=fps, root_motion="full",
                                          start_frame=fixture["startFrame"], end_frame=fixture["endFrame"])
        report = publish_walk(spec, fixture, args.publish_selected)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return
    spec = retarget_bvh_to_motion_spec(bvh, name=name, loop=False, output_fps=fps, root_motion="full")
    candidates = select_candidates(motion_arrays(spec), fps=fps)
    report = {"sourceName": name, "sourceSHA256": digest, "sourceFrames": len(source.frames),
              "sourceFrameTime": source.frame_time, "outputFPS": fps,
              "sampling": "all original frames; nominal source FPS; no key insertion or endpoint edits",
              "footMeasurement": "reference exported humanoid; XZ root removed, full source Y retained",
              "visualAcceptance": "not-performed", "installed": False, "candidates": candidates}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
