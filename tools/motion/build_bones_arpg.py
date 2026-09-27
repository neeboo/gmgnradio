#!/usr/bin/env python3
"""Import an explicitly selected, privately licensed BONES action collection.

Clips keep their full source interval and root trajectory. They are one-shot
library entries, not automatically enabled navigation or combat capabilities.
Run as ``python3 -m tools.motion.build_bones_arpg`` from the repository root.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
from pathlib import Path

from tools.motion.bones_seed_import import BonesSeedViewerClient, retarget_bvh_to_motion_spec
from tools.motion.gmgn_motion_factory import publish_motion


def validate_manifest(manifest):
    if manifest.get("schemaVersion") != 1 or not isinstance(manifest.get("motions"), list) or not manifest["motions"]:
        raise ValueError("unsupported or empty ARPG manifest")
    keys, filenames = set(), set()
    for source in manifest["motions"]:
        key, filename = source.get("key", ""), source.get("filename", "")
        if len(key) > 102 or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", key) or key in keys:
            raise ValueError("unsafe or duplicate motion key")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", filename) or filename in filenames:
            raise ValueError("unsafe or duplicate BONES filename")
        if not isinstance(source.get("displayName"), str) or not source["displayName"].strip():
            raise ValueError("missing motion display name")
        keys.add(key)
        filenames.add(filename)
    return manifest["motions"]


def build_motion(source, staging_root):
    validate_manifest({"schemaVersion": 1, "motions": [source]})
    staging_root = Path(staging_root)
    name = source["filename"]
    cached = staging_root / "sources" / f"{name}.json"
    if cached.exists():
        payload = json.loads(cached.read_text())
        if payload.get("name") != name or not isinstance(payload.get("tree"), str):
            raise ValueError(f"BONES cached identity mismatch: {name}")
        bvh = payload["tree"]
        digest = hashlib.sha256(bvh.encode()).hexdigest()
        if payload.get("sha256") != digest:
            raise ValueError(f"BONES cached source digest mismatch: {name}")
    else:
        bvh = BonesSeedViewerClient(timeout=60).fetch_bvh(name)
        digest = hashlib.sha256(bvh.encode()).hexdigest()
        cached.parent.mkdir(parents=True, exist_ok=True)
        partial = cached.with_suffix(".partial")
        partial.write_text(json.dumps({"name": name, "tree": bvh, "sha256": digest}))
        partial.replace(cached)
    if source.get("sourceSHA256") and source["sourceSHA256"] != digest:
        raise ValueError(f"BONES manifest source digest mismatch: {name}")
    spec = retarget_bvh_to_motion_spec(bvh, name=source["displayName"], loop=False, root_motion="full")
    entries = []
    for avatar_format, motion_format in [("pmx", "vmd"), ("vrm", "vrma")]:
        entries.append(publish_motion(
            spec=spec, output_root=staging_root / "catalog",
            motion_id=f"gmgn.motion.bones.arpg.{source['key']}-{avatar_format}",
            display_name=source["displayName"], version="1.0.0", activity_ids=[],
            prompt=f"BONES-SEED:{name}", seed=None,
            generator={"engine": "bones-seed", "model": "SOMA-BVH", "revision": "seed_metadata_v004",
                       "sourceSHA256": digest, "rootMotion": "full", "sourceInterval": "full",
                       "libraryCategory": source.get("category", "")},
            motion_format=motion_format, in_place=False))
    root = spec["hips"][-1]["p"]
    return {"source": source, "sourceSHA256": digest, "duration": spec["duration"],
            "rootDisplacementMeters": math.sqrt(sum(value * value for value in root)),
            "entries": entries}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--staging-root", type=Path, required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    motions = validate_manifest(manifest)
    args.staging_root.mkdir(parents=True, exist_ok=True)
    evidence = {"visualAcceptance": "not-performed", "automaticBehaviorEnabled": False,
                "motionPolicy": "full source interval, full root trajectory, one-shot playback",
                "motions": [], "failures": [], "gaps": manifest.get("gaps", [])}
    evidence_path = args.staging_root / "evidence.json"
    for index, source in enumerate(motions, 1):
        try:
            evidence["motions"].append(build_motion(source, args.staging_root))
            print(f"{index}/{len(motions)} imported {source['key']}", flush=True)
        except Exception as error:
            evidence["failures"].append({"key": source["key"], "filename": source["filename"], "error": str(error)})
            print(f"{index}/{len(motions)} FAILED {source['key']}: {error}", flush=True)
        temporary = evidence_path.with_suffix(".partial")
        temporary.write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n")
        temporary.replace(evidence_path)
    print(json.dumps({"imported": len(evidence["motions"]), "failed": len(evidence["failures"]),
                      "catalog": str(args.staging_root / "catalog" / "catalog.json")}), flush=True)
    return 1 if evidence["failures"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
