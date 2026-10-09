//! 启动加载态：**进门之前**把清单上的每一项准备好，而不是进门之后再一条条报"没 ready"。
//!
//! ## 为什么要有这一层
//!
//! 2026-10-09 的现场是一串**进门之后**才出现的"没 ready"：进空间冷启动要约
//! 17 秒（七个生成物串行恢复，`[WorldPrepare] step=…`），期间界面已经在跑；进入后
//! 点装修会弹「真实空间网格生成失败，摆放尚未启用。」；发消息可能撞上
//! 「空间服务尚未就绪，消息已保留。」；主题曲是「播放器尚未准备好」。
//!
//! 用户的判断（2026-10-09）是：**与其到处暴露"没 ready"的状态，不如一开始做一个
//! "很长的加载态"，把所有东西准备好再放人进去。** 这一层就是那个加载态——
//! 它不是一个转圈，而是一份清单加一台状态机：
//!
//! - [`STARTUP_ITEMS`] 是那份清单，**穷举**：每一项都钉住真实源码
//!   （`source`）、写出"已就绪"的**可观测判定**（`ready_when`）、"在什么条件下会
//!   失败"（`fails_when`）、失败时的**具名码**（`failure_code`）、以及它
//!   **本可以不可以在启动阶段做完**（[`GateRole`]）。
//! - [`StartupGate`] 是那台状态机：并行推进、有上限、失败**具名**、可重试。
//! - [`RETIRED_COPY`] 把"以前进门之后才看到的没 ready 文案"逐条绑定到清单里的某一项，
//!   于是"这一项被移出加载态"这件事可以机械地判红（见
//!   `tests/startup_readiness_gate.rs`）。
//! - [`StartupGatePane`] 是那个界面：步骤名 + 进度 + 具名失败 + 重试。
//!
//! ## 硬性规则（实现必须满足，测试逐条钉住）
//!
//! 1. 加载态覆盖清单里的**每一项**：`STARTUP_ITEMS` 的 id 唯一、非空、有引用、
//!    有上界。
//! 2. 加载态结束后**不得**再出现已知的"没 ready"文案：每条这样的文案要么绑定到
//!    清单里的一项，要么在 [`ALLOWED_AFTER_READY`] 里逐条写明"为什么它本来就不是
//!    启动阶段的事"。
//! 3. 加载态有上限且失败具名：任何一项不可能无限等待——它有 `budget_ms`，整体还有
//!    [`STARTUP_DEADLINE_MS`]；超时只会变成 `"<id>_timeout"` / `"<id>_deadline"`
//!    这样的具名失败，不会静默。
//!
//! ## 不放宽任何校验
//!
//! 这一层只把**时机**提前并**具名**，不改判定：真的失败仍然失败（[`StepPhase::Failed`]），
//! 真的需要用户/下载的仍然等（[`GateRole::Deferred`]，且在加载态里就**具名列出**，
//! 不是等到点按钮时才弹）。
use std::collections::BTreeSet;

use gpui_kit::assets::IconName;
use gpui_kit::component::*;
use gpui_kit::prelude::InteractiveElement as _;
use gpui_kit::*;
use serde_json::Value;

use crate::primitives as ui;
use crate::ui_tokens::scene as s;
use crate::ui_tokens::{CAPTION as CAPTION_SIZE, SPACING_4, SPACING_8};

/// The loading surface's own column width. One constant because the progress
/// track and the card must be the same box.
const GATE_COLUMN_WIDTH: f32 = 420.;
/// The progress track's width: the column minus its own padding.
const GATE_TRACK_WIDTH: f32 = GATE_COLUMN_WIDTH - 2. * s::PANEL_PADDING;

// ---------------------------------------------------------------------------
// 清单
// ---------------------------------------------------------------------------

/// 一项在启动阶段**本可以**做到什么程度。
///
/// 这个分类是这份清单的核心结论：它决定了加载态对一项是"挡人"、"具名但不挡人"，
/// 还是"只能进门后按需"。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum GateRole {
    /// 本可以在启动阶段完成，而且**没做完就不放人进去**。
    ///
    /// 超时 = 具名失败 + 重试，不是"进去以后再告诉你"。
    Blocking,
    /// 本可以在启动阶段**判定**，但判定的结果允许是"本轮不可用"。
    ///
    /// 它必须先被判定并**具名**（哪一项、为什么），否则用户会在点某个按钮时才
    /// 撞上它；但它不挡人进门——例如"这个空间这一轮没有电视"是正常状态。
    Preflight,
    /// 启动阶段**做不到**：需要用户输入，或需要只在用户动手时才发生的下载/网络。
    ///
    /// 这一项仍然在加载态里**具名列出**（[`StepView`] 的 `Deferred`），所以用户是
    /// 在进门之前就知道"这件事进去以后才会发生"，而不是被它突袭。
    Deferred,
}

/// 清单项的"已就绪"由**哪个可观测信号**决定。
///
/// 每一个变体都是宿主已经发布的东西的函数（`ProductHost` 自己的布尔量，或
/// `poll()` 出来的快照键）。这一层不发明新的真相，也不去猜渲染器内部状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Signal {
    /// `ProductHost::load()` 成功：dylib 打开、符号齐全、`gmgn_product_host_start`
    /// 返回非 0（`apps/gpui-app/src/product_host.rs:79`）。
    HostCore,
    /// 第一次 `poll()` 拿到**可解析**的批次（`apps/gpui-app/src/main.rs:465`）。
    HostSnapshot,
    /// 真实渲染面挂载成功（`ProductHost::mount` 返回 true，
    /// `apps/gpui-app/src/main.rs:414`）。
    HostSurface,
    /// 快照里空间呈现被请求：`stage.presentation.isWorldPresentationRequested`
    /// （`apps/macos/UnityHost/UnityMediaHost.swift:1044`）。
    WorldRequested,
    /// 渲染侧确认空间可见：`stage.presentation.isWorldVisible`。它就是
    /// `[UnityMediaHost] … phase=activate` 之后 `WorldMode visible=True`
    /// 的那件事（`apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:348`、
    /// `apps/macos/UnityHost/UnityMediaHost.swift:1133`）。
    WorldVisible,
    /// 居民会话可领取：`stage.presentation.chatAvailable`
    /// （`apps/gpui-app/src/main.rs:791` 读它）。
    ResidentSession,
    /// 装修面可用：`stage.presentation.propsAvailable`
    /// （`apps/gpui-app/src/main.rs:792` 读它）。
    PlacementSurface,
    /// 活动目录已判定：`activities.canRun` 与 `activities.message`
    /// （`apps/gpui-ui/src/stage_panels.rs:186`）。
    ActivityCatalog,
    /// 播放器菜单已建立：`liveCamPlayerMenu`
    /// （`apps/gpui-app/src/main.rs:758`）。
    PlayerMenu,
    /// 音乐库投影到达：`musicLibrary`
    /// （`apps/gpui-app/src/main.rs:511` 把它喂给节目单）。
    MusicLibrary,
    /// 通知投影到达：`inbox`
    /// （`apps/gpui-app/src/main.rs:509`）。
    InboxProjection,
    /// 许愿投影到达：`wish`。
    WishProjection,
    /// 电视投影已判定：`screenVideo` / `screenOperation`
    /// （`apps/gpui-app/src/main.rs:816`）。
    ScreenProjection,
    /// 设置投影到达：`settings`
    /// （`apps/gpui-app/src/main.rs:524`）。
    SettingsProjection,
    /// 舞台面板投影到达：`stage`
    /// （`apps/gpui-app/src/main.rs:510`）。
    StageProjection,
    /// 摆放几何可用：Unity 侧 `PlacementGeometry` 已派生并回执
    /// （`apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:811`）。
    ///
    /// 宿主今天**还没有**把这件事投影出来，所以这一项在
    /// [`ReadinessItem::ready_when`] 里写明了它需要的新键；
    /// 见模块末尾"诚实边界"。
    PlacementGeometry,
    /// 物理探针几何 ready：`WorldPhysicsProbeBridge` 的 `ready=true`
    /// （`apps/unity-player/Assets/GMGN/WorldPhysicsProbeBridge.cs:62`）。
    PhysicsProbe,
    /// 生成服务健康：`PropGenerationHealth.isReady`
    /// （`apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift:14`）。
    GenerationService,
}

/// 清单里的一项。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReadinessItem {
    /// 稳定 id（失败码、重试、测试都按它认人）。
    pub id: &'static str,
    /// 用户在加载态里看到的**步骤名**。一句话说清"在准备什么"。
    pub label: &'static str,
    /// 判定依据的源码位置，`仓库相对路径:行`。
    pub source: &'static str,
    /// "已就绪"的**可观测**条件。
    pub ready_when: &'static str,
    /// 在什么条件下会失败 / 不能就绪。
    pub fails_when: &'static str,
    /// 失败时的**具名**码（真实日志/回执里的码，不是这里编的）。
    pub failure_code: &'static str,
    /// 失败时用户看到的那句话（就是被 [`RETIRED_COPY`] 收走的那一句）。
    pub user_copy: &'static str,
    pub role: GateRole,
    /// 驱动它的可观测信号。
    pub signal: Signal,
    /// 这一项自己的上界（毫秒）。任何一项都**必须**有上界。
    pub budget_ms: u64,
    /// 必须先就绪的项。空 = 可以和其他项**同时**开始。
    pub depends_on: &'static [&'static str],
}

/// 加载态的**整体**上界。超过它，所有还没就绪的挡人项都会变成
/// `"<id>_deadline"` 具名失败——不会无限等。
///
/// 这个数必须 ≥ 渲染侧自己的准备预算（`WorldRuntimeBridge.cs:60` 的
/// `PrepareBudget = 120 s`）加上它的宿主兜底（`UnityMediaHost.swift:98` 的
/// 180 s watchdog 只在回执丢失时生效，正常路径由渲染侧 120 s 先答），
/// 所以取 150 s：它不会抢先杀掉一个**合法**的长准备，但会给出结局。
pub const STARTUP_DEADLINE_MS: u64 = 150_000;

