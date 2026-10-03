# DSH 返工交付与验收说明 — 2026-10-03（第二轮）

接手 `docs/plans/2026-10-03-dsh-reacceptance-task.md`。本轮**不是写方案**：每条都落到
了生产代码 / 门禁 / 驱动器里，能独立复跑的都在 DSH 内跑过并附结果。主代理在宿主做最终
构建与真实 E2E。

- 基线：`HEAD b8e9056`（主代理宿主 `make build` 退出码 0，日志
  `/tmp/gmgn-parent-reacceptance-build-20261003.log`）。
- 本轮**未** commit / push / reset / checkout / `git add -A`；未改 `tools/world-backup/`；
  未替换引擎；未动 `/Applications` 已装应用、真实用户数据与 Keychain；未用 AppleScript。
- 主代理已在本轮于宿主启动 `tools/e2e-app-build.sh --print-path`（日志
  `/tmp/gmgn-parent-host-e2e-build-20261003.log`）；DSH **没有**并行生成工程/构建。

---

# 第六轮返工（2026-10-03，接主代理 18:04 崩溃 / 对话审计）

基线：主代理 18:04 真实 App 崩溃报告
`/Users/ghostcorn/Library/Logs/DiagnosticReports/gmgn radio-2026-10-03-180453.ips`
（`_dispatch_assert_queue_fail` → `_swift_task_checkIsolatedSwift` →
`NativeAudioSampleTap.install(on:track:) closure #3`），以及同一时间的只读对话审计。

本轮**未** commit / push / reset / `git add -A`；未改 `tools/world-backup/`；未替换引擎；
未动 `/Applications` 已装应用、真实用户数据与 Keychain；未用 AppleScript；**未**在 DSH 内
构建 App、**未**运行同一测试 App/root。他人已改的播放 epoch / 选点 / 音频采样改动一律保留。

## F.1 音频线程隔离断言（`NativeAudioSampleTap.install`）

根因是 `install` 带 `@MainActor`，音频回调闭包因此继承主 actor 隔离，音频线程进入回调时
触发 `dispatch_assert_queue_fail`。主代理已删掉 `install` 上的 `@MainActor`；本轮**未回退**，
并确认 `NativeAudioSampleTap` 为 `@unchecked Sendable`、`prepare`/`record` 均不在主 actor 上，
`install` 签名现在是 `func install(on item: AVPlayerItem, track: AVAssetTrack?)`。

## F.2 真实 chat 内部失败因：保存必须早于清 `currentResidentAgent`

问题：`ResidentCodexAgent` 已有 `failureStage/Code/Category/Detail`，但 `sendResident` 只靠
`catch` 保存；E2E 会因 agent 引用被清而只剩 UI 那句「居民未能完成本轮回复」。

修法（生产代码）：

- `AgentConversationService.sendResident`：把失败因保存放进**清 `currentResidentAgent` 之前**
  的 `defer`（成功/抛错/取消三条路径都会执行），只存安全投影后的字段，绝不带 stderr / 认证
  配置 / 凭据。
- 新增有界历史 `residentFailureHistory`（最近 8 条）：`lastResidentFailure` 会被下一轮成功或
  更晚失败覆盖，历史让"具体哪一轮、为什么"在 App 运行结束后仍可回看。
- `ResidentCodexAgent` 新增 `failureTurnStatus` / `failureErrorShape`（只列协议字段名集合，
  不含值）：当 category/detail 只能给出 `unclassified` 时，用它区分「`turn.error` 缺失」与
  「错误体不是预期字典」；`turn/completed` 与 `error` 通知两条失败路径统一走
  `recordSafeError`。
- `GMGNRadioApp.e2eStatusSnapshot` 的 `agentConversation` 增加 `recentResidentFailures`。
- 驱动器 `verify_chat_turn` 用新增只读 helper `resident_failure_for_turn` 按回合时间从历史里
  取失败因，并把 `residentFailures` 写进账本；`lastResidentFailure` 为空时不再只报"未知"。

## F.3 本轮 DSH 内实际跑过

| 命令 | 结果 |
|---|---|
| `swift tools/test-resident-codex-agent.swift` | exit 0：`PASS: 189 resident Codex agent checks`（含本轮改动的 `ResidentCodexAgent` + `AgentConversationService`，`-swift-version 6`） |
| `python3 -m unittest tools.tests.test_e2e_real_app` | exit 0：`Ran 64 tests ... OK`（新增 4 条失败因按轮取回断言） |

顺带修好 `test-resident-codex-agent.swift` 的源码清单：`ResidentDSHHostToolsBridge` 读
`Presence/RetryBackoff.swift` 的共享退避策略，该自包含源码未随 harness 编译，导致
`cannot find 'RetryBackoffSite' in scope`；补进清单后恢复绿。

## F.4 给主代理的重跑与要看的东西

同一构建/同一隔离根重跑 `chat_turn`（本轮**不**要求 skip-chat-turn）；终态 `failed` 时，
账本 `residentFailure` 会给出 `stage/code/category/detail/turnStatus/errorShape`。要具体
根因就看这几项：`category=missing_provider_env` ⇒ 隔离环境缺 provider 变量；
`code=unauthorized`/`unsupported_model`/`httpConnectionFailed:4xx` ⇒ 上游拒绝；
`errorShape` 非 `message,codexErrorInfo` 或缺 `turn.error` ⇒ 协议面形状变化。
`NativeAudioSampleTap` 采样字段（`sampledAudioBuffers/Frames`、`audioPeakAmplitude`）保持
真实采样，未禁采样冒充通过。

---

# 第五轮返工（2026-10-03，接主代理 17:38 真实恢复验收 53 pass / 6 fail）

基线：主代理当前树 build2（`/tmp/gmgn-parent-reacceptance-1740-build2.log`，exit 0）与
17:38 真实恢复运行（`/tmp/gmgn-parent-reacceptance-1740-real-app3.log`，53 pass / 6 fail）。
本轮只修失败与补未验项，**未** commit/push/reset/`git add -A`；未改 `tools/world-backup/`、
未替换引擎、未动 `/Applications` 已装应用、真实用户数据与 Keychain；未用 AppleScript。
保护主代理已有改动：`claimEvidence` 非可选值误用修复、`sampleProvider` 显式
`@MainActor/@Sendable`、driver 的 `center` 数组读取、已领取任务的
`run_owned_placement` 恢复分支，一律保留未回退。

## E.1 摆放 `placement_rejected`（贴墙格心）— 改成真的选可放位置（不关碰撞）

