//! 启动加载态**作为像素**：步骤名 + 进度 + 具名失败 + 重试。
//!
//! 用户 2026-10-09 的判断：与其到处暴露"没 ready"，不如一开始做一个"很长的加载态"，
//! 把所有东西准备好再放人进去。这一层要能**被看见**——一句"有步骤名和进度"不算
//! 证据，一张真渲染出来的帧才算。`screencapture`/合成输入在这里都是禁止的，所以
//! 这个 harness 把**真的** `StartupGatePane` 挂进一个无头窗口，用 GPUI 自己的
//! Metal 渲染器抓帧。
//!
//! 写出的帧（设 `GMGN_SHOTS_DIR`）：
//!
//! * `startup-loading.png` —— 准备中：一部分步骤 `完成`、一部分 `准备中`，整条进度
//!   条与 `n/m 项已就绪`；
//! * `startup-blocked.png` —— 卡住：整体超时之后的**具名**失败（哪一项、什么码、
//!   第几次尝试）与「重试」控件，以及"进门后按需"的具名列表。
//!
//! 每一帧同时是判据：
//!
//! 1. 准备中**不许**出现重试（失败才可重试，否则就是把"还没好"说成"坏了"）；
//! 2. 卡住时**必须**有具名失败块与可点到的重试控件；
//! 3. 两个帧都必须有真实墨迹与颜色数（退化成空卡片就红）；
//! 4. 全部信号观测到之后，加载态**必须**不再盖住窗口。
#![recursion_limit = "256"]

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use gmgn_gpui_ui::startup::{
    STARTUP_DEADLINE_MS, StartupGatePane, StartupPhase, StartupSignals, Signal,
};

use gpui_kit::prelude::*;
use gpui_kit::test::{ElementSnapshot, TestWindowExt as _};
use gpui_kit::*;

/// The product stage window (`main.rs` opens 1180×760 and clamps to 760×520).
const STAGE: (f32, f32) = (1180., 760.);

struct Shot {
    pane: Entity<StartupGatePane>,
}

impl Render for Shot {
    fn render(&mut self, _: &mut Window, _: &mut Context<Self>) -> impl IntoElement {
        // The real host paints the loading surface over the whole window
        // (`apps/gpui-app/src/main.rs`, `OverlaySlot::StartupGate`).
        div().size_full().child(self.pane.clone())
    }
}

struct Session {
    handle: gpui_kit::AnyWindowHandle,
    pane: Entity<StartupGatePane>,
}

/// Everything the host can observe **today**, minus the placement/physics/generation
/// projections (which no host publishes yet — see the module's honest boundary):
/// this is the "half ready" frame a person really sees during the 17 s prepare.
fn half_ready_signals() -> StartupSignals {
    let mut signals = StartupSignals::new();
    signals.observe_host(true, true, true);
    // `WorldVisible` 与 `ResidentSession` **刻意不给**：这一帧要是"世界还在准备"的
    // 真实现场（`[WorldPrepare] step=recover…` 那 17 秒），所以最贵的几步必须显示
    // 成「准备中」，后面的几步显示成「等待」——全绿的一帧是一张说明书，不是现场。
    for signal in [
        Signal::WorldRequested,
        Signal::PlacementSurface,
        Signal::StageProjection,
        Signal::ActivityCatalog,
        Signal::InboxProjection,
        Signal::WishProjection,
        Signal::ScreenProjection,
        Signal::SettingsProjection,
        Signal::MusicLibrary,
        Signal::PlayerMenu,
    ] {
        signals.set(signal, true);
    }
    signals
}

fn open(cx: &mut HeadlessAppContext) -> Session {
    let slot: Rc<RefCell<Option<Entity<StartupGatePane>>>> = Rc::new(RefCell::new(None));
    let pane_slot = slot.clone();
    let (handle, _) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(STAGE.0), px(STAGE.1)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                move |_, cx| {
                    let pane = cx.new(StartupGatePane::new);
                    *pane_slot.borrow_mut() = Some(pane.clone());
                    cx.new(|_| Shot { pane })
                },
            )
        })
        .expect("headless startup window");
    Session { handle, pane: slot.borrow().clone().expect("pane built") }
}

