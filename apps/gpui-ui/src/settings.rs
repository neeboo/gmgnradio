//! The system settings surface: the five-page window from
//! `apps/macos/Sources/GMGNRadio/Settings/GMGNSettingsView.swift` (角色／音乐／
//! 空间／快捷键／DJ) rebuilt on gpui-kit.
//!
//! Shape of the surface, and why it is split this way:
//!
//! - [`AgentSettingsPane`] owns the host snapshot, the draft, the input
//!   entities and the command queue. Commands (`settings.load`,
//!   `presence.*`, `music.*`, `space.*`, `shortcuts.*`, `agent.*`, `tts.*`,
//!   `asr.*`, `video.*`) keep their exact op names, field names and state
//!   machine semantics; this rewrite only changes presentation.
//! - The **product window** (`unity_external == false`) renders the original
//!   chrome: a 330 pt five-segment picker at the very top (14 pt above, 8 pt
//!   below), the page header from the original Swift page (`padding 18`, or 14
//!   on the Agent page), **one** scrolling content area, and the page's notice
//!   pinned under it. Window/tabs/notice never scroll with the content.
//! - The **Unity settings window** (`unity_external == true`) keeps the
//!   category sidebar the Unity host navigates with; it shares the same page
//!   bodies so a section filters groups instead of duplicating them.
//! - Pure decisions live in free functions ([`settings_tabs`],
//!   [`page_index_for_key`], [`tab_index_for_page`], [`presence_action`],
//!   [`music_status_label`], [`generation_check_enabled`],
//!   [`shortcut_validation`], …) so the renderer and the tests share one
//!   answer instead of each re-deriving it.
//! - Chrome and type come from [`crate::primitives`] and
//!   [`crate::ui_tokens`]; this file contains no `rgb()`/`rgba()` literal and no
//!   bare font size. The original readings that have no shared role live in
//!   [`crate::ui_tokens::settings`], each with its Swift source line.
//!
//! ## Where the metrics live
//!
//! The surface-level readouts were moved from a local `metrics` module into
//! [`crate::ui_tokens::settings`] on 2026-10-08: `ui_tokens` is the one place a
//! surface keeps its numbers, and the module alias below keeps every call site
//! reading the same names it always did.
//!
//! ## Accessibility
//!
//! The original Swift settings views carry no `accessibilityIdentifier` (only
//! the stage surfaces do), so this layer defines the `settings.*` identifier
//! scheme: `settings.tabs`, `settings.content`, `settings.<page>.…`. Labels
//! stay the original Chinese copy.

use crate::i18n::{
    UiLocale, language_command, settings_copy, settings_navigation_label, settings_notice,
};
use crate::primitives as ui;
use crate::ui_tokens as tokens;
use crate::ui_tokens::scene as s;
use gpui_kit::assets::IconName;
use gpui_kit::component::input::InputEvent;
use gpui_kit::component::tab::{Tab, TabBar};
use gpui_kit::component::{
    collapsible::Collapsible,
    color_picker::{ColorPicker, ColorPickerEvent, ColorPickerState},
    button::*,
    input::*,
    menu::*,
    slider::{Slider, SliderEvent, SliderState},
    spinner::Spinner,
    switch::Switch,
    *,
};
use gpui_kit::prelude::{FluentBuilder, InteractiveElement as _};
use gpui_kit::*;
use serde_json::{Value, json};

// ---------------------------------------------------------------------------
// Original metrics
// ---------------------------------------------------------------------------

/// The settings surface's readouts now live in [`crate::ui_tokens::settings`]
/// (window/segment sizes plus every per-row reading). They were moved there
/// verbatim on 2026-10-08 so the surface has **one** metrics copy; the alias
/// below is the same module the constants used to sit in.
use crate::ui_tokens::settings as metrics;

/// Page indices. They are part of the host contract (`select_page` keys) and
/// must not be renumbered.
pub const PAGE_PRESENCE: usize = 0;
pub const PAGE_MUSIC: usize = 1;
pub const PAGE_SPACE_PREFS: usize = 2;
pub const PAGE_SHORTCUTS: usize = 3;
pub const PAGE_AGENT: usize = 4;
pub const PAGE_PLAYER: usize = 5;
pub const PAGE_SPACE: usize = 6;
pub const PAGE_ACTIVITIES: usize = 7;

// ---------------------------------------------------------------------------
// Pure decisions
// ---------------------------------------------------------------------------

/// One segment of the original five-page picker (`GMGNSettingsPage`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SettingsTab {
    /// The `select_page` key that activates this tab.
    pub key: &'static str,
    /// The original Chinese label (`GMGNSettingsPage.rawValue`).
    pub label: &'static str,
    /// The page the tab selects.
    pub page: usize,
}

/// One icon per [`settings_tabs`] entry, keyed by the tab's `select_page` key.
///
/// The five-segment page picker is a control, and controls in this layer are
/// icon-only: the page names live in the tab's accessibility label and tooltip.
/// `music` and `shortcuts` have no glyph in gpui-kit's default component bundle;
/// the app registers the full catalog (`gpui_kit::assets::AllAssets`), which
/// embeds them, and the packaging test records them in its reviewed allow-list.
fn settings_tab_icon(key: &str) -> IconName {
    match key {
        "presence" => IconName::CircleUser,
        "music" => IconName::Music,
        "space-preferences" => IconName::Globe,
        "shortcuts" => IconName::Keyboard,
        "agent" => IconName::Settings2,
        _ => IconName::Settings,
    }
}

/// The original tab set and order: 角色／音乐／空间／快捷键／DJ
/// (`GMGNSettingsView.swift:3-9`).
pub fn settings_tabs() -> [SettingsTab; 5] {
    [
        SettingsTab {
            key: "presence",
            label: "角色",
            page: PAGE_PRESENCE,
        },
        SettingsTab {
            key: "music",
            label: "音乐",
            page: PAGE_MUSIC,
        },
        SettingsTab {
            key: "space-preferences",
            label: "空间",
            page: PAGE_SPACE_PREFS,
        },
        SettingsTab {
            key: "shortcuts",
            label: "快捷键",
            page: PAGE_SHORTCUTS,
        },
        SettingsTab {
            key: "agent",
            label: "DJ",
            page: PAGE_AGENT,
        },
    ]
}

/// The page a `select_page` key resolves to. This is the original host mapping
/// and must stay stable.
pub fn page_index_for_key(key: &str) -> usize {
    match key {
        "music" => PAGE_MUSIC,
        "space-preferences" => PAGE_SPACE_PREFS,
        "shortcuts" => PAGE_SHORTCUTS,
        "agent" | "dj" => PAGE_AGENT,
        "player" => PAGE_PLAYER,
        "space" => PAGE_SPACE,
        "activities" => PAGE_ACTIVITIES,
        _ => PAGE_PRESENCE,
    }
}

/// Which of the five segments is active for a page, or `None` for the stage
/// pages that have no home in the original system settings.
pub fn tab_index_for_page(page: usize) -> Option<usize> {
    match page {
        PAGE_PRESENCE => Some(0),
        PAGE_MUSIC => Some(1),
        // Both space entries render the original 空间 page.
        PAGE_SPACE_PREFS | PAGE_SPACE => Some(2),
        PAGE_SHORTCUTS => Some(3),
        PAGE_AGENT => Some(4),
        _ => None,
    }
}

/// Whether a page belongs to the original five-tab system settings window.
pub fn system_settings_page(page: usize) -> bool {
    page <= PAGE_AGENT
}

/// The snapshot section whose `notice`/`hasError` the page footer shows, or
/// `None` when the page renders its own validation inline (shortcuts) — the
/// original keeps the recorder message inside the form.
pub fn page_notice_section(page: usize) -> Option<&'static str> {
    match page {
        PAGE_PRESENCE => Some("presence"),
        PAGE_MUSIC => Some("music"),
        PAGE_SPACE_PREFS | PAGE_SPACE => Some("space"),
        PAGE_AGENT => Some("agent"),
        PAGE_SHORTCUTS => None,
        _ => Some("stage"),
    }
}

/// The original page header (title, subtitle). Subtitle copy is shared with the
/// catalog; titles that are navigation routes are translated through it too.
pub fn page_header_routes(page: usize) -> (&'static str, &'static str) {
    match page {
        PAGE_PRESENCE => ("角色与动作", "选择角色的形象与表演动作"),
        PAGE_MUSIC => ("音乐", "角色可以使用的账号"),
        PAGE_SPACE_PREFS | PAGE_SPACE => ("空间", "选择默认空间，并管理空间生成服务"),
        PAGE_SHORTCUTS => ("快捷键", "点击按键框，再按下新的组合键"),
        PAGE_AGENT => ("Agent 与语音", "文字和语音共用同一会话，回答后再朗读"),
        PAGE_PLAYER => ("播放器", "字幕、3D 点阵与视频效果"),
        _ => ("活动", "选择与控制空间生活活动"),
    }
}

/// `AgentSettingsView.swift:470-471` tightens the header to 14 pt; the other
/// pages use 18.
pub fn header_vertical_padding(page: usize) -> f32 {
    if page == PAGE_AGENT {
        metrics::AGENT_HEADER_PADDING_V
    } else {
        metrics::HEADER_PADDING_V
    }
}

/// Original section picker of the embedded stage pages. A single section needs
/// no picker (the pane owns its scroll and its own layout).
pub fn stage_sections(page: usize) -> &'static [&'static str] {
    match page {
        PAGE_PLAYER => &["歌词", "视觉效果", "视频"],
        PAGE_SPACE => &["我的空间"],
        _ => &["活动"],
    }
}

/// The `select_page` key for an embedded stage page.
pub fn stage_page_key(page: usize) -> &'static str {
    match page {
        PAGE_SPACE => "space",
        PAGE_ACTIVITIES => "activities",
        _ => "player",
    }
}

/// What the presence row offers: the active character, a renderer that is not
/// ready, or the select action (`PresenceSettingsView.swift:278-289`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PresenceAction {
    Active,
    Waiting,
    Select,
}

pub fn presence_action(is_active: bool, renderer_available: bool) -> PresenceAction {
    if is_active {
        PresenceAction::Active
    } else if !renderer_available {
        PresenceAction::Waiting
    } else {
        PresenceAction::Select
    }
}

/// What the motion row offers (`PresenceSettingsView.swift:355-363`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MotionAction {
    Current,
    Select { enabled: bool },
}

pub fn motion_action(is_active: bool, compatible: bool) -> MotionAction {
    if is_active && compatible {
        MotionAction::Current
    } else {
        MotionAction::Select {
            enabled: compatible,
        }
    }
}

/// The six authorization states of `MusicAccountsModel`
/// (`MusicAccountsView.swift:137-152`). Callers translate the result.
pub fn music_status_label(status: Option<&str>) -> &'static str {
    match status {
        Some("connected") => "已连接",
        Some("authorizing") => "正在连接",
        Some("expired") => "登录已过期",
        Some("denied") => "未授权",
        Some("unavailable") => "当前不可用",
        _ => "未连接",
    }
}

/// `MusicAccountRow` swaps the buttons for a spinner while authorizing.
pub fn music_row_authorizing(status: Option<&str>) -> bool {
    status == Some("authorizing")
}

/// The original shows either 断开 or 连接 depending on the stored state.
pub fn music_connect_label(connected: bool) -> &'static str {
    if connected { "断开" } else { "连接" }
}

/// `PresenceSettingsView.swift:123`: `Int(flowIntensity * 100)`.
pub fn orb_intensity_percent(value: f32) -> u32 {
    (value * 100.).round().clamp(0., 999.) as u32
}

/// A model is selectable only while the Rust capabilities list contains it
/// (`AgentSettingsView.swift:133-136`).
pub fn model_in_catalog(models: &[Value], model_id: &Value) -> bool {
    models.iter().any(|model| model["id"] == *model_id)
}

/// `AgentSettingsView.swift:69`: preview needs a voice and a supported model.
pub fn tts_preview_enabled(valid_model: bool, voice_id: &str) -> bool {
    valid_model && !voice_id.trim().is_empty()
}

/// `AgentSettingsView.swift:113`: 保存配置 disabled while the model is
/// unsupported.
pub fn tts_save_enabled(valid_model: bool) -> bool {
    valid_model
}

/// `AgentSettingsView.swift:936`-equivalent for the ASR half.
pub fn asr_save_enabled(valid_model: bool) -> bool {
    valid_model
}

/// `GMGNSettingsView.swift:224-230`: 保存 Key needs a replacement value.
pub fn marble_save_enabled(replacement_key: &str) -> bool {
    !replacement_key.trim().is_empty()
}

/// `PropGenerationSettingsSection.swift:48`: 保存 needs an endpoint.
pub fn prop_save_enabled(endpoint: &str) -> bool {
    !endpoint.trim().is_empty()
}

/// `PropGenerationSettingsSection.swift:45`: 检测连接 disabled unless configured,
/// idle and not holding a replacement key.
pub fn prop_check_enabled(configured: bool, checking: bool, replacement_key_empty: bool) -> bool {
    configured && !checking && replacement_key_empty
}

/// The same rule for the Wish-machine section (`settings.rs` v51 transport).
pub fn generation_check_enabled(
    configured: bool,
    checking: bool,
    replacement_key_empty: bool,
) -> bool {
    configured && !checking && replacement_key_empty
}

/// 保存 stays disabled while a check runs or the endpoint is empty.
pub fn generation_save_enabled(endpoint: &str, checking: bool) -> bool {
    !checking && !endpoint.trim().is_empty()
}

/// `PresenceSettingsView.swift:215`: the import menu is disabled while the
/// presence model is working.
pub fn import_menu_enabled(working: bool) -> bool {
    !working
}

/// `GMGNKeyboardShortcuts.swift:719-731`: what a key cell shows.
pub fn shortcut_cell_label(recording: bool, display: &str) -> String {
    if recording {
        "请按快捷键".to_owned()
    } else if display.trim().is_empty() {
        "未设置".to_owned()
    } else {
        display.to_owned()
    }
}

/// `GMGNKeyboardShortcuts.swift:747-767`: the recorder's validation copy, in
/// the original order. `None` accepts the combination.
pub fn shortcut_validation(
    scope: &str,
    combination_valid: bool,
    has_modifiers: bool,
) -> Option<&'static str> {
    if !combination_valid {
        return Some(metrics::SHORTCUT_INCOMPLETE);
    }
    if scope == "global" && !has_modifiers {
        return Some("全局快捷键至少需要一个修饰键。");
    }
    None
}

// ---------------------------------------------------------------------------
// Existing display helpers (kept; they are pinned by the display tests)
// ---------------------------------------------------------------------------

// macOS virtual key codes used by the original shortcut authority. GPUI lives
// in another process, so key recording must cross the settings transport.
fn shortcut_capture_command(key: &str, modifiers: u64) -> Option<Value> {
    let key = key.to_ascii_lowercase();
    if key == "escape" {
        return Some(json!({"op":"shortcuts.cancel"}));
    }
    let (code, label) = match key.as_str() {
        "space" => (49, "Space".to_owned()),
        "left" => (123, "←".to_owned()),
        "right" => (124, "→".to_owned()),
        "down" => (125, "↓".to_owned()),
        "up" => (126, "↑".to_owned()),
        "enter" => (36, "Return".to_owned()),
        "tab" => (48, "Tab".to_owned()),
        "backspace" => (51, "Delete".to_owned()),
        other => {
            let codes = [
                ("a", 0),
                ("s", 1),
                ("d", 2),
                ("f", 3),
                ("h", 4),
                ("g", 5),
                ("z", 6),
                ("x", 7),
                ("c", 8),
                ("v", 9),
                ("b", 11),
                ("q", 12),
                ("w", 13),
                ("e", 14),
                ("r", 15),
                ("y", 16),
                ("t", 17),
                ("1", 18),
                ("2", 19),
                ("3", 20),
                ("4", 21),
                ("6", 22),
                ("5", 23),
                ("=", 24),
                ("9", 25),
                ("7", 26),
                ("-", 27),
                ("8", 28),
                ("0", 29),
                ("]", 30),
                ("o", 31),
                ("u", 32),
                ("[", 33),
                ("i", 34),
                ("p", 35),
                ("l", 37),
                ("j", 38),
                ("'", 39),
                ("k", 40),
                (";", 41),
                ("\\", 42),
                (",", 43),
                ("/", 44),
                ("n", 45),
                ("m", 46),
                (".", 47),
                ("`", 50),
                ("f1", 122),
                ("f2", 120),
                ("f3", 99),
                ("f4", 118),
                ("f5", 96),
                ("f6", 97),
                ("f7", 98),
                ("f8", 100),
                ("f9", 101),
                ("f10", 109),
                ("f11", 103),
                ("f12", 111),
            ];
            let (_, code) = codes.iter().find(|(name, _)| *name == other)?;
            (*code, other.to_uppercase())
        }
    };
    Some(json!({"op":"shortcuts.capture","keyCode":code,"keyLabel":label,"modifiers":modifiers}))
}

fn avatar_detail(package: &Value) -> String {
    if let Some(detail) = package["displayDetail"].as_str() {
        return detail.to_owned();
    }
    let engine = match package["engine"].as_str() {
        Some("orb") => "呼吸球",
        Some("pmx") => "PMX",
        Some("vrm") => "VRM",
        Some("live2D" | "live2d") => "Live2D",
        _ => "",
    };
    if package["isBuiltIn"].as_bool() == Some(true) {
        format!("内置 · {engine}")
    } else {
        package["detail"].as_str().unwrap_or("").replacen(
            package["engine"].as_str().unwrap_or(""),
            engine,
            1,
        )
    }
}

fn motion_format(value: &str) -> &str {
    match value {
        "procedural" => "内置动态",
        "vmd" => "VMD",
        "bvh" => "BVH",
        "vrma" => "VRMA",
        "bones" => "Bones",
        other => other,
    }
}

fn tts_draft_change_requires_stop(
    section: &str,
    field: &str,
    previous: &Value,
    current: &Value,
) -> bool {
    section == "tts" && matches!(field, "voiceID" | "modelID") && previous != current
}

fn save_ack_clear(revision: u64, ack: u64, submitted: &str, current: &str) -> bool {
    ack > revision && submitted == current
}

fn presence_more_accessibility(action: &str, name: &str) -> (Role, String) {
    (
        Role::Button,
        format!("{}「{name}」的更多操作", action.trim_start_matches("移除")),
    )
}

fn music_sync_command(provider: &Value, working: bool) -> Option<Value> {
    if working
        || provider["syncing"].as_bool() == Some(true)
        || provider["connected"].as_bool() != Some(true)
    {
        return None;
    }
    Some(json!({"op":"music.sync","id":provider["id"]}))
}

fn unity_section_available(snapshot: &Value, section: &str) -> bool {
    snapshot["unity"]["availableSections"]
        .as_array()
        .is_some_and(|sections| {
            sections
                .iter()
                .any(|value| value.as_str() == Some(section))
        })
}

fn unity_agent_group_available(snapshot: &Value, title: &str) -> bool {
    snapshot["unity"]["availableAgentGroups"]
        .as_array()
        .is_some_and(|groups| groups.iter().any(|value| value.as_str() == Some(title)))
}

/// Whether the 我的空间 world library can render at all.
///
/// The list is the Unity host's living-world packages
/// (`apps/macos/UnityHost/UnitySpaceLibraryBridge.swift:104-105`, published as
/// `settings["spaceLibrary"]` by `UnityMediaHost.swift:1538`). The GPUI product
/// snapshot (`ProductHost/ProductSettingsParity.swift:60-133`) does **not**
/// publish `spaceLibrary` — the native renderer has one space, not a package
/// library — and the original product settings page
/// (`GMGNSettingsView.swift:19`) has only 默认空间 / Marble 空间. So the section
/// is shown exactly when the host published a library; in product mode the
/// 刷新 (`space.library.load`) and world rows (`space.library.select`) are not
/// rendered instead of being visible and guaranteed to fail.
pub fn space_library_available(snapshot: &Value) -> bool {
    !snapshot["spaceLibrary"].is_null()
}

/// The complete render condition of the 我的空间 world library, so the decision
/// lives in one place the tests can drive: the host must have published a
/// library **and** the section's own visibility rules must allow it. In product
/// mode (`unity_external == false`) the first term is the only one that matters.
pub fn space_library_visible(
    snapshot: &Value,
    unity_external: bool,
    space_entry: bool,
    group_visible: bool,
) -> bool {
    space_library_available(snapshot) && (!unity_external || space_entry) && group_visible
}

