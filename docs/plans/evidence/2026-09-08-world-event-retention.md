# 世界事件保留：30Hz 时间事件的有界保留证据

日期：2026-09-08。状态：WorldRuntime 单包实现并离线验证通过；未运行整包 App 构建/测试宿主，未启动宿主。对应 [生活空间路线图]（../2026-09-05-living-space-roadmap.md）阶段 0 第 97 行的长驻增长风险与阶段 2 的 30 分钟居民验收，只实现最小有界事件保留，不扩展通用事件总线、不改数据库、不改状态存档格式。

## 一、问题与消费方索引审计

问题：`WorldSimulation.record` 对每一次 `advance`/`catchUp` 都追加一条 `.timeAdvanced`/`.timeCaughtUp` 事件。生产代码在生活空间装载后 `context.startTicking()` 以 30 Hz 连续推进（`WorldAgentContext.tick` → `simulation.advance`），因此即使居民静止，内存事件数组也以 30 Hz 无限增长（约 10.8 万条/小时），这正是路线图长期驻留风险所描述的增长曲线。

改前逐一读取消费者确认索引依赖：

- `WorldAgentContext.publishObservations`（约 1100-1118 行）用绝对整数游标 `publishedEventCount..<simulation.events.count` 直接按下标遍历 `simulation.events`，游标推进到 `count` 后永不回退；若 `count < publishedEventCount`（前缀裁剪后）`Range` 下界大于上界会运行时崩溃。因此 `events` 数组必须保持**只追加、下标稳定**；前缀裁剪或原位重编号必须先同步该消费方。
- `WorldAgentContext.publishObservations` 在投递前已过滤 `.timeAdvanced/.timeCaughtUp/.agentTransformUpdated/.liveCameraChanged`；`ResidentWorldObservation.event` 对这四类返回 nil。时间事件不产生任何观察。
- 但 `WorldAgentToolDispatcherTests`（约 227-230 行）断言 `context.events.contains` `.agentTransformUpdated`，即姿态更新事件仍被现有消费测试读取，**不能**与时间事件一并裁剪。
- `ResidentAgentLoop` 按 `world:scope:world:sequence` 的 id 去重并自行封顶（默认 24）；`WorldAgentContext.events` 只是 `simulation.events` 的透传；存档只保存 `WorldState`，不含事件。

结论：最小有界保留 = 时钟事件不入库（它们不产生观察、只占内存），其余事件保持只追加入库；事件序号改为全局单调水位，任何未来裁剪/恢复都不会回到 0。

## 二、实现改动（独占范围）

### `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldSimulation.swift`

1. `record(_:)`：
   - 事件 `sequence` 与 `revision` 一律取 `state.revision`（每次记录的突变水位）。序号不再由 `events.last.sequence + 1 ?? 0` 推导，因此与数组内容解耦：跨恢复、跨长时间时钟流、以及未来任何前缀裁剪都不会让序号回到 0；水位来自持久化的 `state.revision`，天然全局单调。
   - 仅当 `!isDisposableClockEvent(kind)` 时把事件追加进 `events`。`.timeAdvanced/.timeCaughtUp` 仍然返回给调用方（API 形状不变、revision 照常递增、`catchUp` 一次性结算语义不变），只是不入内存库。
2. `isDisposableClockEvent`：只把 `.timeAdvanced/.timeCaughtUp` 判为可丢弃时钟事件；保留 `.worldLoaded/.worldRestored/.weatherChanged/.agentTransformUpdated/.liveCameraChanged/` 全部活动/移动/布局/目标事件。代码注释写明三处分类（此处、`WorldAgentContext.publishObservations`、`ResidentWorldObservation`）需保持同步，以及不要再次把时钟流加回入库集合。
3. `init(restoring:)`：恢复标记事件 `sequence` 从 0 改为 `state.revision`（= 存档水位），后续记录从该水位之上继续编号。
4. 在 `events` 属性与 `record` 处文档化不变量：库只追加、下标稳定（观察游标契约）；不要把 30 Hz 时钟流重新入库。