根因：驱动器固定取 `list_placement_surfaces` 的第一层格心，真实舱体那一格贴墙，
被**真实的** `PropPlacementEvaluator` 以 `blockedByMesh` 拒绝。判据没错，是选点错。

修法（`tools/e2e-real-app.py`）：

- 新增 `find_placeable_placement(...)`：候选按"离所有格心质心由近到远"排序，逐个交给
  **与落地完全同源**的 `preview_prop_placement`；只有预检放行的候选才拿去
  `apply_prop_placement`。上限 `PLACEMENT_PROBE_BUDGET = 160`。
- 一个都没通过时具名 `blocked`（带最后一次原因），**绝不**退回固定格心硬提交。
- **碰撞判据一个字没放宽**：没有关碰撞、没有改表面算法，只是不再闭眼选第一格。

## E.2 电视 `screen_not_found` — 定位为摆放失败的连锁，画面链已就绪

`WorldScreenStore.rebuild()` 只看 `state.isEnabled == true` 的物件；`.place` 才置真。
上一轮 `apply_prop_placement` 被拒 ⇒ 物件只在库存/手持（`isEnabled=false`）⇒
`resolveTarget` 与 `unrecognizedScreenCandidates()` 都为空 ⇒ `screen_not_found`
（`unrecognized: "0"`）。名字判据本身没问题（"E2E 端到端电视" 含「电视」）。E.1 修好后
摆放→手持→放回会把物件留在**已摆出**状态，屏幕即可被识别，`WorldScreenVideoRenderer`
的画面判据（`drawPasses/encodedQuads/fragments`）与原生解码链已在前几轮接好。

## E.3 重启接地 `min=-5.026 / lift=5.11 / offset=0` — 字段语义 + 真实渲染分开

- 新增渲染事实字段 `appliedGroundingOffsetY`：最近一帧**真实乘进 `modelTransform`** 的
  补偿（`PMXFullStageGroundingPolicy` 之后），与策略前的 `groundingOffsetY` 分开上报。
  渲染器同时暴露 `renderedSceneTime` / `renderedAvatarFrameCount`（只随真实角色帧递增）。
- 驱动器新增 `wait_grounding_consistent(...)`：按真实渲染帧等到
  `minimumContactY + appliedGroundingOffsetY + 5mm ≥ restGlobalReferenceY` 再断言；
  超时仍不收敛则如实判红。逐帧运动判据也改用 `appliedGroundingOffsetY`（缺字段才回落），
  把"算出来但没施加"钉红。
- 这解释了重启时的读数：偏移被 `clearMotion` 清零后要等下一帧真实渲染重算；读一次可能
  踩到空窗。现在不靠"读一次碰运气"，也不把持续不收敛放过去。

## E.4 动作指标 `avatarFrameRevision` 全 1 — 换成逐帧结构化骨骼姿态 + 播放时钟

- `PMXStageAvatarRenderer` 新增 `motionPlaybackSnapshot`（结构化）：真实 `clip` /
  `hasPlayer` / `speed` / `sceneTime` / `renderedAvatarFrameCount` / 每根诊断骨骼
  （左/右腕、左/右膝、左/右足）相对静止姿态的角度 / `maximumBoneAngleDegrees` /
  `poseDigest` / `restBoneCount`。
- `MarbleSpatialView` 新增 `avatarMotionDiagnostics`；`GMGNRadioApp` 把它接进
  `status.avatarMotion` 与 `capture_frames`（`trackGrounding`）的逐帧采样。
- 驱动器删掉"资源 revision 递增"这条验收指标（降级为 info），新增
  `check_motion_pose(...)`：要求 `hasPlayer`、`clip != none`、`sceneTime` 推进、
  `renderedAvatarFrameCount` 严格递增、骨骼姿态真的在变（最大骨骼角 > 1° 且 digest
  或单骨跨度 > 1°）。**只换 GPU frameIndex / 资源 revision 冒充动作会红**，单测里加了
  冻结骨骼但相机帧照常前进的负对照。

## E.5 坐下：默认世界补真实活动入口

`apps/macos/Resources/Worlds/marble-living-cabin/world.json` 增加 `chair.sit`
（`action: sit`，锚点 `wp.spawn`，loop 动作 `gmgn.motion.bones.chair-sit-loop-pmx/vrm`，
六个相位齐全），并登记 `activity:chair.sit` 能力。`wp.spawn` 与锚点 transform 距离 0，
`WorldPackageValidator` 的 0.08 m 约束满足。`MarbleLivingCabinPackageTests` 的期望活动集合
同步加入 `chair.sit`。

## E.6 真实 chat 回合提交链

- `AgentConversationService` 增加只读 `sendEnteredCount` / `lastSendReceipt`。
- `e2eStatusSnapshot` 增加 `chatScopeKey` / `chatTurns`（id/原文/投递终态/回复/中断原因）/
  `residentLoop`（runID/modelTurnsStarted/lastFailure…）/ `agentConversation`
  （可用后端、已装后端、进入次数、最近一次 send）。
- 驱动器新增 `chat_turn` 段（默认执行，`--skip-chat-turn` 可关）：走生产 `submit_wish`
  提交门 → 断言回合被登记、`sendEnteredCount` 增长、`modelTurnsStarted` 增长；终态
  `delivered` 通过，`failed/cancelled/interrupted` 具名 `blocked`（把 `lastFailure` 写进账本），
  没有可用后端时直接 `blocked`，绝不空跑通过。

## E.7 电视声音：真实解码 PCM 采样（无麦克风权限）

- `NativeLinkPlayer` 新增 `NativeAudioSampleTap`（`MTAudioProcessingTap`，直通输出，
  不静音、不改音量）；记录 `sampledAudioBuffers` / `sampledAudioFrames` /
  `audioPeakAmplitude`，并暴露 `isMuted` / `volume` / `rate` / `hasAudio`。
  分轨 item 同步挂 tap；HLS/清单等轨道协商完再异步补挂。
- `NativeScreenPlaybackCoordinator.Metrics` 与 `playback_state.nativeLink` 增加这些字段。
- 驱动器新增 `screen_audio` 段：`isMuted=false`、`volume>0`、`rate>0` 必须成立；
  tap 挂不上时具名 `blocked`；挂上后要求采样缓冲/帧增长且峰值 > 0（真实非静音 PCM）。

## E.8 本轮 DSH 内实际跑过

