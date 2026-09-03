# Live Cam 桌面形态统一实施计划

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**目标：** 呼吸球与 Live Cam 成为唯一两种桌面形态；选择角色后显示跟随角色的局部 Live Cam，玩家可环绕旋转，双击进入完整空间。

**架构：** 保留唯一的 `MarbleSpatialView` 和角色渲染器，在 Live Cam 下切换为仅角色渲染，完整舞台下恢复空间与角色共同渲染。桌面形态由角色选择统一决定，旧桌宠窗口不再创建 PMX/VRM 视图。Live Cam 使用独立的角色跟随轨道参数，不污染完整舞台的玩家相机。

**技术栈：** Swift 6、AppKit、MetalKit、Swift Testing、现有 Marble/VRM/PMX 渲染链。

---

### 任务 1：固定桌面形态与 Live Cam 相机合同

**文件：**
- 新增：`apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPresentation.swift`
- 新增：`apps/macos/Tests/GMGNRadioTests/DesktopPresence/LiveCamPresentationTests.swift`

1. 先写失败测试：无角色映射到呼吸球，任何角色格式映射到 Live Cam。
2. 先写失败测试：角色跟随相机保留玩家的水平/俯仰角，角色移动时相机同步平移，俯仰角受限。
3. 实现最小纯模型并执行无宿主验证。

### 任务 2：移除旧桌宠角色分支

**文件：**
- 修改：`apps/macos/Sources/GMGNRadio/DesktopPresence/OrbWindowController.swift`
- 修改：`apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`

1. `OrbWindowController` 只负责呼吸球，不再创建 PMX/VRM 桌面视图。
2. 应用层观察角色选择：无角色显示呼吸球，有角色显示 Live Cam。
3. 模式切换时确保两个窗口不会同时可见。

### 任务 3：Live Cam 只渲染角色局部

**文件：**
- 修改：`apps/macos/Sources/GMGNRadio/VisualEngine/StageRenderSurfaceController.swift`
- 修改：`apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MarbleSpatialView.swift`

1. 增加完整空间和角色局部两种渲染内容模式。
2. 角色局部模式清理透明背景、跳过 SPZ 和天气，只绘制角色及已接入的活动内容。
3. 保留一个活动渲染循环；窗口被遮挡、隐藏或进入完整舞台时暂停 Live Cam。

### 任务 4：接入玩家旋转与往返状态

**文件：**
- 修改：`apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift`
- 修改：`apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamWindowController.swift`

1. 在开口内拖动时更新 Live Cam 水平角和俯仰角。
2. 双击仍进入完整空间，不能被拖动手势抢占。
3. 完整空间关闭后恢复 Live Cam 的环绕角度和角色跟随状态。

### 任务 5：验证端到端路径

1. 执行纯模型测试与相关无宿主回归。
2. 使用 `build-for-testing` 完整编译，禁止启动测试宿主。
3. 启动应用验证：角色选择显示 Live Cam、呼吸球选择显示呼吸球、拖动旋转、活动动作同步、双击往返完整空间。
4. 记录帧率策略：默认 30 帧、0.75 渲染比例、遮挡暂停，确认 Live Cam 不加载/绘制 SPZ。
