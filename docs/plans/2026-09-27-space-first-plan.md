# 3D Space 成为主体：阶段 1 执行计划（2026-09-27）

日期：2026-09-27
状态：待用户确认后执行
基线：分支 `codex/agent-living-world-e2e`，HEAD `3376c55`（2026-09-08）
本计划不启动宿主、不触发系统授权、不消费真实生成额度。

## 0. 目标与非目标

**本阶段唯一目标：拿到市场接受程度的真实信号。**

不是把工程做漂亮，不是把架构做干净，不是跨平台。判断标准是：

> 一个没用过的人，能不能自己把空间装修起来、觉得好玩、并且愿意第二天再打开。

**本阶段不做**：跨平台（含换引擎）、多 agent 同场、出租/开放策略、身份层长期记忆、订阅/支付。

**已定方向（不在本阶段执行）**：
- 引擎问题推后，先走 macOS/Metal（理由见 §7）。
- 播放器降级为官方插件，3D space 为主体。
- 阶段 2 = 开放策略 + 出租；阶段 3 = 多 agent / 游乐场。

## 1. 阶段划分

| 阶段 | 内容 | 预估 | 交付判断 |
| --- | --- | --- | --- |
| **P0** | 仓库止血：`.gitignore` + 分批提交 + tag | 0.5 天 | 干净基线，可回滚 |
| **P1** | 定位：默认界面只呈现空间 | 1–2 天 | 给朋友看时它像"AI 生活空间"，不像播放器 |
| **P2** | 装修可玩性（1a） | 1–2 周 | 陌生人 5 分钟能自己摆 10 件并觉得好玩 |
| **P3** | 分发与做客（1b） | 1–2 周 | 10 个人能互相逛，收到反馈 |
| **P4** | 结构债（**市场反馈之后再定**） | 待定 | — |

P1 只做"看得见的定位"，**不做模块拆分**。真正把电台搬成 `RadioPlugin` 属于 P4：它服务长期健康，不服务市场验证。

## P0 仓库止血

### 现状（已核实）

- `git status` = **251 untracked + 82 modified**，最后提交 2026-09-08，之后 19 天工作全未提交。
- **45 个 app 源文件（14,363 行）从未进入任何 commit**，含整个 DSH / Claude / 记忆 / 视觉 / 道具工具层。
- 单作者（`neeboo`，122 commits），无协作者冲突风险。
- `Package.resolved` **已**在版本控制中，因此忽略 `Packages/*` 缓存不影响可复现构建。

### 工作项

1. **补 `.gitignore`**（在提交之前）：

   ```text
   apps/macos/Packages/checkouts/
   apps/macos/Packages/repositories/
   apps/macos/Packages/artifacts/
   apps/macos/Packages/workspace-state.json
   tmp/
   backups/
   dist/
   .sessions/
   .pytest_cache/
   __pycache__/
   *.blend1
   ```

   挡住约 707 MB（checkouts 136 M + artifacts 152 M + repositories 419 M）与 `tmp/` 391 M。

2. **分批提交**（语义化，conventional commits）。建议顺序与批次：

   | 批次 | 内容 | 说明 |
   | --- | --- | --- |
   | 1 | `.gitignore` | 必须最先，否则后续 `git add` 会带进缓存 |
   | 2 | `Packages/WorldRuntime`（含 `PropCapability` / `WorldPropLayout` / 新增测试） | 纯逻辑，143 项测试可立即验证 |
   | 3 | `services/gmgn-taskd` | Rust，独立可验证 |
   | 4 | 世界数据：`world.json` + `layout.json` + `wish-machine.json` | **`wish-machine.json` 必须一起提交**，否则包校验失败 |
   | 5 | `Agent/`（后端传输、工具桥、记忆） | 行数最大的一批 |
   | 6 | `Presence/`（道具、许愿机、视觉、动作库） | |
   | 7 | `VisualEngine/` + `DesktopPresence/` + `Settings/` + `App/` | 含 `AppDelegate` 与 `StageOverlayView` |
   | 8 | `tools/` + `apps/macos/Tests/` | 含 124 个 harness |
   | 9 | `docs/`（含 `evidence/` 32 个未跟踪文件） | |
   | 10 | 修复陈旧验证资产（见下） | 单独一批，让修复可见 |