/// 那份清单。**穷举**——每一行对应一次"进门之后才发现的没 ready"，
/// 顺序是它在链路里的顺序，不是渲染顺序。
pub const STARTUP_ITEMS: &[ReadinessItem] = &[
    // ---- 宿主自身：没有它，后面全是空话 -------------------------------------
    ReadinessItem {
        id: "host.core",
        label: "应用核心",
        source: "apps/gpui-app/src/product_host.rs:79",
        ready_when: "`gmgn_product_host_start` 返回非 0，且 `create` 返回了句柄",
        fails_when: "dylib 打不开 / 符号缺失 / start 返回 0",
        failure_code: "product_host_unavailable",
        user_copy: "这个原有功能入口暂未能打开，请检查应用启动状态。",
        role: GateRole::Blocking,
        signal: Signal::HostCore,
        budget_ms: 5_000,
        depends_on: &[],
    },
    ReadinessItem {
        id: "host.snapshot",
        label: "应用状态",
        source: "apps/gpui-app/src/main.rs:465",
        ready_when: "`poll()` 给出一个能解析成 `{events,state,transcript}` 的批次",
        fails_when: "批次为空 / JSON 坏了 / 缺 `state` 或 `transcript`",
        failure_code: "product_snapshot_unreadable",
        user_copy: "应用返回的对话状态无法读取，文字已保留。",
        role: GateRole::Blocking,
        signal: Signal::HostSnapshot,
        budget_ms: 10_000,
        depends_on: &["host.core"],
    },
    ReadinessItem {
        id: "host.surface",
        label: "场景画面",
        source: "apps/gpui-app/src/main.rs:414",
        ready_when: "`ProductHost::mount` 返回 true，即真实渲染面已接上这个窗口",
        fails_when: "容器视图拿不到 / `attach_surface` 返回 0",
        failure_code: "render_surface_unattached",
        user_copy: "正在连接原应用场景…",
        role: GateRole::Blocking,
        signal: Signal::HostSurface,
        budget_ms: 20_000,
        depends_on: &["host.core"],
    },
    // ---- 世界：最贵的一段，也是"进不去"的那 17 秒 ----------------------------
    ReadinessItem {
        id: "world.authority",
        label: "空间记录",
        source: "apps/macos/UnityHost/UnityMediaHost.swift:783",
        ready_when: "`WorldAuthorityClient.snapshot()` 拿得到世界记录（`phase=reading` 有世界 id）",
        fails_when: "权威 helper 冷启动未起（`world_authority_unavailable`）、这台机器从未进过这个世界（`world_authority_record_missing`）、载入期间状态前进（`world_authority_activation_failed`）",
        failure_code: "world_authority_unavailable",
        user_copy: "空间暂时无法连接，音乐和聊天仍可使用。请重新选择空间或稍后重试。",
        role: GateRole::Blocking,
        signal: Signal::WorldRequested,
        budget_ms: 30_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "world.prepare",
        label: "空间画面与物件",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:409",
        ready_when: "`[WorldPrepare] step=ready world=… items=N`，且 N 个物件 `Status != \"failed\"`",
        fails_when: "背景格式未接入（`:396`）、物件没完整载入（`:406`）、超时（`:411` `world_prepare_timeout`）、回执丢失（`UnityMediaHost.swift:805` `world_prepare_unanswered`）",
        failure_code: "world_prepare_timeout",
        user_copy: "空间画面准备超时，当前空间已保留。",
        role: GateRole::Blocking,
        signal: Signal::WorldVisible,
        budget_ms: 120_000,
        depends_on: &["world.authority"],
    },
    ReadinessItem {
        id: "world.activate",
        label: "空间确认可见",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:348",
        ready_when: "`SetVisible(true)` 之后渲染侧回执 `phase=activate`，快照里 `stage.presentation.isWorldVisible` 为 true",
        fails_when: "`phase=failed` + 任一具名 code；或 `activate` 的 revision 与已准备好的 revision 不一致（`:324` 直接 return）",
        failure_code: "world_activation_unconfirmed",
        user_copy: "空间暂时无法打开，请重新选择空间。",
        role: GateRole::Blocking,
        signal: Signal::WorldVisible,
        budget_ms: 30_000,
        depends_on: &["world.prepare"],
    },
    // ---- 摆放：网格、几何、物理、容量 --------------------------------------
    ReadinessItem {
        id: "placement.grid",
        label: "摆放网格",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:811",
        ready_when: "`OnPlacementDerived` 收到本次 `placementDeriveID` 的 `status=completed` 且 `grid != null`",
        fails_when: "派生回执 `status != completed` 或 grid 为空（`:812`）；校验服务忙 50/100 次重试后仍拒（`:782`/`:798`）",
        failure_code: "world_grid_unavailable",
        user_copy: "真实空间网格生成失败，摆放尚未启用。",
        role: GateRole::Preflight,
        signal: Signal::PlacementGeometry,
        budget_ms: 20_000,
        depends_on: &["world.activate"],
    },
    ReadinessItem {
        id: "placement.geometry",
        label: "物件碰撞几何",
        source: "apps/unity-player/Assets/GMGN/WorldInteraction/PlacementRequestBuilder.cs:81",
        ready_when: "每一个已启用物件的 `MeshFilter.sharedMesh` 都非空且 `isReadable`，因此 `unavailable` 为空",
        fails_when: "某个物件的网格不可读（`nonreadableMesh`，`:81`）、没有 MeshFilter（`noMeshFilters`，`:89`）、或权威里有但场景里没有（`unmodelledProp:<id>`，`:117`）",
        failure_code: "placement_geometry_unavailable",
        user_copy: "有空间物件尚未载入，这次调整已取消。",
        role: GateRole::Preflight,
        signal: Signal::PlacementGeometry,
        budget_ms: 20_000,
        depends_on: &["world.activate"],
    },
    ReadinessItem {
        id: "placement.calibration",
        label: "碰撞模型校准",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:770",
        ready_when: "碰撞模型可读（`PlacementGeometry.cs:122` 的 `isReadable` 通过），且非舱室世界有显式校准",
        fails_when: "模型未保留几何数据（`PlacementGeometry.cs:122`）、缺校准（`WorldRuntimeBridge.cs:770`）、空间包缺碰撞模型（`PlacementGeometry.cs:36`/`:103`）",
        failure_code: "collision_model_unreadable",
        user_copy: "碰撞模型未保留几何数据，请启用 GLTFAST_KEEP_MESH_DATA 后重新构建。",
        role: GateRole::Preflight,
        signal: Signal::PlacementGeometry,
        budget_ms: 20_000,
        depends_on: &["world.activate"],
    },
    ReadinessItem {
        id: "world.physics",
        label: "物理探针",
        source: "apps/unity-player/Assets/GMGN/WorldPhysicsProbeBridge.cs:54",
        ready_when: "`ready=true` 且 `physics.IsValid()`；每个 restored 物件的网格非空且 `isReadable`",
        fails_when: "物件实例为空 / 没有 MeshFilter / 网格不可读 / 场景物理无效 / 几何非有限（`:54`、`:57`、`:66`）",
        failure_code: "world_physics_not_ready",
        user_copy: "空间物理尚未就绪，动作暂时无法验证。",
        role: GateRole::Preflight,
        signal: Signal::PhysicsProbe,
        budget_ms: 20_000,
        depends_on: &["world.activate"],
    },
    ReadinessItem {
        id: "prop.capability",
        label: "落点与能力容量",
        source: "services/gmgn-taskd/src/world_prop_capability.rs:261",
        ready_when: "发起前本地校验：`waypoints` 是长度 1…64 的数组、每个 waypoint 有唯一非空 `id` 与布尔 `enabled`、`position` 是有限三元组",
        fails_when: "waypoints 不是数组或超过 64 个（权威侧 `prop_capability_capacity`，`:261`）；几何/模板非法则是同族的 `prop_capability_invalid_geometry` / `_unsupported_template`",
        failure_code: "prop_capability_capacity",
        user_copy: "物件落点过多，这次摆放已取消。",
        role: GateRole::Preflight,
        signal: Signal::PlacementSurface,
        budget_ms: 10_000,
        depends_on: &["world.activate"],
    },
    // ---- 居民会话与队列 -----------------------------------------------------
    ReadinessItem {
        id: "resident.session",
        label: "居民会话",
        source: "apps/macos/RenderHost/ResidentConversationBridge.swift:188",
        ready_when: "`worldServices` 已建且 `isCurrent()`；`stage.presentation.chatAvailable` 为 true",
        fails_when: "空间服务没建起来（`:188`「空间服务尚未就绪」）、会话正在切换（`:183`「空间正在切换」）、后端是 `codex` 且没有世界服务（`:597`）",
        failure_code: "resident_session_unavailable",
        user_copy: "空间服务尚未就绪，消息已保留。",
        role: GateRole::Blocking,
        signal: Signal::ResidentSession,
        budget_ms: 45_000,
        depends_on: &["world.activate"],
    },
    ReadinessItem {
        id: "resident.agent",
        label: "原生 Agent 连接",
        source: "apps/macos/RenderHost/ResidentConversationBridge.swift:606",
        ready_when: "`RenderHostDSHConnector` 建得起来（原生 DSH 安装被找到）",
        fails_when: "现有 Agent 的原生连接未就绪（`:606`）、后端不支持（`:605`）、原生连接只能退回 headless（`:607`，明确拒绝）",
        failure_code: "resident_agent_unavailable",
        user_copy: "现有 Agent 的原生连接尚未就绪，请检查 DeepSeek Harness 安装。",
        role: GateRole::Blocking,
        signal: Signal::ResidentSession,
        budget_ms: 45_000,
        depends_on: &["world.activate"],
    },
    ReadinessItem {
        id: "resident.queue",
        label: "队列可领取",
        source: "services/gmgn-taskd/src/agent_scheduler.rs:283",
        ready_when: "该 world+scope 没有真正在飞的回合（`state IN ('claimed','cancel_requested')` 为空）、`agent_loop_configure` 的 `hostSessionID` 与本次一致、`available` 为 true 且 `editing` 为 false",
        fails_when: "上一次的回合仍在 `claimed`/`cancel_requested`（`:283` 的 `executing`）或 `editing`（`:262`）⇒ `agent_loop_claim` 只回答 `claimed:false`；`unknown` **不再**挡（`:284` 起的那段注释就是 2026-10-09 的修复）",
        failure_code: "resident_queue_blocked",
        user_copy: "居民正在处理上一条，这条消息已排好队。",
        role: GateRole::Blocking,
        signal: Signal::ResidentSession,
        budget_ms: 30_000,
        depends_on: &["world.activate"],
    },
    // ---- 界面层各页需要的数据 ----------------------------------------------
    ReadinessItem {
        id: "ui.chat",
        label: "聊天面板",
        source: "apps/gpui-ui/src/chat.rs:67",
        ready_when: "快照 `transcript` 与 `reply` 可读，`contextID` 已确定",
        fails_when: "麦克风授权未完成（`microphone_permission_pending`，`:67`）、语音识别未配置（`:68`）、服务不可用（`:69`）——这三条都是**发起语音时**的状态，不是面板数据",
        failure_code: "chat_surface_unavailable",
        user_copy: "语音识别服务暂不可用，请稍后重试。",
        role: GateRole::Preflight,
        signal: Signal::ResidentSession,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.inbox",
        label: "通知",
        source: "apps/gpui-app/src/main.rs:509",
        ready_when: "快照 `inbox.entries` 是数组（可以是空）",
        fails_when: "宿主没把 `inbox` 投影出来；此时未读数是 0，而不是「没有通知」",
        failure_code: "inbox_projection_missing",
        user_copy: "通知列表暂时读不出来，稍后会自己刷新。",
        role: GateRole::Preflight,
        signal: Signal::InboxProjection,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.props",
        label: "我的物件",
        source: "apps/gpui-ui/src/stage_panels/props.rs:93",
        ready_when: "快照 `propEditor` 可读；`rooms` 列表与 `placed` 列表都是数组",
        fails_when: "`propEditor` 没到，或 `stage.presentation.propsAvailable` 为 false",
        failure_code: "prop_editor_projection_missing",
        user_copy: "这个房间里的物件暂时读不出来。",
        role: GateRole::Preflight,
        signal: Signal::PlacementSurface,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.program",
        label: "节目单",
        source: "apps/gpui-app/src/main.rs:758",
        ready_when: "快照 `liveCamPlayerMenu` 与 `musicLibrary` 都可读（`loaded`/`total` 有值）",
        fails_when: "宿主还没建播放器菜单（`:707`「播放器尚未准备好」）或音乐库没加载",
        failure_code: "player_menu_unavailable",
        user_copy: "播放器尚未准备好",
        role: GateRole::Preflight,
        signal: Signal::PlayerMenu,
        budget_ms: 20_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.playlist",
        label: "歌单与节目",
        source: "apps/gpui-app/src/main.rs:511",
        ready_when: "快照 `stageProgramRail` 可读：`programs` / `playlists` / `tracks` 都是数组",
        fails_when: "音乐库投影没到；此时节目单是空列表，而不是「还没有节目」",
        failure_code: "program_rail_projection_missing",
        user_copy: "歌单暂时读不出来，稍后会自己刷新。",
        role: GateRole::Preflight,
        signal: Signal::MusicLibrary,
        budget_ms: 20_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.tv",
        label: "电视与屏幕",
        source: "apps/gpui-app/src/main.rs:816",
        ready_when: "快照 `screenOperation.available` 与 `screenVideo.screens` 都已判定（可以是「这个空间没有电视」）",
        fails_when: "投影没到，于是 `available` 读成 false、按钮文案变成「这块空间里还没有在放的电视」——把「没数据」说成「没电视」",
        failure_code: "screen_projection_missing",
        user_copy: "这块空间里还没有在放的电视",
        role: GateRole::Preflight,
        signal: Signal::ScreenProjection,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.settings",
        label: "设置页",
        source: "apps/gpui-app/src/main.rs:524",
        ready_when: "快照 `settings` 可读，且 `presence` / `generation` 子块都在",
        fails_when: "设置投影没到；此时页面显示「该页面尚未完成 Unity 运行时接线。」而不是真实配置",
        failure_code: "settings_projection_missing",
        user_copy: "该页面尚未完成 Unity 运行时接线。",
        role: GateRole::Preflight,
        signal: Signal::SettingsProjection,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.stage",
        label: "舞台面板",
        source: "apps/gpui-app/src/main.rs:510",
        ready_when: "快照 `stage` 可读：`presentation` / `mode` / `space` / `activities` / `player` 都在",
        fails_when: "舞台投影没到；此时空间页显示「正在载入空间，完成后自动进入…」（`apps/gpui-ui/src/stage_panels.rs:1702`）——那正是这个加载态要取代的东西",
        failure_code: "stage_projection_missing",
        user_copy: "正在载入空间，完成后自动进入…",
        role: GateRole::Preflight,
        signal: Signal::StageProjection,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.activities",
        label: "生活活动",
        source: "apps/gpui-ui/src/stage_panels.rs:186",
        ready_when: "快照 `activities.canRun` 是布尔，`items` 是数组（空数组 = 这个空间没配活动）",
        fails_when: "投影没到；此时文案是「这个空间还没有配置生活活动。」——把「没数据」说成「没配活动」",
        failure_code: "activity_projection_missing",
        user_copy: "这个空间还没有配置生活活动。",
        role: GateRole::Preflight,
        signal: Signal::ActivityCatalog,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "ui.screen_operation",
        label: "屏幕操作",
        source: "apps/gpui-app/src/main.rs:395",
        ready_when: "快照 `screenOperation` 可读，且 `stage.presentation.taskFeedbackVisible` 已判定",
        fails_when: "投影没到；此时每次场景操作都会被报成「场景操作尚未确认完成，请检查当前状态。」",
        failure_code: "screen_operation_projection_missing",
        user_copy: "场景操作尚未确认完成，请检查当前状态。",
        role: GateRole::Preflight,
        signal: Signal::ScreenProjection,
        budget_ms: 15_000,
        depends_on: &["host.snapshot"],
    },
    // ---- 生成服务：能提前确认 -------------------------------------------------
    ReadinessItem {
        id: "generation.health",
        label: "许愿生成服务",
        source: "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift:18",
        ready_when: "`GET /health` 返回 `status == \"api_ready\"` 且 `generation.ready`（5 s 超时，`:14`）",
        fails_when: "服务没配（`generation_not_configured`）、连不上、`generation.reason == \"shared_memory_busy\"`（`:17`「正在等待生成资源」）或其它未就绪",
        failure_code: "generation_not_ready",
        user_copy: "服务已连接，生成暂未就绪，请稍后再检测。",
        role: GateRole::Preflight,
        signal: Signal::GenerationService,
        budget_ms: 10_000,
        depends_on: &["host.snapshot"],
    },
    ReadinessItem {
        id: "window.mode",
        label: "窗口形态",
        source: "apps/gpui-app/src/main.rs:711",
        ready_when: "当前形态（大窗 / 小窗）建得出来，而且**这一形态**的渲染面已经挂上：`main_window` 指向当前形态，`surface_mounted` 在最近一次形态下重新为 true",
        fails_when: "`cx.open_window` 失败（`:704`「窗口切换未完成。」）；或上一次切换没结算，`profile_switch_pending` 让后续切换被**静默**忽略（`:668` `if self.profile_switch_pending { return; }`）",
        failure_code: "profile_window_unavailable",
        user_copy: "窗口切换未完成。",
        role: GateRole::Blocking,
        signal: Signal::HostSurface,
        budget_ms: 20_000,
        depends_on: &["host.core"],
    },
    ReadinessItem {
        id: "cache.scene",
        label: "场景缓存",
        source: "apps/unity-player/Assets/GMGN/GaussianWorld/GaussianWorldView.cs:114",
        ready_when: "`[GaussianWorld] show cached=True`（或 marble 路径的 `ShowFormalMarble` 返回 true）——背景的 GPU 资源是热的，进门之后不会再解一次",
        fails_when: "缓存没命中（`cached=False`，冷启动实测 23.75 ms 解一次）；若这一步卡在 `WorldPrepareDeferAgent` 的 defer 循环里，`step=scene` 会一直不出下一行（`:383`）",
        failure_code: "scene_cache_cold",
        user_copy: "场景缓存未命中，第一次进空间会慢一点。",
        role: GateRole::Preflight,
        signal: Signal::WorldVisible,
        budget_ms: 20_000,
        depends_on: &["world.activate"],
    },
    // ---- 只能进门之后做的 -----------------------------------------------------
    ReadinessItem {
        id: "wish.download",
        label: "许愿产物下载",
        source: "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift:226",
        ready_when: "job `stage == .ready` 且 `modelPath` 真的在磁盘上（`:898`）",
        fails_when: "`stage != .ready`，即下载/检查还没做完（`:226`「物品还未完成下载检查」）",
        failure_code: "wish_control_not_ready",
        user_copy: "物品还未完成下载检查，暂时不能领取。",
        role: GateRole::Deferred,
        signal: Signal::WishProjection,
        budget_ms: 0,
        depends_on: &[],
    },
    ReadinessItem {
        id: "wish.claim",
        label: "许愿领取与摆放",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift:990",
        ready_when: "摆放面板已接到世界里（`worldSession` 在）且挂点已提交",
        fails_when: "面板没接到世界（`:990`「空间会话未就绪」）、没接到许愿任务上（`:961`）、当前空间拿不到摆放几何（`:204`）",
        failure_code: "wish_placement_revoked",
        user_copy: "摆放面板还没有接到世界里（空间会话未就绪），这次挂点没有提交。请关掉面板重开一次。",
        role: GateRole::Deferred,
        signal: Signal::WishProjection,
        budget_ms: 0,
        depends_on: &[],
    },
    ReadinessItem {
        id: "wish.inventory_save",
        label: "许愿入库回执",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift:346",
        ready_when: "入库回执已确认（`ResidentOwnershipProjection` 的 `hasAssetFailure` 为 false）",
        fails_when: "回执未确认或资产失败（`:346`/`:347`「资产未就绪」、`GMGNRadioApp.swift:5224`「入库回执尚未确认」）",
        failure_code: "inventory_not_confirmed",
        user_copy: "已入库，资产未就绪",
        role: GateRole::Deferred,
        signal: Signal::WishProjection,
        budget_ms: 0,
        depends_on: &[],
    },
    ReadinessItem {
        id: "media.voice_input",
        label: "按住说话的授权",
        source: "apps/gpui-ui/src/chat.rs:67",
        ready_when: "麦克风授权已给出、ASR 已配置",
        fails_when: "系统授权提示还没被回答（`microphone_permission_pending`）、ASR 没配（`asr_configuration_missing`）",
        failure_code: "microphone_permission_pending",
        user_copy: "麦克风授权尚未完成，请确认系统授权提示。",
        role: GateRole::Deferred,
        signal: Signal::ResidentSession,
        budget_ms: 0,
        depends_on: &[],
    },
];