| 命令 | 结果 |
|---|---|
| `swift tools/test-pmx-frame-diagnostics.swift` | exit 0（7 条，含本轮新增结构化诊断源码） |
| `swift tools/test-avatar-grounding.swift` | exit 0（17 条 + 源级 + 注入） |
| `swift tools/test-motion-playback-lifecycle.swift` | exit 0（含"渲染路径不再每帧写 player.speed"） |
| `swift tools/test-resident-screen-app-wiring.swift` | exit 0 |
| `swift tools/probe-native-link-playback.swift` | exit 0（11 条，编译本轮改动的 `NativeLinkPlayer.swift`） |
| `swift tools/test-resident-screen-overlay.swift` | 见日志（屏幕判据 + 注入负对照） |
| `python3 -m unittest discover -s tools/tests -p 'test_*.py'` | exit 0（70 条；新增摆放选点、applied 补偿、冻结姿态负对照） |

## E.9 未在本机验证（主代理宿主复验）

- App target 的完整编译仍由主代理宿主 `make build` / `tools/e2e-app-build.sh` 出具
  （DSH 内 `xcodebuild` 沙箱受限）。
- `MTAudioProcessingTap` 在 Twitch HLS 上是否真的产出 PCM 采样，需要真实 App 运行验证；
  挂不上时驱动器会如实 `blocked`（不冒充通过）。
- 坐下的真实姿态变化依赖测试根装好 `gmgn.motion.bones.chair-sit-loop-pmx`（命令行已含）。

---

# 第四轮返工（2026-10-03，接主代理冷启动接线返工）— 单一 taskd 根 / 安全测试根 / 真实活动接地

主代理本轮的真实 E2E 进展：短目录可加载世界、PMX 标准人物与 4 个 BONES 动作已复制到
`/tmp/gmgn-e2e-20261003-1710`、真实人物/接地/连续 GPU 帧通过、真实生成已提交。本轮把
冷启动接线的剩余硬缺口落到生产代码 / 驱动器 / 门禁里。本轮**未** commit / push / reset /
`git add -A`；未动运行中的测试目录 `/tmp/gmgn-e2e-20261003-1710`；未碰 Keychain / 生产
数据；未替换引擎；未用 AppleScript；保护主代理已有修改（`e2eWishAuthorizationID` 授权、
driver `providerMessage`）。

## D.1 单一 taskd 根（世界权威 ↔ 生成服务同根）

`Presence/AuthorityWorldStatePersistence.swift` 的 `WorldAuthorityEndpoint` 原来在显式
`applicationSupportBase` 下把 socket 落在 `<base>/TaskService/taskd.sock`，而
`PropTaskDaemonClient(root:)` 落在 `<base>/gmgn radio/TaskService/taskd.sock` ——
同一个测试根里真的出现了两个 taskd（`/tmp/gmgn-e2e-20261003-1710/.../TaskService` 与
`.../gmgn radio/TaskService` 两份 `taskd.sock` 都在）。世界加载走一个、生成/入库走另一个。

修法：新增**唯一**拼根口 `WorldAuthorityEndpoint.taskServiceRoot(applicationSupportBase:)`
（恒为 `<Application Support>/gmgn radio/TaskService`），`WorldAuthorityEndpoint` 与
`GMGNRadioApp.injectedTaskDaemonRoot` 都只经它取根。生产（base=nil）逐字节不变。

## D.2 默认短安全测试根 + 已有 root 默认拒绝覆盖

`tools/e2e-real-app.py`：

- 默认根从仓库内 `tmp/e2e-real-app/<时间戳>` 改为 `/tmp/gmgn-e2e-<时间戳>`：taskd 走
  AF_UNIX，`sockaddr_un.sun_path` 在 macOS 上 104 字节（含 NUL）。默认根 socket 路径实测
  92 字节；过深的 `--root` 在启动前就被 `validate_taskd_socket_path` 拒绝并给出短根建议。
- **已有 root 默认拒绝覆盖**：默认不再静默 `rmtree`；要复用显式 `--reuse-root`，要删掉
  重建显式 `--overwrite-root`。同时拒绝把真实用户 Application Support / home 当测试根。

## D.3 `--avatar-source` / `--motion-source`：只读源 → **复制**进测试根

新增 `--avatar-source` / `--motion-source`（可重复，接受单个包或包目录）。驱动器把包装
**复制**到 `<root>/Library/Application Support/gmgn radio/{PresencePackages,MotionPackages}`，
并把来源的选中项写进**测试根自己的** `.selection.json`：

- **绝不**把生产 PresencePackages/MotionPackages symlink 到测试根；
- 源里任何 symlink 一律拒绝（不放宽现有 symlink 安全检查）；
- 生产 selection 只读、绝不写；`production_fingerprint` 现在把两个
  `PresencePackages/.selection.json`、`MotionPackages/.selection.json` 单独纳入指纹 ——
  写它们只改子目录 mtime，只看 `gmgn radio` 根目录会把这类越界写漏过去。

## D.4 真实活动入口 + 连续运动帧接地（不再 idle 静止冒充穿地已验）

驱动器新增 `activity_motion` 段（排在生成之前，生成 blocked 也不丢这一段）：

- 经生产 `list_available_activities` 发现当前世界声明的活动；
- 对 行走 / 跳跃 / 坐下 三类各选候选，经生产 `start_activity` 启动，等
  `status.activeActivity` 真的是它，再连续抓帧（`capture_frames` 新增 `trackGrounding`）；
- 生产 `stop_activity` 收尾。世界没声明的类别仍然触发一次入口拿到具名拒绝码
  （证明入口控制在工作），但**不记 pass**；
- 至少一类真实非待机活动被验证，否则硬 FAIL（idle-only 不能通过）。

宿主侧：`capture_frames` 在 `trackGrounding=true` 时给**每一帧**附上同一时刻的
`residentPosition` / `activeActivity` / `activityPhase` / `avatarGrounding`。

逐帧接地判据（比旧 status 判据强）：除 `lift + 0.05 >= uncompensated`、`lift >= 0` 外，
新增 **`minimumContactY + groundingOffsetY + 0.005 >= restGlobalReferenceY`** —— 这条能把
"offset 算出来了但渲染没施加 / 被清零"的回归钉红（旧的只看 lift 是自证的）。行走还要求
位置跨度 ≥ 0.01 m（静止不算走）。

## D.5 本轮 DSH 内实际跑过并通过的门禁

