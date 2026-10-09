//! Renders 小窗's chat **inside the compact window's own 224×336 frame** through
//! GPUI's headless Metal renderer.
//!
//! Why this exists: clicking 聊天 in 小窗 used to look like "the window jumped
//! back to the big one", so the compact chat needs a picture that can be looked
//! at, and a real-layout regression that can fail. `screencapture` and synthetic
//! input are both unavailable here, so this harness paints the **real**
//! `ResidentChatPane` in the real compact box ([`gmgn_gpui_ui::chat::
//! compact_column`], `.compact-window .chat-column`, `Player.uss:102`) in a
//! headless window the size of the compact window.
//!
//! What it asserts, from the real prepared boxes rather than from the constants:
//!
//! * the message list and the composer both paint, and both stay inside the
//!   compact column's box — left 8, right at the reserved 48 pt Live Cam control
//!   column, 8 pt above the bottom, 244 pt tall;
//! * the composer is **whole** (input + its own padding) with an image attached
//!   too: the message list flexes in the compact column instead of holding the
//!   stage window's fixed 132 pt, which is what used to push the input out of the
//!   little window;
//! * the frame really carries ink inside the chat column, so a blank or clipped
//!   render fails instead of passing silently.
//!
//! Set `GMGN_SHOTS_DIR=/some/dir` to write `compact-chat.png` (输入框 + 消息) and
//! `compact-chat-attached.png` (the same column with an attachment pending).

#![recursion_limit = "256"]

use std::sync::Arc;

use gmgn_gpui_ui::chat::{self, ResidentChatPane};
use gmgn_gpui_ui::primitives as ui;
use gmgn_gpui_ui::state::TranscriptLine;
use gmgn_gpui_ui::ui_tokens::{chat as chat_metrics, scene, shell as shell_metrics};
use gpui_kit::assets::IconName;
use gpui_kit::prelude::*;
use gpui_kit::test::TestWindowExt as _;
use gpui_kit::*;
use serde_json::json;

/// The compact window itself (`UnityCompactWindowController`: 224×336 content).
const WIDTH: f32 = 224.;
const HEIGHT: f32 = 336.;

/// The backdrop the layer floats over: the same scene colour `ui_shots` uses, so
/// the fixed dark chrome can be read against a scene-like tone.
const BACKDROP: u32 = 0x2b2f36ff;

struct CompactWindow {
    chat: Entity<ResidentChatPane>,
}

impl Render for CompactWindow {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let _ = cx;
        div()
            .relative()
            .size_full()
            .bg(rgba(BACKDROP))
            .text_color(rgba(scene::TEXT))
            // The Live Cam control column, built from the very tokens the probe's
            // `compact_column()` reads (`Player.uss:96-97`: 30 pt entries, 6 pt
            // apart, 10 pt from the top/right corner). It is what the chat
            // column's 48 pt right inset is reserved for, so the picture shows
            // whether the chat really stops in front of it.
            .child(
                div()
                    .absolute()
                    .top(px(shell_metrics::COMPACT_MARGIN))
                    .right(px(shell_metrics::COMPACT_MARGIN))
                    .w(px(shell_metrics::COMPACT_CONTROL))
                    .flex()
                    .flex_col()
                    .gap(px(shell_metrics::COMPACT_CONTROL_GAP))
                    .children(
                        [
                            ("space", IconName::Globe, "空间"),
                            ("player", IconName::Music, "播放器"),
                            ("chat", IconName::Bot, "聊天"),
                            ("inbox", IconName::Bell, "通知"),
                            ("settings", IconName::Settings, "设置"),
                        ]
                        .map(|(id, icon, label)| {
                            ui::icon_button(id, icon, label, id == "chat", true)
                                .w(px(shell_metrics::COMPACT_CONTROL))
                                .h(px(shell_metrics::COMPACT_CONTROL))
                                .rounded(px(scene::CONTROL_RADIUS))
                                .bg(rgba(shell_metrics::COMPACT_CONTROL_BG))
                                .border_1()
                                .border_color(rgba(shell_metrics::COMPACT_CONTROL_BORDER))
                                .into_any_element()
                        }),
                    ),
            )
            // 小窗's chat, in place: the same pane, the original's compact box.
            .child(chat::compact_column(HEIGHT).child(self.chat.clone()))
    }
}

