# 启动就绪清单：进门之前该准备好的每一件事

日期：2026-10-09 · 工作树 `~/.codex/worktrees/rust-full-migration/gmgnradio`（HEAD `5e5dfa1`，build 229 已装机）

**这份清单是机读的。** 它的权威副本是
[`apps/gpui-ui/src/startup.rs`](../../apps/gpui-ui/src/startup.rs) 的 `STARTUP_ITEMS`
（每一项的 `source` / `ready_when` / `fails_when` / `failure_code` / `role` / `budget_ms`），
门禁在 [`apps/gpui-ui/tests/startup_readiness_gate.rs`](../../apps/gpui-ui/tests/startup_readiness_gate.rs)：
**每一项引用的那一行必须真的存在**，**每一条"没 ready"文案必须被某一项收走**，
**每一句没登记的"没 ready"字面量都会让门禁变红**。所以这份文档不是散文，是那张表的说明。

## 用户的判断（本清单的依据）

> 与其到处暴露"没 ready"的状态，不如一开始做一个"很长的加载态"，把所有东西准备好再放人进去。

于是清单要回答的是同一件事的两个方向：

1. **哪些"没 ready"能在启动阶段解决**（`STARTUP_ITEMS.role = Blocking` 或 `Preflight`）；
2. **哪些必须等到用户动手**（`Deferred`），而且它们必须**在加载态里就具名列出**，
   不是等用户点某个按钮时才弹。

## 现场（2026-10-09 19:10 冷启动，真机日志）

`$HOME/Library/Logs/DefaultCompany/GMGN Unity Sample/Player.log`（就是 `/Applications/gmgn radio.app` 里的
Unity player；进程名是产品内嵌的 player 名）。**这一段只有两个时间戳**，因为 Unity 的
`Debug.Log` 不带时间，只有宿主的 `NSLog` 带——这本身是一条发现，见文末"改了什么"。

| 时刻 | 事件 | 距上一锚点 |
|---|---|---|
| `19:10:42.618` | `[UnityMediaHost] world startup scheduled: candidates=1` | — |
| `19:10:43.988` | `[UnityMediaHost] world startup authority read: world=84503420-…` | +1.370 s |
| `19:10:46.778` | `phase=prepare revision=1` ＋ `world selection assets: entries=7` | +2.790 s |
| （无时间戳） | `[WorldPrepare] step=open` → `step=scene marble=False` → `step=items entries=7` → `step=recover.begin objects=9` → **7 个物件的 `metadata`/`resolve`/`load` 串行** → `step=recover.done objects=7` → `step=ready items=7` | ← 这一段 **17.107 s** 全在里面 |
| `19:11:03.885` | `[UnityMediaHost] world selection: … phase=activate revision=1` | +17.107 s |
| `19:11:04.066` | `[UnityActivityPhase] snapshot phase=idle revision=8037011`（第一次活动快照） | +0.181 s |

**冷启动到"空间真的在画面里"＝ 19:10:42.618 → 19:11:03.885 ＝ 21.267 s**
（权威读取 1.370 s ＋ 准备事务 2.790 s ＋ 渲染侧准备 17.107 s）。
其中 17.107 s 是**七个生成物串行恢复**，而宿主与界面在这 17 秒里什么都还没有。

同一份日志里的旁证（`step=scene` 之后那段没有时间戳的窗口）：`[GaussianWorld] show cached=False
cpuMs=23.75`（场景缓存**冷**），asset 恢复期间夹着 `GPU frame timing cpuMs=172.629`（一帧 172 ms）
——主线程正被资产装载占着。

## 清单

列的含义：**来源** ＝ 判定依据的那一行；**已就绪** ＝ 可观测的"好了"；**会失败于** ＝ 什么时候不成立；
**用户看到** ＝ 他会在**进门之后**撞上的那句话（或码）；**能否前置** ＝ 本可以在启动阶段做完吗。

### A. 宿主自身（没有这些，后面全是空话）

