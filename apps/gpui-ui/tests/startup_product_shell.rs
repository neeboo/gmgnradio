//! 启动加载态的**产品壳**信号源：同一份清单，两个不同的宿主信封形状。
//!
//! 背景（这就是这条门禁存在的理由）：加载态最早只接在独立应用
//! `apps/gpui-app` 上，而**装机产品**的 GPUI 是
//! `tools/fixtures/gpui-unity-overlay-probe`（打成
//! `Contents/PlugIns/libgmgn_gpui_overlay_probe.dylib`），它接的是
//! `UnityMediaHost.snapshot()` 的信封。于是出现了一类重复的错误：
//! **测试在独立应用里绿，产品壳里根本没接**。这个文件把"产品壳信封 → 同一批信号"
//! 这件事变成可断言的，`tools/verify-product-shell-parity.py` 再把"产品壳真的接了"
//! 钉在源文件上。
//!
//! ## 2026-10-09 21:48 真机那次为什么会被门永久盖住
//!
//! 上一版的 `shipped_product_envelope()` **把信封编成了方便的假形状**：它把舞台放在
//! `settings.stage`，而真机是 `settings.settings.stage`；它把 `unityInventory` 编成
//! 对象，而真机是数组。于是：
//!
//! * `settings.stage` 永远是 `Null` ⇒ `world.authority`（`isWorldPresentationRequested`）
//!   与 `world.prepare` / `world.activate`（`isWorldVisible`）永远拿不到信号；
//! * 30 s 后 `world.authority_timeout` 把整门判 `Blocked`，再连锁
//!   `world.* / placement.* / resident.* → blocked_by_world.authority`；
//! * 同一时刻真机日志里空间其实已经 `phase=activate`、`[WorldMode] visible=True`、
//!   55 帧、卡顿帧 0——**应用是好的，门在错误地挡人**。
//!
//! 所以这个文件的信封**逐字按生产者写**（下面每个键都引到发布它的行），并且多了两条
//! 判定：没有生产者的项必须"不参与门"，世界一激活门必须放行。
//!
//! 两条硬性要求，各有一个负对照：
//!
//! 1. [`the_product_shell_envelope_reaches_the_same_world_signals`]：产品壳信封里的
//!    `settings.settings.stage.presentation` / `settings.settings.stage.activities`
//!    必须点亮与独立应用**同名**的信号——路径不同不是事实不同。
//! 2. [`the_product_shell_never_invents_a_signal_for_a_missing_key`]：信封里没有的键
//!    **不许**算就绪。空信封必须一个信号都不给；把舞台挪出真实路径、把
//!    `unityInventory` 换成对象，都不许算就绪。

use gmgn_gpui_ui::startup::{
    GateRole, PRODUCT_SHELL_SIGNAL_PRODUCERS, ReadinessItem, Signal, SignalAvailability, StartupGate,
    StartupPhase, StartupSignals, StepPhase, STARTUP_ITEMS,
    blocking_items_without_a_product_shell_producer,
};
use serde_json::{Value, json};

/// 真机那次的空间 id（`~/Library/Logs/DefaultCompany/GMGN Unity Sample/Player.log`
/// 2026-10-09 21:48 的 `world=84503420-3010-4944-8fde-2f383cd08ebe`）。
const SHIPPED_WORLD_ID: &str = "84503420-3010-4944-8fde-2f383cd08ebe";

