# P2 设计：装修可玩性（Sims 式格子摆放）

日期：2026-09-27（修订）
状态：待实施
上游：`docs/plans/2026-09-27-space-first-plan.md` 的 P2
前置：P0（仓库止血）与 P1（默认呈现面）已完成并推送

## 0. 标准

> **要像 The Sims 那样才算 OK。**

具体是这五条，后文全部围绕它们：

1. **进建造模式 → 整个房间浮出格子**，不是几个画好的小方块。
2. **不限件数**。你能放多少由房间和你的耐心决定，不由渲染预算决定。
3. **鼠标直接指着放**：悬停高亮、绿/红判定、吸附到格、一键旋转。
4. **格子被墙和家具正确遮挡**，不是浮在画面最上层。
5. **退出重进，东西还在原处。**

## 1. 问题（已核实）

| # | 卡点 | 证据 |
| --- | --- | --- |
| 1 | 同时只能摆 **4 件** | `WorldSimulation.swift:142`、`:175`；`ResidentPropPlacementService.swift:144`；**另有 2 处静默截断**：`ResidentPropRenderer.swift:53`（`removeLast()`）、`WishMachineOutputDescriptor.swift:49`（`.prefix(4)`） |
| 2 | 只有 **2 个手写摆放面**，写死在这间屋子 | `ResidentPropPlacementConfiguration.swift`：`resident.floor`（0.8 m × 1.0 m）与 `resident.display_table` |
| 3 | 摆放面被哈希锁进导航烘焙门禁 | `build-package.mjs:69` 对该 Swift 文件取 SHA-256 写入 `navigation.source`，`:72` 不匹配即 "Baked navigation is stale" |

**这不是技术限制，是刻意的范围缩小。** 出处：`todos/002-ready-p2-generated-prop-placement.md:29`

> "**先批准一块地面和一张独立展示台**……**至多四件同时摆出**，其他留在物件库。手持、网页、交易和**完整装修不在本批范围**。"

那一批的目的是跑通"生成 → 领取 → 摆放 → 存档"链路。P2 就是那句**完整装修**。

**差距**：房间地面 13.5 m × 23.0 m = **310 m²**；可站立格点 2,421 个 ≈ 605 m²（含桌面、多层）；当前可放 **1.39 m² = 0.23%**。

## 2. 几何事实

| 事实 | 值 | 来源 |
| --- | --- | --- |
| 房间地面范围 | 13.5 m × 23.0 m | `layout.json` → `navigation.report.groundBounds` |
| 可站立格点 | 2,421（0.5 m 间距） | 同上 |
| 碰撞网格 | 161,600 三角形 | `MarbleLivingCabinPackageTests` 实测 |
| 被拒格点 | `capsuleCollision` 104、`meshTraversal` 69、`combinedTraversal` 61、`stepHeight` 15、`supportReservation` 3、`missingGround` 1 | `report.rejectedEdges` |

## 3. 三个决定

### 决定 1：物件阻挡导航（Sims 式），靠已有的运行时重规划实现 —— 不需要重烘焙

Sims 里的家具是**真的挡路**的：Sim 会绕过沙发，你把门堵死他就过不去。所以"像 Sims"就意味着**物件阻挡导航**。

**关键发现：这套机制仓库里已经写好了，只是没接上。**

| 已核实的事实 | 位置 |
| --- | --- |
| 路径规划**已经支持**惰性重规划：在提议路径上做碰撞查询，发现受阻的有向边就加入 `blockedEdges` 并**重新规划** | `WaypointNavigationGraph.route(from:to:canTraverse:)`（:117-211） |
| `ActivityExecutor` **已经持有**碰撞世界，并在逐步移动时校验 `canOccupy` + `canTraverse` | `ActivityExecutor.swift:96`、`:509-515` |
| 但它算路径时调的是**不检查**的那个重载（`canTraverse: { _,_ in true }`） | `ActivityExecutor.swift:229` |
| 物件**已经在**碰撞世界里 | `MarbleLivingCabinCollisionWorld`（`LivingWorldBootstrap.swift:5-16`）组合 `environment` + `props` |

**所以改动很小**：让 `ActivityExecutor` 把由 `collisionQuery` 推出的 `canTraverse` 传进 `route(from:to:canTraverse:)`。已有的惰性重规划立刻生效——**居民会绕过你放的家具，而不是撞上去然后报"受阻"**。

