#!/usr/bin/env python3
"""Offline candidate calibration for PMX one-shot recovery clips.

Produces *candidate* センター-Y corrections for
``gmgn.motion.bones.arpg.recovery-get-up-back-pmx`` and
``gmgn.motion.bones.arpg.recovery-faint-recover-back-pmx`` on the actual
na_2b_0414 rig, plus rerunnable bounded regression.  It never writes the
installed MotionPackages; candidates are written only under a caller-supplied
output directory (default a /tmp subfolder).

Convention summary (verified against the factory/import path):
  * the clips were retargeted from SOMA BVH with ``root_motion="full"``; hips
    root Y is relative to the clip first frame and metres are divided by the
    fixed 0.08 m/u VMD constant, so the root curve is *not* re-anchored to the
    target rig bind (centre-to-sole = 8.9 u on this 1.7 m-normalised model).
  * standing frames bake centre offset ~0 (feet on the bind-sole floor F0);
    lying frames sink ~11.9-12.1 u (source hips drop in source scale), which
    places the *skinned body* up to ~0.55 m below the floor; get-up-back bakes
    a whole-body +12 u offset so it floats ~0.4-0.97 m above the floor.
  * only センター translation keys carry root motion; all other keys are
    per-bone rotations and stay untouched.

Primary metric: the skinned *body* low envelope (whole mesh excluding skirt
and hair physics bones, which are rigid in this runtime because PMX physics is
detached) against the bind-sole floor F0.  Skirt/hair sub-floor behaviour is
reported separately as a rigid-cloth residual, never used to anchor.

Run from the repo root (direct-path execution cannot import the tools
package):
  python3 -m tools.motion.recovery_ground_calib profile|calibrate|regress
  [--output-dir DIR]
The CLI stays rerunnable: it never touches the installed MotionPackages.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np

from tools.motion.recovery_ground import (
    APPLICATION_SUPPORT,
    MOTION_PACKAGES,
    Rig,
    VMDClip,
    decode_name,
    evaluate_clip,
    require_dense,
)

CLIPS = {
    "get-up-back": (
        "gmgn.motion.bones.arpg.recovery-get-up-back-pmx",
        "get-up-back (仰卧起身): lying on back -> standing",
    ),
    "faint-recover-back": (
        "gmgn.motion.bones.arpg.recovery-faint-recover-back-pmx",
        "faint-recover-back (昏厥后从仰卧起身): standing -> faint/lying -> standing",
    ),
}
WALK_ID = "gmgn.motion.bones.walk-loop-pmx"

# Contact tolerance band in model units (1 u ~= 0.0801 m).  The float band
# covers the authored stand-pose sole hover (~0.1-0.27 u) plus pose noise, and
# stays an order of magnitude below the observed artifacts (5-14 u); see the
# evidence record.
PENETRATION_TOL_U = 0.12
FLOAT_TOL_U = 0.35


def clip_path(clip_id: str) -> Path:
    return MOTION_PACKAGES / clip_id / f"{clip_id}.vmd"


def load_rig_and_clip(clip_id: str):
    rig = Rig()
    clip = VMDClip(clip_path(clip_id))
    require_dense(clip)
    return rig, clip


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _excluded_bone_ids(rig: Rig) -> list[int]:
    """Rigid trailing-cloth bones (skirt/coat, sleeve cuffs, hair).

    These chains are not keyed by the clips and the PMX runtime detaches
    physics, so offline they stay rigid in their bind pose relative to their
    parents.  They must not drive the body contact anchor (a resting back
    would otherwise be floated by a coat hem); their sub-floor residual is
    reported separately.
    """
    excluded = []
    for name, index in rig.bone_name_index.items():
        normalized = name.lower()
        if "スカート" in name or "髪" in name or "hair" in normalized:
            excluded.append(index)
    for name, index in rig.bone_name_index.items():
        if len(name) > 1 and name[0] in ("左", "右") and name[1] == "F" and "_" in name:
            excluded.append(index)
    return sorted(set(excluded))


def _cloth_mask(rig: Rig) -> np.ndarray:
    """Trailing-cloth vertices (skirt/coat, sleeve cuffs, hair)."""
    excluded = _excluded_bone_ids(rig)
    mask = np.zeros(len(rig.positions), dtype=bool)
    for slot in range(4):
        in_excluded = np.isin(rig.skin_idx[:, slot], excluded)
        mask |= in_excluded & (rig.skin_w[:, slot] > 0.01)
    return mask


def _body_mask(rig: Rig) -> np.ndarray:
    """Body vertices: not significantly driven by trailing-cloth bones."""
    excluded = _excluded_bone_ids(rig)
    mask = np.ones(len(rig.positions), dtype=bool)
    for slot in range(4):
        in_excluded = np.isin(rig.skin_idx[:, slot], excluded)
        mask &= ~(in_excluded & (rig.skin_w[:, slot] > 0.01))
    return mask


def skinned_body_low(rig: Rig, frame_result, mask: np.ndarray):
    y_all = rig.skinned_min_profile(frame_result["q"], frame_result["pos"])
    y_body = y_all[mask]
    return {
        "all_min": float(y_all.min()),
        "body_min": float(y_body.min()),
        "body_q01": float(np.quantile(y_body, 0.01)),
        "body_q05": float(np.quantile(y_body, 0.05)),
    }


# Semantic rest windows verified from the pose/mesh profile of the actual
# clips (standing = bind-equivalent vertical pose, lying = horizontal spine).
# Mid-fall/mid-rise poses (crouches, rolls) are deliberately *not* rest
# windows: their vertical correctness is only bounded by the one-sided
# penetration lift and is reported as transition residual, never re-anchored.
SEMANTIC_WINDOWS: dict[str, list[dict[str, object]]] = {
    # get-up-back: lying on back 0..44, upright 122..185; between = rise.
    "gmgn.motion.bones.arpg.recovery-get-up-back-pmx": [
        {"state": "lying", "f0": 0, "f1": 39},
        {"state": "standing", "f0": 122, "f1": 185},
    ],
    # faint-recover-back: standing 0..23, fall 24..51, lying 52..195,
    # rise 196..259, standing 260..401.
    "gmgn.motion.bones.arpg.recovery-faint-recover-back-pmx": [
        {"state": "standing", "f0": 0, "f1": 23},
        {"state": "lying", "f0": 52, "f1": 195},
        {"state": "standing", "f0": 260, "f1": 401},
    ],
}


def semantic_windows(clip_id: str, frame_list) -> list[dict[str, object]]:
    by_frame = {int(frame): i for i, frame in enumerate(frame_list)}
    windows = []
    for window in SEMANTIC_WINDOWS[clip_id]:
        windows.append(
            {
                "state": window["state"],
                "f0": int(window["f0"]),
                "f1": int(window["f1"]),
                "i0": by_frame[int(window["f0"])],
                "i1": by_frame[int(window["f1"])],
            }
        )
    return windows


def spine_features(rig: Rig, frame_result):
    p = frame_result["pos"]
    center = p[rig.bone_name_index["センター"]]
    head = p[rig.bone_name_index["頭"]]
    chord = head - center
    length = float(np.linalg.norm(chord))
    if length < 1e-6:
        return 1.0, 0.0
    return abs(float(chord[1])) / length, math.hypot(float(chord[0]), float(chord[2])) / length


def evaluate_with_low(
    rig: Rig, clip: VMDClip, frames, body_mask, y_override=None
):
    rows = []
    for frame_result in evaluate_clip(rig, clip, frames=frames, y_override=y_override):
        low = skinned_body_low(rig, frame_result, body_mask)
        vertical, horizontal = spine_features(rig, frame_result)
        rows.append(
            {
                "frame": int(frame_result["frame"]),
                "center_y": float(frame_result["center_y"]),
                "min_y": low["all_min"],
                "body_min": low["body_min"],
                "body_q01": low["body_q01"],
                "body_q05": low["body_q05"],
                "spine_vert": vertical,
                "spine_horiz": horizontal,
            }
        )
    return rows


def classify_state(row) -> str:
    """standing / lying / transition from pose only (root-Y invariant)."""
    if row["spine_vert"] >= 0.85:
        return "standing"
    if row["spine_horiz"] >= 0.80:
        return "lying"
    return "transition"


def simplify_runs(states: list[str], min_run: int = 4) -> list[str]:
    """Merge short runs into their neighbours so windows are stable."""
    n = len(states)
    current = list(states)
    changed = True
    while changed:
        changed = False
        i = 0
        while i < n:
            j = i
            while j < n and current[j] == current[i]:
                j += 1
            if current[i] in ("standing", "lying") and j - i < min_run:
                left = current[i - 1] if i > 0 else None
                right = current[j] if j < n else None
                replacement = None
                if left == right:
                    replacement = left
                elif current[i] == "lying" and right == "standing":
                    replacement = "standing"
                else:
                    replacement = right or left or "transition"
                for k in range(i, j):
                    current[k] = replacement
                changed = True
            i = j
    return current


def detect_windows(rows):
    """Return list of (state, first_frame, last_frame, first_i, last_i)."""
    states = [classify_state(row) for row in rows]
    states = simplify_runs(states)
    windows = []
    i = 0
    n = len(states)
    while i < n:
        j = i
        while j < n and states[j] == states[i]:
            j += 1
        if states[i] in ("standing", "lying"):
            windows.append(
                {
                    "state": states[i],
                    "f0": rows[i]["frame"],
                    "f1": rows[j - 1]["frame"],
                    "i0": i,
                    "i1": j - 1,
                }
            )
        i = j
    return windows


def _smoothstep(a: float, b: float, t: float) -> float:
    t = max(0.0, min(1.0, t))
    return a + (b - a) * (t * t * (3.0 - 2.0 * t))


CONTACT_MARGIN_U = 0.02  # resting low point target above the floor plane


def build_correction(
    rows,
    windows,
    ground_y: float,
    penetration_tol: float,
    float_tol: float = FLOAT_TOL_U,
):
    """Piecewise rest-window anchors + one-sided penetration lift.

    Returns dict frame -> correction c (added to the raw センター Y).
    """
    frames = [row["frame"] for row in rows]
    # anchor constant per rest window from its body-low envelope median; a
    # standing window that is already grounded (within the float tolerance) is
    # left untouched so bind-standing clips are never shifted.
    anchors = []
    for window in windows:
        values = [rows[k]["body_min"] for k in range(window["i0"], window["i1"] + 1)]
        median = float(np.median(values))
        if window["state"] == "standing" and (median - ground_y) <= float_tol:
            anchors.append((window, 0.0))
        else:
            anchors.append((window, ground_y - median))

    def anchor_at(frame: float) -> float:
        # constant in windows; smoothstep between neighbouring windows in gaps
        if not anchors:
            return 0.0
        if frame <= anchors[0][0]["f0"]:
            return anchors[0][1]
        if frame >= anchors[-1][0]["f1"]:
            return anchors[-1][1]
        for index, (window, value) in enumerate(anchors):
            if window["f0"] <= frame <= window["f1"]:
                return value
        # gap between anchors[index] and anchors[index + 1]
        for index in range(len(anchors) - 1):
            (left_window, left_value) = anchors[index]
            (right_window, right_value) = anchors[index + 1]
            if left_window["f1"] < frame < right_window["f0"]:
                t = (frame - left_window["f1"]) / max(
                    right_window["f0"] - left_window["f1"], 1
                )
                return _smoothstep(left_value, right_value, t)
        return 0.0

    correction = {}
    for row in rows:
        frame = row["frame"]
        cwin = anchor_at(frame)
        # one-sided lift: only when the anchored body would still sink below
        # the floor plane; never pulls airborne (above-floor) frames down
        residual = ground_y + CONTACT_MARGIN_U - (row["body_min"] + cwin)
        extra = max(0.0, residual)
        correction[frame] = cwin + extra
    return correction


def corrected_rows(rig: Rig, clip: VMDClip, rows, correction):
    """DEPRECATED theoretical preview — do NOT use as a pass/evidence basis.

    Corrected low envelopes without re-evaluation.  Kept only as a cheap
    preview; regress and calibrate must re-read the exported candidate VMD and
    re-run the real FK/skin (see the 2026-09-07 evidence record: this theory
    masked the delta-vs-absolute patch bug).

    The only change is センター translation Y, which the deformation model
    applies as a pure world-Y shift of every skinned vertex (the センター
    parent is the identity 全ての親), so every low envelope shifts by exactly
    the per-frame correction and the spine features are unchanged.
    """
    out = []
    for row in rows:
        frame = row["frame"]
        c = float(correction[frame])
        out.append(
            {
                "frame": frame,
                "correction": c,
                "center_y": row["center_y"] + c,
                "min_y": row["min_y"] + c,
                "body_min": row["body_min"] + c,
                "body_q01": row["body_q01"] + c,
                "spine_vert": row["spine_vert"],
                "spine_horiz": row["spine_horiz"],
            }
        )
    return out


def metrics(rows, windows, ground_y):
    """Bounded contact metrics over rest windows and across the whole clip."""
    result = {}
    all_body_min = [row["body_min"] for row in rows]
    result["wholeClip"] = {
        "maxPenetrationU": round(ground_y - min(all_body_min), 4),
        "maxPenetrationM": round((ground_y - min(all_body_min)) * 0.0801, 4),
        "minBodyMinU": round(min(all_body_min), 4),
    }
    result["windows"] = []
    for window in windows:
        rows_in_window = [
            row for row in rows if window["f0"] <= row["frame"] <= window["f1"]
        ]
        if not rows_in_window:
            continue
        body_mins = [row["body_min"] for row in rows_in_window]
        body_q01s = [row["body_q01"] for row in rows_in_window]
        result["windows"].append(
            {
                "state": window["state"],
                "frames": [window["f0"], window["f1"]],
                "bodyMinMinU": round(min(body_mins), 4),
                "bodyMinMaxU": round(max(body_mins), 4),
                "penetrationMaxU": round(ground_y - min(body_mins), 4),
                "floatGapMinU": round(min(body_mins) - ground_y, 4),
                "floatGapQ01MinU": round(min(body_q01s) - ground_y, 4),
            }
        )
    return result


def residual_metrics(rows, windows, ground_y):
    """Transition residuals and rigid-cloth sub-floor residual (info only)."""
    window_frames = set()
    for window in windows:
        window_frames.update(range(window["f0"], window["f1"] + 1))
    transition = [
        row
        for row in rows
        if row["frame"] not in window_frames
    ]
    if transition:
        float_gaps = [row["body_min"] - ground_y for row in transition]
        penetration = [ground_y - row["body_min"] for row in transition]
        cloth = [ground_y - row["min_y"] for row in transition]
    else:
        float_gaps = penetration = cloth = []
    cloth_all = [ground_y - row["min_y"] for row in rows]
    return {
        "transitionMaxFloatU": round(max(float_gaps, default=0.0), 4),
        "transitionMaxPenetrationU": round(max(penetration, default=0.0), 4),
        "transitionMaxClothUnderU": round(max(cloth, default=0.0), 4),
        "wholeClipMaxClothUnderU": round(max(cloth_all, default=0.0), 4),
        "transitionFrameCount": len(transition),
    }


def candidate_summary(
    clip_id: str, rows_orig, rows_corr, correction, ground_y, windows
):
    return {
        "clip": clip_id,
        "package": CLIPS[clip_id][0],
        "frameCount": len(rows_orig),
        "correctionRangeU": [
            round(min(correction.values()), 4),
            round(max(correction.values()), 4),
        ],
        "original": metrics(rows_orig, windows, ground_y),
        "candidate": metrics(rows_corr, windows, ground_y),
        "residual": residual_metrics(rows_corr, windows, ground_y),
    }


def command_profile(args) -> int:
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    summary = {}
    for key, (clip_id, _description) in CLIPS.items():
        rig, clip = load_rig_and_clip(clip_id)
        rows = evaluate_with_low(
            rig,
            clip,
            frames=range(0, clip.last_frame + 1),
            body_mask=_body_mask(rig),
        )
        windows = semantic_windows(clip_id, [row["frame"] for row in rows])
        met = metrics(rows, windows, rig.rest_foot_reference_y)
        summary[key] = {
            "restFootReferenceY": round(rig.rest_foot_reference_y, 4),
            "mpu": round(rig.mpu, 6),
            "windows": windows,
            "metrics": met,
            "residual": residual_metrics(rows, windows, rig.rest_foot_reference_y),
            "frames": rows,
        }
        print(f"===== {key} last={clip.last_frame}")
        for window in windows:
            print(
                " window %-9s %4d..%-4d  %s"
                % (
                    window["state"],
                    window["f0"],
                    window["f1"],
                    [
                        m
                        for m in met["windows"]
                        if m["frames"] == [window["f0"], window["f1"]]
                    ],
                )
            )
    (out_dir / "profile.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=1, default=str)
    )
    print("wrote", out_dir / "profile.json")
    return 0


def command_calibrate(args) -> int:
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    for key, (clip_id, _description) in CLIPS.items():
        rig, clip = load_rig_and_clip(clip_id)
        frames = list(range(0, clip.last_frame + 1))
        rows = evaluate_with_low(rig, clip, frames=frames, body_mask=_body_mask(rig))
        windows = semantic_windows(clip_id, [row["frame"] for row in rows])
        correction = build_correction(
            rows, windows, rig.rest_foot_reference_y, PENETRATION_TOL_U, FLOAT_TOL_U
        )
        candidate_vmd = out_dir / f"{clip_id}.calibrated.vmd"
        # patch_center_y adds each delta to the original key Y (absolute value
        # = raw + delta); the old bug wrote the delta itself as the absolute Y.
        clip.patch_center_y(correction, candidate_vmd)
        # Candidate metrics are re-computed by re-reading the exported VMD and
        # running the real FK/skin, not from the theoretical raw+delta rows.
        candidate_clip = VMDClip(candidate_vmd)
        require_dense(candidate_clip)
        rows_corr_real = evaluate_with_low(
            rig, candidate_clip, frames=frames, body_mask=_body_mask(rig)
        )
        summary = candidate_summary(
            key, rows, rows_corr_real, correction,
            rig.rest_foot_reference_y, windows,
        )
        summary["penetrationTolU"] = PENETRATION_TOL_U
        summary["floatTolU"] = FLOAT_TOL_U
        summary["contactMarginU"] = CONTACT_MARGIN_U
        summary["windows"] = [
            {"state": w["state"], "frames": [w["f0"], w["f1"]]} for w in windows
        ]
        summary["footReferenceY"] = round(rig.rest_foot_reference_y, 4)
        summary["candidateVMD"] = str(candidate_vmd)
        summary["candidateVMD_sha256"] = sha256(candidate_vmd)
        summary["originalVMD_sha256"] = sha256(clip_path(clip_id))
        summary["metricsBasis"] = "real FK re-read of exported candidate VMD"
        (out_dir / f"{clip_id}.summary.json").write_text(
            json.dumps(summary, ensure_ascii=False, indent=1)
        )
        print(json.dumps({"clip": key, "file": str(candidate_vmd)}, indent=1))
    return 0


def command_regress(args) -> int:
    """Run the bounded regression and write pass/fail JSON."""
    from tools.motion.recovery_ground_regress import run_regression

    results = run_regression(
        output_dir=Path(args.output_dir),
        penetration_tol=PENETRATION_TOL_U,
        float_tol=FLOAT_TOL_U,
    )
    Path(args.output_dir).mkdir(parents=True, exist_ok=True)
    (Path(args.output_dir) / "regression.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=1)
    )
    print(json.dumps(results, ensure_ascii=False, indent=1))
    return 0 if results.get("passed") else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("profile", "calibrate", "regress"):
        p = sub.add_parser(name)
        p.add_argument(
            "--output-dir",
            type=Path,
            default=Path("/tmp/gmgn-recovery-calib"),
            help="temporary output directory (never the installed packages)",
        )
        p.set_defaults(func=globals()[f"command_{name}"])
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