/// 一份**真机形状**的产品壳信封：键与路径逐个来自发布它们的代码。
///
/// * `settings.settings.stage.*`：`UnityMediaHost.settingsSnapshot()` 返回
///   `["…", "settings": settings, …]`（`UnityMediaHost.swift:1998`），而
///   `settings["stage"] = stageSnapshot(...)`（`:1995`）——所以舞台在**内层**设置字典里
///   `settings.settings.stage`。产品壳自己的 `settings_projection` 就是这么读的
///   （`tools/fixtures/gpui-unity-overlay-probe/src/lib.rs:599`）。
/// * `settings.settings.stage.presentation.*` / `.space` / `.activities`：
///   `stageSnapshot()`（`UnityMediaHost.swift:1103`-`:1122`）。
/// * `music.canPrevious/.canNext`：`snapshot()`（`UnityMediaHost.swift:1668`）。
/// * `screenVideo.screens`：`UnityScreenVideoBridge.snapshot()`（`:369`）。
/// * `inbox.entries` / `wish.entries`：`UnityInboxBridge.swift:169` /
///   `UnityWishMachineBridge.swift:144`（经 `worldSession.snapshot()` 进信封）。
/// * `unityInventory` 是**数组**：`GPUIProjectionPayload.cs:38` 把 `JArray` 放进来，
///   `inventory_ui.rs:196` 按数组读。
///
/// `musicLibrary` 刻意**只有 generation/pending/currentTrackID**：真机上歌单/节目历史
/// 由用户打开音乐页触发的操作发布（`UnityMusicLibraryBridge.swift:371`），启动阶段
/// 还没有——这正是 `ui.playlist` 在产品壳里是"进门后按需"的原因。
fn shipped_product_envelope() -> Value {
    json!({
        "settings": {
            "version": 1,
            "revision": 7,
            "settings": {
                "stage": {
                    "mode": "space",
                    "presentation": {
                        "isWorldPresentationRequested": true,
                        "isWorldVisible": true,
                        "chatAvailable": true,
                        "propsAvailable": true,
                    },
                    "space": {
                        "worlds": [],
                        "selectedWorldID": SHIPPED_WORLD_ID,
                        "isVisible": true,
                        "isRequested": true,
                    },
                    "activities": {"items": [], "canRun": true, "phase": Value::Null},
                },
            },
            "runtimeDiagnostics": {},
            "supportedCommands": ["stage.load", "music.load"],
        },
        "music": {"canPrevious": true, "canNext": false, "isPlaying": false, "title": "", "volume": 0.5},
        "musicLibrary": {"generation": 1, "pending": false, "currentTrackID": ""},
        "screenVideo": {"screens": [], "frames": [], "commandNotice": Value::Null},
        "inbox": {"entries": []},
        "wish": {"entries": []},
        "unityInventory": [],
        "unityWorldAuthority": {"state": {"worldID": SHIPPED_WORLD_ID}},
    })
}

/// **只**从信封读信号：`the_product_shell_never_invents_a_signal_for_a_missing_key`
/// 要的是"信封里没有的键不许算就绪"，所以这里不掺这一层壳自己的生命周期事实。
fn signals_of(envelope: &Value) -> StartupSignals {
    let mut signals = StartupSignals::new();
    signals.observe_product_shell_envelope(envelope);
    signals
}

/// 产品壳的一整份观测：信封 + 这一层壳自己的三项生命周期事实
/// （`shell_ui.rs:586` 的 `observe_host`）。
fn shell_signals(envelope: &Value) -> StartupSignals {
    let mut signals = signals_of(envelope);
    signals.observe_host(true, envelope.is_object(), true);
    signals
}

#[test]
fn the_product_shell_envelope_reaches_the_same_world_signals() {
    let signals = signals_of(&shipped_product_envelope());
    for signal in [
        Signal::WorldRequested,
        Signal::WorldVisible,
        Signal::ResidentSession,
        Signal::StageProjection,
        Signal::ActivityCatalog,
        Signal::SettingsProjection,
        Signal::InboxProjection,
        Signal::WishProjection,
        Signal::ScreenProjection,
        Signal::PlayerMenu,
        Signal::PlacementSurface,
    ] {
        assert!(
            signals.has(signal),
            "{signal:?} 在产品壳信封里已经发布，却被判成未就绪"
        );
    }
    // 路径不同不是事实不同：把同一个舞台放在**根上**（独立应用的形状）必须给出
    // 同样的世界类信号。
    let stage = shipped_product_envelope()["settings"]["settings"]["stage"].clone();
    let canonical = json!({
        "stage": stage.clone(),
        "activities": stage["activities"].clone(),
    });
    let mut canonical_signals = StartupSignals::new();
    canonical_signals.observe_snapshot(&canonical);
    for signal in [Signal::WorldRequested, Signal::WorldVisible, Signal::ResidentSession] {
        assert_eq!(
            canonical_signals.has(signal),
            signals.has(signal),
            "{signal:?} 在两个壳里必须是同一个事实"
        );
    }
}