fn marble_command(library: &Value, op: &str, value: &str) -> Option<Value> {
    let working = library["marbleWorking"].as_bool() == Some(true);
    let pending = library["marbleOperationID"]
        .as_str()
        .is_some_and(|id| !id.is_empty());
    if op == "space.marble.cancel" {
        return working.then(|| json!({"op": op}));
    }
    if library["generationSupported"].as_bool() != Some(true) || working {
        return None;
    }
    match op {
        "space.marble.generate"
            if !pending
                && library["marblePresets"].as_array().is_some_and(|presets| {
                    presets
                        .iter()
                        .any(|preset| preset["id"].as_str() == Some(value))
                }) =>
        {
            Some(json!({"op": op, "presetID": value}))
        }
        "space.marble.resume" if pending => Some(json!({"op": op})),
        "space.marble.import" if !pending && !value.trim().is_empty() => {
            Some(json!({"op": op, "worldID": value.trim()}))
        }
        _ => None,
    }
}

fn marble_phase_label(phase: &str) -> &'static str {
    match phase {
        "generating" => "正在生成空间",
        "downloading" => "正在下载空间资产",
        "validating" => "正在校验空间运行包",
        "registering" => "正在注册空间",
        "registered" => "空间已导入",
        "resume_available" => "已有待恢复的生成任务",
        "cancelled" => "本机任务已取消",
        "cancelled_remote_operation_may_continue" => "本机等待已取消，远端生成可能继续；可恢复原任务。",
        "failed" => "空间任务失败",
        _ => "",
    }
}

// ---------------------------------------------------------------------------
// Chrome helpers
// ---------------------------------------------------------------------------

/// Resolve a Chinese source string: navigation routes first, then the settings
/// copy catalog, then the source itself.
fn localized_route(locale: UiLocale, route: &'static str) -> SharedString {
    let navigation = settings_navigation_label(locale, route);
    if navigation != route {
        return navigation.into();
    }
    settings_copy(locale, route).into()
}

/// One original `Section`: a fixed dark card with a muted title above and the
/// rows below. Returns boxed elements on purpose — GPUI element types carry
/// their whole child tree, and several cards nested in one render is enough
/// generic depth to blow this crate's `#[test]` recursion budget.
#[derive(IntoElement)]
struct SettingsSection {
    title: SharedString,
    content: Div,
    visible: bool,
}

impl SettingsSection {
    fn new(title: impl Into<SharedString>) -> Self {
        Self {
            title: title.into(),
            visible: true,
            content: v_flex()
                .gap(px(metrics::SECTION_CONTENT_GAP))
                .w_full()
                .min_w(px(0.)),
        }
    }
    fn visible(mut self, visible: bool) -> Self {
        self.visible = visible;
        self
    }
    fn row_gap(mut self, gap: f32) -> Self {
        self.content = self.content.gap(px(gap));
        self
    }
}

impl ParentElement for SettingsSection {
    fn extend(&mut self, elements: impl IntoIterator<Item = AnyElement>) {
        self.content.extend(elements);
    }
}

impl RenderOnce for SettingsSection {
    fn render(self, _: &mut Window, _: &mut App) -> impl IntoElement {
        if !self.visible {
            return div().into_any_element();
        }
        let title = self.title.clone();
        ui::scene_card()
            .p(px(metrics::SECTION_PADDING))
            .flex()
            .flex_col()
            .gap(px(metrics::SECTION_TITLE_GAP))
            .when(!title.is_empty(), |card| {
                card.child(ui::section_title(title))
            })
            .child(self.content)
            .into_any_element()
    }
}

/// A row title: the original `.fontWeight(.medium)` body text.
fn row_title(text: impl Into<SharedString>) -> Div {
    ui::body(text).font_weight(FontWeight::MEDIUM)
}

/// The original `.caption` secondary description under a row.
fn row_detail(text: impl Into<SharedString>) -> Div {
    ui::muted(text)
}

/// A label/control row (`HStack(spacing: 12)` with the control trailing).
fn field_row(label: impl Into<SharedString>, control: impl IntoElement) -> Div {
    h_flex()
        .items_center()
        .justify_between()
        .gap(px(metrics::ROW_GAP))
        .w_full()
        .child(ui::body(label))
        .child(control)
}

fn check_icon(checked: bool) -> Icon {
    Icon::new(if checked {
        IconName::CircleCheck
    } else {
        IconName::Circle
    })
    .size(px(metrics::NOTICE_ICON))
}

fn orb_preview() -> impl IntoElement {
    div()
        .size(px(metrics::PREVIEW_SIZE))
        .flex_shrink_0()
        .rounded(px(metrics::PREVIEW_RADIUS))
        .bg(rgba(s::ACCENT).opacity(metrics::PREVIEW_BG_ALPHA))
        .with_animation(
            "settings-orb-breath",
            Animation::new(std::time::Duration::from_millis(3491)).repeat(),
            |this, phase| {
                let breath = 0.94 + 0.03 * ((phase * std::f32::consts::TAU).sin() + 1.);
                this.child(
                    canvas(
                        |_, _, _| (),
                        move |bounds: Bounds<Pixels>, _, window, _| {
                            let center = bounds.center();
                            let radius = px((metrics::PREVIEW_SIZE / 2. - metrics::ORB_INSET) * breath);
                            let colors = [
                                [1., 1., 1.],
                                [0.30, 0.66, 1.],
                                [0.08, 0.35, 0.95],
                                [1., 1., 1.],
                            ];
                            for slice in 0..96 {
                                let position = slice as f32 / 96.;
                                let index = (position * 3.).floor() as usize;
                                let blend = position * 3. - index as f32;
                                let color = Rgba {
                                    r: colors[index][0]
                                        + (colors[index + 1][0] - colors[index][0]) * blend,
                                    g: colors[index][1]
                                        + (colors[index + 1][1] - colors[index][1]) * blend,
                                    b: colors[index][2]
                                        + (colors[index + 1][2] - colors[index][2]) * blend,
                                    a: 1.,
                                };
                                let first = position * std::f32::consts::TAU;
                                let last = (slice as f32 + 1.05) / 96. * std::f32::consts::TAU;
                                let mut path = PathBuilder::fill();
                                path.move_to(center);
                                path.line_to(point(
                                    center.x + radius * first.cos(),
                                    center.y + radius * first.sin(),
                                ));
                                path.line_to(point(
                                    center.x + radius * last.cos(),
                                    center.y + radius * last.sin(),
                                ));
                                path.close();
                                if let Ok(path) = path.build() {
                                    window.paint_path(path, color);
                                }
                            }
                            let mut outline = PathBuilder::stroke(px(metrics::ORB_STROKE));
                            for step in 0..=96 {
                                let angle = step as f32 / 96. * std::f32::consts::TAU;
                                let vertex = point(
                                    center.x + radius * angle.cos(),
                                    center.y + radius * angle.sin(),
                                );
                                if step == 0 {
                                    outline.move_to(vertex);
                                } else {
                                    outline.line_to(vertex);
                                }
                            }
                            if let Ok(path) = outline.build() {
                                window.paint_path(path, rgba(s::TEXT));
                            }
                        },
                    )
                    .size_full(),
                )
            },
        )
}

fn presence_preview(package: &Value) -> AnyElement {
    let box_style = div()
        .size(px(metrics::PREVIEW_SIZE))
        .flex_shrink_0()
        .rounded(px(metrics::PREVIEW_RADIUS))
        .bg(rgba(s::ACCENT).opacity(metrics::PREVIEW_BG_ALPHA));
    if let Some(path) = package["thumbnailPath"]
        .as_str()
        .filter(|path| !path.is_empty())
    {
        box_style
            .overflow_hidden()
            .child(
                img(std::path::PathBuf::from(path))
                    .size_full()
                    .object_fit(ObjectFit::Cover),
            )
            .into_any_element()
    } else if package["engine"].as_str() == Some("orb") {
        orb_preview().into_any_element()
    } else {
        box_style
            .flex()
            .items_center()
            .justify_center()
            .text_color(rgba(s::ACCENT).opacity(metrics::PREVIEW_GLYPH_ALPHA))
            .child(
                Icon::new(if package["engine"].as_str() == Some("pmx") {
                    IconName::PersonStanding
                } else {
                    IconName::UserRound
                })
                .size(px(metrics::PREVIEW_ICON)),
            )
            .into_any_element()
    }
}

// ---------------------------------------------------------------------------
// The pane
// ---------------------------------------------------------------------------

pub struct AgentSettingsPane {
    snapshot: Value,
    draft: Value,
    inputs: Vec<Entity<InputState>>,
    personas: Vec<Entity<TextareaState>>,
    commands: Vec<Value>,
    initialized: bool,
    unity_external: bool,
    page: usize,
    section: String,
    stage_pane: Option<Entity<crate::stage_panels::StagePanelsPane>>,
    extra_inputs: Vec<Entity<InputState>>,
    motion_category: String,
    orb_color: Entity<ColorPickerState>,
    orb_intensity: Entity<SliderState>,
    position_inputs: Vec<Entity<InputState>>,
    position_dirty: bool,
    syncing_position: bool,
    position_world: String,
    position_revision: u64,
    position_layout_revision: u64,
    position_notice: Option<String>,
    video_brightness: Entity<SliderState>,
    syncing_video: bool,
    _subscriptions: Vec<Subscription>,
    import_link_open: bool,
    custom_voice_open: bool,
    import_link_window: Option<AnyWindowHandle>,
    import_link_pending: bool,
    import_link_revision: u64,
    pending_marble: Option<(u64, String)>,
    pending_prop: Option<(u64, String, String)>,
    /// The host's `settings.supportedCommands` whitelist, pushed by the Unity
    /// settings window (`settings_ui.rs`). It is not part of the `settings`
    /// sub-root the three host snapshot producers write, so it cannot be read
    /// off [`Self::snapshot`]. See [`Self::op_supported`].
    supported_ops: Vec<String>,
}

impl AgentSettingsPane {
    fn open_import_link(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let locale = UiLocale::from_settings(&self.snapshot);
        self.import_link_open = true;
        self.import_link_pending = false;
        self.import_link_revision = self.snapshot["presence"]["downloadRevision"]
            .as_u64()
            .unwrap_or(0);
        self.import_link_window = Some(Window::window_handle(window));
        let weak = cx.entity().downgrade();
        window.open_dialog(cx, move |dialog, _, cx| {
            let Some(entity) = weak.upgrade() else {
                return dialog;
            };
            let this = entity.read(cx);
            let input = this.extra_inputs[4].clone();
            let working = this.import_link_pending
                || this.snapshot["presence"]["working"].as_bool() == Some(true);
            let notice = this.snapshot["presence"]["notice"]
                .as_str()
                .filter(|_| this.snapshot["presence"]["hasError"].as_bool() == Some(true))
                .map(str::to_owned);
            let disabled = working || input.read(cx).value().trim().is_empty();
            let cancel = weak.clone();
            let submit = weak.clone();
            let close = weak.clone();
            let escape_input = weak.clone();
            let escape_footer = weak.clone();
            let escape_action = weak.clone();
            let mut body = div()
                .flex()
                .flex_col()
                .gap(px(tokens::SPACING_12))
                .capture_key_down(move |event, window, cx| {
                    if event.keystroke.key == "escape" {
                        _ = escape_input.update(cx, |this, cx| {
                            this.import_link_open = false;
                            cx.notify();
                        });
                        window.close_dialog(cx);
                        cx.stop_propagation();
                    }
                })
                .child(ui::muted(settings_copy(
                    locale,
                    "支持 HTTPS 地址指向 VRM、ZIP 或 gmgnpet 模型包。",
                )))
                .child(Input::new(&input).accessibility_id("settings.presence.import.url"));
            if let Some(notice) = notice {
                body = body.child(ui::notice(notice));
            }
            let width = metrics::LINK_SHEET_WIDTH;
            let height = metrics::LINK_SHEET_HEIGHT;
            dialog
                .w(px(width))
                .h(px(height))
                .p(px(metrics::LINK_SHEET_PADDING))
                .title(settings_copy(locale, "从链接导入角色"))
                .close_button(false)
                .overlay_closable(false)
                .child(body)
                .footer(
                    div()
                        .flex()
                        .justify_end()
                        .items_center()
                        .gap(px(tokens::SPACING_8))
                        .capture_key_down(move |event, window, cx| {
                            if event.keystroke.key == "escape" {
                                _ = escape_footer.update(cx, |this, cx| {
                                    this.import_link_open = false;
                                    cx.notify();
                                });
                                window.close_dialog(cx);
                                cx.stop_propagation();
                            }
                        })
                        .child(
                            Button::new("cancel-link")
                                .label(settings_copy(locale, "取消"))
                                .on_click(move |_, window, cx| {
                                    _ = cancel.update(cx, |this, cx| {
                                        this.import_link_open = false;
                                        cx.notify();
                                    });
                                    window.close_dialog(cx);
                                }),
                        )
                        .child(
                            Button::new("import-link")
                                .label(settings_copy(
                                    locale,
                                    if working { "正在下载…" } else { "下载并安装" },
                                ))
                                .primary()
                                .disabled(disabled)
                                .on_click(move |_, _, cx| {
                                    _ = submit.update(cx, |this, cx| {
                                        this.commands.push(json!({"op":"presence.import.link","url":this.extra_inputs[4].read(cx).value().to_string()}));
                                        this.import_link_pending = true;
                                        this.import_link_revision = this.snapshot["presence"]
                                            ["downloadRevision"]
                                            .as_u64()
                                            .unwrap_or(0);
                                        cx.notify();
                                    });
                                }),
                        ),
                )
                .on_cancel(move |_, window, cx| {
                    _ = escape_action.update(cx, |this, cx| {
                        this.import_link_open = false;
                        cx.notify();
                    });
                    window.close_dialog(cx);
                    true
                })
                .on_close(move |_, _, cx| {
                    _ = close.update(cx, |this, cx| {
                        this.import_link_open = false;
                        cx.notify();
                    });
                })
        });
        cx.notify();
    }

