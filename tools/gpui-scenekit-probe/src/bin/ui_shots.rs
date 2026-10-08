//! Screenshot harness for the rewritten GPUI UI layer.
//!
//! It mounts the **real** panes (`ResidentChatPane`, `InboxPane`) with
//! host-shaped fixtures and shows them side by side in one window, so a plain
//! `screencapture` of that window is a picture of the shipping widgets rather
//! than a mock-up. Nothing here is a second implementation: seeding goes through
//! the same entry points the host uses (`set_transcript` / `update_snapshot`).
//!
//! Usage:
//! ```text
//! GMGN_SHOTS=chat,inbox GMGN_SHOTS_EXIT_MS=0 cargo run --bin ui-shots --offline
//! ```
//! `GMGN_SHOTS_EXIT_MS` closes the window after that many milliseconds; `0`
//! (the default) leaves it open for a human or a script to capture.
use std::time::Duration;

use gmgn_gpui_ui::chat::ResidentChatPane;
use gmgn_gpui_ui::inbox::InboxPane;
use gmgn_gpui_ui::state::TranscriptLine;
use gmgn_gpui_ui::ui_tokens::scene;
use gpui_kit::prelude::InteractiveElement as _;
use gpui_kit::*;
use serde_json::json;

struct Shots {
    chat: Entity<ResidentChatPane>,
    inbox: Entity<InboxPane>,
    show_chat: bool,
    show_inbox: bool,
}

/// One line of a real conversation shape: a person's turn, the resident's
/// answer, and a system notice (unlabelled and warning-coloured, like the
/// original).
fn transcript() -> Vec<TranscriptLine> {
    [
        ("你", "把电视放到墙边，屏幕朝沙发。"),
        ("居民", "放好了，屏幕正对沙发，边框留了 9 毫米。"),
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
        "attachments": [
            {"id": "shot-a", "fileName": "参考图.png"},
        ],
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
        let mut row = div()
            .size_full()
            .flex()
            .items_start()
            .gap(px(24.))
            .p(px(28.))
            // The layer floats over the 3D scene; a mid-tone backdrop makes the
            // fixed dark chrome readable exactly as it will be in the app.
            .bg(rgba(0x2b2f36ff))
            .text_color(rgba(scene::TEXT));
        if self.show_chat {
            row = row.child(
                div()
                    .id("shots-chat")
                    .w(px(620.))
                    .flex_shrink_0()
                    .child(self.chat.clone()),
            );
        }
        if self.show_inbox {
            row = row.child(
                div()
                    .id("shots-inbox")
                    .w(px(gmgn_gpui_ui::ui_tokens::inbox::WINDOW_WIDTH))
                    .h(px(gmgn_gpui_ui::ui_tokens::inbox::WINDOW_HEIGHT))
                    .flex_shrink_0()
                    .child(self.inbox.clone()),
            );
        }
        let _ = cx;
        row
    }
}

fn main() {
    let wanted: Vec<String> = std::env::var("GMGN_SHOTS")
        .unwrap_or_else(|_| "chat,inbox".into())
        .split(',')
        .map(|part| part.trim().to_owned())
        .collect();
    let show_chat = wanted.iter().any(|name| name == "chat");
    let show_inbox = wanted.iter().any(|name| name == "inbox");
    let exit_ms: u64 = std::env::var("GMGN_SHOTS_EXIT_MS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(0);

    gpui_kit::application().run(move |cx| {
        gpui_kit::init(cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(Bounds::new(
                    point(px(60.), px(60.)),
                    size(px(1420.), px(560.)),
                ))),
                titlebar: Some(TitlebarOptions::default()),
                is_resizable: true,
                focus: true,
                window_background: WindowBackgroundAppearance::Opaque,
                ..Default::default()
            },
            move |window, cx| {
                let chat = cx.new(|cx| {
                    let mut pane = ResidentChatPane::new(window, cx);
                    pane.set_transcript(transcript(), cx);
                    pane.update_snapshot(chat_snapshot(), cx);
                    pane
                });
                let inbox = cx.new(|cx| {
                    let mut pane = InboxPane::new(cx);
                    pane.update_snapshot(inbox_snapshot(), cx);
                    pane
                });
                if exit_ms > 0 {
                    let timer = cx.background_executor().timer(Duration::from_millis(exit_ms));
                    cx.spawn(async move |cx| {
                        timer.await;
                        cx.update(|cx| cx.quit());
                    })
                    .detach();
                }
                let view = cx.new(|_| Shots {
                    chat,
                    inbox,
                    show_chat,
                    show_inbox,
                });
                cx.new(|cx| gpui_kit::base::Root::new(view, window, cx).bg(rgba(0x2b2f36ff)))
            },
        )
        .expect("shots window");
        cx.activate(true);
    });
}