#[test]
fn the_product_shell_never_invents_a_signal_for_a_missing_key() {
    // 负对照：空信封。任何一项被点亮都意味着"没数据"被当成了"真的没有"。
    let empty = signals_of(&json!({}));
    for item in STARTUP_ITEMS {
        assert!(
            !empty.has(item.signal),
            "空信封却点亮了 {}（{:?}）",
            item.id,
            item.signal
        );
    }
    // 逐个把"同义键"拿掉：没有那一个键，就不许有那一个信号。
    let mut without_screens = shipped_product_envelope();
    without_screens["screenVideo"] = json!({});
    assert!(!signals_of(&without_screens).has(Signal::ScreenProjection));

    let mut without_player = shipped_product_envelope();
    without_player["music"] = json!({"title": "x", "isPlaying": true});
    assert!(!signals_of(&without_player).has(Signal::PlayerMenu));

    // `unityInventory` 真机是**数组**：换成对象就不算就绪（上一版正是按对象判的，
    // 于是真机上这一项白等 15 秒）。
    let mut inventory_object = shipped_product_envelope();
    inventory_object["unityInventory"] = json!({"items": []});
    assert!(!signals_of(&inventory_object).has(Signal::PlacementSurface));

    // `propsAvailable` 为假时，装修面也不算就绪（它是宿主自己的判定）。
    let mut props_off = shipped_product_envelope();
    props_off["settings"]["settings"]["stage"]["presentation"]["propsAvailable"] = json!(false);
    assert!(!signals_of(&props_off).has(Signal::PlacementSurface));

    // 舞台被放在**不存在的** `settings.stage` 上时，世界类信号一个都不许点亮——
    // 上一版就是这样把真机的 `settings.settings.stage` 读成了 `Null`。
    let mut wrong_nest = shipped_product_envelope();
    let stage = wrong_nest["settings"]["settings"]["stage"].take();
    wrong_nest["settings"]["stage"] = stage;
    let wrong = signals_of(&wrong_nest);
    for signal in [
        Signal::WorldRequested,
        Signal::WorldVisible,
        Signal::ResidentSession,
        Signal::StageProjection,
        Signal::ActivityCatalog,
    ] {
        assert!(
            !wrong.has(signal),
            "{signal:?} 被一个不存在的路径点亮了（舞台不在 settings.stage）"
        );
    }
}

#[test]
fn the_product_shell_drives_the_same_gate_to_ready() {
    let signals = shell_signals(&shipped_product_envelope());
    let mut gate = StartupGate::new();
    // 世界已经可见：硬规则说门必须放行。产品壳发布的那批信号必须足以开门。
    assert_eq!(
        gate.observe(&signals, 0),
        StartupPhase::Ready,
        "产品壳发布的那批信号必须足以开门：{}",
        gate.named()
            .iter()
            .map(|view| format!("{}={:?}", view.id, view.code))
            .collect::<Vec<_>>()
            .join(" ")
    );
    assert!(gate.failure().is_none(), "开门时不该有挡人失败");
    // 就算世界还没进来（只有宿主自身三项），也必须在有界时间内给出结局，而不是
    // 被一个这个壳不发布的信号永久挡住。
    let mut cold = StartupGate::new();
    let mut host_only = StartupSignals::new();
    host_only.observe_product_shell_envelope(&json!({}));
    host_only.observe_host(true, true, true);
    assert_eq!(cold.observe(&host_only, 0), StartupPhase::Preparing);
    assert_eq!(
        cold.observe(&host_only, 150_000),
        StartupPhase::Blocked,
        "世界没进来时，门的结局仍然有界且具名"
    );
}