| 命令 | 结果 |
|---|---|
| `swift tools/test-e2e-root-unification.swift` | PASS：4 条 socket 根断言 + 注入负对照（抽掉 `gmgn radio` 一层必须红）+ 6 条来源扫描；exit 0 |
| `swift tools/test-e2e-isolation.swift` | PASS：8 条 + 注入来源扫描；exit 0 |
| `swift tools/test-avatar-grounding.swift` | PASS：17 条 + 3 条源级 + 注入；exit 0 |
| `swift tools/test-resident-screen-app-wiring.swift` | PASS：电视机接线判据全部通过；exit 0 |
| `python3 -m unittest discover -s tools/tests -p 'test_*.py'` | OK：44 条（新增 34 条：短根 / AF_UNIX 上限 / 生产根拒绝 / 已有 root 拒绝覆盖 / 复制 vs symlink / reuse 不重拷 / selection 落测试根 / 指纹含 selection / 逐帧接地含"清零 offset 必红"、静止行走必红、活动缺失必红 / 世界工具错误码解析） |
| `make test-python` | EXIT=0（含上面的 44 条） |

**App target 编译仍由主代理宿主出具**（DSH 内 `xcodebuild` 被沙箱挡在 SwiftPM manifest
缓存，按既定边界不在 DSH 内构建）。

## D.6 给主代理的重构建 + E2E 命令

```bash
cd /Users/ghostcorn/dev/gmgnradio
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 1) 重构建当前代码（含本轮 Swift 改动：单一 taskd 根 / 逐帧接地采样 / status 暴露 avatar）
make build
make test-harnesses          # 含新增 tools/test-e2e-root-unification.swift
make test-python             # 含新增 tools/tests/test_e2e_real_app.py

# 2) 独立测试产物
APP="$(tools/e2e-app-build.sh --print-path)"

# 3) 真实 E2E：短根默认、人物/动作从生产**复制**进测试根（源只读、selection 写测试根）
python3 tools/e2e-real-app.py --app "$APP" \
    --avatar-source "$HOME/Library/Application Support/gmgn radio/PresencePackages/pmx.2b-miss-0414-standard" \
    --motion-source "$HOME/Library/Application Support/gmgn radio/MotionPackages/gmgn.motion.bones.walk-loop-pmx" \
    --motion-source "$HOME/Library/Application Support/gmgn radio/MotionPackages/gmgn.motion.bones.jumping-jacks-pmx" \
    --motion-source "$HOME/Library/Application Support/gmgn radio/MotionPackages/gmgn.motion.bones.chair-sit-loop-pmx" \
    --motion-source "$HOME/Library/Application Support/gmgn radio/MotionPackages/gmgn.motion.bones.idle-loop-pmx" \
    --prop-config "$HOME/Library/Application Support/ai.gmgn.radio/secrets/prop-generation.json" \
    --video-url https://www.twitch.tv/eslcs
```

判定同上：`activity_motion` 段的逐帧接地必须全绿（`motion_grounding` 账本条目），
行走位移跨度 ≥ 0.01 m；世界没声明的类别（marble 世界没有坐下的世界声明）在账本里
具名记录但不算通过。默认世界 `marble-living-cabin` 声明 `home.walk` 与
`performance.jumping_jacks`；若要验坐下，需要世界声明 `bunk.rest` / `chair.sit`
（`living-pod-v1` / `warm-kitchen-canary` 才有），本轮不擅自切换世界。

## D.7 本轮边界（如实说）

- 本轮没有在 DSH 内跑真实 App（沙箱不允许 xcodebuild）；逐帧活动接地判据的**行为**由
  合成帧单测（清零 offset 必红、静止行走必红、活动缺失必红）钉住，真实数字由主代理宿主 E2E 出具。
- 默认世界 marble 没有坐下活动，`activity_motion` 会对坐下调一次生产入口拿到具名拒绝
  并如实记录；这是世界声明的事实，不是通过。


# 第三轮返工（2026-10-03，接主代理拒收）— 电视画面渲染 + helper 打包

主代理拒收的两条原文：**「`WorldScreenNativeVideoRegistry` 未被 `MarbleSpatialView` 消费，
电视实际没画面，不能用解码统计当播放」** 与 **「完成 yt-dlp 打包脚本与 hash pinned
可复现路径，不要空 hash 交付」**。两条都已落到生产代码 / 脚本 / 门禁里，并在 DSH 内跑过。

本轮**未** commit / push / reset / checkout / `git add -A`；未改 `tools/world-backup/`、
未替换引擎、未动 `/Applications` 已装应用、真实用户数据与 Keychain；未用 AppleScript。

## A. 电视画面：原生视频纹理真的画进场景 + 深度遮挡

### A.1 新件

| 文件 | 作用 |
|---|---|
| `VisualEngine/Shaders/WorldScreenVideo.metal` | 世界四角 → 裁剪空间（与 `marbleOccluderVertex` 同一条反向深度翻转）；采样解码纹理并做 sRGB→线性（drawable 是 `bgra8Unorm_srgb`，不做就二次 gamma） |
| `VisualEngine/Metal/WorldScreenVideoRenderer.swift` | 唯一的渲染 pass：管线 / 深度状态（forward `.less`、reverse `.greater`，**都写深度**）/ 采样器 / 每屏一张的 GPU 可见性查询；只读度量 `Stats` |
| `tools/probe-screen-video-render.swift` | 离线判据：把上面两份生产源码 + 同一个 `.metal` **原文**编起来，在真 Metal 离屏纹理上验"真的画了 / 真的被深度挡住" |

### A.2 接线（生产路径，唯一一处）

- `MarbleSpatialView` 增加 `worldScreenNativeVideoRegistry`（转发给渲染器）与
  `screenVideoDiagnostics`；
- `MarbleSpatialRenderer.draw` 在**道具之后、角色之前**读 `registry.frames()` 并调
  `WorldScreenVideoRenderer.render`：与房间遮挡网格 / 已摆放道具共用同一张 color+depth
  —— 前墙/道具挡住电视，电视写深度后**身后的角色被电视挡住**
  （`drawAvatar` 的 `preservesDepth` 链接上 `screenVideoDrew`）；
- `GMGNRadioApp.installScreenOverlayIfNeeded` / 舞台渲染面构造点把
  `WorldScreenStore.nativeVideoRegistry` 注入渲染面（两处幂等，谁先建好都能接上）；
- `playback_state` / `status` 暴露 `screenVideo`（`drawPasses` / `encodedQuads` /
  `fragments` / `lastObjectIDs` / 纹理尺寸）。

**没有登记任何屏幕时 `frames()` 为空，一个视频 pass 都不加，既有画面逐字节不变。**

### A.3 帧所有权（渲染器与帧泵不再抢帧）

