# 菜单、入口与设置重整 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 让 Live Cam 成为应用默认入口，并把系统驻留菜单、Live Cam、空间、播放器和系统设置整理成职责清楚的一套导航。

**Architecture:** 使用一个很小的应用入口合同统一 Live Cam、空间、播放器和设置的跳转。系统驻留菜单只放全局入口；Live Cam 提供空间、播放器、聊天、语音和设置五个并列入口；完整舞台内部只保留空间与播放器之间的切换，以及各自当前场景所需的调节项。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Metal、Swift Testing、XcodeGen

---

## 一、现状审计

2026-09-04 已在当前安装版本中逐项检查以下界面：

- 系统驻留菜单包含启动电台、本地音乐、播放暂停、打开/关闭舞台、Live Cam、角色动作、生活活动、歌词视觉、设置、退出桌面背景和退出应用。入口与场景操作混在一起，菜单过长。
- Live Cam 只有聊天和语音两个按钮。进入完整舞台依赖双击，缺少空间、播放器和设置的明确入口。
- 完整舞台右上角用“3D 点阵”表示离开空间，视觉面板里又有“3D 点阵 / 空间舞台”切换。相同跳转出现两次，命名也未体现“播放器”。
- 完整舞台的视觉面板同时展示空间选择、人物位置、字幕、点阵、颗粒大小和 MV，空间调节与播放器调节混在同一个面板。
- 系统设置的“视觉”页再次提供颗粒大小，同时还放置 Marble API Key。颗粒大小与完整舞台重复；长期服务配置和即时画面调节混在同一页。

审计截图保存在本地 `tmp/menu-audit-2026-09-04/`，仅用于本轮核对，不纳入产品资源。

## 二、信息架构结论

### 1. 系统驻留菜单：只做入口

固定顺序：

1. `显示 Live Cam`
2. `进入空间`
3. `打开播放器`
4. 分隔线
5. `设置…`
6. 分隔线
7. `退出 gmgn radio`

从系统驻留菜单移除：启动电台、本地文件选择、播放暂停、关闭舞台、角色动作、生活活动、歌词视觉、退出桌面背景。原有能力继续保留在播放器、空间或对应的场景面板中。

### 2. Live Cam：默认入口和轻量控制台

Live Cam 右侧使用五个同规格图标，按下面顺序排列：

1. 空间：`cube.transparent`
2. 播放器：`music.note`
3. 文字聊天：保留现有图标与行为
4. 语音：保留现有状态和行为
5. 设置：`gearshape.fill`

行为约定：

- 单击人物或画面空白处进入当前空间。拖动窗口、右键/中键旋转和按钮点击不能误触进入空间。
- 空间按钮与单击画面执行同一个入口动作。
- 播放器按钮弹出轻量菜单，菜单包含当前歌曲摘要、上一首、播放/暂停、下一首和 `进入播放器`。打开菜单本身不改变播放状态。
- 没有可播放节目时，上一首和下一首保持禁用；播放/暂停沿用现有可用性规则。
- 设置按钮打开唯一的系统设置窗口。
- 每个图标都要有中文悬浮提示、无障碍标签和稳定标识。

### 3. 完整舞台：空间和播放器是同级模式

- 从 Live Cam 进入完整舞台时，默认请求并显示空间。
- 从系统驻留菜单或 Live Cam 的播放器菜单进入时，先退出空间呈现，再显示播放器。
- 右上角保留一个始终可见的模式切换按钮：当前在空间时显示 `播放器`；当前在播放器时显示 `空间`。
- 现有视觉面板顶部的“舞台模式”与两个模式按钮删除，消除重复入口。
- 当前在空间时，视觉按钮打开空间面板，只显示空间选择、生成入口、人物位置和载入状态。
- 当前在播放器时，视觉按钮打开播放器画面面板，只显示字幕特效、3D 点阵、颗粒大小和 MV 场景。
- 底部播放条继续存在，播放音乐可以作为空间里的环境行为；它不承担空间与播放器之间的导航。

### 4. 系统设置：只保留长期配置

设置页签调整为：`角色 / 音乐 / 空间 / 快捷键 / DJ`。

- 将原“视觉”改名为“空间”。
- “空间”页只保留 Marble 服务说明、API Key 和未来的默认空间配置。
- 从系统设置移除颗粒大小。颗粒大小只在播放器画面面板出现。
- 空间选择、人物位置、字幕、点阵和 MV 都属于当前场景操作，不进入系统设置。
- Live Cam、系统驻留菜单和应用菜单的设置入口都打开同一个窗口。

## 三、方案比较

### 方案 A：统一入口合同，现有窗口继续复用（采用）

增加 `showPlayer()`，让 `showStage()` 继续代表进入空间；所有入口转发到同一组应用动作。改动集中，能消除菜单漂移，也不需要重写窗口层。

