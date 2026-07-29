# GMGN Radio Metal 360° Stage Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在现有 macOS 原生应用中交付一个可运行、可拖拽、自动环绕并响应音频的白蓝色 Metal 3D 舞台。

**Architecture:** 使用独立的 `StageCameraModel` 管理交互和惯性，`MetalStageView` 与 `StageRenderer` 管理 Metal 生命周期，`StageWindowController` 管理可关闭舞台窗口。现有 `VisualAudioFeatureStore` 直接向渲染器提供低中高频特征。

**Tech Stack:** Swift 6、AppKit、SwiftUI、MetalKit、Metal Shading Language、simd、Swift Testing、XcodeGen。

---

### Task 1: 360°相机模型

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/StageCameraModel.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/VisualEngine/StageCameraModelTests.swift`

**Step 1: Write the failing tests**

覆盖自动环绕、拖拽角度、俯仰限制和惯性衰减。

**Step 2: Run test to verify it fails**

Run:

```bash
xcodebuild test -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS' \
  -only-testing:GMGNRadioTests
```

Expected: 编译失败，提示找不到 `StageCameraModel`。

**Step 3: Implement the minimal model**

模型公开 `beginDrag()`、`drag(delta:)`、`endDrag()` 和 `step(deltaTime:)`，输出 `StageCameraFrame`。

**Step 4: Run tests**

Expected: 新增相机测试通过。

### Task 2: 粒子场景数据

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/StageParticleGeometry.swift`
- Create: `apps/macos/Tests/GMGNRadioTests/VisualEngine/StageParticleGeometryTests.swift`

**Step 1: Write the failing tests**

验证同一固定种子生成完全相同的顶点、各语义区域均有粒子、包围盒可见且数量受预算限制。

**Step 2: Run the tests and observe RED**

Expected: 找不到 `StageParticleGeometry`。

**Step 3: Implement deterministic geometry**

生成头部椭球、肩部曲面、耳机圆环、唱盘圆环、能量轨道和远景尘埃。

**Step 4: Run tests**

Expected: 几何测试通过。

### Task 3: Metal 渲染器

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/MetalStageView.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/StageRenderer.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Metal/StageUniforms.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/Shaders/Stage.metal`
- Modify: `apps/macos/project.yml`

**Step 1: Add uniform contract tests**

验证相机帧和音频特征能生成范围正确的 Metal uniform。

**Step 2: Observe RED**

Expected: 找不到 `StageUniforms`。

**Step 3: Implement background and particle passes**

配置深度缓冲、透明混合、透视矩阵和两个管线；背景为高对比白蓝空间，粒子主体按真实 3D 相机旋转。

**Step 4: Generate Xcode project and run tests**

Expected: 着色器编译成功，合同测试通过。

### Task 4: 舞台窗口与菜单入口

**Files:**
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift`
- Create: `apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift`
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift`

**Step 1: Add lifecycle tests**

验证重复打开复用同一个窗口，关闭窗口后控制器可以重新创建舞台。

**Step 2: Observe RED**

Expected: 找不到舞台窗口控制器。

**Step 3: Implement window and menu**

增加“打开 360°舞台”和“关闭 360°舞台”，舞台窗口支持拖拽相机和关闭，不改变呼吸球生命周期。

**Step 4: Run tests**

Expected: 生命周期测试与全量测试通过。

### Task 5: Visual verification

**Files:**
- Modify: `docs/design/visual-baselines/README.md`

**Step 1: Build**

Run:

```bash
xcodebuild build -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio -destination 'platform=macOS'
```

Expected: `BUILD SUCCEEDED`。

**Step 2: Launch**

Run built `gmgn radio.app`, open the stage from the menu, and capture a screenshot.

**Step 3: Inspect**

确认白蓝对比度、主体轮廓、窗口尺寸、自动环绕、拖拽和关闭行为。

**Step 4: Run the complete test suite**

Expected: `TEST SUCCEEDED`。

**Step 5: Commit**

```bash
git add apps/macos docs/plans docs/design
git commit -m "feat: add native 360 degree Metal stage"
```