**代价**：无重烘焙，无放置卡顿。每次路径规划多做几次局部碰撞查询，而图的实现已有缓存。

**并且 `supportReservation` 可以直接删除**（设计因此大幅简化，见决定 3）：它今天的作用是"让 waypoint 不要生成在那两个手写摆放面上"。既然物件改为在运行时通过受阻边阻挡通行，就**不需要** waypoint 回避摆放区了。实测代价：`report.rejectedEdges.supportReservation = 3`——删掉只会让烘焙图多出约 3 个点。

**放置时的连通性检查**从"必需"降为"体验优化"（Sims 会提示你堵死了通路）。它可以后做，且不是本期的阻塞项。

### 决定 2：取消件数上限

**不是调大，是取消。** 共 **8 处门禁**需要删除：

**WorldRuntime（数据模型）**
1. `WorldSimulation.swift:142` —— `guard count < 4`
2. `WorldSimulation.swift:175` —— `guard otherVisibleCount < 4`
3. `WorldPropLayout.swift:106` —— `case visibleLimit`
4. `WorldPropLayout.swift:155` —— 对应的用户文案

**App（门禁）**

5. `ResidentPropPlacementService.swift:144` —— `guard placed.count <= 4`
6. `ResidentPropRenderer.swift:53` —— `if nextHeld != nil, next.count == 4 { next.removeLast() }`（**静默截断**）
7. `WishMachineOutputDescriptor.swift:49` —— `.prefix(4)`（**静默截断**）
8. `WishMachineOutputDescriptor.swift:52` —— `result.count < 4`

**并确立一条原则：**

> **渲染预算永远不该变成"你不许放"。**

渲染端按距离与重要性裁剪（近处优先、远处淡出），必要时降级；**绝不因渲染理由拒绝用户的放置**。

### 决定 2b：渲染侧有一个真预算，必须重新设计而不是删除

删掉上面 8 处之后会暴露一个**真实约束**（第 6 处，且它不是门禁）：

```swift
// ResidentPropRenderer.swift:101-103
if cache.count+loads.count >= 5, let evict = cache.keys.sorted().first(where: { !active.contains($0) }) { cache.removeValue(forKey: evict) }
guard cache.count+loads.count < 5 else { throw WishMachineOutputError.renderUnavailable }
```

每个 GLB 道具是**一次完整解析 + 纹理上传**，所以缓存上限是必要的。但现在的策略有两个问题：

1. **上限 5 的来源就是那个 4 件上限**（4 件 + 1 手持）。取消件数上限后，放第 6 件会抛 `renderUnavailable`。
2. **缓存满且全都在视野内时直接抛错**——这正是"渲染预算变成了不许放"。

**重新设计：**

| 项 | 策略 |
| --- | --- |
| 缓存上限 | 提高到可容纳整个房间的合理值（例如 32），不再是 5 |
| 淘汰顺序 | **按到相机的距离**（最远先淘汰），而不是 `cache.keys.sorted().first`（按 key 字典序，语义上无意义） |
| 距离裁剪 | 超过阈值（房间对角线约 27 m，阈值取 30 m 即可覆盖全屋）的道具不绘制，其资产可释放 |
| 预算不足时 | **跳过本帧绘制，绝不抛错**；等有资产被淘汰后自然恢复 |
| 加载并发 | 目前**每个物件一个 `Task`，无全局并发上限**——放 30 件会同时解析 30 个 GLB。需要**有界并发**（例如 2–4）并排队 |

这样"放多少"由用户决定，"同时画多少 / 同时解析多少"由渲染端自己管。

### 决定 3：门禁不再锁摆放面 —— 那个耦合直接消失，而不是被管理

因为决定 1 删除了 `supportReservation`，摆放面**不再是导航烘焙的输入**，所以不需要"改锁什么"的折中方案：

| | 现在 | 改成 |
| --- | --- | --- |
| `supportReservation` | 依据两个手写面预留 0.25 / 0.30 m 净空 | **删除**（实测只影响 3 个候选点） |
| `build-package.mjs` 里的 `propSupportConfigurationSHA256` 门禁 | 对手写摆放面文件取 SHA-256 | **删除该条**（不再有这条依赖） |
| 其余门禁 | `collider.glb` SHA-256、`framing`、`collisionVolumes`、`manualWaypoints` | **保留不变** |

