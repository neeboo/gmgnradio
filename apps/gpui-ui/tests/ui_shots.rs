//! Renders the real panes to a PNG through GPUI's headless Metal renderer.
//!
//! Why this exists: `screencapture` and synthetic input are both blocked by
//! macOS privacy permissions in this environment, so "show me the UI" cannot go
//! through the window server. This harness renders the **same panes the product
//! mounts** (`ResidentChatPane`, `InboxPane`) with host-shaped fixtures into an
//! RGBA image, which is a picture of the shipping widgets rather than a mock-up.
//!
//! It is also a real regression: the captured image must contain actual painted
//! content (more than one colour, and a meaningful share of non-background
//! pixels), so a pane that renders nothing, or renders off its own bounds, fails
//! here instead of passing silently.
//!
//! Set `GMGN_SHOTS_DIR=/some/dir` to also write `chat-inbox.png`,
//! `selected-states.png` (the same frame, named for the 选中态 evidence) and
//! `settings.png` there. See the module docs above.
#![recursion_limit = "256"]

use std::sync::Arc;


use gmgn_gpui_ui::chat::ResidentChatPane;
use gmgn_gpui_ui::inbox::InboxPane;
use gmgn_gpui_ui::primitives as ui;
use gmgn_gpui_ui::settings::AgentSettingsPane;
use gmgn_gpui_ui::state::TranscriptLine;
use gmgn_gpui_ui::shell::{self, TransportControl};
use gmgn_gpui_ui::ui_tokens::{inbox as inbox_metrics, scene};
use gpui_kit::prelude::*;
use gpui_kit::test::TestWindowExt as _;
use gpui_kit::*;
use serde_json::json;

struct Shots {
    chat: Entity<ResidentChatPane>,
    inbox: Entity<InboxPane>,
    /// The 音量 track's state, so the shot can paint a real kit `Slider` through
    /// [`gmgn_gpui_ui::primitives::scene_slider`] and show its filled part.
    volume: Entity<gpui_kit::component::slider::SliderState>,
}

fn transcript() -> Vec<TranscriptLine> {
    [
        ("你", "把电视放到墙边，屏幕朝沙发。"),
        ("居民", "放好了，屏幕正对沙发，四边各留了 9 毫米边框。"),
        ("系统", "「超大荧幕电视」已摆放。"),
        ("你", "给电视放一段视频。"),
    ]
    .into_iter()
    .map(|(speaker, text)| TranscriptLine {
        speaker: speaker.into(),
        text: text.into(),
    })
    .collect()
}

fn chat_snapshot() -> serde_json::Value {
    json!({
        "voiceState": "idle",
        "attachments": [{"id": "shot-a", "fileName": "参考图.png"}],
        "attachmentsPreparing": false,
        "voiceActive": false,
        "isSpeaking": false,
        "canStop": false,
        "isThinking": true,
        "progress": "正在查询歌单…",
        "statusNotice": "该物件已摆放，无需再次摆放。",
        "reply": "我可以按刚才那张参考图重新生成一版，尺寸还是 1443 × 862 × 302 毫米。",
    })
}

fn inbox_snapshot() -> serde_json::Value {
    json!({
        "scope": "world:showcase",
        "entries": [
            {"id": "m1", "eventID": "event-m1", "isRead": false,
             "title": "「超大荧幕电视」已摆放", "status": "已完成",
             "relativeTimeText": "刚刚", "updatedAtText": "2026年10月8日 16:20",
             "detail": "物件已进入空间，位置与朝向已保存。\n屏幕范围由最大平坦面推断：法向 +Z（正面），四边各留边框 9 毫米。"},
            {"id": "m2", "eventID": "event-m2", "isRead": false,
             "title": "「暖光落地灯」生成中", "status": "进行中",
             "relativeTimeText": "6分钟前", "updatedAtText": "2026年10月8日 16:14",
             "detail": "生成队列第 2 位。"},
            {"id": "m3", "eventID": "event-m3", "isRead": true,
             "title": "「2B 白色长剑（外形摆件）」已删除", "status": "已结束",
             "relativeTimeText": "9小时前", "updatedAtText": "2026年10月8日 7:30",
             "detail": "删除不可恢复。"}
        ]
    })
}