### 方案 B：分别修改每个菜单

改动较少，但系统驻留菜单、Live Cam 和完整舞台仍各自维护跳转，后续容易再次出现命名和行为差异。

### 方案 C：重写应用外壳和导航状态机

长期结构更完整，当前只有两个完整舞台模式，投入会超过本轮范围。

## 四、交互示意

```text
应用启动
   ↓
Live Cam ──单击画面/空间──→ 空间 ──播放器──→ 播放器
   │                           ↑                 │
   ├─播放器菜单─进入播放器─────┘                 └─空间─┘
   ├─聊天
   ├─语音
   └─设置──→ 系统设置

系统驻留菜单
   ├─显示 Live Cam
   ├─进入空间
   ├─打开播放器
   ├─设置
   └─退出应用
```

## 五、实施任务

### Task 1: 建立统一入口合同并精简系统驻留菜单

**Files:**

- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:140-271`
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:403-444`
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:828-865`
- Modify: `apps/macos/Tests/GMGNRadioTests/AppMenuActionTests.swift:250-370`

**Step 1: 写失败测试**

- 给 `GMGNApplicationControlling` 和 `AppMenuAction` 增加 `showPlayer`。
- 增加一个纯值类型菜单策略，断言系统驻留菜单的入口顺序严格为 Live Cam、空间、播放器、设置、退出。
- 更新控制器替身，断言 `showPlayer` 只转发一次。

**Step 2: 编译测试代码并确认失败**

Run:

```bash
xcodebuild build-for-testing \
  -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: 新合同尚未实现时出现编译失败。禁止使用 `xcodebuild test` 和 `test-without-building`，这两个命令会启动测试宿主。

**Step 3: 实现最小入口合同**

- `showStage()` 保持“进入空间”语义，继续调用 `spatialStage.requestWorldPresentation()`。
- 新增 `showPlayer()`：准备完整舞台、调用 `spatialStage.exitWorld()`、显示舞台窗口。
- 精简 `MenuBarExtra`，只保留第二节定义的项目和分隔线。
- 设置入口继续复用现有 `SettingsMenuAction`，不要复制设置窗口逻辑。
- 保留旧的播放、动作和活动方法供场景内部调用，只从系统驻留菜单移除。

**Step 4: 重新编译**

Run: 使用 Step 2 的 `build-for-testing` 命令。

Expected: 编译通过。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift \
  apps/macos/Tests/GMGNRadioTests/AppMenuActionTests.swift
git commit -m "refactor: simplify app entry menu"
```

### Task 2: 给 Live Cam 增加五个并列入口

**Files:**

- Modify: `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift`
- Modify: `apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamWindowController.swift`
- Modify: `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:2251-2280`
- Modify: `apps/macos/Tests/GMGNRadioTests/DesktopPresence/LiveCamPanelTests.swift`

**Step 1: 写失败测试**

覆盖以下合同：

- `LiveCamInteractionView` 暴露空间、播放器、聊天、语音、设置五个按钮。
- 五个按钮都有稳定标识和中文无障碍标签。
- 单击画面触发进入空间。
- 单击任意控制按钮不触发进入空间。
- 拖动窗口不触发进入空间。
- 播放器菜单按当前快照设置标题、播放按钮文案和上一首/下一首可用性。
- 设置按钮只调用统一设置入口。

**Step 2: 编译测试代码并确认失败**

Run: Task 1 的 `build-for-testing` 命令。

**Step 3: 实现 Live Cam 控件**

- 为 `LiveCamPanel` 和 `LiveCamWindowController` 增加 `onEnterSpace`、`onOpenPlayer`、`onOpenSettings`、上一首、播放暂停和下一首回调。
- 用小型 `LiveCamPlayerMenuSnapshot` 传入歌曲标题、播放状态和前后切歌可用性，避免 Live Cam 直接依赖播放器内部对象。
- 播放器菜单使用原生 `NSMenu` 锚定在播放器按钮旁。
- 单击入口需要识别点击与拖动的差异，并忽略交互控件区域；替换现有双击入口，避免一次点击后还等待第二次点击。
- 五个按钮保持 30×30，垂直间距保持 6；回复气泡继续避开按钮栏。
- `AppDelegate.configureStage()` 注入现有播放和设置动作，不新增第二套播放状态。

**Step 4: 重新编译**

Run: Task 1 的 `build-for-testing` 命令。

Expected: 编译通过，现有聊天、语音、窗口拖动和相机旋转测试仍可编译。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamPanel.swift \
  apps/macos/Sources/GMGNRadio/DesktopPresence/LiveCamWindowController.swift \
  apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift \
  apps/macos/Tests/GMGNRadioTests/DesktopPresence/LiveCamPanelTests.swift
git commit -m "feat: add Live Cam navigation controls"
```

