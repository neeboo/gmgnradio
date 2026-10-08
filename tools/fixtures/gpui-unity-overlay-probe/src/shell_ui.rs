//! Embedded production shell; host snapshots remain authoritative.
use crate::{UiCommandQueue, enqueue_ui_command};
use gmgn_gpui_ui::shell::{self, TransportControl};
use gmgn_gpui_ui::ui_tokens::{chat, scene, shell as metrics, stage};
use gpui_kit::assets::IconName;
use gpui_kit::component::{
    ActiveTheme, WindowExt,
    slider::{Slider, SliderEvent, SliderState},
};
use gpui_kit::*;
use serde_json::{Value, json};

fn action_command(action: &str, playing: bool) -> Option<Value> {
    let op = match action {
        "previous" => "music.previous",
        "next" => "music.next",
        "play" => {
            if playing {
                "music.pause"
            } else {
                "music.play"
            }
        }
        "mode" => "ui.window.fullscreen",
        "lyrics" => "ui.lyrics.toggle",
        "compact" => "ui.window.compact",
        "visual" => "ui.settings.open",
        _ => return None,
    };
    Some(json!({"op":op}))
}
fn media_section(action: &str) -> Option<&'static str> {
    match action {
        "program" => Some("programs"),
        "inbox" => Some("inbox"),
        "screen" => Some("screen"),
        _ => None,
    }
}

fn panel_container(is_chat: bool, width: f32, height: f32) -> Div {
    let panel = div()
        .absolute()
        .right(px(metrics::TRANSPORT_INSET))
        .bottom(px(metrics::TRANSPORT_INSET
            + metrics::TRANSPORT_HEIGHT
            + metrics::COMPOSER_GAP))
        .w(px(width))
        .max_h(px(height))
        .flex()
        .flex_col()
        .min_h_0()
        .min_w_0()
        .overflow_hidden();
    // Chat is content-sized: pin its actual visible bottom above the bar.
    // A fixed-height flex wrapper leaves empty space below a short composer.
    if is_chat { panel } else { panel.h(px(height)) }
}