fn drive(cx: &mut HeadlessAppContext, session: &Session, signals: &StartupSignals, now_ms: u64) -> StartupPhase {
    let signals = signals.clone();
    cx.update(|cx| {
        session
            .pane
            .update(cx, |pane, cx| pane.observe(&signals, now_ms, cx))
    })
}

fn frame(cx: &mut HeadlessAppContext, session: &Session, name: &str, dir: &Option<std::path::PathBuf>) -> image::RgbaImage {
    let shot = cx
        .update_window(session.handle, |_, window, cx| window.render_frame(cx))
        .map(|_| ())
        .and_then(|_| cx.capture_screenshot(session.handle))
        .unwrap_or_else(|_| panic!("{name}: GPUI's headless Metal renderer must be available on macOS"));
    if let Some(dir) = dir {
        let path = dir.join(name);
        shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
    }
    shot
}

fn ink(image: &image::RgbaImage, background: [u8; 4]) -> (u64, usize) {
    let mut coloured = 0u64;
    let mut seen: std::collections::HashSet<[u8; 4]> = std::collections::HashSet::new();
    for pixel in image.pixels() {
        let value = [pixel[0], pixel[1], pixel[2], pixel[3]];
        if value != background {
            coloured += 1;
        }
        if seen.len() < 4096 {
            seen.insert(value);
        }
    }
    (coloured, seen.len())
}

fn find(cx: &mut HeadlessAppContext, session: &Session, id: &'static str) -> Option<(ElementSnapshot, bool)> {
    cx.update_window(session.handle, |_, window, cx| {
        window.render_frame(cx);
        window.try_find(id).map(|snapshot| {
            let visible = snapshot.visible();
            (snapshot, visible)
        })
    })
    .unwrap()
}