/// 按 id 找清单项。
pub fn readiness_item(id: &str) -> Option<&'static ReadinessItem> {
    STARTUP_ITEMS.iter().find(|item| item.id == id)
}

// ---------------------------------------------------------------------------
// 观测到的信号
// ---------------------------------------------------------------------------

/// 宿主当前**真实观测到**的就绪集合。
///
/// 它是纯数据：`from_snapshot` 只读快照键，所以"什么算就绪"这件事可以在没有窗口、
/// 没有 Unity、没有设备的情况下用一份 JSON 断言。
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StartupSignals {
    ready: BTreeSet<Signal>,
}

impl StartupSignals {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn set(&mut self, signal: Signal, ready: bool) -> &mut Self {
        if ready {
            self.ready.insert(signal);
        } else {
            self.ready.remove(&signal);
        }
        self
    }
    pub fn has(&self, signal: Signal) -> bool {
        self.ready.contains(&signal)
    }
    /// 宿主自身的三个量（`ProductHost` 直接给的，不在快照里）。
    pub fn observe_host(&mut self, core: bool, snapshot: bool, surface: bool) -> &mut Self {
        self.set(Signal::HostCore, core)
            .set(Signal::HostSnapshot, snapshot)
            .set(Signal::HostSurface, surface)
    }
    /// 从宿主快照读出的项。
    ///
    /// **只认"键在且形状对"**，不认"值看起来像好了"：一个还没投影出来的块
    /// （`Null` 或缺键）不算就绪，这样"没数据"和"真的没有"不会混淆——这正是
    /// 「这块空间里还没有在放的电视」被误报的根因。
    pub fn observe_snapshot(&mut self, snapshot: &Value) -> &mut Self {
        let presentation = &snapshot["stage"]["presentation"];
        let is_world_requested = presentation["isWorldPresentationRequested"].as_bool() == Some(true);
        let is_world_visible = presentation["isWorldVisible"].as_bool() == Some(true);
        self.set(Signal::WorldRequested, is_world_requested && snapshot["stage"]["space"].is_object());
        self.set(Signal::WorldVisible, is_world_visible);
        // 会话"可领取"以世界真的可见为前提：`chatAvailable` 由宿主在呈现被请求时
        // 就置 true（`GMGNRadioApp.swift:782`），那时空间还没进来。
        self.set(
            Signal::ResidentSession,
            presentation["chatAvailable"].as_bool() == Some(true) && is_world_visible,
        );
        self.set(
            Signal::PlacementSurface,
            presentation["propsAvailable"].as_bool() == Some(true) && snapshot["propEditor"].is_object(),
        );
        self.set(
            Signal::StageProjection,
            snapshot["stage"].is_object() && snapshot["stage"]["mode"].is_string(),
        );
        self.set(
            Signal::ActivityCatalog,
            snapshot["activities"]["canRun"].is_boolean() && snapshot["activities"]["items"].is_array(),
        );
        self.set(Signal::InboxProjection, snapshot["inbox"]["entries"].is_array());
        self.set(Signal::WishProjection, snapshot["wish"]["entries"].is_array());
        self.set(
            Signal::ScreenProjection,
            snapshot["screenOperation"]["available"].is_boolean()
                && snapshot["screenVideo"]["screens"].is_array(),
        );
        self.set(Signal::SettingsProjection, snapshot["settings"].is_object());
        self.set(
            Signal::MusicLibrary,
            snapshot["musicLibrary"]["programs"].is_array() && snapshot["musicLibrary"]["playlists"].is_array(),
        );
        self.set(
            Signal::PlayerMenu,
            snapshot["liveCamPlayerMenu"]["canTogglePlayback"].is_boolean(),
        );
        // 这三项是宿主还没投影出来的（见模块末尾"诚实边界"）：调用方显式给，
        // 不给就一直是未就绪，于是它会在加载态里**具名**出现，而不是进门后才炸。
        self
    }
    /// **产品壳**（Unity 播放器里那条 overlay）的信封形状 → 同一批信号。
    ///
    /// 为什么需要它：装机产品的那层 GPUI 壳是
    /// `tools/fixtures/gpui-unity-overlay-probe`（打成
    /// `libgmgn_gpui_overlay_probe.dylib`），它接的是
    /// `UnityMediaHost.settingsSnapshot()` 的信封——和独立应用
    /// `apps/gpui-app` 的 `ProductHost.snapshot()` **不是同一个形状**。差别只有两处，
    /// 都不是新事实：
    ///
    /// 1. **路径**：Unity 宿主把舞台表面嵌在 `settings.stage`
    ///    （`apps/macos/UnityHost/UnityMediaHost.swift:1995` 的
    ///    `settings["stage"] = stageSnapshot(...)`），独立应用放在根上。这里只做一次
    ///    搬运，判定仍然只有 [`observe_snapshot`](Self::observe_snapshot) 那一份。
    /// 2. **同义键**：电视/播放器菜单/装修面在这层壳里由**别的投影**表达，而它们正是
    ///    这层壳真正渲染所用的键（下面逐条引到行）。凡是某个键在这层壳里根本不存在，
    ///    就**不设**对应的信号——不发明真相，那一项会按清单自己的上界**具名**落地。
    ///
    /// 面板文案与门禁登记（[`STARTUP_ITEMS`] / [`RETIRED_COPY`]）不因壳而变：两个壳
    /// 加载的是同一份清单、同一台状态机、同一个 [`StartupGatePane`]。
    pub fn observe_product_shell_envelope(&mut self, envelope: &Value) -> &mut Self {
        let settings = &envelope["settings"];
        let stage = &settings["stage"];
        let mut canonical = serde_json::Map::new();
        canonical.insert("stage".to_owned(), stage.clone());
        canonical.insert("activities".to_owned(), stage["activities"].clone());
        for key in ["settings", "inbox", "wish", "musicLibrary", "screenVideo"] {
            canonical.insert(key.to_owned(), envelope[key].clone());
        }
        self.observe_snapshot(&Value::Object(canonical));
        let presentation = &stage["presentation"];
        // 这层壳**没有** `screenOperation`（那是 AppKit/`ProductHost` 的投影，
        // `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift:1008`）。它判断"电视投影
        // 已到达"用的是 `screenVideo.screens`——就是 `media_ui.rs` 渲染电视所读的那个
        // 数组（`UnityScreenVideoBridge.swift:369` 的 `"screens": surfaces`）。同一个事实。
        self.set(
            Signal::ScreenProjection,
            envelope["screenVideo"]["screens"].is_array(),
        );
        // 这层壳**没有** `liveCamPlayerMenu`（`ProductHost.swift:177`）。它自己的
        // 播放器菜单由 `music` 的可切歌标志决定（`shell_ui.rs` 的
        // `shell_projection` 只搬 `canPrevious`/`canNext`/`isPlaying`）。
        let music = &envelope["music"];
        self.set(
            Signal::PlayerMenu,
            music["canPrevious"].is_boolean() && music["canNext"].is_boolean(),
        );
        // 这层壳**没有** `propEditor`（`ProductHost.swift:178`）。它的装修面读
        // `presentation.propsAvailable` 加自己的库存投影 `unityInventory`
        // （`inventory_ui.rs`）。两个键都必须在，且 `propsAvailable` 必须为真。
        self.set(
            Signal::PlacementSurface,
            presentation["propsAvailable"].as_bool() == Some(true)
                && envelope["unityInventory"].is_object(),
        );
        self
    }
}

// ---------------------------------------------------------------------------
// 状态机
// ---------------------------------------------------------------------------

/// 一项在加载态里的状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StepPhase {
    /// 依赖还没满足，还没轮到它（依赖是显式声明的，不是"按顺序排队"）。
    Waiting,
    /// 正在准备。
    Running,
    /// 已就绪。
    Ready,
    /// 判定为"本轮不可用"，**具名**，但不挡人进门（[`GateRole::Preflight`] 的结果）。
    Unavailable,
    /// **挡人的**失败：具名 + 可重试。
    Failed,
    /// 只能进门之后按需完成（[`GateRole::Deferred`]）。
    Deferred,
}