| # | 项 | 来源 | 已就绪（可观测） | 会失败于 | 用户看到 | 能否前置 |
|---|---|---|---|---|---|---|
| A1 | 应用核心 | `apps/gpui-app/src/product_host.rs:79` | `gmgn_product_host_start` 返回非 0 且 `create` 给了句柄 | dylib 打不开 / 符号缺失 / start 返回 0 | `这个原有功能入口暂未能打开，请检查应用启动状态。`（`main.rs:558`） | **能**（Blocking，5 s） |
| A2 | 应用状态 | `apps/gpui-app/src/main.rs:458` | 第一次 `poll()` 给出可解析的 `{events,state,transcript}` | 批次为空 / JSON 坏 / 缺 `state`、`transcript` | `应用返回的对话状态无法读取，文字已保留。`（`main.rs:463`） | **能**（Blocking，10 s） |
| A3 | 场景画面 | `apps/gpui-app/src/main.rs:407` | `ProductHost::mount` 返回 true（真实渲染面已接上这个窗口） | 容器视图拿不到 / `attach_surface` 返回 0 | `正在连接原应用场景…`（`main.rs:416`，今天唯一那句"加载态"） | **能**（Blocking，20 s） |
| A4 | 窗口形态 | `apps/gpui-app/src/main.rs:704` | 当前形态（大窗/小窗）建得出来，且**这一形态**的面已挂上 | `open_window` 失败；或上一次切换没结算，`profile_switch_pending` 让后续切换被**静默忽略**（`:668`） | `窗口切换未完成。`（`main.rs:704`） | **能**（Blocking，20 s） |

### B. 世界：那 21 秒

| # | 项 | 来源 | 已就绪（可观测） | 会失败于 | 用户看到 | 能否前置 |
|---|---|---|---|---|---|---|
| B1 | 空间记录（权威） | `apps/macos/UnityHost/UnityMediaHost.swift:778` | `WorldAuthorityClient.snapshot()` 拿得到世界记录 | helper 冷启动没起（`world_authority_unavailable`）／这台机器从未进过（`world_authority_record_missing`）／载入期间状态前进（`world_authority_activation_failed`） | `空间暂时无法连接，音乐和聊天仍可使用。请重新选择空间或稍后重试。`（`:778`） | **能**（Blocking，30 s） |
| B2 | 空间画面与物件 | `apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:409` | `[WorldPrepare] step=ready items=N` 且 N 个物件都不是 `failed` | 背景格式未接入（`:396`）／物件没完整载入（`:406`）／渲染侧 120 s 预算到期（`:411` `world_prepare_timeout`）／回执丢失（`UnityMediaHost.swift:797` `world_prepare_unanswered`） | `空间画面准备超时，当前空间已保留。`（`:414`） | **能**（Blocking，120 s ＝ 渲染侧自己的预算） |
| B3 | 空间确认可见 | `apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:348` | `SetVisible(true)` 之后 `phase=activate`，快照里 `isWorldVisible` 为 true | `phase=failed` ＋ 任一具名 code；或 `activate` 的 revision 与已准备好的不一致（`:324` 直接 return） | `空间暂时无法打开，请重新选择空间。`（`:322`） | **能**（Blocking，30 s） |
| B4 | 场景缓存 | `apps/unity-player/Assets/GMGN/GaussianWorld/GaussianWorldView.cs:114` | `[GaussianWorld] show cached=True`（GPU 资源是热的） | 缓存未命中（实测 `cached=False` 时 23.75 ms 现场解一次）；或卡在 `WorldPrepareDeferAgent` 的 defer 循环里，`step=scene` 后不再出下一行 | 无用户文案（性能问题）；由 B2 的预算兜住 | **能判定**（Preflight，20 s） |

### C. 摆放：网格、几何、物理、容量

