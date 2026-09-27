#!/usr/bin/env python3
"""Build private BONES resident clips from an auditable source selection.

No authored keyframes, interpolation, mirroring, or endpoint replacement is
performed here: each output is a contiguous sampled mocap interval. Source
downloads and generated artifacts belong in private staging, not in git.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

from tools.motion.bones_seed_import import BonesSeedViewerClient, retarget_bvh_to_motion_spec
from tools.motion.gmgn_motion_factory import publish_motion


def motion_metrics(spec):
    angles = np.asarray([[key["r"] for key in track] for track in spec["tracks"].values()]).transpose(1, 0, 2)
    quats = Rotation.from_euler("XYZ", angles.reshape(-1, 3), degrees=True).as_quat().reshape(*angles.shape[:2], 4)
    distances = np.rad2deg(2 * np.arccos(np.clip(np.abs(np.sum(quats * quats[0], axis=-1)), 0, 1)))
    steps = np.rad2deg(2 * np.arccos(np.clip(np.abs(np.sum(quats[1:] * quats[:-1], axis=-1)), 0, 1)))
    roots = np.asarray([key["p"] for key in spec["hips"]])
    return {"seamMaxDegrees": float(distances[-1].max()),
            "seamMeanDegrees": float(distances[-1].mean()),
            "motionMaxDegrees": float(distances.max()),
            "meanFrameMotionDegrees": float(steps.mean()),
            "rootSeamMeters": float(np.linalg.norm(roots[-1] - roots[0])),
            "rootRangeMeters": float(np.linalg.norm(np.ptp(roots, axis=0)))}


def select_loop(angles, roots, *, fps, min_seconds, max_seconds, min_motion_degrees=1):
    """Find the smallest pose seam among continuous, nonstationary intervals."""
    angles = np.asarray(angles)
    quats = Rotation.from_euler("XYZ", angles.reshape(-1, 3), degrees=True).as_quat().reshape(*angles.shape[:2], 4)
    best = None
    for start in range(0, len(angles) - round(min_seconds * fps), 3):
        ends = np.arange(start + round(min_seconds * fps), min(len(angles), start + round(max_seconds * fps) + 1), 3)
        if not len(ends):
            continue
        seam = np.rad2deg(2 * np.arccos(np.clip(np.abs(np.sum(quats[ends] * quats[start], axis=-1)), 0, 1)))
        cost = seam.max(axis=1) + seam.mean(axis=1) + np.linalg.norm(roots[ends] - roots[start], axis=1) * 100
        for index in np.argsort(cost):
            end = int(ends[index])
            excursion = np.rad2deg(2 * np.arccos(np.clip(np.abs(np.sum(quats[start:end+1] * quats[start], axis=-1)), 0, 1)))
            if excursion.max() < min_motion_degrees:
                continue
            candidate = (float(cost[index]), start, end)
            if best is None or candidate < best:
                best = candidate
            break
    if best is None:
        raise ValueError("source is stationary or too short for a continuous loop")
    return best[1:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path(__file__).with_name("fixtures") / "bones-resident.json")
    parser.add_argument("--staging-root", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    args.staging_root.mkdir(parents=True, exist_ok=True)
    evidence = []
    for source in manifest["motions"]:
        name = source["filename"]
        cached = args.staging_root / f"{name}.json"
        if cached.exists():
            payload = json.loads(cached.read_text())
            if payload["name"] != name:
                raise ValueError("cached source name mismatch")
            bvh = payload["tree"]
        else:
            bvh = BonesSeedViewerClient(timeout=60).fetch_bvh(name)
            cached.write_text(json.dumps({"name": name, "tree": bvh}))
        digest = hashlib.sha256(bvh.encode()).hexdigest()
        if source.get("sourceSHA256") and digest != source["sourceSHA256"]:
            raise ValueError(f"BONES source changed: {name}")
        spec = retarget_bvh_to_motion_spec(bvh, name=source["displayName"], loop=True, root_motion="vertical-only",
                                          start_frame=source.get("startFrame"), end_frame=source.get("endFrame"))
        metrics = motion_metrics(spec)
        if metrics["seamMaxDegrees"] > source["maxSeamDegrees"] or metrics["rootSeamMeters"] > .025:
            raise ValueError(f"Unacceptable mocap loop seam: {name}: {metrics}")
        if metrics["motionMaxDegrees"] < source["minMotionDegrees"]:
            raise ValueError(f"Insufficient continuous mocap motion: {name}: {metrics}")
        (args.staging_root / f"{source['key']}.motion.json").write_text(json.dumps(spec))
        entries = []
        for avatar_format, motion_format in [("pmx", "vmd"), ("vrm", "vrma")]:
            entries.append(publish_motion(spec=spec, output_root=args.staging_root / "catalog",
                motion_id=f"gmgn.motion.bones.{source['key']}-{avatar_format}", display_name=source["displayName"],
                version="1.0.0", activity_ids=source["activityIDs"], prompt=f"BONES-SEED:{name}", seed=None,
                generator={"engine": "bones-seed", "model": "SOMA-BVH", "revision": "seed_metadata_v004",
                           "sourceSHA256": digest, "startFrame": source.get("startFrame"), "endFrame": source.get("endFrame")},
                motion_format=motion_format, in_place=True))
        evidence.append({"source": source, "sourceSHA256": digest, "metrics": metrics, "entries": entries})
    (args.staging_root / "evidence.json").write_text(json.dumps({"visualAcceptance": "not-performed", "motions": evidence}, indent=2))
    print(json.dumps({"catalog": str(args.staging_root / "catalog"), "motions": len(evidence)}))


if __name__ == "__main__":
    main()
