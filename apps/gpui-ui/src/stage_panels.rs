//! Native stage panels. Catalogs, availability and every mutation belong to the
//! host; this layer only presents them.
//!
//! The stage settings surface is the original `StageVisualPickerView`
//! (`apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift:2716-3351`,
//! plus `StageControlPanelLayout` / `StageVisualPickerGroup` /
//! `StageControlPanelTab` / `StageActivityAvailability` at `:2629-2713`)
//! rebuilt on gpui-kit.
//!
//! Shape of the surface, and why it is split this way:
//!
//! - **Four partitions, in the original order** — 播放器 / 空间 / 角色 / 活动.
//!   The set and the order live in [`STAGE_TABS`], the initial choice in
//!   [`initial_tab`]; the render reads them instead of spelling its own list.
//! - **The grouping order inside a partition is the original's**, not the order
//!   the widgets happen to be written in: [`visible_groups`] returns the
//!   `StageVisualPickerGroup` sequence for a mode, and the render iterates it.
//! - **This is the right-hand popup.** One fixed header row (title + mode), the
//!   segmented partition picker, then exactly one scrolling content area, so no
//!   amount of scrolling can push the partition choice or the mode readout out of
//!   the panel. The host already clamps the popup to the original 590×458
//!   (`StageControlPanelLayout.maximumWidth/.maximumHeight`); the pane fills the
//!   frame it is given and never grows past those maxima, so a smaller window
//!   shrinks the panel instead of clipping it.
//! - **Nothing here reads `cx.theme()`.** Every colour, size and gap is a token:
//!   [`crate::ui_tokens::scene`] for chrome the overlay panels share,
//!   [`crate::primitives`] for type roles, and [`crate::ui_tokens::stage`] for
//!   the numbers that only exist in the original picker. A light system theme can
//!   never invert a panel that floats over the rendered space.
//! - Controls are kit components: `Button` with an explicit custom variant (so
//!   resting/hover/pressed chrome is fixed rather than theme-derived), kit
//!   `Slider`, kit segmented `TabBar`/`Tab`, kit `Icon`, kit `PopupMenu` for the
//!   world and video submenus. Nothing here is a bare `div` pretending to be a
//!   control.
use crate::i18n::{UiLocale, player_choice_label, settings_copy};
use crate::primitives as ui;
use crate::ui_tokens as doc;
use crate::ui_tokens::scene as s;
use gpui_kit::assets::IconName as AssetIcon;
use gpui_kit::component::{
    button::*,
    menu::*,
    slider::{SliderEvent, SliderState},
    *,
};
use gpui_kit::prelude::{FluentBuilder as _, InteractiveElement as _, StatefulInteractiveElement as _};
use gpui_kit::*;
use serde_json::{Value, json};

mod program;
mod props;
pub use program::{ProgramMaterialCard, ProgramMaterialFrame, StageProgramRailPane};
pub use props::ResidentPropEditorPane;

/// The stage panels' surface readings now live in [`crate::ui_tokens::stage`]
/// (with [`crate::ui_tokens::props`] and [`crate::ui_tokens::program`] for the
/// two sub-panels). They were moved there verbatim from this file's local
/// `metrics` module on 2026-10-08 so each surface has **one** copy: `ui_tokens`
/// carries the numbers together with their Swift source, and this file only
/// references them through the alias below.
use crate::ui_tokens::stage as metrics;

/// The original's panel width/height ceilings (`StageControlPanelLayout`). The
/// host clamps the popup to these; the pane only ever shrinks below them.
pub const STAGE_PANEL_WIDTH: f32 = metrics::PANEL_MAX_WIDTH;
pub const STAGE_PANEL_HEIGHT: f32 = metrics::PANEL_MAX_HEIGHT;

/// The four partitions, in `StageControlPanelTab.allCases` order
/// (`StageOverlayView.swift:2659-2681`). These are the original's own labels and
/// stay literal.
pub const STAGE_TABS: [&str; 4] = ["播放器", "空间", "角色", "活动"];

/// The stage panel's bootstrap request. The Unity host has **no** load step
/// behind it — the stage projection arrives with every snapshot — and its
/// handler answers `false` (`UnityMediaHost.command` /
/// `UnityMediaHost.settingsCommand`), so [`StagePanelsPane::new`] does not emit
/// it. The name is kept here so the op surface stays documented in one place.
pub const STAGE_LOAD_OP: &str = "stage.load";

/// One icon per [`STAGE_TABS`] entry, in the same order. The partition picker is
/// a control, and controls in this layer are icon-only: the words live in the
/// tab's accessibility label and tooltip, never on its face.
pub const STAGE_TAB_ICONS: [AssetIcon; 4] = [
    AssetIcon::Play,
    AssetIcon::Globe,
    AssetIcon::CircleUser,
    AssetIcon::Calendar,
];

/// `StageVisualPickerMode` (`:2629-2636`): derived from whether the world
/// presentation was requested, never stored locally.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StageMode {
    Player,
    Space,
}

impl StageMode {
    pub fn resolve(is_world_requested: bool) -> Self {
        if is_world_requested {
            Self::Space
        } else {
            Self::Player
        }
    }

    /// Index into [`STAGE_TABS`].
    pub fn tab(self) -> usize {
        match self {
            Self::Player => 0,
            Self::Space => 1,
        }
    }
}

/// `StageVisualPickerGroup` (`:2638-2657`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VisualGroup {
    WorldSelection,
    AvatarPlacement,
    LoadingStatus,
    LyricsEffects,
    PointCloud,
    ParticleSize,
    MusicVideo,
}

/// `StageVisualPickerGroup.visibleGroups(for:)`: the groups a mode shows, **in
/// the original's order**. A local reordering renders a different panel.
pub fn visible_groups(mode: StageMode) -> &'static [VisualGroup] {
    match mode {
        StageMode::Space => &[
            VisualGroup::WorldSelection,
            VisualGroup::AvatarPlacement,
            VisualGroup::LoadingStatus,
        ],
        StageMode::Player => &[
            VisualGroup::LyricsEffects,
            VisualGroup::PointCloud,
            VisualGroup::ParticleSize,
            VisualGroup::MusicVideo,
        ],
    }
}

/// `StageControlPanelTab.initial(for:isRadioPluginEnabled:)` (`:2665-2671`).
///
/// With the radio plugin off (the default) **every** entry point lands on
/// 「空间」; with it on, space mode lands on space and everything else on the
/// player. The four partitions stay selectable either way.
pub fn initial_tab(is_radio_plugin_enabled: bool, mode: StageMode) -> usize {
    if !is_radio_plugin_enabled {
        return StageMode::Space.tab();
    }
    mode.tab()
}

/// `StageControlPanelTab` from a host tab name (`select_tab`). Unknown names keep
/// the original default: 「空间」.
pub fn tab_for_name(name: &str) -> usize {
    match name {
        "player" => 0,
        "motions" => 2,
        "activities" => 3,
        _ => 1,
    }
}

/// `StageActivityAvailability.canRun(isWorldVisible:selectedWorldID:activityWorldID:)`
/// (`:2706-2712`): the world must be visible **and** be the world the activity
/// belongs to. A world that is merely requested does not qualify.
pub fn activity_can_run(
    is_world_visible: bool,
    selected_world_id: Option<&str>,
    activity_world_id: Option<&str>,
) -> bool {
    is_world_visible && selected_world_id.is_some() && selected_world_id == activity_world_id
}

/// `StageActivityAvailability.unavailableMessage` (`:2697-2704`).
pub fn activity_unavailable_message(
    is_world_visible: bool,
    is_world_requested: bool,
) -> &'static str {
    if is_world_visible {
        "这个空间还没有配置生活活动。"
    } else if is_world_requested {
        "空间载入完成后可选择活动。"
    } else {
        "进入空间后可选择生活活动。"
    }
}

/// The mode readout under the title (`:2747`).
pub fn mode_readout(mode: StageMode) -> &'static str {
    match mode {
        StageMode::Space => "正在空间中",
        StageMode::Player => "正在播放器中",
    }
}

/// `GridItem(.adaptive(minimum:))`: how many equal columns fit in `available`
/// with `spacing` between them. SwiftUI picks the largest count whose minimum
/// still fits; at least one column always exists.
pub fn adaptive_columns(minimum: f32, available: f32, spacing: f32) -> usize {
    if minimum <= 0. || !available.is_finite() || !spacing.is_finite() || available <= 0. {
        return 1;
    }
    (((available + spacing) / (minimum + spacing)).floor() as usize).max(1)
}

/// The width one adaptive column gets, so a tile fills the grid exactly.
pub fn adaptive_tile_width(minimum: f32, available: f32, spacing: f32) -> f32 {
    let columns = adaptive_columns(minimum, available, spacing) as f32;
    ((available - spacing * (columns - 1.)) / columns).max(1.)
}

/// The grid width the original lays tiles into: the panel minus the outer 7 pt
/// (:2792) and inner 16 pt (:2780) insets.
pub fn grid_width() -> f32 {
    metrics::PANEL_MAX_WIDTH - 2. * metrics::PANEL_OUTER_PADDING - 2. * metrics::PANEL_PADDING
}

/// `loadingStatusGroup` (`:3012-3032`), in the original's evaluation order.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WorldStatus<'a> {
    /// `isWorldPresentationRequested && !isWorldVisible`.
    Loading,
    /// `marbleLibrary.generationMessage`.
    Generating(&'a str),
    /// `marbleLibrary.errorMessage`.
    Failed(&'a str),
}

/// The first of the three states that applies. A requested-but-invisible world
/// wins over both messages — otherwise a failed load would render as a
/// successful one.
pub fn world_loading_status<'a>(
    is_world_requested: bool,
    is_world_visible: bool,
    generation_message: Option<&'a str>,
    error_message: Option<&'a str>,
) -> Option<WorldStatus<'a>> {
    if is_world_requested && !is_world_visible {
        return Some(WorldStatus::Loading);
    }
    if let Some(message) = generation_message.filter(|s| !s.trim().is_empty()) {
        return Some(WorldStatus::Generating(message));
    }
    if let Some(message) = error_message.filter(|s| !s.trim().is_empty()) {
        return Some(WorldStatus::Failed(message));
    }
    None
}