未改任何其它文件。咖啡能力/使用状态/布局回执、`layoutRevision`/`layoutReceipts`、活动执行、导航、存档编解码全部原样。

## 三、测试执行（全部离线，无真实等待）

命令均在 `/Users/ghostcorn/dev/gmgnradio/apps/macos/Packages/WorldRuntime` 执行 `swift test --disable-sandbox`（环境不允许 SwiftPM 嵌套沙箱，使用 `--disable-sandbox` 后构建/测试正常）：

```
Test run with 140 tests in 0 suites passed
```

- 原 `WorldSimulationTests` 仅按新契约调整 3 处断言（时间事件不入库、catchUp 不增库、活动生命周期事件序列去掉三条 `.timeAdvanced`），其余断言未动；140 项全部通过。
- 新增 `Tests/WorldRuntimeTests/WorldEventRetentionTests.swift` 3 项全过：
  1. 45 模拟分钟 30 Hz 纯时钟推进（81,000 tick）：revision 正确递增到 81,000、返回的时钟回执序号严格单调，但保留库始终只有 1 条装载事实。
  2. 长时钟流中穿插全部正式结果（姿态、相机、天气、活动开始/中断/恢复/失败、目标、移动成功/失败），最后再空转 20 模拟分钟：保留库恰好等于这些正式事件、不含任何时钟事件、序号单调且等于水位。
  3. 存档（revision 达 10,000）→ 恢复：恢复标记序号 = 存档水位；再空转 5,400 tick 库不增长；恢复后的第一条正式事件序号 = 水位 + 5,400 + 1，证明序号跨恢复续走而非回到 0。
- 回归 `tools/test-resident-world-observations.swift`：`PASS: 36 world observation checks, 0 failures`（改前后一致，观察游标、重入、活动/失败观察、迟接观察者均不受影响）。
- 新增纯离线长时工具 `tools/test-resident-world-retention-longrun.swift`：`PASS: 25 resident retention checks, 0 failures; retained events 5, ticks 135001`。它编译真实生产运行时的 `WorldAgentContext` + `ResidentAgentLoop` + `ResidentWorldObservation` 并链接重建后的 WorldRuntime 目标文件，用真实 `marble-living-cabin/world.json`：
  - 60 模拟分钟静止居民 30 Hz（108,000 tick）：保留库恒为 1，时钟事件零入库，观察投递只有一次初始装载事实，居民循环不触发任何模型调用；
  - 之后天气/目标改动与真实执行器失败（`home.walk` 无地板被阻挡 → `activity_failed`）仍能到达居民观察；
  - 再空转 15 模拟分钟（27,000 tick）：保留库冻结不增长；全场景 135,001 tick 只保留 5 条正式事实；
  - 存档契约：提前/事后 `WorldState` 顶层键集合一致、无 `events` 字段泄漏、save → load → save 字节稳定、revision 与长时运行一致。

## 四、保留项核对

- 咖啡能力状态、`recordPropUsage` 停止语义、布局回执与 `layoutRevision`：未触碰，相关 WorldRuntime 测试（WorldPropCapability/WorldPropLayout）随 140 项全过。
- 79 条消息确认、许愿持久队列、DSH 工具边界：位于 `WorldAgentContext`/`ResidentAgentLoop`/`GMGNRadioApp` 等未改动文件层，本改动不涉及。
- 观察游标、重入、正式活动/失败结果可达性：由上述观察工具 36 项与长时工具 25 项直接覆盖。
- 状态存档字节稳定与 schema 不变：包内持久化测试与长时工具存档断言均通过。

## 五、未验证项与协调补丁建议（报告主代理）