    fn remove_menu(
        &self,
        id: impl Into<ElementId>,
        label: &'static str,
        asset_name: &str,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let weak = cx.entity().downgrade();
        let locale = UiLocale::from_settings(&self.snapshot);
        let (role, mut name) = presence_more_accessibility(label, asset_name);
        if locale != UiLocale::ZhCn {
            name = format!("{}: {asset_name}", settings_copy(locale, "更多操作"));
        }
        let label = settings_copy(locale, label);
        Button::new(id)
            .role(role)
            .accessibility_label(name)
            .icon(IconName::Ellipsis)
            .small()
            .w(px(metrics::NOTICE_ICON + 8.))
            .h(px(metrics::NOTICE_ICON + 8.))
            .dropdown_menu(move |menu, _, _| {
                let weak = weak.clone();
                let command = command.clone();
                menu.item(PopupMenuItem::new(label).on_click(move |_, _, cx| {
                    _ = weak.update(cx, |this, cx| {
                        this.commands.push(command.clone());
                        cx.notify();
                    });
                }))
            })
            .into_any_element()
    }

    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let inputs: Vec<Entity<InputState>> = ["居民人格", "角色人格与偏好", "使用 Codex 默认模型", "自定义音色 ID"]
            .into_iter()
            .map(|label| cx.new(|cx| InputState::new(window, cx).placeholder(label)))
            .collect();
        let personas = ["居民人格", "角色人格与偏好"]
            .map(|label| cx.new(|cx| TextareaState::new(window, cx).placeholder(label).rows(4)))
            .to_vec();
        let extra_inputs: Vec<Entity<InputState>> = [
            "新的 TTS API Key",
            "新的 ASR API Key",
            "新的 Marble API Key",
            "https://…/catalog.json",
            "https://…/avatar.vrm",
            "生成服务地址",
            "生成服务密钥",
            "Marble World ID",
        ]
        .into_iter()
        .enumerate()
        .map(|(index, label)| {
            cx.new(|cx| {
                let mut state = InputState::new(window, cx).placeholder(label);
                if index < 3 || index == 6 {
                    state.set_masked(true, window, cx);
                }
                state
            })
        })
        .collect();
        let orb_color = cx.new(|cx| ColorPickerState::new(window, cx));
        let orb_intensity = cx.new(|_| SliderState::new().min(0.35).max(1.5).step(0.01));
        let position_inputs: Vec<_> = ["X", "Y", "Z"]
            .into_iter()
            .map(|axis| cx.new(|cx| InputState::new(window, cx).placeholder(axis)))
            .collect();
        // The brightness authority's floor is the product host's own accepted
        // range, `(0.15...1)` (`GMGNRadioApp.swift` `case "stage.video.brightness"`,
        // the same band `StagePanelsPane::new`'s brightness slider uses). A
        // 0-based slider here let the UI emit 0…0.15, which the Unity host
        // rejects (`UnityScreenVideoBridge` `case "video.brightness"`, aligned
        // to the same band), so the control's own domain is the authority's.
        let video_brightness = cx.new(|_| SliderState::new().min(0.15).max(1.).step(0.01));
        let weak = cx.entity().downgrade();
        let escape_subscription = cx.intercept_keystrokes(move |event, window, cx| {
            if event.keystroke.key != "escape" {
                return;
            }
            _ = weak.update(cx, |this, cx| {
                if this.import_link_open
                    && this.import_link_window == Some(Window::window_handle(window))
                {
                    this.import_link_open = false;
                    window.close_dialog(cx);
                    cx.stop_propagation();
                    cx.notify();
                }
            });
        });
        let mut subscriptions = vec![
            escape_subscription,
            cx.subscribe(&inputs[3], |this, input, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && this.initialized {
                    let current = json!(input.read(cx).value().to_string());
                    if tts_draft_change_requires_stop(
                        "tts",
                        "voiceID",
                        &this.draft["tts"]["voiceID"],
                        &current,
                    ) {
                        this.commands.push(json!({"op":"tts.stop"}));
                        this.draft["tts"]["voiceID"] = current;
                        cx.notify();
                    }
                }
            }),
            cx.subscribe(&extra_inputs[0], |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && this.initialized {
                    this.commands.push(json!({"op":"speech.settings.cancel","clearVoices":true,"cancelCapabilities":false}));
                    cx.notify();
                }
            }),
            cx.subscribe(&extra_inputs[3], |this, input, event: &InputEvent, cx| {
                if matches!(event, InputEvent::PressEnter { .. })
                    && this.snapshot["presence"]["working"].as_bool() != Some(true)
                {
                    let url = input.read(cx).value().to_string();
                    if !url.trim().is_empty() {
                        this.commands.push(json!({"op":"presence.catalog","url":url}));
                        cx.notify();
                    }
                }
            }),
            cx.subscribe(&extra_inputs[5], |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && this.initialized && !this.unity_external {
                    this.commands
                        .push(json!({"op":"space.prop.cancel","clearNotice":true}));
                    cx.notify();
                }
            }),
            cx.subscribe(&extra_inputs[6], |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && this.initialized && !this.unity_external {
                    this.commands
                        .push(json!({"op":"space.prop.cancel","clearNotice":true}));
                    cx.notify();
                }
            }),
            cx.subscribe(&extra_inputs[7], |_, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) {
                    cx.notify();
                }
            }),
            cx.subscribe(&inputs[2], |this, input, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && this.initialized {
                    this.commands.push(json!({"op":"agent.save","planningModel":input.read(cx).value().to_string()}));
                }
            }),
            cx.subscribe(&orb_color, |this, _, event: &ColorPickerEvent, cx| {
                if let ColorPickerEvent::Change(Some(color)) = event {
                    let color = color.to_rgb();
                    this.commands.push(json!({"op":"presence.orb.color","red":color.r,"green":color.g,"blue":color.b}));
                    cx.notify();
                }
            }),
            cx.subscribe(&orb_intensity, |this, _, event: &SliderEvent, cx| {
                if let SliderEvent::Change(value) = event {
                    this.commands
                        .push(json!({"op":"presence.orb.intensity","value":value.start()}));
                    cx.notify();
                }
            }),
            cx.subscribe(&video_brightness, |this, _, event: &SliderEvent, cx| {
                if !this.syncing_video {
                    if let SliderEvent::Change(value) = event {
                        this.commands
                            .push(json!({"op":"video.brightness","value":value.start()}));
                        cx.notify();
                    }
                }
            }),
        ];
        for input in &position_inputs {
            subscriptions.push(cx.subscribe(input, |this, _, event: &InputEvent, cx| {
                if matches!(event, InputEvent::Change) && !this.syncing_position {
                    this.position_dirty = true;
                    this.position_notice = None;
                    cx.notify();
                }
            }));
        }
        Self {
            snapshot: Value::Null,
            draft: Value::Null,
            inputs,
            personas,
            commands: vec![json!({"op":"settings.load"})],
            initialized: false,
            unity_external: false,
            page: PAGE_PRESENCE,
            section: "角色管理".into(),
            stage_pane: None,
            extra_inputs,
            motion_category: String::new(),
            orb_color,
            orb_intensity,
            position_inputs,
            position_dirty: false,
            syncing_position: false,
            position_world: String::new(),
            position_revision: 0,
            position_layout_revision: 0,
            position_notice: None,
            _subscriptions: subscriptions,
            video_brightness,
            syncing_video: false,
            import_link_open: false,
            custom_voice_open: false,
            import_link_window: None,
            import_link_pending: false,
            import_link_revision: 0,
            pending_marble: None,
            pending_prop: None,
            supported_ops: Vec::new(),
        }
    }

    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }

    /// Whether the host's `supportedCommands` declares this op. It is the same
    /// list `SettingsPane`'s dispatch whitelist enforces
    /// (`gpui-unity-overlay-probe/src/settings_ui.rs`), so an op missing here
    /// would be refused after the click; those controls are not drawn. An
    /// unpublished list keeps every control (see `StagePanelsPane::op_supported`).
    fn op_supported(&self, op: &str) -> bool {
        self.supported_ops.is_empty()
            || self.supported_ops.iter().any(|supported| supported == op)
    }

    /// The host's settings whitelist, applied whenever the settings window
    /// receives a new snapshot.
    pub fn set_supported_ops(&mut self, supported: Vec<String>, cx: &mut Context<Self>) {
        if self.supported_ops == supported {
            return;
        }
        self.supported_ops = supported;
        cx.notify();
    }

    pub fn select_page(&mut self, page: &str, cx: &mut Context<Self>) {
        if self.page == PAGE_AGENT && !matches!(page, "agent" | "dj") {
            self.commands.push(json!({"op":"speech.settings.cancel"}));
        }
        if self.page == PAGE_SPACE_PREFS && !self.unity_external {
            self.commands.push(json!({"op":"space.prop.cancel"}));
        }
        if self.page == PAGE_SHORTCUTS {
            self.commands.push(json!({"op":"shortcuts.cancel"}));
        }
        self.page = page_index_for_key(page);
        if self.unity_external && self.page == PAGE_SPACE {
            self.commands.push(json!({"op":"space.library.load"}));
        }
        let valid = match self.page {
            PAGE_PRESENCE => matches!(self.section.as_str(), "角色管理" | "动作管理"),
            PAGE_MUSIC => self.section == "音乐账号与歌单同步",
            PAGE_SPACE_PREFS => self.section == "生成服务",
            PAGE_SHORTCUTS => self.section == "快捷键",
            PAGE_AGENT => matches!(
                self.section.as_str(),
                "Agent 连接" | "语音播放" | "按住说话" | "自主行动"
            ),
            PAGE_PLAYER => matches!(self.section.as_str(), "歌词" | "视觉效果" | "视频"),
            PAGE_SPACE => self.section == "我的空间",
            _ => true,
        };
        if !valid {
            self.section = match self.page {
                PAGE_PRESENCE => "角色管理",
                PAGE_MUSIC => "音乐账号与歌单同步",
                PAGE_SPACE_PREFS => "生成服务",
                PAGE_SHORTCUTS => "快捷键",
                PAGE_AGENT => "Agent 连接",
                PAGE_PLAYER => "歌词",
                PAGE_SPACE => "我的空间",
                _ => "活动",
            }
            .into();
        }
        if self.page == PAGE_PRESENCE {
            self.commands.push(json!({"op":"presence.load"}));
        }
        if self.page == PAGE_AGENT {
            self.commands.push(json!({"op":"speech.settings.load"}));
        }
        if let Some(stage) = &self.stage_pane {
            let tab = match self.page {
                PAGE_PLAYER => Some("player"),
                PAGE_SPACE => Some("space"),
                PAGE_ACTIVITIES => Some("activities"),
                _ => None,
            };
            if let Some(tab) = tab {
                stage.update(cx, |stage, cx| {
                    stage.select_tab(tab, cx);
                    stage.select_section(&self.section, cx);
                });
            }
        }
        cx.notify();
    }

    pub fn set_stage_pane(
        &mut self,
        pane: Entity<crate::stage_panels::StagePanelsPane>,
        cx: &mut Context<Self>,
    ) {
        pane.update(cx, |stage, cx| stage.set_embedded(true, cx));
        self.stage_pane = Some(pane);
        cx.notify();
    }

    pub fn set_unity_external(&mut self, enabled: bool, cx: &mut Context<Self>) {
        self.unity_external = enabled;
        cx.notify();
    }

    pub fn select_section(&mut self, page: &str, section: &str, cx: &mut Context<Self>) {
        self.section = section.into();
        self.select_page(page, cx);
        if self.unity_external && section == "视频" {
            self.commands.push(json!({"op":"video.load"}));
        }
        if let Some(stage) = &self.stage_pane {
            stage.update(cx, |stage, cx| stage.select_section(section, cx));
        }
    }

    pub fn dismissed(&mut self, cx: &mut Context<Self>) {
        if !self.unity_external {
            self.commands.push(json!({"op":"space.prop.cancel"}));
        }
        self.commands.push(json!({"op":"shortcuts.cancel"}));
        self.commands.push(json!({"op":"speech.settings.cancel"}));
        cx.notify();
    }

    pub fn update_snapshot(&mut self, snapshot: Value, window: &mut Window, cx: &mut Context<Self>) {
        if snapshot.is_null() || self.snapshot == snapshot {
            return;
        }
        let locale = UiLocale::from_settings(&snapshot);
        for (index, source) in [(0, "新的 TTS API Key"), (1, "新的 ASR API Key")] {
            self.extra_inputs[index].update(cx, |input, cx| {
                input.set_placeholder(settings_copy(locale, source), window, cx)
            });
        }
        self.inputs[3].update(cx, |input, cx| {
            input.set_placeholder(settings_copy(locale, "自定义音色 ID"), window, cx)
        });
        for (index, source) in [(0, "居民人格"), (1, "角色人格与偏好")] {
            self.personas[index].update(cx, |input, cx| {
                input.set_placeholder(settings_copy(locale, source), window, cx)
            });
        }
        self.inputs[2].update(cx, |input, cx| {
            input.set_placeholder(settings_copy(locale, "使用 Codex 默认模型"), window, cx)
        });
        self.extra_inputs[5].update(cx, |input, cx| {
            input.set_placeholder(settings_copy(locale, "生成服务地址"), window, cx)
        });
        self.extra_inputs[7].update(cx, |input, cx| {
            input.set_placeholder(settings_copy(locale, "Marble World ID"), window, cx)
        });
        self.extra_inputs[2].update(cx, |input, cx| {
            input.set_placeholder(
                settings_copy(
                    locale,
                    if snapshot["space"]["credentialConfigured"].as_bool() == Some(true) {
                        "粘贴新的 API Key 可覆盖现有配置"
                    } else {
                        "粘贴 API Key"
                    },
                ),
                window,
                cx,
            )
        });
        self.extra_inputs[6].update(cx, |input, cx| {
            input.set_placeholder(
                settings_copy(
                    locale,
                    if snapshot["space"]["propCredentialConfigured"].as_bool() == Some(true) {
                        "填写新密钥可替换；留空保留现有密钥"
                    } else {
                        "生成服务密钥"
                    },
                ),
                window,
                cx,
            )
        });
        if self.unity_external {
            self.extra_inputs[6].update(cx, |input, cx| {
                input.set_placeholder(
                    settings_copy(
                        locale,
                        if snapshot["generation"]["configured"].as_bool() == Some(true) {
                            "填写新密钥可替换；留空保留现有密钥"
                        } else {
                            "生成服务密钥"
                        },
                    ),
                    window,
                    cx,
                )
            });
        }
        if let Some((revision, submitted)) = &self.pending_marble {
            if snapshot["space"]["marbleMutationRevision"]
                .as_u64()
                .is_some_and(|ack| ack > *revision)
            {
                if save_ack_clear(
                    *revision,
                    snapshot["space"]["marbleMutationRevision"].as_u64().unwrap_or(0),
                    submitted,
                    self.extra_inputs[2].read(cx).value().as_str(),
                ) {
                    self.extra_inputs[2].update(cx, |input, cx| input.set_value("", window, cx));
                }
                self.pending_marble = None;
            }
        }
        if let Some((revision, endpoint, key)) = &self.pending_prop {
            if snapshot["space"]["propSaveRevision"]
                .as_u64()
                .is_some_and(|ack| ack > *revision)
            {
                if self.extra_inputs[5].read(cx).value().as_str() == endpoint {
                    let normalized = snapshot["space"]["propEndpoint"]
                        .as_str()
                        .unwrap_or(endpoint)
                        .to_owned();
                    self.extra_inputs[5].update(cx, |input, cx| {
                        input.set_value(normalized, window, cx)
                    });
                }
                if save_ack_clear(
                    *revision,
                    snapshot["space"]["propSaveRevision"].as_u64().unwrap_or(0),
                    key,
                    self.extra_inputs[6].read(cx).value().as_str(),
                ) {
                    self.extra_inputs[6].update(cx, |input, cx| input.set_value("", window, cx));
                }
                self.pending_prop = None;
            }
        }
        if !self.initialized {
            self.draft = snapshot.clone();
            for (i, section, field) in [
                (0, "agent", "residentPersona"),
                (1, "agent", "hostPrompt"),
                (2, "agent", "planningModel"),
                (3, "tts", "voiceID"),
            ] {
                let text = snapshot[section][field].as_str().unwrap_or("").to_owned();
                if i < 2 {
                    self.personas[i].update(cx, |input, cx| input.set_value(text, window, cx));
                } else {
                    self.inputs[i].update(cx, |input, cx| input.set_value(text, window, cx));
                }
            }
            self.initialized = true;
            for (index, section, field) in
                [(3, "presence", "catalogURL"), (5, "space", "propEndpoint")]
            {
                let value = if self.unity_external && index == 5 {
                    snapshot["generation"]["endpoint"].as_str()
                } else {
                    snapshot[section][field].as_str()
                }
                .unwrap_or("")
                .to_owned();
                self.extra_inputs[index].update(cx, |input, cx| input.set_value(value, window, cx));
            }
            let orb = &snapshot["presence"]["orb"];
            if let (Some(r), Some(g), Some(b)) = (
                orb["red"].as_f64(),
                orb["green"].as_f64(),
                orb["blue"].as_f64(),
            ) {
                self.orb_color.update(cx, |state, cx| {
                    state.set_value(
                        Rgba {
                            r: r as f32,
                            g: g as f32,
                            b: b as f32,
                            a: 1.,
                        },
                        window,
                        cx,
                    )
                });
            }
            if let Some(value) = orb["flowIntensity"].as_f64() {
                self.orb_intensity
                    .update(cx, |state, cx| state.set_value(value as f32, window, cx));
            }
        } else if self.snapshot["tts"]["providerID"] != snapshot["tts"]["providerID"] {
            self.draft["tts"] = snapshot["tts"].clone();
            let voice = snapshot["tts"]["voiceID"].as_str().unwrap_or("").to_owned();
            self.inputs[3].update(cx, |input, cx| input.set_value(voice, window, cx));
        } else if self.draft["tts"]["modelID"].as_str().unwrap_or("").is_empty() {
            self.draft["tts"]["modelID"] = snapshot["tts"]["modelID"].clone();
        }
        if self.snapshot["asr"]["providerID"] != snapshot["asr"]["providerID"]
            || self.draft["asr"]["modelID"].as_str().unwrap_or("").is_empty()
        {
            self.draft["asr"] = snapshot["asr"].clone();
        }
        if self.import_link_pending
            && snapshot["presence"]["downloadRevision"]
                .as_u64()
                .is_some_and(|revision| revision > self.import_link_revision)
            && matches!(
                snapshot["presence"]["downloadState"].as_str(),
                Some("succeeded" | "failed")
            )
        {
            self.import_link_pending = false;
            if snapshot["presence"]["downloadState"].as_str() == Some("succeeded") {
                if let Some(handle) = self.import_link_window {
                    _ = handle.update(cx, |_, window, cx| window.close_dialog(cx));
                }
                self.import_link_open = false;
            }
        }
        if let Some(value) = snapshot["video"]["brightness"]
            .as_f64()
            .filter(|value| value.is_finite())
        {
            // An older host (or a restored preference written below the floor)
            // must not drive the control outside its own emitted domain.
            let value = value.clamp(0.15, 1.);
            self.syncing_video = true;
            self.video_brightness
                .update(cx, |slider, cx| slider.set_value(value as f32, window, cx));
            self.syncing_video = false;
        }
        let position = &snapshot["characterPosition"];
        let world = position["worldID"].as_str().unwrap_or("");
        if world != self.position_world || !self.position_dirty {
            self.syncing_position = true;
            for (index, input) in self.position_inputs.iter().enumerate() {
                let value = position["position"][index]
                    .as_f64()
                    .map(|v| format!("{v:.3}"))
                    .unwrap_or_default();
                input.update(cx, |input, cx| input.set_value(value, window, cx));
            }
            self.syncing_position = false;
            self.position_dirty = false;
            self.position_world = world.to_owned();
            self.position_revision = position["revision"].as_u64().unwrap_or(0);
            self.position_layout_revision = position["layoutRevision"].as_u64().unwrap_or(0);
            self.position_notice = None;
        }
        self.snapshot = snapshot;
        cx.notify();
    }

    fn selection(
        &mut self,
        section: &str,
        field: &str,
        value: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if tts_draft_change_requires_stop(section, field, &self.draft[section][field], &value) {
            self.commands.push(json!({"op":"tts.stop"}));
        }
        self.draft[section][field] = value.clone();
        if matches!(section, "tts" | "asr") && field == "providerID" {
            self.extra_inputs[if section == "tts" { 0 } else { 1 }]
                .update(cx, |input, cx| input.set_value("", window, cx));
            self.commands
                .push(json!({"op":format!("{section}.provider"),"id":value}));
        }
        if section == "space" && field == "defaultSpace" {
            self.commands
                .push(json!({"op":"space.default","value":value}));
        }
        if section == "agent" {
            let mut command = json!({"op":"agent.save"});
            command[field] = value.clone();
            self.commands.push(command);
        }
        if section == "tts" && field == "voiceID" {
            self.inputs[3]
                .update(cx, |input, cx| input.set_value(value.as_str().unwrap_or(""), window, cx));
        }
        cx.notify();
    }

    fn options(&self, section: &str, key: &str) -> Vec<(Value, String)> {
        let locale = UiLocale::from_settings(&self.snapshot);
        self.snapshot[section][key]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|v| {
                if let Some(n) = v.as_u64() {
                    Some((
                        json!(n),
                        if n == 0 {
                            settings_copy(locale, "0 轮（不再新起）").to_owned()
                        } else {
                            format!("{n} {}", settings_copy(locale, "轮"))
                        },
                    ))
                } else {
                    let raw = v.get("name")?.as_str()?;
                    let mut name = if (section == "presence" && key == "categories")
                        || (section == "asr" && key == "microphoneDevices")
                    {
                        settings_copy(locale, raw).to_owned()
                    } else {
                        raw.to_owned()
                    };
                    if key == "models" && v["id"] == self.snapshot[section]["defaultModelID"] {
                        name.push_str(settings_copy(locale, "（默认）"));
                    }
                    if v.get("installed").and_then(Value::as_bool) == Some(false) {
                        name.push_str(settings_copy(locale, "（未安装）"));
                    }
                    Some((v.get("id")?.clone(), name))
                }
            })
            .collect()
    }

    /// The original `Picker`: a labelled pop-up button. Kit's `Button` with a
    /// dropdown menu is the same control the Swift picker draws on macOS.
    fn dropdown(
        &self,
        id: &'static str,
        label: &'static str,
        section: &'static str,
        field: &'static str,
        items: Vec<(Value, String)>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let value = self.draft[section][field].clone();
        let selected = items
            .iter()
            .find(|(id, _)| *id == value)
            .map(|(_, name)| name.clone())
            .unwrap_or_else(|| {
                value
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .map(|raw| {
                        if field == "modelID" {
                            settings_copy(locale, "旧模型不受支持，请重新选择").to_owned()
                        } else if field == "voiceID" {
                            format!("{} ({raw})", settings_copy(locale, "当前声音"))
                        } else {
                            raw.to_owned()
                        }
                    })
                    .unwrap_or_else(|| {
                        if field == "modelID" {
                            settings_copy(locale, "正在加载模型选项").to_owned()
                        } else {
                            settings_copy(locale, "请选择").to_owned()
                        }
                    })
            });
        let weak = cx.entity().downgrade();
        h_flex()
            .items_center()
            .justify_between()
            .gap(px(metrics::ROW_GAP))
            .w_full()
            .child(ui::body(settings_copy(locale, label)))
            .child(
                Button::new(id)
                    .label(selected)
                    .dropdown_caret(true)
                    .accessibility_id(format!("settings.{section}.{field}"))
                    .accessibility_label(settings_copy(locale, label))
                    .disabled(
                        items.is_empty()
                            || (section == "tts"
                                && field == "voiceID"
                                && self.snapshot["tts"]["loading"].as_bool() == Some(true)),
                    )
                    .dropdown_menu(move |mut menu, _, _| {
                        for (value, name) in &items {
                            let weak = weak.clone();
                            let value = value.clone();
                            menu = menu.item(PopupMenuItem::new(name.clone()).on_click(
                                move |_, window, cx| {
                                    _ = weak.update(cx, |this, cx| {
                                        this.selection(section, field, value.clone(), window, cx)
                                    });
                                },
                            ));
                        }
                        menu
                    }),
            )
            .into_any_element()
    }

    fn toggle(
        &self,
        id: &'static str,
        label: &'static str,
        field: &'static str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        Switch::new(id)
            .label(settings_copy(locale, label))
            .accessibility_label(settings_copy(locale, label))
            .checked(self.draft["agent"][field].as_bool().unwrap_or(false))
            .on_change(cx.listener(move |this, value: &bool, _, cx| {
                this.draft["agent"][field] = json!(*value);
                let mut command = json!({"op":"agent.save"});
                command[field] = json!(*value);
                this.commands.push(command);
                cx.notify();
            }))
            .into_any_element()
    }

    fn tts_action(&mut self, op: &str, cx: &mut Context<Self>) {
        let mut tts = self.draft["tts"].clone();
        tts["voiceID"] = json!(self.inputs[3].read(cx).value().to_string());
        tts["apiKey"] = json!(self.extra_inputs[0].read(cx).value().to_string());
        tts["op"] = json!(op);
        self.commands.push(tts);
    }

    fn command_button(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        command: Value,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let label: SharedString = label.into();
        let label = settings_copy(UiLocale::from_settings(&self.snapshot), label.as_ref()).to_owned();
        Button::new(id)
            .label(label)
            .when(command["op"] == "space.key.clear", |button| button.danger())
            .on_click(cx.listener(move |this, _, _, cx| {
                if command["op"] == "space.key.clear" {
                    this.pending_marble = Some((
                        this.snapshot["space"]["marbleMutationRevision"]
                            .as_u64()
                            .unwrap_or(0),
                        this.extra_inputs[2].read(cx).value().to_string(),
                    ));
                }
                this.commands.push(command.clone());
                cx.notify();
            }))
            .into_any_element()
    }

    /// Whether a section is shown in the Unity category menu. The product
    /// window shows every original section of its page.
    fn group_visible(&self, title: &str) -> bool {
        if !self.unity_external {
            return true;
        }
        match self.section.as_str() {
            "角色管理" => matches!(title, "角色" | "呼吸球样式"),
            "动作管理" => matches!(title, "动作" | "动作库"),
            "我的空间" => title == "默认空间",
            "生成服务" => title != "默认空间",
            _ => true,
        }
    }

    /// The Agent page additionally hides groups the Unity runtime does not
    /// advertise.
    fn agent_group_visible(&self, title: &str) -> bool {
        if !self.unity_external {
            return true;
        }
        if !unity_agent_group_available(&self.snapshot, title) {
            return false;
        }
        match self.section.as_str() {
            "语音播放" => title == "回复语音",
            "按住说话" => title == "按住说话",
            "自主行动" => matches!(title, "角色人格与偏好" | "居民人格" | "自主行动"),
            _ => matches!(title, "角色内核" | "聊天模型"),
        }
    }
}

// ---------------------------------------------------------------------------
// Pages
// ---------------------------------------------------------------------------