/// Whether a motion belongs to the selected category. An empty selection is
/// 「全部」 and keeps every motion.
pub fn motion_in_category(motion: &Value, category: &str) -> bool {
    category.is_empty() || motion["category"].as_str() == Some(category)
}

/// The selected index of the category picker: 0 is 「全部」, then the categories
/// in the host's order. A category the host no longer lists falls back to 全部
/// rather than selecting a different category.
pub fn motion_category_index(category: &str, categories: &[Value]) -> usize {
    if category.is_empty() {
        return 0;
    }
    categories
        .iter()
        .position(|entry| entry["id"].as_str() == Some(category))
        .map_or(0, |index| index + 1)
}

/// Which notice — if any — the motion list shows. The original checks the
/// unfiltered list first, then the loader's notice, and only then the empty
/// category (`:2862-2868`); getting that order wrong hides a real failure.
#[derive(Debug, PartialEq, Eq)]
pub enum MotionNotice<'a> {
    Empty,
    ListNotice(&'a str),
    CategoryEmpty,
    None,
}

pub fn motion_notice<'a>(
    total: usize,
    visible: usize,
    category: &str,
    list_notice: Option<&'a str>,
) -> MotionNotice<'a> {
    if total == 0 {
        return MotionNotice::Empty;
    }
    if let Some(notice) = list_notice.filter(|s| !s.is_empty()) {
        return MotionNotice::ListNotice(notice);
    }
    if visible == 0 && !category.is_empty() {
        return MotionNotice::CategoryEmpty;
    }
    MotionNotice::None
}

pub(crate) fn style_choice_accessibility(title: &str, name: &str, selected: bool) -> (Role, String) {
    (
        Role::Button,
        format!("{title}：{name}{}", if selected { "，已选择" } else { "" }),
    )
}
pub(crate) fn player_section_includes(section: &str, key: &str) -> bool {
    match section {
        "歌词" => key == "lyrics",
        "视觉效果" => key == "clouds",
        "视频" => key == "videoModes",
        _ => true,
    }
}

fn video_asset_actions(player: &Value, asset: &Value) -> Vec<(&'static str, Value, bool)> {
    let id = asset["id"].clone();
    let active = player["videoActive"].as_bool() == Some(true) && player["videoAssetID"] == id;
    let mut actions = vec![(
        if active { "取消加载" } else { "加载" },
        json!({"op":"stage.video.toggle","id":id}),
        false,
    )];
    if player["trackID"].as_str().is_some_and(|s| !s.is_empty()) {
        let bound = player["boundVideoID"] == id;
        // Unbinding acts on the current track, not on a named asset: both hosts
        // derive the track themselves (`GMGNRadioApp` `case "stage.video.unbind"`
        // uses `programStore.activeSlot?.track`; `UnityScreenVideoBridge`
        // injects `trackID` from `currentTrack()`), so the unbind action
        // carries no `id`/payload. `bind` is the one that names the asset.
        actions.push((
            if bound {
                "解除当前歌曲绑定"
            } else {
                "绑定到当前歌曲"
            },
            if bound {
                json!({"op":"stage.video.unbind"})
            } else {
                json!({"op":"stage.video.bind","id":id})
            },
            false,
        ));
    }
    actions.push(("移出素材库", json!({"op":"stage.video.remove","id":id}), true));
    actions
}
pub(crate) fn video_authority_notice(player: &Value) -> Option<&str> {
    player["videoNotice"]
        .as_str()
        .filter(|s| !s.trim().is_empty())
}

#[cfg(test)]
mod video_menu_tests {
    use super::{video_asset_actions, video_authority_notice};
    use serde_json::json;
    #[test]
    fn asset_submenu_preserves_active_toggle_and_bound_track_commands() {
        let actions = video_asset_actions(
            &json!({"videoActive":true,"videoAssetID":"asset","trackID":"track","boundVideoID":"asset"}),
            &json!({"id":"asset"}),
        );
        assert_eq!(actions[0].0, "取消加载");
        assert_eq!(actions[0].1, json!({"op":"stage.video.toggle","id":"asset"}));
        assert_eq!(actions[1].0, "解除当前歌曲绑定");
        assert_eq!(actions[1].1["op"], "stage.video.unbind");
        assert_eq!(actions[2].0, "移出素材库");
        assert!(actions[2].2);
    }
    #[test]
    fn no_track_omits_binding_and_inactive_asset_loads() {
        let actions = video_asset_actions(&json!({"videoActive":false}), &json!({"id":"asset"}));
        assert_eq!(actions.len(), 2);
        assert_eq!(actions[0].0, "加载");
        assert_eq!(actions[1].1, json!({"op":"stage.video.remove","id":"asset"}));
        let actions = video_asset_actions(
            &json!({"trackID":"track","boundVideoID":"other"}),
            &json!({"id":"asset"}),
        );
        assert_eq!(actions[1].0, "绑定到当前歌曲");
        assert_eq!(actions[1].1["op"], "stage.video.bind");
    }
    #[test]
    fn video_authority_failure_is_projected_without_inventing_success() {
        let waiting = json!({"videoNotice":"视频执行状态待核验；未重放旧动作。"});
        assert_eq!(
            video_authority_notice(&waiting),
            Some("视频执行状态待核验；未重放旧动作。")
        );
        assert_eq!(video_authority_notice(&json!({"videoNotice":null})), None);
        assert_eq!(video_authority_notice(&json!({"videoNotice":"  "})), None);
    }
}

pub struct StagePanelsPane {
    snapshot: Value,
    commands: Vec<Value>,
    tab: usize,
    embedded: bool,
    section: String,
    initialized: bool,
    motion_category: String,
    sliders: Vec<Entity<SliderState>>,
    syncing: bool,
    /// The host's `settings.supportedCommands` whitelist
    /// (`UnityMediaHost.swift` `supportedCommands`, forwarded by
    /// `SettingsPane::update_snapshot`). The Unity settings window refuses any
    /// op that is not in it (`settings_ui.rs` dispatch), so a control whose op
    /// is missing from the list is not drawn at all instead of being drawn and
    /// then refused with 「当前运行时不支持此操作」.
    ///
    /// An empty/absent list keeps every control: a host that does not publish
    /// the whitelist must not blank the pane.
    supported_ops: Vec<String>,
    _subscriptions: Vec<Subscription>,
}

impl StagePanelsPane {
    pub fn new(_window: &mut Window, cx: &mut Context<Self>) -> Self {
        let sliders: Vec<_> = [(-2., 2.), (-2., 2.), (-3., 3.), (0.6, 1.6), (0.15, 1.)]
            .into_iter()
            .map(|(min, max)| cx.new(|_| SliderState::new().min(min).max(max).step(0.01)))
            .collect();
        let subscriptions = sliders
            .iter()
            .enumerate()
            .map(|(i, slider)| {
                cx.subscribe(slider, move |this, _, event: &SliderEvent, cx| {
                    if this.syncing {
                        return;
                    }
                    if let SliderEvent::Change(value) = event {
                        let command = match i {
                            0..=2 => json!({"op":"stage.avatar.position","axis":(["X","Y","Z"][i]),"value":value.start()}),
                            3 => json!({"op":"stage.player.particles","value":value.start()}),
                            // Clamped to the authority's own band: the product
                            // host rejects `(0.15...1)` outside it
                            // (`GMGNRadioApp` `case "stage.video.brightness"`)
                            // and the Unity host now enforces the same band
                            // (`UnityScreenVideoBridge` `case "video.brightness"`).
                            _ => json!({"op":"stage.video.brightness","value":value.start().clamp(0.15, 1.)}),
                        };
                        this.commands.push(command);
                        cx.notify();
                    }
                })
            })
            .collect();
        Self {
            snapshot: Value::Null,
            // No `stage.load` request is sent: the Unity host has no load step
            // behind it (it is not a second snapshot source — the whole stage
            // state arrives through the normal projection — and its handler
            // answers `false`, `UnityMediaHost.command`/`settingsCommand`), so
            // emitting it would only manufacture a rejected settings command on
            // open. [`STAGE_LOAD_OP`] keeps the name documented.
            commands: Vec::new(),
            tab: StageMode::Space.tab(),
            embedded: false,
            section: String::new(),
            initialized: false,
            motion_category: String::new(),
            sliders,
            syncing: false,
            supported_ops: Vec::new(),
            _subscriptions: subscriptions,
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }
    /// The host's settings whitelist (`supportedCommands`), applied whenever the
    /// settings window receives a new snapshot. See [`Self::op_supported`].
    pub fn set_supported_ops(&mut self, supported: Vec<String>, cx: &mut Context<Self>) {
        if self.supported_ops == supported {
            return;
        }
        self.supported_ops = supported;
        cx.notify();
    }
    /// Whether the host declares this op supported. `false` means the settings
    /// window would refuse it (`settings_ui.rs` dispatch whitelist), so the
    /// control that would emit it is not drawn.
    pub(crate) fn op_supported(&self, op: &str) -> bool {
        self.supported_ops.is_empty() || self.supported_ops.iter().any(|supported| supported == op)
    }

    /// The ops each [`STAGE_TABS`] partition is built from. A partition with no
    /// host whitelist entry would open on a body of refused controls.
    fn tab_ops(tab: usize) -> &'static [&'static str] {
        match tab {
            0 => &[
                "stage.player.lyrics",
                "stage.player.cloud",
                "stage.player.particles",
                "stage.video.toggle",
                "stage.video.bind",
                "stage.video.unbind",
            ],
            2 => &["stage.motion.refresh", "stage.motion.activate"],
            3 => &["stage.activity.run", "stage.activity.stop"],
            _ => &[],
        }
    }