1. GMGNRadio 的 Xcode 单元测试目标与整包 App 构建本轮未运行（需要完整 `xcodebuild`，且为保护共享脏工作树不并行重编译）；`WorldSimulation` 公开签名未变，改前已确认 GMGNRadio 测试仅依赖正式事件入库与 `.agentTransformUpdated` 保留，二者均保持。
2. 残余增长：正式结果与 `.agentTransformUpdated` 仍按真实活动入库（居民实际走动时约每 tick 一条），其量随活动而非随 30 Hz 时钟；对阶段 0/2 的 30 分钟验收而言有界（长时工具中静止期零增长、活动期冻结尾部）。若后续要把它也硬性封顶（前缀裁剪），不能只在 WorldRuntime 内做：`WorldAgentContext.publishObservations` 的绝对计数游标必须同步，建议补丁为——WorldSimulation 暴露 `retainedPrefixCount`（或等价 firstRetainedIndex），`WorldAgentContext` 用 `publishedEventCount - retainedOffset` 换算真实数组下标、并把游标推进为逻辑总数；裁剪只允许移除已经发布的前缀（`index < retainedOffset` 永远不再被读），且需保留 `worldLoaded/worldRestored` 或把“迟接观察者重放起点”改为从保留窗口头开始，避免 `cursor..<count` 在裁剪后下界超过上界崩溃。此补丁涉及本工作独占范围之外的文件，按约定只报告、由主代理协调后再实施。

---

# 第二轮（同文件追加）：单调 sequence 游标 + 固定容量事件窗口证据

日期：2026-09-08（同日第二轮）。用户已明确：正式持久事件由 App/Rust 侧接线（DSH 负责 Rust），内存缓存不是永久经历；本独占范围 = `WorldAgentContext.swift` 的 `publishObservations` 游标区 + `WorldSimulation.swift` 事件缓存 + 相应测试，CC 不动该文件，本工作不改其它咖啡/导航实现、不写 SQLite、不跑 App/真实 DB。

## 一、问题与裁决

第一轮把 30 Hz 时钟事件挡在库外，但居民真实走动时每个 tick 仍追加一条 `.agentTransformUpdated`（活动执行器同样产生姿态更新），只要走动就长期增长 —— 不能称缓存有界。第一轮第五节建议的“前缀裁剪需把 `WorldAgentContext` 绝对计数游标同步换成逻辑序号”正是本轮的授权落地范围：

- `WorldAgentContext.publishObservations` 的 `publishedEventCount..<events.count` 是绝对数组下标：前缀裁剪后 Range 下界会超过上界（运行时崩溃）或静默错位；且裁剪会把“还没投递给消费者的正式事实”丢掉而不自知。二者都必须解决。
- 方案：WorldSimulation 保留**固定容量窗口**（含会话标记，标记永不裁剪），事件仍带单调不重置的 `sequence`（== mutation watermark）；WorldAgentContext 把游标换成 **sequence 游标**；窗口裁剪通过公开单调水位 `trimmedNewestSequence` **显式可检测**；消费者落后超过缓存时，由 publishObservations 给出**明确重新观察边界**而不是把残缺历史伪装成完整历史。快照与真实动作回执不受裁剪影响。

## 二、实现改动（独占范围）

### `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldSimulation.swift`（事件缓存区）

1. `public static let retainedEventCapacity = 64`：窗口上限（**含**会话标记，故最多保留 63 条非标记事件）。容量远大于正常消费下一次 drain 之间的保留产量（走动每 tick ≤ 1 条、正式突变每调用 ≤ 数条、宿主每 tick drain），因此每 tick 正常消费永远不会因裁剪丢失活动/失败/布局事实；同时把“连续走动”的保留量硬性封顶。
2. `events` 语义改为有界窗口：`events[0]` 恒为会话标记（`.worldLoaded`/`.worldRestored`），其后是最新的保留事件。溢出时只从**非标记**最旧端裁剪（`appendRetained`：append 后 `count > capacity` 则 `remove(at: 1)` 并更新水位）。**撤销了上一轮的“数组下标稳定、只追加”契约**，注释写明：游标必须走 sequence，不能记绝对下标。
3. 新增 `public private(set) var trimmedNewestSequence: UInt64?`：被裁剪事件中最新的 sequence，单调；`nil` 表示尚无裁剪。消费者游标 `c` 可用 `c < trimmedNewestSequence` 判断“存在我没读到的保留事件已被裁掉”——这是唯一能区分真实裁剪与时钟占号（时钟事件消耗 sequence 但不保留）的可检测缺口；会话标记不计入。
4. `record` 只把事件交给 `appendRetained`，序列生成逻辑与时钟不入库分类不变；真实动作回执仍是 API 返回值，裁剪不影响已返回的回执。