/// 一台清单项的状态。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StepState {
    pub id: &'static str,
    pub phase: StepPhase,
    /// 具名码：`Failed`/`Unavailable`/`Deferred` 一定有。
    pub code: Option<String>,
    /// 人类可读的补充（依赖谁、为什么不可用）。
    pub detail: Option<String>,
    pub started_at_ms: Option<u64>,
    pub finished_at_ms: Option<u64>,
}

/// 加载态的整体状态。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartupPhase {
    Preparing,
    Ready,
    Blocked,
}

/// 挡人的失败，**具名**。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartupFailure {
    pub step: &'static str,
    pub label: &'static str,
    pub code: String,
    pub message: String,
    pub retryable: bool,
}

/// 渲染用的一行。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StepView {
    pub id: &'static str,
    pub label: &'static str,
    pub role: GateRole,
    pub phase: StepPhase,
    pub code: Option<String>,
    pub detail: Option<String>,
}

/// 并行推进、有上限、具名失败的加载态状态机。
///
/// 纯值类型：`observe` 只吃（信号，时钟），所以整套"什么时候算好了、什么时候算超时、
/// 超时叫什么名字"都可以在没有窗口的情况下逐条断言。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartupGate {
    deadline_ms: u64,
    attempt: u32,
    attempt_started_ms: u64,
    now_ms: u64,
    steps: Vec<StepState>,
}

impl Default for StartupGate {
    fn default() -> Self {
        Self::new()
    }
}

impl StartupGate {
    /// 生产用的加载态：整体上界是 [`STARTUP_DEADLINE_MS`]。
    pub fn new() -> Self {
        Self::with_deadline(STARTUP_DEADLINE_MS)
    }
    pub fn with_deadline(deadline_ms: u64) -> Self {
        Self {
            deadline_ms,
            attempt: 1,
            attempt_started_ms: 0,
            now_ms: 0,
            steps: STARTUP_ITEMS
                .iter()
                .map(|item| StepState {
                    id: item.id,
                    phase: StepPhase::Waiting,
                    code: None,
                    detail: None,
                    started_at_ms: None,
                    finished_at_ms: None,
                })
                .collect(),
        }
    }
    pub fn deadline_ms(&self) -> u64 {
        self.deadline_ms
    }
    pub fn attempt(&self) -> u32 {
        self.attempt
    }
    pub fn elapsed_ms(&self) -> u64 {
        self.now_ms.saturating_sub(self.attempt_started_ms)
    }
    pub fn steps(&self) -> Vec<StepView> {
        self.steps
            .iter()
            .filter_map(|state| {
                readiness_item(state.id).map(|item| StepView {
                    id: item.id,
                    label: item.label,
                    role: item.role,
                    phase: state.phase,
                    code: state.code.clone(),
                    detail: state.detail.clone(),
                })
            })
            .collect()
    }
    pub fn step(&self, id: &str) -> Option<&StepState> {
        self.steps.iter().find(|state| state.id == id)
    }
    pub fn phase(&self) -> StartupPhase {
        if self.steps.iter().any(|state| {
            state.phase == StepPhase::Failed
                && readiness_item(state.id).is_some_and(|item| item.role == GateRole::Blocking)
        }) {
            return StartupPhase::Blocked;
        }
        let pending = self.steps.iter().any(|state| {
            readiness_item(state.id).is_some_and(|item| item.role != GateRole::Deferred)
                && matches!(state.phase, StepPhase::Waiting | StepPhase::Running)
        });
        if pending { StartupPhase::Preparing } else { StartupPhase::Ready }
    }
    /// `(已就绪的挡人项, 挡人项总数)`。进度条读它。
    pub fn progress(&self) -> (usize, usize) {
        let mut done = 0;
        let mut total = 0;
        for state in &self.steps {
            let Some(item) = readiness_item(state.id) else { continue };
            if item.role != GateRole::Blocking {
                continue;
            }
            total += 1;
            if matches!(state.phase, StepPhase::Ready | StepPhase::Deferred) {
                done += 1;
            }
        }
        (done, total)
    }
    pub fn fraction(&self) -> f32 {
        let (done, total) = self.progress();
        if total == 0 { 1. } else { done as f32 / total as f32 }
    }
    /// "本轮不可用"与"进门后按需"的具名清单——加载态**必须**把它们摆出来，
    /// 而不是等用户点按钮时才说。
    pub fn named(&self) -> Vec<StepView> {
        self.steps()
            .into_iter()
            .filter(|view| {
                matches!(view.phase, StepPhase::Unavailable | StepPhase::Deferred | StepPhase::Failed)
            })
            .collect()
    }
    /// 挡人的失败（第一个），**具名**。
    pub fn failure(&self) -> Option<StartupFailure> {
        self.steps.iter().find_map(|state| {
            let item = readiness_item(state.id)?;
            if state.phase != StepPhase::Failed || item.role != GateRole::Blocking {
                return None;
            }
            Some(StartupFailure {
                step: item.id,
                label: item.label,
                code: state.code.clone().unwrap_or_else(|| format!("{}_failed", item.id)),
                message: item.user_copy.to_owned(),
                retryable: true,
            })
        })
    }
    /// 推进一次。`now_ms` 是宿主给的单调时钟（毫秒）。
    ///
    /// 所有依赖已满足的项在**同一次** `observe` 里一起推进——这就是"并行"的含义：
    /// 没有任何一项在等另一项**完成**，除了 `depends_on` 显式声明的那几条。
    pub fn observe(&mut self, signals: &StartupSignals, now_ms: u64) -> StartupPhase {
        self.now_ms = now_ms;
        let elapsed_total = self.elapsed_ms();
        for index in 0..self.steps.len() {
            let item = readiness_item(self.steps[index].id).expect("every step comes from the table");
            let state = self.steps[index].clone();
            if matches!(
                state.phase,
                StepPhase::Ready | StepPhase::Unavailable | StepPhase::Failed | StepPhase::Deferred
            ) {
                continue;
            }
            if signals.has(item.signal) {
                self.finish(index, StepPhase::Ready, None, None, now_ms);
                continue;
            }
            // 依赖先判：挡人的依赖**失败**时立刻具名，不陪着等满整个上界。
            let mut blocked_by = None;
            let mut waiting_for = None;
            for dep in item.depends_on {
                let Some(dep_state) = self.steps.iter().find(|s| s.id == *dep) else { continue };
                match dep_state.phase {
                    StepPhase::Ready | StepPhase::Deferred => {}
                    StepPhase::Failed => blocked_by = Some(*dep),
                    StepPhase::Unavailable => blocked_by = Some(*dep),
                    _ => waiting_for = Some(*dep),
                }
                if blocked_by.is_some() {
                    break;
                }
            }
            if let Some(dep) = blocked_by {
                let label = readiness_item(dep).map(|item| item.label).unwrap_or(dep);
                let code = format!("{}_blocked_by_{}", item.id, dep);
                let detail = Some(format!("等待「{label}」先解决"));
                self.finish(index, StepPhase::Failed, Some(code), detail, now_ms);
                continue;
            }
            if let Some(dep) = waiting_for {
                let label = readiness_item(dep).map(|item| item.label).unwrap_or(dep);
                self.steps[index].phase = StepPhase::Waiting;
                self.steps[index].detail = Some(format!("等待「{label}」"));
                continue;
            }
            if item.role == GateRole::Deferred {
                self.finish(
                    index,
                    StepPhase::Deferred,
                    Some(format!("{}_after_entry", item.id)),
                    Some("进入空间之后按需完成，加载态里先具名".to_owned()),
                    now_ms,
                );
                continue;
            }
            if self.steps[index].started_at_ms.is_none() {
                self.steps[index].started_at_ms = Some(now_ms);
            }
            self.steps[index].phase = StepPhase::Running;
            self.steps[index].detail = None;
            let started = self.steps[index].started_at_ms.unwrap_or(now_ms);
            let elapsed_item = now_ms.saturating_sub(started);
            if elapsed_item > item.budget_ms {
                let (phase, code) = match item.role {
                    GateRole::Blocking => (StepPhase::Failed, format!("{}_timeout", item.id)),
                    _ => (StepPhase::Unavailable, format!("{}_unavailable", item.id)),
                };
                let detail = Some(format!(
                    "超过这一项的上限（{} 秒）",
                    item.budget_ms as f32 / 1000.
                ));
                self.finish(index, phase, Some(code), detail, now_ms);
                continue;
            }
            if item.role == GateRole::Blocking && elapsed_total > self.deadline_ms {
                let code = format!("{}_deadline", item.id);
                let detail = Some(format!(
                    "超过加载态整体上限（{} 秒）",
                    self.deadline_ms as f32 / 1000.
                ));
                self.finish(index, StepPhase::Failed, Some(code), detail, now_ms);
            }
        }
        self.phase()
    }
    /// 重试：只在被挡住时有意义。失败项回到 `Waiting`，整体时钟重开，
    /// **已经就绪的项保持就绪**（重试不会把做好的事作废）。
    pub fn retry(&mut self, now_ms: u64) -> bool {
        if self.phase() != StartupPhase::Blocked {
            return false;
        }
        for state in &mut self.steps {
            if state.phase == StepPhase::Failed {
                state.phase = StepPhase::Waiting;
                state.code = None;
                state.detail = None;
                state.started_at_ms = None;
                state.finished_at_ms = None;
            }
        }
        self.attempt += 1;
        self.attempt_started_ms = now_ms;
        self.now_ms = now_ms;
        true
    }
    fn finish(
        &mut self,
        index: usize,
        phase: StepPhase,
        code: Option<String>,
        detail: Option<String>,
        now_ms: u64,
    ) {
        self.steps[index].phase = phase;
        self.steps[index].code = code;
        self.steps[index].detail = detail;
        self.steps[index].finished_at_ms = Some(now_ms);
    }
}

// ---------------------------------------------------------------------------
// 加载态要收走的"没 ready"文案
// ---------------------------------------------------------------------------

/// 加载态对一条"没 ready"文案做了什么。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    /// 进门前**必须**就绪；不就绪就不放人进去（具名 + 重试）。
    Blocks,
    /// 进门前**判定并具名**；判成"本轮不可用"是允许的结果，不挡人。
    NamedAtStartup,
    /// 进门前**具名列出**，但只能进门之后按需完成。
    Deferred,
}

/// 一条"以前进门之后才看到的没 ready 文案"，绑定到清单里的一项。
///
/// 这张表是"加载态结束后不再出现这些文案"的**判据来源**：测试会逐条回到
/// `source` 那一行确认文案还在（句子挪了/删了都要重新决定），并确认 `gate_item`
/// 真的在 [`STARTUP_ITEMS`] 里且角色一致。**把一项移出加载态 ⇒ 这里的绑定悬空 ⇒ 红。**
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RetiredCopy {
    pub text: &'static str,
    pub source: &'static str,
    pub gate_item: &'static str,
    pub disposition: Disposition,
    pub why: &'static str,
}