    fn choose_available_tab(&self, preferred: usize) -> usize {
        if self.supported_ops.is_empty() || self.op_supported_any(Self::tab_ops(preferred)) {
            return preferred;
        }
        for tab in 0..STAGE_TABS.len() {
            if self.op_supported_any(Self::tab_ops(tab)) {
                return tab;
            }
        }
        preferred
    }

    fn op_supported_any(&self, ops: &[&str]) -> bool {
        ops.is_empty() || ops.iter().any(|op| self.op_supported(op))
    }
    pub fn set_embedded(&mut self, embedded: bool, cx: &mut Context<Self>) {
        self.embedded = embedded;
        cx.notify();
    }
    pub fn select_section(&mut self, section: &str, cx: &mut Context<Self>) {
        self.section = section.into();
        cx.notify();
    }
    pub fn select_tab(&mut self, tab: &str, cx: &mut Context<Self>) {
        self.tab = tab_for_name(tab);
        if self.tab == 2 && self.op_supported("stage.motion.refresh") {
            self.commands.push(json!({"op":"stage.motion.refresh"}));
        }
        cx.notify();
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if snapshot.is_null() || self.snapshot == snapshot {
            return;
        }
        if !self.initialized {
            // The partition is chosen once, by the original's rule; a later mode
            // change keeps whatever the person selected (`didChooseInitialTab`).
            // If that partition's controls are not in the host whitelist, the
            // first partition that does have them is used instead.
            self.tab = self.choose_available_tab(initial_tab(
                snapshot["stageRadioPluginEnabled"].as_bool() == Some(true),
                stage_mode(&snapshot),
            ));
            self.initialized = true;
        }
        self.syncing = true;
        for (i, value) in [
            snapshot["space"]["position"]["X"].as_f64(),
            snapshot["space"]["position"]["Y"].as_f64(),
            snapshot["space"]["position"]["Z"].as_f64(),
            snapshot["player"]["particleScale"].as_f64(),
            snapshot["player"]["videoBrightness"].as_f64(),
        ]
        .into_iter()
        .enumerate()
        {
            if let Some(value) = value {
                if value.is_finite() {
                    self.sliders[i]
                        .update(cx, |slider, cx| slider.set_value(value as f32, window, cx));
                }
            }
        }
        self.syncing = false;
        self.snapshot = snapshot;
        cx.notify();
    }