fn transcript() -> Vec<TranscriptLine> {
    [
        ("你", "就在小窗里说。"),
        ("居民", "好，我在小窗里回你。"),
    ]
    .into_iter()
    .map(|(speaker, text)| TranscriptLine {
        speaker: speaker.into(),
        text: text.into(),
    })
    .collect()
}

fn attached_snapshot() -> serde_json::Value {
    json!({
        "voiceState": "idle",
        "attachments": [{"id": "shot-compact-a", "fileName": "参考图.png"}],
        "attachmentsPreparing": false,
        "voiceActive": false,
        "isSpeaking": false,
        "canStop": false,
        "isThinking": false,
    })
}

/// Non-background pixels, and how many distinct colours the frame contains.
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

/// Ink inside one box: the share of the chat column's own rectangle that is not
/// the backdrop.
fn ink_in(image: &image::RgbaImage, rect: (f32, f32, f32, f32), background: [u8; 4]) -> u64 {
    let (x, y, w, h) = rect;
    let (x0, y0) = (x.max(0.).floor() as u32, y.max(0.).floor() as u32);
    let x1 = ((x + w).min(image.width() as f32).ceil() as u32).max(x0);
    let y1 = ((y + h).min(image.height() as f32).ceil() as u32).max(y0);
    let mut coloured = 0u64;
    for py in y0..y1 {
        for pxx in x0..x1 {
            let pixel = image.get_pixel(pxx, py);
            if [pixel[0], pixel[1], pixel[2], pixel[3]] != background {
                coloured += 1;
            }
        }
    }
    coloured
}

fn boxed(bounds: Bounds<Pixels>) -> (f32, f32, f32, f32) {
    (
        f32::from(bounds.origin.x),
        f32::from(bounds.origin.y),
        f32::from(bounds.size.width),
        f32::from(bounds.size.height),
    )
}

/// GPUI's macOS platform must be created on the main thread, so this is a
/// `harness = false` test binary (like `ui_shots`/`props_pane_shot`) rather than
/// a `#[test]`.
fn main() {
    the_compact_chat_paints_inside_the_224x336_window();
    println!("PASS compact_chat_shot: 小窗's chat column painted inside its own 224×336 window");
}