### Task 3: 统一完整舞台的空间/播放器切换

**Files:**

- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift:320-340`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift:560-640`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift:700-745`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift:1317-1365`
- Modify: `apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift:1901-2145`
- Modify: `apps/macos/Tests/GMGNRadioTests/VisualEngine/StageWindowControllerTests.swift`

**Step 1: 写失败测试**

- 增加纯状态策略：空间状态下切换按钮显示“播放器”并执行 `exitWorld()`；播放器状态下显示“空间”并执行 `requestWorldPresentation()`。
- 断言模式切换按钮在两个状态下都可见。
- 断言视觉面板按模式只展示对应分组。

**Step 2: 编译测试代码并确认失败**

Run: Task 1 的 `build-for-testing` 命令。

**Step 3: 实现模式切换和面板分组**

- 将 `StageReturnToPointCloudButton` 改为双向的 `StageDestinationButton`，沿用现有视觉样式。
- 按 `spatialStage.isWorldPresentationRequested` 更新标题、图标、提示和动作。
- 从 `StageVisualPickerView` 删除“舞台模式”标题和两个模式按钮。
- 空间模式只渲染空间相关分组；播放器模式只渲染字幕、点阵、颗粒和 MV 分组。
- 空间加载期间保持按钮可用，允许用户返回播放器。
- 视觉按钮的无障碍说明随当前模式更新。

**Step 4: 重新编译**

Run: Task 1 的 `build-for-testing` 命令。

Expected: 编译通过。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/VisualEngine/StageWindowController.swift \
  apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift \
  apps/macos/Tests/GMGNRadioTests/VisualEngine/StageWindowControllerTests.swift
git commit -m "refactor: separate space and player controls"
```

### Task 4: 收拢系统设置

**Files:**

- Modify: `apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift:1-170`
- Add or Modify: `apps/macos/Tests/GMGNRadioTests/Settings/GMGNSettingsViewTests.swift`

**Step 1: 写失败测试**

- 抽出可测试的设置页定义。
- 断言页签顺序为角色、音乐、空间、快捷键、DJ。
- 断言系统“空间”页不再包含颗粒大小，只保留 Marble 长期配置。

**Step 2: 编译测试代码并确认失败**

Run: Task 1 的 `build-for-testing` 命令。

**Step 3: 实现设置分层**

- 将 `.visual` 改为 `.space`，标题和说明改成空间服务配置。
- 删除系统设置中的颗粒大小控件。
- `GMGNSettingsView` 不再需要 `visualDirections` 参数；同步更新创建点和相关测试。
- 保留现有本地明文 API Key 存储方式，不改回钥匙串。

**Step 4: 重新编译**

Run: Task 1 的 `build-for-testing` 命令。

Expected: 编译通过。

**Step 5: 提交**

```bash
git add apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift \
  apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift \
  apps/macos/Tests/GMGNRadioTests/Settings
git commit -m "refactor: keep persistent options in system settings"
```

### Task 5: 集成检查和交付

**Files:**

- Verify only: all changed files

**Step 1: 检查工作树边界**

Run:

```bash
git status --short --branch
git diff --check
git diff HEAD~4 --stat
```

Expected: 只包含本计划列出的源码、测试和计划文档；不要改动当前已有的 `artifacts/`、`checkouts/`、`repositories/`、`workspace-state.json`、`roundtrip/`、`backups/`、`dist/`、`tmp/` 和 Python 缓存。

**Step 2: 完整无宿主编译**

Run:

```bash
xcodebuild build-for-testing \
  -project apps/macos/GMGNRadio.xcodeproj \
  -scheme GMGNRadio \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`。不要启动应用、不要安装、不要运行会拉起 `gmgn radio.app` 的测试命令。

**Step 3: 人工验收清单**

留给主会话在用户确认后操作当前安装应用：

- 启动只出现 Live Cam。
- 系统驻留菜单只显示五个入口动作。
- 单击 Live Cam 画面进入空间；拖动不进入。
- Live Cam 五个按钮都可点击，播放器菜单不会自动播放。
- 空间和播放器可以通过右上角按钮往返。
- 两种模式的调节面板互不混杂。
- 设置页签为角色、音乐、空间、快捷键、DJ，颗粒大小只在播放器内出现。
- 聊天、语音、窗口拖动、相机旋转和播放控制未回退。

**Step 4: 报告**

提交哈希、改动文件、编译结果和未执行的宿主测试。任何与本轮无关的失败要单独列出，不要顺手修改。

## 六、本轮边界

- 不重做播放器视觉样式。
- 不增加新的世界规则、角色编排或多人能力。
- 不更改音乐来源、语音供应商、思考模型和 API Key 存储机制。
- 不引入新的导航框架。
- 不处理当前工作树中的其他未跟踪产物。