### `apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift`（publishObservations 游标区）

1. 删除 `publishedEventCount: Int`，新增 `publishedSequence: UInt64?`（nil = 尚未扫描过任何保留事件）。每次 drain：从保留窗口取 `sequence > publishedSequence` 的事件（nil 时取整个窗口）；扫描覆盖被过滤的 `.agentTransformUpdated/.liveCameraChanged` 等（游标照常推进，不重扫）。
2. **缺口检测**：`missedRetained = trimmedNewestSequence.map { (publishedSequence ?? 0) < $0 } ?? false`。检测到时**不再假装连续历史**：
   - 若游标从未扫描（nil），跳过窗口头部的陈旧会话标记（它前接的是不完整流），改为先交付一条显式重新观察边界；
   - 若游标已有值，同样先交付边界，再交付 `sequence > cursor` 的存活尾部。
   - 边界 = 复用 `.worldRestored(worldID:)` 的**重观察语义**（`ResidentWorldObservation` 已把它映射为“请查询当前状态再继续安排活动”），不是伪造活动/失败事实；它不进 simulation 事件库。
   - 边界的 `sequence` 从保留高位带 `UInt64.max &- 1` 递减铸造（`resyncSequence`），**不与真实事件 id 冲突**：真实事件 id = `world:<scope>:<worldID>:<sequence>`，而真实 sequence 是从 0 每记录 +1 的水位，永达不到 UInt64 顶端，resident 循环按 id 去重不会吞掉边界也不会误吞后续真实事件。
3. 游标仍在回调前推进（保留重入安全：观察者可同步再改世界），过滤集合与 `ResidentWorldObservation` 保持同步不变。
4. `events` 透传注释改为有界窗口说明（供测试/内省，投递走 sequence 游标）。

## 三、测试执行（全部离线）

命令：`cd apps/macos/Packages/WorldRuntime && swift test --disable-sandbox`：

```
Test run with 143 tests in 0 suites passed
```

- 原 140 项全过（含上一轮 3 项保留测试：纯时钟不增长、正式结果环时钟流、恢复续走水位）。
- `Tests/WorldRuntimeTests/WorldEventRetentionTests.swift` 新增 3 项全过：
  1. **连续移动有上限**：2048 次连续姿态更新（等价数十分钟真实走动）——窗口恒 = 容量 64、标记头不裁、窗口 = 最新 63 条后缀、`trimmedNewestSequence` 恰好是“最新被裁事件”的 sequence、回执严格单调且 = 水位；走动后的真实 `movementCompleted` 落在窗口尾部。
  2. **时钟噪声下缺口可检测**：每条姿态前插入一个 30 Hz 时钟 tick（sequence 跳号 2,4,6…），窗口仍 = 容量；裁剪水位不被时钟跳号污染；滞后游标 `4 < trimmedNewest` 判定为缺口、跟到最新游标判定无缺口——可检测缺口 ≠ 时钟占号。
  3. **恢复**：revision 10000 存档恢复 → 再走动超过容量：恢复标记头不裁、窗口 = 容量、watermark 算术精确（`loadedState.revision + 2*steps`）、恢复后第一条正式事件 sequence = 水位 + 2*steps + 1，证明跨恢复 + 跨裁剪都不回到 0。
- 新增独立观察工具 `tools/test-resident-world-retention-window.swift`（**只编译生产 `WorldAgentContext` + 重建的 WorldRuntime 目标文件**，不依赖 ResidentAgentLoop/MemoryStore，用真实 `marble-living-cabin/world.json`）：