3. **打 tag `pre-space-first`**。

4. **提交后立即修 3 个已坏资产**（单独提交，不混进上面）：

   | 资产 | 问题 |
   | --- | --- |
   | `tools/test-living-resident-loop.swift` | 编译失败 14 处（`residentUnconfirmedNotice` / `presentResidentLoopFailure` / `refreshResidentBackendGuidance` 已不存在，`autoRevealsChat` 签名已变） |
   | `tools/marble/tests/test_cabin_prop_render.py` | 2 项失败（`MarbleSpatialView` 重构后抽取失效） |
   | `contracts/*.schema.json` | 零代码校验且已与实现漂移（工具名仅 `search_music` 一个交集） |

   `contracts/` 建议**删除或移到 `docs/legacy/`**，不要留在仓库根暗示它有效。

5. **加 `make test-all`**，把已有但没入口的强测试接进默认路径：

   ```make
   test-all: test-install
   swift test --package-path apps/macos/Packages/WorldRuntime   # 143 项
   cd services/gmgn-taskd && cargo test --locked                # 70 项
   python3 -m unittest discover -s tools/navigation -p 'test_*.py'
   python3 -m unittest discover -s tools/blender/tests -p 'test_*.py'
   python3 -m unittest discover -s tools/motion/tests -p 'test_*.py'
   ```

### 验收

- `git status` 只剩预期的未跟踪项（无 `checkouts/`、`tmp/` 等）。
- `git log` 批次清晰；`pre-space-first` tag 存在。
- `make test-all` 全绿（WorldRuntime 143 / Rust 70 / installer 32 / Python 除已标注的 2 项外全绿）。
- `make build` 退出 0，`project.pbxproj` 与 `make generate` 幂等（已核实当前幂等）。

### 非目标

- 不清理 `Build/`（4.1 G，已被忽略）。
- 不重写历史、不 `git reset`、不 force push。
- 不修任何功能问题，只止血。

### 风险

- **提交前需要你过一遍批次清单**：如果某些未提交改动是你不想要的实验，先告诉我，我在分批时不纳入。
- `apps/macos/Packages/artifacts` 被忽略后，干净 clone 首次构建需要重新下载 xcframework（约 152 M），属预期。

## P1 定位：默认界面只呈现空间

**目的**：给朋友看的时候，它看起来是"能给 agent 住的地方"，不是"又一个播放器"。只改默认呈现，不删代码。

### 现状（已核实）

- 仓库最大文件 `VisualEngine/StageOverlayView.swift` **3,914 行**，其中 **≈2,600 行（67%）是播放器 UI**：歌词家族（`StageLyricsView` + 12 个 `*LyricsFrame`，:547–2262）与节目单（`StageProgramRail*`，:2982–3875）。
- 空间自己的 UI 只有 **375 行**（`StageResidentChatState` / `ResidentSpeechErrorNotice` / `WishMachineTaskStatusView` / `StageResidentComposer`，:6–375）。
- 菜单栏条目（`SystemResidentMenuPolicy`）含 `openPlayer`。
- 电台相关模块：`DJCore` 1,062 + `VoiceSession` 2,135 + `MusicKnowledge` 962 + `DJAgentToolDispatcher` 1,242。

### 工作项

1. 默认呈现面收窄为：**菜单栏 + LiveCam（空间视图）+ 设置**。
2. 播放器呈现收进开关（保留代码，默认关闭）：歌词舞台、节目单、电台控制面板、`openPlayer` 菜单项。
3. **光球（`OrbWindowController`）默认不显示**——它是播放器的身体，随播放器一起进插件。（此条为产品决定，见 §8 待确认项 1。）
4. 设置窗口的页面顺序调整为空间优先；音乐账号页保留（空间需要音乐源，见 §9 陷阱）。
5. 定位文案：对外名称与首屏说明中不出现"电台/播放器"。

### 验收

- 冷启动后默认可见的界面元素只有：菜单栏图标、空间视图、设置。
- 无播放入口时，空间全部 6 个活动仍可执行，**含 `music.listen` 与点唱机交互**。
- `make build` 退出 0；`StageOverlayView` 未删除任何代码（仅入口开关）。