/// 逐条登记：文案、出处、被哪一项收走、收成什么、为什么这样收。
pub const RETIRED_COPY: &[RetiredCopy] = &[
    RetiredCopy {
        text: "空间画面准备超时，当前空间已保留。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:414",
        gate_item: "world.prepare",
        disposition: Disposition::Blocks,
        why: "渲染侧 120 s 预算到期的具名结局；加载态在它之前就把这一段变成可见的步骤名，到点了仍然是同一个具名失败 + 重试。",
    },
    RetiredCopy {
        text: "空间暂时无法连接，音乐和聊天仍可使用。请重新选择空间或稍后重试。",
        source: "apps/macos/UnityHost/UnityMediaHost.swift:783",
        gate_item: "world.authority",
        disposition: Disposition::Blocks,
        why: "权威不可达是**进门前**就该知道的事（helper 冷启动），不是进去以后才弹的红字。",
    },
    RetiredCopy {
        text: "空间暂时无法打开，请重新选择空间。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:322",
        gate_item: "world.activate",
        disposition: Disposition::Blocks,
        why: "`phase=failed` 的兜底句；加载态用它的具名 code（`world_prepare_*`）当步骤结果，而不是进门后一句没人知道原因的弹窗。",
    },
    RetiredCopy {
        text: "真实空间网格生成失败，摆放尚未启用。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:812",
        gate_item: "placement.grid",
        disposition: Disposition::NamedAtStartup,
        why: "用户点「装修」时才会撞上它（2026-10-09 现场）。摆放网格是进门前就能派生并判定的：好就静默就绪，不好就在加载态里点名「摆放网格：本轮不可用」。",
    },
    RetiredCopy {
        text: "空间已载入，真实摆放网格尚未就绪；不会保存未经校验的摆放。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:803",
        gate_item: "placement.grid",
        disposition: Disposition::NamedAtStartup,
        why: "同上一条，是它的异步版本（`PrepareFormalPlacement` 的 catch）。",
    },
    RetiredCopy {
        text: "空间网格校验服务忙，摆放尚未启用。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:782",
        gate_item: "placement.grid",
        disposition: Disposition::NamedAtStartup,
        why: "50 次 ×100 ms 的重试耗尽（`:778-781`）；加载态把这段重试放进「摆放网格」这一步的预算里，耗尽了就具名。",
    },
    RetiredCopy {
        text: "有空间物件尚未载入，这次调整已取消。",
        source: "apps/unity-player/Assets/GMGN/WorldInteraction/PlacementRequestBuilder.cs:117",
        gate_item: "placement.geometry",
        disposition: Disposition::NamedAtStartup,
        why: "权威里启用但场景里没有的物件（`unmodelledProp:<id>`）。进门前枚举一遍就能逐个点名，而不是等用户拖到一半才取消。",
    },
    RetiredCopy {
        text: "这个物件的碰撞几何未载入，暂时不能移动。",
        source: "apps/unity-player/Assets/GMGN/WorldInteraction/PlacementRequestBuilder.cs:107",
        gate_item: "placement.geometry",
        disposition: Disposition::NamedAtStartup,
        why: "`nonreadableMesh` / `noMeshFilters` 的逐物件结果；加载态把不可用物件**记名**，正是用户要求的「明确地判定该物件本轮不可用并记名」。",
    },
    RetiredCopy {
        text: "空间碰撞几何未载入，暂时不能摆放。",
        source: "apps/unity-player/Assets/GMGN/WorldInteraction/PlacementRequestBuilder.cs:124",
        gate_item: "placement.geometry",
        disposition: Disposition::NamedAtStartup,
        why: "`missingGridGeometry`（网格本体没到）。它是「摆放网格」这一步的前置，加载态里就有结论。",
    },
    RetiredCopy {
        text: "真实碰撞模型缺少明确校准，摆放尚未启用。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:770",
        gate_item: "placement.calibration",
        disposition: Disposition::NamedAtStartup,
        why: "缺 `GMGN_UNITY_WORLD_COLLIDER_TRANSFORM` 是**环境**事实，进门前一读就知道，不该等到用户摆放时才发现。",
    },
    RetiredCopy {
        text: "碰撞模型未保留几何数据，请启用 GLTFAST_KEEP_MESH_DATA 后重新构建。",
        source: "apps/unity-player/Assets/GMGN/WorldPlacementGeometry/PlacementGeometry.cs:122",
        gate_item: "placement.calibration",
        disposition: Disposition::NamedAtStartup,
        why: "`mesh.isReadable` 为假是**构建期**事实（和 `PlacementRequestBuilder.cs:81` 同族）。加载态一读即可判定，并把该物件记名。",
    },
    RetiredCopy {
        text: "空间备份缺少真实碰撞模型，暂时不能摆放。",
        source: "apps/unity-player/Assets/GMGN/WorldPlacementGeometry/PlacementGeometry.cs:103",
        gate_item: "placement.calibration",
        disposition: Disposition::NamedAtStartup,
        why: "空间包/备份里根本没有碰撞参考；这是进门前的静态事实。",
    },
    RetiredCopy {
        text: "摆放网格着色器缺失，预览暂不可用。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:818",
        gate_item: "placement.grid",
        disposition: Disposition::NamedAtStartup,
        why: "资源加载失败，和网格同一步骤里就能发现。",
    },
    RetiredCopy {
        text: "空间服务尚未就绪，消息已保留。",
        source: "apps/macos/RenderHost/ResidentConversationBridge.swift:188",
        gate_item: "resident.session",
        disposition: Disposition::Blocks,
        why: "用户发一条消息才发现世界服务没建起来——这在进门前就是「居民会话」这一步，没就绪就不该放人进去聊天。",
    },
    RetiredCopy {
        text: "当前空间服务尚未就绪。",
        source: "apps/macos/RenderHost/ResidentConversationBridge.swift:597",
        gate_item: "resident.session",
        disposition: Disposition::Blocks,
        why: "后台轮次的同一件事（`worldUnavailable`），同一个步骤。",
    },
    RetiredCopy {
        text: "现有 Agent 的原生连接尚未就绪，请检查 DeepSeek Harness 安装。",
        source: "apps/macos/RenderHost/ResidentConversationBridge.swift:606",
        gate_item: "resident.agent",
        disposition: Disposition::Blocks,
        why: "原生连接能不能建起来是进门前可判定的（装没装 DSH）；不该等到发消息才报。",
    },
    RetiredCopy {
        text: "空间正在切换，请稍后再发送。",
        source: "apps/macos/RenderHost/ResidentConversationBridge.swift:183",
        gate_item: "resident.session",
        disposition: Disposition::Blocks,
        why: "切换期间发消息被拒；加载态本身就不让人在切换时说第一句话。",
    },
    RetiredCopy {
        text: "服务已连接，生成暂未就绪，请稍后再检测。",
        source: "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift:18",
        gate_item: "generation.health",
        disposition: Disposition::NamedAtStartup,
        why: "`GET /health` 5 s 超时就能问出来，进门前问一次即可；问出来不 ready 就具名（含 `shared_memory_busy` 那个分支）。",
    },
    RetiredCopy {
        text: "正在载入空间，完成后自动进入…",
        source: "apps/gpui-ui/src/stage_panels.rs:1702",
        gate_item: "world.activate",
        disposition: Disposition::Blocks,
        why: "这正是「到处暴露没 ready」的样本：舞台面板自己转圈。它说的就是「空间还没激活」这件事，所以绑定到真正挡人的 `world.activate`——进门前空间就确认可见，进去之后这个面板不该再出现这句话。",
    },
    RetiredCopy {
        text: "播放器尚未准备好",
        source: "apps/gpui-app/src/main.rs:758",
        gate_item: "ui.program",
        disposition: Disposition::NamedAtStartup,
        why: "播放器菜单是宿主投影，进门前可判定；菜单标题不该是「尚未准备好」。",
    },
    RetiredCopy {
        text: "这个空间还没有配置生活活动。",
        source: "apps/gpui-ui/src/stage_panels.rs:186",
        gate_item: "ui.activities",
        disposition: Disposition::NamedAtStartup,
        why: "「没数据」与「真的没配」被混为一谈；加载态把 `activities` 是否投影出来判定清楚，空列表才是真的没配。",
    },
    RetiredCopy {
        text: "该页面尚未完成 Unity 运行时接线。",
        source: "apps/gpui-ui/src/i18n.rs:70",
        gate_item: "ui.settings",
        disposition: Disposition::NamedAtStartup,
        why: "设置页的兜底句；设置投影进门前可判定，所以它不该是用户看到的第一句话。",
    },
    RetiredCopy {
        text: "该服务尚未配置凭据，请填写后保存",
        source: "apps/gpui-ui/src/i18n.rs:310",
        gate_item: "generation.health",
        disposition: Disposition::NamedAtStartup,
        why: "「没配凭据」是 `generation.health` 这一步能判出来的具名结果（`generation_not_configured`），进门前说，别在用户点生成时兜头一句。",
    },
    RetiredCopy {
        text: "尚未配置生成服务",
        source: "apps/gpui-ui/src/i18n.rs:362",
        gate_item: "generation.health",
        disposition: Disposition::NamedAtStartup,
        why: "同上（`generation_not_configured` 的面板文案）。",
    },
    RetiredCopy {
        text: "服务已连接，正在等待生成资源。",
        source: "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift:17",
        gate_item: "generation.health",
        disposition: Disposition::NamedAtStartup,
        why: "`shared_memory_busy` 的具名分支；加载态问一次就知道要等，进门后不该再让用户自己点「检测」才发现。",
    },
    RetiredCopy {
        text: "这个原有功能入口暂未能打开，请检查应用启动状态。",
        source: "apps/gpui-app/src/main.rs:565",
        gate_item: "host.core",
        disposition: Disposition::Blocks,
        why: "「应用启动状态」本来就是加载态该回答的问题；启动没完成就不放人进去，于是这句话在门内不可能出现。",
    },
    RetiredCopy {
        text: "窗口切换未完成。",
        source: "apps/gpui-app/src/main.rs:711",
        gate_item: "window.mode",
        disposition: Disposition::Blocks,
        why: "小窗/大窗切换失败时的一次性兜底；加载态在进门前就确认当前形态建得出来、面挂得上，于是它不可能成为进门后的第一句话。`profile_switch_pending` 那条静默忽略（`:668`）也由同一项的上界兜住。",
    },
    RetiredCopy {
        text: "正在连接原应用场景…",
        source: "apps/gpui-app/src/main.rs:423",
        gate_item: "host.surface",
        disposition: Disposition::Blocks,
        why: "它是现在的「加载态」——一条没有进度、没有上界、没有失败名的通知。这一层把它变成有步骤名和上限的加载界面。",
    },
    RetiredCopy {
        text: "应用返回的对话状态无法读取，文字已保留。",
        source: "apps/gpui-app/src/main.rs:470",
        gate_item: "host.snapshot",
        disposition: Disposition::Blocks,
        why: "第一个快照解析不了等于宿主没起来；这是进门前的 `host.snapshot`，不是用户发消息之后的报错。",
    },
    RetiredCopy {
        text: "设置操作尚未确认完成，请检查当前配置。",
        source: "apps/gpui-app/src/main.rs:407",
        gate_item: "ui.settings",
        disposition: Disposition::NamedAtStartup,
        why: "和「场景操作尚未确认完成」同一族：设置面板的命令被拒时的兜底。投影没到才会这样，`ui.settings` 在进门前判定。",
    },
    RetiredCopy {
        text: "场景操作尚未确认完成，请检查当前状态。",
        source: "apps/gpui-app/src/main.rs:395",
        gate_item: "ui.screen_operation",
        disposition: Disposition::NamedAtStartup,
        why: "它是「操作没有被宿主接受」的兜底句，根因往往是投影没到；加载态先把投影判定清楚，可用的操作不会被动变成这句话。",
    },
];

/// 今天**没有任何用户可见文案**的挡人项。
///
/// 它们以前是**静默**失败（或者只说别的事），所以没有"被收走的句子"可以绑到
/// [`RETIRED_COPY`]。加载态必须替它们说话：每一条都写明"以前静默在哪一行"。
/// 这张表的作用是让"Blocking 却没人替它说话"这件事**不可能悄悄发生**——
/// 测试要求每个挡人项要么在 [`RETIRED_COPY`] 里，要么在这里具名。
pub const SILENT_BEFORE_THE_GATE: &[(&str, &str)] = &[
    (
        "resident.queue",
        "services/gmgn-taskd/src/agent_scheduler.rs:283 在真的在飞时只回答 `claimed:false`；宿主侧一次 `chat.send` \
         就此静默——2026-10-09 现场「消息发出去、回合不被领取」，界面上没有一句话。加载态在进门前把 \
         `executing` / `editing` / `hostSessionID` 三件事判定清楚并具名。",
    ),
    (
        "resident.session",
        "同一件事的另一半：`ResidentConversationBridge.swift:183` 的「空间正在切换」只在用户正好在切的时候出现， \
         `:188` 才是常态——所以这一项同时有 [`RETIRED_COPY`] 的绑定和这里的静默登记。",
    ),
];

/// 这台加载态**自己**的登记表常量名。
///
/// 扫描前它们会被整体抹白（否则登记表会扫到自己）。这份名单是**唯一**来源：
/// 门禁测试读它，而不是另写一遍——两份名单就会漂移，而漂移的那一份会让扫描
/// 静默扫回自己。
pub const REGISTRY_CONST_NAMES: &[&str] = &[
    "STARTUP_ITEMS",
    "RETIRED_COPY",
    "ALLOWED_AFTER_READY",
    "NOT_READY_PATTERNS",
    "SILENT_BEFORE_THE_GATE",
];

/// 扫描器认的**"没 ready"句式**。凡是 `SCANNED_SOURCES` 里的字符串字面量命中
/// 其中一条，就必须在 [`RETIRED_COPY`] 或 [`ALLOWED_AFTER_READY`] 里有登记——
/// 否则 `tests/startup_readiness_gate.rs` 变红。
pub const NOT_READY_PATTERNS: &[&str] = &[
    "尚未",
    "未就绪",
    "还没有",
    "暂未",
    "暂时不",
    "暂时不能",
    "还不能",
    "没有接到",
    "不能领取",
    "稍后再",
    "准备好",
    "不可用",
    "等待",
    "没有配置",
    "正在载入",
    "无法连接",
    "读不出来",
];

/// 一条"看着像没 ready，其实本来就不是启动阶段的事"的豁免。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Allowance {
    pub text: &'static str,
    pub source: &'static str,
    pub why: &'static str,
}

