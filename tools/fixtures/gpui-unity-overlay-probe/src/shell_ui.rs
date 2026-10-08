//! Presentation-only shell for the existing host. Buttons enqueue requests;
//! playback and window state are exclusively read back from host snapshots.
use crate::{UiCommandQueue, enqueue_ui_command};
use gpui_kit::component::{
    ActiveTheme, Disableable, Selectable,
    button::{Button, ButtonVariants},
    slider::{Slider, SliderEvent, SliderState},
};
use gpui_kit::*;
use serde_json::{Value, json};

pub struct ShellPane {
    commands: UiCommandQueue,
    panes: Vec<(String, AnyView)>,
    selected: Option<usize>,
    snapshot: Value,
    volume: Entity<SliderState>,
    syncing: bool,
    queue_error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl ShellPane {
    pub fn open_panel(&mut self,label:&str,_:&mut Window,cx:&mut Context<Self>) {
        let Some(index)=self.panes.iter().position(|(name,_)|name==label) else {return;};
        if enqueue_ui_command(&self.commands,json!({"op":"ui.overlay.panel","expanded":true})) {
            self.selected=Some(index);
            self.queue_error=None;
        } else {self.queue_error=Some("操作队列已满，面板尚未打开。".into());}
        cx.notify();
    }
    pub fn new(
        _: &mut Window,
        cx: &mut Context<Self>,
        commands: UiCommandQueue,
        panes: Vec<(String, AnyView)>,
    ) -> Self {
        let volume = cx.new(|_| SliderState::new().min(0.).max(1.).step(0.01));
        // Commit only on release. No per-frame commands or implicit audio change
        // while loading, mounting, or accepting authoritative volume snapshots.
        let subscription = cx.subscribe(&volume, |this, _, event: &SliderEvent, cx| {
            if !this.syncing && this.connected() {
                if let SliderEvent::Release(value) = event {
                    this.submit(json!({"op":"music.volume", "value":value.start()}), cx);
                }
            }
        });
        Self {
            commands,
            panes,
            selected: None,
            snapshot: Value::Null,
            volume,
            syncing: false,
            queue_error: None,
            _subscriptions: vec![subscription],
        }
    }

    pub fn update_snapshot(
        &mut self,
        snapshot: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let projection=crate::shell_projection(snapshot);
        if self.snapshot == projection {
            return;
        }
        let changed_volume = self.snapshot["music"]["volume"] != snapshot["music"]["volume"];
        self.snapshot = projection;
        if changed_volume {
            if let Some(volume) = snapshot["music"]["volume"]
                .as_f64()
                .filter(|v| v.is_finite())
            {
                self.syncing = true;
                self.volume.update(cx, |slider, cx| {
                    slider.set_value(volume.clamp(0., 1.) as f32, window, cx)
                });
                self.syncing = false;
            }
        }
        cx.notify();
    }

    fn connected(&self) -> bool {
        self.snapshot["ui"]["connected"].as_bool() == Some(true)
    }

    /// Called only after placement actually starts, never merely on enqueue.
    pub fn close_panel(&mut self, _: &mut Window, cx: &mut Context<Self>)->bool {
        if self.selected.is_none() {
            return false;
        }
        if enqueue_ui_command(
            &self.commands,
            json!({"op":"ui.overlay.panel","expanded":false}),
        ) {
            self.selected = None;
            self.queue_error = None;
            cx.notify();
            return true;
        } else {
            self.queue_error = Some("操作队列已满，面板尚未关闭。".into());
        }
        cx.notify();
        false
    }

    fn submit(&mut self, command: Value, cx: &mut Context<Self>) {
        self.queue_error = if enqueue_ui_command(&self.commands, command) {
            None
        } else {
            Some("操作队列已满，请稍后再试。".into())
        };
        cx.notify();
    }

    fn control(
        &self,
        id: &'static str,
        label: &'static str,
        operation: &'static str,
        disabled: bool,
        selected: bool,
        cx: &mut Context<Self>,
    ) -> Button {
        Button::new(id)
            .ghost()
            .label(label)
            .tooltip(label)
            .disabled(disabled)
            .selected(selected)
            .on_click(cx.listener(move |this, _, _, cx| this.submit(json!({"op":operation}), cx)))
    }
}

fn playback_time(value: Option<f64>) -> String {
    let seconds = value.filter(|v| v.is_finite()).unwrap_or(0.).max(0.) as u64;
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

impl Render for ShellPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let connected = self.connected();
        let playing = self.snapshot["music"]["isPlaying"].as_bool() == Some(true);
        let music = &self.snapshot["music"];
        let title = music["title"]
            .as_str()
            .filter(|t| !t.is_empty())
            .unwrap_or(if connected {
                "尚未选择音乐"
            } else {
                "正在连接播放器…"
            })
            .to_owned();
        let clock = format!(
            "{} / {}",
            playback_time(music["position"].as_f64()),
            playback_time(music["duration"].as_f64())
        );
        let ui = &self.snapshot["ui"];
        let host_error = ui["error"].as_str().filter(|s| !s.is_empty());
        let notice = self
            .queue_error
            .as_deref()
            .or(host_error)
            .or_else(|| music["notice"].as_str().filter(|s| !s.is_empty()))
            .or_else(|| ui["status"].as_str().filter(|s| !s.is_empty()))
            .map(str::to_owned);
        let is_error = self.queue_error.is_some()
            || host_error.is_some()
            || music["noticeSeverity"].as_str() == Some("error");
        let mut navigation = div().flex().flex_wrap().items_center().gap_1();
        for (index, (label, _)) in self.panes.iter().enumerate() {
            navigation = navigation.child(
                Button::new(format!("shell-pane-{index}"))
                    .ghost()
                    .label(label.clone())
                    .selected(self.selected == Some(index))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        let selected = if this.selected == Some(index) {
                            None
                        } else {
                            Some(index)
                        };
                        if enqueue_ui_command(
                            &this.commands,
                            json!({"op":"ui.overlay.panel","expanded":selected.is_some()}),
                        ) {
                            this.selected = selected;
                            this.queue_error = None;
                        } else {
                            this.queue_error = Some("操作队列已满，请稍后再试。".into());
                        }
                        cx.notify();
                    })),
            );
        }
        let mut root = div()
            .on_key_down(cx.listener(|this,event:&KeyDownEvent,window,cx| {
                if event.keystroke.key!="escape" || this.selected.is_none() {return;}
                // IME owns its marked text. Do not dismiss a panel while that
                // same Escape is resolving composition in a standard Kit input.
                if crate::kit_text_input_facts(window,cx).1 {return;}
                if this.close_panel(window,cx) {
                    crate::record_panel_escape();
                    cx.stop_propagation();
                }
            }))
            .size_full()
            .flex()
            .flex_col()
            .justify_end()
            .gap_2()
            .p_3()
            .bg(cx.theme().background)
            .text_color(cx.theme().foreground)
            .text_size(px(14.));
        if let Some(index) = self.selected.filter(|i| *i < self.panes.len()) {
            let is_chat=self.panes[index].0=="聊天";
            if !is_chat {crate::report_chat_drop_bounds(None);}
            root = root.child(
                div()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .overflow_hidden()
                    .on_children_prepainted(move |bounds,_,_| {
                        if is_chat {crate::report_chat_drop_bounds(bounds.first().copied());}
                    })
                    .child(self.panes[index].1.clone()),
            );
        } else {crate::report_chat_drop_bounds(None);}
        root.child(
            div()
                .id("shell-toolbar")
                .flex()
                .flex_col()
                .flex_shrink_0()
                .max_h(px(
                    (f32::from(window.viewport_size().height) - 24.).clamp(0., 204.)
                ))
                .overflow_y_scroll()
                .gap_2()
                .border_t_1()
                .border_color(cx.theme().border)
                .pt_2()
                .children(notice.map(|notice| {
                    div()
                        .text_size(px(12.))
                        .text_color(if is_error {
                            cx.theme().danger
                        } else {
                            cx.theme().muted_foreground
                        })
                        .child(notice)
                }))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .gap_2()
                        .flex_wrap()
                        .child(div().flex_1().min_w_0().child(title))
                        .child(
                            div()
                                .text_size(px(12.))
                                .text_color(cx.theme().muted_foreground)
                                .child(clock),
                        ),
                )
                .child(
                    div()
                        .flex()
                        .items_center()
                        .flex_wrap()
                        .gap_1()
                        .child(self.control(
                            "player-previous",
                            "上一首",
                            "music.previous",
                            !connected || music["canPrevious"].as_bool() != Some(true),
                            false,
                            cx,
                        ))
                        .child(self.control(
                            "player-play",
                            if playing { "暂停" } else { "播放" },
                            if playing { "music.pause" } else { "music.play" },
                            !connected,
                            false,
                            cx,
                        ))
                        .child(self.control(
                            "player-next",
                            "下一首",
                            "music.next",
                            !connected || music["canNext"].as_bool() != Some(true),
                            false,
                            cx,
                        ))
                        .child(
                            div()
                                .text_size(px(12.))
                                .text_color(cx.theme().muted_foreground)
                                .child("音量"),
                        )
                        .child(
                            div()
                                .w(px(112.))
                                .flex_shrink_0()
                                .child(Slider::new(&self.volume).disabled(!connected)),
                        )
                        .child(self.control(
                            "player-lyrics",
                            "歌词",
                            "ui.lyrics.toggle",
                            false,
                            ui["lyricsVisible"].as_bool() == Some(true),
                            cx,
                        ))
                        .child(self.control(
                            "player-space",
                            "空间",
                            "ui.space.toggle",
                            false,
                            ui["spaceVisible"].as_bool() == Some(true),
                            cx,
                        ))
                        .child(self.control(
                            "player-fullscreen",
                            "全屏",
                            "ui.window.fullscreen",
                            false,
                            ui["fullscreen"].as_bool() == Some(true),
                            cx,
                        ))
                        .child(self.control(
                            "player-compact",
                            "小窗",
                            "ui.window.compact",
                            false,
                            ui["compact"].as_bool() == Some(true),
                            cx,
                        ))
                        .child(self.control(
                            "player-restore",
                            "还原窗口",
                            "ui.window.restore",
                            ui["compact"].as_bool() != Some(true),
                            false,
                            cx,
                        )),
                )
                .child(navigation),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::playback_time;
    #[test]
    fn formats_playback_time_without_nonfinite_or_negative_values() {
        assert_eq!(playback_time(None), "0:00");
        assert_eq!(playback_time(Some(f64::NAN)), "0:00");
        assert_eq!(playback_time(Some(-1.)), "0:00");
        assert_eq!(playback_time(Some(184.9)), "3:04");
    }
}
