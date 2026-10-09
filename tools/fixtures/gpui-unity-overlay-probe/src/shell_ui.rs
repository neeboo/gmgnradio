//! Embedded production shell; host snapshots remain authoritative.
use crate::{UiCommandQueue, enqueue_ui_command};
use gmgn_gpui_ui::primitives as ui;
use gmgn_gpui_ui::shell::{self, TransportControl};
use gmgn_gpui_ui::ui_tokens::{chat, scene, shell as metrics, stage};
use gpui_kit::assets::IconName;
use gpui_kit::component::{
    WindowExt,
    menu::{DropdownMenu, PopupMenuItem},
    slider::{SliderEvent, SliderState},
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

/// The Live Cam entries, in the original's order (`Player.uxml:53-58`,
/// `PlayerScreen.cs:101-104`): 空间 ｜ 播放器 ｜ 文字聊天 ｜ 通知 ｜ 设置.
///
/// This is the **compact window's whole menu**. The original lays it out as a
/// vertical `NSStackView` (`orientation = .vertical`, `LiveCamPanel.swift:699`)
/// pinned 10 pt from the window's top-right corner at a fixed 30 pt width
/// (`:861-866`); the Unity build says the same in USS
/// (`.compact-window .livecam-controls`, 30 pt wide, 30 pt entries stacked 6 pt
/// apart, `Player.uss:96-97`). The wide floating transport bar belongs to the
/// stage window and is never drawn in 小窗.
///
/// The Unity column is exactly these five: unlike the AppKit original it does
/// **not** stack a sixth 语音 entry (`LiveCamPanel.swift:707`, which the GPUI
/// product App mirrors) — in the Unity build push-to-talk is the chat
/// composer's own `chatVoice` button, which the compact chat column keeps
/// (`Player.uxml:25`, `Player.uss:107,119`).
const COMPACT_CONTROLS: [(&str, &str); 5] = [
    ("space", "空间"),
    ("player", "播放器"),
    ("chat", "聊天"),
    ("inbox", "通知"),
    ("settings", "设置"),
];

/// The column's glyphs (`PlayerScreen.cs:179-183`: `screen` · `music` · `chat` ·
/// `mail` · `settings`), the same mapping the product host uses for its own
/// compact column.
fn compact_icon(id: &str) -> IconName {
    match id {
        "space" => IconName::Globe,
        "player" => IconName::Music,
        "chat" => IconName::Bot,
        "inbox" => IconName::Bell,
        _ => IconName::Settings,
    }
}

/// The op each Live Cam entry sends. These are the ops this worktree already
/// handles — none is invented: 空间 is the overlay's own `ui.space.toggle`, 设置
/// reuses the bar's 设置 action, 聊天/通知 are the bar's own panel toggles, and
/// 播放器 is the dropdown below.
fn compact_action(id: &'static str) -> &'static str {
    match id {
        "space" => "space",
        "settings" => "visual",
        other => other,
    }
}

/// The compact menu's own box: **30 pt wide, pinned 10 pt from the window's top
/// and right corner, stacking its entries downwards**. The Unity build writes
/// exactly this as `.compact-window .livecam-controls { display:flex;
/// position:absolute; top:10px; right:10px; width:30px; }` with 30 pt entries
/// 6 pt apart (`Player.uss:96-97`); the AppKit original is the same vertical
/// `NSStackView` (`LiveCamPanel.swift:699-708,861-866`). It is one function so
/// the test can read the box the column is really laid out with.
fn compact_column() -> Div {
    div()
        .absolute()
        .top(px(metrics::COMPACT_MARGIN))
        .right(px(metrics::COMPACT_MARGIN))
        .w(px(metrics::COMPACT_CONTROL))
        .flex()
        .flex_col()
        .gap(px(metrics::COMPACT_CONTROL_GAP))
}

/// The volume icon's face: a bare glyph, no words (the label is the tooltip and
/// the accessibility label, as for every other control in the bar).
///
/// Clicking the icon opens a panel above the bar. The **surface** is the bar's
/// own ([`gmgn_gpui_ui::shell::transport_popover`], drawn by
/// `transport_bar_slots` from the control's slot): it is anchored to the bar's
/// box with `bottom = TRANSPORT_HEIGHT + gap`, so the panel opens **upwards**
/// from the bar's top edge and never overlaps the panel area above it, and it
/// comes from `ui_tokens` (`scene::CARD_BG` + `scene::BORDER`), never from a kit
/// theme variant, so a light system theme cannot turn it white. This builder
/// therefore returns the panel's **content only**; wrapping it in a second
/// `transport_popover` here is what used to leave an empty strip above the bar.
///
/// The panel holds the two controls the person asked for and nothing else:
///
/// * [`ui::volume_slider`] — the layer's **vertical** track (up = louder), not
///   the horizontal bar it used to be;
/// * [`ui::volume_mute_button`] — a **small icon** (`volume-2` / `volume-x`),
///   not a switch and not a bar, whose two states the mute flag picks.
///
/// Both write the same single `music.volume` command (see
/// [`ShellPane::set_volume`]): the slider sends the dragged level, the mute icon
/// sends 0 and then the level it replaced. There is no mute op in the host to
/// use instead — `music.mute` appears nowhere in `services/**`, `apps/macos`
/// or the Unity player (the only `isMuted` flags belong to the screen/video
/// players, not to the music level), so the remembered-level pair rides the
/// existing op.
///
/// The slider entity is captured by value: the bar may outlive this borrow, and
/// `Entity` is the cheap handle that keeps the popover's value live.
fn with_volume_popover(
    mut controls: Vec<TransportControl>,
    volume: gpui_kit::Entity<SliderState>,
    open: bool,
    muted: bool,
    connected: bool,
    shell_pane: gpui_kit::WeakEntity<ShellPane>,
) -> Vec<TransportControl> {
    if let Some(control) = controls.iter_mut().find(|control| control.id.as_ref() == "volume") {
        control.active = open;
        if open {
            *control = control.clone().popover(move |_, _| {
                let mute = shell_pane.clone();
                div()
                    .flex()
                    .flex_col()
                    .items_center()
                    .gap(px(stage::GROUP_GAP))
                    .child(ui::volume_slider(&volume, connected))
                    .child(ui::volume_mute_button(muted, connected).on_click(
                        move |_, _, cx| {
                            let _ = mute.update(cx, |this, cx| this.toggle_mute(cx));
                        },
                    ))
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
///
/// In 小窗 there is no transport bar and the window's right edge is reserved for
/// the Live Cam control column, so the same corner is measured from the compact
/// margins instead (`LiveCamPanel.swift:861-889`, `Player.uss:96-102`).
///
/// `content_min_width` is the floor the selected pane's own content needs
/// ([`panel_content_floor`]): the extent grows to it when the viewport is
/// narrower than the pane can be drawn in, but never past the window's own
/// inset — a pane only takes the width it needs while the window can hold it.
fn panel_extent(viewport: Size<Pixels>, compact: bool, content_min_width: f32) -> (f32, f32) {
    let width = f32::from(viewport.width);
    let height = f32::from(viewport.height);
    if compact {
        return (
            (width - metrics::COMPACT_MARGIN - metrics::COMPACT_CONTENT_RIGHT)
                .max(0.)
                .max(content_min_width)
                .min((width - metrics::COMPACT_CONTENT_RIGHT).max(0.)),
            (height - metrics::COMPACT_MARGIN * 2.).max(0.),
        );
    }
    (
        (width - metrics::TRANSPORT_INSET * 2.)
            .max(0.)
            .max(content_min_width)
            .min((width - metrics::TRANSPORT_INSET).max(0.)),
        (height
            - metrics::TRANSPORT_INSET * 2.
            - metrics::TRANSPORT_HEIGHT
            - metrics::COMPOSER_GAP)
            .max(0.),
    )
}

/// The gap between a pane's bottom edge and the transport bar's top edge.
///
/// The shell's own edge is [`metrics::COMPOSER_GAP`] (16), but 「我的物件」 is
/// not the composer: the original pins the prop editor's bottom at
/// `transportControls.top - 12` (`StageWindowController.swift:1523`, the
/// `stage::PROP_EDITOR_BOTTOM_GAP` token), so the 物品 pane keeps the original
/// 12 and every other pane keeps the shell's 16. One function, so the two can
/// never be swapped by a branch that forgot which pane it is building.
fn panel_bottom_gap(label: &str) -> f32 {
    if label == "物品" {
        stage::PROP_EDITOR_BOTTOM_GAP
    } else {
        metrics::COMPOSER_GAP
    }
}

/// Panel container for the window's *current* viewport, pinned to the same
/// bottom-right corner as the transport bar. `content_sized` is the pane's own
/// choice: the composer and the 物品 list size themselves (so a short panel
/// hugs the corner instead of stretching a full-height container down from the
/// window's top), while the media surfaces fill the extent they are given.
/// `bottom_gap` is the pane's own distance to the bar ([`panel_bottom_gap`]).
///
/// `compact` keeps the identical corner rule but measured from the 小窗 margins,
/// so every compact surface stops at the reserved Live Cam control column
/// instead of under it (`LiveCamPanel.swift:881-889`: 「控件列是保留区，任何东西
/// 都不许进去」).
fn panel_container(
    content_sized: bool,
    width: f32,
    height: f32,
    bottom_gap: f32,
    compact: bool,
) -> Div {
    let (right, bottom) = if compact {
        (metrics::COMPACT_CONTENT_RIGHT, metrics::COMPACT_MARGIN)
    } else {
        (
            metrics::TRANSPORT_INSET,
            metrics::TRANSPORT_INSET + metrics::TRANSPORT_HEIGHT + bottom_gap,
        )
    };
    let panel = div()
        .absolute()
        .right(px(right))
        .bottom(px(bottom))
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

/// The width floor the selected pane's own content needs. Only the media panel
/// has one: 「消息」 mounts the shared `InboxPane` whole, and that pane keeps a
/// list floor and a detail floor side by side (`media_ui::PANEL_CONTENT_FLOOR`
/// is the panel width they add up to). The other panes either size themselves
/// (the composer, 物品) or have no floor of their own.
///
/// It is the *panel's* floor, not the section's: the media panel keeps one width
/// whichever of its surfaces is showing, so switching between 音乐库 and 消息
/// does not resize the floating panel.
pub(crate) fn panel_content_floor(label: &str) -> f32 {
    if label == "音乐与空间" {
        crate::media_ui::PANEL_CONTENT_FLOOR
    } else {
        0.
    }
}

/// The ceiling the selected pane may use. The original stage panel's
/// `stage::PANEL_MAX_WIDTH` (590) stands for every surface that fits inside it;
/// a pane whose own content floor is wider — the media panel hosting 「消息」
/// needs 614 — raises the ceiling to that floor, because the alternative is
/// clipping the columns the panel was opened to show.
fn panel_max_width(label: &str) -> f32 {
    let original = if label == "聊天" {
        chat::PANEL_MAX_WIDTH
    } else {
        stage::PANEL_MAX_WIDTH
    };
    original.max(panel_content_floor(label))
}

/// The panel box for one pane at one viewport: the single place the width and
/// height decisions are made, so the arithmetic a test pins is the arithmetic
/// the shell really lays out.
pub(crate) fn panel_box(viewport: Size<Pixels>, compact: bool, label: &str) -> (f32, f32) {
    let (width, height) = panel_extent(viewport, compact, panel_content_floor(label));
    let max_height = if label == "聊天" {
        chat::PANEL_MAX_HEIGHT
    } else {
        stage::PANEL_MAX_HEIGHT
    };
    (width.min(panel_max_width(label)), height.min(max_height))
}

/// The panel's content box. It is pinned to the panel's own width (100 %)
/// rather than left to size itself from its content: the panel ends its children
/// at the bottom-right corner (`panel_container`'s `items_end`), so a pane whose
/// intrinsic width is wider than the panel takes its right edge from that corner
/// and overflows off the panel's **left** — locally reproduced 2026-10-09 as a
/// 640 pt message body in a 590 pt panel, 83 pt of it (the list's unread dot and
/// the head of every title) painted outside the panel and clipped:
/// 「消息面板没显示完整，左边缺一块」. Pinned, an over-wide pane is at worst
/// clipped *inside* the panel; it can never leave it.
fn panel_content(content: AnyElement) -> Div {
    div()
        .w_full()
        .flex_1()
        .min_h_0()
        .min_w_0()
        .overflow_hidden()
        .child(content)
}

/// The transport bar's controls, in the order the person asked for.
///
/// A table rather than literals inside the builder, because the rule is a
/// **position** — 音量 belongs inside the media group, ahead of the divider —
/// and a position can only be read from the sequence the bar is really built
/// from:
///
/// `歌单 歌词 上一首 播放/暂停 下一首 音量 ｜ 聊天 通知 物品 电视 ｜ 设置 小窗 全屏`
///
/// 麦克风 is deliberately absent: the push-to-talk path in the bar's own loop is
/// kept, but no microphone control is drawn.
fn transport_rows(
    playing: bool,
    fullscreen: bool,
) -> [(&'static str, IconName, &'static str); 13] {
    [
        // Group 1 — the media operations: what is playing, the words for it, the
        // transport, and the level. 音量 is the group's **last** entry, so the
        // divider that ends the group follows it and the level stays beside the
        // controls it applies to.
        ("program", IconName::FileText, "音乐与节目"),
        ("lyrics", IconName::Music, "显示或隐藏歌词"),
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
        ("volume", IconName::Volume2, "音量"),
        // Group 2 — the room: talking to it, what it tells you, what is in it.
        ("chat", IconName::Bot, "聊天"),
        ("inbox", IconName::Bell, "通知"),
        ("props", IconName::SquareStack, "物品"),
        ("screen", IconName::Monitor, "电视"),
        // Group 3 — the window itself.
        ("visual", IconName::Settings, "设置"),
        ("compact", IconName::PanelRight, "小窗"),
        (
            "mode",
            if fullscreen {
                IconName::Minimize
            } else {
                IconName::Maximize
            },
            "全屏",
        ),
    ]
}

/// Whether the group divider is painted **after** this control: 音量 ends the
/// media group (its level belongs with what it controls) and 电视 ends the
/// room's, so the bar reads media ｜ the room ｜ the window itself.
fn transport_group_ends_after(id: &str) -> bool {
    id == "volume" || id == "screen"
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
    /// The level 取消静音 restores: the last **non-zero** level the host
    /// published (or the slider sent), remembered while 静音 holds the level at
    /// 0. This field is the whole of the mute state: the host has no mute op to
    /// delegate it to, so 静音 is a pair of `music.volume` writes.
    volume_before_mute: f32,
    /// Whether the bar's mute icon is showing 静音 (level 0) or 取消静音. Both
    /// the mute icon and the slider's release write it, and the authoritative
    /// snapshot reconciles it whenever the host publishes a new level.
    muted: bool,
    syncing: bool,
    queue_error: Option<String>,
    _subscriptions: Vec<Subscription>,
}

/// The level 静音 restores when the host has never published a non-zero one.
///
/// 1.0 is the player's own full level (`NativePlayerBackend`'s snapshot carries
/// the player's `volume` straight through), so 取消静音 never invents a level
/// quieter than the product's own.
const VOLUME_MUTE_RESTORE_DEFAULT: f32 = 1.;

/// Whether the 音量 panel is open on the first frame.
///
/// A diagnostics affordance with the same opt-in shape as
/// `GMGN_GPUI_INPUT_DIAGNOSTICS`: the layer can be screenshotted here but not
/// clicked (synthetic input is forbidden in this environment), so
/// `GMGN_GPUI_VOLUME_OPEN=1` opens the panel at mount and changes nothing else.
fn volume_panel_open_at_mount() -> bool {
    std::env::var("GMGN_GPUI_VOLUME_OPEN").as_deref() == Ok("1")
}

/// Whether the shell draws the **小窗** layout on the first frame.
///
/// The same diagnostics affordance as [`volume_panel_open_at_mount`]: entering
/// 小窗 for real is a click on the bar's 小窗 control, and synthetic input is
/// forbidden in this environment, so `GMGN_GPUI_COMPACT=1` selects the compact
/// menu at mount and changes nothing else. The host's own projection stays
/// authoritative — the override can only turn the compact layout **on**, never
/// hide a window the host reported as compact. The GPUI product App honours the
/// same variable name for the same reason.
fn compact_window(snapshot: &Value) -> bool {
    snapshot["ui"]["compact"].as_bool() == Some(true)
        || std::env::var("GMGN_GPUI_COMPACT").as_deref() == Ok("1")
}

/// The level 取消静音 restores after `published` becomes the live level.
///
/// Only a **non-zero** level is remembered: 静音 itself publishes 0, and
/// overwriting the memory with it would make 取消静音 restore silence. This is
/// the whole "记住静音前的音量" rule, in one place, so both the slider's release
/// and the host's own snapshot keep the same memory.
fn remembered_level(previous: f32, published: f32) -> f32 {
    if published > 0. { published } else { previous }
}

/// What one 静音 press publishes: 0 while the level is audible, and the level it
/// replaced when the same icon is pressed again.
fn mute_toggle_value(muted: bool, remembered: f32) -> f32 {
    if muted { remembered } else { 0. }
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
                    this.set_volume(value.start(), cx);
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
            volume_open: volume_panel_open_at_mount(),
            volume_before_mute: VOLUME_MUTE_RESTORE_DEFAULT,
            muted: false,
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
    /// Publish one volume level through the **single** `music.volume` sender.
    ///
    /// The slider's release and the mute icon both come through here, so exactly
    /// one place writes the op — and it is also the place that keeps the mute
    /// pair honest: a non-zero level becomes the level 取消静音 restores and
    /// clears 静音, while 0 sets 静音. A non-finite drag is never forwarded.
    fn set_volume(&mut self, value: f32, cx: &mut Context<Self>) {
        let value = if value.is_finite() {
            value.clamp(0., 1.)
        } else {
            0.
        };
        self.volume_before_mute = remembered_level(self.volume_before_mute, value);
        self.muted = value <= 0.;
        self.submit(json!({"op":"music.volume","value":value}), cx);
    }
    /// 静音 / 取消静音: write 0 while the level is audible, and write the level
    /// it replaced when the same icon is pressed again. Both halves are
    /// [`Self::set_volume`], so the one `music.volume` op carries the pair and
    /// the host needs no mute op of its own.
    fn toggle_mute(&mut self, cx: &mut Context<Self>) {
        if !self.connected() {
            return;
        }
        let value = mute_toggle_value(self.muted, self.volume_before_mute);
        self.set_volume(value, cx);
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
                let value = value.clamp(0., 1.) as f32;
                // The host's level is authoritative for the track's position
                // *and* for the mute face: a non-zero level is what 取消静音
                // restores, and 0 is 静音. Without this the icon would keep
                // showing 取消静音 after the host itself turned the music down.
                self.volume_before_mute = remembered_level(self.volume_before_mute, value);
                self.muted = value <= 0.;
                self.syncing = true;
                self.volume.update(cx, |slider, cx| {
                    slider.set_value(value, window, cx)
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
            // 空间, from the compact column: `ui.space.toggle` is the op the
            // Unity product already handles, and from 小窗 it restores the stage
            // window before entering the world (`PlayerScreen.cs:106`).
            "space" => self.submit(json!({"op":"ui.space.toggle"}), cx),
            "visual" | "settings" => self.submit(action_command("visual", false).unwrap(), cx),
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
    /// The compact window's whole menu: the Live Cam control column, laid out
    /// **vertically down the window's right edge**.
    ///
    /// Every entry is one 30 pt rounded icon button, 6 pt below the previous
    /// one, the whole column 10 pt from the top and right corner at a fixed
    /// 30 pt width (`LiveCamPanel.swift:699-708,861-877`; `Player.uss:96-97`).
    /// The wide floating transport bar is deliberately **not** built here: in
    /// 小窗 the original hides the toolbar and draws `livecam-controls` instead
    /// (`.compact-window .player { display: none }`, `Player.uss:95`), and a
    /// 224 pt window cannot hold a horizontal bar anyway.
    fn compact_controls(&self, cx: &mut Context<Self>) -> Div {
        let mut column = compact_column();
        for (id, label) in COMPACT_CONTROLS {
            column = column.child(self.compact_control(id, label, cx));
        }
        column
    }

    /// One Live Cam column entry, with the original's surface
    /// (`LiveCamPanel.swift:945-950`: `white 0.12 @0.94`, `white 0.18` border,
    /// `scene::CONTROL_RADIUS`). The product host builds its own column from the
    /// same tokens, so the two windows cannot drift apart.
    fn compact_control(
        &self,
        id: &'static str,
        label: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let active = match (id, self.selected) {
            ("chat", Some(index)) => self.panes.get(index).is_some_and(|(name, _)| name == "聊天"),
            ("inbox", Some(_)) => self.media_action == Some("inbox"),
            _ => false,
        };
        let button = ui::icon_button(id, compact_icon(id), label, active)
            .w(px(metrics::COMPACT_CONTROL))
            .h(px(metrics::COMPACT_CONTROL))
            .rounded(px(scene::CONTROL_RADIUS))
            .bg(rgba(metrics::COMPACT_CONTROL_BG))
            .border_1()
            .border_color(rgba(metrics::COMPACT_CONTROL_BORDER))
            .text_color(rgba(metrics::COMPACT_TINT));
        if id == "player" {
            // 播放器 opens the original's `livecamPlayerMenu`
            // (`PlayerScreen.cs:185`): 上一首 ｜ 播放/暂停 ｜ 下一首, the three
            // `music.*` ops the bar already sends, enabled by the same flags.
            let music = self.snapshot["music"].clone();
            let connected = self.connected();
            let weak = cx.entity().downgrade();
            return button
                .dropdown_menu(move |menu, _, _| {
                    let playing = music["isPlaying"].as_bool() == Some(true);
                    let mut menu = menu
                        .item(
                            PopupMenuItem::new(
                                music["title"]
                                    .as_str()
                                    .unwrap_or("播放器尚未准备好")
                                    .to_owned(),
                            )
                            .disabled(true),
                        )
                        .separator();
                    for (title, op, enabled) in [
                        (
                            "上一首",
                            "music.previous",
                            music["canPrevious"].as_bool() == Some(true),
                        ),
                        (
                            if playing { "暂停" } else { "播放" },
                            if playing { "music.pause" } else { "music.play" },
                            connected,
                        ),
                        ("下一首", "music.next", music["canNext"].as_bool() == Some(true)),
                    ] {
                        let weak = weak.clone();
                        menu = menu.item(
                            PopupMenuItem::new(title.to_owned())
                                .disabled(!enabled)
                                .on_click(move |_, _, cx| {
                                    let _ = weak
                                        .update(cx, |this, cx| this.submit(json!({"op":op}), cx));
                                }),
                        );
                    }
                    menu
                })
                .into_any_element();
        }
        let action = compact_action(id);
        button
            .on_click(cx.listener(move |this, _, _, cx| this.action(action, cx)))
            .into_any_element()
    }

    fn controls(&self) -> Vec<TransportControl> {
        let playing = self.snapshot["music"]["isPlaying"].as_bool() == Some(true);
        let fullscreen = self.snapshot["ui"]["fullscreen"].as_bool() == Some(true);
        let rows = transport_rows(playing, fullscreen);
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
                    // The group divider is painted after the group's last entry:
                    // 音量 ends the media group, 电视 the room's.
                    .ends_group(transport_group_ends_after(id))
                    .hold(id == "voice");
                // 设置 is an icon like every other control now: the words live in
                // its tooltip and its accessibility label.
                control
            })
            .collect()
    }
}

impl Render for ShellPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let viewport = window.viewport_size();
        trace_layout(viewport, None);
        // 小窗 is a different window shape, not a smaller one: its menu is the
        // right-edge Live Cam column and its surfaces stop at that column.
        let compact = compact_window(&self.snapshot);
        // The full-window root has no surface: only the shared floating chrome
        // and the selected panel paint, leaving the production world visible.
        let mut root = div()
            .relative()
            .size_full()
            // The root's text colour is the overlay's own, not the system
            // theme's: this layer floats over the rendered space and its
            // palette is fixed (`ui_tokens::scene`). `cx.theme()` here made the
            // probe's text follow the OS appearance while every panel around it
            // stayed dark.
            .text_color(rgba(scene::TEXT))
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
            let label = self.panes[index].0.clone();
            let is_chat = label == "聊天";
            // 物品 sizes itself too: the list is short far more often than it
            // is long, and the original's 340 pt panel is bottom-right pinned
            // rather than stretched to a full-height container.
            let is_props = label == "物品";
            if !is_chat {
                crate::report_chat_drop_bounds(None);
            }
            // The whole box decision in one place (`panel_box`), so the width a
            // test pins is the width the panel is really given: the pane's own
            // content floor can raise the panel above the original 590 pt
            // ceiling but never past what the window can hold.
            let (panel_width, panel_height) = panel_box(viewport, compact, &label);
            // The panel's own 音量 row is gone: the duplicate lyrics button that
            // sat in it, and the 小窗 button beside it. 音量 moved into the
            // floating bar as an icon whose slider pops **up** from the bar
            // (`with_volume_popover`), and 小窗 moved there as a bar toggle.
            let content = if is_chat {
                self.panes[index].1.clone().into_any_element()
            } else {
                // The box is pinned to the panel's own width: a pane mounted
                // whole (「消息」 mounts the shared `InboxPane`) must never take
                // its right edge from `panel_container`'s `items_end` and push
                // its left out of the panel.
                panel_content(self.panes[index].1.clone().into_any_element())
                    .into_any_element()
            };
            root = root.child(
                panel_container(
                    is_chat || is_props,
                    panel_width,
                    panel_height,
                    panel_bottom_gap(&label),
                    compact,
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
        if compact {
            // 小窗: the menu is the right-edge Live Cam column, never the wide
            // transport bar nor the destination pill — the original's compact
            // window hides the toolbar and draws `livecam-controls` in its place
            // (`Player.uss:95-97`).
            root = root.child(self.compact_controls(cx));
        } else {
            let hold = click.clone();
            let destination = click.clone();
            // The bar's 音量 icon carries its panel — the vertical track and the
            // mute icon — as a popover above the bar; the slider entity is
            // captured so the panel stays live while it is open, and the pane's
            // own weak handle is what the mute icon clicks back into.
            let controls = with_volume_popover(
                self.controls(),
                self.volume.clone(),
                self.volume_open,
                self.muted,
                self.connected(),
                click.clone(),
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
        }
        if let Some(notice) = self.queue_error.clone().or_else(|| {
            self.snapshot["ui"]["error"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
        }) {
            // The notice keeps clear of the reserved compact column too.
            let (left, bottom, width) = if compact {
                (
                    metrics::COMPACT_MARGIN,
                    metrics::COMPACT_MARGIN,
                    (f32::from(viewport.width)
                        - metrics::COMPACT_MARGIN
                        - metrics::COMPACT_CONTENT_RIGHT)
                        .max(0.),
                )
            } else {
                (
                    metrics::TRANSPORT_INSET,
                    metrics::TRANSPORT_INSET,
                    metrics::TASK_FEEDBACK_WIDTH,
                )
            };
            root = root.child(
                div()
                    .absolute()
                    .left(px(left))
                    .bottom(px(bottom))
                    .w(px(width))
                    .p_2()
                    // The queue/notice toast is an overlay surface: its card and
                    // its words come from the fixed palette, like every other
                    // panel in this layer. `cx.theme()` painted it with the
                    // system appearance (`theme.background` /
                    // `theme.danger`) — a second palette inside one window.
                    .bg(rgba(scene::CARD_BG))
                    .text_color(rgba(scene::WARNING))
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
        let mut chat = super::panel_container(true, 620., 320., super::panel_bottom_gap("聊天"), false);
        let mut content_sized = div().max_h(px(320.));
        let mut fixed = super::panel_container(false, 590., 458., super::panel_bottom_gap("音乐与空间"), false);
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
        let mut props = super::panel_container(true, 590., 374., super::panel_bottom_gap("物品"), false);
        let mut content_sized = div().max_h(px(374.));
        let mut filled = super::panel_container(false, 590., 374., super::panel_bottom_gap("音乐与空间"), false);
        assert_eq!(props.style().size.height, content_sized.style().size.height);
        assert_ne!(props.style().size.height, filled.style().size.height);
        // The corner is the transport bar's: 22 from the right, the 物品 pane's
        // own 12 pt gap + the 48 pt bar above the window's bottom.
        let mut anchor = div()
            .right(px(super::metrics::TRANSPORT_INSET))
            .bottom(px(
                super::metrics::TRANSPORT_INSET
                    + super::metrics::TRANSPORT_HEIGHT
                    + super::stage::PROP_EDITOR_BOTTOM_GAP,
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

    /// The 物品 panel's bottom distance is the original's own
    /// (`StageWindowController.swift:1523`: `bottom == transportControls.top -
    /// 12`), and **only** the 物品 panel gets it: the composer and the media
    /// surfaces keep the shell's 16. Both numbers are asserted against the
    /// shared tokens, so pinning the pane to the wrong gap (16 for 物品, or 12
    /// everywhere) turns this red.
    #[test]
    fn only_the_props_pane_keeps_the_originals_twelve_pt_bottom_gap() {
        assert_eq!(super::stage::PROP_EDITOR_BOTTOM_GAP, 12.);
        assert_eq!(super::metrics::COMPOSER_GAP, 16.);
        assert_ne!(
            super::stage::PROP_EDITOR_BOTTOM_GAP,
            super::metrics::COMPOSER_GAP
        );
        assert_eq!(super::panel_bottom_gap("物品"), 12.);
        for other in ["聊天", "音乐与空间"] {
            assert_eq!(
                super::panel_bottom_gap(other),
                super::metrics::COMPOSER_GAP,
                "{other} keeps the shell's composer gap"
            );
        }
        // …and the container really places its bottom edge there: 22 + 48 + 12
        // above the window's bottom, a media pane 4 pt higher.
        use gpui_kit::{Styled, div, px};
        let mut props = super::panel_container(true, 590., 374., super::panel_bottom_gap("物品"), false);
        let mut media = super::panel_container(false, 590., 374., super::panel_bottom_gap("音乐与空间"), false);
        let mut props_anchor = div().bottom(px(22. + 48. + 12.));
        let mut media_anchor = div().bottom(px(22. + 48. + 16.));
        assert_eq!(props.style().inset.bottom, props_anchor.style().inset.bottom);
        assert_eq!(media.style().inset.bottom, media_anchor.style().inset.bottom);
        assert_ne!(props.style().inset.bottom, media.style().inset.bottom);
    }
    #[test]
    fn panel_extent_is_derived_from_the_live_viewport_after_a_fullscreen_resize() {
        use gpui_kit::{Pixels, Size, Styled, px, size};
        let windowed: Size<Pixels> = size(px(720.), px(450.));
        let fullscreen: Size<Pixels> = size(px(1920.), px(1080.));
        let (small_width, small_height) = super::panel_extent(windowed, false, 0.);
        let (large_width, large_height) = super::panel_extent(fullscreen, false, 0.);
        // The old 720×450 extent must not survive into the fullscreen window:
        // both numbers follow the window it is laid out in.
        assert_eq!((small_width, small_height), (720. - 44., 450. - 44. - 48. - 16.));
        assert_eq!((large_width, large_height), (1920. - 44., 1080. - 44. - 48. - 16.));
        assert!(large_width > small_width && large_height > small_height);
        // A pane with a content floor is never given less than that floor while
        // the window can hold it, and is never pushed past the window's own
        // 22 pt inset when it cannot.
        assert_eq!(
            super::panel_extent(size(px(560.), px(450.)), false, 614.),
            (560. - 22., 450. - 44. - 48. - 16.)
        );
        assert_eq!(
            super::panel_box(fullscreen, false, "音乐与空间").0,
            614.,
            "a roomy window gives the message surface its floor, not the whole viewport"
        );
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
            let mut panel = super::panel_container(content_sized, width, height, super::metrics::COMPOSER_GAP, false);
            assert_eq!(panel.style().inset.right, anchor.style().inset.right);
            assert_eq!(panel.style().inset.bottom, anchor.style().inset.bottom);
        }
    }

    /// 「消息」 is the widest thing the media panel can show: the shared
    /// `InboxPane` keeps a 240 pt list floor and a 320 pt detail floor side by
    /// side (`inbox::PANE_MIN_WIDTH` = 580 pt), and the media surface's own
    /// padding makes that a 614 pt panel (`media_ui::PANEL_CONTENT_FLOOR`).
    ///
    /// The panel used to take `min(viewport − 2 × TRANSPORT_INSET,
    /// stage::PANEL_MAX_WIDTH)` = 590 pt and hand the pane 558 — 22 pt short of
    /// the two columns — so the message surface could not be shown whole. This
    /// pins the real `panel_box` the renderer calls: the panel takes that floor
    /// while the window can hold it, never leaves the window, and only the media
    /// panel is affected.
    #[test]
    fn the_media_panel_takes_the_width_the_message_surface_needs() {
        use gpui_kit::{Pixels, Size, px, size};
        let floor = crate::media_ui::PANEL_CONTENT_FLOOR;
        assert_eq!(floor, 614.);
        assert_eq!(
            floor,
            gmgn_gpui_ui::ui_tokens::inbox::PANE_MIN_WIDTH
                + 2. * crate::media_ui::SURFACE_PADDING
                + 2. * crate::media_ui::SURFACE_BORDER
        );
        // The original 590 pt ceiling really is too narrow for this pane: that
        // is the defect, not a preference.
        assert!(floor > super::stage::PANEL_MAX_WIDTH);
        for (w, h) in [(720., 482.), (1280., 720.), (1920., 1080.)] {
            let viewport: Size<Pixels> = size(px(w), px(h));
            let (width, _) = super::panel_box(viewport, false, "音乐与空间");
            assert_eq!(
                width, floor,
                "the media panel must be wide enough for the message surface at {w}×{h}"
            );
            assert!(
                w - super::metrics::TRANSPORT_INSET - width >= 0.,
                "the panel must stay inside the window at {w}×{h}: width={width}"
            );
        }
        // A window too small for the floor still uses every point it has, and
        // never grows past its own left inset.
        let narrow: Size<Pixels> = size(px(560.), px(450.));
        assert_eq!(super::panel_box(narrow, false, "音乐与空间").0, 560. - 22.);
        // …and the floor belongs to the media panel: the other panes keep the
        // widths they had.
        let roomy: Size<Pixels> = size(px(1920.), px(1080.));
        assert_eq!(super::panel_box(roomy, false, "聊天").0, super::chat::PANEL_MAX_WIDTH);
        assert_eq!(super::panel_box(roomy, false, "物品").0, super::stage::PANEL_MAX_WIDTH);
    }

    /// The panel's content box is pinned to the panel's own width. The panel
    /// ends its children at the bottom-right corner (`items_end`), so a pane
    /// whose intrinsic width is wider than the panel — 「消息」 mounts the whole
    /// `InboxPane`, whose list keeps a definite 300 pt preferred width — takes
    /// its right edge from that corner and overflows off the panel's **left**.
    /// Measured on the unfixed fixture at 720×482: the message body came out
    /// 640 pt wide in a 590 pt panel, starting 83 pt left of the panel's edge,
    /// with the list's unread dot and the head of every title clipped away.
    ///
    /// The style is read off the box the renderer really builds, and the source
    /// check keeps the renderer routing every non-chat pane through it.
    #[test]
    fn the_panel_content_box_is_pinned_to_the_panels_own_width() {
        use gpui_kit::{IntoElement, Styled, div, px, relative};
        let mut content = super::panel_content(div().into_any_element());
        assert_eq!(
            content.style().size.width,
            Some(relative(1.).into()),
            "the panel's content box must be 100 % of the panel, not sized by its own content"
        );
        assert_eq!(
            content.style().min_size.width,
            Some(px(0.).into()),
            "the box must be allowed to shrink to the panel's width"
        );
        let source = include_str!("shell_ui.rs");
        assert!(
            source.contains("panel_content(self.panes[index].1.clone()"),
            "the renderer must mount every non-chat pane through the pinned content box"
        );
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

    /// 音量's panel opens **upwards** and carries the two controls the person
    /// asked for: the layer's **vertical** track and a **small icon** mute
    /// button — never a horizontal `Slider` and never a switch or a bar.
    ///
    /// The assertions slice the popover builder this file really mounts, so
    /// putting the track back to a bare (horizontal) kit `Slider`, or the mute
    /// back to a switch/full-width bar, turns this red.
    #[test]
    fn the_volume_panel_opens_upwards_with_a_vertical_track_and_an_icon_mute() {
        let source = include_str!("shell_ui.rs");
        let panel = &source[source.find("fn with_volume_popover(").unwrap()..];
        let panel = &panel[..panel.find("\n}\n").expect("the builder ends at column zero")];
        // The track is the layer's own vertical element. A bare kit `Slider` is
        // horizontal until `.vertical()` is applied, and it is what was rejected.
        assert!(
            panel.contains("ui::volume_slider(&volume, connected)"),
            "音量's track must be the layer's vertical one: {panel}"
        );
        assert!(
            !panel.contains("Slider::new(&volume)"),
            "a bare kit Slider is the horizontal bar that was rejected: {panel}"
        );
        // The mute control is the layer's small square icon button.
        assert!(
            panel.contains("ui::volume_mute_button(muted, connected)"),
            "静音 must be the layer's icon button: {panel}"
        );
        assert!(!panel.contains("Switch"), "静音 is not a switch: {panel}");
        assert!(
            !panel.contains("w_full()"),
            "静音 is not a full-width bar: {panel}"
        );
        // The panel itself is the bar's own surface, and it is a column: the
        // track sits above the mute icon. The builder returns **content only** —
        // wrapping it in a second `transport_popover` leaves an empty card
        // sitting right above the bar, which is the stray strip that was there.
        assert!(
            !panel.contains("shell::transport_popover("),
            "the content must not wrap itself in the bar's own surface: {panel}"
        );
        assert!(
            gmgn_gpui_ui::shell::TRANSPORT_POPOVER_GAP > 0.,
            "the popover must clear the bar upward rather than sit inside it"
        );
        assert!(
            panel.find("ui::volume_slider(") < panel.find("ui::volume_mute_button("),
            "the vertical track comes first; the mute icon sits under it: {panel}"
        );
    }

    /// 静音 remembers the level it replaced and 取消静音 writes it back — the
    /// pair is the one `music.volume` op in both directions, and a `0` level
    /// never overwrites the memory (otherwise the second press would restore
    /// silence instead of the music).
    #[test]
    fn mute_remembers_the_level_it_replaced() {
        // 静音 → 0; 取消静音 → the level that was playing.
        assert_eq!(super::mute_toggle_value(false, 0.35), 0.);
        assert_eq!(super::mute_toggle_value(true, 0.35), 0.35);
        assert_ne!(
            super::mute_toggle_value(true, 0.35),
            super::mute_toggle_value(false, 0.35),
            "the two states publish different levels"
        );
        // Publishing 0 keeps the memory; publishing a non-zero level replaces it.
        assert_eq!(super::remembered_level(0.35, 0.), 0.35);
        assert_eq!(super::remembered_level(0.35, 0.8), 0.8);
        // The default is the player's own full level, so 取消静音 never invents
        // a quieter level than the product's own.
        assert_eq!(super::VOLUME_MUTE_RESTORE_DEFAULT, 1.);
    }

    /// The bar's order, read from the table the bar is really built from:
    ///
    /// `歌单 歌词 上一首 播放/暂停 下一首 音量 ｜ 聊天 通知 物品 电视 ｜ 设置 小窗 全屏`
    ///
    /// 音量's **position** is the rule: it is the media group's last control, so
    /// it sits *before* the divider that ends the group. Moving it out of the
    /// group (past the divider, or to the end of the bar) turns this red, and
    /// the microphone stays out of the bar.
    #[test]
    fn the_bar_order_keeps_volume_inside_the_media_group() {
        let rows = super::transport_rows(false, false);
        let ids: Vec<&str> = rows.iter().map(|(id, _, _)| *id).collect();
        assert_eq!(
            ids,
            vec![
                "program", "lyrics", "previous", "play", "next", "volume", "chat", "inbox",
                "props", "screen", "visual", "compact", "mode",
            ]
        );
        // The media group's boundary is the first divider, and 音量 is the
        // control it follows.
        let media_group_ends = ids
            .iter()
            .position(|id| super::transport_group_ends_after(id))
            .expect("the media group has a boundary");
        assert_eq!(ids[media_group_ends], "volume", "音量 ends the media group");
        assert_eq!(
            ids[..=media_group_ends].to_vec(),
            vec!["program", "lyrics", "previous", "play", "next", "volume"],
            "音量 must be inside the media group, ahead of the divider"
        );
        assert_eq!(ids[media_group_ends + 1], "chat", "聊天 opens the next group");
        // Playing flips 播放/暂停's glyph and fullscreen flips 全屏's; neither
        // moves a control.
        let playing: Vec<&str> = super::transport_rows(true, true)
            .iter()
            .map(|(id, _, _)| *id)
            .collect();
        assert_eq!(playing, ids, "live state never reorders the bar");
        // 麦克风 is not drawn; the push-to-talk path stays in the bar's loop.
        assert!(!ids.contains(&"voice"), "the microphone stays hidden");
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
        // The mute icon publishes through that same sender, so 静音 cannot
        // become a second writer of the op.
        assert!(
            source.contains("this.set_volume(value.start(), cx)"),
            "the slider's release must go through the one volume sender"
        );
        assert!(
            source.contains("fn set_volume(&mut self, value: f32, cx: &mut Context<Self>)"),
            "the one volume sender is `set_volume`, which both controls call"
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

    /// 小窗's menu is the Live Cam control column: **vertical, down the window's
    /// right edge**. The assertion reads the box the column is really laid out
    /// with — its axis, its corner and its width — against the original's own
    /// numbers, so turning the axis back into the bar's row, moving the column
    /// off the right edge or widening it turns this red.
    ///
    /// Reference: the AppKit original's vertical stack, 30 pt entries 6 pt
    /// apart, 10 pt from the top/right corner (`LiveCamPanel.swift:699-708,
    /// 861-866`) and its Unity transcription `.compact-window .livecam-controls
    /// { display:flex; position:absolute; top:10px; right:10px; width:30px; }`
    /// (`Player.uss:96-97`).
    #[test]
    fn the_compact_menu_is_a_vertical_column_on_the_right_edge() {
        use gpui_kit::{Styled, div, px};
        let mut column = super::compact_column();
        // The axis is a column — and specifically *not* the wide bar's row.
        assert_eq!(
            column.style().flex_direction,
            div().flex().flex_col().style().flex_direction,
            "小窗 lays its menu out vertically"
        );
        assert_ne!(
            column.style().flex_direction,
            div().flex().style().flex_direction,
            "a row is the transport bar's axis; 小窗 must not use it"
        );
        // absolute, `top: 10px; right: 10px; width: 30px` — the reference
        // literals themselves, read back out of the real style.
        assert_eq!(
            column.style().position,
            div().absolute().style().position,
            "the column floats over the scene"
        );
        assert_eq!(
            column.style().inset.top,
            div().top(px(10.)).style().inset.top
        );
        assert_eq!(
            column.style().inset.right,
            div().right(px(10.)).style().inset.right,
            "the column is pinned to the window's right edge"
        );
        assert_eq!(
            column.style().inset.left,
            div().style().inset.left,
            "only the right edge is anchored; the column is not stretched"
        );
        assert_eq!(
            column.style().size.width,
            div().w(px(30.)).style().size.width,
            "30 pt wide, the original's fixed column width"
        );
        assert_eq!(
            column.style().gap,
            div().gap(px(6.)).style().gap,
            "entries sit 6 pt apart"
        );
        // 10 pt margin + 30 pt column + 8 pt reserved gap = the 48 pt inset every
        // other compact surface stops at (`Player.uss:99,102`).
        assert_eq!(super::metrics::COMPACT_CONTENT_RIGHT, 48.);
        assert_eq!(
            super::metrics::COMPACT_MARGIN
                + super::metrics::COMPACT_CONTROL
                + super::metrics::COMPACT_COLUMN_GAP,
            super::metrics::COMPACT_CONTENT_RIGHT
        );
    }

    /// The column carries the original's six entries, in the original's order
    /// (`LiveCamPanel.swift:703-708`; `PlayerScreen.cs:101-104`).
    #[test]
    fn the_compact_column_lists_the_originals_entries_in_order() {
        assert_eq!(
            super::COMPACT_CONTROLS.map(|(id, _)| id),
            ["space", "player", "chat", "inbox", "settings"]
        );
        assert_eq!(super::COMPACT_CONTROLS.len(), 5);
        // Each entry routes to an op this worktree already handles.
        assert_eq!(super::compact_action("space"), "space");
        assert_eq!(super::action_command("visual", false).unwrap()["op"], "ui.settings.open");
        for (id, action) in [
            ("space", "space"),
            ("player", "player"),
            ("chat", "chat"),
            ("inbox", "inbox"),
            ("settings", "visual"),
        ] {
            assert_eq!(super::compact_action(id), action, "{id}'s op");
            // Every entry has a glyph, so no button can render blank.
            let _ = super::compact_icon(id);
        }
    }

    /// The host's projection is what selects 小窗; the screenshot override can
    /// only turn it on, never off. Without a `compact` flag the wide bar's
    /// window is what is drawn.
    #[test]
    fn the_hosts_compact_projection_selects_the_compact_layout() {
        use serde_json::json;
        assert!(super::compact_window(&json!({"ui": {"compact": true}})));
        if std::env::var("GMGN_GPUI_COMPACT").as_deref() != Ok("1") {
            assert!(!super::compact_window(&json!({"ui": {"compact": false}})));
            assert!(!super::compact_window(&json!({"ui": {}})));
            assert!(!super::compact_window(&json!({})));
        }
    }

    /// 小窗 renders the column **instead of** the wide bar and the destination
    /// The probe's own control set, measured against the derivation.
    ///
    /// `transport_rows` is 13 controls — twelve 44 pt slots and the 68 pt 设置
    /// slot — with [`super::transport_group_ends_after`] ending two groups, so
    /// the bar places 13 slots + 2 hairlines = 15 flex children and gaps the 14
    /// pairs between them. The reading is spelled out instead of derived, so a
    /// wrong `transport_width` cannot make this agree with itself: the old
    /// "two group gaps" reading derives 691 - 72 = 619 for the same bar.
    #[test]
    fn the_transport_width_counts_every_flex_child_the_bar_places() {
        use gmgn_gpui_ui::shell::{self, TransportControl};

        let rows = super::transport_rows(false, false);
        let controls: Vec<TransportControl> = rows
            .into_iter()
            .map(|(id, icon, label)| {
                TransportControl::new(id, id, icon, label)
                    .ends_group(super::transport_group_ends_after(id))
            })
            .collect();

        let slots = 12. * 44. + 68.;
        let dividers = 2. * 1.;
        let insets = 2. * 4.;
        let gaps = 14. * 6.;
        let width = slots + dividers + insets + gaps + 1.;
        assert_eq!(controls.len(), 13);
        assert_eq!(
            controls.iter().filter(|control| control.ends_group).count(),
            2,
            "音量 and 电视 end the bar's two groups"
        );
        assert_eq!(
            shell::transport_width(&controls),
            width,
            "the derivation must count a gap between every neighbouring pair of \
             the bar's real children, not two group gaps"
        );
        assert_eq!(width, 691.);
        // 691 + the 1 pt rounding term is 692 pt of bar pinned 22 pt from the
        // right edge of the probe's 720 pt Unity sample: `x = 6`, i.e. it fits.
        // The defect was never that this bar overflowed — it is that the host
        // placed it by a derivation that **understated** it (the old reading is
        // 619 for this set, and 529 vs a real 584 for the product's), so the
        // number the placement trusted was smaller than the thing it placed.
        // `apps/gpui-ui/tests/transport_popover_geometry.rs` pins that equality
        // in real pixels; this pins the probe's own arithmetic.
        assert!(width + 1. + 22. <= 720., "the probe's bar fits its sample canvas");
    }

    /// 小窗 renders the column **instead of** the wide bar and the destination
    /// pill: the original hides the toolbar in its compact window and draws
    /// `livecam-controls` in its place (`Player.uss:95-97`), and a 224 pt window
    /// cannot hold a horizontal bar anyway.
    #[test]
    fn the_compact_window_replaces_the_transport_bar_with_the_column() {
        let source = include_str!("shell_ui.rs");
        let render = &source[source.find("impl Render for ShellPane").unwrap()..];
        let body = &render[..render.find("\n}\n").unwrap()];
        let column = format!("self.{}(", "compact_controls");
        assert!(
            body.contains(&column),
            "the compact branch must build the Live Cam column"
        );
        let compact_at = body.find("if compact {").expect("a compact branch");
        let branch = &body[compact_at..];
        let else_at = branch
            .find("} else {")
            .expect("the compact branch has a non-compact else");
        let bar_at = branch
            .find("shell::transport_bar_in(")
            .expect("the wide bar still exists for the stage window");
        assert!(
            bar_at > else_at,
            "the wide transport bar must sit on the non-compact branch, not in 小窗"
        );
    }
}