效果：**"改摆放面 → 导航失效"这个问题不存在了**，而不是被绕开。`bake-living-cabin-navigation.py` 里把 `ResidentPropPlacementConfiguration.swift` 编进烘焙模块的那段代码也可以删掉。网格间距因此完全自由（决定见 §5.3）。

## 4. 摆放面为什么必须派生（而不是手写或删掉）

**历史原因（已核实，靠删除解决）**：依赖方向曾经是反的——

```text
手写摆放面 ──是──▶ 导航烘焙的【输入】
                  cabinSupportReservationIntersects 在每个面周围预留 0.25 / 0.30 m 净空，
                  让 waypoint 不生成在摆放区里
```

这就是"改摆放面 → 导航失效"的由来：不是官僚主义，是真实依赖。

**但决定 1 让这个依赖变得多余**：物件改为在运行时通过受阻边阻挡通行，waypoint 就不需要回避摆放区了。所以这条路走的是**删除依赖**（决定 3），而不是"让派生面成为共同真相"。

**那为什么摆放面仍然要派生？** 因为用户需要一个**能看见、能指着放的表面结构**：

- 画格子要有"哪一层、在哪、多大"（§5）
- 判定"放得下吗"要有承托高度与净空（§6.3）
- 物件 footprint 占几格要有一致的格子坐标系（§5.2）

这三件事都只服务放置体验与渲染，**与导航再无关系**。所以派生是一件事，导航是另一件事——两条线解耦了。

## 5. 格子怎么看到（Sims 标准）

### 5.1 现状（已核实）

- **完全没有任何 3D 鼠标拾取**：`MarbleSpatialView.swift`（3,080 行）里只有一个 `hitTest`（:1049），没有 `mouseDragged` / `mouseMoved` / 射线求交。今天的摆放是"在下拉框里选一个命名的面"。
- **但深度缓冲已共用**：`ResidentPropRenderer` 用 `depthAttachment.storeAction = .store` + reversed depth（:130 / :182）。**所以格子画进同一个 pass 就会被墙和家具正确遮挡**——标准第 4 条几乎免费。

### 5.2 设计

| 项 | 设计 |
| --- | --- |
| 出现时机 | **建造模式开关**。生活模式不显示 |
| 画在哪 | 派生出的承托面。**一层一个平面**：地面、桌面、台阶 |
| 怎么画 | 实例化四边形（一格一个 quad），同一深度缓冲 + 深度测试；按距离淡出；贴地抬高约 1 mm 防 z-fighting |
| 颜色 | 🟢 可放 · 🔴 不可放（插墙/家具、越界） · 🟡 悬停格 + 物件 footprint · ⬜ 已被占用 |
| 怎么选 | **光标射线 → 与格子平面求交 → 取最近命中**。纯 CPU，不做 GPU readback。矩阵取自 `StageCameraCoordinator` / `StageUniforms` |
| 吸附 / 旋转 | 位置吸附到格；旋转默认 **90° 步进**，修饰键自由转 |
| 多格占用 | footprint 由物件 `size` 算（0.45 m 物件在 0.25 m 格上占 **2×2**），**整块一起高亮、一起变绿/红** |
| 键盘 | 旋转 / Esc 取消 / Delete 收回 / 撤销（复用已有单槽 undo） |

### 5.3 间距不必与导航相同

| 网格 | 间距 | 理由 |
| --- | --- | --- |
| 导航 | 0.5 m | 只需"角色能站" |
| **摆放** | **0.25 m 起步**（小物件可到 0.1 m） | 需要贴合物件尺寸 |

两者只在**"哪些区域要预留"这个粗粒度问题**上必须一致——而这个问题已经随决定 1 消失了，所以间距完全自由。

### 5.3b 必须做"可达性过滤"，否则格子会铺满屋顶（已用真实数据证实）

列扫描枚举出**每一层承托面**，但烘焙器紧接着还有一步而派生当时漏掉了。烘焙器的注释写着：

> "Visit every actual ground layer; **connectivity decides which layer belongs to the resident's reachable area.**"

真实生活舱实测（161,600 三角形，0.25 m 间距）：

