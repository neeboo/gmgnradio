# 电视机：`App/GMGNRadioApp.swift` 的粘贴补丁（**未落盘**）

`App/GMGNRadioApp.swift` 在本轮开工时 mtime 为 **0 分钟**（点唱机线正在改），
`Agent/ResidentActivityOutcome.swift` 同时为 1 分钟。按纪律：**只给可粘贴补丁，先不落**。

补丁一共 4 处，全部是**新增**，不改任何既有行。基线 `6168747`。

---

## 补丁 1 / 4：持有电视接线（`GMGNRadioApp` 的存储属性）

锚点（第 770 行附近）：

```swift
    private var stageWindowController: StageWindowController?
```

紧跟其后粘贴：

```swift
    /// 电视机：覆盖层 + 面板 + agent 工具共用的一份接线。
    ///
    /// 世界那一侧（读 `objectStates`、持久化）从外面注入，所以这一份不知道
    /// `WorldSimulation` / 权威的存在 —— 见 `Screen/WorldScreenStore.swift` 的 `Source`。
    private var screenStore: WorldScreenStore?
```

## 补丁 2 / 4：装覆盖层与面板（舞台窗口第一次建起来的地方）

锚点（第 1151 行附近，`if stageWindowController == nil {` 那个分支里，
`stageWindowController = StageWindowController(...)` 之后）：

```swift
                self?.stageWindowController?.show()
```

紧跟其后粘贴：

```swift
                self?.installScreenOverlayIfNeeded()
```

并在 `GMGNRadioApp` 里新增这个方法：

```swift
    /// 把电视覆盖层接到舞台窗口上。**只接一次**。
    ///
    /// 这里刻意不做的事：
    /// - 不往 `consumesScenePointer` 加任何输入（覆盖层容器 `hitTest` 恒 nil，不吃指针）；
    /// - 不改渲染管线（画面是 native `WKWebView` 覆盖层，不是 Metal 纹理）；
    /// - 不改世界状态（读写都经注入的闭包，见补丁 4）。
    private func installScreenOverlayIfNeeded() {
        guard screenStore == nil, let controller = stageWindowController,
              let host = controller.screenOverlayHostView else { return }
        let overlay = WorldScreenOverlayController(hostView: host)
        let store = WorldScreenStore(
            spatialStage: spatialStage,
            overlay: overlay,
            source: WorldScreenStore.Source(
                objectStates: { [weak self] in
                    self?.livingWorldContext?.state.objectStates ?? [:]
                },
                displayName: { [weak self] objectID in
                    // 显示名的唯一来源与摆画面板一致：生成道具的 displayName，
                    // 没有就用 objectID（绝不编一个名字）。
                    self?.livingWorldContext?.state.objectStates[objectID]?
                        .generatedProp?.displayName ?? objectID
                },
                // 持久化：本轮**留空**（见文末「没做的部分」）。为 nil 时标定与换片
                // 只在本会话内生效，面板上照实显示。
                persistDefinition: nil,
                persistContent: nil
            ),
            projectionProvider: { [weak self] in
                guard let self else {
                    return WorldScreenProjection(
                        camera: WorldScreenCamera(), profile: .fullStage,
                        viewportSize: SIMD2(1, 1)
                    )
                }
                let size = self.stageWindowController?.screenOverlayHostView?.bounds.size ?? .zero
                return WorldScreenProjection(
                    camera: WorldScreenCamera(
                        position: self.spatialStage.camera.position,
                        yaw: self.spatialStage.camera.yaw,
                        pitch: self.spatialStage.camera.pitch
                    ),
                    profile: .fullStage,
                    viewportSize: SIMD2(Float(size.width), Float(size.height))
                )
            }
        )
        store.startTracking()
        controller.installScreenPanel(store)
        controller.setScreenPanelVisible(true)
        screenStore = store
    }
```

## 补丁 3 / 4：agent 工具（`makeResidentWorldTools`）

锚点（第 5546 行附近）：

```swift
        // This lease authorizes only registered world, loop and music-library tools for this turn.
```

在它**之前**粘贴：

```swift
        // 电视机：三条工具（play_screen / stop_screen / read_screen）。
        // 与点唱机同一条纪律 —— 只说"放个视频"而没给链接是**信息不足**，
        // 走成功通道（`insufficient_input`，`isError: false`），不是失败。
        // 适配层只有下面这一处：把 `WorldScreenToolReply` 折成 `RealtimeDJToolResult`。
        let screenTools: [ResidentWorldToolSession.AdditionalTool] =
            screenStore.map { store in
                ResidentScreenTools(control: store, isCurrent: isCurrent).tools.map { tool in
                    ResidentWorldToolSession.AdditionalTool(
                        name: tool.name, description: tool.description,
                        inputSchema: tool.inputSchema, validate: { _ in true },
                        handle: { id, arguments in
                            let reply = await tool.handle(id, arguments)
                            return RealtimeDJToolResult(
                                callID: id, resultJSON: reply.payloadJSON,
                                isError: reply.isError
                            )
                        }
                    )
                }
            } ?? []
```

锚点（第 5591 行附近，`additionalTools:` 那一行）：

```swift
            additionalTools: additionalTools + musicTools.tools + visionTools + wishTools + referenceTools + propTools,
```

改成：

```swift
            additionalTools: additionalTools + musicTools.tools + visionTools + wishTools + referenceTools + propTools + screenTools,
```

## 补丁 4 / 4（可选）：菜单里开关电视面板

`StageControlPanel` 那一套菜单项（`装修空间` 的邻位）里加一项：

```swift
                Button("电视") { stageWindowController?.setScreenPanelVisible(true) }
```

---

## 没做的部分（**明确写出来**，不是遗漏）

1. **标定/换片的持久化**：`persistDefinition` / `persistContent` 传的是 `nil`，
   所以标定与换片**只在本会话内生效**。要落盘必须走**唯一写者**那条路
   （`WorldSimulation` 的世界状态变更 → `AuthorityWorldStatePersistence.save(state:)`，
   即 `WorldAuthorityClient.commit`），而 `WorldRuntime/**` 这一轮是**另一条线**
   （存档自愈 + 网格噪音）正在改的目录 ⇒ 按"优先落在新文件 + 你独享的区域"的纪律，
   这一处留给下一轮。落点很小：`WorldScreenStore.Source` 的两个闭包，
   实现体是"`writeScreenDefinition`/`writeScreenContent` 改内存投影 + 走既有 commit"。
2. **在屏幕上点击/滚动**：不做，且**故意**不做 —— 见设计 §5.3 与
   `WorldScreenOverlayContainer` 的注释（14 条 `场景输入链[N]` 是红线）。
3. **逐像素遮挡**：不做，只做背向剔除 + 近似退让（设计 §2.3）。