### 非目标

- 不做模块拆分、不建 `RadioPlugin` target。
- 不删 `DJCore` / `VoiceSession` / 歌词布局代码。

## P2 装修可玩性（1a）

**目的**：让"装修"这件事真的成立。这是阶段 1 的核心，也是市场验证的主体。

### 现状（已核实，三个硬卡点）

1. **同时只能摆 4 件**：`WorldSimulation.swift:142` 与 `:175` 两处 `guard count < 4 else { throw WorldPropLayoutError.visibleLimit }`。
2. **只有 2 个手写摆放面**，且写死在这间屋子：`ResidentPropPlacementConfiguration.swift` 的 `resident.floor`（中心 `(-2.6,-0.03,-3)`，半尺寸 `(0.4,0,0.5)` = **0.8 m × 1.0 m**）与 `resident.display_table`。注释自陈 "verified against this cabin's shipped collider"。
3. **摆放面被哈希锁进导航烘焙门禁**：`authoring/worlds/marble-living-cabin/build-package.mjs:69` 对 `ResidentPropPlacementConfiguration.swift` 取 SHA-256 写入 `navigation.source`，:72 不匹配即抛 "Baked navigation is stale"。**即：改摆放面 → 导航包失效。**

### 关键发现（降低本阶段成本）

`tools/navigation/LivingCabinNavigation.swift` 的烘焙器**已经在算同一件事**：`surfaceCandidates` 2,421、`blockedCandidates` 729、`supportReservedCandidates`、`cabinSupportReservationIntersects`。"哪块地面能站人"与"哪块地面能放东西"是同一计算，判定条件不同。它现在只喂给导航，没用来生成摆放面。

**所以 P2 是把已有几何计算结果，从"只修导航"扩展成"同时产出摆放面"**——纯客户端 + 纯几何，不需要 GPU、不需要生成。

### 工作项

1. **摆放面派生**（放 `WorldRuntime`，保持 Foundation-only，可单测）
   - 复用 capsule-grid 烘焙，产出 **prop support grid**：可放置格子 + 承托高度 + 净空要求。
   - 替换 `ResidentPropPlacementConfiguration` 的手写 `surfaces`。
   - 判定条件与导航不同处：净空高度、承托面、以及是否需要 `supportReservation` 通行净空。
2. **解除摆放面与导航哈希的耦合**
   - 门禁改为只锁**输入**：`collider.glb` SHA-256、`framing`、`collisionVolumes`、`manualWaypoints`、烘焙参数。
   - 不再锁"输出"（手写的摆放面文件），因为它将不再是手写常量。
   - **需要重新烘焙一次**现有 `marble-living-cabin`，并核对 `report` 字段（`triangleCount` 161,600 / `waypointCount` 631 / `bidirectionalEdgeCount` 2285 应保持一致或有意变化）。
3. **提高可见上限**：4 → 先设 20，压测后调整。
   - 涉及：`WorldSimulation` 两处 guard、`objectStates` 渲染路径（`ResidentPropRenderer` / `MarbleSpatialView`）、`supportReservation` 范围。
   - `objectStates` 已是字典，主要是渲染与几何的承受能力。
4. **编辑器手感**（`ResidentPropEditorView` 现 121 行 + `ResidentPropEditorState` 224 + `ResidentPropPlacementService` 213 = 558 行）
   - 从"选面 + 坐标"改为：网格选点 → 拖放 → 旋转 → 吸附 → 撤销。
   - 复用已有的 `WorldPropLayout` 8 命令事务层（幂等 receipt、单槽 undo、`WorldPropMeshClearance.canPlace` SAT 检测），不新造事务模型。
5. **新增测试**（在已有 143 项之上）
   - 派生摆放面：确定性与碰撞一致性；同一碰撞几何必须产出同一网格。
   - 上限提升后的幂等、undo、并发拒绝行为不回归。
   - `WorldPropLayout` 既有 12 项测试必须继续通过。

### 验收