| 指标 | 值 |
| --- | --- |
| 层总数 | **9,737** |
| 有承托面的列 | 4,591（其中 4,535 列是多层） |
| 高度分布 | y≈-1: 1067 · **y≈0: 3231** · y≈1: 694 · y≈2: 864 · **y≈3: 1611** · y≈4: 555 · **y≈5: 1715** |
| 最高层 | **5.31 m**（几何包围盒顶 5.35 m） |
| 站立胶囊可容纳 | 6,763 / 9,737 |

**两个显而易见的过滤都不管用：**

1. `isWalkableSurface` 用 `normal.y * normal.y`——**对朝上/朝下都成立**，区分不了地板与天花板；屋顶外表面甚至是**朝上**的，照样通过。
2. "站立胶囊可容纳"——**顶不住**：屋顶上方没有东西，站在屋顶上完全合法，所以 6,763 层通过，包含 3–5 米那 3,881 层。

**正确做法（对齐烘焙器）**：从种子点（世界 spawn）做**连通性 BFS**，只保留：

- **可达的站立层**（用 `canOccupy` 判定候选 + `canTraverse` 判定相邻列之间的连通 + `maximumStepHeight` 判定同列纵向连通）
- **紧挨可达层上方一个带宽内的层**（`furnitureBandHeight`，默认 1.6 m）——这些是**桌面/家具顶面**：它们自己站不住人（被家具占着），但就在可达地面正上方，是合法摆放面

并输出 `report`（`layersBeforeFilter` / `layersAfterFilter` / `standableLayers` / `reachableLayers` / `furnitureBandLayers` / `seeded`），对齐烘焙器的 `report` 风格。

这条过滤同时解决三件事：屋顶/天花板不再有格子、地面以下（y≈-1）的外侧底面被排除、不连通的孤岛被排除。

### 5.4 连续性

今天编辑器里的 2 个"面"（`ResidentPropEditorSurface`）**正好对应未来的 2 个"层"**。UI 上那个"选面"下拉框不用删，升级为"选层"（地面 / 桌面 / 台阶）：用户习惯不变，只是每层从 0.8 m 小方块变成整片区域。

### 5.5 三方接口（已定，基于工作项 1–3 实际产出的 API）

**格子（工作项 1–2 已产出）**

```swift
PropSupportGrid                                  // spacing / bounds / parameters
  .layers: [PropSupportLayerRef]                 // 扁平、确定性顺序（x → z → layer）
  .layers(at: PropSupportColumn) -> [PropSupportLayer]
  .contains(_ column: PropSupportColumn) -> Bool
  .nearestLayer(to:maximumDistance:) -> PropSupportLayerRef?

PropSupportLayerRef { column: PropSupportColumn; layer: PropSupportLayer }
  .supportHeight / .center                       // 便捷访问
```

**判定（工作项 3 已产出）**

```swift
WorldPlanarFootprint(size:yaw:)                  // .halfExtents / .center(anchoredAt:spacing:) / .columns(...)
PropPlacementEvaluator.evaluate(footprint:height:at:grid:collision:blockingVolumes:placedProps:) -> PropSupportBlockReason?
PropSupportBlockReason                           // 已带 errorDescription（中文，可直接做悬停提示）
WorldPropBoxOverlap.overlaps(...)                // OBB SAT
```

**工作项 7（渲染）**：新增 `PropSupportGridRenderer`，签名照搬 `ResidentPropRenderer.render`：

```swift
func render(commandBuffer:colorTexture:depthTexture:viewProjection:cameraPosition:
            reversedDepth:preservesDepth:grid:hovered:evaluate:) -> Bool
```

- `colorAttachments[0].loadAction = .load`（叠加在 splat 场景之上）
- `depthAttachment` 复用**同一个**深度纹理做深度测试 → **墙体遮挡自动成立**（§5.1）
- 一格一个实例化 quad，`y = supportHeight + 0.001` 防 z-fighting
- 颜色由 `evaluate` 闭包给出的 `PropSupportBlockReason?` 决定（nil = 绿）
- 距离淡出；超出阈值整格不画

**工作项 8（拾取）**：**不需要对三角形求交。**

```swift
// 1) 用 viewProjection 的逆矩阵把光标 NDC 反投影成射线
// 2) 对每个候选层求交：平面为 y = supportHeight，t = (supportHeight - origin.y) / dir.y
// 3) 交点 (x, z) → 用 grid.spacing 取整成 PropSupportColumn → grid.contains 确认
// 4) 多层命中时取最近的 t
```