/// 豁免清单。每条都写明理由；空理由不算登记。
pub const ALLOWED_AFTER_READY: &[Allowance] = &[
    Allowance {
        text: "等待居民回应…",
        source: "apps/gpui-ui/src/state.rs:130",
        why: "这是**正在进行**的对话状态（轮次在飞），不是「没 ready」；加载态不该等一条回复。",
    },
    Allowance {
        text: "麦克风授权尚未完成，请确认系统授权提示。",
        source: "apps/gpui-ui/src/chat.rs:67",
        why: "系统授权只能在用户第一次按麦克风时申请（红线：不触发钥匙串/不合成输入），因此是 Deferred 那一项的运行时文案。",
    },
    Allowance {
        text: "语音识别尚未配置，请检查按住说话设置。",
        source: "apps/gpui-ui/src/chat.rs:68",
        why: "同上的配置类文案，属于用户自己的设置，不是启动就绪项。",
    },
    Allowance {
        text: "语音识别服务暂不可用，请稍后重试。",
        source: "apps/gpui-ui/src/chat.rs:69",
        why: "一次语音请求的瞬时失败，必须仍然是失败（不放宽语义）。",
    },
    Allowance {
        text: "当前不可用",
        source: "apps/gpui-ui/src/settings.rs:305",
        why: "某一行的瞬时不可用标记；具体是哪一行由 `ui.settings` 之外的实时状态决定。",
    },
    Allowance {
        text: "等待渲染",
        source: "apps/gpui-ui/src/settings.rs:2505",
        why: "设置里一项**实时**状态读数（渲染器正在处理），不是启动就绪项。",
    },
    Allowance {
        text: "本机等待已取消，远端生成可能继续；可恢复原任务。",
        source: "apps/gpui-ui/src/settings.rs:646",
        why: "用户主动取消等待之后的说明，只能在用户动手之后出现。",
    },
    Allowance {
        text: "取消本机等待",
        source: "apps/gpui-ui/src/settings.rs:3378",
        why: "控件文案（按钮），不是状态。",
    },
    Allowance {
        text: "取消仅停止本机等待，远端生成可能继续并计费。",
        source: "apps/gpui-ui/src/settings.rs:3394",
        why: "确认文案，只能在用户动手之后出现。",
    },
    Allowance {
        text: "该服务尚未配置凭据，请填写后保存",
        source: "apps/gpui-ui/src/settings.rs:4065",
        why: "与 `generation.health` 收走的那条同源（i18n 表），但这条在**设置页**里当字段提示用；`generation.health` 已绑定同一句，这里只豁免设置页的呈现位置。",
    },
    Allowance {
        text: "空间有新的保存记录，这次修改尚未保存，仍保留在当前窗口。请稍后重试保存。",
        source: "apps/gpui-app/src/main.rs:53",
        why: "revision 冲突的**保存**结果，只能在用户改了东西之后出现。",
    },
    Allowance {
        text: "此操作暂未完成，请重试。",
        source: "apps/gpui-app/src/main.rs:456",
        why: "一次具体操作的失败回执（必须仍然是失败），不是启动就绪项。",
    },
    Allowance {
        text: "应用尚未确认接收，无法交付这条回复。",
        source: "apps/gpui-app/src/main.rs:494",
        why: "一轮对话的协议顺序错误（必须仍然是错误），发生在用户发消息之后。",
    },
    Allowance {
        text: "还没有可显示的角色",
        source: "apps/gpui-app/src/main.rs:577",
        why: "用户还没选角色的引导弹窗标题——是数据状态，不是 ready 问题。",
    },
    Allowance {
        text: "物件编辑尚未关闭，请重试。",
        source: "apps/gpui-app/src/main.rs:621",
        why: "关闭装修被拒的回执，发生在用户已经进门并打开装修之后。",
    },
    Allowance {
        text: "这块空间里还没有在放的电视",
        source: "apps/gpui-app/src/main.rs:816",
        why: "它是「这个空间没有电视」的正确说法，保留；加载态的 `ui.tv` 只负责别让「投影没到」被说成这句话。",
    },
    Allowance {
        text: "该页面尚未完成 Unity 运行时接线。",
        source: "apps/macos/UnityHost/UnityMediaHost.swift:1986",
        why: "Unity 宿主侧的同一句兜底；`ui.settings` 已绑定 UI 层那一份，这里只豁免宿主副本的呈现位置。",
    },
    Allowance {
        text: "尚未选择角色",
        source: "apps/gpui-ui/src/i18n.rs:116",
        why: "「还没选角色」是合法状态（默认值），不是 ready 问题。",
    },
    Allowance {
        text: "人物位置尚未完成空间持久确认。",
        source: "apps/gpui-ui/src/i18n.rs:107",
        why: "一次**移动**操作的回执语义，只能在用户移动角色之后出现。",
    },
    Allowance {
        text: "此设置尚未接入 Unity；角色、快捷键、视频与空间活动仍由原应用管理。",
        source: "apps/gpui-ui/src/i18n.rs:266",
        why: "一块**未迁移**的设置说明（功能缺口，不是就绪问题）；回答它需要迁移，不是加载态。",
    },
    Allowance {
        text: "当前可管理语音配置和试听；Unity 按住说话及回复朗读尚未接入。",
        source: "apps/gpui-ui/src/i18n.rs:313",
        why: "同上，语音迁移缺口说明。",
    },
    Allowance {
        text: "Codex CLI 不可用",
        source: "apps/gpui-ui/src/i18n.rs:82",
        why: "后端选择的实时可用性（用户可换后端），不是启动阻塞项。",
    },
    Allowance {
        text: "Unity 设置连接不可用，请从 Unity 重新打开。",
        source: "apps/gpui-ui/src/i18n.rs:86",
        why: "Unity 设置窗口自己的连接错误；它是那个窗口的**失败回执**（必须仍然失败）。",
    },
    Allowance {
        text: "人物正在移动，等待空间与画面确认。",
        source: "apps/gpui-ui/src/i18n.rs:102",
        why: "一次移动操作的进行态。",
    },
    Allowance {
        text: "取消本机等待",
        source: "apps/gpui-ui/src/i18n.rs:215",
        why: "控件文案的 i18n 表项（与 `settings.rs:3378` 同一句）。",
    },
    Allowance {
        text: "取消仅停止本机等待，远端生成可能继续并计费。",
        source: "apps/gpui-ui/src/i18n.rs:216",
        why: "确认文案的 i18n 表项。",
    },
    Allowance {
        text: "本机等待已取消，远端生成可能继续；可恢复原任务。",
        source: "apps/gpui-ui/src/i18n.rs:224",
        why: "用户取消之后的说明（i18n 表项）。",
    },
    Allowance {
        text: "此功能尚未接入 Unity，原设置保持不变。",
        source: "apps/gpui-app/src/unity_settings_transport.rs:28",
        why: "未迁移设置项的一次**拒绝回执**（必须仍然是拒绝），不是就绪问题。",
    },
    Allowance {
        text: "生成资产清单尚未同步，原库存记录已保留。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:314",
        why: "准备阶段内部的一致性异常（清单与库存不匹配）；它只在 `world.prepare` 这一步内部发生，加载态把整步的结局具名。",
    },
    Allowance {
        text: "这个空间的背景格式尚未接入运行时切换，当前空间已保留。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:396",
        why: "格式不支持是**真失败**（不放宽），且已经在 `world.prepare` 的预算内，具名后由加载态呈现。",
    },
    Allowance {
        text: "空间物件尚未完整载入。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:406",
        why: "同上：`world.prepare` 内部的真失败，加载态把整步结局具名。",
    },
    Allowance {
        text: "手持模型的握持坐标尚未准备。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:531",
        why: "**手持**（拿在手里）的先决条件，只能在用户拿起一件东西之后才有意义。",
    },
    Allowance {
        text: "新物件暂未载入，原库存和空间数据已保留。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:591",
        why: "生成/导入一件新物件的**刷新**结果，发生在用户动手之后。",
    },
    Allowance {
        text: "空间权威快照尚未读取，请稍后打开。",
        source: "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs:629",
        why: "权威快照读取尚未完成时的拒绝；`world.authority` 这一步就是它的前置。",
    },
    Allowance {
        text: "空间包包含多个碰撞模型，尚未指定组合规则。",
        source: "apps/unity-player/Assets/GMGN/WorldPlacementGeometry/PlacementGeometry.cs:28",
        why: "空间包的**内容缺陷**（真失败，不放宽）；`placement.calibration` 在进门前判定并具名。",
    },
    Allowance {
        text: "空间包缺少真实碰撞模型，暂时不能摆放。",
        source: "apps/unity-player/Assets/GMGN/WorldPlacementGeometry/PlacementGeometry.cs:36",
        why: "与 `placement.calibration` 同一件事的另一个入口（`LoadBundledCabin`）。",
    },
    Allowance {
        text: "这个物件的碰撞几何未载入，暂时不能移动。",
        source: "apps/unity-player/Assets/GMGN/WorldInteraction/PlacementRequestBuilder.cs:107",
        why: "逐物件不可用；`placement.geometry` 在进门前把它记名。",
    },
    Allowance {
        text: "摆放面板还没有接到许愿任务上（宿主还没接线），这一次没有提交。",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift:961",
        why: "许愿任务尚未创建时才出现，只能在用户发起许愿之后。",
    },
    Allowance {
        text: "物品还未完成下载检查，暂时不能领取。",
        source: "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift:226",
        why: "`wish.download` 那一项已声明为 Deferred：下载只在用户许愿之后发生，加载态只把它**具名列出**。",
    },
    Allowance {
        text: "另一项生成请求仍在处理中，本次操作尚未发送，请稍后重试。",
        source: "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift:225",
        why: "一次生成提交的忙拒绝，发生在用户动手之后。",
    },
    Allowance {
        text: "请先核实原物件已在当前空间库存中且尚未摆放，暂未恢复自动摆放。",
        source: "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift:234",
        why: "自动摆放的**核实**结论，只能在一次领取之后。",
    },
    Allowance {
        text: "当前空间拿不到摆放几何，暂时不能摆放",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift:204",
        why: "与 `placement.geometry` 同一件事在装修面板里的说法；加载态负责在进门前判定并记名。",
    },
    Allowance {
        text: "摆放面板还没有接到世界里（空间会话未就绪），这次挂点没有提交。请关掉面板重开一次。",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift:990",
        why: "`wish.claim` 已声明为 Deferred（挂点只能在用户摆放时提交）；加载态把它具名列出。",
    },
    Allowance {
        text: "已领取，入库尚未保存",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift:113",
        why: "领取之后的入库进行态（`wish.inventory_save`）。",
    },
    Allowance {
        text: "资产未就绪",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift:346",
        why: "`wish.inventory_save` 的徽章文案（Deferred 项）。",
    },
    Allowance {
        text: "资产未就绪：",
        source: "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift:347",
        why: "同上带原因的那一行。",
    },
    Allowance {
        text: "居民本轮没有返回内容或安排等待",
        source: "apps/macos/UnityHost/UnityMediaHost.swift:596",
        why: "一轮**已完成**但没有内容的结束语（真结局），不是 ready 问题。",
    },
    Allowance {
        text: "许愿输出预览暂不可用（",
        source: "apps/macos/UnityHost/UnityMediaHost.swift:1236",
        why: "许愿输出预览的数据缺陷；许愿相关项都已声明 Deferred。",
    },
    Allowance {
        text: "已停止尚未发送的消息。",
        source: "apps/macos/RenderHost/ResidentConversationBridge.swift:474",
        why: "用户取消之后的结果说明。",
    },
    Allowance {
        text: "这个空间还没有配置生活活动。",
        source: "apps/gpui-ui/src/i18n.rs:122",
        why: "`ui.activities` 已绑定 UI 层那一份（`stage_panels.rs:186`）；这里豁免 i18n 表里的同一句。",
    },
    Allowance {
        text: "房间里还没有摆放物件",
        source: "apps/gpui-ui/src/stage_panels/props.rs:93",
        why: "空房间的**空状态**（正确说法），不是「没 ready」。",
    },
    Allowance {
        text: "还没有许愿。对居民说你想要什么，做好后会出现在这里。",
        source: "apps/gpui-ui/src/stage_panels/props.rs:98",
        why: "同上：还没许愿是合法空状态。",
    },
    Allowance {
        text: "本轮不可用",
        source: "apps/gpui-ui/src/startup.rs",
        why: "加载态**自己**的状态词：这一项这次判定为不可用（具名），正是用来取代「进门后才弹」的那句。",
    },
    Allowance {
        text: "等待「{label}」先解决",
        source: "apps/gpui-ui/src/startup.rs",
        why: "加载态**自己**的依赖说明（等哪一项先有结论），不是用户会撞上的失败文案。",
    },
    Allowance {
        text: "等待「{label}」",
        source: "apps/gpui-ui/src/startup.rs",
        why: "同上，未就绪那一档的说法。",
    },
    Allowance {
        text: "先把要用的东西都准备好，再放你进去——这样进去之后不会再碰上「还没准备好」。",
        source: "apps/gpui-ui/src/startup.rs",
        why: "加载态**自己**的副标题，就是这个界面存在的理由。",
    },
    Allowance {
        text: "准备图片期间服务配置发生变化，本次生成尚未提交，请检查配置后重新发起。",
        source: "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift:360",
        why: "一次**提交**被配置变更挡回的拒绝回执（必须仍然是拒绝），只能在用户动手之后出现。",
    },
    Allowance {
        text: "(who)：读不出来",
        source: "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift:190",
        why: "尺寸意图的摘要行读不出来（数据缺陷），属于单件产物的说明，不是启动就绪项。",
    },
    Allowance {
        text: "有 (unreadableJobs.count) 条记录读不出来，已经跳过：",
        source: "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift:471",
        why: "许愿档案的**局部降级**（一条坏记录不许让整个列表消失）；是坏数据的诚实记录，不是就绪项。",
    },
];

