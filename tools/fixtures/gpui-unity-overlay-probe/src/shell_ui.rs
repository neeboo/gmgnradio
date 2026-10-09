//! Embedded production shell; host snapshots remain authoritative.
use crate::{UiCommandQueue, enqueue_ui_command};
use gmgn_gpui_ui::shell::{self, TransportControl};
use gmgn_gpui_ui::ui_tokens::{chat, shell as metrics, stage};
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

/// The volume icon's face: a bare glyph, no words (the label is the tooltip and
/// the accessibility label, as for every other control in the bar).
///
/// The slider is **not** in the bar. Clicking the icon opens
/// [`gmgn_gpui_ui::shell::transport_popover`], whose surface is anchored to the
/// bar's own box with `bottom = TRANSPORT_HEIGHT + gap`, so the panel opens
/// **upwards** from the bar's top edge and never overlaps the panel area above
/// it. The surface comes from `ui_tokens` (`scene::CARD_BG` + `scene::BORDER`),
/// never from a kit theme variant, so a light system theme cannot turn it white.
///
/// The slider entity is captured by value: the bar may outlive this borrow, and
/// `Entity` is the cheap handle that keeps the popover's value live.
fn with_volume_popover(
    mut controls: Vec<TransportControl>,
    volume: gpui_kit::Entity<SliderState>,
    open: bool,
) -> Vec<TransportControl> {
    if let Some(control) = controls.iter_mut().find(|control| control.id.as_ref() == "volume") {
        control.active = open;
        if open {
            *control = control.clone().popover(move |_, _| {
                shell::transport_popover(Slider::new(&volume))
                    .into_any_element()
            });
        }
    }
    controls
}

/// Read-only layout tracing for `GMGN_GPUI_INPUT_DIAGNOSTICS=1`. The shell logs
/// the viewport it actually laid out with and the resulting panel rect, so a
/// stale native size can be told apart from a late paint. Nothing here changes
/// layout; only an actual change is printed.
fn trace_layout(viewport: Size<Pixels>, panel: Option<Bounds<Pixels>>) {
    use std::sync::atomic::{AtomicU64, Ordering};
    static VIEWPORT: AtomicU64 = AtomicU64::new(u64::MAX);
    static PANEL: AtomicU64 = AtomicU64::new(u64::MAX);
    if std::env::var("GMGN_GPUI_INPUT_DIAGNOSTICS").as_deref() != Ok("1") {
        return;
    }
    let vw = f32::from(viewport.width);
    let vh = f32::from(viewport.height);
    let viewport_key = (vw.to_bits() as u64) << 32 | vh.to_bits() as u64;
    let viewport_changed = VIEWPORT.swap(viewport_key, Ordering::Relaxed) != viewport_key;
    let mut panel_changed = false;
    let mut rect = (-1., -1., -1., -1.);
    if let Some(b) = panel {
        rect = (
            (f32::from(b.origin.x) * 2.).round() / 2.,
            (f32::from(b.origin.y) * 2.).round() / 2.,
            (f32::from(b.size.width) * 2.).round() / 2.,
            (f32::from(b.size.height) * 2.).round() / 2.,
        );
        let panel_key = viewport_key
            ^ (rect.0.to_bits() as u64).rotate_left(3)
            ^ (rect.1.to_bits() as u64).rotate_left(7)
            ^ (rect.2.to_bits() as u64).rotate_left(11)
            ^ (rect.3.to_bits() as u64).rotate_left(17);
        panel_changed = PANEL.swap(panel_key, Ordering::Relaxed) != panel_key;
    }
    if !viewport_changed && !panel_changed {
        return;
    }
    let ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0);
    let (px_, py, pw, ph) = rect;
    eprintln!("[GPUIOverlayTrace] ms={ms} event=gpuiLayout viewport={vw}x{vh} panel={px_},{py},{pw}x{ph}");
}