impl AgentSettingsPane {
    /// Character position (Unity 角色管理 section). The commands and their
    /// revision guards are the original transport's; only the chrome changed.
    fn character_position_form(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let position = self.snapshot["characterPosition"].clone();
        let unavailable = position["available"].as_bool() != Some(true);
        let working = position["working"].as_bool() == Some(true);
        let mut coordinates = h_flex()
            .items_center()
            .gap(px(tokens::SPACING_8))
            .w_full();
        for (index, axis) in ["X", "Y", "Z"].into_iter().enumerate() {
            coordinates = coordinates.child(ui::body(axis)).child(
                div().flex_1().min_w(px(0.)).child(
                    Input::new(&self.position_inputs[index])
                        .disabled(unavailable || working)
                        .accessibility_id(format!("settings.presence.position.{axis}"))
                        .aria_label(format!("{} {axis}", settings_copy(locale, "人物位置"))),
                ),
            );
        }
        let mut section = SettingsSection::new(settings_copy(locale, "人物位置"))
            .child(coordinates)
            .child(row_detail(settings_copy(
                locale,
                "坐标以米计；人物会沿可通行地面移动，Y 必须贴合目标地面。",
            )))
            .child(
                h_flex()
                    .items_center()
                    .gap(px(tokens::SPACING_8))
                    .child(
                        Button::new("character-position-apply")
                            .small()
                            .icon(IconName::Map)
                            .tooltip(settings_copy(locale, "移动到坐标"))
                            .accessibility_label(settings_copy(locale, "移动到坐标"))
                            .disabled(unavailable || working)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let values: Option<Vec<f64>> = this
                                    .position_inputs
                                    .iter()
                                    .map(|input| {
                                        input
                                            .read(cx)
                                            .value()
                                            .trim()
                                            .parse::<f64>()
                                            .ok()
                                            .filter(|v| v.is_finite())
                                    })
                                    .collect();
                                if let Some(values) = values {
                                    let id = format!(
                                        "position-{}",
                                        std::time::SystemTime::now()
                                            .duration_since(std::time::UNIX_EPOCH)
                                            .unwrap_or_default()
                                            .as_nanos()
                                    );
                                    this.commands.push(json!({"op":"presence.position", "worldID":this.position_world,
                                        "expectedRevision":this.position_revision, "expectedLayoutRevision":this.position_layout_revision,
                                        "requestID":id, "position":values}));
                                    this.position_dirty = false;
                                    this.position_notice = None;
                                } else {
                                    this.position_notice =
                                        Some("请输入有效的 X、Y、Z 坐标。".into());
                                }
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("character-position-reset")
                            .small()
                            .icon(IconName::Undo2)
                            .tooltip(settings_copy(locale, "重置"))
                            .accessibility_label(settings_copy(locale, "重置"))
                            .disabled(unavailable || working)
                            .on_click(cx.listener(|this, _, _, cx| {
                                let id = format!(
                                    "position-reset-{}",
                                    std::time::SystemTime::now()
                                        .duration_since(std::time::UNIX_EPOCH)
                                        .unwrap_or_default()
                                        .as_nanos()
                                );
                                this.commands.push(json!({"op":"presence.position.reset", "worldID":this.snapshot["characterPosition"]["worldID"],
                                    "expectedRevision":this.snapshot["characterPosition"]["revision"],
                                    "expectedLayoutRevision":this.snapshot["characterPosition"]["layoutRevision"], "requestID":id}));
                                this.position_dirty = false;
                                this.position_notice = None;
                                cx.notify();
                            })),
                    ),
            );
        if let Some(notice) = self
            .position_notice
            .as_deref()
            .or_else(|| position["notice"].as_str())
        {
            section = section.child(ui::notice(settings_notice(locale, notice)));
        }
        section.into_any_element()
    }