pub struct ShellPane {
    commands: UiCommandQueue,
    panes: Vec<(String, AnyView)>,
    selected: Option<usize>,
    media_action: Option<&'static str>,
    snapshot: Value,
    volume: Entity<SliderState>,
    syncing: bool,
    queue_error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl ShellPane {
    pub fn new(
        _: &mut Window,
        cx: &mut Context<Self>,
        commands: UiCommandQueue,
        panes: Vec<(String, AnyView)>,
    ) -> Self {
        let volume = cx.new(|_| SliderState::new().min(0.).max(1.).step(0.01));
        let subscription = cx.subscribe(&volume, |this, _, event: &SliderEvent, cx| {
            if !this.syncing && this.connected() {
                if let SliderEvent::Release(value) = event {
                    this.submit(json!({"op":"music.volume","value":value.start()}), cx);
                }
            }
        });
        Self {
            commands,
            panes,
            selected: None,
            media_action: None,
            snapshot: Value::Null,
            volume,
            syncing: false,
            queue_error: None,
            _subscriptions: vec![subscription],
        }
    }
    pub fn open_panel(&mut self, label: &str, _: &mut Window, cx: &mut Context<Self>) {
        let Some(index) = self.panes.iter().position(|(name, _)| name == label) else {
            return;
        };
        self.set_panel(Some(index), cx);
    }
    fn set_panel(&mut self, selected: Option<usize>, cx: &mut Context<Self>) -> bool {
        if enqueue_ui_command(
            &self.commands,
            json!({"op":"ui.overlay.panel","expanded":selected.is_some()}),
        ) {
            self.selected = selected;
            self.queue_error = None;
            cx.notify();
            true
        } else {
            self.queue_error = Some("操作队列已满，请稍后再试。".into());
            cx.notify();
            false
        }
    }
    pub fn close_panel(&mut self, _: &mut Window, cx: &mut Context<Self>) -> bool {
        self.selected.is_some() && self.set_panel(None, cx)
    }
    /// The same, from a caller that only has a windowless context. Used by the
    /// 物品 panel's × (`inventory_ui.rs`), which asks the shell to close the
    /// panel it is drawn inside; the native hit region follows through the
    /// normal `ui.overlay.panel` byte path, because nothing pops the command.
    pub fn close_panel_without_window(&mut self, cx: &mut Context<Self>) -> bool {
        self.set_panel(None, cx)
    }
    fn toggle_panel(&mut self, label: &str, cx: &mut Context<Self>) {
        if let Some(index) = self.panes.iter().position(|(name, _)| name == label) {
            self.set_panel(
                if self.selected == Some(index) {
                    None
                } else {
                    Some(index)
                },
                cx,
            );
        }
    }
    fn connected(&self) -> bool {
        self.snapshot["ui"]["connected"].as_bool() == Some(true)
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let projection = crate::shell_projection(snapshot);
        if self.snapshot == projection {
            return;
        }
        let changed = self.snapshot["music"]["volume"] != snapshot["music"]["volume"];
        self.snapshot = projection;
        if changed {
            if let Some(value) = snapshot["music"]["volume"]
                .as_f64()
                .filter(|v| v.is_finite())
            {
                self.syncing = true;
                self.volume.update(cx, |slider, cx| {
                    slider.set_value(value.clamp(0., 1.) as f32, window, cx)
                });
                self.syncing = false;
            }
        }
        cx.notify();
    }
    fn submit(&mut self, command: Value, cx: &mut Context<Self>) {
        self.queue_error = if enqueue_ui_command(&self.commands, command) {
            None
        } else {
            Some("操作队列已满，请稍后再试。".into())
        };
        cx.notify();
    }
    fn action(&mut self, action: &str, cx: &mut Context<Self>) {
        match action {
            "program" | "inbox" | "screen" => {
                let section = media_section(action).expect("matched media action");
                crate::select_media_section(section, cx);
                if let Some(index) = self.panes.iter().position(|(name, _)| name == "音乐与空间")
                {
                    let next = if self.selected == Some(index) && self.media_action == Some(section)
                    {
                        None
                    } else {
                        Some(index)
                    };
                    if self.set_panel(next, cx) {
                        self.media_action = Some(section);
                    }
                }
            }
            "chat" => self.toggle_panel("聊天", cx),
            "props" => self.toggle_panel("物品", cx),
            "visual" => self.submit(action_command("visual", false).unwrap(), cx),
            "lyrics" => self.submit(action_command("lyrics", false).unwrap(), cx),
            "play" | "previous" | "next" | "mode" => self.submit(
                action_command(
                    action,
                    self.snapshot["music"]["isPlaying"].as_bool() == Some(true),
                )
                .expect("matched command action"),
                cx,
            ),
            _ => {}
        }
    }
    fn controls(&self) -> Vec<TransportControl> {
        let playing = self.snapshot["music"]["isPlaying"].as_bool() == Some(true);
        let fullscreen = self.snapshot["ui"]["fullscreen"].as_bool() == Some(true);
        let rows = [
            ("program", IconName::FileText, "音乐与节目"),
            ("previous", IconName::ChevronLeft, "上一首"),
            (
                "play",
                if playing {
                    IconName::Pause
                } else {
                    IconName::Play
                },
                if playing { "暂停" } else { "播放" },
            ),
            ("next", IconName::ChevronRight, "下一首"),
            ("voice", IconName::Mic, "按住说话"),
            ("chat", IconName::Bot, "聊天"),
            ("inbox", IconName::Bell, "通知"),
            ("lyrics", IconName::Music, "显示或隐藏歌词"),
            ("props", IconName::SquareStack, "物品"),
            ("screen", IconName::MousePointerClick, "电视"),
            ("visual", IconName::Settings, "设置"),
            (
                "mode",
                if fullscreen {
                    IconName::Minimize
                } else {
                    IconName::Maximize
                },
                "全屏",
            ),
        ];
        rows.into_iter()
            .map(|(id, icon, label)| {
                let panel = match id {
                    "program" | "inbox" | "screen" => Some("音乐与空间"),
                    "chat" => Some("聊天"),
                    "props" => Some("物品"),
                    _ => None,
                };
                let active = if id=="lyrics" {self.snapshot["ui"]["lyricsVisible"].as_bool()==Some(true)} else if id == "visual" {
                    self.snapshot["ui"]["settingsWindowOpen"].as_bool() == Some(true)
                } else {
                    panel.is_some_and(|label| {
                        self.selected.is_some_and(|i| self.panes[i].0 == label)
                    }) && media_section(id).is_none_or(|section| self.media_action == Some(section))
                };
                let enabled = match id {
                    "previous" => {
                        self.connected()
                            && self.snapshot["music"]["canPrevious"].as_bool() == Some(true)
                    }
                    "next" => {
                        self.connected()
                            && self.snapshot["music"]["canNext"].as_bool() == Some(true)
                    }
                    "play" | "voice" => self.connected(),
                    _ => true,
                };
                let control = TransportControl::new(id, id, icon, label)
                    .active(active)
                    .enabled(enabled)
                    .ends_group(id == "next")
                    .hold(id == "voice");
                if id == "visual" {
                    control.face_text("设置")
                } else {
                    control
                }
            })
            .collect()
    }
}

impl Render for ShellPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let viewport = window.viewport_size();
        let panel_width = (f32::from(viewport.width) - metrics::TRANSPORT_INSET * 2.).max(0.);
        let panel_height = (f32::from(viewport.height)
            - metrics::TRANSPORT_INSET * 2.
            - metrics::TRANSPORT_HEIGHT
            - metrics::COMPOSER_GAP)
            .max(0.);
        // The full-window root has no surface: only the shared floating chrome
        // and the selected panel paint, leaving the production world visible.
        let mut root = div()
            .relative()
            .size_full()
            .text_color(cx.theme().foreground)
            .on_children_prepainted(|bounds, window, cx| {
                if window.has_active_dialog(cx) || window.has_active_sheet(cx) {
                    crate::report_ui_hit_bounds(&[Bounds::new(
                        point(px(0.), px(0.)),
                        window.viewport_size(),
                    )]);
                } else {
                    crate::report_ui_hit_bounds(&bounds);
                }
            })
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                if event.keystroke.key == "escape"
                    && this.selected.is_some()
                    && !crate::kit_text_input_facts(window, cx).1
                    && this.close_panel(window, cx)
                {
                    crate::record_panel_escape();
                    cx.stop_propagation();
                }
            }));
        if let Some(index) = self.selected.filter(|i| *i < self.panes.len()) {
            let is_chat = self.panes[index].0 == "聊天";
            if !is_chat {
                crate::report_chat_drop_bounds(None);
            }
            let max_width = if is_chat {
                chat::PANEL_MAX_WIDTH
            } else {
                stage::PANEL_MAX_WIDTH
            };
            let max_height = if is_chat {
                chat::PANEL_MAX_HEIGHT
            } else {
                stage::PANEL_MAX_HEIGHT
            };
            let media_controls = (self.panes[index].0 == "音乐与空间").then(|| {
                div()
                    .flex()
                    .items_center()
                    .flex_shrink_0()
                    .min_w_0()
                    .h(px(scene::CONTROL_HEIGHT))
                    .px_2()
                    .gap_2()
                    .bg(rgba(scene::BAR_BG))
                    .text_color(rgba(scene::TEXT_MUTED))
                    .text_size(px(metrics::CONTROL_LABEL_SIZE))
                    .child("音量")
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .max_w(px(160.))
                            .child(Slider::new(&self.volume).disabled(!self.connected())),
                    )
                    .child(
                        gmgn_gpui_ui::primitives::icon_button(
                            "media-lyrics",
                            IconName::Music,
                            "显示或隐藏歌词",
                            self.snapshot["ui"]["lyricsVisible"].as_bool() == Some(true),
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.submit(action_command("lyrics", false).unwrap(), cx)
                        })),
                    )
                    .child(
                        gmgn_gpui_ui::primitives::icon_button(
                            "media-compact",
                            IconName::Minimize,
                            "切换小窗",
                            self.snapshot["ui"]["compact"].as_bool() == Some(true),
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.submit(action_command("compact", false).unwrap(), cx)
                        })),
                    )
            });
            let content = if is_chat {
                self.panes[index].1.clone().into_any_element()
            } else {
                div()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .overflow_hidden()
                    .child(self.panes[index].1.clone())
                    .into_any_element()
            };
            root = root.child(
                panel_container(
                    is_chat,
                    panel_width.min(max_width),
                    panel_height.min(max_height),
                )
                .on_children_prepainted(move |bounds, _, _| {
                    if is_chat {
                        crate::report_chat_drop_bounds(bounds.first().copied());
                    }
                })
                .children(media_controls)
                .child(content),
            );
        } else {
            crate::report_chat_drop_bounds(None);
        }
        let click = cx.entity().downgrade();
        let hold = click.clone();
        let destination = click.clone();
        root = root
            .child(shell::transport_bar(
                self.controls(),
                move |action, _, cx| {
                    let _ = click.update(cx, |this, cx| this.action(action, cx));
                },
                move |action, pressed, _, cx| {
                    if action == "voice" {
                        let _ = hold.update(cx, |this, cx| {
                            this.submit(
                                json!({"op":if pressed{"voice.press"}else{"voice.release"}}),
                                cx,
                            )
                        });
                    }
                },
            ))
            .child(shell::destination_button(
                gpui_kit::component::Icon::new(IconName::Globe),
                "切换空间",
                true,
                move |_, _, cx| {
                    let _ = destination.update(cx, |this, cx| {
                        this.submit(json!({"op":"ui.space.toggle"}), cx)
                    });
                },
            ));
        if let Some(notice) = self.queue_error.clone().or_else(|| {
            self.snapshot["ui"]["error"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        }) {
            root = root.child(
                div()
                    .absolute()
                    .left(px(metrics::TRANSPORT_INSET))
                    .bottom(px(metrics::TRANSPORT_INSET))
                    .w(px(metrics::TASK_FEEDBACK_WIDTH))
                    .p_2()
                    .bg(cx.theme().background)
                    .text_color(cx.theme().danger)
                    .child(notice),
            );
        }
        root
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn chat_is_content_sized_and_keeps_the_same_bottom_anchor_in_fullscreen() {
        use gpui_kit::{Styled, div, px};
        let mut chat = super::panel_container(true, 620., 320.);
        let mut content_sized = div().max_h(px(320.));
        let mut fixed = super::panel_container(false, 590., 458.);
        assert_eq!(chat.style().size.height, content_sized.style().size.height);
        assert_ne!(chat.style().size.height, fixed.style().size.height);
        assert_eq!(chat.style().inset.bottom, fixed.style().inset.bottom);
    }
    #[test]
    fn transport_routes_existing_host_commands_and_distinct_media_sections() {
        assert_eq!(
            super::action_command("play", true).unwrap()["op"],
            "music.pause"
        );
        assert_eq!(
            super::action_command("play", false).unwrap()["op"],
            "music.play"
        );
        assert_eq!(
            super::action_command("previous", false).unwrap()["op"],
            "music.previous"
        );
        assert_eq!(
            super::action_command("next", false).unwrap()["op"],
            "music.next"
        );
        assert_eq!(
            super::action_command("mode", false).unwrap()["op"],
            "ui.window.fullscreen"
        );
        assert!(super::action_command("invented", false).is_none());
        assert_eq!(super::media_section("program"), Some("programs"));
        assert_eq!(super::media_section("inbox"), Some("inbox"));
        assert_eq!(super::media_section("screen"), Some("screen"));
        assert_eq!(super::media_section("chat"), None);
        assert_eq!(
            super::action_command("visual", false).unwrap()["op"],
            "ui.settings.open"
        );
        assert_eq!(
            super::action_command("lyrics", false).unwrap()["op"],
            "ui.lyrics.toggle"
        );
        assert_eq!(
            super::action_command("compact", false).unwrap()["op"],
            "ui.window.compact"
        );
    }
}