`NativeLinkPlayer.copyFrameTexture()` 改为返回**最近一帧**：有新像素就解一帧、blit 进私有
纹理；没有新帧就返回上一张（而不是 `nil`）。帧泵（~30 Hz）与渲染器（~60 Hz）同时拉时，
谁先取到新帧都不会让另一方空手而归；`decodedFrames` / `gpuCopies` 仍然只按**新帧**计数。

### A.4 本机已跑（可复跑）

```bash
cd /Users/ghostcorn/dev/gmgnradio
swift tools/probe-screen-video-render.swift       # 行为 15 条 + 源码接线 9 条，全过
swift tools/probe-native-link-playback.swift      # 离线 11 条，全过（改动后复跑）
swift tools/test-screen-link-behavior.swift       # 原件全过 + 注入负对照全红
swift tools/test-resident-screen-overlay.swift    # 电视机判据全部通过
swift tools/test-resident-screen-app-wiring.swift # 接线判据全部通过
make test-harnesses                                # 全量 harness exit 0（含本轮新增两件）
make test-python                                   # exit 0（含新增的 helper 打包 9 条）
```

`probe-screen-video-render.swift` 的实测数字：可见四边形 **784 片元**（GPU 可见性查询与
独立数出的亮像素数**一致**）→ 色值为纹理的纯红 → 深度清到更近后 **0 片元** →
两台电视按深度分先后（远的那台 +0 片元）→ 没出画时 `render=false`（不画黑矩形）。
源码级判据额外钉住"`registry.frames()` 真的被读、真的交给渲染器、视频 pass 的深度真的
并入 `drawAvatar`" —— 上一轮的缺口正是"注册了但没人消费"。

### A.5 顺带修复的既有门禁红（不是本轮引入，但 `make test-harnesses` 一直红）

- `test-livecam-panel-sizing.swift` / `test-livecam-no-occlusion.swift`：上一轮给
  `LiveCamPanel.swift` 加了 `E2ERuntime.applicationSupportBase` 的附件目录注入，但这两
  个 harness 没把 `App/E2ERuntime.swift` 编进来源 ⇒ 停在校验编译（`cannot find
  'E2ERuntime' in scope`）。本轮把这份（Foundation-only、自包含）源码补进
  `attachmentSources`，两个 harness 恢复绿。
- `test-user-facing-copy.swift`：`GMGNRadioApp.swift` 的 E2E 回执里出现禁词「后端」、
  以及本轮新增的 license note 命中「文件路径 / 超长」⇒ 文案改为「服务」并压到两句内，
  扫描 2586 条可见文案违规 0。
- **Swift 6 严格并发下的一个潜在编译阻断**：`ScreenLinkRedaction.swift` 的
  `ScreenLinkSitePolicy.rules` 是全局常量，`Rule.isWatchPath` 的类型是裸 `(URL) -> Bool`
  ⇒ 在 `-swift-version 6` 下报 `static property 'rules' is not concurrency-safe`
  （`Rule` 不是 Sendable）。这条被 `make test-harnesses` 的默认语言模式掩盖了。
  本轮把闭包标成 `@Sendable` 并让 `Rule: Sendable`（判据都是纯函数，不捕获状态），
  不用 `nonisolated(unsafe)` 绕过。
- **本轮对 DSH 能隔离编译的部分做了 `-swift-version 6` 类型检查**（App target 需要
  包模块，仍由主代理构建）：`LinkResolver/*`、`NativeMedia/*`、`WorldScreenGeometry/State/
  Content/Inference`、`ResidentScreenTools`、`WorldScreenPersistence`、`E2ERuntime`、
  `E2EHostControl` + `ResidentVisionCapture`、`WorldScreenNativeVideoRegistry` +
  `WorldScreenVideoRenderer` —— 全部 `error-count=0`。

## B. yt-dlp 打包：hash pinned、可复现、空哈希直接拒

### B.1 单一来源 + 运行时权威

| 文件 | 角色 |
|---|---|
| `tools/helpers/screen-link-helpers.lock.json` | 打包钉死清单（版本 / 来源 / sha256 / 许可 / 归档哈希） |
| `tools/bundle-screen-link-helper.py` | 唯一写者：读钉死清单 → 下载（或 `--source-dir` 离线）→ 校验 → 内置 `<app>/Contents/Helpers/` + `<name>.sha256`；**空/非法哈希直接 exit 1** |
| `tools/verify-helper-manifest.py` | 独立复核：helper 在包里就必须与钉死哈希一致；`--require-screen-link` 时缺了即红 |
| `tools/test-screen-link-helper-lock.swift` | 锁文件 ↔ `BundledHelperManifest.pinned` **逐字段**一致 + 4 条注入（空哈希 / 版本 / 许可 / 少源码组件）必须红 |
| `apps/macos/Resources/Helpers/THIRD_PARTY_LICENSES.txt` | 随包许可声明（yt-dlp 独立二进制是 **GPLv3+ 组合作品**） |

`BundledHelperManifest.pinned` 现在钉的是**实测值**（不再是空串）：

- `yt-dlp` `2026.06.09` = `b82c…f244`（官方 `yt-dlp_macos`，universal x86_64+arm64）；
- `deno` `2.9.7` = `b737…7f1a`（arm64；默认不内置，`--include deno` 才随包）；
- `yt-dlp-ejs` 是**源码树**（没有单文件 sha256），改为 `components` 里的许可/版本登记。

打包入口：

```bash
make bundle-screen-link-helper APP="/path/to/gmgn radio.app"        # yt-dlp
make bundle-screen-link-helper APP="..." INCLUDE=deno               # + deno
# 独立复核（缺 yt-dlp 即红）：
python3 tools/verify-helper-manifest.py --app "/path/to/gmgn radio.app" --require-screen-link
# 或构建时一步到位：
GMGN_BUNDLE_SCREEN_LINK_HELPER=1 tools/e2e-app-build.sh --print-path
```

### B.2 本机已跑（可复跑，含真实下载）

- 离线 `--source-dir` 内置 + `--verify-only`：exit 0；
- **真实网络下载**（yt-dlp + deno）→ 校验 → 内置 → 复核：exit 0；
- 空哈希 / 非十六进制哈希锁：exit 1（`拒绝交付未钉哈希的 helper`）；
- `python3 -m unittest discover -s tools/tests -p 'test_*.py'`：10 条全过（空哈希拒装、
  哈希不符拒、装完 `--verify-only` 可复核、篡改后红、缺许可声明红、
  `--require-screen-link` 缺则红）；已挂进 `make test-python`；