    /// The Unity video section (播放器 → 视频). The stage pane owns the lyrics and
    /// point-cloud sections; this authority panel is settings-only.
    fn video_page(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let video = self.snapshot["video"].clone();
        let mut section = SettingsSection::new(settings_copy(locale, "视频")).child(
            h_flex()
                .items_center()
                .gap(px(tokens::SPACING_8))
                .w_full()
                .child(self.command_button(
                    "unity-video-choose",
                    "导入视频",
                    json!({"op":"video.choose"}),
                    cx,
                ))
                .child(
                    Button::new("unity-video-play")
                        .small()
                        .icon(if video["playing"].as_bool() == Some(true) {
                            IconName::Pause
                        } else {
                            IconName::Play
                        })
                        .tooltip(settings_copy(
                            locale,
                            if video["playing"].as_bool() == Some(true) {
                                "暂停"
                            } else {
                                "播放"
                            },
                        ))
                        .accessibility_label(settings_copy(
                            locale,
                            if video["playing"].as_bool() == Some(true) {
                                "暂停"
                            } else {
                                "播放"
                            },
                        ))
                        .disabled(video["selectedID"].is_null() && video["activeID"].is_null())
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.commands.push(json!({
                                "op": if this.snapshot["video"]["playing"].as_bool() == Some(true) {
                                    "video.pause"
                                } else {
                                    "video.play"
                                }
                            }));
                            cx.notify();
                        })),
                )
                .child(self.command_button(
                    "unity-video-stop",
                    "停止",
                    json!({"op":"video.stop"}),
                    cx,
                )),
        );
        if let Some(notice) = video["notice"].as_str().filter(|s| !s.trim().is_empty()) {
            section = section.child(ui::notice(notice.to_owned()).id("unity-video-authority-notice"));
        }
        if video["canRecoverStop"].as_bool() == Some(true) {
            section = section.child(self.command_button(
                "unity-video-recover-stop",
                "停止并核验",
                json!({"op":"video.recoverStop"}),
                cx,
            ));
        }
        if let Some(title) = video["currentTrackTitle"].as_str() {
            section = section.child(row_detail(format!(
                "{}: {}",
                settings_copy(locale, "当前歌曲"),
                title
            )));
        }
        for asset in video["assets"].as_array().into_iter().flatten() {
            let Some(id) = asset["id"].as_str() else {
                continue;
            };
            let selected = video["selectedID"].as_str() == Some(id);
            let mut row = h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .w_full()
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .child(ui::body(asset["name"].as_str().unwrap_or(id).to_owned())),
                )
                .child(
                    Button::new(format!("unity-video-select-{id}"))
                        .small()
                        .icon(if selected { IconName::Check } else { IconName::Play })
                        .tooltip(settings_copy(
                            locale,
                            if selected { "使用中" } else { "选择并播放" },
                        ))
                        .accessibility_label(settings_copy(
                            locale,
                            if selected { "使用中" } else { "选择并播放" },
                        ))
                        .disabled(selected)
                        .on_click(cx.listener({
                            let id = id.to_owned();
                            move |this, _, _, cx| {
                                this.commands.push(json!({"op":"video.select","id":id}));
                                cx.notify();
                            }
                        })),
                )
                .child(self.remove_menu(
                    format!("unity-video-remove-{id}"),
                    "移出素材库",
                    asset["name"].as_str().unwrap_or(id),
                    json!({"op":"video.remove","id":id}),
                    cx,
                ));
            if let Some(track_id) = video["currentTrackID"].as_str() {
                let bound = video["boundAssetID"].as_str() == Some(id);
                // `video.unbind` acts on the current track only: the Unity
                // handler validates `trackID` and derives the binding itself
                // (`UnityScreenVideoBridge` `case "video.unbind"`), so it
                // carries no `id`. `video.bind` is the one that names the asset.
                let command = if bound {
                    json!({"op":"video.unbind","trackID":track_id})
                } else {
                    json!({"op":"video.bind","id":id,"trackID":track_id})
                };
                row = row.child(self.command_button(
                    format!("unity-video-bind-{id}"),
                    if bound {
                        "解除当前歌曲绑定"
                    } else {
                        "绑定到当前歌曲"
                    },
                    command,
                    cx,
                ));
            }
            section = section.child(row);
        }
        if let Some(prompt_id) = video["pendingBoundVideo"]["id"].as_str() {
            section = section.child(
                h_flex()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .w_full()
                    .child(
                        div().flex_1().min_w(px(0.)).child(ui::body(settings_copy(
                            locale,
                            "当前歌曲有绑定视频",
                        ))),
                    )
                    .child(self.command_button(
                        "unity-video-bound-play",
                        "播放绑定视频",
                        json!({"op":"video.bound.play","id":prompt_id}),
                        cx,
                    ))
                    .child(self.command_button(
                        "unity-video-bound-dismiss",
                        "关闭",
                        json!({"op":"video.bound.dismiss","id":prompt_id}),
                        cx,
                    )),
            );
        }
        let mut modes = h_flex().items_center().gap(px(tokens::SPACING_8));
        for (id, label) in [("once", "单次"), ("loop", "循环"), ("randomSequence", "随机拼接")] {
            modes = modes.child(
                Button::new(format!("unity-video-mode-{id}"))
                    .small()
                    .icon(match id {
                        "once" => IconName::Square,
                        "loop" => IconName::RotateCw,
                        _ => IconName::RefreshCw,
                    })
                    .tooltip(settings_copy(locale, label))
                    .accessibility_label(settings_copy(locale, label))
                    .disabled(video["mode"].as_str() == Some(id))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.commands
                            .push(json!({"op":"video.mode","value":id}));
                        cx.notify();
                    })),
            );
        }
        section = section
            .child(modes)
            .child(
                h_flex()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .w_full()
                    .child(ui::body(settings_copy(locale, "视频亮度")))
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(Slider::new(&self.video_brightness)),
                    ),
            );
        v_flex()
            .gap(px(metrics::SECTION_CONTENT_GAP))
            .w_full()
            .child(section)
            .into_any_element()
    }

    /// The Wish-machine section. The Unity host consumes `generation.*`; the
    /// product host consumes `space.prop.*` on the same two inputs.
    fn wish_machine_section(&self, locale: UiLocale, cx: &mut Context<Self>) -> SettingsSection {
        if self.unity_external {
            let generation = &self.snapshot["generation"];
            let configured = generation["configured"].as_bool() == Some(true);
            let checking = generation["checking"].as_bool() == Some(true);
            let replacement_empty = self.extra_inputs[6].read(cx).value().is_empty();
            let mut section = SettingsSection::new(settings_copy(locale, "许愿机"))
                .child(
                    Input::new(&self.extra_inputs[5])
                        .accessibility_id("settings.space.generation.endpoint")
                        .aria_label(settings_copy(locale, "生成服务地址")),
                )
                .child(
                    Input::new(&self.extra_inputs[6])
                        .accessibility_id("settings.space.generation.key")
                        .aria_label(settings_copy(locale, "生成服务密钥")),
                )
                .child(
                    h_flex()
                        .items_center()
                        .gap(px(metrics::ROW_GAP))
                        .w_full()
                        .child(
                            h_flex()
                                .flex_1()
                                .items_center()
                                .gap(px(tokens::SPACING_4))
                                .text_color(rgba(if configured { s::ACCENT } else { s::TEXT_MUTED }))
                                .child(check_icon(configured))
                                .child(ui::muted(settings_copy(
                                    locale,
                                    if configured { "已配置" } else { "未配置" },
                                ))),
                        )
                        .child(
                            Button::new("generation-check")
                                .small()
                                .icon(IconName::Network)
                                .tooltip(settings_copy(
                                    locale,
                                    if checking { "检测中…" } else { "检测连接" },
                                ))
                                .accessibility_label(settings_copy(
                                    locale,
                                    if checking { "检测中…" } else { "检测连接" },
                                ))
                                .accessibility_id("settings.space.generation.check")
                                .disabled(!generation_check_enabled(
                                    configured,
                                    checking,
                                    replacement_empty,
                                ))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.commands.push(json!({"op":"generation.check"}));
                                    cx.notify();
                                })),
                        )
                        .child(
                            Button::new("generation-save")
                                .small()
                                .primary()
                                .icon(IconName::Check)
                                .tooltip(settings_copy(locale, "保存"))
                                .accessibility_label(settings_copy(locale, "保存"))
                                .accessibility_id("settings.space.generation.save")
                                .disabled(!generation_save_enabled(
                                    self.extra_inputs[5].read(cx).value().as_str(),
                                    checking,
                                ))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.commands.push(json!({"op":"generation.save","endpoint":this.extra_inputs[5].read(cx).value().to_string(),"token":this.extra_inputs[6].read(cx).value().to_string()}));
                                    cx.notify();
                                })),
                        ),
                )
                .child(row_detail(settings_copy(
                    locale,
                    "地址和密钥只存在这台电脑上，保存后不会立刻开始生成。",
                )));
            if let Some(code) = generation["noticeCode"].as_str() {
                section = section.child(ui::notice(settings_notice(locale, code)));
            }
            return section;
        }
        let configured_prop =
            self.snapshot["space"]["propCredentialConfigured"].as_bool() == Some(true);
        let prop_checking = self.snapshot["space"]["propChecking"].as_bool() == Some(true);
        let prop_save_supported = self.op_supported("space.prop.save");
        let prop_check_supported = self.op_supported("space.prop.check");
        // The product host (`ProductSettingsParity.swift`) is the only owner of
        // `space.prop.save` / `space.prop.check` in this branch. When the
        // whitelist does not carry them, the form and its two buttons are not
        // drawn instead of being drawn and answered with
        // 「当前运行时不支持此操作」. (The Unity window renders the same two
        // inputs through `generation.*` above, and the overlay translates
        // `space.prop.*` onto it if a host ever publishes those names instead.)
        if !prop_save_supported && !prop_check_supported {
            return SettingsSection::new(settings_copy(locale, "许愿机")).child(ui::muted(
                settings_copy(locale, "当前运行时不提供许愿机配置。"),
            ));
        }
        let prop_row = h_flex()
            .items_center()
            .gap(px(metrics::ROW_GAP))
            .w_full()
            .child(
                h_flex()
                    .flex_1()
                    .items_center()
                    .gap(px(tokens::SPACING_4))
                    .text_color(rgba(if configured_prop {
                        s::ACCENT
                    } else {
                        s::TEXT_MUTED
                    }))
                    .child(check_icon(configured_prop))
                    .child(ui::muted(settings_copy(
                        locale,
                        if configured_prop { "已配置" } else { "未配置" },
                    ))),
            )
            .when(prop_check_supported, |row| {
                row.child(
                    Button::new("prop-check")
                        .icon(IconName::Network)
                        .tooltip(settings_copy(
                            locale,
                            if prop_checking { "检测中…" } else { "检测连接" },
                        ))
                        .accessibility_label(settings_copy(
                            locale,
                            if prop_checking { "检测中…" } else { "检测连接" },
                        ))
                        .small()
                        .accessibility_id("settings.space.prop.check")
                        .disabled(!prop_check_enabled(
                            configured_prop,
                            prop_checking,
                            self.extra_inputs[6].read(cx).value().is_empty(),
                        ))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.commands.push(json!({"op":"space.prop.check","endpoint":this.extra_inputs[5].read(cx).value().to_string()}))
                        })),
                )
            })
            .when(prop_save_supported, |row| {
                row.child(
                    Button::new("prop-save")
                        .primary()
                        .icon(IconName::Check)
                        .tooltip(settings_copy(locale, "保存"))
                        .accessibility_label(settings_copy(locale, "保存"))
                        .accessibility_id("settings.space.prop.save")
                        .disabled(!prop_save_enabled(
                            self.extra_inputs[5].read(cx).value().as_str(),
                        ))
                        .on_click(cx.listener(|this, _, _, cx| {
                            let endpoint = this.extra_inputs[5].read(cx).value().to_string();
                            let key = this.extra_inputs[6].read(cx).value().to_string();
                            this.pending_prop = Some((
                                this.snapshot["space"]["propSaveRevision"]
                                    .as_u64()
                                    .unwrap_or(0),
                                endpoint.clone(),
                                key.clone(),
                            ));
                            this.commands.push(json!({"op":"space.prop.save","endpoint":endpoint,"apiKey":key}));
                        })),
                )
            });
        SettingsSection::new(settings_copy(locale, "许愿机"))
            .child(
                Input::new(&self.extra_inputs[5])
                    .accessibility_id("settings.space.prop.endpoint")
                    .aria_label(settings_copy(locale, "生成服务地址")),
            )
            .child(
                Input::new(&self.extra_inputs[6])
                    .accessibility_id("settings.space.prop.key")
                    .aria_label(settings_copy(locale, "生成服务密钥")),
            )
            .child(prop_row)
            .child(row_detail(settings_copy(
                locale,
                "地址和密钥只存在这台电脑上，保存后不会立刻开始生成。",
            )))
    }

    fn presence_page(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let mut roles = SettingsSection::new(settings_copy(locale, "角色"))
            .visible(self.group_visible("角色"));
        for package in self.snapshot["presence"]["packages"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let id = package["id"].clone();
            let name = package["name"].as_str().unwrap_or("").to_owned();
            let mut row = h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .py(px(metrics::ROW_PADDING_V))
                .w_full()
                .child(presence_preview(package))
                .child(
                    v_flex()
                        .flex_1()
                        .min_w(px(0.))
                        .gap(px(metrics::HEADER_TITLE_GAP))
                        .child(row_title(name.clone()))
                        .child(row_detail(if package["isBuiltIn"].as_bool() == Some(true) {
                            format!(
                                "{} · {}",
                                settings_copy(locale, "内置"),
                                settings_copy(
                                    locale,
                                    match package["engine"].as_str() {
                                        Some("orb") => "呼吸球",
                                        Some("pmx") => "PMX",
                                        Some("vrm") => "VRM",
                                        Some("live2D" | "live2d") => "Live2D",
                                        _ => "",
                                    },
                                )
                            )
                        } else {
                            avatar_detail(package)
                        })),
                );
            match presence_action(
                package["isActive"].as_bool() == Some(true),
                package["rendererAvailable"].as_bool() != Some(false),
            ) {
                PresenceAction::Active => {
                    row = row.child(
                        h_flex()
                            .items_center()
                            .gap(px(tokens::SPACING_4))
                            .flex_shrink_0()
                            .text_color(rgba(s::ACCENT))
                            .child(
                                Icon::new(IconName::CircleCheck).size(px(metrics::NOTICE_ICON)),
                            )
                            .child(ui::muted(settings_copy(locale, "当前角色"))),
                    );
                }
                PresenceAction::Waiting => {
                    row = row.child(ui::muted(format!(
                        "{} · {}",
                        settings_copy(locale, "等待渲染"),
                        settings_copy(
                            locale,
                            match package["engine"].as_str() {
                                Some("orb") => "呼吸球",
                                Some("pmx") => "PMX",
                                Some("vrm") => "VRM",
                                Some("live2d") => "Live2D",
                                _ => "当前引擎",
                            },
                        )
                    )));
                }
                PresenceAction::Select => {
                    row = row.child(
                        Button::new(format!("avatar-{id}"))
                            .icon(IconName::Check)
                            .tooltip(settings_copy(locale, "选择"))
                            .small()
                            .accessibility_id(format!("settings.presence.select.{id}"))
                            .accessibility_label(format!(
                                "{}「{name}」",
                                settings_copy(locale, "选择")
                            ))
                            .on_click(cx.listener({
                                let id = id.clone();
                                move |this, _, _, cx| {
                                    this.commands
                                        .push(json!({"op":"presence.activate","id":id}));
                                    cx.notify();
                                }
                            })),
                    );
                }
            }
            if package["isBuiltIn"].as_bool() == Some(false) {
                row = row.child(self.remove_menu(
                    format!("remove-avatar-{id}"),
                    "移除角色",
                    if name.is_empty() {
                        settings_copy(locale, "未命名角色")
                    } else {
                        &name
                    },
                    json!({"op":"presence.remove","id":id}),
                    cx,
                ));
            }
            roles = roles.child(row);
        }

        let mut motions = SettingsSection::new(settings_copy(locale, "动作"))
            .visible(self.group_visible("动作"))
            .row_gap(metrics::ROW_GAP);
        let categories = self.options("presence", "categories");
        let weak = cx.entity().downgrade();
        let category_values: Vec<_> = std::iter::once((json!(""), settings_copy(locale, "全部").to_owned()))
            .chain(categories)
            .collect();
        let selected = category_values
            .iter()
            .position(|(id, _)| id.as_str() == Some(&self.motion_category))
            .unwrap_or(0);
        motions = motions.child(
            TabBar::new("settings.presence.motion-category")
                .segmented()
                .small()
                .w_full()
                .selected_index(selected)
                .children(category_values.iter().map(|(_, name)| {
                    Tab::new()
                        .flex_1()
                        .min_w(px(0.))
                        .aria_label(name.clone())
                        .child(
                            div()
                                .text_size(px(tokens::CAPTION))
                                .min_w(px(0.))
                                .whitespace_nowrap()
                                .child(name.clone()),
                        )
                }))
                .on_click(move |index, _, cx| {
                    _ = weak.update(cx, |this, cx| {
                        this.motion_category =
                            category_values[*index].0.as_str().unwrap_or("").to_owned();
                        cx.notify();
                    });
                }),
        );
        if let Some(notice) = self.snapshot["presence"]["motionNotice"].as_str() {
            motions = motions.child(ui::notice(settings_notice(locale, notice)));
        }
        if !self.motion_category.is_empty()
            && self.snapshot["presence"]["motionNotice"].is_null()
            && !self.snapshot["presence"]["motions"]
                .as_array()
                .into_iter()
                .flatten()
                .any(|m| m["category"].as_str() == Some(&self.motion_category))
        {
            motions = motions.child(ui::muted(settings_copy(
                locale,
                "这个分类下暂无当前角色可用的动作。",
            )));
        }
        for motion in self.snapshot["presence"]["motions"]
            .as_array()
            .into_iter()
            .flatten()
        {
            if !self.motion_category.is_empty()
                && motion["category"].as_str() != Some(&self.motion_category)
            {
                continue;
            }
            let id = motion["id"].clone();
            let compatible = motion["compatible"].as_bool().unwrap_or(false);
            let active = motion["active"].as_bool().unwrap_or(false);
            let name = if motion["id"].as_str() == Some("builtin.motion.natural-idle") {
                settings_copy(locale, "自然待机").to_owned()
            } else {
                motion["name"].as_str().unwrap_or("").to_owned()
            };
            let mut row = h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .py(px(metrics::ROW_PADDING_V))
                .w_full()
                .child(
                    div()
                        .size(px(metrics::MOTION_ICON_BOX))
                        .flex_shrink_0()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(metrics::MOTION_ICON_RADIUS))
                        .bg(rgba(if compatible { s::ACCENT } else { s::ICON })
                            .opacity(metrics::MOTION_ICON_ALPHA))
                        .text_color(rgba(if compatible { s::ACCENT } else { s::TEXT_MUTED }))
                        .child(Icon::new(IconName::Activity).size(px(metrics::MOTION_ICON_SIZE))),
                )
                .child(
                    v_flex()
                        .flex_1()
                        .min_w(px(0.))
                        .gap(px(metrics::HEADER_TITLE_GAP))
                        .child(row_title(name))
                        .child(row_detail(format!(
                            "{}{}",
                            settings_copy(
                                locale,
                                motion_format(motion["format"].as_str().unwrap_or(""))
                            ),
                            motion["reason"]
                                .as_str()
                                .filter(|s| !s.is_empty())
                                .map(|s| format!(" · {}", settings_notice(locale, s)))
                                .unwrap_or_default()
                        ))),
                );
            match motion_action(active, compatible) {
                MotionAction::Current => {
                    row = row.child(
                        h_flex()
                            .items_center()
                            .gap(px(tokens::SPACING_4))
                            .flex_shrink_0()
                            .text_color(rgba(s::ACCENT))
                            .child(
                                Icon::new(IconName::CircleCheck).size(px(metrics::NOTICE_ICON)),
                            )
                            .child(ui::muted(settings_copy(locale, "当前动作"))),
                    );
                }
                MotionAction::Select { enabled } => {
                    row = row.child(
                        Button::new(format!("motion-{id}"))
                            .icon(IconName::Check)
                            .tooltip(settings_copy(locale, "选择"))
                            .small()
                            .disabled(!enabled)
                            .accessibility_id(format!("settings.presence.motion.{id}"))
                            .on_click(cx.listener({
                                let id = id.clone();
                                move |this, _, _, _| {
                                    this.commands.push(json!({"op":"presence.motion","id":id}))
                                }
                            })),
                    );
                }
            }
            if motion["isBuiltIn"].as_bool() == Some(false) {
                let motion_name = motion["name"].as_str().unwrap_or("").to_owned();
                row = row.child(self.remove_menu(
                    format!("remove-motion-{id}"),
                    "移除动作",
                    if motion_name.is_empty() {
                        settings_copy(locale, "未命名动作")
                    } else {
                        &motion_name
                    },
                    json!({"op":"presence.motion.remove","id":id}),
                    cx,
                ));
            }
            motions = motions.child(row);
        }
        motions = motions.child(ui::muted(settings_copy(
            locale,
            "两种角色各有自己的动作列表，切换时会分别记住你选的。",
        )));

        let mut catalog = SettingsSection::new(settings_copy(locale, "动作库"))
            .visible(self.group_visible("动作库"));
        catalog = catalog.child(
            h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .w_full()
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .child(
                            Input::new(&self.extra_inputs[3])
                                .accessibility_id("settings.presence.catalog")
                                .aria_label(settings_copy(locale, "动作目录地址")),
                        ),
                )
                .child(
                    Button::new("catalog-refresh")
                        .icon(IconName::RefreshCw)
                        .tooltip(settings_copy(locale, "获取动作列表"))
                        .accessibility_label(settings_copy(locale, "获取动作列表"))
                        .small()
                        .disabled(
                            self.snapshot["presence"]["working"].as_bool() == Some(true)
                                || self.extra_inputs[3].read(cx).value().trim().is_empty(),
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.commands.push(json!({"op":"presence.catalog","url":this.extra_inputs[3].read(cx).value().to_string()}))
                        })),
                ),
        );
        for motion in self.snapshot["presence"]["publishedMotions"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let identity = motion["catalogIdentity"].clone();
            let mut row = h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .w_full()
                .child(
                    div()
                        .w(px(metrics::PUBLISHED_ICON_BOX))
                        .flex_shrink_0()
                        .child(
                            Icon::new(if motion["loop"].as_bool() == Some(true) {
                                IconName::Repeat
                            } else {
                                IconName::Activity
                            })
                            .size(px(metrics::PUBLISHED_ICON_SIZE)),
                        ),
                )
                .child(
                    v_flex()
                        .flex_1()
                        .min_w(px(0.))
                        .gap(px(metrics::HEADER_TITLE_GAP))
                        .child(row_title(motion["name"].as_str().unwrap_or("").to_owned()))
                        .child(row_detail(format!(
                            "{} {} · {:.1} {}",
                            settings_copy(locale, "版本"),
                            motion["version"].as_str().unwrap_or(""),
                            motion["duration"].as_f64().unwrap_or(0.),
                            settings_copy(locale, "秒")
                        ))),
                );
            if motion["installLabel"].as_str() == Some("已安装") {
                row = row.child(
                    h_flex()
                        .items_center()
                        .gap(px(tokens::SPACING_4))
                        .flex_shrink_0()
                        .text_color(rgba(s::ACCENT))
                        .child(Icon::new(IconName::CircleCheck).size(px(metrics::NOTICE_ICON)))
                        .child(ui::muted(settings_copy(locale, "已安装"))),
                );
            } else {
                row = row.child(
                    Button::new(format!("install-motion-{identity}"))
                        .icon(IconName::Plus)
                        .tooltip(
                            settings_copy(
                                locale,
                                motion["installLabel"].as_str().unwrap_or("安装"),
                            )
                            .to_owned(),
                        )
                        .accessibility_label(
                            settings_copy(
                                locale,
                                motion["installLabel"].as_str().unwrap_or("安装"),
                            )
                            .to_owned(),
                        )
                        .small()
                        .disabled(self.snapshot["presence"]["working"].as_bool() == Some(true))
                        .on_click(cx.listener(move |this, _, _, _| {
                            this.commands.push(
                                json!({"op":"presence.motion.install","catalogIdentity":identity}),
                            )
                        })),
                );
            }
            catalog = catalog.child(row);
        }

        let mut page = v_flex()
            .gap(px(metrics::SECTION_CONTENT_GAP))
            .w_full();
        // The Unity 角色管理 section also carries the character position form.
        if self.unity_external && self.section == "角色管理" {
            page = page.child(self.character_position_form(locale, cx));
        }
        page = page.child(roles).child(motions).child(catalog);
        if self.snapshot["presence"]["activeEngine"].as_str() == Some("orb") {
            page = page.child(
                SettingsSection::new(settings_copy(locale, "呼吸球样式"))
                    .visible(self.group_visible("呼吸球样式"))
                    .child(
                        h_flex()
                            .items_center()
                            .gap(px(metrics::ROW_GAP))
                            .w_full()
                            .child(ui::body(settings_copy(locale, "流光颜色")))
                            .child(div().flex_1().child(ColorPicker::new(&self.orb_color))),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap(px(metrics::ROW_GAP))
                            .w_full()
                            .child(ui::body(settings_copy(locale, "流光强度")))
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .child(Slider::new(&self.orb_intensity)),
                            )
                            .child(
                                div()
                                    .w(px(metrics::ORB_PERCENT_WIDTH))
                                    .flex_shrink_0()
                                    .child(ui::muted(format!(
                                        "{}%",
                                        orb_intensity_percent(
                                            self.orb_intensity.read(cx).value().start()
                                        )
                                    ))),
                            ),
                    ),
            );
        }
        page.into_any_element()
    }

    fn music_page(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let mut services = SettingsSection::new(settings_copy(locale, "音乐服务"))
            .visible(self.group_visible("音乐服务"))
            .row_gap(0.);
        for (index, provider) in self.snapshot["music"]["providers"]
            .as_array()
            .into_iter()
            .flatten()
            .enumerate()
        {
            if index > 0 {
                services = services.child(ui::divider());
            }
            let id = provider["id"].clone();
            let connected = provider["connected"].as_bool().unwrap_or(false);
            let working = self.snapshot["music"]["working"].as_bool().unwrap_or(false);
            let syncing = provider["syncing"].as_bool() == Some(true);
            let status = provider["status"].as_str();
            let mut row = h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .py(px(metrics::MUSIC_ROW_PADDING_V))
                .w_full()
                .child(
                    div()
                        .size(px(metrics::PROVIDER_ICON_BOX))
                        .flex_shrink_0()
                        .flex()
                        .items_center()
                        .justify_center()
                        .rounded(px(metrics::PROVIDER_ICON_RADIUS))
                        .bg(rgba(s::ACCENT).opacity(metrics::PROVIDER_ICON_ALPHA))
                        .text_color(rgba(s::ACCENT))
                        .child(
                            Icon::new(match id.as_str() {
                                Some("qq-music") => IconName::ListMusic,
                                Some("apple-music") => IconName::Apple,
                                _ => IconName::Music,
                            })
                            .size(px(metrics::PROVIDER_ICON_SIZE)),
                        ),
                )
                .child(
                    v_flex()
                        .flex_1()
                        .min_w(px(0.))
                        .gap(px(tokens::SPACING_4))
                        .child(row_title(provider["name"].as_str().unwrap_or("").to_owned()))
                        .child(row_detail(settings_copy(
                            locale,
                            music_status_label(status),
                        ))),
                );
            if music_row_authorizing(status) {
                row = row.child(Spinner::new().small().color(rgba(s::TEXT_MUTED).into()));
            } else {
                let mut buttons = h_flex()
                    .items_center()
                    .gap(px(tokens::SPACING_8))
                    .flex_shrink_0();
                if connected {
                    buttons = buttons.child(
                        Button::new(format!("sync-{id}"))
                            .ghost()
                            .small()
                            .icon(if syncing {
                                IconName::Loader
                            } else {
                                IconName::RefreshCw
                            })
                            .tooltip(if syncing {
                                settings_copy(locale, "正在同步…")
                            } else {
                                settings_copy(locale, "同步")
                            })
                            .accessibility_label(if syncing {
                                settings_copy(locale, "正在同步…")
                            } else {
                                settings_copy(locale, "同步")
                            })
                            .accessibility_id(format!("settings.music.sync.{id}"))
                            .disabled(working || syncing)
                            .on_click(cx.listener({
                                let id = id.clone();
                                move |this, _, _, cx| {
                                    if let Some(provider) = this.snapshot["music"]["providers"]
                                        .as_array()
                                        .into_iter()
                                        .flatten()
                                        .find(|provider| provider["id"] == id)
                                    {
                                        if let Some(command) = music_sync_command(
                                            provider,
                                            this.snapshot["music"]["working"].as_bool()
                                                == Some(true),
                                        ) {
                                            this.commands.push(command);
                                            cx.notify();
                                        }
                                    }
                                }
                            })),
                    );
                }
                buttons = buttons.child(
                    Button::new(format!("account-{id}"))
                        .small()
                        .when(connected, |button| button.ghost())
                        .icon(IconName::ExternalLink)
                        .tooltip(settings_copy(locale, music_connect_label(connected)))
                        .accessibility_label(settings_copy(locale, music_connect_label(connected)))
                        .accessibility_id(format!("settings.music.connect.{id}"))
                        .disabled(working)
                        .on_click(cx.listener({
                            let id = id.clone();
                            move |this, _, _, _| {
                                this.commands.push(json!({
                                    "op": if connected { "music.disconnect" } else { "music.connect" },
                                    "id": id
                                }))
                            }
                        })),
                );
                row = row.child(buttons);
            }
            services = services.child(row);
        }
        if self.unity_external {
            services = services.child(ui::muted(settings_copy(
                locale,
                "同步完成后，音乐库会显示最新歌单。",
            )));
        }
        v_flex()
            .gap(px(metrics::SECTION_CONTENT_GAP))
            .w_full()
            .child(services)
            .into_any_element()
    }

    fn space_page(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let unity = self.unity_external;
        let space_entry = self.page == PAGE_SPACE;
        let configured = self.snapshot["space"]["credentialConfigured"].as_bool() == Some(true);
        let detail = self.snapshot["space"]["options"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|value| value["id"] == self.draft["space"]["defaultSpace"])
            .and_then(|value| value["detail"].as_str())
            .unwrap_or("");
        let default_space = SettingsSection::new(settings_copy(locale, "默认空间"))
            .visible((!unity || space_entry) && self.group_visible("默认空间"))
            .child(self.dropdown(
                "default-space",
                "启动时进入",
                "space",
                "defaultSpace",
                self.options("space", "options"),
                cx,
            ))
            .child(row_detail(detail.to_owned()))
            .child(row_detail(settings_copy(locale, "修改后下次启动生效。")));

        let mut credential = SettingsSection::new(settings_copy(locale, "Marble 空间"))
            .visible(!unity || space_entry)
            .child(
                h_flex()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .w_full()
                    .child(
                        div()
                            .w(px(metrics::MARBLE_ICON_COLUMN))
                            .flex_shrink_0()
                            .text_color(rgba(s::ACCENT))
                            .child(Icon::new(IconName::Box).size(px(metrics::MARBLE_ICON_SIZE))),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w(px(0.))
                            .gap(px(tokens::SPACING_4))
                            .child(row_title("World Labs Marble"))
                            .child(row_detail(settings_copy(
                                locale,
                                "用于同步和生成可探索的 3D 空间",
                            ))),
                    )
                    .child(
                        h_flex()
                            .items_center()
                            .gap(px(tokens::SPACING_4))
                            .flex_shrink_0()
                            .text_color(rgba(if configured { s::ACCENT } else { s::TEXT_MUTED }))
                            .child(check_icon(configured))
                            .child(ui::muted(settings_copy(
                                locale,
                                if configured { "已配置" } else { "未配置" },
                            ))),
                    ),
            )
            .child(
                Input::new(&self.extra_inputs[2])
                    .accessibility_id("settings.space.marble.key")
                    .aria_label(settings_copy(locale, "新的 Marble API Key")),
            )
            .child(
                h_flex()
                    .items_center()
                    .justify_between()
                    .gap(px(metrics::ROW_GAP))
                    .w_full()
                    .child(ui::muted(settings_copy(locale, "只保存在本机，不使用钥匙串。")))
                    .child(
                        h_flex()
                            .items_center()
                            .gap(px(tokens::SPACING_8))
                            .flex_shrink_0()
                            .when(configured, |row| {
                                row.child(self.command_button(
                                    "marble-clear",
                                    "清除",
                                    json!({"op":"space.key.clear"}),
                                    cx,
                                ))
                            })
                            .child(
                                Button::new("marble-save")
                                    .primary()
                                    .icon(IconName::Check)
                                    .tooltip(settings_copy(locale, "保存 Key"))
                                    .accessibility_label(settings_copy(locale, "保存 Key"))
                                    .accessibility_id("settings.space.marble.save")
                                    .disabled(!marble_save_enabled(
                                        self.extra_inputs[2].read(cx).value().as_str(),
                                    ))
                                    .on_click(cx.listener(|this, _, _, cx| {
                                        let key = this.extra_inputs[2].read(cx).value().to_string();
                                        this.pending_marble = Some((
                                            this.snapshot["space"]["marbleMutationRevision"]
                                                .as_u64()
                                                .unwrap_or(0),
                                            key.clone(),
                                        ));
                                        this.commands
                                            .push(json!({"op":"space.key.save","apiKey":key}));
                                        cx.notify();
                                    })),
                            ),
                    ),
            );
        if let Some(message) = self.snapshot["space"]["marbleMessage"].as_str() {
            credential = credential.child(if self.snapshot["space"]["marbleHasError"].as_bool()
                == Some(true)
            {
                ui::notice(message.to_owned())
            } else {
                ui::muted(message.to_owned())
            });
        }

        let library = &self.snapshot["spaceLibrary"];
        let mut spaces = SettingsSection::new(settings_copy(locale, "我的空间"))
            .visible(space_library_visible(
                &self.snapshot,
                unity,
                space_entry,
                self.group_visible("我的空间"),
            ))
            .child(self.command_button(
                "space-library-refresh",
                "刷新",
                json!({"op":"space.library.load"}),
                cx,
            ));
        let library_working = library["working"].as_bool() == Some(true);
        for world in library["worlds"].as_array().into_iter().flatten() {
            let Some(id) = world["id"].as_str() else {
                continue;
            };
            let selected = world["selected"].as_bool() == Some(true);
            let id = id.to_owned();
            spaces = spaces.child(
                h_flex()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .w_full()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(ui::body(world["name"].as_str().unwrap_or(&id).to_owned())),
                    )
                    .child(
                        Button::new(format!("space-library-{id}"))
                            .small()
                            .icon(if selected { IconName::Check } else { IconName::Play })
                            .tooltip(settings_copy(
                                locale,
                                if selected { "使用中" } else { "选择" },
                            ))
                            .accessibility_label(settings_copy(
                                locale,
                                if selected { "使用中" } else { "选择" },
                            ))
                            .accessibility_id(format!("settings.space.library.{id}"))
                            .disabled(library_working || selected)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.commands
                                    .push(json!({"op":"space.library.select","id":id}));
                                cx.notify();
                            })),
                    ),
            );
        }
        if let Some(code) = library["noticeCode"].as_str() {
            spaces = spaces.child(ui::notice(settings_notice(locale, code)));
        }
        for world in library["marbleWorlds"].as_array().into_iter().flatten() {
            spaces = spaces.child(ui::body(world["name"].as_str().unwrap_or("").to_owned()));
        }
        if let Some(code) = library["marbleNoticeCode"].as_str() {
            spaces = spaces.child(ui::notice(settings_notice(locale, code)));
        }

        let supported = library["generationSupported"].as_bool() == Some(true);
        let marble_working = library["marbleWorking"].as_bool() == Some(true);
        let pending = library["marbleOperationID"]
            .as_str()
            .filter(|id| !id.is_empty());
        let mut marble = SettingsSection::new(settings_copy(locale, "生成与导入空间"))
            .visible((!unity || space_entry) && self.group_visible("生成与导入空间"))
            .child(row_detail(settings_copy(
                locale,
                "生成会调用付费 Marble API；仅点击生成按钮时提交。",
            )));
        if !supported {
            marble = marble.child(row_detail(settings_copy(
                locale,
                "当前运行时不支持 Marble 空间生成与导入。",
            )));
        }
        if let Some(id) = pending {
            marble = marble
                .child(row_detail(format!(
                    "{}: {id}",
                    settings_copy(locale, "生成任务 ID")
                )))
                .child(row_detail(settings_copy(
                    locale,
                    "已有生成回执，请恢复原任务；不会重复提交付费生成。",
                )));
        }
        for preset in library["marblePresets"].as_array().into_iter().flatten() {
            let Some(id) = preset["id"].as_str() else {
                continue;
            };
            let enabled = configured && marble_command(library, "space.marble.generate", id).is_some();
            let id = id.to_owned();
            marble = marble.child(
                h_flex()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .w_full()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(ui::body(preset["name"].as_str().unwrap_or(&id).to_owned())),
                    )
                    .child(
                        Button::new(format!("marble-generate-{id}"))
                            .small()
                            .icon(IconName::Star)
                            .tooltip(settings_copy(locale, "生成（付费）"))
                            .accessibility_label(settings_copy(locale, "生成（付费）"))
                            .accessibility_id(format!("settings.space.marble.generate.{id}"))
                            .disabled(!enabled)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if let Some(command) = marble_command(
                                    &this.snapshot["spaceLibrary"],
                                    "space.marble.generate",
                                    &id,
                                ) {
                                    this.commands.push(command);
                                    cx.notify();
                                }
                            })),
                    ),
            );
        }
        marble = marble.child(
            h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .w_full()
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .child(
                            Input::new(&self.extra_inputs[7])
                                .accessibility_id("settings.space.marble.world")
                                .aria_label(settings_copy(locale, "Marble World ID")),
                        ),
                )
                .child(
                    Button::new("marble-import")
                        .icon(IconName::ArrowDown)
                        .tooltip(settings_copy(locale, "按 World ID 导入"))
                        .accessibility_label(settings_copy(locale, "按 World ID 导入"))
                        .small()
                        .accessibility_id("settings.space.marble.import")
                        .disabled(
                            !configured
                                || marble_command(
                                    library,
                                    "space.marble.import",
                                    self.extra_inputs[7].read(cx).value().as_str(),
                                )
                                .is_none(),
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            let id = this.extra_inputs[7].read(cx).value().to_string();
                            if let Some(command) = marble_command(
                                &this.snapshot["spaceLibrary"],
                                "space.marble.import",
                                &id,
                            ) {
                                this.commands.push(command);
                                cx.notify();
                            }
                        })),
                ),
        );
        let mut controls = h_flex().items_center().gap(px(tokens::SPACING_8));
        if pending.is_some() {
            controls = controls.child(
                Button::new("marble-resume")
                    .icon(IconName::Undo2)
                    .tooltip(settings_copy(locale, "恢复原任务"))
                    .accessibility_label(settings_copy(locale, "恢复原任务"))
                    .small()
                    .disabled(
                        !configured
                            || marble_command(library, "space.marble.resume", "").is_none(),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(command) = marble_command(
                            &this.snapshot["spaceLibrary"],
                            "space.marble.resume",
                            "",
                        ) {
                            this.commands.push(command);
                            cx.notify();
                        }
                    })),
            );
        }
        if marble_working {
            controls = controls.child(
                Button::new("marble-cancel")
                    .icon(IconName::CircleX)
                    .tooltip(settings_copy(locale, "取消本机等待"))
                    .accessibility_label(settings_copy(locale, "取消本机等待"))
                    .small()
                    .on_click(cx.listener(|this, _, _, cx| {
                        if let Some(command) = marble_command(
                            &this.snapshot["spaceLibrary"],
                            "space.marble.cancel",
                            "",
                        ) {
                            this.commands.push(command);
                            cx.notify();
                        }
                    })),
            );
            marble = marble.child(row_detail(settings_copy(
                locale,
                "取消仅停止本机等待，远端生成可能继续并计费。",
            )));
        }
        marble = marble.child(controls);
        let phase = marble_phase_label(library["marblePhase"].as_str().unwrap_or(""));
        if !phase.is_empty() {
            marble = marble.child(row_detail(settings_copy(locale, phase)));
        }
        if let Some(progress) = library["marbleProgress"]
            .as_f64()
            .filter(|value| value.is_finite())
        {
            marble = marble.child(row_detail(format!(
                "{}: {:.0}%",
                settings_copy(locale, "生成进度"),
                progress.clamp(0., 100.)
            )));
        }
        if let Some(id) = library["marbleWorldID"].as_str().filter(|id| !id.is_empty()) {
            marble = marble.child(row_detail(format!("World ID: {id}")));
        }
        if let Some(error) = library["marbleError"]
            .as_str()
            .filter(|error| !error.is_empty())
        {
            marble = marble.child(ui::notice(error.to_owned()));
        }

        let prop = self
            .wish_machine_section(locale, cx)
            .visible(!unity || !space_entry);

        v_flex()
            .gap(px(metrics::SECTION_CONTENT_GAP))
            .w_full()
            .child(default_space)
            .child(credential)
            .child(spaces)
            .child(marble)
            .child(prop)
            .into_any_element()
    }

    fn shortcuts_page(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let mut grid = SettingsSection::new("").row_gap(0.);
        grid = grid.child(
            h_flex()
                .items_center()
                .gap(px(metrics::SHORTCUT_GRID_GAP))
                .w_full()
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .child(ui::muted(settings_copy(locale, "功能"))),
                )
                .child(
                    div()
                        .w(px(metrics::SHORTCUT_COLUMN_WIDTH))
                        .flex_shrink_0()
                        .child(ui::muted(settings_copy(locale, "应用内"))),
                )
                .child(
                    div()
                        .w(px(metrics::SHORTCUT_COLUMN_WIDTH))
                        .flex_shrink_0()
                        .child(ui::muted(settings_copy(locale, "全局"))),
                ),
        );
        grid = grid.child(ui::divider());
        for item in self.snapshot["shortcuts"]["assignments"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let id = item["id"].clone();
            let mut row = h_flex()
                .items_center()
                .gap(px(metrics::SHORTCUT_GRID_GAP))
                .py(px(metrics::ROW_PADDING_V))
                .w_full()
                .child(
                    div()
                        .flex_1()
                        .min_w(px(0.))
                        .child(ui::body(
                            settings_copy(locale, item["title"].as_str().unwrap_or(""))
                                .to_owned(),
                        )),
                );
            for scope in ["local", "global"] {
                let recording = self.snapshot["shortcuts"]["recordingID"] == id
                    && self.snapshot["shortcuts"]["recordingScope"].as_str() == Some(scope);
                let label = shortcut_cell_label(
                    recording,
                    item[scope].as_str().unwrap_or(""),
                );
                let label = if label == "请按快捷键" || label == "未设置" {
                    settings_copy(locale, &label).to_owned()
                } else {
                    label
                };
                let tint = ButtonCustomVariant::new(cx)
                    .color(rgba(s::ACCENT).opacity(metrics::RECORDING_TINT_ALPHA).into())
                    .foreground(rgba(s::ACCENT).into())
                    .hover(rgba(s::ACCENT).opacity(metrics::RECORDING_TINT_HOVER_ALPHA).into())
                    .active(
                        rgba(s::ACCENT)
                            .opacity(metrics::RECORDING_TINT_ACTIVE_ALPHA)
                            .into(),
                    );
                row = row.child(
                    div()
                        .w(px(metrics::SHORTCUT_COLUMN_WIDTH))
                        .flex_shrink_0()
                        .child(
                            Button::new(format!("shortcut-{id}-{scope}"))
                                .small()
                                .w_full()
                                .when(recording, |button| button.custom(tint))
                                .accessibility_id(format!("settings.shortcuts.{id}.{scope}"))
                                .accessibility_label(label.clone())
                                .child(
                                    div()
                                        .w(px(metrics::SHORTCUT_TEXT_WIDTH))
                                        .font_family(metrics::MONO_FAMILY)
                                        .text_size(px(metrics::SHORTCUT_TEXT_SIZE))
                                        .child(label),
                                )
                                .on_click(cx.listener({
                                    let id = id.clone();
                                    move |this, _, _, _| {
                                        this.commands.push(json!({"op":"shortcuts.record","id":id,"scope":scope}))
                                    }
                                })),
                        ),
                );
            }
            grid = grid.child(row);
        }

        let mut toggles = SettingsSection::new("");
        toggles = toggles
            .child(
                Switch::new("settings.shortcuts.global")
                    .label(settings_copy(locale, "启用全局快捷键"))
                    .accessibility_label(settings_copy(locale, "启用全局快捷键"))
                    .checked(
                        self.snapshot["shortcuts"]["globalEnabled"]
                            .as_bool()
                            .unwrap_or(false),
                    )
                    .on_change(cx.listener(|this, value: &bool, _, _| {
                        this.commands
                            .push(json!({"op":"shortcuts.global","value":value}))
                    })),
            )
            .child(row_detail(settings_copy(locale, "gmgn radio 在后台时也能响应。")))
            .child(
                Switch::new("settings.shortcuts.media")
                    .label(settings_copy(locale, "使用系统媒体快捷键"))
                    .accessibility_label(settings_copy(locale, "使用系统媒体快捷键"))
                    .checked(
                        self.snapshot["shortcuts"]["mediaKeysEnabled"]
                            .as_bool()
                            .unwrap_or(false),
                    )
                    .on_change(cx.listener(|this, value: &bool, _, _| {
                        this.commands
                            .push(json!({"op":"shortcuts.media","value":value}))
                    })),
            )
            .child(row_detail(settings_copy(
                locale,
                "响应键盘上的播放、暂停、上一首和下一首。",
            )));

        let mut actions = SettingsSection::new("");
        actions = actions.child(
            h_flex()
                .items_center()
                .gap(px(metrics::ROW_GAP))
                .w_full()
                .when_some(
                    self.snapshot["shortcuts"]["validationMessage"].as_str(),
                    |row, message| row.child(ui::notice(settings_notice(locale, message))),
                )
                .child(div().flex_1().min_w(px(0.)))
                .child(self.command_button(
                    "shortcuts-reset",
                    "恢复默认",
                    json!({"op":"shortcuts.reset"}),
                    cx,
                )),
        );

        v_flex()
            .gap(px(metrics::SECTION_CONTENT_GAP))
            .w_full()
            .child(grid)
            .child(toggles)
            .child(actions)
            .into_any_element()
    }

    fn agent_page(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let valid_model = model_in_catalog(
            self.snapshot["tts"]["models"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or(&[]),
            &self.draft["tts"]["modelID"],
        );
        let asr_models = self.snapshot["asr"]["models"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        let asr_valid = model_in_catalog(&asr_models, &self.draft["asr"]["modelID"]);
        let signed_in = self.snapshot["agent"]["codexState"].as_str() == Some("signedIn");
        let working = self.snapshot["agent"]["working"].as_bool() == Some(true);
        let unavailable = self.snapshot["agent"]["codexState"].as_str() == Some("unavailable");

        // 角色内核
        let mut core = SettingsSection::new(settings_copy(locale, "角色内核"))
            .visible(self.agent_group_visible("角色内核"));
        core = core
            .child(
                h_flex()
                    .items_center()
                    .gap(px(metrics::ROW_GAP))
                    .w_full()
                    .child(
                        div()
                            .size(px(metrics::AGENT_ICON_BOX))
                            .flex_shrink_0()
                            .flex()
                            .items_center()
                            .justify_center()
                            .rounded(px(metrics::AGENT_ICON_RADIUS))
                            .bg(rgba(s::ACCENT).opacity(metrics::AGENT_ICON_ALPHA))
                            .text_color(rgba(s::ACCENT))
                            .child(
                                Icon::new(IconName::Terminal).size(px(metrics::AGENT_ICON_SIZE)),
                            ),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w(px(0.))
                            .gap(px(tokens::SPACING_4))
                            .child(row_title(settings_copy(locale, "gmgn 角色")))
                            .child(ui::muted(settings_notice(
                                locale,
                                self.snapshot["agent"]["codexStatus"]
                                    .as_str()
                                    .unwrap_or(settings_copy(locale, "策划引擎未登录")),
                            ))),
                    )
                    .child(
                        Button::new("codex-login")
                            .icon(if signed_in {
                                IconName::CircleUser
                            } else {
                                IconName::User
                            })
                            .tooltip(settings_copy(
                                locale,
                                if signed_in { "退出登录" } else { "登录" },
                            ))
                            .accessibility_label(settings_copy(
                                locale,
                                if signed_in { "退出登录" } else { "登录" },
                            ))
                            .small()
                            .accessibility_id("settings.agent.codex")
                            .disabled(working || unavailable)
                            .on_click(cx.listener(|this, _, _, _| {
                                this.commands.push(json!({
                                    "op": if this.snapshot["agent"]["codexState"].as_str() == Some("signedIn") {
                                        "agent.logout"
                                    } else {
                                        "agent.login"
                                    }
                                }))
                            })),
                    ),
            )
            .child(row_detail(settings_copy(
                locale,
                if self.unity_external {
                    "Codex 账号用于选择 Codex 后端；当前聊天后端以下方选择为准。"
                } else {
                    "Codex 提供策划和推理能力；它与下面的声音共同属于同一个角色。"
                },
            )));
        if !self.unity_external || self.snapshot["unity"]["planningSupported"].as_bool() == Some(true)
        {
            core = core
                .child(self.toggle(
                    "settings.agent.takeover",
                    "允许角色自动接管",
                    "takeoverEnabled",
                    cx,
                ))
                .child(row_detail(settings_copy(
                    locale,
                    "可以自主切歌、暂停、继续、重排节目和调整视觉。",
                )))
                .child(field_row(
                    settings_copy(locale, "策划模型"),
                    div()
                        .w(px(metrics::PLANNING_MODEL_WIDTH))
                        .child(
                            Input::new(&self.inputs[2])
                                .accessibility_id("settings.agent.planning-model")
                                .aria_label(settings_copy(locale, "使用 Codex 默认模型")),
                        ),
                ));
        }

        // 角色人格与偏好
        let persona = SettingsSection::new(settings_copy(locale, "角色人格与偏好"))
            .visible(self.agent_group_visible("角色人格与偏好"))
            .child(
                div()
                    .h(px(metrics::HOST_PROMPT_MIN_HEIGHT))
                    .min_h(px(metrics::HOST_PROMPT_MIN_HEIGHT))
                    .flex_shrink_0()
                    .child(
                        Textarea::new(&self.personas[1])
                            .h(px(metrics::HOST_PROMPT_MIN_HEIGHT))
                            .aria_label(settings_copy(locale, "角色人格与偏好"))
                            .accessibility_id("settings.agent.persona"),
                    ),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap(px(tokens::SPACING_12))
                    .w_full()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(row_detail(settings_copy(
                                locale,
                                "用自然语言告诉角色怎么策划和主持。",
                            ))),
                    )
                    .child(
                        Button::new("save-dj")
                            .flex_shrink_0()
                            .primary()
                            .icon(IconName::Check)
                            .tooltip(settings_copy(locale, "保存"))
                            .accessibility_label(settings_copy(locale, "保存"))
                            .accessibility_id("settings.agent.persona.save")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.commands.push(json!({"op":"agent.save","hostPrompt":this.personas[1].read(cx).value().to_string()}))
                            })),
                    ),
            );

        // 居民人格
        let resident = SettingsSection::new(settings_copy(locale, "居民人格"))
            .visible(self.agent_group_visible("居民人格"))
            .child(
                div()
                    .h(px(metrics::RESIDENT_PROMPT_MIN_HEIGHT))
                    .min_h(px(metrics::RESIDENT_PROMPT_MIN_HEIGHT))
                    .flex_shrink_0()
                    .child(
                        Textarea::new(&self.personas[0])
                            .h(px(metrics::RESIDENT_PROMPT_MIN_HEIGHT))
                            .aria_label(settings_copy(locale, "居民人格"))
                            .accessibility_id("settings.agent.resident-persona"),
                    ),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap(px(tokens::SPACING_12))
                    .w_full()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(row_detail(settings_copy(
                                locale,
                                "只影响居民，和上面的角色偏好分开。人格只改语气和关注点，不改变它能做什么。",
                            ))),
                    )
                    .child(
                        Button::new("save-resident")
                            .flex_shrink_0()
                            .primary()
                            .icon(IconName::Check)
                            .tooltip(settings_copy(locale, "保存"))
                            .accessibility_label(settings_copy(locale, "保存"))
                            .accessibility_id("settings.agent.resident-persona.save")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.commands.push(json!({"op":"agent.save","residentPersona":this.personas[0].read(cx).value().to_string()}))
                            })),
                    ),
            );

        // 聊天模型（原版把自主开关与预算放在这里）
        let mut chat = SettingsSection::new(settings_copy(locale, "聊天模型"))
            .visible(self.agent_group_visible("聊天模型"));
        chat = chat
            .child(self.dropdown(
                "backend",
                "模型",
                "agent",
                "backendID",
                self.options("agent", "backends"),
                cx,
            ))
            .when_some(
                self.snapshot["agent"]["backendStatus"].as_str(),
                |section, status| {
                    section.child(ui::notice(settings_notice(locale, status)))
                },
            )
            .child(row_detail(settings_copy(
                locale,
                "空间和 Live Cam 共用这里选定的 Agent；文字和语音转写进入同一个会话。",
            )));
        if !self.unity_external {
            chat = chat
                .child(self.toggle(
                    "settings.agent.autonomy",
                    "允许居民自主安排活动",
                    "autonomyEnabled",
                    cx,
                ))
                .child(row_detail(settings_copy(
                    locale,
                    "打开后，居民会自己观察和行动，会消耗模型额度。设为 0 就不再新起一轮，要先停下请按停止。",
                )))
                .child(self.dropdown(
                    "budget",
                    "每小时后台思考预算",
                    "agent",
                    "backgroundTurnsPerHour",
                    self.options("agent", "budgetOptions"),
                    cx,
                ))
                .child(row_detail(settings_copy(
                    locale,
                    "按最近一小时算，默认 6。这只数后台思考的次数，不等于请求次数或费用。",
                )));
        }

        // 自主行动（Unity 分区）
        let autonomy = SettingsSection::new(settings_copy(locale, "自主行动"))
            .visible(self.agent_group_visible("自主行动"))
            .child(self.toggle(
                "settings.agent.autonomy-unity",
                "允许居民自主安排活动",
                "autonomyEnabled",
                cx,
            ))
            .child(row_detail(settings_copy(
                locale,
                "打开后，居民会自己观察和行动，会消耗模型额度。设为 0 就不再新起一轮，要先停下请按停止。",
            )))
            .child(self.dropdown(
                "budget-unity",
                "每小时后台思考预算",
                "agent",
                "backgroundTurnsPerHour",
                self.options("agent", "budgetOptions"),
                cx,
            ));

        // 回复语音
        let mut voice = SettingsSection::new(settings_copy(locale, "回复语音"))
            .visible(self.agent_group_visible("回复语音"));
        if !self.unity_external || self.snapshot["unity"]["autoSpeakSupported"].as_bool() == Some(true)
        {
            voice = voice
                .child(self.toggle(
                    "settings.agent.auto-speak",
                    "自动朗读 Agent 回复",
                    "autoSpeak",
                    cx,
                ));
        }
        voice = voice
            .child(self.dropdown(
                "tts-provider",
                "服务",
                "tts",
                "providerID",
                self.options("tts", "providers"),
                cx,
            ))
            .child(field_row(
                "API Key",
                div()
                    .w(px(metrics::KEY_FIELD_WIDTH))
                    .child(
                        Input::new(&self.extra_inputs[0])
                            .accessibility_id("settings.tts.key")
                            .aria_label(settings_copy(locale, "新的 TTS API Key")),
                    ),
            ))
            .child(
                h_flex()
                    .items_center()
                    .gap(px(tokens::SPACING_8))
                    .w_full()
                    .child(
                        div()
                            .flex_1()
                            .min_w(px(0.))
                            .child(self.dropdown(
                                "tts-voice",
                                "声音",
                                "tts",
                                "voiceID",
                                self.options("tts", "voices"),
                                cx,
                            )),
                    )
                    .child(
                        Button::new("refresh-voices")
                            .icon(IconName::RefreshCw)
                            .small()
                            .tooltip(settings_copy(locale, "刷新声音"))
                            .accessibility_label(settings_copy(locale, "刷新声音"))
                            .disabled(self.snapshot["tts"]["loading"].as_bool() == Some(true))
                            .on_click(cx.listener(|this, _, _, cx| this.tts_action("tts.refresh", cx))),
                    )
                    .child(
                        Button::new("preview-tts")
                            .icon(
                                if self.snapshot["tts"]["isSpeaking"].as_bool() == Some(true) {
                                    IconName::Pause
                                } else {
                                    IconName::Play
                                },
                            )
                            .tooltip(settings_copy(
                                locale,
                                if self.snapshot["tts"]["isSpeaking"].as_bool() == Some(true) {
                                    "停止试听"
                                } else {
                                    "试听声音"
                                },
                            ))
                            .accessibility_label(settings_copy(
                                locale,
                                if self.snapshot["tts"]["isSpeaking"].as_bool() == Some(true) {
                                    "停止试听"
                                } else {
                                    "试听声音"
                                },
                            ))
                            .small()
                            .accessibility_id("settings.tts.preview")
                            .disabled(!tts_preview_enabled(
                                valid_model,
                                self.inputs[3].read(cx).value().as_str(),
                            ))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.tts_action(
                                    if this.snapshot["tts"]["isSpeaking"].as_bool() == Some(true) {
                                        "tts.stop"
                                    } else {
                                        "tts.preview"
                                    },
                                    cx,
                                )
                            })),
                    ),
            )
            .child(
                Collapsible::new()
                    .open(self.custom_voice_open)
                    .child(
                        Button::new("custom-voice-disclosure")
                            .ghost()
                            .tooltip(settings_copy(locale, "高级设置"))
                            .accessibility_label(settings_copy(locale, "高级设置"))
                            .icon(if self.custom_voice_open {
                                IconName::ChevronDown
                            } else {
                                IconName::ChevronRight
                            })
                            .small()
                            .accessibility_id("settings.tts.advanced")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.custom_voice_open = !this.custom_voice_open;
                                cx.notify();
                            })),
                    )
                    .content(
                        v_flex()
                            .gap(px(tokens::SPACING_8))
                            .w_full()
                            .child(self.dropdown(
                                "tts-model",
                                "模型",
                                "tts",
                                "modelID",
                                self.options("tts", "models"),
                                cx,
                            ))
                            .child(row_detail(
                                if self.draft["tts"]["providerID"].as_str() == Some("fish") {
                                    settings_copy(locale, "自定义 Reference ID")
                                } else {
                                    settings_copy(locale, "自定义 Voice ID")
                                },
                            ))
                            .child(
                                Input::new(&self.inputs[3])
                                    .accessibility_id("settings.tts.custom-voice")
                                    .aria_label(settings_copy(locale, "自定义音色 ID")),
                            )
                            .child(row_detail(settings_copy(
                                locale,
                                "填写该服务已有的音色 ID，无需重新上传；账号、模型及服务区域须与创建音色时一致。",
                            )))
                            .when(
                                self.draft["tts"]["providerID"].as_str() == Some("bailian"),
                                |column| {
                                    column.child(row_detail(settings_copy(
                                        locale,
                                        "复刻音色请选择创建时使用的模型。",
                                    )))
                                },
                            ),
                    ),
            )
            .when(
                self.snapshot["tts"]["catalogLoaded"].as_bool() == Some(true) && !valid_model,
                |section| {
                    section.child(row_detail(settings_copy(
                        locale,
                        "原配置模型不在当前支持列表中，请选择后保存；不会自动改用其他模型。",
                    )))
                },
            )
            .child(row_detail(if self.snapshot["tts"]["credentialConfigured"].as_bool()
                == Some(true)
            {
                settings_copy(locale, "已配置")
            } else {
                settings_copy(locale, "该服务尚未配置凭据，请填写后保存")
            }))
            .child(
                Button::new("save-tts")
                    .primary()
                    .icon(IconName::Check)
                    .tooltip(settings_copy(locale, "保存配置"))
                    .accessibility_label(settings_copy(locale, "保存配置"))
                    .accessibility_id("settings.tts.save")
                    .disabled(!tts_save_enabled(valid_model))
                    .on_click(cx.listener(|this, _, _, cx| this.tts_action("tts.save", cx))),
            )
            .when_some(
                self.snapshot["tts"]["notice"].as_str(),
                |section, notice| section.child(ui::notice(settings_notice(locale, notice))),
            )
            .child(row_detail(settings_copy(
                locale,
                "传输：本机 TCP → Rust → 服务商；录放音留在系统设备层。",
            )));

        // 按住说话
        let asr = SettingsSection::new(settings_copy(locale, "按住说话"))
            .visible(self.agent_group_visible("按住说话"))
            .child(self.dropdown(
                "asr-microphone",
                "麦克风",
                "asr",
                "microphoneDeviceID",
                self.options("asr", "microphoneDevices"),
                cx,
            ))
            .child(self.dropdown(
                "asr-provider",
                "服务",
                "asr",
                "providerID",
                self.options("asr", "providers"),
                cx,
            ))
            .child(field_row(
                "API Key",
                div()
                    .w(px(metrics::KEY_FIELD_WIDTH))
                    .child(
                        Input::new(&self.extra_inputs[1])
                            .accessibility_id("settings.asr.key")
                            .aria_label(settings_copy(locale, "新的 ASR API Key")),
                    ),
            ))
            .child(self.dropdown(
                "asr-model",
                "模型",
                "asr",
                "modelID",
                self.options("asr", "models"),
                cx,
            ))
            .when(
                self.snapshot["asr"]["catalogLoaded"].as_bool() == Some(true) && !asr_valid,
                |section| {
                    section.child(row_detail(settings_copy(
                        locale,
                        "原配置模型不在当前支持列表中，请选择后保存；不会自动改用其他模型。",
                    )))
                },
            )
            .child(
                Button::new("save-asr")
                    .primary()
                    .icon(IconName::Check)
                    .tooltip(settings_copy(locale, "保存配置"))
                    .accessibility_label(settings_copy(locale, "保存配置"))
                    .accessibility_id("settings.asr.save")
                    .disabled(!asr_save_enabled(asr_valid))
                    .on_click(cx.listener(|this, _, _, cx| {
                        let mut value = this.draft["asr"].clone();
                        value["op"] = json!("asr.save");
                        value["apiKey"] = json!(this.extra_inputs[1].read(cx).value().to_string());
                        this.commands.push(value);
                    })),
            )
            .when_some(
                self.snapshot["asr"]["notice"].as_str(),
                |section, notice| section.child(ui::notice(settings_notice(locale, notice))),
            )
            .child(row_detail(settings_copy(
                locale,
                "在空间或 Live Cam 按住麦克风录音，松开后将完整转写交给当前 Agent。没有双向实时通话。",
            )));

        v_flex()
            .gap(px(metrics::SECTION_CONTENT_GAP))
            .w_full()
            .child(core)
            .child(persona)
            .child(resident)
            .child(chat)
            .when(self.unity_external, |column| column.child(autonomy))
            .child(voice)
            .child(asr)
            .into_any_element()
    }

    fn stage_page(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let sections = stage_sections(self.page);
        let mut column = v_flex().size_full().min_h(px(0.));
        if sections.len() > 1 {
            let key = stage_page_key(self.page);
            let selected = sections
                .iter()
                .position(|section| *section == self.section)
                .unwrap_or(0);
            let weak = cx.entity().downgrade();
            column = column.child(
                div().flex_shrink_0().pb(px(metrics::SECTION_CONTENT_GAP)).child(
                    TabBar::new("settings.stage-sections")
                        .segmented()
                        .small()
                        .w_full()
                        .selected_index(selected)
                        .children(sections.iter().map(|section| {
                            Tab::new()
                                .flex_1()
                                .min_w(px(0.))
                                .aria_label(localized_route(locale, section).to_string())
                                .child(
                                    div()
                                        .text_size(px(tokens::CAPTION))
                                        .min_w(px(0.))
                                        .whitespace_nowrap()
                                        .child(localized_route(locale, section).to_string()),
                                )
                        }))
                        .on_click(move |index, _, cx| {
                            let section = sections[*index];
                            _ = weak.update(cx, |this, cx| {
                                this.select_section(key, section, cx);
                            });
                        }),
                ),
            );
        }
        let pane = self.stage_pane.clone();
        let body = match pane {
            Some(pane) => div()
                .flex_1()
                .min_h(px(0.))
                .child(pane)
                .into_any_element(),
            None => ui::empty_state(settings_copy(locale, "加载中…")).into_any_element(),
        };
        column.child(body).into_any_element()
    }

    /// The notice footer. It is pinned under the single scroll area and never
    /// scrolls with the content (`PresenceSettingsView.swift:133-146`).
    fn page_notice(&self, locale: UiLocale) -> Option<AnyElement> {
        let key = page_notice_section(self.page)?;
        let notice = self.snapshot[key]["notice"]
            .as_str()
            .filter(|notice| !notice.is_empty())?;
        let error = self.snapshot[key]["hasError"].as_bool() == Some(true);
        let working =
            key == "music" && self.snapshot["music"]["working"].as_bool() == Some(true);
        let leading = if working {
            Spinner::new().small().color(rgba(s::TEXT_MUTED).into()).into_any_element()
        } else {
            Icon::new(if error {
                IconName::CircleAlert
            } else {
                IconName::CircleCheck
            })
            .size(px(metrics::NOTICE_ICON))
            .into_any_element()
        };
        Some(
            h_flex()
                .items_center()
                .gap(px(metrics::NOTICE_GAP))
                .flex_shrink_0()
                .px(px(metrics::HEADER_PADDING_H))
                .pb(px(metrics::CONTENT_PADDING_BOTTOM))
                .max_h(px(metrics::NOTICE_MAX_HEIGHT))
                .overflow_hidden()
                .child(leading)
                .child(
                    div()
                        .text_size(px(tokens::CAPTION))
                        .line_height(px(tokens::CAPTION_LINE_HEIGHT))
                        .text_color(rgba(if error { s::WARNING } else { s::TEXT_MUTED }))
                        .child(settings_notice(locale, notice)),
                )
                .into_any_element(),
        )
    }

    fn import_menu(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let weak = cx.entity().downgrade();
        Button::new("presence-import")
            .icon(IconName::ArrowDown)
            .tooltip(settings_copy(locale, "导入"))
            .accessibility_label(settings_copy(locale, "导入"))
            .dropdown_caret(true)
            .small()
            .accessibility_id("settings.presence.import")
            .disabled(!import_menu_enabled(
                self.snapshot["presence"]["working"].as_bool() == Some(true),
            ))
            .dropdown_menu(move |menu, _, _| {
                let a = weak.clone();
                let b = weak.clone();
                let c = weak.clone();
                menu.item(
                    PopupMenuItem::new(settings_copy(locale, "角色模型…")).on_click(move |_, _, cx| {
                        _ = a.update(cx, |this, cx| {
                            this.commands.push(json!({"op":"presence.import"}));
                            cx.notify();
                        });
                    }),
                )
                .item(
                    PopupMenuItem::new(settings_copy(locale, "动作文件…")).on_click(move |_, _, cx| {
                        _ = b.update(cx, |this, cx| {
                            this.commands.push(json!({"op":"presence.motion.import"}));
                            cx.notify();
                        });
                    }),
                )
                .item(
                    PopupMenuItem::new(settings_copy(locale, "从链接导入角色…"))
                        .on_click(move |_, window, cx| {
                            _ = c.update(cx, |this, cx| this.open_import_link(window, cx));
                        }),
                )
            })
            .into_any_element()
    }

    fn language_menu(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let weak = cx.entity().downgrade();
        Button::new("settings-language")
            .small()
            .label(locale.name())
            .dropdown_caret(true)
            .accessibility_id("settings.language")
            .accessibility_label(locale.language_label())
            .disabled(self.snapshot["locale"].as_str().and_then(UiLocale::parse).is_none())
            .dropdown_menu(move |mut menu, _, _| {
                for language in UiLocale::ALL {
                    let weak = weak.clone();
                    menu = menu.item(PopupMenuItem::new(language.name()).on_click(move |_, _, cx| {
                        _ = weak.update(cx, |this, cx| {
                            // Readback owns the visible locale. A rejected
                            // command must not optimistically switch copy.
                            this.commands.push(language_command(language));
                            cx.notify();
                        });
                    }));
                }
                menu
            })
            .into_any_element()
    }

    fn page_header(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let (title, subtitle) = page_header_routes(self.page);
        let import_visible = self.page == PAGE_PRESENCE
            && (!self.unity_external || unity_section_available(&self.snapshot, &self.section));
        h_flex()
            .items_center()
            .justify_between()
            .gap(px(metrics::HEADER_ACTION_GAP))
            .flex_shrink_0()
            .w_full()
            .px(px(metrics::HEADER_PADDING_H))
            .py(px(header_vertical_padding(self.page)))
            .child(
                v_flex()
                    .gap(px(metrics::HEADER_TITLE_GAP))
                    .min_w(px(0.))
                    .child(
                        div()
                            .font_family(tokens::FONT_FAMILY)
                            .text_size(px(tokens::TITLE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .child(localized_route(locale, title)),
                    )
                    .child(ui::muted(settings_copy(locale, subtitle))),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap(px(tokens::SPACING_8))
                    .flex_shrink_0()
                    .when(import_visible, |row| row.child(self.import_menu(locale, cx)))
                    .when(!self.unity_external, |row| {
                        row.child(self.language_menu(locale, cx))
                    }),
            )
            .into_any_element()
    }

    /// The original five-segment picker: 330 wide, 14 above, 8 below.
    fn tab_bar(&self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let tabs = settings_tabs();
        let weak = cx.entity().downgrade();
        h_flex()
            .w_full()
            .justify_center()
            .flex_shrink_0()
            .pt(px(tokens::settings::SEGMENT_TOP))
            .pb(px(tokens::settings::SEGMENT_BOTTOM))
            .child(
                TabBar::new("settings.tabs")
                    .segmented()
                    .small()
                    .w(px(tokens::settings::SEGMENT_WIDTH))
                    .when_some(tab_index_for_page(self.page), |bar, index| {
                        bar.selected_index(index)
                    })
                    .children(tabs.map(|tab| {
                        let page = localized_route(locale, tab.label).to_string();
                        Tab::new()
                            .icon(settings_tab_icon(tab.key))
                            .aria_label(page.clone())
                            .tooltip(move |window, cx| {
                                gpui_kit::component::tooltip::Tooltip::new(page.clone())
                                    .build(window, cx)
                            })
                            .flex_1()
                            .min_w(px(0.))
                    }))
                    .on_click(move |index, _, cx| {
                        let key = tabs[*index].key;
                        _ = weak.update(cx, |this, cx| this.select_page(key, cx));
                    }),
            )
            .into_any_element()
    }

    fn page_body(&mut self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        match self.page {
            PAGE_PRESENCE => self.presence_page(locale, cx),
            PAGE_MUSIC => self.music_page(locale, cx),
            PAGE_SPACE_PREFS | PAGE_SPACE => self.space_page(locale, cx),
            PAGE_SHORTCUTS => self.shortcuts_page(locale, cx),
            PAGE_AGENT => self.agent_page(locale, cx),
            // The Unity 视频 section is the settings authority panel; the other
            // player sections stay with the stage pane.
            PAGE_PLAYER if self.unity_external && self.section == "视频" => {
                self.video_page(locale, cx)
            }
            _ => self.stage_page(locale, cx),
        }
    }

    /// Whether the page is the embedded stage pane (which owns its own scroll
    /// and needs a definite height inside the Unity window's scrolling column).
    fn embedded_stage_page(&self) -> bool {
        !system_settings_page(self.page)
            && !(self.page == PAGE_PLAYER && self.unity_external && self.section == "视频")
    }

    /// The product window: original tabs, original page header, one scroll area.
    fn system_settings(&mut self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        let stage = !system_settings_page(self.page);
        let body = self.page_body(locale, cx);
        let mut column = v_flex()
            .size_full()
            .min_h(px(0.))
            .child(self.tab_bar(locale, cx))
            .child(self.page_header(locale, cx));
        column = column.child(if stage {
            // The embedded stage pane owns its own scroll; the settings layer
            // must not add a second one.
            div()
                .flex_1()
                .min_h(px(0.))
                .child(body)
                .into_any_element()
        } else {
            div()
                .id("settings.content")
                .flex_1()
                .min_h(px(0.))
                .overflow_y_scroll()
                .px(px(metrics::CONTENT_PADDING_H))
                .pb(px(metrics::CONTENT_PADDING_BOTTOM))
                .child(body)
                .into_any_element()
        });
        if let Some(notice) = self.page_notice(locale) {
            column = column.child(notice);
        }
        column.into_any_element()
    }

    /// The Unity settings window keeps the category sidebar the Unity host
    /// navigates with; its sections filter the same page bodies.
    fn unity_settings(&mut self, locale: UiLocale, cx: &mut Context<Self>) -> AnyElement {
        use gpui_kit::component::sidebar::{Sidebar, SidebarMenu, SidebarMenuItem};
        let body = self.page_body(locale, cx);
        let content = if self.embedded_stage_page() {
            div()
                .h(px(metrics::STAGE_EMBED_HEIGHT))
                .child(body)
                .into_any_element()
        } else {
            body
        };
        let mut root = v_flex()
            .size_full()
            .min_h(px(0.))
            .child(self.page_header(locale, cx))
            .child(
                div()
                    .id("settings.content")
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_y_scroll()
                    .px(px(metrics::CONTENT_PADDING_H))
                    .pb(px(metrics::CONTENT_PADDING_BOTTOM))
                    .child(content),
            );
        if let Some(notice) = self.page_notice(locale) {
            root = root.child(notice);
        }
        let mut menu = SidebarMenu::new();
        for (label, items) in [
            (
                "播放器",
                vec![
                    ("player", "歌词"),
                    ("player", "视觉效果"),
                    ("player", "视频"),
                ],
            ),
            (
                "空间",
                vec![("space", "我的空间"), ("space-preferences", "生成服务")],
            ),
            (
                "角色",
                vec![
                    ("presence", "角色管理"),
                    ("presence", "动作管理"),
                    ("agent", "自主行动"),
                ],
            ),
            ("音乐", vec![("music", "音乐账号与歌单同步")]),
            (
                "对话与语音",
                vec![
                    ("agent", "Agent 连接"),
                    ("agent", "语音播放"),
                    ("agent", "按住说话"),
                ],
            ),
            ("应用", vec![("shortcuts", "快捷键")]),
        ] {
            let active = items.iter().any(|(_, section)| *section == self.section);
            let children = items
                .into_iter()
                .map(|(key, section)| {
                    SidebarMenuItem::new(settings_navigation_label(locale, section))
                        .active(self.section == section)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.select_section(key, section, cx)
                        }))
                })
                .collect::<Vec<_>>();
            menu = menu.child(
                SidebarMenuItem::new(settings_navigation_label(locale, label))
                    .active(active)
                    .default_open(active)
                    .click_to_toggle(true)
                    .children(children),
            );
        }
        // Sidebar supplies the same horizontal inset as its navigation content.
        let language = v_flex()
            .w_full()
            .pb(px(tokens::SPACING_8))
            .gap(px(tokens::SPACING_4))
            .child(ui::section_title(locale.language_label()))
            .child(self.language_menu(locale, cx));
        div()
            .id("settings-root")
            .size_full()
            .flex()
            .child(
                Sidebar::new("settings-sidebar")
                    .w(px(metrics::SIDEBAR_WIDTH))
                    .header(language)
                    .child(menu),
            )
            .child(div().flex_1().min_w(px(0.)).h_full().child(root))
            .into_any_element()
    }
}