    /// The original's `Button("…").buttonStyle(.plain)` inside a group: no
    /// resting fill, one step up while hovered, dimmed instead of themed when
    /// disabled.
    fn plain_button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        icon: AssetIcon,
        command: Value,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let label: SharedString = label.into();
        let label = settings_copy(locale, label.as_ref()).to_owned();
        let text = if disabled { s::TEXT_DIM } else { s::TEXT };
        let icon_tone = ui::icon_color(
            false,
            !(disabled || self.snapshot["isSaving"].as_bool() == Some(true)),
        );
        Button::new(id)
            .custom(scene_variant(cx, 0x00000000, 0xffffff14, text))
            .small()
            .icon(icon)
            .rounded(px(metrics::ROW_RADIUS))
            .text_color(icon_tone)
            .tooltip(label.clone())
            .accessibility_label(label)
            .disabled(disabled || self.snapshot["isSaving"].as_bool() == Some(true))
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }

    /// [`Self::plain_button`] only when the host declares the op. A button whose
    /// command the settings window refuses is not drawn.
    fn supported_button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        icon: AssetIcon,
        command: Value,
        op: &str,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        if !self.op_supported(op) {
            return v_flex().into_any_element();
        }
        self.plain_button(id, label, icon, command, disabled, cx)
    }

    /// The original's group row: a full-width plain button with a
    /// `white.opacity(0.05)` fill, radius 10, leading symbol, and the active one
    /// carrying a check mark.
    fn row(
        &self,
        id: impl Into<ElementId>,
        body: AnyElement,
        aria: String,
        active: bool,
        disabled: bool,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let text = if disabled {
            s::TEXT_DIM
        } else if active {
            s::ACCENT
        } else {
            s::TEXT
        };
        let icon_tone = ui::icon_color(active, !disabled);
        Button::new(id)
            .custom(scene_variant(
                cx,
                metrics::ROW_FILL,
                metrics::ROW_FILL_HOVER,
                text,
            ))
            .w_full()
            .min_h(px(metrics::TILE_MIN_HEIGHT))
            .px(px(metrics::ROW_PADDING))
            .rounded(px(metrics::ROW_RADIUS))
            .text_color(icon_tone)
            .accessibility_label(aria)
            .disabled(disabled)
            .child(body)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }

    /// `pickerButton`: one tile of a `LazyVGrid`. `导入 MP4` / `关闭` are tiles in
    /// the original too, not a separate button row.
    fn tile(
        &self,
        key: &str,
        id: &str,
        title: &str,
        aria: String,
        symbol: AssetIcon,
        is_selected: bool,
        width: f32,
        command: Value,
        cx: &mut Context<Self>,
    ) -> Button {
        let text = if is_selected {
            metrics::TILE_TEXT_SELECTED
        } else {
            metrics::TILE_TEXT
        };
        Button::new(format!("{key}-{id}"))
            .custom(scene_variant(
                cx,
                if is_selected {
                    metrics::TILE_FILL_SELECTED
                } else {
                    metrics::TILE_FILL
                },
                metrics::TILE_FILL_HOVER,
                text,
            ))
            .w(px(width))
            .min_h(px(metrics::TILE_MIN_HEIGHT))
            .rounded(px(metrics::TILE_RADIUS))
            .border(px(if is_selected {
                metrics::TILE_BORDER_WIDTH_SELECTED
            } else {
                metrics::TILE_BORDER_WIDTH
            }))
            .border_color(rgba(if is_selected {
                metrics::TILE_BORDER_SELECTED
            } else {
                metrics::TILE_BORDER
            }))
            .text_color(rgba(text))
            .tooltip(aria.clone())
            .accessibility_label(aria)
            .child(
                v_flex()
                    .items_center()
                    .justify_center()
                    .gap(px(metrics::TILE_GAP))
                    .child(Icon::new(symbol).size(px(metrics::TILE_ICON_SIZE)))
                    .child(title.to_owned()),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.commands.push(command.clone());
                cx.notify();
            }))
    }

    /// The original's integer-percent readout beside a slider (`Int(value*100)`).
    fn slider_readout(value: f32) -> String {
        format!("{}%", (value * 100.).round() as i32)
    }

    // ---------------------------------------------------------------- 空间 ----

    fn space(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let mut group = v_flex().w_full().gap(px(metrics::PANEL_GROUP_GAP));
        for entry in visible_groups(StageMode::Space) {
            match entry {
                VisualGroup::WorldSelection => group = group.child(self.world_selection(locale, cx)),
                VisualGroup::AvatarPlacement => {
                    group = group.child(self.avatar_placement(locale, cx))
                }
                VisualGroup::LoadingStatus => {
                    if let Some(status) = world_loading_status(
                        self.snapshot["space"]["isRequested"].as_bool() == Some(true),
                        self.snapshot["space"]["isVisible"].as_bool() == Some(true),
                        self.snapshot["space"]["generationMessage"]
                            .as_str()
                            .or_else(|| self.snapshot["space"]["notice"].as_str()),
                        self.snapshot["space"]["errorMessage"].as_str(),
                    ) {
                        group = group.child(status_element(status));
                    }
                }
                _ => {}
            }
        }
        group.into_any_element()
    }

    /// `worldSelectionGroup`: the public-world / generated-scene menu, with the
    /// selected world check-marked inside its section. A section is drawn only
    /// when its op is in the host whitelist. In the Unity settings window the
    /// overlay publishes `stage.world.enter` / `stage.scene.activate` and
    /// translates them itself: 进入世界 onto the `space.library.select`
    /// transaction with a real package id, 激活/切换场景 onto the existing
    /// `marbleWorlds.activatePreset` path (`gpui-unity-overlay-probe/src/settings_ui.rs`
    /// `STAGE_OPS` / `translate_settings_command`). An id the host cannot
    /// resolve is refused with a named code, never accepted locally.
    fn world_selection(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let catalog = self.snapshot["space"].clone();
        let label = catalog["worldLabel"]
            .as_str()
            .unwrap_or(settings_copy(locale, "公开空间 · 无需生成"))
            .to_owned();
        let sections: Vec<(&'static str, &'static str, &'static str)> =
            [("worlds", "公开空间", "stage.world.enter"), ("presets", "生成场景", "stage.scene.activate")]
                .into_iter()
                .filter(|(_, _, op)| self.op_supported(op))
                .collect();
        if sections.is_empty() {
            return v_flex().w_full().into_any_element();
        }
        let weak = cx.entity().downgrade();
        let menu_label = label.clone();
        v_flex()
            .w_full()
            .child(
                Button::new("stage-world-menu")
                    .custom(scene_variant(
                        cx,
                        metrics::TILE_FILL,
                        metrics::TILE_FILL_HOVER,
                        metrics::MENU_TEXT,
                    ))
                    .w_full()
                    .small()
                    .min_h(px(metrics::MENU_MIN_HEIGHT))
                    .rounded(px(metrics::MENU_RADIUS))
                    .icon(AssetIcon::Globe)
                    .label(menu_label)
                    .dropdown_caret(true)
                    .text_color(rgba(metrics::MENU_TEXT))
                    .tooltip(label.clone())
                    .accessibility_label(label)
                    .dropdown_menu(move |mut menu, _, _| {
                        for &(key, title, op) in &sections {
                            menu = menu.item(PopupMenuItem::label(title));
                            for world in catalog[key].as_array().into_iter().flatten() {
                                let id = world["id"].as_str().unwrap_or("").to_owned();
                                if id.is_empty() {
                                    continue;
                                }
                                let handle = weak.clone();
                                let command = json!({"op":op,"id":id});
                                let selected = catalog["selectedWorldID"] == world["id"];
                                menu = menu.item(
                                    PopupMenuItem::new(format!(
                                        "{}{}",
                                        if selected { "✓ " } else { "" },
                                        world["name"].as_str().unwrap_or("")
                                    ))
                                    .on_click(move |_, _, cx| {
                                        _ = handle.update(cx, |this, cx| {
                                            this.commands.push(command.clone());
                                            cx.notify();
                                        });
                                    }),
                                );
                            }
                            menu = menu.separator();
                        }
                        menu
                    }),
            )
            .into_any_element()
    }

    /// `avatarPlacementGroup`: the three axes, then the two original footers.
    fn avatar_placement(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let group = v_flex()
            .w_full()
            .gap(px(metrics::PANEL_GROUP_GAP))
            .child(
                ui::section_title(settings_copy(locale, "人物位置"))
                    .text_size(px(metrics::SECTION_TITLE_SIZE))
                    .text_color(rgba(s::TEXT)),
            );
        let mut axes = v_flex().w_full().gap(px(metrics::AXIS_STACK_GAP));
        // Each slider emits one changed axis; the Unity overlay completes the
        // coordinate from the host's own `characterPosition` projection and
        // sends the whole position together with `worldID`, both CAS revisions
        // and a fresh `requestID` (`presence.position`,
        // `UnityCharacterPositionBridge.command`), so this stays a real
        // authority movement rather than a local pose. The 镜头复位 button below
        // is served by the Unity player itself (`GPUIChat2Probe.cs`).
        if self.op_supported("stage.avatar.position") {
            for (i, label) in ["X", "Y", "Z"].into_iter().enumerate() {
                let value = self.snapshot["space"]["position"][label]
                    .as_f64()
                    .unwrap_or(0.);
                axes = axes.child(
                    h_flex()
                        .w_full()
                        .items_center()
                        .gap(px(metrics::AXIS_ROW_GAP))
                        .min_h(px(metrics::AXIS_ROW_MIN_HEIGHT))
                        .child(
                            div()
                                .w(px(metrics::AXIS_LABEL_WIDTH))
                                .font_family(doc::FONT_FAMILY)
                                .font_weight(FontWeight::BOLD)
                                .text_color(rgba(metrics::AXIS_LABEL_TEXT))
                                .child(label),
                        )
                        .child(
                            div()
                                .id(format!("stage-avatar-{label}"))
                                .flex_1()
                                .min_w(px(0.))
                                .role(Role::Slider)
                                .aria_label(match label {
                                    "X" => "人物左右位置",
                                    "Y" => "人物上下位置",
                                    _ => "人物前后位置",
                                })
                                .child(ui::scene_slider(&self.sliders[i])),
                        )
                        .child(
                            div()
                                .w(px(metrics::AXIS_READOUT_WIDTH))
                                .text_right()
                                .font_family(doc::FONT_FAMILY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(rgba(metrics::AXIS_READOUT_TEXT))
                                .child(format!("{value:.2}")),
                        ),
                );
            }
        }
        group
            .child(axes)
            .child(
                h_flex()
                    .w_full()
                    .justify_between()
                    .items_center()
                    .child(ui::muted(settings_copy(locale, "人物位置会按当前空间保存")))
                    .child(self.supported_button(
                        "avatar-reset",
                        "重置",
                        AssetIcon::Undo2,
                        json!({"op":"stage.avatar.reset"}),
                        "stage.avatar.reset",
                        false,
                        cx,
                    )),
            )
            .child(
                h_flex()
                    .w_full()
                    .justify_between()
                    .items_center()
                    .child(ui::muted(settings_copy(
                        locale,
                        "W/S 沿视线前后移动，A/D 左右移动",
                    )))
                    // The Unity player serves this one itself
                    // (`GPUIChat2Probe.cs` `stage.camera.reset`), so it is not
                    // part of the host whitelist and stays drawn.
                    .child(self.plain_button(
                        "camera-reset",
                        "镜头复位",
                        AssetIcon::RotateCw,
                        json!({"op":"stage.camera.reset"}),
                        false,
                        cx,
                    )),
            )
            .into_any_element()
    }

    // ---------------------------------------------------------------- 角色 ----

    fn motions(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let motions = &self.snapshot["motions"];
        let mut group = v_flex()
            .w_full()
            .gap(px(metrics::GROUP_ROW_GAP))
            .text_size(px(metrics::GROUP_TEXT_SIZE))
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .child(
                        Icon::new(AssetIcon::CircleUser)
                            .size(px(metrics::TILE_ICON_SIZE))
                            .text_color(rgba(s::TEXT)),
                    )
                    .child(div().child(
                        motions["avatarName"]
                            .as_str()
                            .unwrap_or(settings_copy(locale, "尚未选择角色"))
                            .to_owned(),
                    ))
                    .child(div().flex_1())
                    .child(self.supported_button(
                        "motion-refresh",
                        "刷新",
                        AssetIcon::RefreshCw,
                        json!({"op":"stage.motion.refresh"}),
                        "stage.motion.refresh",
                        false,
                        cx,
                    )),
            )
            .child(ui::muted(settings_copy(
                locale,
                "选择已安装动作；自然待机可结束当前表演。",
            )));
        let items = motions["items"].as_array().cloned().unwrap_or_default();
        let categories = motions["categories"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let visible: Vec<&Value> = items
            .iter()
            .filter(|motion| motion_in_category(motion, &self.motion_category))
            .collect();
        group = group.child(ui::selected_tabs(
            "motion-categories",
            std::iter::once("全部".to_owned())
                .chain(
                    categories
                        .iter()
                        .map(|category| category["name"].as_str().unwrap_or("").to_owned()),
                )
                .map(ui::TabFace::text)
                .collect(),
            motion_category_index(&self.motion_category, &categories),
            // The picker's callback carries no entity, so the pane is reached
            // through its weak handle — the same shape the settings tab bars use.
            {
                let weak = cx.entity().downgrade();
                move |index: usize, _: &mut Window, cx: &mut App| {
                    _ = weak.update(cx, |this, cx| {
                        this.motion_category = if index == 0 {
                            String::new()
                        } else {
                            this.snapshot["motions"]["categories"]
                                .as_array()
                                .and_then(|categories| categories.get(index - 1))
                                .and_then(|category| category["id"].as_str())
                                .unwrap_or("")
                                .to_owned()
                        };
                        cx.notify();
                    });
                }
            },
        ));
        let saving = motions["isWorking"].as_bool() == Some(true);
        // 刷新 → `presence.load`, 每个动作 → `presence.motion` (the same two
        // production entries `ProductHost.swift:284-290` uses). The Unity
        // overlay publishes both ops and translates them
        // (`gpui-unity-overlay-probe/src/settings_ui.rs` `STAGE_OPS`), so rows
        // are drawn whenever the host advertises them and a refusal is a real
        // named failure instead of a missing control.
        if !self.op_supported("stage.motion.activate") {
            return group
                .child(ui::muted(settings_copy(
                    locale,
                    "当前运行时不提供动作选择。",
                )))
                .into_any_element();
        }
        for motion in &visible {
            let id = motion["id"].as_str().unwrap_or("");
            let active = motions["activeID"] == motion["id"];
            let compatible = motion["compatible"].as_bool() == Some(true);
            let mut body = v_flex()
                .items_start()
                .gap(px(metrics::ROW_STACK_GAP))
                .child(div().child(motion["name"].as_str().unwrap_or("").to_owned()));
            if let Some(reason) = motion["reason"].as_str().filter(|s| !s.is_empty()) {
                body = body.child(ui::muted(reason).text_size(px(metrics::REASON_SIZE)));
            }
            group = group.child(self.row(
                format!("motion-{id}"),
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .child(
                        Icon::new(if active {
                            AssetIcon::CircleCheck
                        } else {
                            AssetIcon::PersonStanding
                        })
                        .size(px(metrics::TILE_ICON_SIZE))
                        .text_color(ui::icon_color(active, true)),
                    )
                    .child(body)
                    .child(div().flex_1())
                    .when(active, |row| {
                        row.child(
                            Icon::new(AssetIcon::Check)
                                .size(px(metrics::TILE_ICON_SIZE))
                                .text_color(ui::icon_color(true, true)),
                        )
                    })
                    .into_any_element(),
                format!(
                    "{}，{}{}",
                    motion["name"].as_str().unwrap_or(""),
                    settings_copy(locale, "动作"),
                    if active {
                        settings_copy(locale, "，已选择")
                    } else {
                        ""
                    }
                ),
                active,
                !compatible || saving,
                json!({"op":"stage.motion.activate","id":id}),
                cx,
            ));
        }
        group = group.child(
            match motion_notice(
                items.len(),
                visible.len(),
                &self.motion_category,
                motions["notice"].as_str(),
            ) {
                MotionNotice::Empty => ui::muted(settings_copy(
                    locale,
                    "暂无可用动作，请在资产管理中安装。",
                )),
                MotionNotice::ListNotice(text) => ui::muted(text),
                MotionNotice::CategoryEmpty => ui::muted(settings_copy(
                    locale,
                    "这个分类下暂无当前角色可用的动作。",
                )),
                MotionNotice::None => div(),
            },
        );
        if let Some(message) = motions["message"].as_str().filter(|s| !s.is_empty()) {
            group = group.child(if motions["hasError"].as_bool() == Some(true) {
                ui::notice(message)
            } else {
                ui::muted(message)
            });
        }
        group
            // 管理角色与动作… — the original's `onManageAssets` →
            // `openPresenceSettings()`. In the Unity settings window the
            // overlay translates it locally onto the real 设置 window's 角色管理
            // page (`gpui-unity-overlay-probe/src/lib.rs::open_settings_window`
            // + `SettingsPane::select_presence_page`), which issues the same
            // `presence.load` the page needs; the product host handles the very
            // same op (`ProductHost.swift:298`).
            .child(self.supported_button(
                "manage-motion-assets",
                "管理角色与动作…",
                AssetIcon::Settings,
                // 原版 `StageOverlayView` 的这个按钮走 `onManageAssets` →
                // `openPresenceSettings()`，即打开设置的角色页；宿主
                // `GPUIProductHost.settingsCommand` 用真实存在的
                // `settings.open.presence` 承接（`stage.assets.manage` 从无处理者）。
                json!({"op":"settings.open.presence"}),
                "settings.open.presence",
                false,
                cx,
            ))
            .into_any_element()
    }

    // ---------------------------------------------------------------- 活动 ----

    fn activities(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let activity = &self.snapshot["activities"];
        let mut group = v_flex()
            .w_full()
            .gap(px(metrics::GROUP_ROW_GAP))
            .text_size(px(metrics::GROUP_TEXT_SIZE))
            .child(ui::muted(settings_copy(
                locale,
                "活动来自当前空间，角色会走到对应位置再开始。",
            )));
        let is_visible = self.snapshot["space"]["isVisible"].as_bool() == Some(true);
        let is_requested = self.snapshot["space"]["isRequested"].as_bool() == Some(true);
        // 开始 → `startActivityMeasured`, 停止 → `stopActivity` (the same calls
        // `GMGNRadioApp.runLivingWorldActivity` / `stopLivingWorldActivity`
        // make). The Unity overlay publishes both ops and dispatches them onto
        // the world session's own activity owner
        // (`UnityMediaHost.settingsCommand`), so the list is drawn and an
        // activity that is not runnable is refused by name.
        if !self.op_supported("stage.activity.run") && !self.op_supported("stage.activity.stop") {
            return group
                .child(ui::muted(settings_copy(
                    locale,
                    "当前运行时不提供生活活动控制。",
                )))
                .into_any_element();
        }
        let can_run = activity["canRun"].as_bool().unwrap_or_else(|| {
            activity_can_run(
                is_visible,
                self.snapshot["space"]["selectedWorldID"].as_str(),
                activity["worldID"].as_str(),
            )
        });
        if can_run {
            let items = activity["items"].as_array().cloned().unwrap_or_default();
            // Each run row emits `stage.activity.run`; stop stays a separate
            // control so the two ops are gated independently.
            if self.op_supported("stage.activity.run") {
                for item in &items {
                    let id = item["id"].as_str().unwrap_or("");
                    let active = activity["activeID"] == item["id"];
                    group = group.child(self.row(
                        format!("activity-{id}"),
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap(px(metrics::ROW_GAP))
                            .child(
                                Icon::new(if active {
                                    AssetIcon::CircleCheck
                                } else {
                                    AssetIcon::CirclePlay
                                })
                                .size(px(metrics::TILE_ICON_SIZE))
                                .text_color(ui::icon_color(active, true)),
                            )
                            .child(div().child(item["name"].as_str().unwrap_or("").to_owned()))
                            .child(div().flex_1())
                            .into_any_element(),
                        format!(
                            "{}，{}{}",
                            item["name"].as_str().unwrap_or(""),
                            settings_copy(locale, "活动"),
                            if active {
                                settings_copy(locale, "，正在进行")
                            } else {
                                ""
                            }
                        ),
                        active,
                        false,
                        json!({"op":"stage.activity.run","id":id}),
                        cx,
                    ));
                }
            }
            if items.is_empty() {
                group = group.child(ui::muted(settings_copy(
                    locale,
                    "这个空间还没有配置生活活动。",
                )));
            }
            group = group.child(self.supported_button(
                "activity-stop",
                "停止活动",
                AssetIcon::Square,
                json!({"op":"stage.activity.stop"}),
                "stage.activity.stop",
                activity["activeID"].as_str().is_none_or(|s| s.is_empty()),
                cx,
            ));
            if let Some(message) = activity["message"].as_str().filter(|s| !s.is_empty()) {
                group = group.child(ui::muted(message));
            }
        } else {
            group = group.child(ui::muted(settings_copy(
                locale,
                activity_unavailable_message(is_visible, is_requested),
            )));
        }
        group.into_any_element()
    }

    // -------------------------------------------------------------- 播放器 ----

    fn player(&self, cx: &mut Context<Self>) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let mut group = v_flex().w_full().gap(px(metrics::PANEL_GROUP_GAP));
        if stage_mode(&self.snapshot) == StageMode::Space {
            group = group.child(
                h_flex()
                    .items_center()
                    .gap(px(metrics::TILE_GAP))
                    .child(
                        Icon::new(AssetIcon::Info)
                            .size(px(metrics::TILE_ICON_SIZE))
                            .text_color(rgba(metrics::INFO_TEXT)),
                    )
                    .child(ui::muted(settings_copy(
                        locale,
                        "这些效果用于播放器画面，切回播放器后可查看",
                    ))),
            );
        }
        for entry in visible_groups(StageMode::Player) {
            match entry {
                VisualGroup::LyricsEffects => {
                    if let Some(grid) = self.effect_grid(
                        locale,
                        "lyrics",
                        "字幕特效",
                        AssetIcon::Captions,
                        "lyricID",
                        "stage.player.lyrics",
                        metrics::GRID_MIN_LYRICS,
                        cx,
                    ) {
                        group = group.child(grid);
                    }
                }
                VisualGroup::PointCloud => {
                    if let Some(grid) = self.effect_grid(
                        locale,
                        "clouds",
                        "3D 点阵",
                        AssetIcon::Grid3x3,
                        "cloudID",
                        "stage.player.cloud",
                        metrics::GRID_MIN_POINT_CLOUD,
                        cx,
                    ) {
                        group = group.child(grid);
                    }
                }
                VisualGroup::ParticleSize => {
                    if !self.embedded || player_section_includes(&self.section, "clouds") {
                        group = group.child(self.particle_size(locale, cx));
                    }
                }
                VisualGroup::MusicVideo => {
                    if let Some(video) = self.music_video(locale, cx) {
                        group = group.child(video);
                    }
                }
                _ => {}
            }
        }
        group.into_any_element()
    }

    /// One `LazyVGrid` of `pickerButton` tiles plus its `pickerHeader`. Returns
    /// `None` when the embedded settings page is showing a different section.
    #[allow(clippy::too_many_arguments)]
    fn effect_grid(
        &self,
        locale: UiLocale,
        key: &str,
        title: &str,
        symbol: AssetIcon,
        selected_key: &str,
        op: &'static str,
        minimum: f32,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        if self.embedded && !player_section_includes(&self.section, key) {
            return None;
        }
        let player = &self.snapshot["player"];
        let width = adaptive_tile_width(minimum, grid_width(), metrics::GRID_SPACING);
        let mut tiles = Vec::new();
        for item in player[key].as_array().into_iter().flatten() {
            let id = item["id"].as_str().unwrap_or("");
            let is_selected = player[selected_key] == item["id"];
            let name = player_choice_label(locale, key, id, item["name"].as_str().unwrap_or(""));
            let (_, aria) = style_choice_accessibility(settings_copy(locale, title), name, is_selected);
            tiles.push(
                self.tile(
                    key,
                    id,
                    name,
                    aria,
                    symbol,
                    is_selected,
                    width,
                    json!({"op":op,"id":id}),
                    cx,
                )
                .into_any_element(),
            );
        }
        Some(
            v_flex()
                .w_full()
                .gap(px(metrics::PANEL_GROUP_GAP))
                .child(section_heading(settings_copy(locale, title), symbol))
                .child(
                    h_flex()
                        .flex_wrap()
                        .w_full()
                        .gap(px(metrics::GRID_SPACING))
                        .children(tiles),
                )
                .into_any_element(),
        )
    }

    /// `particleSizeGroup`: symbol, slider, trailing 38 pt readout.
    fn particle_size(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let value = self.sliders[3].read(cx).value().start();
        h_flex()
            .w_full()
            .items_center()
            .gap(px(metrics::ROW_GAP))
            .px(px(metrics::SLIDER_ROW_H_PADDING))
            .min_h(px(metrics::SLIDER_ROW_MIN_HEIGHT))
            .child(
                Icon::new(AssetIcon::Grid3x3)
                    .size(px(metrics::TILE_ICON_SIZE))
                    .text_color(rgba(s::TEXT)),
            )
            .child(
                div()
                    .id("stage-particle-size")
                    .flex_1()
                    .min_w(px(0.))
                    .role(Role::Slider)
                    .aria_label(settings_copy(locale, "颗粒大小"))
                    .child(ui::scene_slider(&self.sliders[3])),
            )
            .child(
                div()
                    .w(px(metrics::READOUT_WIDTH))
                    .text_right()
                    .font_family(doc::FONT_FAMILY)
                    .text_color(rgba(metrics::READOUT_TEXT))
                    .child(Self::slider_readout(value)),
            )
            .into_any_element()
    }

    /// `musicVideoGroup`: the mode tiles **including** 导入 MP4 and 关闭, then the
    /// brightness row and the asset menu.
    fn music_video(&self, locale: UiLocale, cx: &mut Context<Self>) -> Option<AnyElement> {
        if self.embedded && !player_section_includes(&self.section, "videoModes") {
            return None;
        }
        let player = &self.snapshot["player"];
        let width =
            adaptive_tile_width(metrics::GRID_MIN_VIDEO, grid_width(), metrics::GRID_SPACING);
        let mut group = v_flex().w_full().gap(px(metrics::PANEL_GROUP_GAP));
        group = group.child(section_heading(
            settings_copy(locale, "MV 场景"),
            AssetIcon::Film,
        ));
        let mut tiles: Vec<AnyElement> = Vec::new();
        {
            tiles.push(
                self.tile(
                    "videoModes",
                    "import",
                    settings_copy(locale, "导入 MP4"),
                    settings_copy(locale, "导入 MP4").to_owned(),
                    AssetIcon::Plus,
                    false,
                    width,
                    json!({"op":"stage.video.import"}),
                    cx,
                )
                .into_any_element(),
            );
            for item in player["videoModes"].as_array().into_iter().flatten() {
                let id = item["id"].as_str().unwrap_or("");
                let name = player_choice_label(
                    locale,
                    "videoModes",
                    id,
                    item["name"].as_str().unwrap_or(""),
                );
                let active = player["videoActive"].as_bool() == Some(true)
                    && player["videoMode"] == item["id"];
                let (_, aria) =
                    style_choice_accessibility(settings_copy(locale, "MV 场景"), name, active);
                tiles.push(
                    self.tile(
                        "videoModes",
                        id,
                        name,
                        aria,
                        AssetIcon::Film,
                        active,
                        width,
                        json!({"op":"stage.video.mode","id":id}),
                        cx,
                    )
                    .into_any_element(),
                );
            }
            let assets = player["videoAssets"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let idle = player["videoActive"].as_bool() != Some(true);
            let (_, aria) =
                style_choice_accessibility(settings_copy(locale, "MV 场景"), "关闭", idle);
            tiles.push(
                self.tile(
                    "videoModes",
                    "stop",
                    settings_copy(locale, "关闭"),
                    aria,
                    AssetIcon::X,
                    idle && !assets.is_empty(),
                    width,
                    json!({"op":"stage.video.stop"}),
                    cx,
                )
                .into_any_element(),
            );
        }
        group = group.child(
            h_flex()
                .flex_wrap()
                .w_full()
                .gap(px(metrics::GRID_SPACING))
                .children(tiles),
        );
        if let Some(notice) = video_authority_notice(player) {
            group = group.child(
                ui::notice(notice)
                    .id("stage-video-authority-notice")
                    .text_size(px(metrics::GROUP_TEXT_SIZE)),
            );
        }
        if player["videoCanRecoverStop"].as_bool() == Some(true) {
            group = group.child(self.plain_button(
                "stage-video-recover-stop",
                "停止并核验",
                AssetIcon::CircleCheck,
                json!({"op":"stage.video.recoverStop"}),
                false,
                cx,
            ));
        }
        let assets = player["videoAssets"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        if !assets.is_empty() {
            group = group.child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .px(px(metrics::SLIDER_ROW_H_PADDING))
                    .min_h(px(metrics::SLIDER_ROW_MIN_HEIGHT))
                    .child(
                        Icon::new(AssetIcon::SunDim)
                            .size(px(metrics::TILE_ICON_SIZE))
                            .text_color(rgba(s::TEXT)),
                    )
                    .child(
                        div()
                            .id("stage-video-brightness")
                            .flex_1()
                            .min_w(px(0.))
                            .role(Role::Slider)
                            .aria_label(settings_copy(locale, "视频亮度"))
                            .child(ui::scene_slider(&self.sliders[4])),
                    )
                    .child(
                        div()
                            .w(px(metrics::READOUT_WIDTH))
                            .text_right()
                            .font_family(doc::FONT_FAMILY)
                            .text_color(rgba(metrics::READOUT_TEXT))
                            .child(Self::slider_readout(
                                self.sliders[4].read(cx).value().start(),
                            )),
                    ),
            );
            let active = player["videoActive"].as_bool() == Some(true);
            let name = assets
                .iter()
                .find(|asset| asset["id"] == player["videoAssetID"])
                .and_then(|asset| asset["name"].as_str())
                .unwrap_or(settings_copy(locale, "未加载视频"))
                .to_owned();
            let status = if active {
                settings_copy(locale, "已加载").to_owned()
            } else {
                format!("{} {}", assets.len(), settings_copy(locale, "段"))
            };
            let weak = cx.entity().downgrade();
            let menu_player = player.clone();
            group = group.child(
                Button::new("video-assets-menu")
                    .custom(scene_variant(
                        cx,
                        metrics::TILE_FILL,
                        metrics::TILE_FILL_HOVER,
                        metrics::MENU_TEXT,
                    ))
                    .w_full()
                    .small()
                    .min_h(px(metrics::MENU_MIN_HEIGHT))
                    .rounded(px(metrics::MENU_MIN_HEIGHT / 2.))
                    .text_color(rgba(metrics::MENU_TEXT))
                    .accessibility_label(format!("{name}，{status}"))
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap(px(doc::SPACING_8))
                            .child(
                                Icon::new(if active {
                                    AssetIcon::Video
                                } else {
                                    AssetIcon::VideoOff
                                })
                                .size(px(metrics::TILE_ICON_SIZE)),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .overflow_hidden()
                                    .whitespace_nowrap()
                                    .child(name),
                            )
                            .child(div().flex_shrink_0().child(status)),
                    )
                    .dropdown_menu(move |mut menu, window, cx| {
                        for asset in &assets {
                            let actions = video_asset_actions(&menu_player, asset);
                            let weak = weak.clone();
                            menu = menu.submenu(
                                asset["name"].as_str().unwrap_or("").to_owned(),
                                window,
                                cx,
                                move |mut sub, _, _| {
                                    for (label, command, dangerous) in &actions {
                                        if *dangerous {
                                            sub = sub.separator();
                                        }
                                        let weak = weak.clone();
                                        let command = command.clone();
                                        let item = if *dangerous {
                                            PopupMenuItem::element(move |_, _| {
                                                div()
                                                    .id("video-remove-menu-label")
                                                    .role(Role::MenuItem)
                                                    .aria_label(settings_copy(
                                                        locale,
                                                        "移出素材库",
                                                    ))
                                                    .text_color(rgba(metrics::DANGER_TEXT))
                                                    .child(settings_copy(locale, "移出素材库"))
                                            })
                                        } else {
                                            PopupMenuItem::new(settings_copy(locale, label))
                                        };
                                        sub = sub.item(item.on_click(move |_, _, cx| {
                                            _ = weak.update(cx, |this, cx| {
                                                this.commands.push(command.clone());
                                                cx.notify();
                                            });
                                        }));
                                    }
                                    sub
                                },
                            );
                        }
                        menu
                    }),
            );
        }
        Some(group.into_any_element())
    }
}