- `verify-helper-manifest.py`：无 yt-dlp 时 `absent` 不红；`--require-screen-link` 缺则红；
  篡改一个字节后 `manifest_mismatch` 红；
- 用内置的 yt-dlp 跑 `probe-native-link-playback.swift https://www.twitch.tv/eslcs`：
  **731 帧解码 / 731 次 GPU 拷贝 / 256×144 / 时间前进 25.3 s / verdict=PLAYING**（真解析、
  真解码、真进 Metal 纹理）。

### B.3 YouTube 403 的具名诊断（没有统称"反爬"）

用钉死的 yt-dlp 解析 YouTube VOD `aqz-KE-bpKQ`：解析面**成功**（33 个格式，选出
`avc1` 360p）；但 media 面的签名地址 `Range: bytes=0-1048575` 与 `bytes=0-2000000000`
**都返回 403**，加 `--js-runtimes deno:<内置>` 与 `--remote-components ejs:github` 后仍然
403。归类为**媒体面平台阻断**（PO token / 播放器客户端），不是本项目参数或编码问题。
Twitch 直播同一套生产路径可播（见 B.2）。因此验收"电视真的出画面"时给驱动器的
`--video-url` 指向真实可播链接：

```bash
python3 tools/e2e-real-app.py --app "$(tools/e2e-app-build.sh --print-path)" \
    --video-url https://www.twitch.tv/eslcs
```

驱动器的 `video_playback` 现在**新增画面判据**：除解码帧增长/时间前进外，还必须
`screenVideo.drawPasses > 0`、`encodedQuads > 0`、`fragments > 0`（GPU 可见性查询）——
解码统计不再能单独让它通过。

## C. 第三轮后仍如实说的边界

- **App target 的编译仍由主代理出具**：`tools/e2e-app-build.sh` 在 DSH 内被沙箱挡在
  SwiftPM manifest 缓存（同上一轮，退出码 74）。本轮新增的
  `WorldScreenVideoRenderer.swift` / `WorldScreenVideo.metal` 由 `probe-screen-video-render.swift`
  用真 `swiftc` + 真 Metal 编过跑过，但 `MarbleSpatialView` 的完整编译要主代理宿主构建。
- **本机没有把 yt-dlp 装进已装 App**：脚本只在显式 `--app` / `GMGN_BUNDLE_SCREEN_LINK_HELPER=1`
  时写独立测试产物；未碰 `/Applications`。
- §2 的世界权威 metadata 持久化仍按原样（未在本轮改动唯一世界写入者）。

---

## 1. yt-dlp 原生播放（链接优先）— 已恢复并接线

### 1.1 恢复的文件（从被回退的 dangling blob 原样取回）

`Screen/LinkResolver/`：

| 文件 | blob |
|---|---|
| `ScreenLinkContract.swift` | `89a8ab3e` |
| `ScreenLinkRedaction.swift` | `bcbc916f` |
| `BundledHelperManifest.swift` | `97878e79` |
| `YtDlpInvocation.swift` | `f7fe63ce` |
| `YtDlpResultParser.swift` | `6ed1f2b8` |
| `ScreenLinkProcess.swift` | `4f2907bc` |
| `ScreenLinkHelperLocator.swift` | `3b30ad0c` |
| `ScreenLinkResolverService.swift` | `2a9e14a3` |

`Screen/NativeMedia/`：`NativeScreenMediaDescriptor.swift`（`7a0198ee`）、
`ScreenLinkAssetLoader.swift`（`f9b8dcca`）、`NativeLinkPlayer.swift`（`9516c7ec`）、
`WorldScreenNativeVideoRegistry.swift`（`65290162`）、
`NativeScreenPlaybackCoordinator.swift`（`64cc9a0d`）。

取回方式：`git cat-file -p <blob>`（这些对象不可达，`git show <commit>:<path>` 无效）。

### 1.2 接线（生产路径）

- `Screen/WorldScreenContent.swift`：`Kind` 增加 `.nativeLink`；`isValid` 只做机械校验
  （https + 主机），站点白名单交给运行时解析器 —— 于是 `WorldScreenContent` /
  `WorldScreenState` 不依赖解析器目录，离线 harness 仍只切 `Screen/` 就能编。
- `Screen/WorldScreenState.swift`：新增值类型 `NativeLinkFailureInfo` 与
  `WorldScreenFailure.nativeLink(_:)`（人话 / 工程口径两句文案）。
- `Screen/WorldScreenStore.swift`：`playScreen` **链接优先** ——
  `ScreenLinkSitePolicy.accepts(rawContent)` 成立就走
  `NativeScreenPlaybackCoordinator`（yt-dlp 解析 → AVPlayer → Metal 纹理注册表）；
  裸 id / 站方嵌入输入回落官方嵌入。停 / 删 / 换片都把原生会话作废
  （`nativeCoordinator.stop/remove`），过期解析结果不许复活。
- `Screen/NativeMedia/NativeLinkPlayer.swift`：增加**帧泵**（~30 Hz 主动
  `copyFrameTexture()`）。`AVPlayerItemVideoOutput` 只在被索取时才产出像素；渲染器
  接线进来时由渲染器拉，没有渲染器（控制面 / 命令行只看 `decodedFrames`）时这里自己拉，
  保证"解码真的在跑、统计真的在涨"，而不是 item 就绪就报播放中。
- `Screen/WorldScreenPersistence.swift`（新增）：只落盘**原始定义与原始页面 URL**；
  解析器产出的签名媒资地址永远只在内存。
- `App/GMGNRadioApp.swift`：
  - `e2eStatusSnapshot` 暴露角色接地诊断；
  - `e2ePlaybackState` 的每条 `screens[]` 增加 `nativeLink`
    （`decodedFrames` / `gpuCopies` / `pixelWidth/Height` / `currentSeconds` / `itemStatus`），
    驱动器据此判"持续视频帧 / 时间"。

### 1.3 旧门禁范围更新（保留注入负对照）

`tools/test-resident-screen-overlay.swift` 的断言 5：

- `yt-dlp` / `googlevideo` / `--cookies` 等解析器 token **只允许**出现在
  `Screen/LinkResolver/` 与 `Screen/NativeMedia/` 两个受控目录；
- 受控目录之外一律红（`Screen/` 根、App、其它模块）；
- **凭据红线不放松**：`Keychain` / `SecItem` / `kSecClass` / `Authorization: Bearer`
  在受控目录里也命中即红；