impl Render for AgentSettingsPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let locale = UiLocale::from_settings(&self.snapshot);
        let body = if self.unity_external {
            self.unity_settings(locale, cx)
        } else {
            self.system_settings(locale, cx)
        };
        div()
            .id("settings-root")
            .size_full()
            .flex()
            .font_family(tokens::FONT_FAMILY)
            .text_size(px(tokens::BODY))
            .line_height(px(tokens::BODY_LINE_HEIGHT))
            .bg(rgba(s::PANEL_BG))
            .text_color(rgba(s::TEXT))
            .on_key_down(cx.listener(|this, event: &KeyDownEvent, _, cx| {
                // 按键录制分两条真实链路，不能同时发：
                //
                // - **产品模式**（`unity_external == false`）：宿主在**同一个进程**
                //   里装 `NSEvent` 本地监视器，`shortcuts.record` →
                //   `ProductSettingsParity.installRecordingMonitor()` /
                //   `handleRecordingEvent()`（ProductSettingsParity.swift:324-354）。
                //   监视器在窗口分发**之前**消费 keyDown，直接 `assign`／报校验／
                //   Esc 取消；面板再转发一个产品链没有处理者的 `shortcuts.capture`
                //   只会在快照滞后（宿主已结束录制、面板仍读到 `recordingID`）时
                //   打到空处理者，触发「设置操作尚未确认完成」。
                // - **Unity 设置窗**（`unity_external == true`）：`gmgn-unity-settings`
                //   是**独立进程**（apps/gpui-app/src/bin/gmgn-unity-settings.rs:62），
                //   宿主的监视器收不到这里的按键，所以由面板转发
                //   `shortcuts.capture`（UnityShortcutSettingsBridge.swift:44）。
                if !this.unity_external {
                    return;
                }
                if this.snapshot["shortcuts"]["recordingID"].as_str().is_none() {
                    return;
                }
                let modifiers = event.keystroke.modifiers;
                let flags = u64::from(modifiers.platform)
                    | (u64::from(modifiers.alt) << 1)
                    | (u64::from(modifiers.control) << 2)
                    | (u64::from(modifiers.shift) << 3);
                if let Some(command) = shortcut_capture_command(&event.keystroke.key, flags) {
                    this.commands.push(command);
                    cx.stop_propagation();
                    cx.notify();
                }
            }))
            .child(body)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod unity_settings_capability_tests {
    use super::{unity_agent_group_available, unity_section_available};
    use serde_json::{Value, json};
    #[test]
    fn host_capabilities_enable_real_groups_and_keep_missing_groups_explicit() {
        let snapshot = json!({"unity":{"availableSections":["歌词","视觉效果","语音播放","自主行动"],"availableAgentGroups":["回复语音","居民人格"]}});
        assert!(unity_section_available(&snapshot, "视觉效果"));
        assert!(unity_agent_group_available(&snapshot, "居民人格"));
        assert!(!unity_agent_group_available(&snapshot, "自主行动"));
        assert!(!unity_section_available(&snapshot, "音乐账号与歌单同步"));
        assert!(!unity_section_available(&Value::Null, "歌词"));
    }
}

