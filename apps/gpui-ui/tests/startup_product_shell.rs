//! 启动加载态的**产品壳**信号源：同一份清单，两个不同的宿主信封形状。
//!
//! 背景（这就是这条门禁存在的理由）：加载态最早只接在独立应用
//! `apps/gpui-app` 上，而**装机产品**的 GPUI 是
//! `tools/fixtures/gpui-unity-overlay-probe`（打成
//! `Contents/Plugins/libgmgn_gpui_overlay_probe.dylib`），它接的是
//! `UnityMediaHost.settingsSnapshot()` 的信封。于是出现了一类重复的错误：
//! **测试在独立应用里绿，产品壳里根本没接**。这个文件把"产品壳信封 → 同一批信号"
//! 这件事变成可断言的，`tools/verify-product-shell-parity.py` 再把"产品壳真的接了"
//! 钉在源文件上。
//!
//! 两条硬性要求，各有一个负对照：
//!
//! 1. [`the_product_shell_envelope_reaches_the_same_world_signals`]：产品壳信封里
//!    的 `settings.stage.presentation` / `settings.stage.activities` 必须点亮与
//!    独立应用**同名**的信号——路径不同不是事实不同。
//! 2. [`the_product_shell_never_invents_a_signal_for_a_missing_key`]：信封里没有的键
//!    **不许**算就绪。空信封必须一个信号都不给（负对照：把不存在的键当就绪会让加载态
//!    在空间还没进来时就开门）。

use gmgn_gpui_ui::startup::{
    GateRole, Signal, StartupGate, StartupPhase, StartupSignals, StepPhase, STARTUP_ITEMS,
};
use serde_json::{Value, json};

/// 一份**产品壳**（`UnityMediaHost.settingsSnapshot()`）形状的信封：能发布的全发布。
fn shipped_product_envelope() -> Value {
    json!({
        // UnityHost 把舞台表面嵌在 `settings.stage`（`UnityMediaHost.swift:1914`）。
        "settings": {
            "settings": {"selectedWorldID": "w1"},
            "stage": {
                "mode": "space",
                "presentation": {
                    "isWorldPresentationRequested": true,
                    "isWorldVisible": true,
                    "chatAvailable": true,
                    "propsAvailable": true,
                },
                "space": {"worlds": [], "selectedWorldID": "w1", "isVisible": true, "isRequested": true},
                "activities": {"items": [], "canRun": true, "phase": null},
            },
        },
        "inbox": {"entries": []},
        "wish": {"entries": []},
        "musicLibrary": {"programs": [], "playlists": []},
        "screenVideo": {"screens": [], "frames": [], "commandNotice": Value::Null},
        "music": {"canPrevious": true, "canNext": false, "isPlaying": false, "title": "", "volume": 0.5},
        "unityInventory": {"items": []},
    })
}

fn signals_of(envelope: &Value) -> StartupSignals {
    let mut signals = StartupSignals::new();
    signals.observe_product_shell_envelope(envelope);
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
        Signal::MusicLibrary,
        Signal::ScreenProjection,
        Signal::PlayerMenu,
        Signal::PlacementSurface,
    ] {
        assert!(
            signals.has(signal),
            "{signal:?} 在产品壳信封里已经发布，却被判成未就绪"
        );
    }
    // 路径不同不是事实不同：把同一个 `presentation` 放在**根上**（独立应用的形状）
    // 必须给出同样的世界类信号。
    let canonical = json!({
        "stage": shipped_product_envelope()["settings"]["stage"].clone(),
        "activities": shipped_product_envelope()["settings"]["stage"]["activities"].clone(),
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

    let mut without_inventory = shipped_product_envelope();
    without_inventory["unityInventory"] = Value::Null;
    assert!(!signals_of(&without_inventory).has(Signal::PlacementSurface));

    // `propsAvailable` 为假时，装修面也不算就绪（它是宿主自己的判定）。
    let mut props_off = shipped_product_envelope();
    props_off["settings"]["stage"]["presentation"]["propsAvailable"] = json!(false);
    assert!(!signals_of(&props_off).has(Signal::PlacementSurface));
}

#[test]
fn the_product_shell_drives_the_same_gate_to_ready() {
    let mut signals = signals_of(&shipped_product_envelope());
    signals.observe_host(true, true, true);
    let mut gate = StartupGate::new();
    // 一次观察里，所有依赖已满足的项一起推进；此时还没有信号的那几项是 Preflight
    // （摆放网格/物理探针/生成服务），它们只会在自己的上界到点时**具名**变成
    // 「本轮不可用」，不挡人——所以这里先 Preparing，到点上界后必须 Ready。
    assert_eq!(gate.observe(&signals, 0), StartupPhase::Preparing);
    assert_eq!(
        gate.observe(&signals, 30_000),
        StartupPhase::Ready,
        "产品壳发布的那批信号必须足以开门：{}",
        gate.named()
            .iter()
            .map(|view| format!("{}={:?}", view.id, view.code))
            .collect::<Vec<_>>()
            .join(" ")
    );
    assert!(gate.failure().is_none(), "开门时不该有挡人失败");
}

#[test]
fn every_blocking_item_can_be_observed_from_a_product_shell_or_is_named() {
    // 产品壳能发布的那批信号，必须真的把每一个**挡人**项喂饱——否则加载态会在
    // 产品里永久挡住用户（这正是"接进产品壳"最危险的一种失败）。
    let mut signals = signals_of(&shipped_product_envelope());
    signals.observe_host(true, true, true);
    let mut gate = StartupGate::new();
    gate.observe(&signals, 0);
    for view in gate.steps() {
        let item = STARTUP_ITEMS.iter().find(|item| item.id == view.id).expect("from the table");
        if item.role == GateRole::Blocking {
            assert!(
                matches!(view.phase, StepPhase::Ready | StepPhase::Deferred),
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