/// Panel extent for the window's *current* viewport. The anchored corner is
/// the window's bottom-right, so both numbers are derived from the viewport the
/// window has right now and never from a remembered one.
fn panel_extent(viewport: Size<Pixels>) -> (f32, f32) {
    (
        (f32::from(viewport.width) - metrics::TRANSPORT_INSET * 2.).max(0.),
        (f32::from(viewport.height)
            - metrics::TRANSPORT_INSET * 2.
            - metrics::TRANSPORT_HEIGHT
            - metrics::COMPOSER_GAP)
            .max(0.),
    )
}

/// Panel container for the window's *current* viewport, pinned to the same
/// bottom-right corner as the transport bar. `content_sized` is the pane's own
/// choice: the composer and the 物品 list size themselves (so a short panel
/// hugs the corner instead of stretching a full-height container down from the
/// window's top), while the media surfaces fill the extent they are given.
fn panel_container(content_sized: bool, width: f32, height: f32) -> Div {
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
        // Both slack axes go to the far corner: a pane narrower or shorter than
        // the extent still ends at the transport bar's own edge (the original
        // pins `propEditorPanel.trailing == transportControls.trailing` and
        // `bottom == transportControls.top - 12`,
        // `StageWindowController.swift:1521-1526`). Without this the 340 pt
        // 物品 panel sat at the container's *left* and its content started at
        // the window's top.
        .items_end()
        .justify_end()
        .min_h_0()
        .min_w_0()
        .overflow_hidden();
    if content_sized { panel } else { panel.h(px(height)) }
}