#[cfg(test)]
mod settings_display_tests {
    use super::{
        MotionAction, PAGE_ACTIVITIES, PAGE_AGENT, PAGE_MUSIC, PAGE_PLAYER, PAGE_PRESENCE,
        PAGE_SHORTCUTS, PAGE_SPACE, PAGE_SPACE_PREFS, PresenceAction, avatar_detail,
        generation_check_enabled, generation_save_enabled, header_vertical_padding,
        import_menu_enabled, marble_save_enabled, model_in_catalog, motion_action,
        motion_format, music_connect_label, music_row_authorizing, music_status_label,
        music_sync_command, orb_intensity_percent, page_header_routes, page_index_for_key,
        page_notice_section, presence_action, presence_more_accessibility, prop_check_enabled,
        prop_save_enabled, save_ack_clear, settings_tabs,
        shortcut_cell_label, shortcut_validation, space_library_available,
        space_library_visible, stage_sections, system_settings_page,
        tab_index_for_page, tts_draft_change_requires_stop, tts_preview_enabled, tts_save_enabled,
        asr_save_enabled,
    };
    use serde_json::json;

    /// The 我的空间 world list renders only when the host published a library.
    /// The product snapshot has no `spaceLibrary` (the native renderer has one
    /// space, not a package library), so in product mode the 刷新 button
    /// (`space.library.load`) and the world rows (`space.library.select`) are
    /// never rendered — there is no visible control that can only fail.
    #[test]
    fn space_library_section_requires_a_published_library() {
        let product = json!({"space":{"defaultSpace":"living-pod"},"shortcuts":{"assignments":[]}});
        assert!(product.get("spaceLibrary").is_none());
        assert!(!space_library_available(&product));
        // An explicit null is "no library" too.
        assert!(!space_library_available(&json!({"spaceLibrary":null})));
        // The Unity host publishes it (`UnityMediaHost.swift:1538`).
        let unity = json!({"spaceLibrary":{"worlds":[{"id":"world-1","selected":false}],"marblePresets":[]}});
        assert!(space_library_available(&unity));
        // Product-mode render condition (空间 page): no library ⇒ the section is
        // not built at all.
        assert!(!space_library_visible(&product, false, false, true));
        assert!(!space_library_visible(&product, false, true, true));
        assert!(!space_library_visible(&json!({"spaceLibrary":null}), false, true, true));
        // With a published library the Unity sidebar's own rules still apply.
        assert!(space_library_visible(&unity, true, true, true));
        assert!(!space_library_visible(&unity, true, false, true));
        assert!(!space_library_visible(&unity, true, true, false));
        // The render must go through that one decision: reverting to the old
        // "visible whenever the section is" condition fails here. The needle is
        // split so this assertion's own text cannot satisfy it.
        let needle = [".visible(space", "_library_visible("].concat();
        assert!(
            include_str!("settings.rs").contains(needle.as_str()),
            "the 我的空间 section must render through space_library_visible"
        );
    }