#[test]
fn every_blocking_item_can_be_observed_from_a_product_shell_or_is_named() {
    // 产品壳能发布的那批信号，必须真的把每一个**挡人**项喂饱——否则加载态会在
    // 产品里永久挡住用户（这正是"接进产品壳"最危险的一种失败）。
    let signals = shell_signals(&shipped_product_envelope());
    let mut gate = StartupGate::new();
    gate.observe(&signals, 0);
    for view in gate.steps() {
        let item = STARTUP_ITEMS.iter().find(|item| item.id == view.id).expect("from the table");
        if item.role == GateRole::Blocking {
            assert!(
                matches!(
                    view.phase,
                    StepPhase::Ready | StepPhase::Deferred | StepPhase::NotApplicable
                ),
                "挡人项 {} 在产品壳里没有信号，加载态会永久挡住人：{:?}",
                view.id,
                view.phase
            );
        }
    }
    // 再确认一次：没有任何挡人项因为超时而变成具名失败。
    gate.observe(&signals, 30_000);
    let blocked: Vec<&str> = gate
        .steps()
        .iter()
        .filter(|view| matches!(view.phase, StepPhase::Failed))
        .map(|view| view.id)
        .collect();
    assert!(blocked.is_empty(), "产品壳把挡人项饿死了：{blocked:?}");
}

/// 这个壳不发布的信号：对应项必须**不参与门**（`NotApplicable`，具名说清读哪个键），
/// 而不是在自己的上界到点后变成"本轮不可用"，更不是挡住人。
#[test]
fn items_the_product_shell_does_not_publish_are_not_applicable_not_failed() {
    let signals = shell_signals(&shipped_product_envelope());
    let mut gate = StartupGate::new();
    gate.observe(&signals, 0);
    gate.observe(&signals, 150_000);
    let never: Vec<&str> = PRODUCT_SHELL_SIGNAL_PRODUCERS
        .iter()
        .filter(|producer| producer.availability == SignalAvailability::Never)
        .map(|producer| signal_name(producer.signal))
        .collect();
    let mut checked = 0;
    for item in STARTUP_ITEMS {
        if product_availability(item.signal) != SignalAvailability::Never {
            continue;
        }
        checked += 1;
        let view = gate.step(item.id).expect("every item is a step");
        assert_eq!(
            view.phase,
            StepPhase::NotApplicable,
            "{} 的信号（{never:?}）在产品壳里没有生产者，必须不参与门，而不是 {:?}",
            item.id,
            view.phase
        );
        let code = view.code.as_deref().unwrap_or("");
        assert!(
            code.ends_with("_signal_not_published"),
            "{} 必须具名说明'这个壳不发布该信号'，实际码 {code}",
            item.id
        );
        let detail = view.detail.as_deref().unwrap_or("");
        assert!(
            detail.contains("不参与门") && detail.contains("apps/") ,
            "{} 的说明必须给出它读的键与出处，实际 {detail:?}",
            item.id
        );
    }
    assert!(checked >= 4, "至少要有四项是没有生产者的（实际 {checked}）");
    // 「进门后按需」的那一项：产品壳会发布它，但要用户打开音乐页触发。
    let playlist = gate.step("ui.playlist").expect("ui.playlist is a step");
    assert_eq!(
        playlist.phase,
        StepPhase::Deferred,
        "ui.playlist 在产品壳里是进门后按需（歌单由用户打开音乐页触发），不能挡人"
    );
}

