#!/usr/bin/env python3
"""Bounded regression for the offline recovery-ground candidates.

Read-only over the installed assets; all outputs go to a temporary directory.
The regression encodes the semantic contract of the two one-shot clips:

  * the *original* clips necessarily fail a bounded lying-contact test
    (faint-recover-back sinks through the floor; get-up-back floats),
  * each *candidate* keeps every rest window (lying/standing) inside a contact
    band above the bind-sole floor and restores the standing terminal state,
  * the candidate changes only the センター translation Y values, so duration,
    frame grid, every bone rotation and the centre X/Z travel are unchanged,
  * the walk-loop control asset is never read-for-write and stays untouched,
  * no uniform whole-library lift is introduced (corrections differ per clip
    and are near zero on already-grounded standing windows).

VRMA is *not* validated here: the VRM counterpart files were never byte-level
verified against a VRM animation validator in this scope.
"""

from __future__ import annotations

import hashlib
import json
import struct
from pathlib import Path

import numpy as np

from tools.motion.recovery_ground import (
    MOTION_PACKAGES,
    Rig,
    VMDClip,
    decode_name,
    require_dense,
)
from tools.motion.recovery_ground_calib import (
    CLIPS,
    CONTACT_MARGIN_U,
    WALK_ID,
    _body_mask,
    build_correction,
    evaluate_with_low,
    metrics,
    semantic_windows,
    sha256,
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _clip_package(clip_id: str) -> Path:
    return MOTION_PACKAGES / clip_id


def _check(name: str, passed: bool, detail: str) -> dict[str, object]:
    return {"name": name, "passed": bool(passed), "detail": detail}


def _parse_identity(path: Path):
    """Full structural parse of a VMD: frames, translations, rotations."""
    data = Path(path).read_bytes()
    off = VMDClip.HEADER
    count = struct.unpack_from("<I", data, off)[0]
    off += 4
    records = []
    for _ in range(count):
        name = decode_name(data[off : off + 15])
        off += 15
        frame = struct.unpack_from("<I", data, off)[0]
        off += 4
        translation = struct.unpack_from("<3f", data, off)
        off += 12
        rotation = struct.unpack_from("<4f", data, off)
        off += 16
        interpolation = bytes(data[off : off + 64])
        off += 64
        records.append(
            (name, frame, translation, rotation, interpolation)
        )
    return records, bytes(data[off:])


def _invariance_checks(clip_id: str, original_path: Path, candidate_path: Path):
    """candidate differs from original only in センター translation Y."""
    checks = []
    original_records, original_tail = _parse_identity(original_path)
    candidate_records, candidate_tail = _parse_identity(candidate_path)
    checks.append(
        _check(
            "duration_and_frame_grid",
            len(candidate_records) == len(original_records)
            and candidate_tail == original_tail,
            f"records {len(original_records)}->{len(candidate_records)}, tail "
            f"{'equal' if candidate_tail == original_tail else 'DIFFERS'}",
        )
    )
    changed_translation_y = 0
    rotation_diffs = 0
    xz_or_other_diffs = 0
    grid_diffs = 0
    for original, candidate in zip(original_records, candidate_records):
        (name_a, frame_a, t_a, q_a, i_a) = original
        (name_b, frame_b, t_b, q_b, i_b) = candidate
        if name_a != name_b or frame_a != frame_b or i_a != i_b:
            grid_diffs += 1
            continue
        if q_a != q_b:
            rotation_diffs += 1
        if name_a == "センター":
            if t_a[0] != t_b[0] or t_a[2] != t_b[2]:
                xz_or_other_diffs += 1
            if t_a[1] != t_b[1]:
                changed_translation_y += 1
        else:
            if t_a != t_b:
                xz_or_other_diffs += 1
    checks.append(
        _check(
            "only_center_translation_y_changed",
            grid_diffs == 0 and rotation_diffs == 0 and xz_or_other_diffs == 0
            and changed_translation_y > 0,
            f"centre-Y keys changed={changed_translation_y} rotation diffs="
            f"{rotation_diffs} xz/other diffs={xz_or_other_diffs} grid diffs="
            f"{grid_diffs}",
        )
    )
    return checks


def _evaluate_candidates(rig: Rig, clip: VMDClip, clip_id: str, out_dir: Path):
    require_dense(clip)
    frames = list(range(0, clip.last_frame + 1))
    rows = evaluate_with_low(rig, clip, frames=frames, body_mask=_body_mask(rig))
    windows = semantic_windows(clip_id, frames)
    correction = build_correction(
        rows, windows, rig.rest_foot_reference_y, PENETRATION_TOL, FLOAT_TOL
    )
    candidate_path = out_dir / f"{clip_id}.calibrated.vmd"
    clip.patch_center_y(correction, candidate_path)
    # The pass basis is the *exported* candidate: re-read the written VMD and
    # re-run the real FK + skinned envelope.  Theoretical raw+delta rows are
    # not accepted as evidence (that masked the delta-vs-absolute patch bug).
    candidate_clip = VMDClip(candidate_path)
    require_dense(candidate_clip)
    corrected = evaluate_with_low(
        rig, candidate_clip, frames=frames, body_mask=_body_mask(rig)
    )
    last = frames[-1]
    center_keys = clip.keys["センター"]
    center_keys_candidate = candidate_clip.keys["センター"]
    return {
        "rows": rows,
        "corrected": corrected,
        "windows": windows,
        "correction": correction,
        "candidate_path": candidate_path,
        "candidate_sha256": sha256(candidate_path),
        "original_sha256": sha256(_clip_package(clip_id) / f"{clip_id}.vmd"),
        "original_metrics": metrics(rows, windows, rig.rest_foot_reference_y),
        "candidate_metrics": metrics(corrected, windows, rig.rest_foot_reference_y),
        "lastFrameKeyContract": {
            "frame": last,
            "rawKeyY": round(float(center_keys[-1][1][1]), 6),
            "deltaY": round(float(correction[last]), 6),
            "writtenKeyY": round(float(center_keys_candidate[-1][1][1]), 6),
            "expectRawPlusDelta": round(
                float(center_keys[-1][1][1]) + float(correction[last]), 6
            ),
        },
    }


def _rest_window_check(state: str, metrics_windows, ground: float, clip_id: str):
    checks = []
    for window in metrics_windows:
        if window["state"] != state:
            continue
        penetration = window["penetrationMaxU"]
        # floatGapMinU is the minimum over frames of bodyMin - ground; the
        # window stays inside the band when penetration and gap are bounded.
        gap_max = window["bodyMinMaxU"] - ground
        gap_min = window["floatGapMinU"]
        penetration_ok = penetration <= PENETRATION_TOL
        band_ok = gap_min >= -PENETRATION_TOL and gap_max <= FLOAT_TOL
        checks.append(
            _check(
                f"{clip_id}:{state}_window_{window['frames'][0]}_{window['frames'][1]}",
                bool(penetration_ok and band_ok),
                f"penetrationMaxU={penetration} tol={PENETRATION_TOL} "
                f"gapMinU={gap_min} gapMaxU={gap_max} floatTol={FLOAT_TOL}",
            )
        )
    return checks


def run_regression(
    *,
    output_dir: Path | None = None,
    penetration_tol: float,
    float_tol: float,
) -> dict[str, object]:
    global PENETRATION_TOL, FLOAT_TOL
    PENETRATION_TOL = penetration_tol
    FLOAT_TOL = float_tol
    out_dir = Path(output_dir) if output_dir else Path("/tmp/gmgn-recovery-calib")
    out_dir.mkdir(parents=True, exist_ok=True)
    rig = Rig()
    ground = rig.rest_foot_reference_y
    walk_sha_before = _sha256(MOTION_PACKAGES / WALK_ID / f"{WALK_ID}.vmd")
    all_checks = []
    per_clip = {}
    for key, (clip_id, _description) in CLIPS.items():
        clip = VMDClip(_clip_package(clip_id) / f"{clip_id}.vmd")
        result = _evaluate_candidates(rig, clip, clip_id, out_dir)
        clip_checks = []
        # 1. original necessarily fails a bounded lying-contact test
        lying_windows = [
            w for w in result["windows"] if w["state"] == "lying"
        ]
        original_lying = [
            w
            for w in result["original_metrics"]["windows"]
            if w["state"] == "lying"
        ]
        violation = None
        for window, metric in zip(lying_windows, original_lying):
            penetration = metric["penetrationMaxU"]
            gap = metric["bodyMinMinU"] - ground
            if penetration > max(penetration_tol, 1.5):
                violation = f"penetration {penetration:.3f}u"
            if gap > max(float_tol, 1.5):
                violation = f"float {gap:.3f}u"
        clip_checks.append(
            _check(
                "original_clip_fails_lying_contact",
                violation is not None,
                violation or "no bounded violation found",
            )
        )
        # 2. candidate rest windows stay inside the contact band
        for window in result["candidate_metrics"]["windows"]:
            clip_checks.extend(
                _rest_window_check(
                    window["state"],
                    [window],
                    ground,
                    key,
                )
            )
        # 3. terminal standing (last frames of the final standing window)
        standing_windows = [
            w
            for w in result["windows"]
            if w["state"] == "standing"
        ]
        last_standing = standing_windows[-1]
        terminal_rows = [
            row
            for row in result["corrected"]
            if row["frame"] >= last_standing["f1"] - 9
        ]
        terminal_ok = all(
            -penetration_tol <= row["body_min"] - ground <= float_tol
            and row["spine_vert"] >= 0.9
            and abs(row["center_y"] - rig.bind_pos[rig.bone_name_index["センター"]][1])
            <= 0.6
            for row in terminal_rows
        )
        clip_checks.append(
            _check(
                "terminal_standing_restored",
                bool(terminal_ok),
                "last 10 frames within band, spine vertical, centre at bind "
                f"height: "
                + "; ".join(
                    f"f{row['frame']} bmin={row['body_min']:.3f} "
                    f"cen={row['center_y']:.3f} v={row['spine_vert']:.2f}"
                    for row in terminal_rows[:4]
                ),
            )
        )
        # 4. candidate never penetrates on any frame
        worst = min(row["body_min"] for row in result["corrected"])
        clip_checks.append(
            _check(
                "candidate_no_penetration_any_frame",
                ground - worst <= penetration_tol,
                f"min corrected body min = {worst:.4f}u vs floor {ground:.4f}u",
            )
        )
        # 5. invariance: patch only touches センター Y
        clip_checks.extend(
            _invariance_checks(
                clip_id,
                _clip_package(clip_id) / f"{clip_id}.vmd",
                result["candidate_path"],
            )
        )
        # 6. not a uniform whole-library lift
        correction = result["correction"]
        values = list(correction.values())
        grounded_standing_zero = None
        for window, metric in zip(result["windows"], result["original_metrics"]["windows"]):
            if window["state"] == "standing" and metric["floatGapMinU"] <= float_tol:
                in_window = [correction[f] for f in range(window["f0"], window["f1"] + 1)]
                grounded_standing_zero = max(abs(v) for v in in_window)
                break
        clip_checks.append(
            _check(
                "correction_is_not_a_uniform_shift",
                max(values) - min(values) > 1.5
                and (
                    grounded_standing_zero is None
                    or grounded_standing_zero <= 0.35
                ),
                f"correction span {min(values):.3f}..{max(values):.3f}u, "
                f"already-grounded standing window correction "
                f"{grounded_standing_zero}",
            )
        )
        # 7. dynamics preserved: correction steps bounded and centre travel kept
        steps = [
            abs(correction[f] - correction[prev])
            for prev, f in zip(sorted(correction), sorted(correction)[1:])
        ]
        raw_center = [row["center_y"] for row in result["rows"]]
        corr_center = [row["center_y"] for row in result["corrected"]]
        travel_raw = max(raw_center) - min(raw_center)
        travel_corr = max(corr_center) - min(corr_center)
        clip_checks.append(
            _check(
                "vertical_dynamics_retained",
                max(steps) <= 1.2
                and travel_corr >= 0.3 * travel_raw
                and travel_corr >= 2.0,
                f"max |dC|/frame={max(steps):.3f}u centre travel "
                f"raw={travel_raw:.3f} corrected={travel_corr:.3f}u",
            )
        )
        per_clip[key] = {
            "checks": clip_checks,
            "correctionRangeU": [round(min(values), 4), round(max(values), 4)],
            "originalWindows": result["original_metrics"]["windows"],
            "candidateWindows": result["candidate_metrics"]["windows"],
            "originalVMD_sha256": result["original_sha256"],
            "candidateVMD_sha256": result["candidate_sha256"],
            "metricsBasis": "real FK re-read of exported candidate VMD",
            "lastFrameKeyContract": result["lastFrameKeyContract"],
        }
        all_checks.extend(clip_checks)
    walk_sha_after = _sha256(MOTION_PACKAGES / WALK_ID / f"{WALK_ID}.vmd")
    all_checks.append(
        _check(
            "walk_control_untouched",
            walk_sha_before == walk_sha_after,
            f"walk-loop sha256 stable {walk_sha_before[:12]}...",
        )
    )
    passed = all(check["passed"] for check in all_checks)
    return {
        "passed": passed,
        "rig": str(rig.bone_name_index and "na_2b_0414.pmx"),
        "restFootReferenceY": round(ground, 4),
        "mpu": round(rig.mpu, 6),
        "tolerancesU": {"penetration": penetration_tol, "float": float_tol},
        "checks": all_checks,
        "clips": per_clip,
    }


PENETRATION_TOL = 0.12
FLOAT_TOL = 0.35


if __name__ == "__main__":
    import sys

    out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/gmgn-recovery-calib")
    results = run_regression(
        output_dir=out_dir,
        penetration_tol=PENETRATION_TOL,
        float_tol=FLOAT_TOL,
    )
    (out_dir / "regression.json").write_text(
        json.dumps(results, ensure_ascii=False, indent=1)
    )
    print(json.dumps(results, ensure_ascii=False, indent=1))
    sys.exit(0 if results["passed"] else 1)