- 一个没玩过的人，**5 分钟内自己摆 10 件物件**，无需指导。
- 摆放过程中 60 fps 不塌（`FrameRateSampler` 已有 p95 统计）。
- 摆完退出重进，摆放与朝向完整保留（`WorldStatePersistence` 原子 JSON）。
- 改摆放面**不再**导致导航失效。
- `swift test --package-path apps/macos/Packages/WorldRuntime` 全绿（≥143 + 新增）。
- 真实鼠标手感需要**你或真人**确认，离线测试不代替。

### 非目标

- 不做分享/导入。
- 不做任意 GLB 家具系统（点唱机等仍是专用实现）。
- 不做物理仿真（不做重力掉落、不做堆叠）。

### 风险

- 提高上限可能撞渲染性能：先做 20 的压测，不达标就回到 10，不硬上。
- 摆放面派生会改变 `layout.json` 的 `navigation.source`：需要一次完整重烘焙并核对 report，否则会静默产出不一致的导航。

## P3 分发与做客（1b）

**目的**：让"我可以访问某人的地盘，让我的 agent 进去玩一下"成立，从而拿到多个人的真实反馈。

### 已核实的三个事实

1. **空间态与 agent 态在数据模型里已经天然分离**（`WorldState`）：空间侧 `layoutRevision` / `layoutReceipts` / `layoutUndo` / `weather` / `liveCamera` / `objectStates`；agent 侧 `agentTransform` / `activeActivity` / `heldProp` / `completedGoals`。
2. **但加载入口只认 bundled 包**：`LivingWorldBootstrap.loadBundledCanary` 用 `bundle.resourceURL`。
   好消息：`WorldPackageValidator.resourceFindings(in:packageRoot:)` **本来就是按任意 packageRoot 设计的**，只是入口没打开。
3. **居民身份目前是世界的属性**：`AgentConversationService.sessionScope` 由 `selectedWorldID` 推导；`ResidentStateScope = (worldID, residentScope)` 两维均由世界派生。

### 工作项

1. **空间态/agent 态显式化**
   - 把 `WorldState` 的隐式切分变成显式类型：`WorldSpaceSnapshot`（可分享）+ `WorldAgentState`（本地）。
   - 导出 = `world.json` + resources + `WorldSpaceSnapshot`。
2. **只读导入**
   - 打开非 bundled 包加载路径（`packageRoot` 参数化）。
   - `WorldPackageValidator` 扩展到外来包全流程。
   - **加固（必须与导入同时上线，不能后补）**：包体积上限、资源解码防御（`GLBColliderDecoder` / spz / PMX / VRM 均会吃外来文件）、路径逃逸（已有）、SHA-256 完整性（已有）。
   - **只读**：访客不能编辑他人空间。
3. **居民进去玩**
   - 保持自己的 `scopeID`，替换 `worldID`（绑定层已支持：`ResidentWorldToolSession` 已是 `(scopeID, worldID)` 且已有跨世界隔离守卫）。
   - 只读会话：可看、可走、可交互，不可摆放。
   - **访问摘要留在本地，不进长期记忆**——身份层是阶段 2 的事。
4. **反馈收集**
   - waitlist 记录**设备分布（Mac / Windows）**，为将来的跨平台决策提供数据。
   - 记录"第二天是否还想打开"。

### 验收

- 两个人互相导入对方空间，各自的 agent 能进去走动与交互，双方状态互不串写、互不覆盖。
- 恶意/畸形包被拒绝且不崩溃（含超大包、截断 GLB、非法 spz）。
- 导入后退出重进，访客本地空间不受影响。
- 收集到 ≥10 个真人的反馈与设备分布。

### 非目标

- 不做开放策略/权限（阶段 2）。
- 不做身份层长期记忆。
- 不做多 agent 同场。
- 不做出租/支付。
- 不做实时联网访问（本阶段是"包"，不是"服务"）。

## P4 结构债（市场反馈之后再定）

不在本阶段执行，列在这里是为了明确**它们被有意推迟**：