/// 硬规则：世界一旦 `phase=activate`（快照 `isWorldVisible=true`），门必须**立刻**放行，
/// 即使还有别的项没有结论。
#[test]
fn the_gate_releases_the_moment_the_world_is_visible() {
    // 一份"世界可见、但聊天投影还没到"的信封：`chatAvailable` 被拿掉 ⇒
    // `ResidentSession` 没有信号 ⇒ `resident.session/agent/queue` 还在等。
    let mut envelope = shipped_product_envelope();
    envelope["settings"]["settings"]["stage"]["presentation"]
        .as_object_mut()
        .expect("presentation object")
        .remove("chatAvailable");
    let signals = shell_signals(&envelope);
    assert!(signals.has(Signal::WorldVisible), "这一份信封里世界是可见的");
    assert!(
        !signals.has(Signal::ResidentSession),
        "这一份信封刻意让居民会话拿不到信号"
    );
    let mut gate = StartupGate::new();
    assert_eq!(
        gate.observe(&signals, 0),
        StartupPhase::Ready,
        "世界已经激活，门必须立刻放行：{:?}",
        gate.steps()
            .iter()
            .filter(|view| matches!(view.phase, StepPhase::Waiting | StepPhase::Running))
            .map(|view| view.id)
            .collect::<Vec<_>>()
    );
    assert!(gate.failure().is_none(), "放行时不该有用户可见的挡人失败");
    for id in ["resident.session", "resident.agent", "resident.queue"] {
        let view = gate.step(id).expect("resident steps exist");
        assert!(
            matches!(view.phase, StepPhase::Deferred | StepPhase::Ready),
            "{id} 在世界可见之后不该把门继续盖着，实际 {:?}",
            view.phase
        );
    }
}

/// 负对照：把某个"没有生产者"的项改回 `Blocking`，门禁判定**必须变红**。
#[test]
fn a_no_producer_item_put_back_on_the_blocking_path_turns_the_check_red() {
    // 真实清单：每个挡人项的信号在产品壳里都有启动期生产者。
    assert!(
        blocking_items_without_a_product_shell_producer(STARTUP_ITEMS).is_empty(),
        "真实清单里就有挡人项没有生产者：{:?}",
        blocking_items_without_a_product_shell_producer(STARTUP_ITEMS)
    );
    // 把 `generation.health`（它的 `GenerationService` 在产品壳里是 `Never`）改回
    // `Blocking`：判定必须报出它，并点名信号。
    let mut mutated: Vec<ReadinessItem> = STARTUP_ITEMS.to_vec();
    let target = mutated
        .iter_mut()
        .find(|item| item.id == "generation.health")
        .expect("generation.health is in the table");
    assert_eq!(target.role, GateRole::Preflight, "前提：它现在是 Preflight");
    target.role = GateRole::Blocking;
    let red = blocking_items_without_a_product_shell_producer(&mutated);
    assert_eq!(
        red,
        vec![("generation.health", Signal::GenerationService)],
        "把没有生产者的项改回 Blocking 必须被判红"
    );
}

/// 信号名（给失败信息用；`Signal` 没有公开的字符串表）。
fn signal_name(signal: Signal) -> &'static str {
    match signal {
        Signal::HostCore => "HostCore",
        Signal::HostSnapshot => "HostSnapshot",
        Signal::HostSurface => "HostSurface",
        Signal::WorldRequested => "WorldRequested",
        Signal::WorldVisible => "WorldVisible",
        Signal::ResidentSession => "ResidentSession",
        Signal::PlacementSurface => "PlacementSurface",
        Signal::ActivityCatalog => "ActivityCatalog",
        Signal::PlayerMenu => "PlayerMenu",
        Signal::MusicLibrary => "MusicLibrary",
        Signal::InboxProjection => "InboxProjection",
        Signal::WishProjection => "WishProjection",
        Signal::ScreenProjection => "ScreenProjection",
        Signal::SettingsProjection => "SettingsProjection",
        Signal::StageProjection => "StageProjection",
        Signal::PlacementGeometry => "PlacementGeometry",
        Signal::PhysicsProbe => "PhysicsProbe",
        Signal::GenerationService => "GenerationService",
    }
}

fn product_availability(signal: Signal) -> SignalAvailability {
    PRODUCT_SHELL_SIGNAL_PRODUCERS
        .iter()
        .find(|producer| producer.signal == signal)
        .map(|producer| producer.availability)
        .unwrap_or(SignalAvailability::Startup)
}
