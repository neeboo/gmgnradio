# 2026-09-07 recovery-ground candidate — evidence record

Scope: `tools/motion/recovery_ground.py`, `recovery_ground_calib.py`,
`recovery_ground_regress.py`. Only the 2 PMX recovery clips are verified plus
the walk-loop control hash. VRM counterparts are **not** validated. No
installed MotionPackages file was written; all candidates went to fresh
`mktemp` directories (the old, distrusted `/tmp/gmgn-recovery-calib` was left
untouched). No App/GPU/keychain/system authorization was used; product code
was not modified.

## Contract bug fixed (delta vs absolute センター Y)

`build_correction()` returns a per-frame *delta* on the raw センター key Y
(`corrected_rows` applied it as `raw + delta`), but `VMDClip.patch_center_y()`
was writing that delta verbatim as the *absolute* key Y. Symptom observed
before the fix: get-up-back terminal frame key `11.8668` → `-12.04549`
(expected ≈ `-0.17867`).

Fix: `patch_center_y(corrections)` now **adds each delta to the original key
Y** read from the record (`absolute = raw + delta`) and refuses sparse key
grids (`changed != len(corrections)` → ValueError). Regression + calibrate
prove it by re-reading the exported VMD:

| clip | frame | rawKeyY | deltaY | writtenKeyY | expected raw+delta |
|---|---|---|---|---|---|
| get-up-back | 185 | 11.866824 | -12.045494 | **-0.178670** | -0.178670 |
| faint-recover-back | 401 | -0.036604 | 0.000000 | -0.036604 | -0.036604 |

## Key density audit

`require_dense()` (recovery_ground.py) audits keyed bones: every *keyed* bone
must carry a key on every integer frame `0..last_frame` (gap 1). `vmd_key_at`
falls back to an endpoint on missing keys, which is only faithful under dense
keying; sparse clips are refused, never silently evaluated or interpolated.

Real clips: all 19 keyed bones × 402 (faint, 0..401) and 186 (get-up, 0..185)
centre keys, dense, gap 1 → audit passes and the FK hold path is never hit in
the evaluated grid.

## Regression basis (real FK, not theory)

`run_regression()`/`command_calibrate()` write the candidate, then **re-open
the exported `.calibrated.vmd`** and re-run `evaluate_clip` (real FK +
skinned low envelope). The theoretical `corrected_rows` (raw+delta) translation
is no longer used as the passing basis anywhere in regress or calibrate
(`metricsBasis: "real FK re-read of exported candidate VMD"` in outputs).

Run commands (repo root; direct-path execution cannot import `tools`):
`python3 -m tools.motion.recovery_ground_calib regress --output-dir DIR`
`python3 -m tools.motion.recovery_ground_calib calibrate --output-dir DIR`
`... profile --output-dir DIR`

## Results (strict thresholds: penetration 0.12 u, float 0.35 u — unchanged)

Regression: **passed, 20/20 checks**, tolerances not relaxed
(exit 0). Rig: rest_foot_reference_y = -0.0022 u, mpu = 0.080085.

| clip | corr range (u) | cand. rest windows (pen / floatMin / floatMax u) |
|---|---|---|
| get-up-back | [-12.078, -5.937] | lying 0-39: -0.02 / 0.02 / 0.095; standing 122-185: -0.02 / 0.02 / 0.074 |
| faint-recover-back | [0.000, 6.632] | standing 0-23: -0.106 / 0.106 / 0.133; lying 52-195: -0.02 / 0.02 / 0.329; standing 260-401: -0.079 / 0.079 / 0.270 |

At all sampled integer frames (both candidates): minimum body Y = +0.0178 u,
which is 0.0200 u above the bind-sole floor at -0.0022 u
(`maxPenetrationU = -0.02`, i.e. no frame penetrates). Originals fail as
designed: get-up floats +5.96 u in lying, faint penetrates 6.61 u in lying.
Centre-only Y change verified (186/236 centre keys, 0 rotation / XZ / grid
diffs), walk-loop VMD sha256 stable before/after.

Note (not a green-wash): faint lying gapMax 0.329 u sits 0.021 u under the
0.35 band — reported as measured, threshold untouched.

## Honest residuals / limitations (recorded, not fixed here)

- **CPU skinning**: linear-blend FK skin; SDEF approximated as BDEF2; dense
  integer-frame sampling does not validate fractional-frame interpolation; PMX physics
  detached → skirt/hair/coat chains stay rigid.
- **Cloth residual**: whole-clip max cloth-under up to 2.43 u (faint), 1.02 u
  (get-up) — rigid trailing cloth under floor, never used as contact anchor.
- **Transition residual**: mid-rise float up to 1.57 u (get-up) / 1.22 u
  (faint), transition frames never re-anchored (82 / 92 frames reported).
- **VRM**: counterpart clips unverified in this scope.
- Rigid-sole assumption: bind sole = floor; runtime normalisation (1.7 m) and
  PMXSoleGrounding semantics are emulated offline, not executed on device.

## Artifacts

Output dirs (fresh, per run): regress
`/tmp/gmgn-recovery-calib2.Skj3wJ`, calibrate `/tmp/gmgn-recovery-calib3.S8pboY`.
Candidates are deterministic: identical sha256 in both runs.

主代理独立复跑：`/tmp/gmgn-recovery-main.SmNQnV/regression.json`，退出码 0，20/20 项通过，阈值保持 0.12 / 0.35 u。另验证了“重复帧掩盖缺帧”的稀疏输入会被拒绝。候选未安装；衣裙、过渡悬浮、帧间插值与实际宿主画面仍未通过验收。

| file | sha256 |
|---|---|
| na_2b_0414.pmx (2601300 B) | 0a9cbf81c0c9f87cc814df450f8b405c35fb5d67994a596563c95ec1d974ea57 |
| walk-loop-pmx.vmd (90761 B) | 4c12642f6b7b4791983a98727bf6d59baf0da4688f0046ca594cbb2c93f7eb19 |
| recovery-get-up-back-pmx.vmd (392348 B, original) | 91073fe9ff058dd0e87d12a0bf4c36b8d2ae134f12f86616625a1abf068f5008 |
| recovery-faint-recover-back-pmx.vmd (847892 B, original) | 399e6a36d2d7828948139b309492cec20816180e729a69686ad2810d27c8edfd |
| get-up-back `.calibrated.vmd` (candidate) | 7d0b0d6d62464e4189aaf12fbb61a744f8262dce4b6d1f3957d7adedcc24954e |
| faint-recover-back `.calibrated.vmd` (candidate) | 8c0a8c3ec76d510482b35f56d0dbf370dda95725f1eb43aa2600f86d02a0d529 |