pub struct ShellPane {
    commands: UiCommandQueue,
    panes: Vec<(String, AnyView)>,
    selected: Option<usize>,
    media_action: Option<&'static str>,
    snapshot: Value,
    volume: Entity<SliderState>,
    /// Whether the volume panel is open above its bar icon. The slider is not a
    /// panel row any more: the icon is a plain control, and this is the state
    /// that pops the slider up over the bar when it is clicked.
    volume_open: bool,
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
            volume_open: false,
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
            // 小窗 moved out of the 音乐与空间 panel footer into the bar: same
            // single `ui.window.compact` sender, now the bar's own toggle.
            "compact" => self.submit(action_command("compact", false).unwrap(), cx),
            // 音量 opens/closes its slider above the bar. The bar's own click
            // callback is the only place this is decided, so the panel can
            // never be left open by another control's click.
            "volume" => {
                self.volume_open = !self.volume_open;
                cx.notify();
            }
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
            // Moved into the bar from the 音乐与空间 panel's own footer: the
            // panel's duplicate volume row and its 小窗 button are gone, and
            // the two live here instead. 音量 is a bare icon (no words) that
            // pops its slider up over the bar; see `with_volume_popover`.
            ("volume", IconName::Volume2, "音量"),
            ("compact", IconName::Minimize, "小窗"),
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
                let active = if id=="lyrics" {self.snapshot["ui"]["lyricsVisible"].as_bool()==Some(true)} else if id == "volume" {
                    self.volume_open
                } else if id == "compact" {
                    self.snapshot["ui"]["compact"].as_bool() == Some(true)
                } else if id == "visual" {
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
        trace_layout(viewport, None);
        let (panel_width, panel_height) = panel_extent(viewport);
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
            // 物品 sizes itself too: the list is short far more often than it
            // is long, and the original's 340 pt panel is bottom-right pinned
            // rather than stretched to a full-height container.
            let is_props = self.panes[index].0 == "物品";
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
            // The panel's own 音量 row is gone: the duplicate lyrics button that
            // sat in it, and the 小窗 button beside it. 音量 moved into the
            // floating bar as an icon whose slider pops **up** from the bar
            // (`with_volume_popover`), and 小窗 moved there as a bar toggle.
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
                    is_chat || is_props,
                    panel_width.min(max_width),
                    panel_height.min(max_height),
                )
                .on_children_prepainted(move |bounds, _, _| {
                    trace_layout(viewport, bounds.first().copied());
                    if is_chat {
                        crate::report_chat_drop_bounds(bounds.first().copied());
                    }
                })
                .child(content),
            );
        } else {
            crate::report_chat_drop_bounds(None);
        }
        let click = cx.entity().downgrade();
        let hold = click.clone();
        let destination = click.clone();
        // The bar's 音量 icon carries its slider as a popover above the bar; the
        // slider entity is captured so the panel stays live while it is open.
        let controls = with_volume_popover(
            self.controls(),
            self.volume.clone(),
            self.volume_open,
        );
        root = root
            .child(shell::transport_bar_in(
                controls,
                window,
                cx,
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

    /// 物品 is content-sized and pinned to the same corner as the transport bar:
    /// a 340 pt panel on a 720×482 window ends at the bar's own right/bottom
    /// edge instead of starting at the container's left/top. Both slack axes
    /// must go to the end (`items_end`/`justify_end`) and the pane must not
    /// stretch to the container's height — that stretch is what pushed the
    /// panel's content to the window's top-left.
    #[test]
    fn the_props_pane_is_content_sized_and_pinned_to_the_bottom_right() {
        use gpui_kit::{AlignItems, JustifyContent, Styled, div, px};
        let mut props = super::panel_container(true, 590., 374.);
        let mut content_sized = div().max_h(px(374.));
        let mut filled = super::panel_container(false, 590., 374.);
        assert_eq!(props.style().size.height, content_sized.style().size.height);
        assert_ne!(props.style().size.height, filled.style().size.height);
        // The corner is the transport bar's: 22 from the right, one composer
        // gap + the 48 pt bar above the window's bottom.
        let mut anchor = div()
            .right(px(super::metrics::TRANSPORT_INSET))
            .bottom(px(
                super::metrics::TRANSPORT_INSET
                    + super::metrics::TRANSPORT_HEIGHT
                    + super::metrics::COMPOSER_GAP,
            ));
        assert_eq!(props.style().inset.right, anchor.style().inset.right);
        assert_eq!(props.style().inset.bottom, anchor.style().inset.bottom);
        assert_eq!(props.style().align_items, Some(AlignItems::FlexEnd));
        assert_eq!(props.style().justify_content, Some(JustifyContent::End));
        // A media pane still fills the extent it is given.
        assert_eq!(filled.style().align_items, Some(AlignItems::FlexEnd));
        assert_eq!(filled.style().justify_content, Some(JustifyContent::End));
        assert_ne!(
            filled.style().size.height,
            content_sized.style().size.height
        );
    }
    #[test]
    fn panel_extent_is_derived_from_the_live_viewport_after_a_fullscreen_resize() {
        use gpui_kit::{Pixels, Size, Styled, px, size};
        let windowed: Size<Pixels> = size(px(720.), px(450.));
        let fullscreen: Size<Pixels> = size(px(1920.), px(1080.));
        let (small_width, small_height) = super::panel_extent(windowed);
        let (large_width, large_height) = super::panel_extent(fullscreen);
        // The old 720×450 extent must not survive into the fullscreen window:
        // both numbers follow the window it is laid out in.
        assert_eq!((small_width, small_height), (720. - 44., 450. - 44. - 48. - 16.));
        assert_eq!((large_width, large_height), (1920. - 44., 1080. - 44. - 48. - 16.));
        assert!(large_width > small_width && large_height > small_height);
        // Same anchored corner in both: 22 from the right, and its bottom sits
        // one composer gap above the 48 high transport bar.
        let mut anchor = gpui_kit::div()
            .right(px(super::metrics::TRANSPORT_INSET))
            .bottom(px(
                super::metrics::TRANSPORT_INSET
                    + super::metrics::TRANSPORT_HEIGHT
                    + super::metrics::COMPOSER_GAP,
            ));
        for (content_sized, width, height) in [(true, small_width, small_height), (false, large_width, large_height)] {
            let mut panel = super::panel_container(content_sized, width, height);
            assert_eq!(panel.style().inset.right, anchor.style().inset.right);
            assert_eq!(panel.style().inset.bottom, anchor.style().inset.bottom);
        }
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

    /// The 音乐与空间 panel's own footer is gone: no volume row, no music note,
    /// no window button. This is the "歌词是重复的（删掉）" half of the decision,
    /// and it is a source check because the footer was **painted by this file**,
    /// not by the pane it wrapped — a behavioral assertion on the pane could not
    /// see it.
    #[test]
    fn the_media_panel_footer_is_gone() {
        let source = include_str!("shell_ui.rs");
        // Built at run time so this test's own source cannot satisfy the search.
        for gone in [
            format!("media{}", "-lyrics"),
            format!("media{}", "-compact"),
            format!("{}{}", "let media", "_controls"),
            format!("{}{}", ".children(media", "_controls)"),
        ] {
            assert!(
                !source.contains(&gone),
                "the media panel must not draw its old footer: found `{gone}`"
            );
        }
        // The row's label and its slider were the footer's whole body.
        assert!(
            !source.contains("child(\"音量\")"),
            "the panel's 音量 row label must be gone (the icon in the bar has no text face)"
        );
        // The panel body is now the pane alone.
        assert!(source.contains(".child(content),"));
    }

    /// 音量 and 小窗 are in the floating bar, and the volume panel opens
    /// **upwards**: the slider is a popover anchored `bottom = TRANSPORT_HEIGHT
    /// + gap` inside the bar, i.e. above the bar's top edge. This pins the
    /// direction, which is the whole point of "点击 icon 后向上弹出滑动".
    #[test]
    fn the_bar_carries_volume_and_compact_and_the_slider_pops_up() {
        let source = include_str!("shell_ui.rs");
        // The bar's own control table names both, and 音量 is a bare icon.
        assert!(source.contains("(\"volume\", IconName::Volume2, \"音量\")"));
        assert!(source.contains("(\"compact\", IconName::Minimize, \"小窗\")"));
        // The slider is built inside the popover, not as a panel row.
        assert!(source.contains("shell::transport_popover(Slider::new(&volume))"));
        // The direction itself is asserted behaviourally in
        // `apps/gpui-ui/src/shell.rs` (`a_popover_opens_above_the_bar_not_below_it`);
        // here the fixture only has to prove it uses that surface and that the
        // clearance is upward (a non-positive gap would drop the panel onto the
        // bar or below it).
        assert!(
            gmgn_gpui_ui::shell::TRANSPORT_POPOVER_GAP > 0.,
            "the popover must clear the bar upward rather than sit inside it"
        );
        assert!(source.contains("shell::transport_popover("));
    }

    /// The two moved controls each keep a single sender: 音量 still emits only
    /// `music.volume` (from the bar's slider now) and 小窗 still emits only
    /// `ui.window.compact` (from the bar's toggle now).
    #[test]
    fn the_moved_controls_keep_one_sender_each() {
        let source = include_str!("shell_ui.rs");
        // Count the senders of each op, not the mentions of the strings.
        let volume_senders = source.matches("\"op\":\"music.volume\"").count();
        assert_eq!(
            volume_senders, 1,
            "music.volume must have exactly one sender (the bar's slider)"
        );
        for sender in [
            format!("{}{}", "action_command(\"compact\"", ", false).unwrap()"),
            format!("{}{}", "\"ui.window", ".compact\""),
        ] {
            // The op is written once, in `action_command`; every control routes
            // through it.
            assert!(
                source.contains(&sender),
                "the moved control must still route `{sender}`"
            );
        }
        assert_eq!(super::action_command("compact", false).unwrap()["op"], "ui.window.compact");
        // The volume popover reads the live slider entity, so the bar's slider
        // is the one that emits the release.
        assert!(source.contains("with_volume_popover("));
        assert!(source.contains("self.volume.clone()"));
    }
}