纯 CPU、纯数学，**可离线单测**（合成 viewProjection + 合成 grid）。

**工作项 9（编辑器）**
- `ResidentPropEditorState` 增加 `hovered: PropSupportLayerRef?` 与 `blockReason: PropSupportBlockReason?`
- 放置命令的 `surfaceID` 从"手写的面 id"改为**层名**（地面 / 桌面 / 台阶），精确格子由位置反推 —— 这样 `WorldState` 保持紧凑，且与今天的 `metadata["gmgn.support-surface.v1"]` 兼容
- `ResidentPropPlacementService` 里"必须落在某个面内 + `abs(y - surface.center.y) < 0.005`"的校验，替换为 `PropPlacementEvaluator` + footprint 检查
- 交互：悬停高亮 → 点击放下、拖动移动、`R`/`,`/`.` 90° 步进旋转、Esc 取消、Delete 收回、Cmd+Z 撤销

## 6. 实施约束（已核实，直接影响可行性）

### 6.1 `canPlace` 是 O(三角形数)，必须做空间分桶

`WorldPropMeshClearance.canPlace(box:supportHeight:triangles:)` 会遍历**传入的全部**三角形。它的文档注释已经写明：

> "Placement-only triangle/box test. **Callers cache the local triangles for authored support regions.**"

若对 2,000 格 × 161,600 三角形直接调用 = **3.2 亿次**检测，不可行。

**解法**：`TriangleMeshCollisionWorld` 内部**已经有** 0.25 m 的三角形空间哈希（`Cell` + `candidateIndices`），但 `triangles` 是 `private`。需要**加一个公开的按范围取三角形的方法**。

> 这个测试还要求 `abs(q.x) < 0.0001 && abs(q.z) < 0.0001`（只支持 yaw 旋转），并且**允许与承托面接触、但拒绝任何穿入物件的三角形**。正好是摆放校验要的语义。

### 6.2 需要一个新的窄协议

```swift
/// 摆放派生需要三角形几何，而 WorldCollisionQuerying 只有胶囊查询。
/// CollisionVolumeWorld 没有三角形，因此不实现它。
public protocol WorldPropSupportQuerying: WorldCollisionQuerying {
    func triangles(in bounds: WorldPlanarBounds) -> [WorldTriangle]
}
```

由 `TriangleMeshCollisionWorld` 与 `ReplaceableCollisionWorld` 实现。`CollisionVolumeWorld` 不实现（摆放派生要求网格几何）。

### 6.3 摆设校验要同时覆盖网格与阻挡体积

`collider.glb` 是环境；但点唱机、许愿机、展示台是**独立的** `WorldCollisionVolume`（`isBlocking: true`）。所以格子判定必须两样都测：

- 网格：`WorldPropMeshClearance.canPlace`
- 体积：盒 vs 盒（**目前无现成实现**，需新增一个 OBB-OBB SAT 辅助，约 30 行）

## 7. 工作分解