/// 机械扫描的来源。**逐个钉住**，不整树扫：扫描面越大，越容易把别的线正在
/// 写的文件变成假红。`tools/fixtures`、`apps/macos/Tests` 之类不在扫描面内。
///
/// `apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift` **刻意不在**这里
/// （10k 行、别的线正在改）；它的"没 ready"文案由 [`RETIRED_COPY`] /
/// [`ALLOWED_AFTER_READY`] 的**逐条精确引用**冻结，而不是整文件扫描。
pub const SCANNED_SOURCES: &[(&str, ScanLang)] = &[
    // 这台加载态自己：登记表被抹白之后，它的面板文案仍然在扫描面内。
    ("apps/gpui-ui/src/startup.rs", ScanLang::RustGate),
    ("apps/gpui-ui/src/chat.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/i18n.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/inbox.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/primitives.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/projective_card.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/settings.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/shell.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/stage_panels.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/stage_panels/program.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/stage_panels/props.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/state.rs", ScanLang::Rust),
    ("apps/gpui-ui/src/ui_tokens.rs", ScanLang::Rust),
    ("apps/gpui-app/src/host_events.rs", ScanLang::Rust),
    ("apps/gpui-app/src/main.rs", ScanLang::Rust),
    ("apps/gpui-app/src/product_host.rs", ScanLang::Rust),
    ("apps/gpui-app/src/unity_settings_transport.rs", ScanLang::Rust),
    (
        "apps/unity-player/Assets/GMGN/WorldInteraction/PlacementRequestBuilder.cs",
        ScanLang::CLike,
    ),
    (
        "apps/unity-player/Assets/GMGN/WorldPhysicsProbeBridge.cs",
        ScanLang::CLike,
    ),
    (
        "apps/unity-player/Assets/GMGN/WorldPlacementGeometry/PlacementGeometry.cs",
        ScanLang::CLike,
    ),
    (
        "apps/unity-player/Assets/GMGN/WorldRuntimeBridge.cs",
        ScanLang::CLike,
    ),
    (
        "apps/macos/Sources/GMGNRadio/Presence/PropGenerationClient.swift",
        ScanLang::CLike,
    ),
    (
        "apps/macos/Sources/GMGNRadio/Presence/ResidentOwnershipProjection.swift",
        ScanLang::CLike,
    ),
    (
        "apps/macos/Sources/GMGNRadio/Presence/ResidentPropEditorState.swift",
        ScanLang::CLike,
    ),
    (
        "apps/macos/Sources/GMGNRadio/Presence/WishMachineCoordinator.swift",
        ScanLang::CLike,
    ),
    ("apps/macos/RenderHost/ResidentConversationBridge.swift", ScanLang::CLike),
    ("apps/macos/UnityHost/UnityMediaHost.swift", ScanLang::CLike),
];

/// 扫描器要认的字面量语法。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScanLang {
    /// Rust：`"…"`、`r"…"`、`r#"…"#`，外加剥掉 `#[cfg(test)] mod …` 本体。
    Rust,
    /// 这台加载态**自己**：先按 [`Rust`](ScanLang::Rust) 剥掉测试模块，再把
    /// `STARTUP_ITEMS` / `RETIRED_COPY` / `ALLOWED_AFTER_READY` /
    /// `NOT_READY_PATTERNS` 四块整体抹白——否则登记表会扫到自己。
    RustGate,
    /// Swift / C#：`"…"`、`"""…"""`、C# 的 `@"…"`。
    CLike,
}

impl ScanLang {
    /// 是不是 Rust 系（含这台加载态自己）：决定 `r"…"` 与块注释嵌套的读法。
    pub fn is_rust(self) -> bool {
        matches!(self, ScanLang::Rust | ScanLang::RustGate)
    }
}

// ---------------------------------------------------------------------------
// 界面
// ---------------------------------------------------------------------------

/// 加载态要宿主做的事。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartupCommand {
    Retry,
}

/// 进门前的那一整屏：步骤名、进度、具名失败与重试。
///
/// 它是一个普通 pane（`Render`），所以可以被真实宿主挂进窗口，也可以被
/// `apps/gpui-ui/tests/startup_gate_shot.rs` 在无头窗口里渲染成像素。
pub struct StartupGatePane {
    gate: StartupGate,
    commands: Vec<StartupCommand>,
    /// 上一次渲染时的阶段，用来只记一次"进门"日志。
    entered: bool,
    /// 上一次看到的每一项状态：阶段一变就写一行时间线日志。
    ///
    /// 这条日志是"每步耗时"的唯一来源——渲染侧的 `[WorldPrepare]` 步骤**不带时间戳**
    /// （`Player.log` 里整个 17 s 的准备窗口只有两个 `NSLog` 锚点），而加载态自己
    /// 知道每一步**什么时候**从 `准备中` 变成 `完成`/`不可用`/`失败`。
    seen: Vec<(&'static str, StepPhase)>,
    /// 最近一次 `observe` 的时钟。重试必须从这里续，而不是从 0 续——否则新的一次
    /// 尝试会拿一个巨大的 elapsed，当场被判超时。
    last_now_ms: u64,
    /// 已经写过的失败（项 + 码 + 第几次尝试）：同一次失败只写一行，不许 10 Hz 刷屏。
    failure_logged: Option<(String, u32)>,
}

impl StartupGatePane {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let _ = cx;
        Self {
            gate: StartupGate::new(),
            commands: Vec::new(),
            entered: false,
            seen: Vec::new(),
            last_now_ms: 0,
            failure_logged: None,
        }
    }
    /// 推进一次，返回整体阶段。宿主在它自己的 tick 里调。
    pub fn observe(&mut self, signals: &StartupSignals, now_ms: u64, cx: &mut Context<Self>) -> StartupPhase {
        self.last_now_ms = self.last_now_ms.max(now_ms);
        let phase = self.gate.observe(signals, now_ms);
        // 每一步的**时间线**：从"排队/准备中"变成任何终态时写一行，带毫秒与具名码。
        // 一次真机冷启动之后，`grep GMGN_STARTUP_STEP` 就是"每步耗时"那张表。
        for view in self.gate.steps() {
            let previous = self
                .seen
                .iter_mut()
                .find(|(id, _)| *id == view.id);
            match previous {
                Some((_, seen)) if *seen == view.phase => {}
                Some((_, seen)) => {
                    let from = *seen;
                    *seen = view.phase;
                    eprintln!(
                        "GMGN_STARTUP_STEP step={} from={:?} phase={:?} at_ms={} code={}",
                        view.id,
                        from,
                        view.phase,
                        now_ms,
                        view.code.as_deref().unwrap_or("-")
                    );
                }
                None => {
                    self.seen.push((view.id, view.phase));
                }
            }
        }
        if phase == StartupPhase::Ready && !self.entered {
            self.entered = true;
            eprintln!(
                "GMGN_STARTUP_READY attempt={} elapsed_ms={}",
                self.gate.attempt(),
                self.gate.elapsed_ms()
            );
        }
        if let Some(failure) = self.gate.failure() {
            let key = (format!("{}:{}", failure.step, failure.code), self.gate.attempt());
            if self.failure_logged.as_ref() != Some(&key) {
                eprintln!(
                    "GMGN_STARTUP_FAILED step={} code={} attempt={}",
                    failure.step,
                    failure.code,
                    self.gate.attempt()
                );
                self.failure_logged = Some(key);
            }
        }
        cx.notify();
        phase
    }
    /// 加载态是否还该盖在窗口上。
    pub fn covers_window(&self) -> bool {
        self.gate.phase() != StartupPhase::Ready
    }
    pub fn gate(&self) -> &StartupGate {
        &self.gate
    }
    pub fn take_commands(&mut self) -> Vec<StartupCommand> {
        std::mem::take(&mut self.commands)
    }
    fn retry(&mut self, cx: &mut Context<Self>) {
        if self.gate.retry(self.last_now_ms) {
            self.failure_logged = None;
            self.commands.push(StartupCommand::Retry);
        }
        cx.notify();
    }
}

/// 一项的图标与状态词。图标名必须是 gpui-kit 真的嵌进来的那批
/// （`shell.rs` 的 `BUNDLED_ICONS` 是那份清单的副本）——没嵌进来的名字会画成空方块。
fn step_face(phase: StepPhase) -> (IconName, &'static str) {
    match phase {
        StepPhase::Waiting => (IconName::Hourglass, "排队"),
        StepPhase::Running => (IconName::Loader, "准备中"),
        StepPhase::Ready => (IconName::CircleCheck, "完成"),
        StepPhase::Unavailable => (IconName::CircleAlert, "本轮不可用"),
        StepPhase::Failed => (IconName::TriangleAlert, "失败"),
        StepPhase::Deferred => (IconName::Info, "进入后按需"),
    }
}

/// 一项的颜色：**在调用点**写成一次 `match`，每个分支直接点名本层 `scene` 的记号。
///
/// 刻意**不做成函数或宏**：`overlay_theme_gate` 的图标判据读的是**源码文本**——
/// 每个 `Icon::new(..)` 的 `.text_color(..)` 必须能追到一个 `scene::`/`s::` 记号，
/// 追法只有两种（参数里直接写，或同函数里一条含该记号的 `let` 把它绑起来）。
/// `let tone = step_tone(phase)`（函数）与 `step_tone!(phase)`（宏）在这里**都追不到**
/// ——前者那条 `let` 里没有记号，后者记号在宏定义里而不在调用点。于是颜色正确也会被判红，
/// 而一个为了过门禁而把记号写在别处的写法，恰好会让"这个图标到底有没有自己的颜色"
/// 重新变成看不出来的事。下面的两处 `match` 是同一个映射，重复一次是为了让**每一处
/// 都自证**——这也正是判据想要的。
const _: () = ();