impl Render for Shots {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let _ = cx;
        div()
            .size_full()
            .flex()
            .items_start()
            .gap(px(24.))
            .p(px(28.))
            // A mid-tone backdrop: the layer floats over the rendered space, so
            // the fixed dark chrome has to be read against a scene-like colour.
            .bg(rgba(0x2b2f36ff))
            .text_color(rgba(scene::TEXT))
            .child(div().id("shots-chat").w(px(620.)).flex_shrink_0().child(self.chat.clone()))
            .child(
                div()
                    .id("shots-inbox")
                    .w(px(inbox_metrics::WINDOW_WIDTH))
                    .h(px(inbox_metrics::WINDOW_HEIGHT))
                    .flex_shrink_0()
                    .child(self.inbox.clone()),
            )
            // The fixed floating bar, over a stand-in for the rendered space.
            .child(
                div()
                    .relative()
                    .w(px(590.))
                    .h(px(inbox_metrics::WINDOW_HEIGHT))
                    .flex_shrink_0()
                    .rounded(px(12.))
                    .bg(rgba(0x151a20ff))
                    .child(shell::destination_button(
                        gpui_kit::component::Icon::new(gpui_kit::assets::IconName::Globe),
                        "进入空间",
                        true,
                        |_, _, _| {},
                    ))
                    .child(shell::transport_bar(transport_controls(), |_, _, _| {}, |_, _, _, _| {})),
            )
            // 选中态 — the shipping selected surfaces, side by side: the
            // segmented picker's current face, the settings 使用中 marker, an
            // on/off switch and the 音量 track. Every one of them is built by
            // `primitives`, which paints them from `scene::SELECTED`.
            .child(
                div()
                    .id("shots-selected")
                    .w(px(320.))
                    .flex_shrink_0()
                    .flex()
                    .flex_col()
                    .gap(px(16.))
                    .child(ui::selected_tabs(
                        "shots-selected-tabs",
                        vec![
                            ui::TabFace::text("经典"),
                            ui::TabFace::text("渐变"),
                            ui::TabFace::text("海报"),
                        ],
                        1,
                        |_, _, _| {},
                    ))
                    .child(
                        div()
                            .flex()
                            .items_center()
                            .gap(px(12.))
                            .child(ui::selected_marker(
                                "shots-selected-marker",
                                gpui_kit::assets::IconName::Check,
                                "使用中",
                            ))
                            .child(ui::selected_switch("shots-selected-on").checked(true))
                            .child(ui::selected_switch("shots-selected-off").checked(false)),
                    )
                    .child(
                        div()
                            .w(px(220.))
                            .h(px(24.))
                            .flex()
                            .items_center()
                            .child(ui::scene_slider(&self.volume)),
                    ),
            )
    }
}