```
PASS: 48 resident window checks, 0 failures; walk ticks 940
```

  - 附着观察者空转 30 模拟分钟：保留窗口恒 1、首批只有装载事实、revision 照算；
  - 长时后的天气/目标/真实执行器失败（`home.walk` 无地板 → `activity_failed`）仍可达；
  - **真实连续长走**（940 tick、速度 0.5，走到最远可达点）：窗口钉在容量 64、装载标记仍在头部、`movementCompleted` 是窗口尾部且已投递、**没有**伪造任何重观察边界、走动后天气事实仍达、走完空转 5 分钟窗口不变；
  - **消费者落后超缓存**：未附着长走（>容量，`trimmedNewestSequence != nil`）后挂载观察者 → 首批第一件是显式 `.worldRestored` 重观察边界、不含陈旧 `.worldLoaded`（不伪装完整历史）、同批仍收到近期真实移动结果与新天气事实、边界恰好一次、**边界 sequence 不与任何真实事件重复且高于当前水位**；
  - 重入（回调内同步 `completeGoal`：游标先推进、无重复序号）、迟接（无裁剪时迟到观察者仍收到初始装载事实）、恢复（restore 标记头 + 走动超容量仍钉容量 + 越水位续走）；
  - 存档契约：save → load → save 字节稳定、schema 键集合与改动前一致、无 `events` 泄漏。
- 原长时工具 `tools/test-resident-world-retention-longrun.swift` 已补阶段 4/5（附着真实长走钉容量、未附着滞后→重同步边界），**本轮无法编译运行**：见第五节依赖报告。其内嵌 harness 已单独 `swiftc -parse` 验证语法。

## 四、保留项核对

- 快照不经事件缓存（直接读 `state`），真实动作回执是 API 返回值 —— 裁剪对二者无影响（窗口工具与包测试直接覆盖）。
- 咖啡能力状态/使用回执/布局回执、`recordPropUsage` 停止语义、导航实现：未触碰（143 项含 WorldPropCapability/WorldPropLayout/Navigation 全过）。
- 不写 SQLite、不改存档 schema、事件不入档：存档字节稳定性断言全过；正式持久化事件由 App/Rust 侧接线，内存缓存语义为“可检测有界窗口 + 明确重观察”，不是永久经历。
- CC 文件（`ResidentAgentLoop.swift`/`ResidentMemoryStore.swift`/`ResidentStateClient.swift`）未改动。

## 五、协调依赖报告（报告主代理，按约定不改 CC 文件）

1. `ResidentAgentLoop.swift` 现引用 CC 半写/在写的 `ResidentMemoryStore`（`bindMemory`/`save`/`restore`）与 `ResidentStateClient.swift` 的 `ResidentStateScope`；这两个独立观察工具（`test-resident-world-retention-longrun.swift`、`test-resident-world-observations.swift`）的编译集只含 Agent 子集，不含这些 CC 文件，因此报 `cannot find type 'ResidentMemoryStore'/'ResidentStateScope' in scope`（本轮基线之前可通过：彼时 ResidentAgentLoop 尚无 memory 绑定）。待 CC 的统一状态合同/记忆文件合入并稳定后，这两个工具即可编译运行（阶段 4/5 断言已就位、语法已验证）。
2. GMGNRadio 的 Xcode 单元测试目标与整包 App 构建仍未运行（需完整 `xcodebuild`，保护共享脏工作树不并行重编译）。`WorldSimulation`/`WorldAgentContext` 公开签名未变：`events` 仍为 `[WorldEvent]`、`onEventsPublished` 形状不变；现读 `context.events` 的测试（含 `.agentTransformUpdated` contains 断言）在小日志场景下不受窗口影响。

---

# 第三小轮（同文件追加）：去掉伪造 worldRestored 的缺口通知 —— 独立 observation_gap 事件证据