impl Render for StartupGatePane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let phase = self.gate.phase();
        // 就绪之后**什么都不画**——不是"画一层透明的盖子"。宿主已经会把这个槽位移出
        // 计划（`apps/gpui-app` 的 `OverlaySlot::StartupGate`），这里是第二道：一个
        // 忘了移的宿主不许把整窗的指针事件吞掉。
        if phase == StartupPhase::Ready {
            return div().into_any_element();
        }
        // 步骤可以很多（31 项清单），所以**中段滚动、失败块与进度常驻**：卡住时
        // "哪一项、什么码、能不能重试"永远在屏幕上，而不是被 21 行具名列表挤到窗户外
        // （`startup_gate_shot` 第一版就是这样：1180×760 下重试控件不可见）。
        let viewport = window.viewport_size();
        let max_height = (viewport.height.as_f32() - 48.).max(240.);
        let (done, total) = self.gate.progress();
        let fraction = self.gate.fraction();
        let mut column = div()
            .id("startup.gate")
            .test_support()
            .flex()
            .flex_col()
            .gap(px(s::PANEL_GAP))
            .w(px(GATE_COLUMN_WIDTH))
            .max_h(px(max_height))
            .p(px(s::PANEL_PADDING))
            .rounded(px(s::PANEL_RADIUS))
            .bg(rgba(s::PANEL_BG))
            .border_1()
            .border_color(rgba(s::BORDER))
            .text_color(rgba(s::TEXT))
            .child(ui::section_title(if phase == StartupPhase::Blocked {
                "还差一点，没能进去"
            } else {
                "正在进入生活空间"
            }))
            .child(ui::muted(
                "先把要用的东西都准备好，再放你进去——这样进去之后不会再碰上「还没准备好」。",
            ));
        // 进度：一句话 + 一条真实的条。
        column = column.child(
            div()
                .flex()
                .flex_col()
                .gap(px(SPACING_4))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .justify_between()
                        .text_size(px(CAPTION_SIZE))
                        .text_color(rgba(s::TEXT_MUTED))
                        .child(format!("{done}/{total} 项已就绪"))
                        .child(format!("{:.0}%", fraction * 100.)),
                )
                .child(
                    div()
                        .w(px(GATE_TRACK_WIDTH))
                        .h(px(4.))
                        .rounded(px(2.))
                        .bg(rgba(s::PLATE))
                        .child(
                            div()
                                .w(px(GATE_TRACK_WIDTH * fraction.clamp(0., 1.)))
                                .h(px(4.))
                                .rounded(px(2.))
                                .bg(rgba(if phase == StartupPhase::Blocked {
                                    s::WARNING
                                } else {
                                    s::SELECTED
                                })),
                        ),
                ),
        );
        // 中段：步骤 + 具名列表一起滚动。
        let mut middle = div()
            .id("startup.middle")
            .flex()
            .flex_col()
            .gap(px(s::PANEL_GAP))
            .flex_1()
            .min_h(px(0.))
            .overflow_y_scroll();
        // 步骤：先挡人的，再具名的。
        let views = self.gate.steps();
        let mut rows = div()
            .id("startup.steps")
            .test_support()
            .flex()
            .flex_col()
            .gap(px(SPACING_8));
        for view in views.iter().filter(|view| view.role == GateRole::Blocking) {
            let (icon, word) = step_face(view.phase);
            // 这一项自己的颜色：记号写在这里，图标才不会继承 kit 主题的前景色。
            let tone = match view.phase {
                StepPhase::Running => s::SELECTED,
                StepPhase::Unavailable | StepPhase::Failed => s::WARNING,
                StepPhase::Ready => s::TEXT_MUTED,
                StepPhase::Waiting | StepPhase::Deferred => s::TEXT_DIM,
            };
            let mut row = div()
                .flex()
                .items_center()
                .gap(px(SPACING_8))
                .child(Icon::new(icon).size(px(14.)).text_color(rgba(tone)))
                .child(div().flex_1().min_w(px(0.)).child(view.label))
                .child(
                    div()
                        .flex_shrink_0()
                        .text_size(px(CAPTION_SIZE))
                        .text_color(rgba(tone))
                        .child(word),
                );
            if let Some(detail) = &view.detail {
                row = row.child(
                    div()
                        .flex_shrink_0()
                        .text_size(px(CAPTION_SIZE))
                        .text_color(rgba(s::TEXT_DIM))
                        .child(detail.clone()),
                );
            }
            rows = rows.child(row);
        }
        middle = middle.child(rows);
        // 具名：本轮不可用 / 进门后按需。加载态**必须**把它们摆出来。
        let named: Vec<StepView> = views
            .iter()
            .filter(|view| {
                view.role != GateRole::Blocking
                    && matches!(
                        view.phase,
                        StepPhase::Unavailable | StepPhase::Deferred | StepPhase::Failed
                    )
            })
            .cloned()
            .collect();
        if !named.is_empty() {
            let mut block = div()
                .id("startup.named")
                .test_support()
                .flex()
                .flex_col()
                .gap(px(SPACING_4))
                .p(px(SPACING_8))
                .rounded(px(s::PANEL_RADIUS_SMALL))
                .bg(rgba(s::CARD_BG))
                .child(ui::muted("这些这次进不去也没关系，现在就说清楚："));
            for view in &named {
                let (_, word) = step_face(view.phase);
                // 这一项自己的颜色：记号写在这里，图标才不会继承 kit 主题的前景色。
                let tone = match view.phase {
                    StepPhase::Running => s::SELECTED,
                    StepPhase::Unavailable | StepPhase::Failed => s::WARNING,
                    StepPhase::Ready => s::TEXT_MUTED,
                    StepPhase::Waiting | StepPhase::Deferred => s::TEXT_DIM,
                };
                block = block.child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(SPACING_8))
                        .text_size(px(CAPTION_SIZE))
                        .child(div().flex_1().min_w(px(0.)).child(view.label))
                        .child(div().flex_shrink_0().text_color(rgba(tone)).child(word))
                        .child(
                            div()
                                .flex_shrink_0()
                                .text_color(rgba(s::TEXT_DIM))
                                .child(view.code.clone().unwrap_or_default()),
                        ),
                );
            }
            middle = middle.child(block);
        }
        column = column.child(middle);
        // 具名失败 + 重试（常驻，不随中段滚走）。
        if let Some(failure) = self.gate.failure() {
            let mut block = div()
                .id("startup.failure")
                .test_support()
                .flex()
                .flex_col()
                .gap(px(SPACING_4))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap(px(SPACING_8))
                        .text_color(rgba(s::WARNING))
                        .child(
                            Icon::new(IconName::TriangleAlert)
                                .size(px(14.))
                                .text_color(rgba(s::WARNING)),
                        )
                        .child(format!("{}：{}", failure.label, failure.message)),
                )
                .child(
                    div()
                        .text_size(px(CAPTION_SIZE))
                        .text_color(rgba(s::TEXT_DIM))
                        .child(format!("{}（第 {} 次尝试）", failure.code, self.gate.attempt())),
                );
            if failure.retryable {
                block = block.child(
                    ui::bar_button("startup.retry", "重试", IconName::RefreshCw, s::CONTROL_HEIGHT)
                        .on_click(cx.listener(|this, _, _, cx| this.retry(cx))),
                );
            }
            column = column.child(block);
        }
        div()
            .size_full()
            .flex()
            .items_center()
            .justify_center()
            .bg(rgba(s::BAR_BG))
            .child(column)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    // **不要** `use super::*;`：本模块顶部有 `use gpui_kit::*;`，那个 glob 里也有一个
    // `test`，它会把内置的 `#[test]` 属性宏遮住——于是编译器去展开 gpui 的 `test`
    // 而不是测试属性，一次 `--lib` 测试编译会以 SIGBUS 收场（`apps/gpui-ui/src/shell.rs`
    // 的测试模块用 `use core::prelude::v1::test;` 挡的是同一件事）。这里改成**逐名**
    // 引入，两个问题一起消失：名字是显式的，`test` 也不会被带进来。
    use super::{
        Disposition, GateRole, RETIRED_COPY, STARTUP_DEADLINE_MS, STARTUP_ITEMS, Signal, StartupGate,
        StartupPhase, StartupSignals, StepPhase, readiness_item,
    };
    use serde_json::json;
    use std::collections::BTreeSet;

    #[test]
    fn every_item_has_a_unique_id_and_a_citation() {
        let mut seen = BTreeSet::new();
        for item in STARTUP_ITEMS {
            assert!(!item.id.is_empty(), "an item without an id cannot be named");
            assert!(seen.insert(item.id), "duplicate id {}", item.id);
            assert!(!item.label.is_empty(), "{} must carry a step name", item.id);
            assert!(
                item.source.contains(':') && item.source.contains('/'),
                "{} must cite a real source line, got {}",
                item.id,
                item.source
            );
            assert!(!item.ready_when.is_empty(), "{} must say what ready means", item.id);
            assert!(!item.fails_when.is_empty(), "{} must say when it fails", item.id);
            assert!(!item.failure_code.is_empty(), "{} must name its failure", item.id);
            for dep in item.depends_on {
                assert!(
                    STARTUP_ITEMS.iter().any(|other| other.id == *dep),
                    "{} depends on unknown item {}",
                    item.id,
                    dep
                );
                assert_ne!(*dep, item.id, "{} cannot depend on itself", item.id);
            }
            if item.role == GateRole::Blocking {
                assert!(item.budget_ms > 0, "blocking item {} needs a bound", item.id);
            }
        }
    }

    /// 启动是**并行**的：有多项没有任何依赖，一次 `observe` 就能一起就绪。
    #[test]
    fn the_gate_starts_every_independent_item_at_once() {
        let independent = STARTUP_ITEMS.iter().filter(|item| item.depends_on.is_empty()).count();
        assert!(
            independent > 1,
            "a serial startup has exactly one independent item; this one has {independent}"
        );
        let mut gate = StartupGate::new();
        let mut signals = StartupSignals::new();
        for item in STARTUP_ITEMS {
            signals.set(item.signal, true);
        }
        // 依赖是显式声明的，而且声明顺序里靠前的项在同一次观察里就满足了后面的依赖：
        // 一次观察即可全部就绪——这正是"并行"的可观测含义（没有一项在等另一项**完成**
        // 之外的额外一次 tick）。
        assert_eq!(gate.observe(&signals, 0), StartupPhase::Ready);
        for view in gate.steps() {
            assert_eq!(view.phase, StepPhase::Ready, "{} did not flip in one pass", view.id);
        }
        // 并行而不是串行：只给 `HostCore` 时，一次观察里就有多项**同时**开始。
        let mut parallel = StartupGate::new();
        let mut only_core = StartupSignals::new();
        only_core.set(Signal::HostCore, true);
        parallel.observe(&only_core, 0);
        let running = parallel
            .steps()
            .into_iter()
            .filter(|view| view.phase == StepPhase::Running)
            .count();
        assert!(
            running >= 3,
            "a serial gate starts one item per observation; this one started {running}"
        );
    }

    #[test]
    fn the_gate_is_bounded_and_names_everything_it_could_not_do() {
        let mut gate = StartupGate::with_deadline(1_000);
        let signals = StartupSignals::new();
        assert_eq!(gate.observe(&signals, 0), StartupPhase::Preparing);
        assert_eq!(gate.observe(&signals, 1_500), StartupPhase::Blocked);
        let failure = gate.failure().expect("a blocked gate must name a step");
        assert!(!failure.code.is_empty());
        assert!(failure.code.ends_with("_deadline") || failure.code.ends_with("_timeout"), "{}", failure.code);
        assert!(!failure.label.is_empty());
        assert!(!failure.message.is_empty());
        // 每一项不可能无限等：每个挡人项都有一个上界。
        for item in STARTUP_ITEMS.iter().filter(|item| item.role == GateRole::Blocking) {
            assert!(item.budget_ms > 0 && item.budget_ms <= STARTUP_DEADLINE_MS);
        }
        // 重试只把失败的项放回队里，已经就绪的保持就绪。
        let mut ready_gate = StartupGate::with_deadline(1_000);
        let mut signals = StartupSignals::new();
        signals.set(Signal::HostCore, true);
        ready_gate.observe(&signals, 0);
        ready_gate.observe(&signals, 1_500);
        assert!(ready_gate.retry(2_000));
        assert_eq!(ready_gate.attempt(), 2);
        assert_eq!(ready_gate.step("host.core").unwrap().phase, StepPhase::Ready);
        assert_eq!(ready_gate.step("host.surface").unwrap().phase, StepPhase::Waiting);
    }

    #[test]
    fn a_failed_dependency_fails_its_dependents_by_name() {
        let mut gate = StartupGate::with_deadline(1_000);
        let signals = StartupSignals::new();
        gate.observe(&signals, 0);
        gate.observe(&signals, 1_500);
        let code = gate
            .step("world.activate")
            .and_then(|state| state.code.clone())
            .expect("a dependent of a failed item must be named");
        assert!(code.contains("blocked_by"), "{code}");
    }

    #[test]
    fn deferred_items_are_named_not_hidden() {
        let mut gate = StartupGate::new();
        let signals = StartupSignals::new();
        gate.observe(&signals, 0);
        let named = gate.named();
        for item in STARTUP_ITEMS.iter().filter(|item| item.role == GateRole::Deferred) {
            let view = named
                .iter()
                .find(|view| view.id == item.id)
                .unwrap_or_else(|| panic!("{} must be listed before entry", item.id));
            assert_eq!(view.phase, StepPhase::Deferred);
            assert!(view.code.is_some(), "{} must be named with a code", item.id);
        }
    }

    #[test]
    fn snapshot_signals_do_not_confuse_missing_data_with_a_real_empty_state() {
        // 一个还没投影出 `screenVideo` 的快照：电视那一项**不该**被当成就绪。
        let thin = json!({"stage": {"mode": "space", "presentation": {"isWorldPresentationRequested": true, "isWorldVisible": true}}});
        let mut signals = StartupSignals::new();
        signals.observe_snapshot(&thin);
        assert!(signals.has(Signal::WorldVisible));
        assert!(!signals.has(Signal::ScreenProjection));
        assert!(!signals.has(Signal::ActivityCatalog));
        assert!(!signals.has(Signal::MusicLibrary));
        // 投影到了，且值就是"这个空间没有电视"：算就绪（合法的空状态）。
        let full = json!({
            "stage": {"mode": "space", "presentation": {"isWorldPresentationRequested": true, "isWorldVisible": true, "chatAvailable": true, "propsAvailable": true}},
            "activities": {"canRun": true, "items": []},
            "inbox": {"entries": []},
            "wish": {"entries": []},
            "screenOperation": {"available": false},
            "screenVideo": {"screens": []},
            "settings": {},
            "propEditor": {},
            "musicLibrary": {"programs": [], "playlists": []},
            "liveCamPlayerMenu": {"canTogglePlayback": false},
        });
        let mut signals = StartupSignals::new();
        signals.observe_snapshot(&full);
        for signal in [
            Signal::ScreenProjection,
            Signal::ActivityCatalog,
            Signal::InboxProjection,
            Signal::WishProjection,
            Signal::MusicLibrary,
            Signal::PlayerMenu,
            Signal::SettingsProjection,
            Signal::PlacementSurface,
            Signal::ResidentSession,
        ] {
            assert!(signals.has(signal), "{signal:?} should be observed");
        }
    }

    #[test]
    fn retired_copy_binds_every_sentence_to_a_real_gate_item() {
        for entry in RETIRED_COPY {
            let item = readiness_item(entry.gate_item)
                .unwrap_or_else(|| panic!("{} binds to unknown item {}", entry.text, entry.gate_item));
            assert!(!entry.why.is_empty(), "{} must say why", entry.text);
            let expected = match entry.disposition {
                Disposition::Blocks => GateRole::Blocking,
                Disposition::NamedAtStartup => GateRole::Preflight,
                Disposition::Deferred => GateRole::Deferred,
            };
            assert_eq!(
                item.role, expected,
                "{} is bound to {} whose role disagrees with its disposition",
                entry.text, entry.gate_item
            );
        }
    }
}
