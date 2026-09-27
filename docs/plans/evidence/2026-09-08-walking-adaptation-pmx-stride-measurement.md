# PMX 行走自动适配：真实资产测量（walk-loop-pmx VMD × na_2b_0414 PMX）

日期/范围：本 DSH 只读测量安装资产；未修改安装资产/selection，未读取任何聊天/凭据。

## 审查阻断 2 的测量结论（替代未测量的 `.45` 常量）

前次交付把 PMX 行走的 `bonesWalkCompatibility.strideSpeed` 硬编码为 `.45`，且声称“没有可测的 VMD”。
真实机器上有现成安装资产，本证据给出实测值。

- VMD：`~/Library/Application Support/gmgn radio/MotionPackages/gmgn.motion.bones.walk-loop-pmx/gmgn.motion.bones.walk-loop-pmx.vmd`
  （manifest sha256 `4c12642f6b7b4791983a98727bf6d59baf0da4688f0046ca594cbb2c93f7eb19`，manifest 原生无 strideSpeed）。
- 目标 PMX：`PresencePackages/pmx.2b-miss-0414-standard/na_2b_0414.pmx`（标准 MMD 命名骨骼；同包 n/nchl 为同族 rig）。

### 数学限制（如实说明）

VMD 的センター（根）X/Z 每帧全为 0（仅 Y 弹跳，0.032 m 峰峰），即严格的 in-place 循环。
因此**单凭该 VMD 无法唯一恢复“参考全局速度”**——文件中不存在根位移；必须用目标骨骼可观察量标定。

### 方法与数值证据（target-skeleton 标定）

用与运行时一致的形变模型（MMDSceneKit：骨骼 rest frame 恒等、VMD 四元数为父空间 delta、センター 平移键直接作用）
在**真实目标模型骨骼长度**上做纯 FK 探针（43 键 @30fps → 1.4 s 循环），得到每帧足踝相对髋的水平前向位移 r(t) 与踝高。

- 步频：左右踝高曲线最佳反相滞后 21 帧 → 步周期 0.700 s、**85.7 步/分**；身姿垂直弹跳每循环两次、周期一致。
- 足地相位“后移漂移”回归（stance drift，模型单位→世界米按真实模型 1.7 m 归一化，单位尺度 0.080085 m/u）：

| 支撑相窗口 | 后移速度 (m/s) | R² |
|---|---|---|
| 左 1–18 | 0.7652 | 0.997 |
| 左 core 2–16 | 0.7771 | 0.997 |
| 右 23–42 | 0.7333 | 0.993 |
| 右 core 24–41 | 0.7222 | 0.994 |

- **rate=1 时的“着地-植脚速度”最佳估计 0.7495 m/s（范围 0.72–0.78）**；步幅 ≈1.05 m、单步 ≈0.53 m。
- 含义：世界以 ~0.75 m/s 移动该角色、clip 以 rate 1 播放时，支撑脚保持植地；
  这正是 locomotion retimer 消耗的量，与“feet 接地阶段后移速度”方法一致。

复现：`python3 tools/motion/measure_walk_loop_pmx.py`（只读；输出 JSON 摘要）。

## 审查阻断 1：可见性合同修正

`StageLocomotionGait` 原为 internal，却被 public `PMXStageAvatarRenderer` 的
`loadMotion(from:…, locomotion:)` 参数与 `public private(set) var loadedLocomotionGait`
引用 → 完整模块 typecheck 会失败（internal type in public API）。修正：把该值类型声明为 `public`
（含 `public init`、字段与纯函数），渲染器 public 契约不再泄漏 internal 类型。
仅用 `swiftc -parse`/frontend parse 不能视为已编译——本次用全模块 `swiftc -typecheck` 验证。

## 一致的速度策略与 maxRate=1.3 复核

- 把世界行走速度默认 = 实测植脚速度（0.75 m/s，rate 1）：巡航时 rate = 1.0，远低于 cap 1.3，
  **不会长期封顶**；旧 `.45` 若配上 1.2 的漫游速度会令 rate≈1.69 被封顶并滑步。
- cap 1.3 只约束超出 clip 契约的速度（>0.97 m/s）：无 run clip，任何方案在此之上都滑步；
  默认巡航不触发。暂停世界（速度 <0.06 m/s）rate=0 冻结原地、不 reload、相位连续；
  clear 后 locomotion telemetry 置 standing、isLocomotionActive=false。
- 宿主less 测试覆盖：13 组（见 tools/test-walking-adaptation.swift），含 pause/clear 相位连续组。

## 交付改动清单

- `apps/macos/Sources/GMGNRadio/Presence/StageAvatarRuntime.swift`：`StageLocomotionGait` 可见性修正（public）。
- `apps/macos/Sources/GMGNRadio/App/LivingWorldBootstrap.swift`：`bonesWalkCompatibility.strideSpeed` 0.45 → 0.75（实测，注释说明）——唯一允许的 Bootstrap 最小修正。
- 相应测试：`apps/macos/Tests/GMGNRadioTests/App/LivingWorldBootstrapTests.swift`、`tools/test-walking-adaptation.swift`、`tools/test-resident-world-motion-sources.swift`、`tools/test-resident-thinking.swift`（stub 常量同步）。
- `tools/motion/measure_walk_loop_pmx.py`：只读测量工具（证据复现）。

## 给主代理的 renderer 接线变化（不做进本子任务的文件）

PMX full-stage 渲染路径（`MarbleSpatialView.synchronizePMXWorldMotion/loadPMXMotion` + `encode` 每帧）需要：
1. 把 PMX 角色走路时的 gait 传入：
   `renderer.loadMotion(from: url, repeats:…, playbackRate:…, inPlace:…, locomotion: PMXStageAvatarRenderer.locomotionGait(for: motion))`
   （motion 为 `gmgn.motion.bones.walk-loop-pmx` 解析出的 `StageMotionAsset`，经 bootstrap 已带 strideSpeed=0.75）。
2. 每帧把世界遥测喂给 renderer：行走期间
   `renderer.locomotionMeasuredSpeed = avatarRuntime.locomotion.isLocomotionActive ? avatarRuntime.locomotion.measuredSpeed : nil`；
   停止/清除世界时置 nil（否则旧速度会一直参与重定时）。
3. VRM 侧（同为主代理区）：`StageAvatarAnimationLoader.makeLoopingPlayerWithGait(for:model:)` 已在同一 pass 返回
   gait；每帧 `StageAvatarAnimationLoader.applyLocomotion(telemetry:gait:player:)` 即可；`loadedLocomotionGait`
   的公开暴露同时用于桌面 PMX 视图。

主代理最终以完整 xcodebuild + 视觉验收收口。