    #[test]
    fn marble_commands_require_runtime_and_preserve_paid_receipts() {
        let ready = json!({"generationSupported":true,"marbleWorking":false,"marblePresets":[{"id":"room","name":"Room"}]});
        assert_eq!(super::marble_command(&ready, "space.marble.generate", "room"), Some(json!({"op":"space.marble.generate","presetID":"room"})));
        assert_eq!(super::marble_command(&ready, "space.marble.import", " world-1 "), Some(json!({"op":"space.marble.import","worldID":"world-1"})));
        assert!(super::marble_command(&ready, "space.marble.generate", "unknown").is_none());
        assert!(super::marble_command(&ready, "space.marble.import", " ").is_none());
        assert!(super::marble_command(&ready, "space.marble.resume", "").is_none());
        let mut unsupported = ready.clone();
        unsupported["generationSupported"] = json!(false);
        assert!(super::marble_command(&unsupported, "space.marble.generate", "room").is_none());
        assert!(super::marble_command(&unsupported, "space.marble.import", "world-1").is_none());
        let mut pending = ready.clone();
        pending["marbleOperationID"] = json!("operation-1");
        assert!(super::marble_command(&pending, "space.marble.generate", "room").is_none());
        assert!(super::marble_command(&pending, "space.marble.import", "world-2").is_none());
        assert_eq!(super::marble_command(&pending, "space.marble.resume", ""), Some(json!({"op":"space.marble.resume"})));
        pending["marbleWorking"] = json!(true);
        assert!(super::marble_command(&pending, "space.marble.resume", "").is_none());
        assert_eq!(super::marble_command(&pending, "space.marble.cancel", ""), Some(json!({"op":"space.marble.cancel"})));
        pending["generationSupported"] = json!(false);
        assert!(super::marble_command(&pending, "space.marble.generate", "room").is_none());
        assert_eq!(super::marble_command(&pending, "space.marble.cancel", ""), Some(json!({"op":"space.marble.cancel"})));
        pending["marbleWorking"] = json!(false);
        assert!(super::marble_command(&pending, "space.marble.resume", "").is_none());
        assert!(super::marble_command(&pending, "space.marble.import", "world-2").is_none());
    }

    #[test]
    fn shortcut_capture_preserves_native_codes_and_modifiers() {
        assert_eq!(super::shortcut_capture_command("space", 1), Some(json!({"op":"shortcuts.capture","keyCode":49,"keyLabel":"Space","modifiers":1})));
        assert_eq!(super::shortcut_capture_command("K", 9).unwrap()["keyCode"], 40);
        assert_eq!(super::shortcut_capture_command("right", 7).unwrap()["modifiers"], 7);
        assert_eq!(super::shortcut_capture_command("escape", 0), Some(json!({"op":"shortcuts.cancel"})));
        assert!(super::shortcut_capture_command("unsupported-key", 0).is_none());
    }

    #[test]
    fn built_in_character_detail_matches_original_display() {
        assert_eq!(
            avatar_detail(&json!({"engine":"orb","isBuiltIn":true,"detail":"orb · 1.0.0"})),
            "内置 · 呼吸球"
        );
        assert_eq!(
            avatar_detail(&json!({"engine":"pmx","isBuiltIn":false,"detail":"pmx · 4.14.0"})),
            "PMX · 4.14.0"
        );
    }

    #[test]
    fn real_display_detail_preserves_package_author() {
        assert_eq!(
            avatar_detail(&json!({"engine":"vrm","isBuiltIn":false,"displayDetail":"原作者 · 2.0"})),
            "原作者 · 2.0"
        );
    }

    #[test]
    fn original_motion_names_do_not_show_protocol_identifiers() {
        assert_eq!(motion_format("procedural"), "内置动态");
        assert_eq!(motion_format("vmd"), "VMD");
        assert_eq!(motion_format("vrma"), "VRMA");
    }

    #[test]
    fn changing_tts_voice_or_model_stops_old_preview_without_other_draft_changes() {
        for field in ["voiceID", "modelID"] {
            assert!(tts_draft_change_requires_stop("tts", field, &json!("old"), &json!("new")));
            assert!(!tts_draft_change_requires_stop("tts", field, &json!("same"), &json!("same")));
        }
        assert!(!tts_draft_change_requires_stop("asr", "modelID", &json!("old"), &json!("new")));
        assert!(!tts_draft_change_requires_stop("tts", "apiKey", &json!("old"), &json!("new")));
    }

    #[test]
    fn successful_save_ack_clears_only_the_submitted_unchanged_draft() {
        assert!(save_ack_clear(3, 4, "submitted", "submitted"));
        assert!(!save_ack_clear(3, 3, "submitted", "submitted"));
        assert!(!save_ack_clear(3, 4, "submitted", "new edit"));
        assert!(!save_ack_clear(3, 2, "submitted", "submitted"));
    }

    #[test]
    fn presence_more_buttons_have_button_role_and_named_asset() {
        let (role, label) = presence_more_accessibility("移除角色", "2B");
        assert!(matches!(role, gpui_kit::Role::Button));
        assert_eq!(label, "角色「2B」的更多操作");
        let (role, label) = presence_more_accessibility("移除动作", "优雅挥手");
        assert!(matches!(role, gpui_kit::Role::Button));
        assert_eq!(label, "动作「优雅挥手」的更多操作");
    }

    #[test]
    fn provider_sync_busy_blocks_only_that_provider_without_disconnect() {
        let busy = json!({"id":"netease","connected":true,"syncing":true});
        let ready = json!({"id":"qq-music","connected":true,"syncing":false});
        assert!(music_sync_command(&busy, false).is_none());
        assert_eq!(music_sync_command(&ready, false), Some(json!({"op":"music.sync","id":"qq-music"})));
        assert!(music_sync_command(&ready, true).is_none());
        assert!(music_sync_command(&json!({"id":"netease","connected":false}), false).is_none());
    }

    #[test]
    fn sync_failure_keeps_connected_provider_retry_as_sync_not_disconnect() {
        let failed = json!({"id":"netease","connected":true,"syncing":false,"hasError":true});
        assert_eq!(music_sync_command(&failed, false), Some(json!({"op":"music.sync","id":"netease"})));
    }

    #[test]
    fn category_rows_enable_whole_row_expansion() {
        let source = include_str!("settings.rs");
        let navigation = source
            .split("let mut menu=SidebarMenu::new();")
            .nth(1)
            .unwrap()
            .split("div().id(\"settings-root\")")
            .next()
            .unwrap();
        assert!(
            navigation.contains(".click_to_toggle(true)"),
            "category rows must expand on label clicks"
        );
        assert!(
            navigation.contains(".default_open(active)"),
            "current category starts expanded"
        );
    }

    // -- new decisions ------------------------------------------------------

    /// The picker is the original `GMGNSettingsPage.allCases`: 角色／音乐／空间／
    /// 快捷键／DJ, in that order, on the original pages.
    #[test]
    fn tabs_are_the_original_five_segment_picker() {
        let tabs = settings_tabs();
        assert_eq!(
            tabs.map(|tab| tab.label),
            ["角色", "音乐", "空间", "快捷键", "DJ"]
        );
        assert_eq!(
            tabs.map(|tab| tab.page),
            [
                PAGE_PRESENCE,
                PAGE_MUSIC,
                PAGE_SPACE_PREFS,
                PAGE_SHORTCUTS,
                PAGE_AGENT
            ]
        );
        assert_eq!(tabs[2].key, "space-preferences");
        assert_eq!(tab_index_for_page(PAGE_PRESENCE), Some(0));
        assert_eq!(tab_index_for_page(PAGE_AGENT), Some(4));
        // Both "space" entries render the original 空间 page, so both light it.
        assert_eq!(tab_index_for_page(PAGE_SPACE), Some(2));
        // The stage pages have no segment in the original window.
        assert_eq!(tab_index_for_page(PAGE_PLAYER), None);
        assert_eq!(tab_index_for_page(PAGE_ACTIVITIES), None);
    }

    /// Pins the original layout table numbers and the page header insets. The
    /// window/segment values come from the shared `ui_tokens::settings` module
    /// (the foundation owns them and does not duplicate them here).
    #[test]
    fn layout_matches_the_original_settings_window() {
        use super::metrics as m;
        use crate::ui_tokens::settings as window;
        assert_eq!([window::WINDOW_WIDTH, window::WINDOW_HEIGHT], [580., 500.]);
        assert_eq!([window::MIN_WIDTH, window::MIN_HEIGHT], [540., 440.]);
        assert_eq!(window::SEGMENT_WIDTH, 330.);
        assert_eq!([window::SEGMENT_TOP, window::SEGMENT_BOTTOM], [14., 8.]);
        // Kit's segmented `small` control is the 24 pt macOS segmented height.
        assert_eq!(m::SEGMENT_HEIGHT, 24.);
        assert_eq!(m::PREVIEW_SIZE, 44.);
        assert_eq!(m::MOTION_ICON_BOX, 40.);
        assert_eq!(m::PROVIDER_ICON_BOX, 32.);
        assert_eq!(m::HOST_PROMPT_MIN_HEIGHT, 150.);
        assert_eq!(m::RESIDENT_PROMPT_MIN_HEIGHT, 120.);
        assert_eq!(m::PLANNING_MODEL_WIDTH, 220.);
        assert_eq!(m::SHORTCUT_TEXT_WIDTH, 112.);
        assert_eq!(header_vertical_padding(PAGE_AGENT), 14.);
        for page in [PAGE_PRESENCE, PAGE_MUSIC, PAGE_SPACE_PREFS, PAGE_SHORTCUTS] {
            assert_eq!(header_vertical_padding(page), 18.);
        }
    }

    /// Host page keys keep their exact target pages; a typo here would move a
    /// menu entry to the wrong settings page.
    #[test]
    fn host_page_keys_keep_their_target_pages() {
        assert_eq!(page_index_for_key("music"), PAGE_MUSIC);
        assert_eq!(page_index_for_key("space-preferences"), PAGE_SPACE_PREFS);
        assert_eq!(page_index_for_key("shortcuts"), PAGE_SHORTCUTS);
        assert_eq!(page_index_for_key("agent"), PAGE_AGENT);
        assert_eq!(page_index_for_key("dj"), PAGE_AGENT);
        assert_eq!(page_index_for_key("player"), PAGE_PLAYER);
        assert_eq!(page_index_for_key("space"), PAGE_SPACE);
        assert_eq!(page_index_for_key("activities"), PAGE_ACTIVITIES);
        // Unknown keys fall back to the first original tab, like the old match.
        assert_eq!(page_index_for_key("presence"), PAGE_PRESENCE);
        assert_eq!(page_index_for_key("nonsense"), PAGE_PRESENCE);
        assert!(system_settings_page(PAGE_AGENT));
        assert!(!system_settings_page(PAGE_PLAYER));
        assert_eq!(page_notice_section(PAGE_SHORTCUTS), None);
        assert_eq!(page_notice_section(PAGE_PRESENCE), Some("presence"));
        assert_eq!(
            page_header_routes(PAGE_AGENT).0,
            "Agent 与语音"
        );
        assert_eq!(stage_sections(PAGE_PLAYER).len(), 3);
        assert_eq!(stage_sections(PAGE_SPACE), &["我的空间"]);
    }

    #[test]
    fn presence_rows_follow_renderer_availability() {
        assert_eq!(presence_action(true, true), PresenceAction::Active);
        // Active wins even if the renderer is unavailable.
        assert_eq!(presence_action(true, false), PresenceAction::Active);
        assert_eq!(presence_action(false, false), PresenceAction::Waiting);
        assert_eq!(presence_action(false, true), PresenceAction::Select);
    }

    #[test]
    fn motion_rows_never_offer_an_incompatible_selection() {
        assert_eq!(motion_action(true, true), MotionAction::Current);
        assert_eq!(
            motion_action(false, true),
            MotionAction::Select { enabled: true }
        );
        assert_eq!(
            motion_action(false, false),
            MotionAction::Select { enabled: false }
        );
        // An incompatible motion never reads as the current one.
        assert_eq!(
            motion_action(true, false),
            MotionAction::Select { enabled: false }
        );
    }

    #[test]
    fn music_rows_cover_all_original_authorization_states() {
        assert_eq!(music_status_label(Some("connected")), "已连接");
        assert_eq!(music_status_label(Some("authorizing")), "正在连接");
        assert_eq!(music_status_label(Some("expired")), "登录已过期");
        assert_eq!(music_status_label(Some("denied")), "未授权");
        assert_eq!(music_status_label(Some("unavailable")), "当前不可用");
        assert_eq!(music_status_label(Some("disconnected")), "未连接");
        assert_eq!(music_status_label(None), "未连接");
        assert!(music_row_authorizing(Some("authorizing")));
        assert!(!music_row_authorizing(Some("connected")));
        assert_eq!(music_connect_label(true), "断开");
        assert_eq!(music_connect_label(false), "连接");
    }

    #[test]
    fn speech_save_and_preview_follow_the_rust_capabilities() {
        let models = vec![json!({"id":"qwen3-tts"}), json!({"id":"eleven-v3"})];
        assert!(model_in_catalog(&models, &json!("qwen3-tts")));
        assert!(!model_in_catalog(&models, &json!("old-model")));
        assert!(!model_in_catalog(&[], &json!("qwen3-tts")));
        assert!(tts_save_enabled(true));
        assert!(!tts_save_enabled(false));
        assert!(asr_save_enabled(true));
        assert!(!asr_save_enabled(false));
        assert!(tts_preview_enabled(true, "voice-1"));
        assert!(!tts_preview_enabled(true, "   "));
        assert!(!tts_preview_enabled(false, "voice-1"));
    }

    #[test]
    fn save_and_check_buttons_need_the_original_inputs() {
        assert!(marble_save_enabled("sk-1"));
        assert!(!marble_save_enabled("   "));
        assert!(prop_save_enabled("http://127.0.0.1:8191"));
        assert!(!prop_save_enabled("\n"));
        assert!(prop_check_enabled(true, false, true));
        assert!(!prop_check_enabled(false, false, true));
        assert!(!prop_check_enabled(true, true, true));
        assert!(!prop_check_enabled(true, false, false));
        assert!(generation_check_enabled(true, false, true));
        assert!(!generation_check_enabled(true, true, true));
        assert!(!generation_check_enabled(true, false, false));
        assert!(generation_save_enabled("http://127.0.0.1:8191", false));
        assert!(!generation_save_enabled("", false));
        assert!(!generation_save_enabled("http://127.0.0.1:8191", true));
        assert!(import_menu_enabled(false));
        assert!(!import_menu_enabled(true));
    }

    #[test]
    fn shortcut_cells_and_validation_match_the_original_recorder() {
        assert_eq!(shortcut_cell_label(true, "⌘K"), "请按快捷键");
        assert_eq!(shortcut_cell_label(false, ""), "未设置");
        assert_eq!(shortcut_cell_label(false, "⌘K"), "⌘K");
        assert_eq!(
            shortcut_validation("local", false, true),
            Some(super::metrics::SHORTCUT_INCOMPLETE)
        );
        // An incomplete combination is reported before the global rule.
        assert_eq!(
            shortcut_validation("global", false, false),
            Some(super::metrics::SHORTCUT_INCOMPLETE)
        );
        assert_eq!(
            shortcut_validation("global", true, false),
            Some("全局快捷键至少需要一个修饰键。")
        );
        assert_eq!(shortcut_validation("global", true, true), None);
        assert_eq!(shortcut_validation("local", true, false), None);
    }

    #[test]
    fn orb_intensity_readout_is_a_whole_percent() {
        assert_eq!(orb_intensity_percent(0.35), 35);
        assert_eq!(orb_intensity_percent(1.0), 100);
        assert_eq!(orb_intensity_percent(1.5), 150);
        assert_eq!(orb_intensity_percent(0.999), 100);
    }

    /// The pane must survive real GPUI window draws for every original tab, and
    /// a tab click must keep sending the original page commands.
    #[test]
    fn pane_draws_every_original_tab_and_keeps_host_command_semantics() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| {
                let pane = super::AgentSettingsPane::new(window, cx);
                pane
            });
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        let pane = stored.borrow().clone().expect("pane entity");
        // Settings load is queued on construction.
        let initial = pane.update(&mut cx, |pane, _| pane.take_commands());
        assert_eq!(initial, vec![json!({"op":"settings.load"})]);
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.update_snapshot(
                    json!({
                        "locale":"zh-CN",
                        "presence":{"packages":[{"id":"orb","name":"呼吸球","engine":"orb","isBuiltIn":true,"isActive":true,"rendererAvailable":true}],"motions":[],"publishedMotions":[]},
                        "music":{"providers":[{"id":"netease","name":"网易云音乐","status":"connected","connected":true}],"working":false},
                        "space":{"options":[{"id":"living-pod","name":"飞船生活舱（Marble）","detail":"Marble 生成舱体"}],"defaultSpace":"living-pod","credentialConfigured":false},
                        "shortcuts":{"assignments":[{"id":"play","title":"播放 / 暂停","local":"Space","global":""}],"globalEnabled":true,"mediaKeysEnabled":false},
                        "agent":{"codexState":"signedOut","backends":[],"budgetOptions":[0,6]},
                        "tts":{"providers":[],"voices":[],"models":[]},
                        "asr":{"providers":[],"microphoneDevices":[],"models":[]},
                        "spaceLibrary":{"worlds":[],"marblePresets":[]}
                    }),
                    window,
                    cx,
                );
                // Every original tab page renders.
                for key in ["presence", "music", "space-preferences", "shortcuts"] {
                    pane.select_page(key, cx);
                    assert!(super::system_settings_page(pane.page));
                }
                // Opening the DJ tab loads its speech session (original copy),
                // and leaving it cancels that session.
                pane.take_commands();
                pane.select_page("agent", cx);
                assert!(
                    pane.take_commands()
                        .iter()
                        .any(|command| command["op"] == "speech.settings.load"),
                    "opening the DJ tab must load the speech session"
                );
                pane.select_page("presence", cx);
                assert!(
                    pane.take_commands()
                        .iter()
                        .any(|command| command["op"] == "speech.settings.cancel"),
                    "leaving the DJ tab must cancel the speech session"
                );
                // The stage page stays reachable for the host.
                pane.select_page("player", cx);
                assert_eq!(pane.page, super::PAGE_PLAYER);
                assert_eq!(super::tab_index_for_page(pane.page), None);
                // The Unity window keeps the category sidebar and the three
                // section panels the old implementation carried: the character
                // position form, the generation panel and the video authority.
                pane.set_unity_external(true, cx);
                pane.select_section("presence", "角色管理", cx);
                pane.select_section("space-preferences", "生成服务", cx);
                pane.take_commands();
                pane.select_section("player", "视频", cx);
                assert!(
                    pane.take_commands()
                        .iter()
                        .any(|command| command["op"] == "video.load"),
                    "selecting the video section must load the video authority"
                );
                assert!(!pane.embedded_stage_page());
                cx.notify();
            });
            window.refresh();
            window.draw(cx).clear(cx);
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }
}