/// The eleven controls of the original bar, in the original order.
fn transport_controls() -> Vec<TransportControl> {
    use gpui_kit::assets::IconName;
    vec![
        TransportControl::new("program", "program", IconName::FileText, "节目"),
        TransportControl::new("previous", "previousTrack", IconName::ChevronLeft, "上一首"),
        TransportControl::new("play", "togglePlayback", IconName::Play, "播放").active(true),
        TransportControl::new("next", "nextTrack", IconName::ChevronRight, "下一首").ends_group(true),
        TransportControl::new("voice", "voice", IconName::Mic, "语音"),
        TransportControl::new("chat", "chat", IconName::Bot, "聊天").active(true),
        TransportControl::new("inbox", "showNotifications", IconName::Bell, "通知"),
        TransportControl::new("props", "toggleDecoration", IconName::Frame, "装修"),
        TransportControl::new("screen", "screen", IconName::PanelRight, "屏幕操作"),
        TransportControl::new("visual", "visual", IconName::Settings, "舞台设置"),
        TransportControl::new("mode", "mode", IconName::Maximize, "窗口"),
    ]
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

/// Pixels carrying the layer's selected blue, `scene::SELECTED = #3B9EFF`.
///
/// The box is tight enough to exclude the kit theme's blue (`#1d4ed8`, only
/// 0x1d red and 0x4e green) and the old cyan (`#7af2ff`, 0x7a red), so this is a
/// real "the selected state painted the token" check rather than "something blue
/// is on screen".
fn selected_blue_pixels(image: &image::RgbaImage) -> u64 {
    image
        .pixels()
        .filter(|pixel| {
            let (r, g, b) = (i32::from(pixel[0]), i32::from(pixel[1]), i32::from(pixel[2]));
            (r - 0x3b).abs() <= 8 && (g - 0x9e).abs() <= 8 && (b - 0xff).abs() <= 8
        })
        .count() as u64
}

/// GPUI's macOS platform must be created on the main thread, so this is a
/// `harness = false` test binary (like gpui-kit's own rendering suite) rather
/// than a `#[test]`.
fn main() {
    real_panes_paint_visible_content_and_can_be_captured();
    println!("PASS ui_shots: the chat and inbox panes painted real content");
}

fn real_panes_paint_visible_content_and_can_be_captured() {
    let mut cx = HeadlessAppContext::with_platform(
        gpui_kit::platform::current_platform(true).text_system(),
        Arc::new(gpui_kit::assets::Assets),
        gpui_kit::platform::current_headless_renderer,
    );
    cx.update(gpui_kit::init);
    let (width, height) = (2560., 560.);
    let (handle, _) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(px(width), px(height)),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    let chat = cx.new(|cx| {
                        let mut pane = ResidentChatPane::new(window, cx);
                        pane.set_transcript(transcript(), cx);
                        pane.update_snapshot(chat_snapshot(), cx);
                        pane
                    });
                    let inbox = cx.new(|cx| {
                        let mut pane = InboxPane::new(cx);
                        pane.update_snapshot(inbox_snapshot(), cx);
                        // The **selected** row is part of the picture: a harness
                        // may not synthesise input, so the pane exposes the
                        // selection directly.
                        pane.select_index(0, cx);
                        pane
                    });
                    let volume = cx.new(|_| gpui_kit::component::slider::SliderState::new());
                    cx.new(|_| Shots { chat, inbox, volume })
                },
            )
        })
        .expect("headless window");
    cx.update_window(handle, |_, window, cx| {
        window.render_frame(cx);
    })
    .unwrap();
    let shot = cx
        .capture_screenshot(handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");

    // The layer paints on a 0x2b2f36 backdrop; anything else is content.
    let (coloured, colours) = ink(&shot, [0x2b, 0x2f, 0x36, 0xff]);
    let total = u64::from(shot.width()) * u64::from(shot.height());
    assert!(
        coloured * 100 / total.max(1) > 5,
        "the panes must cover a visible share of the frame, painted {coloured}/{total} px"
    );
    assert!(
        colours > 24,
        "a painted chat + inbox frame has text, icons and chrome, not {colours} colours"
    );
    // 选中态: the asserted transport controls (播放 / 聊天), the selected inbox row
    // and the 选中态 column must all be painted with `scene::SELECTED`.
    let selected = selected_blue_pixels(&shot);
    assert!(
        selected > 400,
        "the selected state must paint `scene::SELECTED` (#3B9EFF): the frame carries only \
         {selected} such pixel(s), so a selected surface is drawing a theme colour again"
    );
    eprintln!("SHOTS selected-blue pixels in the bar/inbox/选中态 frame: {selected}");

    if let Some(dir) = std::env::var_os("GMGN_SHOTS_DIR") {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).expect("shots dir");
        let path = dir.join("chat-inbox.png");
        shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
        let path = dir.join("selected-states.png");
        shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
    }

    // 设置页 — the real `AgentSettingsPane` at its original 580×500, on the
    // 角色 page: the five-tab header's icons and the row icons are the ones the
    // icon-colour pass re-tones.
    let (settings_handle, _) = cx
        .update(|cx| {
            gpui_kit::open_window(
                WindowOptions {
                    window_bounds: Some(WindowBounds::Windowed(Bounds {
                        origin: Default::default(),
                        size: size(
                            px(gmgn_gpui_ui::ui_tokens::settings::WINDOW_WIDTH),
                            px(gmgn_gpui_ui::ui_tokens::settings::WINDOW_HEIGHT),
                        ),
                    })),
                    focus: false,
                    show: false,
                    ..Default::default()
                },
                cx,
                |window, cx| {
                    let pane = cx.new(|cx| AgentSettingsPane::new(window, cx));
                    pane.update(cx, |pane, cx| {
                        pane.update_snapshot(settings_snapshot(), window, cx);
                        pane.select_page("presence", cx);
                    });
                    pane
                },
            )
        })
        .expect("headless settings window");
    cx.update_window(settings_handle, |_, window, cx| {
        window.render_frame(cx);
    })
    .unwrap();
    let settings_shot = cx
        .capture_screenshot(settings_handle)
        .expect("GPUI's headless Metal renderer must be available on macOS");
    let (settings_ink, settings_colours) = ink(&settings_shot, [0x00, 0x00, 0x00, 0x00]);
    assert!(
        settings_colours > 24,
        "a painted settings page has text, icons and chrome, not {settings_colours} colours"
    );
    assert!(
        settings_ink > 0,
        "the settings page must paint visible content"
    );
    // The page's own selected states: the 使用中 marker on the active 角色 row,
    // the five-segment header's current tab and the 动作 category picker.
    let settings_selected = selected_blue_pixels(&settings_shot);
    assert!(
        settings_selected > 100,
        "the settings page must paint its current/使用中 state with `scene::SELECTED`; it \
         carries only {settings_selected} such pixel(s)"
    );
    eprintln!("SHOTS selected-blue pixels on the settings page: {settings_selected}");
    if let Some(dir) = std::env::var_os("GMGN_SHOTS_DIR") {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).expect("shots dir");
        let path = dir.join("settings.png");
        settings_shot.save(&path).expect("write png");
        eprintln!("SHOTS wrote {}", path.display());
    }
}