日期：2026-09-08（同日第三小轮）。主代理裁定：第二轮把"消费者落后于固定容量窗口"的可检测缺口伪装成 `.worldRestored` 边界（`ResidentWorldObservation` 会向居民说"生活空间已恢复"），而世界并未 restore——这是把假事实送进居民持久经历；且边界 sequence 从 `UInt64.max` 向下递减，违反世界事件单调含义。本小轮独占范围不变：`WorldSimulation.swift` 事件缓存区、`WorldAgentContext.swift` 的 `publishObservations`、`WorldEvent.swift` 必要新增 case、`ResidentWorldObservation.swift` 事件转换与对应测试/证据；CC 文件未动，其他协作者在 App/loop/vision/Rust。

## 一、问题与裁决

第二轮实现里，滞后缺口边界 = 一条带 `.worldRestored(worldID:)` kind、sequence 取 `UInt64.max &- 1` 递减铸造（`resyncSequence` 保留带）的合成事件。问题：

1. **伪造事实**：世界没有恢复，`ResidentWorldObservation` 却把该 kind 映射为 `world_restored` / "生活空间已恢复，请查询当前状态再继续安排活动"，居民（及其持久经历层）会把它当成一次真实的"世界已恢复"边界。
2. **违反单调语义**：合成 sequence 位于 `UInt64` 顶端的递减保留带；世界事件 sequence 是全生命周期单调水位（== revision），高位递减号段既不单调也不在真实水位域内，且占用 `UInt64.max` 保留号。

主代理裁决的最小正确实现：使用**明确命名、不宣称世界恢复**的观察缺口通知（`observation_gap`/reobserve_required 语义），用与 `world:<scope>:<worldID>:<sequence>` 不冲突的 dedupe id，不伪装事实进持久经历；必要的 `WorldEvent` 新增 case 与 switch 适配限制在必要文件，禁止广泛重构。优先保证现有 `ResidentWorldObservation` 投递链原样收到该通知（App/loop 接线不改）。

## 二、实现改动（独占范围，apply_patch）

### `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldEvent.swift`

新增枚举 case（带文档说明它只是宿主投递通知、从不被 simulation 记录、由 `publishObservations` 发出）：

```swift
case observationGap(worldID: String)
```

### `apps/macos/Packages/WorldRuntime/Sources/WorldRuntime/WorldSimulation.swift`（事件缓存区）

`isDisposableClockEvent` 补上 `.observationGap` 分支（`return true`，即永不入库），并加注释：simulation 从不 record 该 kind，此分支只为穷尽 switch 与显式不变式——若它被错误路由进 `record` 也不得进入世界事件库。其余缓存逻辑、64 容量、裁剪水位、恢复标记全部未动。

### `apps/macos/Sources/GMGNRadio/Agent/WorldAgentContext.swift`（publishObservations 游标区）

1. 删除 `resyncSequence = UInt64.max` 与 `nextResyncSequence()` 递减铸造（保留带整体移除）。
2. `missedRetained` 时插入的显式边界改为：

```swift
WorldEvent(sequence: trimmed, revision: state.revision,
           worldTime: state.worldTime, kind: .observationGap(worldID: state.worldID))
```

其中 `trimmed = simulation.trimmedNewestSequence`（真实裁剪水位：某条被淘汰事件实际携带的 sequence）。语义：边界不再宣称世界恢复；sequence 锚定真实单调裁剪水位（在活动水位域内、无保留号段）；注释写明其居民身份由 mapper 独立命名空间，永不与 `world:<scope>:<worldID>:<sequence>` 冲突，且从不进 simulation 日志。游标推进仍在回调前（缺口路径重入安全保持）。

### `apps/macos/Sources/GMGNRadio/Agent/ResidentWorldObservation.swift`（事件转换）

1. `.observationGap` 映射为居民 kind **`observation_gap`**，摘要明确"观察存在缺口、不代表世界已恢复或重置、请重新查询当前状态"，绝不落到 `world_restored`。
2. dedupe id 分命名空间：非缺口事件仍为 `world:<scopeID>:<worldID>:<sequence>`；缺口通知为 `observation-gap:<scopeID>:<worldID>:<sequence>`。即使通知 sequence 数值与某条真实事件相同，前缀不同也不会被居民按 id 去重误吞或混淆。
3. 生产穷尽 switch（仅此文件与 `WorldSimulation.isDisposableClockEvent`、`WorldAgentContext.filteredDelivery` 三处）全部适配，无 default 逃逸（`filteredDelivery` 原有 default 分支不涉及新增 case 编译）。