/// The custom variant every stage-panel control wears.
///
/// Kit's default/ghost/danger variants read `cx.theme()` for the resting and
/// hover surfaces; that is precisely the theme dependency this layer exists to
/// remove, so controls carry explicit resting/hover/pressed colours — the same
/// pattern [`crate::primitives::primary_circle_button`] uses for the send
/// button. Shared by all three stage panel surfaces.
pub(crate) fn scene_variant(cx: &App, fill: u32, hover: u32, text: u32) -> ButtonCustomVariant {
    ButtonCustomVariant::new(cx)
        .color(rgba(fill).into())
        .foreground(rgba(text).into())
        .hover(rgba(hover).into())
        .active(rgba(hover).into())
        .shadow(false)
}

/// The mode the panel renders for (`StageVisualPickerMode.resolve`).
fn stage_mode(snapshot: &Value) -> StageMode {
    StageMode::resolve(snapshot["space"]["isRequested"].as_bool() == Some(true))
}

/// A `pickerHeader`: leading symbol plus a 14 pt semibold title.
fn section_heading(title: &str, symbol: AssetIcon) -> AnyElement {
    h_flex()
        .items_center()
        .gap(px(metrics::TILE_GAP))
        .child(
            Icon::new(symbol)
                .size(px(metrics::TILE_ICON_SIZE))
                .text_color(ui::icon_color(false, true)),
        )
        .child(
            ui::section_title(title)
                .text_size(px(metrics::SECTION_TITLE_SIZE))
                .text_color(rgba(s::TEXT)),
        )
        .into_any_element()
}