| # | 项 | 来源 | 已就绪（可观测） | 会失败于 | 用户看到 | 能否前置 |
|---|---|---|---|---|---|---|
| C1 | 摆放网格 | `apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:811` | `OnPlacementDerived` 收到本次 `placementDeriveID` 的 `status=completed` 且 `grid != null` | 回执 `status != completed` 或 grid 为空（`:812`）；校验服务忙，50/100 次重试仍拒（`:782`/`:798`） | `真实空间网格生成失败，摆放尚未启用。`（`:812`）／`空间网格校验服务忙，摆放尚未启用。` | **能**（Preflight，20 s） |
| C2 | 物件碰撞几何 | `apps/unity-player/Assets/GMGN/WorldInteraction/PlacementRequestBuilder.cs:81` | 每个已启用物件的 `sharedMesh` 非空且 `isReadable` ⇒ `unavailable` 为空 | 网格不可读（`nonreadableMesh`，`:81`）／没有 MeshFilter（`noMeshFilters`）／权威里有但场景里没有（`unmodelledProp:<id>`，`:117`） | `这个物件的碰撞几何未载入，暂时不能移动。`（`:107`）／`有空间物件尚未载入，这次调整已取消。`（`:117`） | **能**，而且**必须逐物件记名**（Preflight，20 s） |
| C3 | 碰撞模型校准 | `apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:770` | 碰撞模型可读（`PlacementGeometry.cs:122` 的 `isReadable` 通过），非舱室世界有显式校准 | 模型没保留几何数据（`PlacementGeometry.cs:122`）／缺 `GMGN_UNITY_WORLD_COLLIDER_TRANSFORM`（`:770`）／空间包没有碰撞参考（`PlacementGeometry.cs:36`、`:103`） | `碰撞模型未保留几何数据，请启用 GLTFAST_KEEP_MESH_DATA 后重新构建。`／`真实碰撞模型缺少明确校准，摆放尚未启用。` | **能**（Preflight，20 s） |
| C4 | 物理探针 | `apps/unity-player/Assets/GMGN/WorldPhysicsProbeBridge.cs:54` | `ready=true` 且 `physics.IsValid()`；每个 restored 物件的网格非空且 `isReadable` | 物件实例为空／没有 MeshFilter／网格不可读（`:54`）／场景物理无效（`:66`）／几何非有限（`:57`） | `world_physics_not_ready`（权威侧码；这一步今天没有独立文案） | **能判定**（Preflight，20 s） |
| C5 | 落点与能力容量 | `services/gmgn-taskd/src/world_prop_capability.rs:261` | 发起前本地校验：`waypoints` 是 1…64 长度的数组，每项有唯一非空 `id` 与布尔 `enabled`，`position` 是有限三元组 | `waypoints` 不是数组或超过 64 个 ⇒ 权威拒绝 `prop_capability_capacity`（`:261`）；同族还有 `_invalid_geometry` / `_unsupported_template` | `prop_capability_capacity`（**权威码冒充外层活动方法的码**，见 `docs/deepseek-ui-layer-report-2026-10-08.md:247`） | **能**（发起前一次本地校验即可；Preflight，10 s） |

**关于 `prop_capability_capacity` 的诚实说明**：它不是"这个世界装不下了"，而是
`input["waypoints"]` 不是数组或超过 64 项——**是调用方形状错误**。所以它完全可以
在启动/发起前用一次本地校验拦掉，不该让用户在一次摆放动作里看到权威码。

### D. 居民会话与队列

| # | 项 | 来源 | 已就绪（可观测） | 会失败于 | 用户看到 | 能否前置 |
|---|---|---|---|---|---|---|
| D1 | 居民会话 | `apps/macos/RenderHost/ResidentConversationBridge.swift:188` | `worldServices` 已建且 `isCurrent()`；`chatAvailable` 为 true | 空间服务没建起来（`:188`）／会话正在切换（`:183`）／后端 `codex` 且没有世界服务（`:597`） | `空间服务尚未就绪，消息已保留。`／`当前空间服务尚未就绪。`／`空间正在切换，请稍后再发送。` | **能**（Blocking，45 s） |
| D2 | 原生 Agent 连接 | `apps/macos/RenderHost/ResidentConversationBridge.swift:606` | `RenderHostDSHConnector` 建得起来（找到原生 DSH 安装） | 原生连接未就绪（`:606`）／后端不支持（`:605`）／只能退回 headless（`:607`，明确拒绝） | `现有 Agent 的原生连接尚未就绪，请检查 DeepSeek Harness 安装。` | **能**（Blocking，45 s） |
| D3 | 队列可领取 | `services/gmgn-taskd/src/agent_scheduler.rs:283` | 没有真正在飞的回合（`state IN ('claimed','cancel_requested')` 为空）；`hostSessionID` 一致；`available` 为 true 且 `editing` 为 false | 上一次的回合仍在 `claimed`/`cancel_requested`（`:283`）或 `editing`（`:262`）⇒ `agent_loop_claim` 只回答 `claimed:false` | **今天没有文案**：宿主侧一次 `chat.send` 就此静默（2026-10-09 现场："消息发出去、回合不被领取"） | **能**（Blocking，30 s；见 `SILENT_BEFORE_THE_GATE`） |

**`unknown` 不再挡人**（2026-10-09 已修，`agent_scheduler.rs:284` 起的长注释）：
一个从上一版遗留的 `unknown` 事件曾让该 world+scope 的**每一次** `agent_loop_claim`
都回答 `claimed:false`，消息永远停在 `queued`——"聊天看着是死的"。现在的判据只有
`executing`（真在飞）和 `editing`。

### E. 界面各页需要的数据

判据统一是"**键在且形状对**"，不是"值看起来像好了"——这正是"没数据"被说成
"真的没有"的根因（`ui.tv` / `ui.activities` 两条都是现场实例）。