## 三、测试执行（全部离线，无真实等待）

命令：`cd apps/macos/Packages/WorldRuntime && swift test --disable-sandbox`：

```
Test run with 143 tests in 0 suites passed
```

- 既有 143 项全过（含 64 容量有界窗口、裁剪水位、恢复续走水位等缓存契约），新增 case 未改变任何缓存行为。

独立 window 工具（编译生产 `WorldAgentContext` + `ResidentWorldObservation`，用同构 `ResidentAgentLoop.Event` 桩代替 CC 未完成 loop 类型，避免依赖 CC 未完成类型）：

```
swift tools/test-resident-world-retention-window.swift
PASS: 65 resident window checks, 0 failures; walk ticks 940
```

较上一轮 48 项新增 17 项，覆盖主代理逐条要求：

- **gap kind 明确**：滞后消费者首批第一件是 `.observationGap`，居民侧 kind 为 `observation_gap`；同批不含任何 `.worldRestored`（不是伪造恢复）与 `.worldLoaded`（不伪装完整历史）。
- **最新 movementCompleted 不被去重吞掉**：缺口同批仍投递真实 `movementCompleted`；按居民 id 去重模型（`ResidentAgentLoop` 语义：同 id 只收首见）跑完后 `movement_completed` 仍在、`observation_gap` 恰一次；缺口 id 前缀 `observation-gap:<scope>:<worldID>:` 与真实 `world:` id 集合不相交。
- **正常 worldRestored 仍正常**：真实恢复（持久化存档 → `WorldSimulation(restoring:)`）仍以 `.worldRestored` 开头、映射为 `world_restored`，恢复后走动不伪造缺口通知。
- **重入水位正确**：缺口投递回调内同步 `completeGoal` —— 游标先推进，目标事实从自己的第二次 drain 到达，跨两次 drain 序列不重复、缺口通知恰好一次。
- **不使用 UInt64.max 保留号**：断言通知 sequence == 捕获时的 `trimmedNewestSequence`（真实淘汰水位）且 ≤ 活动 revision；`resyncSequence`/递减铸造已从源码删除。
- **保持 64 容量既有功能**：滞后上下文与恢复上下文走动后仍钉在 `retainedEventCapacity`（=64），裁剪水位低于活动水位。

## 四、保留项核对

- 快照不经事件缓存；真实动作回执是 API 返回值，与裁剪无关（沿用既有断言）。
- `WorldSimulation` 缓存区（64 容量、裁剪、恢复、序列=水位）除穷尽 switch 一行外零改动；`WorldSimulationTests`/`WorldEventRetentionTests` 143 项全过。
- 咖啡/物件布局/使用状态、导航、存档 schema 未触碰；`world.json`、Rust、App、loop、vision 未改。
- 不写 SQLite、不改存档字节：存档 schema 键集合与 save→load→save 字节稳定断言继续通过。

## 五、协调依赖报告（报告主代理，按约定不改 CC 文件）

1. `test-resident-world-retention-longrun.swift` 与 `test-resident-world-observations.swift` 仍不能编译运行：其编译集引用的 `ResidentAgentLoop` 引用 CC 的 `ResidentMemoryStore`/`ResidentStateScope`，这两类不在工具编译集内（实测报 `cannot find type 'ResidentStateScope' in scope`）。长时工具阶段 4/5 与观察工具的断言已按新缺口语义同步更新，待 CC 文件稳定合入后即可运行。
2. GMGNRadio 整包 App/Xcode 目标仍未构建（保护共享脏工作树不并行重编译）。本轮对 App 接线零改动：`onEventsPublished` 形状不变，App 现有循环 `ResidentWorldObservation.event → loop.receiveEvent` 会原样把 `observation_gap` 通知送达居民链。