fn the_compact_chat_paints_inside_the_224x336_window() {
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(gpui_kit::assets::Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.update(gpui_kit::init);
    let (handle, view) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(WIDTH), px(HEIGHT)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    let pane = cx.new(|cx| {
                        // The host's window shape, painted by the pane.
                        let mut pane = ResidentChatPane::new(window, cx).compact_column(true);
                        pane.set_transcript(transcript(), cx);
                        pane
                    });
                    cx.new(|_| CompactWindow { chat: pane.clone() })
                },
            )
        })
        .expect("headless compact window");
    let pane = cx.update(|cx| view.read(cx).chat.clone());

    // The two boxes the chat surface really prepared, inside the window it was
    // laid out in.
    let first = cx
        .update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            let viewport = window.viewport_size();
            (
                (f32::from(viewport.width), f32::from(viewport.height)),
                boxed(
                    window
                        .find("resident-transcript")
                        .bounds(),
                ),
                boxed(window.find("resident-composer-card").bounds()),
            )
        })
        .unwrap();
    let (viewport, list, composer) = first;
    assert_eq!(viewport, (WIDTH, HEIGHT), "the compact window keeps its size");
    assert_inside_the_compact_column("消息列表", list);
    assert_inside_the_compact_column("输入框", composer);
    assert!(list.3 > 0., "the message list must paint inside 小窗: {list:?}");
    assert!(
        composer.3 >= chat_metrics::INPUT_MIN_HEIGHT + 2. * chat_metrics::CARD_PADDING,
        "the composer must be whole in 小窗, not clipped: {composer:?}"
    );
    assert!(
        list.1 + list.3 <= composer.1,
        "the message list sits above the composer in 小窗: {list:?} {composer:?}"
    );
    let shot = cx
        .capture_screenshot(handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");
    let (coloured, colours) = ink(&shot, [0x2b, 0x2f, 0x36, 0xff]);
    let total = u64::from(shot.width()) * u64::from(shot.height());
    assert!(
        coloured * 100 / total.max(1) > 5,
        "the compact window must paint visible content, painted {coloured}/{total} px"
    );
    assert!(
        colours > 24,
        "a painted compact chat has text, chrome and icons, not {colours} colours"
    );
    let in_column = ink_in(
        &shot,
        (
            chat_metrics::COMPACT_COLUMN_LEFT,
            HEIGHT - chat_metrics::COMPACT_COLUMN_BOTTOM - chat_metrics::COMPACT_COLUMN_HEIGHT,
            WIDTH - chat_metrics::COMPACT_COLUMN_LEFT - chat_metrics::COMPACT_COLUMN_RIGHT,
            chat_metrics::COMPACT_COLUMN_HEIGHT,
        ),
        [0x2b, 0x2f, 0x36, 0xff],
    );
    assert!(
        in_column > 400,
        "小窗's chat column must carry its own ink, found {in_column} px"
    );
    eprintln!(
        "SHOTS compact chat: viewport={viewport:?} 消息列表={list:?} 输入框={composer:?} ink_in_column={in_column}"
    );
    if let Some(dir) = std::env::var_os("GMGN_SHOTS_DIR") {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).expect("shots dir");
        let path = dir.join("compact-chat.png");
        shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
    }

    // The same column with an image pending: the message list flexes so the
    // composer still fits whole inside the 244 pt box. With the stage window's
    // fixed 132 pt transcript the composer's real box would be pushed past the
    // column's bottom and clipped — that is the "输入框在小窗里用不了" defect.
    cx.update(|cx| {
        pane.update(cx, |pane, cx| {
            pane.update_snapshot(attached_snapshot(), cx);
        });
    });    let attached = cx
        .update_window(handle, |_, window, cx| {
            window.render_frame(cx);
            (
                boxed(window.find("resident-transcript").bounds()),
                boxed(window.find("resident-composer-card").bounds()),
            )
        })
        .unwrap();
    let (list, composer) = attached;
    assert_inside_the_compact_column("消息列表（带附件）", list);
    assert_inside_the_compact_column("输入框（带附件）", composer);
    assert!(
        composer.3
            >= chat_metrics::ATTACHMENT_HEIGHT
                + chat_metrics::INPUT_MIN_HEIGHT
                + 2. * chat_metrics::CARD_PADDING,
        "with an image attached the composer must still be whole in 小窗: {composer:?}"
    );
    assert!(
        list.3 > 0.,
        "the message list must still paint with an image attached: {list:?}"
    );
    assert!(
        list.1 + list.3 <= composer.1 + 0.5,
        "the message list and the composer must not overlap in 小窗: {list:?} {composer:?}"
    );
    let attached_shot = cx
        .capture_screenshot(handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");
    eprintln!("SHOTS compact chat with attachment: 消息列表={list:?} 输入框={composer:?}");
    if let Some(dir) = std::env::var_os("GMGN_SHOTS_DIR") {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).expect("shots dir");
        let path = dir.join("compact-chat-attached.png");
        attached_shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
    }
}

/// Every piece of 小窗's chat stays inside the original's compact column
/// (`.compact-window .chat-column`: left 8, right at the reserved control
/// column, 8 above the bottom, 244 tall — `Player.uss:102`).
fn assert_inside_the_compact_column(name: &str, rect: (f32, f32, f32, f32)) {
    let left = chat_metrics::COMPACT_COLUMN_LEFT;
    let right = WIDTH - chat_metrics::COMPACT_COLUMN_RIGHT;
    let top = HEIGHT - chat_metrics::COMPACT_COLUMN_BOTTOM - chat_metrics::COMPACT_COLUMN_HEIGHT;
    let bottom = HEIGHT - chat_metrics::COMPACT_COLUMN_BOTTOM;
    let (x, y, w, h) = rect;
    assert!(w > 0. && h > 0., "{name} must paint a real box: {rect:?}");
    assert!(
        x >= left - 0.5 && x + w <= right + 0.5,
        "{name} must stay inside the compact column's width: {rect:?} column=[{left},{right}]"
    );
    assert!(
        y >= top - 0.5 && y + h <= bottom + 0.5,
        "{name} must stay inside the 244 pt compact column: {rect:?} column=[{top},{bottom}]"
    );
}