/// A host-shaped settings projection: one active 角色, one connected 音乐
/// account and the shortcut page, so every icon role on the page has a face.
fn settings_snapshot() -> serde_json::Value {
    json!({
        "locale": "zh-CN",
        "presence": {
            "packages": [
                {"id": "orb", "name": "呼吸球", "engine": "orb", "isBuiltIn": true,
                 "isActive": true, "rendererAvailable": true},
                {"id": "fox", "name": "狐娘", "engine": "pmx", "isBuiltIn": false,
                 "isActive": false, "rendererAvailable": true}
            ],
            "motions": [], "publishedMotions": [], "working": false,
            "catalogURL": "https://example.test/catalog.json"
        },
        "music": {
            "providers": [
                {"id": "netease", "name": "网易云音乐", "status": "connected", "connected": true},
                {"id": "qq-music", "name": "QQ 音乐", "status": "disconnected", "connected": false}
            ],
            "working": false
        },
        "space": {
            "options": [{"id": "living-pod", "name": "飞船生活舱（Marble）", "detail": "Marble 生成舱体"}],
            "defaultSpace": "living-pod", "credentialConfigured": true,
            "generationEndpoint": "https://example.test/gen", "propSaveEndpoint": "https://example.test/prop",
            "marbleKeyConfigured": true
        },
        "shortcuts": {
            "assignments": [
                {"id": "play", "title": "播放 / 暂停", "local": "Space", "global": ""},
                {"id": "chat", "title": "打开聊天", "local": "KeyC", "global": ""}
            ],
            "globalEnabled": true, "mediaKeysEnabled": false
        },
        "agent": {"codexState": "signedOut", "backends": [], "budgetOptions": [0, 6]},
        "tts": {"providers": [], "voices": [], "models": [], "loading": false, "isSpeaking": false},
        "asr": {"providers": [], "microphoneDevices": [], "models": []},
        "spaceLibrary": {"worlds": [], "marblePresets": []},
        "video": {"selectedID": null, "activeID": null, "playing": false, "mode": "once"},
        "generation": {"configured": true, "checking": false},
        "isSaving": false
    })
}