| # | 项 | 来源 | 已就绪（可观测） | 会失败于 | 用户看到 | 能否前置 |
|---|---|---|---|---|---|---|
| E1 | 聊天面板 | `apps/gpui-ui/src/chat.rs:67` | 快照 `transcript` / `reply` 可读，`contextID` 已定 | 麦克风授权未完成（`:67`）／ASR 未配置（`:68`）／服务不可用（`:69`） | `语音识别服务暂不可用，请稍后重试。` | **能判定**（Preflight，15 s；授权本身只能等用户） |
| E2 | 通知 | `apps/gpui-app/src/main.rs:502` | 快照 `inbox.entries` 是数组（可为空） | `inbox` 没投影出来 ⇒ 未读数读成 0 | 无文案（静默：把"没数据"显示成"没有通知"） | **能**（Preflight，15 s） |
| E3 | 我的物件 | `apps/gpui-ui/src/stage_panels/props.rs:93` | 快照 `propEditor` 可读，`rooms`/`placed` 都是数组 | `propEditor` 没到，或 `propsAvailable` 为 false | 列表读不出来（今天会落到 C2 那段文案） | **能**（Preflight，15 s） |
| E4 | 节目单（播放器菜单） | `apps/gpui-app/src/main.rs:751` | 快照 `liveCamPlayerMenu` / `musicLibrary` 可读 | 宿主还没建播放器菜单 | `播放器尚未准备好`（`main.rs:751`，**菜单标题**） | **能**（Preflight，20 s） |
| E5 | 歌单与节目 | `apps/gpui-app/src/main.rs:504` | 快照 `stageProgramRail` 可读（`programs`/`playlists`/`tracks` 都是数组） | 音乐库投影没到 ⇒ 节目单是空列表，而不是"还没有节目" | 无文案（静默：把"没数据"显示成"空"） | **能**（Preflight，20 s） |
| E6 | 电视与屏幕 | `apps/gpui-app/src/main.rs:809` | `screenOperation.available` 与 `screenVideo.screens` 都已判定（可以就是"没有电视"） | 投影没到 ⇒ `available` 读成 false | `这块空间里还没有在放的电视`（`main.rs:809`，**把"没数据"说成"没电视"**） | **能**（Preflight，15 s） |
| E7 | 设置页 | `apps/gpui-app/src/main.rs:517` | 快照 `settings` 可读，`presence`/`generation` 子块都在 | 设置投影没到 | `该页面尚未完成 Unity 运行时接线。`（`i18n.rs:70`） | **能**（Preflight，15 s） |
| E8 | 舞台面板 | `apps/gpui-app/src/main.rs:503` | 快照 `stage` 可读：`presentation`/`mode`/`space`/`activities`/`player` 都在 | 舞台投影没到 ⇒ 空间页显示自己那块转圈 | `正在载入空间，完成后自动进入…`（`stage_panels.rs:1702`，**这句就是"到处暴露没 ready"的样本**） | **能**（Preflight，15 s） |
| E9 | 生活活动 | `apps/gpui-ui/src/stage_panels.rs:186` | 快照 `activities.canRun` 是布尔、`items` 是数组（空数组 ＝ 真的没配） | 投影没到 ⇒ 文案变成"这个空间还没有配置生活活动" | `这个空间还没有配置生活活动。`（`stage_panels.rs:186`） | **能**（Preflight，15 s） |
| E10 | 屏幕操作 | `apps/gpui-app/src/main.rs:388` | 快照 `screenOperation` 可读，`taskFeedbackVisible` 已判定 | 投影没到 ⇒ 每次场景操作都被报成"尚未确认完成" | `场景操作尚未确认完成，请检查当前状态。`（`main.rs:388`）／`设置操作尚未确认完成，请检查当前配置。`（`:400`） | **能**（Preflight，15 s） |
| E11 | 许愿生成服务 | `apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift:18` | `GET /health` 返回 `api_ready` 且 `generation.ready`（5 s 超时，`:14`） | 服务没配（`generation_not_configured`）／连不上／`shared_memory_busy`（`:17`） | `服务已连接，生成暂未就绪，请稍后再检测。`（`:18`）／`服务已连接，正在等待生成资源。`（`:17`）／`尚未配置生成服务`（`i18n.rs:362`） | **能**（一次 `/health`；Preflight，10 s） |

### F. 只能进门之后按需的

它们在加载态里**必须具名列出**（`StepPhase::Deferred`），然后才放人进去。