fn main() {
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(gpui_kit::assets::Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.update(gpui_kit::init);
    cx.update(|cx| gpui_kit::component::Theme::change(gpui_kit::component::ThemeMode::Dark, None, cx));
    let dir = std::env::var_os("GMGN_SHOTS_DIR").map(std::path::PathBuf::from);
    if let Some(dir) = &dir {
        std::fs::create_dir_all(dir).expect("shots dir");
    }
    let mut failures: Vec<String> = Vec::new();

    // ---- 准备中：步骤名 + 进度，**没有**重试 ----------------------------------
    let session = open(&mut cx);
    let phase = drive(&mut cx, &session, &half_ready_signals(), 1_200);
    if phase != StartupPhase::Preparing {
        failures.push(format!("half-ready signals must leave the gate Preparing, got {phase:?}"));
    }
    let loading = frame(&mut cx, &session, "startup-loading.png", &dir);
    let (loading_ink, loading_colours) = ink(&loading, [0, 0, 0, 0]);
    let total = u64::from(loading.width()) * u64::from(loading.height());
    if loading_ink * 100 / total.max(1) < 8 {
        failures.push(format!("startup-loading: only {loading_ink}/{total} px painted"));
    }
    if loading_colours < 32 {
        failures.push(format!("startup-loading: {loading_colours} colours is not a painted surface"));
    }
    for id in ["startup.gate", "startup.steps"] {
        match find(&mut cx, &session, id) {
            Some((_, true)) => {}
            Some((_, false)) => failures.push(format!("startup-loading: {id} is laid out but not visible")),
            None => failures.push(format!("startup-loading: {id} is missing")),
        }
    }
    if find(&mut cx, &session, "startup.retry").is_some() {
        failures.push("startup-loading: a retry must not be offered before anything failed".into());
    }
    if !session.pane.read_with(&mut cx, |pane, _| pane.covers_window()) {
        failures.push("startup-loading: the gate must still cover the window".into());
    }
    // 每一条挡人步骤名都在帧里（进度条数的是它们）。名字是断言的对象，不是样式。
    let views = session.pane.read_with(&mut cx, |pane, _| pane.gate().steps());
    let ready = views.iter().filter(|view| matches!(view.phase, gmgn_gpui_ui::startup::StepPhase::Ready)).count();
    if ready == 0 || ready == views.len() {
        failures.push(format!("startup-loading: the frame must show a real mix, {ready}/{} ready", views.len()));
    }
    println!(
        "MEASURE startup-loading: {ready}/{} steps ready, ink {loading_ink}/{total} px, {loading_colours} colours",
        views.len()
    );

    // ---- 卡住：具名失败 + 重试 + "进门后按需" 的具名列表 ----------------------
    let stalled = open(&mut cx);
    drive(&mut cx, &stalled, &StartupSignals::new(), 0);
    let phase = drive(&mut cx, &stalled, &StartupSignals::new(), STARTUP_DEADLINE_MS + 1);
    if phase != StartupPhase::Blocked {
        failures.push(format!("an empty signal set past the deadline must Block, got {phase:?}"));
    }
    let blocked = frame(&mut cx, &stalled, "startup-blocked.png", &dir);
    let (blocked_ink, blocked_colours) = ink(&blocked, [0, 0, 0, 0]);
    let total = u64::from(blocked.width()) * u64::from(blocked.height());
    if blocked_ink * 100 / total.max(1) < 8 {
        failures.push(format!("startup-blocked: only {blocked_ink}/{total} px painted"));
    }
    if blocked_colours < 32 {
        failures.push(format!("startup-blocked: {blocked_colours} colours is not a painted surface"));
    }
    match find(&mut cx, &stalled, "startup.failure") {
        Some((_, true)) => {}
        Some((_, false)) => failures.push("startup-blocked: the named failure is not visible".into()),
        None => failures.push("startup-blocked: a Blocked gate must paint a named failure".into()),
    }
    match find(&mut cx, &stalled, "startup.retry") {
        Some((snapshot, true)) => {
            let bounds = snapshot.bounds();
            if f32::from(bounds.size.width) < 8. || f32::from(bounds.size.height) < 8. {
                failures.push(format!("startup-blocked: the retry control is {bounds:?}"));
            }
        }
        Some((_, false)) => failures.push("startup-blocked: the retry control is not visible".into()),
        None => failures.push("startup-blocked: a bounded failure must offer 重试".into()),
    }
    let failure = stalled.pane.read_with(&mut cx, |pane, _| pane.gate().failure());
    match &failure {
        Some(failure) => {
            if failure.code.is_empty() || failure.label.is_empty() || failure.message.is_empty() {
                failures.push(format!("startup-blocked: the failure is not named: {failure:?}"));
            }
            println!("MEASURE startup-blocked: step={} code={} attempt={}", failure.step, failure.code, stalled.pane.read_with(&mut cx, |pane, _| pane.gate().attempt()));
        }
        None => failures.push("startup-blocked: no failure recorded".into()),
    }
    let named = stalled.pane.read_with(&mut cx, |pane, _| pane.gate().named());
    if named.is_empty() {
        failures.push("startup-blocked: every miss must be named on the surface".into());
    }
    println!(
        "MEASURE startup-blocked: {} named entries, ink {blocked_ink}/{total} px, {blocked_colours} colours",
        named.len()
    );

    // ---- 全部就绪：加载态必须让位 -------------------------------------------
    let done = open(&mut cx);
    let mut signals = StartupSignals::new();
    for item in gmgn_gpui_ui::startup::STARTUP_ITEMS {
        signals.set(item.signal, true);
    }
    drive(&mut cx, &done, &signals, 0);
    let phase = drive(&mut cx, &done, &signals, 1);
    if phase != StartupPhase::Ready {
        failures.push(format!("every signal observed must open the gate, got {phase:?}"));
    }
    if done.pane.read_with(&mut cx, |pane, _| pane.covers_window()) {
        failures.push("a Ready gate must stop covering the window".into());
    }
    if find(&mut cx, &done, "startup.gate").is_some() {
        failures.push("a Ready gate must not paint at all (no transparent lid)".into());
    }

    if failures.is_empty() {
        println!("PASS startup_gate_shot: loading + blocked frames painted, named failure and retry reachable");
    } else {
        for failure in &failures {
            eprintln!("FAIL {failure}");
        }
        std::process::exit(1);
    }
}