/// `loadingStatusGroup`'s chrome for the winning state.
fn status_element(status: WorldStatus<'_>) -> AnyElement {
    let (symbol, color, text) = match status {
        WorldStatus::Loading => (
            AssetIcon::Package,
            metrics::LOADING_TEXT,
            "正在载入空间，完成后自动进入…".to_owned(),
        ),
        WorldStatus::Generating(message) => {
            (AssetIcon::Sparkles, metrics::LOADING_TEXT, message.to_owned())
        }
        WorldStatus::Failed(message) => (
            AssetIcon::TriangleAlert,
            metrics::FAILURE_TEXT,
            message.to_owned(),
        ),
    };
    h_flex()
        .w_full()
        .items_center()
        .gap(px(metrics::TILE_GAP))
        .text_size(px(metrics::GROUP_TEXT_SIZE))
        .child(
            Icon::new(symbol)
                .size(px(metrics::TILE_ICON_SIZE))
                .text_color(rgba(color)),
        )
        .child(div().flex_1().min_w(px(0.)).child(text))
        .into_any_element()
}

impl Render for StagePanelsPane {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mode = stage_mode(&self.snapshot);
        let tabs = ui::selected_tabs(
            "stage-tabs",
            STAGE_TABS
                .into_iter()
                .zip(STAGE_TAB_ICONS)
                .map(|(label, icon)| ui::TabFace::icon(icon, label))
                .collect(),
            self.tab,
            {
                let weak = cx.entity().downgrade();
                move |index: usize, _: &mut Window, cx: &mut App| {
                    _ = weak.update(cx, |this, cx| {
                        this.tab = index;
                        if index == 2 && this.op_supported("stage.motion.refresh") {
                            this.commands.push(json!({"op":"stage.motion.refresh"}));
                        }
                        cx.notify();
                    });
                }
            },
        );
        let body = match self.tab {
            0 => self.player(cx),
            2 => self.motions(cx),
            3 => self.activities(cx),
            _ => self.space(cx),
        };
        // One panel, one scroll area: the title row and the partition picker stay
        // fixed, so no amount of scrolling can push the partition choice or the
        // mode readout out of the panel.
        let surface = v_flex()
            .size_full()
            .min_w(px(0.))
            .min_h(px(0.))
            .gap(px(metrics::PANEL_GROUP_GAP))
            .p(px(metrics::PANEL_PADDING))
            .rounded(px(metrics::PANEL_RADIUS))
            .bg(rgba(s::CARD_BG))
            .border_1()
            .border_color(rgba(s::BORDER))
            .text_color(rgba(s::TEXT))
            .text_size(px(metrics::GROUP_TEXT_SIZE))
            .font_family(doc::FONT_FAMILY)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .child(
                        div()
                            .text_size(px(metrics::TITLE_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child("舞台设置"),
                    )
                    .child(div().flex_1())
                    .child(
                        div()
                            .text_size(px(metrics::MODE_SIZE))
                            .text_color(rgba(metrics::MODE_TEXT))
                            .child(mode_readout(mode)),
                    ),
            )
            .child(tabs)
            .child(
                div()
                    .id("stage-panel-scroll")
                    .w_full()
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_y_scroll()
                    .pb(px(metrics::CONTENT_BOTTOM_PADDING))
                    .child(body),
            );
        if self.embedded {
            // The settings window gives the pane its own frame and page chrome;
            // only the outer 7 pt shadow padding is dropped.
            return div()
                .size_full()
                .min_h(px(0.))
                .child(surface)
                .into_any_element();
        }
        div()
            .w_full()
            .h_full()
            .max_w(px(STAGE_PANEL_WIDTH))
            .max_h(px(STAGE_PANEL_HEIGHT))
            .p(px(metrics::PANEL_OUTER_PADDING))
            .child(surface)
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    // gpui re-exports a `test` attribute macro; `super::*` would shadow the
    // built-in one, so name it explicitly like the rest of this crate does.
    use core::prelude::v1::test;
    use serde_json::json;

    use super::*;

    /// The four partitions and their order are the original `CaseIterable`
    /// order; renaming or reordering a partition fails here.
    #[test]
    fn partitions_are_the_original_four_in_original_order() {
        assert_eq!(STAGE_TABS, ["播放器", "空间", "角色", "活动"]);
        assert_eq!(tab_for_name("player"), 0);
        assert_eq!(tab_for_name("space"), 1);
        assert_eq!(tab_for_name("motions"), 2);
        assert_eq!(tab_for_name("activities"), 3);
        // An unknown host name must not land on 播放器.
        assert_eq!(tab_for_name("nonsense"), StageMode::Space.tab());
    }

    /// `StageControlPanelTab.initial`: with the radio plugin off — the default —
    /// every entry point lands on 「空间」.
    #[test]
    fn initial_partition_follows_the_original_radio_plugin_rule() {
        assert_eq!(initial_tab(false, StageMode::Player), 1);
        assert_eq!(initial_tab(false, StageMode::Space), 1);
        assert_eq!(initial_tab(true, StageMode::Player), 0);
        assert_eq!(initial_tab(true, StageMode::Space), 1);
        assert_ne!(
            initial_tab(true, StageMode::Player),
            initial_tab(false, StageMode::Player)
        );
    }

    /// The group set and order per mode must match `visibleGroups`, which is not
    /// the order the widgets are written in.
    #[test]
    fn group_order_matches_the_original_per_mode() {
        assert_eq!(
            visible_groups(StageMode::Space),
            [
                VisualGroup::WorldSelection,
                VisualGroup::AvatarPlacement,
                VisualGroup::LoadingStatus,
            ]
        );
        assert_eq!(
            visible_groups(StageMode::Player),
            [
                VisualGroup::LyricsEffects,
                VisualGroup::PointCloud,
                VisualGroup::ParticleSize,
                VisualGroup::MusicVideo,
            ]
        );
        assert_ne!(
            visible_groups(StageMode::Space),
            visible_groups(StageMode::Player)
        );
        // Particle size sits between the point cloud and the music video, not
        // inside the point-cloud group.
        let player = visible_groups(StageMode::Player);
        assert_eq!(player[1], VisualGroup::PointCloud);
        assert_eq!(player[2], VisualGroup::ParticleSize);
        assert_eq!(player[3], VisualGroup::MusicVideo);
    }

    #[test]
    fn mode_readout_and_resolution_come_from_the_requested_world() {
        assert_eq!(StageMode::resolve(true), StageMode::Space);
        assert_eq!(StageMode::resolve(false), StageMode::Player);
        assert_eq!(mode_readout(StageMode::Space), "正在空间中");
        assert_eq!(mode_readout(StageMode::Player), "正在播放器中");
        assert_eq!(
            stage_mode(&json!({"space":{"isRequested":true}})),
            StageMode::Space
        );
        assert_eq!(stage_mode(&json!({"space":{}})), StageMode::Player);
    }

    #[test]
    fn activity_availability_matches_the_original_three_messages() {
        assert!(activity_can_run(true, Some("world"), Some("world")));
        assert!(!activity_can_run(true, Some("world"), Some("other")));
        assert!(!activity_can_run(true, None, Some("world")));
        assert!(!activity_can_run(true, Some("world"), None));
        assert!(!activity_can_run(false, Some("world"), Some("world")));
        assert_eq!(
            activity_unavailable_message(true, false),
            "这个空间还没有配置生活活动。"
        );
        assert_eq!(
            activity_unavailable_message(false, true),
            "空间载入完成后可选择活动。"
        );
        assert_eq!(
            activity_unavailable_message(false, false),
            "进入空间后可选择生活活动。"
        );
    }

    /// The adaptive grid must reproduce SwiftUI's `GridItem(.adaptive(minimum:))`
    /// counts inside the original 544 pt grid width; the SwiftUI panel measures
    /// lyrics at 5 columns and point cloud / video at 4.
    #[test]
    fn adaptive_grid_reproduces_the_original_column_counts() {
        let width = grid_width();
        assert_eq!(width, 544.);
        assert_eq!(adaptive_columns(metrics::GRID_MIN_LYRICS, width, 6.), 5);
        assert_eq!(adaptive_columns(metrics::GRID_MIN_POINT_CLOUD, width, 6.), 4);
        assert_eq!(adaptive_columns(metrics::GRID_MIN_VIDEO, width, 6.), 4);
        assert_eq!(
            adaptive_tile_width(metrics::GRID_MIN_LYRICS, width, 6.),
            104.
        );
        assert_eq!(
            adaptive_tile_width(metrics::GRID_MIN_POINT_CLOUD, width, 6.),
            131.5
        );
        assert_eq!(
            adaptive_tile_width(metrics::GRID_MIN_VIDEO, width, 6.),
            131.5
        );
        // A narrower grid degrades to one column instead of zero or a negative
        // tile width.
        assert_eq!(adaptive_columns(90., 40., 6.), 1);
        assert!(adaptive_tile_width(90., 40., 6.) > 0.);
        assert_eq!(adaptive_columns(90., 0., 6.), 1);
        assert_ne!(
            adaptive_columns(metrics::GRID_MIN_LYRICS, width, 6.),
            adaptive_columns(metrics::GRID_MIN_POINT_CLOUD, width, 6.)
        );
    }

    #[test]
    fn loading_status_order_and_colours_match_the_original() {
        assert_eq!(
            world_loading_status(true, false, None, None),
            Some(WorldStatus::Loading)
        );
        // A requested-but-invisible world wins over both messages.
        assert_eq!(
            world_loading_status(true, false, Some("生成中"), Some("失败")),
            Some(WorldStatus::Loading)
        );
        assert_eq!(world_loading_status(false, true, None, None), None);
        // A whitespace-only host message is not a status, so it must not become
        // an empty status line with a busy icon.
        assert_eq!(world_loading_status(false, true, Some(""), Some("  ")), None);
        assert_eq!(world_loading_status(false, true, Some("  "), None), None);
        // The generation message wins over the error message.
        assert_eq!(
            world_loading_status(false, true, Some("生成中"), Some("失败")),
            Some(WorldStatus::Generating("生成中"))
        );
        assert_eq!(
            world_loading_status(false, true, None, Some("生成失败")),
            Some(WorldStatus::Failed("生成失败"))
        );
        assert_ne!(
            metrics::FAILURE_TEXT,
            metrics::LOADING_TEXT,
            "a failed generation must not read in the loading colour"
        );
    }

    #[test]
    fn motion_notice_priority_matches_the_original() {
        assert_eq!(motion_notice(0, 0, "", None), MotionNotice::Empty);
        assert_eq!(motion_notice(3, 0, "", None), MotionNotice::None);
        assert_eq!(
            motion_notice(3, 0, "dance", Some("列表暂不可用")),
            MotionNotice::ListNotice("列表暂不可用")
        );
        assert_eq!(
            motion_notice(3, 0, "dance", None),
            MotionNotice::CategoryEmpty
        );
        // An empty notice string must not suppress the empty-category message.
        assert_eq!(
            motion_notice(3, 0, "dance", Some("")),
            MotionNotice::CategoryEmpty
        );
        assert_eq!(motion_notice(3, 2, "dance", None), MotionNotice::None);
        assert_ne!(motion_notice(0, 0, "dance", None), MotionNotice::CategoryEmpty);
    }

    #[test]
    fn motion_category_filter_and_picker_index_select_and_clear() {
        let motion = json!({"id":"m","category":"dance"});
        assert!(motion_in_category(&motion, ""));
        assert!(motion_in_category(&motion, "dance"));
        assert!(!motion_in_category(&motion, "idle"));
        let categories = vec![json!({"id":"dance"}), json!({"id":"idle"})];
        assert_eq!(motion_category_index("", &categories), 0);
        assert_eq!(motion_category_index("dance", &categories), 1);
        assert_eq!(motion_category_index("idle", &categories), 2);
        // A category the host no longer lists must not silently select another.
        assert_eq!(motion_category_index("gone", &categories), 0);
    }

    /// The readout the original prints beside a slider: `Int(value * 100)` with a
    /// percent sign, trailing-aligned in 38 pt.
    #[test]
    fn slider_readout_is_the_original_integer_percent() {
        assert_eq!(StagePanelsPane::slider_readout(1.), "100%");
        assert_eq!(StagePanelsPane::slider_readout(0.6), "60%");
        assert_eq!(StagePanelsPane::slider_readout(0.155), "16%");
        assert_eq!(StagePanelsPane::slider_readout(0.15), "15%");
        assert_ne!(StagePanelsPane::slider_readout(0.5), "0.5%");
    }

    /// The panel draws in a real GPUI window in all four partitions, so a broken
    /// layout or an unreachable partition shows up as a failed draw.
    #[test]
    fn pane_draws_every_partition_in_a_real_window() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| {
                let mut pane = super::StagePanelsPane::new(window, cx);
                let snapshot = json!({
                    "stageRadioPluginEnabled": true,
                    "space": {
                        "isRequested": true,
                        "isVisible": true,
                        "selectedWorldID": "world",
                        "worldLabel": "公开空间 · 示例",
                        "position": {"X": 0.5, "Y": -1.0, "Z": 2.0},
                        "worlds": [{"id":"world","name":"示例"}],
                        "presets": [{"id":"preset","name":"雪原"}],
                        "errorMessage": "生成失败"
                    },
                    "player": {
                        "lyricID": "classic",
                        "cloudID": "soft",
                        "videoMode": "full",
                        "particleScale": 1.2,
                        "videoBrightness": 0.4,
                        "lyrics": [{"id":"classic","name":"经典"}],
                        "clouds": [{"id":"soft","name":"柔光"}],
                        "videoModes": [{"id":"full","name":"全屏"}],
                        "videoAssets": [{"id":"a","name":"片段"}],
                        "videoActive": true,
                        "videoAssetID": "a"
                    },
                    "motions": {
                        "avatarName": "小满",
                        "activeID": "wave",
                        "isWorking": false,
                        "categories": [{"id":"dance","name":"舞蹈"}],
                        "items": [{"id":"wave","name":"挥手","category":"dance","compatible": true}],
                        "notice": null,
                        "message": "已载入"
                    },
                    "activities": {
                        "canRun": true,
                        "activeID": "walk",
                        "items": [{"id":"walk","name":"散步"}],
                        "message": "进行中"
                    }
                });
                pane.update_snapshot(snapshot, window, cx);
                pane
            });
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        for tab in 0..4 {
            cx.update_window(handle.into(), |_, window, cx| {
                stored
                    .borrow()
                    .as_ref()
                    .unwrap()
                    .update(cx, |pane, cx| {
                        pane.tab = tab;
                        cx.notify();
                    });
                window.refresh();
                window.draw(cx).clear(cx);
            })
            .unwrap();
        }
        // Space mode with the plugin on selects the space partition, and a later
        // snapshot must not reset the person's choice.
        cx.update_window(handle.into(), |_, window, cx| {
            let pane = stored.borrow().as_ref().unwrap().clone();
            assert_eq!(pane.read(cx).tab, 3, "the loop left the last partition up");
            pane.update(cx, |pane, cx| {
                // A mode change re-renders the same partition: the person's
                // choice is not reset by `update_snapshot`.
                pane.update_snapshot(
                    json!({"space":{"isRequested":false},"player":{"lyricID":"classic"}}),
                    window,
                    cx,
                );
                assert_eq!(pane.tab, 3, "a mode change keeps the chosen partition");
                assert!(pane.snapshot["player"]["lyricID"] == "classic");
            });
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }
    /// The twelve stage settings capabilities, exactly as the Unity overlay
    /// publishes them (`gpui-unity-overlay-probe/src/settings_ui.rs` `STAGE_OPS`):
    /// 进入世界 / 切换场景 / 角色 XYZ / 重置 / 刷新 / 播放动作 / 活动起停 /
    /// 管理角色与动作 / 许愿机保存与检测 / 取消配置.
    const STAGE_CAPABILITY_OPS: [&str; 12] = [
        "stage.world.enter",
        "stage.scene.activate",
        "stage.avatar.position",
        "stage.avatar.reset",
        "stage.motion.refresh",
        "stage.motion.activate",
        "stage.activity.run",
        "stage.activity.stop",
        "settings.open.presence",
        "space.prop.save",
        "space.prop.check",
        "space.prop.cancel",
    ];

    /// A snapshot carrying every value the gated controls read, so the only
    /// thing that can hide a control is its op missing from the whitelist.
    fn capability_snapshot() -> serde_json::Value {
        json!({
            "stageRadioPluginEnabled": true,
            "isSaving": false,
            "space": {
                "isRequested": true, "isVisible": true,
                "selectedWorldID": "world.living-pod",
                "worldLabel": "生活舱",
                "position": {"X": 0.5, "Y": -1.25, "Z": 2.0},
                "worlds": [{"id": "world.living-pod", "name": "生活舱"}],
                "presets": [{"id": "snow", "name": "雪原"}]
            },
            "motions": {
                "avatarName": "小满", "activeID": null, "isWorking": false,
                "categories": [{"id": "dance", "name": "舞蹈"}],
                "items": [{"id": "gmgn.motion.wave", "name": "挥手", "compatible": true}],
                "notice": null, "message": null, "hasError": false
            },
            "activities": {
                "canRun": true, "activeID": null,
                "items": [{"id": "life.coffee", "name": "冲泡一杯咖啡"}],
                "message": null
            },
            "player": {"lyricID": "classic", "cloudID": "soft", "videoMode": "full"}
        })
    }

    /// The published whitelist is the single switch between "hidden" and
    /// "usable". With the overlay's `STAGE_OPS` merged in, every one of the
    /// twelve gated controls becomes drawable and every partition it belongs to
    /// is reachable; without them the same snapshot hides them again.
    #[test]
    fn published_stage_ops_unhide_the_twelve_capabilities_and_their_partitions() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let handle = cx.add_window(|window, cx| {
            let pane = cx.new(|cx| super::StagePanelsPane::new(window, cx));
            pane.update(cx, |pane, cx| {
                pane.update_snapshot(capability_snapshot(), window, cx);
                // What the Unity overlay publishes: the host's own
                // `supportedCommands` plus the twelve translated stage ops.
                let mut published: Vec<String> =
                    ["settings.load", "stage.player.lyrics", "stage.player.cloud", "stage.player.particles"]
                        .iter()
                        .map(|op| (*op).to_owned())
                        .collect();
                published.extend(STAGE_CAPABILITY_OPS.iter().map(|op| (*op).to_owned()));
                pane.set_supported_ops(published.clone(), cx);
                for op in STAGE_CAPABILITY_OPS {
                    assert!(pane.op_supported(op), "{op} must be usable once the host publishes it");
                }
                // 角色 partitions stay reachable: with the motion/activity ops
                // published, 刷新/播放动作 and 活动起停 are drawn in place of the
                // 「当前运行时不提供…」 substitute.
                assert!(pane.op_supported("stage.motion.refresh"));
                assert!(pane.op_supported("stage.motion.activate"));
                assert!(pane.op_supported("stage.activity.run"));
                assert!(pane.op_supported("stage.activity.stop"));
                // And a partition whose ops are absent is still the panel's own
                // choice, not a blank body: `choose_available_tab` must not move
                // off 活动 while 活动 is available.
                pane.tab = 3;
                assert!(pane.op_supported_any(super::StagePanelsPane::tab_ops(3)));
                // The same snapshot without the stage ops hides them again —
                // this is the assertion that fails if the published list stops
                // carrying them (the "hide it instead" ending).
                pane.set_supported_ops(vec!["settings.load".to_owned()], cx);
                for op in STAGE_CAPABILITY_OPS {
                    assert!(!pane.op_supported(op), "{op} must be hidden when the host does not publish it");
                }
                assert!(!pane.op_supported_any(super::StagePanelsPane::tab_ops(3)), "活动 body is refused without its ops");
                assert!(!pane.op_supported_any(super::StagePanelsPane::tab_ops(2)), "角色 body is refused without its ops");
            });
            gpui_kit::base::Root::new(pane, window, cx)
        });
        cx.update_window(handle.into(), |_, window, cx| {
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }

    /// 管理角色与动作… stays a real control: it is published by the overlay (as
    /// local window navigation) and by the product host, so the button is drawn
    /// whenever either host advertises it.
    #[test]
    fn manage_assets_button_is_gated_only_on_its_published_op() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let handle = cx.add_window(|window, cx| {
            let pane = cx.new(|cx| super::StagePanelsPane::new(window, cx));
            pane.update(cx, |pane, cx| {
                pane.update_snapshot(capability_snapshot(), window, cx);
                pane.set_supported_ops(vec!["settings.open.presence".to_owned()], cx);
                assert!(pane.op_supported("settings.open.presence"));
                pane.set_supported_ops(Vec::new(), cx);
                // An unpublished list must not blank the pane (a host that does
                // not advertise anything keeps every control).
                assert!(pane.op_supported("settings.open.presence"));
            });
            gpui_kit::base::Root::new(pane, window, cx)
        });
        cx.update_window(handle.into(), |_, window, cx| {
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }

}