| # | 项 | 来源 | 已就绪（可观测） | 会失败于 | 用户看到 | 为什么不能前置 |
|---|---|---|---|---|---|---|
| F1 | 许愿产物下载 | `apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift:226` | job `stage == .ready` 且 `modelPath` 真在磁盘上（`:898`） | 下载/检查没做完（`:226`） | `物品还未完成下载检查，暂时不能领取。` | 生成与下载**由用户发起**，启动时没有产物可下 |
| F2 | 许愿领取与摆放 | `apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift:990` | 面板已接到世界里（`worldSession` 在）且挂点已提交 | 面板没接到世界（`:990`）／没接到许愿任务（`:961`）／拿不到摆放几何（`:204`） | `摆放面板还没有接到世界里（空间会话未就绪），这次挂点没有提交。请关掉面板重开一次。` | 挂点只能在用户摆放时提交 |
| F3 | 许愿入库回执 | `apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift:346` | 入库回执已确认（`hasAssetFailure` 为 false） | 回执未确认／资产失败（`:346`/`:347`、`GMGNRadioApp.swift:5224`） | `已入库，资产未就绪`／`资产未就绪：<reason>` | 领取之后才有回执 |
| F4 | 按住说话的授权 | `apps/gpui-ui/src/chat.rs:67` | 系统麦克风授权已给出、ASR 已配置 | 授权提示没被回答（`microphone_permission_pending`）／ASR 没配（`asr_configuration_missing`） | `麦克风授权尚未完成，请确认系统授权提示。` | 系统授权**只能**在用户第一次按麦克风时申请（红线：不合成输入、不触发钥匙串） |

## 汇总：能前置 vs 必须等

- **能前置并且挡人（Blocking，10 项）**：A1–A4、B1–B3、D1–D3。
  一共 `host.core`、`host.snapshot`、`host.surface`、`window.mode`、
  `world.authority`、`world.prepare`、`world.activate`、
  `resident.session`、`resident.agent`、`resident.queue`。
- **能前置并判定，但允许结论是"本轮不可用"（Preflight，17 项）**：
  C1–C5、E1–E11、`cache.scene`。
- **必须等用户/下载（Deferred，4 项）**：F1–F4。
- **清单总数 31 项**（`STARTUP_ITEMS.len()`），全部都有 `budget_ms`；整体上界
  `STARTUP_DEADLINE_MS = 150_000 ms`（≥ 渲染侧自己的 120 s 预算，所以不会抢先杀掉一次
  **合法**的长准备，但一定会给出结局）。

## 两处"看着像没 ready，其实不是"（已逐条登记豁免）

- **空状态**：`房间里还没有摆放物件`（`props.rs:93`）、`还没有许愿。…`（`:98`）、
  `尚未选择角色`（`i18n.rs:116`）——这些是**正确**的说法，不是"没 ready"。
- **一次操作的终局**：`此操作暂未完成，请重试。`（`main.rs:449`）、
  `应用尚未确认接收，无法交付这条回复。`（`:487`）、`已停止尚未发送的消息。`
  （`ResidentConversationBridge.swift:474`）——**真失败仍然失败**，这一层只把**时机**提前。

## 改了什么（相对改前）

1. **清单成了机读的表**：`STARTUP_ITEMS`（31 项）+ `RETIRED_COPY`（31 条被收走的文案）
   + `ALLOWED_AFTER_READY`（59 条豁免）+ `SILENT_BEFORE_THE_GATE`（2 条以前静默的挡人项）。
2. **加载态真的存在**：`StartupGatePane` 在进门前盖住整窗，有步骤名、`n/m 项已就绪`、
   进度条、具名失败与「重试」；`OverlaySlot::StartupGate` 是**最后一个**槽位且**不是**被动区
   （进门之前指针不许穿过它落到场景上）。
3. **每一条引用都被钉住**：清单项指向的行一旦移动/变空，门禁变红；每一条被收走的
   文案在它引用的那一行必须逐字还在。

### 边界：这份清单**没能**变成真值的地方

- **`PlacementGeometry` / `PhysicsProbe` / `GenerationService` 三个信号今天没有宿主投影。**
  C1–C4、E11 的"已就绪"在 `startup.rs` 里写明了它们需要的**新快照键**，但在宿主把键
  投影出来之前，这三项会在自己的上界到点后**具名**变成"本轮不可用"——这是刻意的：
  **不发明真相**。要让它们真的在加载态里变绿，需要（a）宿主把 Unity 的摆放网格回执、
  物理探针 `ready`、`generation.health` 投影进快照，以及（b）一次真机冷启动验收。
- **每步耗时无法从 `Player.log` 复原**：渲染侧 `Debug.Log` 不带时间戳，整个 17.107 s
  的窗口里只有两个 `NSLog` 锚点。要拿到每步耗时，需要给 `[WorldPrepare]` 的 step 日志
  加时间戳（`apps/unity-player`，本次未改）**并且**重建 player 冷启动一次。