- 负对照：① 临时树塞 `yt-dlp --cookies-from-browser` ⇒ 红；② 受控目录里的解析器 token
  ⇒ 放行；③ 同样 token 放到 `Screen/` 根 ⇒ 红；④ 受控目录里塞 `Keychain` ⇒ 红。

### 1.4 本机已跑（可复跑）

```bash
cd /Users/ghostcorn/dev/gmgnradio
swift tools/test-screen-link-behavior.swift      # 解析安全/行为 + 4 条注入负对照
swift tools/probe-native-link-playback.swift     # 分轨/合流 + 换片/停/删作废（真 Metal）
```

结果：两个 harness 均 `exit 0`。行为 harness：原件全过，4 条注入全部红；探针：11 条离线
断言全过。

### 1.6 本轮 DSH 内实际跑过并通过的门禁

| harness | 结果 |
|---|---|
| `test-screen-link-behavior.swift` | exit 0（4 条注入全红） |
| `probe-native-link-playback.swift` | exit 0（11 条断言全过） |
| `test-avatar-grounding.swift` | exit 0（17 断言 + 3 源级 + 注入） |
| `test-e2e-isolation.swift` | exit 0（8 断言 + 注入来源扫描） |
| `test-resident-screen-overlay.swift` | `PASS 电视机判据全部通过`（含新增范围/凭据注入） |
| `test-resident-screen-app-wiring.swift` | exit 0 |
| `test-resident-screen-idle-and-motion.swift` | exit 0 |
| `test-resident-screen-embed-origin.swift` | exit 0 |
| `test-resident-screen-capability.swift` | exit 0 |
| `test-resident-tv-look.swift` | exit 0 |

**App 全量构建在 DSH 内被沙箱挡住**：`tools/e2e-app-build.sh --print-path` 在
`xcodebuild` 解析 SwiftPM 包时，因沙箱拒绝写
`~/Library/Caches/org.swift.swiftpm/manifests/ManifestLoading/*.dia` 而以退出码 74 失败
（`Could not resolve package dependencies`）。按沙箱规则尝试 `danger-full-access` 一次性
升级，但当前会话没有审批通道 ⇒ fail-closed。因此 **App target 的编译门仍由主代理宿主
`make build` / `tools/e2e-app-build.sh` 出具**；DSH 侧用上面的 harness（含真 Metal 的
原生播放探针）做代理验证。

### 1.5 仍未闭合（如实说）— **已被本轮 §A / §B 关闭，保留为当时记录**

- **内置 helper 二进制**：本机没有可内置的 `yt-dlp`（下载需要网络/许可确认），
  `BundledHelperManifest.pinned` 的 sha256 仍为空 ⇒ 生产定位器 fail-closed
  （`helperIntegrityMismatch`），只有显式开发覆盖 `GMGN_SCREEN_LINK_HELPER` 才放行。
  因此**真实链接的端到端播放需要主代理提供一个本机 yt-dlp 路径**（或补齐打包脚本后
  重跑）。这是"不能空 hash 交付"的唯一硬缺口，不能靠 DSH 在沙箱里下载解决。
  → **第三轮已修**：sha256 已钉实测值，打包脚本 `tools/bundle-screen-link-helper.py`
  可下载/校验/内置，见 §B。
- **场景显示**：`WorldScreenNativeVideoRegistry` 是渲染器取帧接缝，但当前 `MarbleSpatialView`
  没有消费它（既有画面走的是 AppKit `WKWebView` 覆盖层）。帧泵保证解码/统计在跑，
  但"视频像素真的画进 3D 场景"仍需要一次渲染器 pass 接线；本轮没有把未验证的渲染
  改动塞进主渲染路径。
  → **第三轮已修**：`WorldScreenVideoRenderer` 真的画进场景并参与深度，见 §A。

---

## 2. 电视来源 / 标定持久化 — 已落地（App 本地文件，显式 root 注入）

`Screen/WorldScreenPersistence.swift`：按 `worldID` 隔离的 JSON，只存屏幕定义（来源 +
标定）与**原始页面 URL**。`WorldScreenStore.Source` 增加
`restoreDefinition` / `restoreContent` / `removePersisted`，App 侧把五个回调接到
`<Application Support>/gmgn radio/ScreenState.json`。

- 重启后 `rebuild()` 用 `restoreDefinition` / `restoreContent` 补回会话缓存；
- 物件从世界消失（`rebuild()` 的清理循环）时删除记录 —— 过期内容不复活不存在的电视；
- **局限**：世界权威的布局命令集（`WorldPropLayoutCommand`）里没有写物件 metadata 的
  命令，`WorldScreenMetadata` 的写入口至今零调用点。要真正走 `world_commit` 需要给
  Rust taskd + Swift `WorldSimulation` 新增一条 metadata 命令；本轮没有在未验证的情况下
  动唯一世界写入者。当前实现是"App 数据根内的持久化缓存"，不是权威第二写者。

---

## 3. 人物动作穿地 — 算法已修

`MMD/PMXStageAvatarRenderer.swift`：

- 新增纯逻辑 `PMXContactGrounding.penetrationOffset(restGlobalMinY:animatedGlobalMinY:)`
  （= rest − animated，非有限值拒绝补偿）；
- `PMXSoleGrounding.makeContactProbes(in:stride:maximumProbeCount:)`：从**全身**蒙皮顶点
  按固定步长抽样（每 8 个取 1，上限 512），捕捉坐 / 跪 / 盘腿时由膝 / 小腿 / 臀决定的
  最低接触点；
- `installModel` 冻结 `contactProbes` / `restGlobalReferenceY`，探针为空时**具名上报**；
- 每帧 `localGroundingOffsetY = max(soleOffset, rootDrop, contactLift)`，其中
  `contactLift = max(0, penetration)` —— 安全地板，只抬升绝不下压，不与 root motion
  的有符号补偿打架；
- 暴露只读诊断 `minimumContactY` / `restGlobalReferenceY` / `contactLiftY` /
  `uncompensatedPenetrationY`，经 `MarbleSpatialView.avatarGroundingDiagnostics` →
  E2E `status.avatarGrounding`。

`tools/test-avatar-grounding.swift`（**本轮加入 `make test-harnesses` 门禁**）：新增
全身接触的纯逻辑断言、"脚抬起、膝下沉"的回归、以及"只取脚"注入负对照 + 每帧接地
计算必须真的引用 `PMXContactGrounding` 的源码级断言。

本机结果：`PASS: 17 avatar grounding checks, 0 failures` + 3 条源级断言全过，`exit 0`。

