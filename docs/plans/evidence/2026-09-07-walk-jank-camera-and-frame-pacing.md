# 行走全画面卡顿：相机跟随平滑 + 渲染节拍扣绘制耗时

日期：2026-09-07
范围（本 DSH）：VisualEngine/StageCameraCoordinator.swift、SpatialStageStore.swift、
StageRenderSurfaceController.swift、Metal/MarbleSpatialView.swift（camera 推进/统一 viewport），
以及宿主无关测试与 VisualEngine 托管测试。未触碰 Presence/MMD/App/Agent/WorldRuntime/网页。

## 机制结论（沿用前只读诊断 f32c26ac）

1. 行走时 App 在 ~30 Hz 快照里调 `StageCameraCoordinator.followAvatarHorizontally`，
   fullStageUser 下每 tick 直接 `spatialStage.camera.yaw += bearingDelta`。渲染循环
   （60/24/12 fps）读取同一个 camera，于是世界每 ~33 ms 整步旋转一次 → 全画面顿挫。
2. 渲染由 StageRenderSurfaceController 的 Task.sleep 循环驱动：`draw()` 之后 sleep 完整
   1/fps，实际周期 = drawCPU + interval（慢于目标）。
3. 主代理实测（/tmp/gmgn-walk-tick-profile…）：导航 CPU mean 1.1-1.5 ms、切巡游点
   20-29 ms spike——是导航 CPU，非本项；相机与帧调度先处理，导航另行评估。

## 改动

### 1) 相机跟随改为“快照入队 + 渲染帧平滑消化”（同一相机，无第二套 viewport）

- 新增纯类型 `AvatarFollowYawDigester`（StageCameraCoordinator.swift）：
  - 30 Hz 快照的整步 delta 只入队（`enqueue`）；
  - 每个渲染帧 `advance(deltaTime:)` 按指数时间常数 τ=0.03 s 消化一部分并加回共享
    `camera.yaw`（所有 pass——世界/遮挡/角色/物件/道具——继续读同一个 camera，
    不存在单独 avatar 绘制错位）；
  - 总消化量收敛于总入队量（旋转守恒，不回弹、不丢转）；
  - 渲染间隙 ≥0.5 s（loop 暂停/隐藏/遮挡后恢复）直接丢弃积压，避免一帧甩动。
- 新增纯策略 `AvatarFollowUserPolicy`（同文件）：用户 orbit/复位后 suppressionInterval
  =1 s 内不接收新 follow delta——拖拽不打架、释放后不迟到覆盖（只从“之后”的新 delta 恢复）。
- `SpatialStageStore` 持有 follow 状态与两个“用户直接操作相机”挂点：
  - `look(...)`、`resetCamera()` 在操作瞬间 `noteCameraYawInteraction()`（清残差 + 记时间）；
  - `activateFullStage`/`activateLiveCam` 由 coordinator 开关 `setAvatarFollowActive`
    （Live Cam/其他 owner 下既不消化也不入队）；
  - `selectWorld/selectScene/installCameraHome` 整体替换相机时 `cancelAvatarFollowRotation()`。
- `StageCameraCoordinator`：`followAvatarHorizontally` 改为“政策允许才入队”；
  `activateFullStage` 开启 follow，`activateLiveCam` 先关闭并清残差。owner 权限与
  用户相机存取逻辑不变。

### 2) 渲染节拍：按目标时间扣除本帧绘制耗时，落后不忙转补帧

- 新增纯类型 `StageRenderFramePacer`（StageRenderSurfaceController.swift）：
  每帧“开始时间”相对上一帧开始推进一个 interval；idle = 目标 − 上一帧实测绘制耗时；
  绘制超时（draw > interval）下一帧立即开始（机器受限），丢拍不累积、不 burst 补帧。
- `startRenderLoop()` 用 ContinuousClock 实测 draw 前后，按 pacer 决策 sleep/draw；
  保留单 Task 驱动与每次循环顶部读取 mode/isHidden 的暂停/恢复语义；
  quality 切换（fps 变）重建 pacer 锚点；paused/hidden 仍走 applyRenderState 停/起。
- MarbleSpatialRenderer.draw(in:) 在 `stepCamera` 后、任何 view matrix 读取 camera 前
  调用 `spatialStage.advanceAvatarFollowRotation(deltaTime:)`。

## 红绿复现（宿主无关，真实生产声明抽取编译运行）

- 红：实现前 `tools/test-stage-avatar-follow-smoothing.swift` /
  `tools/test-stage-render-frame-pacer.swift` 报“production declaration not found”，exit 1。
- 绿：实现后两者 PASS，exit 0（见下方运行输出）。
  断言覆盖：30 Hz 整步不入相机；每帧只消化一部分且总量守恒；24/60 fps 消化比例；
  长间隙丢弃积压；cancel；非有限输入；用户抑制窗口开/关；
  稳态 cadence=interval（扣绘制耗时）；超帧机器受限无 burst；200 ms 主线程 hiccup
  只产生一个零 idle 帧后重新锁相。

## 托管测试（未在本沙箱执行，供主代理跑）

- 更新 `fullStageCameraSmoothsAvatarFollowWithoutMovingIntoTheWorld`（原
  fullStageCameraPansWith…）：快照后 yaw 不立即跳变、120 帧消化后收敛到同一终值；
- 新增：逐帧部分消化、渲染间隙清积压、orbit 取消残差+窗口内抑制+过后恢复、
  reset 清残差、离开 fullStage 清残差且 Live Cam 不消化、非 fullStage 惰性、
  相机 home 替换清积压。

## 未宿主实测项（需主代理/宿主验收）

1. 本 DSH 沙箱无法写 ~/Library（SwiftPM manifest cache/DerivedData），整包
   xcodebuild 编译与托管测试无法在此执行——已做逐文件 parse + 关键表达式独立编译验证。
   请主代理跑 `xcodebuild -project apps/macos/GMGNRadio.xcodeproj -scheme GMGNRadio
   build-for-testing` 与托管测试（重点 VisualEngine/StageCameraCoordinatorTests）。
2. 真实画面前后对比：实际 walk 时 GPU FPS/帧时间、ProMotion vs 60 显示下
   Task.sleep 与 drawable 发放的实际叠加效果。
3. 真实窗口遮挡/最小化/切 owner 往返时 digester 间隙清积压与循环停/起。
4. Live Cam 24/12 fps quality 切换过渡帧表现。
5. 角色 XZ 根节点是否还以 30 Hz 步进（属行走占用方平滑范围），未做角色帧间插值。

运行输出（本会话）：
```
swift tools/test-stage-avatar-follow-smoothing.swift
PASS: avatar follow yaw is queued at snapshot cadence and digested smoothly across render frames
swift tools/test-stage-render-frame-pacer.swift
PASS: render loop cadence subtracts frame draw time, drops missed beats without busy catch-up
```