1. 电台模块化：`RadioPlugin`（`DJCore` 1,062 + `VoiceSession` 2,135 + `MusicKnowledge` 962 + DJ 的 18 工具 1,242 + 歌词舞台 ~1,716 + 节目单 ~894）。
2. `AppDelegate` 拆分（5,488 行 / 179 方法 / 110 存储属性）。
3. 渲染器协议化 + 引擎 spike（见 §7）。
4. `make test` 的 `TEST_HOST` 问题（78 个 XCTest 文件实际不运行）。

## 5. 全局纪律（现在就生效，成本为零）

1. **`WorldRuntime` 保持 Foundation-only**：不许 import Metal / AppKit / SceneKit。它现在是干净的，守住即可。
2. **渲染器藏在协议后面**：业务只依赖协议，不直接碰 `MarbleSpatialView`。
3. **新业务逻辑不许进 `AppDelegate`**。
4. 每次改动跑：`make build` + `swift test --package-path WorldRuntime` + `cargo test` + 相关 `tools/test-*.swift`。
5. 沿用现有边界：**不自动启动宿主、不操作窗口、不触发系统授权、不消费真实生成额度**。

## 6. 逐阶段风险与停止信号

| 阶段 | 风险 | 停止信号 |
| --- | --- | --- |
| P0 | 提交了不想要的实验改动 | 分批清单未经你确认前不执行 |
| P1 | 收得太狠导致空间可用性下降 | `music.listen` 或点唱机失效 → 立即回滚该项 |
| P2 | 上限提升撞性能 | p95 帧率不达标 → 回到 10，不带病上线 |
| P2 | 重烘焙导致导航与摆放不一致 | report 字段异常 → 停止，先对齐再继续 |
| P3 | 第三方资产解码是新攻击面 | 任何畸形包导致崩溃 → 停止分发，先加固 |
| 全局 | 又回到"先做架构不做验证" | 若 P2 两周内没有真人摆过 10 件，暂停 P4 讨论，先解决这个 |

## 7. 已定的两个方向性结论（记录理由，避免重复讨论）

**引擎：先走 macOS/Metal，不改。**

- 阶段 1（装修）不碰渲染器：摆放面与上限都在 `WorldRuntime`（5,306 行，Foundation-only）。Apple 绑定的只有 `ResidentPropEditorView` 121 行。
- 跨平台要扔掉的恰是唯一不能复用的那层：3DGS + SceneKit + MMD 蒙皮 33,224 行；而贵的那半本来就跨平台（Rust daemon 17,038、NanoemCore 14,616 C、生成管线）。
- 换引擎只在三个信号出现时重估：需要组队；需要跨平台访客端且访客端要渲染 3DGS；内容管线成瓶颈。
- 若评估，只做 1–2 周 spike（用真实 `scene-500k.spz` + `collider.glb` + 一个 PMX/VRM 角色 + 透明置顶窗口），不迁项目。Unity 过 1–4 卡在 5；Bevy 卡在 3DGS 与 MMD。

**播放器：降级为官方插件，不删除。**

- 保留 `MusicSources` 3,738 + `AudioEngine` 1,991 + 居民那 5 个音乐工具 + `music.listen` + 点唱机。
- 搬走：DJ 人格、节目编排、实时语音 DJ、歌词舞台、节目单。
- 接口契约的雏形已经在代码里：`ResidentMusicToolBridge` 的白名单（5/18）与注释 "Playback still belongs to the room's activity"。

## 8. 待确认项

1. **光球默认是否隐藏？** 它是播放器的身体，但它也是"桌面存在感"的原点。当前计划：默认隐藏，随播放器进插件。
2. **是否为自由摆放重新烘焙 `marble-living-cabin`？** 需要一次完整重烘焙并核对 report。
3. **P0 提交前是否有不想保留的实验性改动？**（需你过一遍分批清单）
4. **部署目标是否下调？** 当前 `MACOSX_DEPLOYMENT_TARGET = 26.0`，第一方代码中未发现 macOS 26 专属 API。下调可显著扩大可用人群，零重写。（建议排入 P1）

## 9. 已核实的陷阱（不要踩）

**空间需要音乐。** 空间的 6 个活动里有 `music.listen`，空间资源里有 `prop.jukebox`。按字面"砍掉播放器"会让 agent 走到点唱机前无事发生。要砍的是**电台产品**，必须保留**音乐能力**。