---

## 4. E2E 隔离（评审逐条）

### 4.1 bootstrap 失败不回落写生产

`App/E2ERuntime.swift`：设了 `GMGN_E2E_DATA_ROOT` 但**不是**专用测试产物，或测试根
建不出来 ⇒ `failClosed()` 写 stderr 后 `exit(78)`（EX_CONFIG）。**绝不**返回 false
让调用方走生产路径。

### 4.2 不依赖 `CFFIXED_USER_HOME`，显式 root 注入

新增非可选访问器 `applicationSupportDirectory` / `cachesDirectory` / `homeDirectory`。
已显式注入的 E2E 关键持久化点（都经 App 组合）：

| 持久化 | 注入 |
|---|---|
| taskd socket/状态根 | `PropTaskDaemonClient(root: injectedTaskDaemonRoot)` |
| 世界预像 + 权威端点 | `LivingWorldBootstrap.makeContext(applicationSupportBase: E2ERuntime.applicationSupportBase)` |
| 许愿档案 | `WishMachineCoordinator(directory: E2ERuntime.applicationSupportBase?/gmgn radio/WishMachine)` |
| 图片附件 | `ResidentAttachmentStore(directory: E2ERuntime.applicationSupportBase?/gmgn radio/ResidentAttachments)` |
| 生成服务配置 | `PropGenerationConfigurationStore(fileURL: injectedPropGenerationConfigURL)` |
| 屏幕定义/内容 | `WorldScreenPersistence(fileURL: E2ERuntime.applicationSupportDirectory()/gmgn radio/ScreenState.json)` |

### 4.3 UserDefaults：每个测试根一个稳定独立 suite

`E2ERuntime.suiteName(forRoot:)` 用 FNV-1a 从测试根路径派生
`ai.gmgn.radio.e2e.<hash>`：同根重启同名（保留），不同根不同名（不串）。每个测试根
**首次**启动时清掉上一轮固定域 `ai.gmgn.radio.e2e` 的遗留键（marker
`<root>/.defaults-suite-initialized`），之后同根重启不再清。

### 4.4 驱动器 `Ledger.blocked` 计数与方法同名

已把计数属性改为 `blocked_count`，`finish()` / 退出码改用 `blocked_count`。
本机验证：`Ledger().blocked("x")` 正常计数，不再 `TypeError`。

### 4.5 prop-config 真实注入（不只是检查）

`tools/e2e-real-app.py`：把 `--prop-config` 指向的真实配置**复制**到
`<root>/Library/Application Support/ai.gmgn.radio/secrets/prop-generation.json`，
`chmod 600`，只记录字节数与相对路径，**不读取、不打印内容**；源路径等于目标路径时拒绝
（拒绝把生产配置当成测试输入）。App 侧读的正是这条注入路径。

### 4.6 本机可复跑

```bash
python3 tools/e2e-real-app.py --help          # 语法/入口
swift tools/test-e2e-isolation.swift          # per-root suite 稳定性 + 注入来源扫描
```

结果：`test-e2e-isolation.swift` `PASS: 8 ... 0 failures` + 注入来源扫描 PASS，`exit 0`。

---

## 5. 驱动器断言（不再"命令成功即通过"）

`tools/e2e-real-app.py` 现在：

- `metal_frames`：≥4 帧、≥2 个不同 sha256、**帧序号严格递增**、抓帧跨真实时间
  （`capturedAt` 跨度 ≥ 0.3s）；
- `video_playback`：等到 `surface == playing` **且** `nativeLink.decodedFrames > 0`；
  间隔 2s 后解码帧数必须增长、播放时间前进 ≥ 0.5s（非直播）；落盘 `contentURL` 必须
  仍等于用户原始页面链接且不含签名标记；
- `inbox_read`：收件箱必须有可验通知（空则 blocked），未读数必须减少 1，重复标记幂等；
- `restart_recovery`：同根重启后已读状态与未读数都必须保持，且"有可验证已读通知"
  （非空跑）；
- `isolation`：对比真实 `~/Library/Application Support/{ai.gmgn.radio,gmgn radio}`
  的运行前后指纹，必须逐字节不变；
- `check_avatar_grounding`（启动后 + 重启后）：`residentPosition` 三维有限，
  `avatarGrounding` 的 `contactLiftY + 0.05 ≥ uncompensatedPenetrationY` 且
  `contactLiftY ≥ 0`。

---

## 6. 主代理建议执行顺序（宿主）

```bash
cd /Users/ghostcorn/dev/gmgnradio
export PATH="/opt/homebrew/bin:$HOME/.cargo/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# 1) 常规构建 + helper 完整性
make build
make verify-helper-manifest

# 2) 机组门禁（本轮新增 4 个：screen-link-behavior / probe-native-link-playback /
#    test-avatar-grounding / test-e2e-isolation）
make test-harnesses

# 3) 独立测试产物（不安装、不启动已装 App）
tools/e2e-app-build.sh --print-path

# 4) 真实 App 端到端（隔离根）
#    - 真实生成服务配置由驱动器复制进测试根（不打印内容）
#    - 真实网站链接原生播放需要一个本机 yt-dlp 路径：
export GMGN_SCREEN_LINK_HELPER="$HOME/.local/bin/yt-dlp"   # 可选：开发覆盖
python3 tools/e2e-real-app.py --app "$(tools/e2e-app-build.sh --print-path)" \
    --prop-config "$HOME/Library/Application Support/ai.gmgn.radio/secrets/prop-generation.json"
```

判定：`make build` / `make test-harnesses` / `verify-helper-manifest` 退出码 0；
`e2e-real-app.py` 退出码 0 = 数据链路全通过；2 = 环境 blocked（必需报告具体原因）；
1 = 真失败。证据：`tmp/e2e-real-app/ledger.json`、`<root>/evidence/{summary.json,frames/*.png}`。

---

## 7. 边界与未闭合（不声明"验收通过"）

- 只有当前 App 构建与运行、关键完整流程和已知缺陷验证都完成，才可声明交付验收通过；
  本轮完成的是**代码修复 + 可复跑门禁 + 驱动器入口**，最终宿主构建与真实 E2E 由主代理执行。
- 未闭合两项见 §1.5（helper 二进制 / 场景像素渲染）。其余项均有本机可复跑的通过证据。
  **第三轮（见文首 §A / §B）已把这两项落成生产代码与脚本**；仍由主代理出具的是 App
  target 的宿主编译，以及用内置 helper + 可播链接复跑真实 E2E。