| # | 工作 | 位置 | 验收 |
| --- | --- | --- | --- |
| 1 | `WorldPlanarBounds` + `WorldPropSupportQuerying` + 三角形范围查询 | `WorldRuntime` | 单测：范围查询返回的三角形与暴力全量筛选一致 |
| 2 | `PropSupportGrid` 派生：多层枚举 + 确定性 | `WorldRuntime` | 单测：同一几何必产出同一网格；地面/桌面/台阶多层；跨列确定性 |
| 2b | **可达性过滤**：从 spawn 做连通性 BFS，只保留可达站立层 + 其上方 `furnitureBandHeight` 内的家具顶面；输出 `report` | `WorldRuntime` | 真实几何实测：层数从 9,737 显著下降，且**不再有 3–5 米的层**；天花板/孤岛/地面以下被剔除 |
| 3 | 物件 footprint 与放置判定（网格 / 阻挡体积 / 已放物件 / 净空） | `WorldRuntime` | 单测：2×2 footprint 整块判定；重叠被拒；旋转 90° 后 footprint 正确 |
| 4 | **让居民绕过家具**：`ActivityExecutor` 把 `collisionQuery` 推出的 `canTraverse` 传进 `route(from:to:canTraverse:)` | `WorldRuntime` | 单测：路径被物件挡住时改走可行边；无障碍时路径与今天逐点一致 |
| 5 | **删除 `supportReservation` 与摆放面哈希门禁** | `tools/navigation/`、`bake-living-cabin-navigation.py`、`build-package.mjs` | Python 守卫重建成功；烘焙图只多约 3 个点 |
| 5b | **重烘焙一次** `marble-living-cabin`，核对 report | `authoring/` + `Resources/` | `triangleCount 161600`；`waypointCount` / `bidirectionalEdgeCount` 变化有据可查 |
| 6 | 删除 8 处件数门禁（决定 2）+ 重新设计渲染预算（决定 2b：缓存 32、按距离淘汰、超距裁剪、预算不足跳过本帧、加载有界并发） | `WorldSimulation`、`WorldPropLayout`、`ResidentPropPlacementService`、`ResidentPropRenderer`、`WishMachineOutputDescriptor` | 放 30 件全部可见、可存档；无 `renderUnavailable`；既有 12 项 `WorldPropLayout` 测试按新语义更新 |
| 7 | 格子渲染 pass（实例化 quad + 距离淡出 + 深度测试） | `ResidentPropRenderer` 旁 | 视觉验收：被墙遮挡、不闪烁、60 fps |
| 8 | 光标拾取：射线 → 格子平面求交 → 最近命中 | 渲染/相机层 | 悬停高亮跟手；远处格子也能选中 |
| 9 | 编辑器改成"格子 + footprint" | `ResidentPropEditorState/Service` + `View` | 悬停绿/红正确；吸附；90° 旋转；Esc/Delete/撤销 |
| 10 | 回归 | — | `make test-all` 全绿；`make build` 成功 |

**串行**：1 → 2 → 3；4 →（与 5 无依赖）；5 → 5b；6 依赖 2/3；7、8、9 依赖 2/3。
**可并行**：6、以及 4/5 这条"导航解耦"线，与 7/8/9 这条"渲染交互"线互不依赖。

## 8. 验收（Sims 标准逐条）

| # | 标准 | 怎么验 |
| --- | --- | --- |
| 1 | 进建造模式整个房间浮出格子 | 真人看 |
| 2 | 不限件数 | 放 30 件，全部可见、可存档、可再进入 |
| 3 | 鼠标指着放：悬停高亮、绿红判定、吸附、旋转 | **真人手感**（测试不能代替） |
| 4 | 格子被墙/家具正确遮挡 | 真人看；以及深度测试的离线检查 |
| 5 | 退出重进还在原处 | 离线可测（`WorldStatePersistence` 原子 JSON） |
| 附加 | 摆放面与导航**彻底解耦**（依赖已删除） | 门禁里不再有摆放面这一条 |
| 附加 | 居民会绕过家具而不是撞上去 | 离线：路径在受阻边处改道 |
| 附加 | `make test-all` 全绿 | 自动 |

**第 3 条只有真人能判**，明确列为真人验收，不用状态测试顶替。

## 9. 非目标

- 不做任意 GLB 家具系统（点唱机等仍是专用实现）。
- 不做物理仿真（无重力掉落、无堆叠、无碰撞反弹）。
- 不做墙体物件（挂画、壁灯）——Sims 有墙格，本期不做。
- 不做分享 / 导入（那是 P3）。
- 不做多 agent 同场。

## 10. 风险

| 风险 | 缓解 |
| --- | --- |
| `canPlace` 全量遍历导致不可用 | §6.1 的空间分桶必须先做（工作项 1） |
| 删除 `supportReservation` 后烘焙图变化 | 实测只影响 3 个候选点；重烘焙后逐项核对 report |
| `canTraverse` 接进路径规划后路径行为变化 | 单测要求"无障碍时路径与今天逐点一致"，把变化限制在"确实受阻"的情形 |
| 物件把某个活动入口围死 | 本期接受（可在放置时提示）；Sims 同样允许堵死。连通性提示列为体验优化 |
| 格子数量大导致渲染/拾取变慢 | 距离裁剪 + 分块上传；拾取按层过滤 |
| 多高度层（桌面/台阶）语义不清 | 派生输出显式带"层"，UI 选层 |
| 重烘焙产出与既有 `layout.json` 不一致 | 先跑 `test_cabin_navigation_package.py` 的重建比对再动 app 资源 |
| 真人手感无法离线验证 | 明确列为真人验收项 |
