# DSH 返工：重启恢复 readback / 足部姿态 / 非 HLS 声音对照

> **更正（2026-10-03，后一提交）**：本文"交付 2"里"重启静止站姿按双边容差判浮地"的前提已被
> 用户纠正。测试根默认动作就是凳上坐姿，**坐姿允许脚离地**，且"无 `activeActivity` = 站姿"
> 不成立。站姿 / 坐姿判据与入口的更正见
> `docs/plans/evidence/2026-10-03-dsh-pose-semantics-correction.md`。本文的 readback /
> 非 HLS 声音对照部分仍然有效。

本轮只改 `tools/e2e-real-app.py` 与必要的结构化 App 诊断；不改引擎、不碰生产 HLS 判据、
不引入系统录音/TCC。沿用已推送检查点 `e231083` 的真实生成任务
`1536D3FF-C7DE-4C18-BC04-9529E7E3B2F2`（复用避免重复生成花费）。**本轮未跑真实 App E2E**
（主代理负责宿主构建与验收）；宿主内 xcodebuild 因沙箱拒绝 Swift 宏插件无法完成，已做
`swiftc -parse` 与关键 SIMD/枚举片段 `-typecheck`，集成编译以主代理宿主构建为准。

## 交付 1：重启后真正回读（不只世界 loaded）

`restart_recovery` 段新增：

- `verify_restart_placement_readback()`：重启后 `read_owned_props` 回读同一物件，逐项对回
  重启前的 `is_placed` / `position`（≤2 cm）/ `surface_id` / `yaw`（≤0.02 rad）/ 未被手持。
- `verify_restart_screen_readback()`：重启后 `playback_state` 仍投影出同一屏，`contentURL`
  仍是重启前的**原始页面链接**（无签名媒资地址）；没有自动续播时**重走生产 `play_screen`**，
  再验解码帧恢复与 GPU `fragments>0`。

## 交付 2：足部/姿态正确诊断 + 真实 GPU 重启抓帧

App 侧（结构化只读诊断）：

- `PMXStageAvatarRenderer.worldGroundingDiagnostics`：把脚底/全身接触探针经最近一帧**真实**
  `modelTransform` 投到世界，给 `lowestSoleWorldY` / `lowestContactWorldY` /
  `restFootPlaneWorldY` / `leftSoleWorldY` / `rightSoleWorldY` / `modelOriginWorldY` /
  `soleProbeCount` / `contactProbeCount`。
- `PMXSoleGrounding`：`modelSpacePositions`、`minimumWorldY`、`soleSide`（按主导骨骼名分侧）。
- `status.avatarGrounding` 合并上述字段。

驱动侧：

- `verify_restart_foot_pose()`：`wait_restart_foot_settled` 先等脚面在世界坐标收敛；静止站姿
  按**双边容差**判"贴地/浮地"（`-5 mm … +5 cm`），并判全身最低点一致（差 ≤0.25 m）、
  左右脚不穿地；抓 6 帧真实 GPU 回读另存到 `<root>/evidence/restart-frames/` 供视觉核验。
- **未删除任何既有 assert**；旧 `min+offset >= rest` 单边判据保留。

## 交付 3：非 HLS 公开 file-based mp4 声音对照

- 只读确认（不启动 App、不录系统声音）：
  `python3 tools/e2e-real-app.py --check-audio-reference`
  实测默认源 `https://media.w3.org/2010/05/sintel/trailer.mp4`：HTTP 200、`video/mp4`、
  `Accept-Ranges: bytes`、h264 + **aac 音轨** ⇒ `usable: true`（exit 0）。
- 真实链采样（`audio_reference` 段，重启恢复之后，`--skip-audio-reference` 可关）：把该 mp4
  交给**同一条生产 `NativeLinkPlayer`**（`MTAudioProcessingTap` 真实 PCM 采样），判
  tap 挂上 / buffers / frames / 非静音峰值。入口是测试控制面命令 `play_direct_media`
  （只在 `GMGN_E2E_DATA_ROOT` 下存在），因为生产 `play_screen` 白名单只放受支持公开观看页，
  直链会被具名拒绝；**不伪装成 `play_screen` 通过**。
- HLS：`screen_audio` 仍按 `unsupported:hls-manifest` blocked，**未改判**。

## 主代理验收命令

```bash
# 1) 只读确认声音对照源（无需 App，几秒）
python3 tools/e2e-real-app.py --check-audio-reference

# 2) 宿主构建当前树（含 helper）
GMGN_BUNDLE_SCREEN_LINK_HELPER=1 bash tools/e2e-app-build.sh --print-path

# 3) 复用已有真实生成任务跑完整 App E2E（重启恢复 + 足部抓帧 + 声音对照）
python3 tools/e2e-real-app.py \
  --app "$APP" --reuse-root --root /tmp/gmgn-e2e-20261003-1838 \
  --existing-wish-id 1536D3FF-C7DE-4C18-BC04-9529E7E3B2F2 \
  --video-url https://www.twitch.tv/eslcs

# 可选：换对照源
python3 tools/e2e-real-app.py --check-audio-reference \
  --audio-reference-url https://example.com/with-audio.mp4
```

关键证据路径：账本 `tmp/e2e-real-app/ledger.json`；重启抓帧
`<root>/evidence/restart-frames/restart-*.png`（另有 `<root>/evidence/summary.json`）。
