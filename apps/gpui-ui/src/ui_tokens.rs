//! Shared 2D typography, spacing and overlay chrome. The system face uses GPUI's
//! native platform resolver (including Chinese fallback); no bundled font is
//! needed. Compact original inspector readouts remain explicit at their existing
//! sizes.
//!
//! Two layers live here:
//!
//! 1. the **document scale** (`BODY`/`CAPTION`/…) for ordinary window content,
//!    which follows the system theme;
//! 2. [`scene`] — the chrome for panels that float **over the rendered Unity
//!    space**. Those panels must not follow the system theme: the original draws
//!    them with fixed dark `Color(white:)` literals so a light system theme can
//!    never invert a panel that sits on top of the scene. Every value in
//!    [`scene`] is copied from an original source, and the surface-specific
//!    metric modules ([`chat`] and the ones added alongside each rewrite) sit
//!    beside it.
pub const FONT_FAMILY: &str = ".SystemUIFont";
pub const BODY: f32 = 14.;
pub const CAPTION: f32 = 12.;
pub const SUBTITLE: f32 = 16.;
pub const TITLE: f32 = 20.;
pub const BODY_LINE_HEIGHT: f32 = 20.;
pub const CAPTION_LINE_HEIGHT: f32 = 16.;
pub const SPACING_4: f32 = 4.;
pub const SPACING_8: f32 = 8.;
pub const SPACING_12: f32 = 12.;
pub const SPACING_16: f32 = 16.;
pub const SPACING_24: f32 = 24.;

/// Chrome shared by every panel that floats over the rendered space.
///
/// Colours are `0xRRGGBBAA` literals so this module stays free of GPUI types;
/// call sites pass them through `rgba(..)`. The values come from the original
/// overlay surfaces (`StageOverlayView.swift`, `StageWindowController.swift`,
/// `ResidentSystemInboxUI.swift`): the original composes them from
/// `Color(white:)` plus an opacity, never from the system theme.
pub mod scene {
    /// Secondary surface — the chat history card in the original.
    pub const PANEL_BG: u32 = 0x1a1a1af5;
    /// Primary panel surface — `Color(white: 0.15).opacity(0.98)`.
    pub const CARD_BG: u32 = 0x262626fa;
    /// Surface while it is an active drop target or an asserted state.
    pub const CARD_BG_ACTIVE: u32 = 0x1a4757fa;
    /// Bar surface behind rows of controls (transport bar, list headers).
    pub const BAR_BG: u32 = 0x0a0a0ab8;
    /// Resting hairline: `white.opacity(0.1)`.
    pub const BORDER: u32 = 0xffffff1a;
    /// Focused field/card hairline: `white.opacity(0.22)`.
    pub const BORDER_FOCUSED: u32 = 0xffffff38;
    /// Active/drop hairline: `white.opacity(0.55)`.
    pub const BORDER_ACTIVE: u32 = 0xffffff8c;
    /// Body text over the scene: `white.opacity(0.9)`.
    pub const TEXT: u32 = 0xffffffe6;
    /// Secondary label: `white.opacity(0.45)`.
    pub const TEXT_MUTED: u32 = 0xffffff73;
    /// Tertiary readout: `white.opacity(0.43)`.
    pub const TEXT_DIM: u32 = 0xffffff6e;
    /// **The icon palette.** Every glyph in the layer — a transport control, a
    /// settings row, a panel button, a standalone `Icon` — resolves through
    /// [`primitives::icon_color`], which returns exactly these four constants.
    /// No icon may take its colour from a kit variant, a component default or
    /// `cx.theme()`; `tests/overlay_theme_gate.rs` pins that.
    ///
    /// Default glyph: one bright white, raised from the original recording of
    /// `white.opacity(0.55)` (`0xffffff8c`) on 2026-10-09 so the whole icon set
    /// reads as one bright family on the dark `CARD_BG`/`PANEL_BG` surfaces.
    /// The old 0.55 tone is [`ICON_MUTED`] now.
    pub const ICON: u32 = 0xffffffd9;
    /// Secondary glyph — a descriptive or hint-level icon (list affordance,
    /// "nothing here yet", a de-emphasised control): `white.opacity(0.55)`
    /// (`0xffffff8c`), the tone [`ICON`] carried before the icon pass.
    pub const ICON_MUTED: u32 = 0xffffff8c;
    /// Asserted / selected glyph: **the layer's selected colour**, [`SELECTED`].
    ///
    /// It replaces the old `ICON_ACTIVE = 0xffffffb8` (`white.opacity(0.72)`),
    /// which was never an asserted state — it was the **resting** tone every
    /// `icon_button` painted, so "active" named the wrong thing and a selected
    /// control was told apart from a resting one only by [`ACCENT`].
    ///
    /// It is an **alias**, not a second definition: the hex lives once, in
    /// [`SELECTED`], so an asserted glyph and a selected tab cannot drift apart.
    pub const ICON_ACTIVE: u32 = SELECTED;
    /// Glyph of a control the host has disabled, and of a glyph that is present
    /// but not actionable: `white.opacity(0.35)`.
    pub const ICON_DISABLED: u32 = 0xffffff59;
    /// Warning / notice text: `orange.opacity(0.95)`.
    pub const WARNING: u32 = 0xff9500f2;

    /// The layer's one **selected / current / active** colour: a bright blue,
    /// `#3B9EFF`.
    ///
    /// **All eight digits are written out.** `scene` tokens are `0xRRGGBBAA`,
    /// and a six-digit literal is not "the RGB colour": `rgba` reads the low
    /// byte as alpha. The accent this replaces was written `0x22d3ee`, which
    /// resolves to `rgb(0, 34, 211)` at 93% — a dark navy, not the cyan its
    /// comment claimed, and only 1.6:1 on [`CARD_BG`](self::CARD_BG). That is
    /// the "default blue" look the layer must not have.
    /// `selected_blue_is_written_with_all_eight_digits` pins the resolved
    /// channels so that class of typo cannot come back.
    ///
    /// Why this value: hue 210°, saturation 100%, lightness 62%. It reads as
    /// **blue** rather than cyan (the old `0x22d3ee` intent was 188°) and it is
    /// bright — lightness above every dark surface in this module — while
    /// clearing 4.5:1 on all of them: 5.4:1 on `CARD_BG`, 5.9:1 on `PANEL_BG`
    /// and 6.5:1 on the transport bar's surface.
    ///
    /// **This is the single source** for every selected/active state in the
    /// layer: the transport bar's asserted control, a settings row's 使用中
    /// marker, a selected list row, the selected tab face and the 音量 track's
    /// filled part all read this constant (or [`SELECTED_SOFT`]). Nothing else
    /// may spell its hex, and no selected state may fall back to `cx.theme()`.
    pub const SELECTED: u32 = 0x3b9effff;
    /// The translucent wash *behind* a selected surface — [`SELECTED`] at 18%,
    /// for a selected list row, a selected tab or an asserted control's own
    /// face. Pairing it with `SELECTED` keeps one hue for "current" and only
    /// varies how loud the state is.
    pub const SELECTED_SOFT: u32 = 0x3b9eff2e;

    /// The layer's accent — fills, rings and icon plates — **the same bright
    /// blue** as [`SELECTED`](self::SELECTED), and an alias for the same
    /// reason: one hue, declared once.
    pub const ACCENT: u32 = SELECTED;
    /// Emphasis fill (primary send button): `white.opacity(0.92)`.
    pub const FILL: u32 = 0xffffffeb;
    /// Disabled emphasis fill: `white.opacity(0.25)`.
    pub const FILL_DISABLED: u32 = 0xffffff40;
    /// Glyph drawn on [`FILL`]: `Color(white: 0.14)`.
    pub const ON_FILL: u32 = 0x242424;
    /// Image plate behind a pre-multiplied thumbnail: `black.opacity(0.2)`.
    pub const PLATE: u32 = 0x00000033;

    pub const CONTROL_HEIGHT: f32 = 30.;
    pub const CONTROL_RADIUS: f32 = 15.;
    pub const PANEL_RADIUS: f32 = 20.;
    pub const PANEL_RADIUS_SMALL: f32 = 16.;
    pub const PANEL_PADDING: f32 = 15.;
    pub const PANEL_GAP: f32 = 10.;
}

/// Resident chat surface (`StageResidentComposer`) metrics.
///
/// Sources, so the surface cannot drift by local edits:
/// - `VisualEngine/StageOverlayView.swift:228-438` — the composer itself;
/// - `VisualEngine/StageWindowController.swift:1515-1531` — preferred width 620,
///   height ≤ 320, bottom 16 above the transport bar, leading/top ≥ 22;
/// - `Presence/ResidentImageAttachment.swift:483-508` — the 54×46 strip;
/// - `Presence/ResidentImageAttachment.swift:672-710` — the input (14 pt,
///   1…3 lines, 26…64 pt tall).
pub mod chat {
    /// Preferred composer width and height ceiling.
    pub const PANEL_MAX_WIDTH: f32 = 620.;
    pub const PANEL_MAX_HEIGHT: f32 = 320.;

    /// History card.
    pub const HISTORY_HEIGHT: f32 = 132.;
    pub const HISTORY_RADIUS: f32 = 16.;
    pub const HISTORY_PADDING_H: f32 = 16.;
    pub const HISTORY_PADDING_V: f32 = 12.;
    pub const HISTORY_GAP: f32 = 12.;
    pub const TRANSCRIPT_GAP: f32 = 8.;
    /// The original stacks a 10 pt speaker label 2 pt above its text.
    pub const ENTRY_GAP: f32 = 2.;

    /// Message typography: 10 pt label, 13 pt text, 4 pt `lineSpacing` folded
    /// into the line height.
    pub const LABEL_SIZE: f32 = 10.;
    pub const MESSAGE_SIZE: f32 = 13.;
    pub const MESSAGE_LINE_HEIGHT: f32 = 17.;
    pub const NOTICE_SIZE: f32 = 11.;
    pub const STATUS_SIZE: f32 = 11.;

    /// Composer card.
    pub const CARD_RADIUS: f32 = 20.;
    pub const CARD_PADDING: f32 = 15.;
    pub const CARD_GAP: f32 = 12.;
    pub const CONTROL_GAP: f32 = 10.;
    pub const ATTACH_BUTTON: f32 = 28.;
    pub const ATTACH_BUTTON_RADIUS: f32 = 14.;
    pub const COPY_BUTTON: f32 = 24.;

    /// Input field: 1…3 lines, 26…64 pt.
    pub const INPUT_ROWS: (usize, usize) = (1, 3);
    pub const INPUT_MIN_HEIGHT: f32 = 26.;
    pub const INPUT_MAX_HEIGHT: f32 = 64.;

    /// Attachment strip.
    pub const ATTACHMENT_WIDTH: f32 = 54.;
    pub const ATTACHMENT_HEIGHT: f32 = 46.;
    pub const ATTACHMENT_RADIUS: f32 = 6.;
    pub const ATTACHMENT_GAP: f32 = 8.;

    /// Live Cam (compact) composer heights: idle vs. anything attached.
    pub const COMPACT_IDLE_HEIGHT: f32 = 70.;
    pub const COMPACT_ATTACHED_HEIGHT: f32 = 140.;

    /// The 小窗 chat column: the chat surface drawn **inside** the compact
    /// window when its own 聊天 entry is pressed.
    ///
    /// Source: the Unity build's compact transcription of the AppKit Live Cam
    /// window — `.compact-window .chat-column { position:absolute; left:8px;
    /// right:48px; bottom:8px; height:244px; max-height:92%; padding:8px; }`
    /// (`Player.uss:102`) with `.compact-window .chat-column.compact-history
    /// { height:320px; }` (`Player.uss:103`). The right edge is the **reserved**
    /// Live Cam control column, the same 48 the other compact surfaces stop at,
    /// so it is read from [`super::shell::COMPACT_CONTENT_RIGHT`] instead of
    /// being written a second time.
    pub const COMPACT_COLUMN_LEFT: f32 = 8.;
    pub const COMPACT_COLUMN_RIGHT: f32 = super::shell::COMPACT_CONTENT_RIGHT;
    pub const COMPACT_COLUMN_BOTTOM: f32 = 8.;
    pub const COMPACT_COLUMN_HEIGHT: f32 = 244.;
    pub const COMPACT_COLUMN_HISTORY_HEIGHT: f32 = 320.;
    /// `max-height: 92%` of the window, as a fraction.
    pub const COMPACT_COLUMN_MAX_HEIGHT: f32 = 0.92;
}

// Ownership of the surface modules below: each `pub mod <surface>` belongs to
// the line rewriting that surface (`chat`, `inbox`, `stage`, `props`, `program`,
// `settings`, `shell`). The rule is **append only** — add constants to your own
// module with a source reference, never renumber or restyle an existing one, and
// never add a second copy of a value `scene` already carries (point at the
// `scene` constant). `scene` and the document scale are foundation: propose
// changes, do not edit them in passing.

/// Stage settings panel — the original's four sections
/// (player / space / character / activity), popping out from the right rather
/// than replacing the stage with a sidebar.
///
/// Sources: `StageOverlayView.swift:2683-2694` (`StageControlPanelLayout`) and,
/// for the picker body moved here from `stage_panels::metrics` on 2026-10-08,
/// `:2733-3351` (`StageVisualPickerView`).
pub mod stage {
    /// `StageControlPanelLayout.maximumWidth`.
    pub const PANEL_MAX_WIDTH: f32 = 590.;
    /// `StageControlPanelLayout.maximumHeight`.
    pub const PANEL_MAX_HEIGHT: f32 = 458.;
    /// One control slot in the transport bar / settings row.
    pub const CONTROL_SIZE: f32 = 44.;
    pub const SIDE_INSET: f32 = 4.;
    pub const GROUP_GAP: f32 = 6.;
    pub const SETTINGS_WIDTH: f32 = 68.;

    /// "我的物件" panel: `StageWindowController.swift:1524`.
    pub const PROP_EDITOR_WIDTH: f32 = 340.;
    /// Prop editor sits 12 above the transport bar (`:1523`).
    pub const PROP_EDITOR_BOTTOM_GAP: f32 = 12.;

    /// Program rail: `StageWindowController.swift:1559-1560`.
    pub const PROGRAM_RAIL_WIDTH: f32 = 350.;
    pub const PROGRAM_RAIL_HEIGHT: f32 = 430.;
    /// Program card and the empty state's content width
    /// (`StageProgramRailView` measurements recorded in the parity log).
    pub const PROGRAM_CARD_WIDTH: f32 = 294.;
    pub const PROGRAM_CARD_HEIGHT: f32 = 76.;
    pub const PROGRAM_CARD_ACTIVE_HEIGHT: f32 = 74.;
    pub const PROGRAM_EMPTY_WIDTH: f32 = 142.;
    pub const PROGRAM_EMPTY_HEIGHT: f32 = 64.;
    pub const PROGRAM_CARD_GAP: f32 = 4.;

    // ---- moved verbatim from `stage_panels::metrics` (2026-10-08). The two
    // ---- values that already existed above (`PANEL_MAX_WIDTH`,
    // ---- `PANEL_MAX_HEIGHT`) are referenced there instead of re-declared;
    // ---- `GROUP_GAP` (12) is renamed because this module's `GROUP_GAP` is the
    // ---- transport bar's 6 pt gap.

    // ---- panel shell: StageVisualPickerView body (:2741-2807) ----
    /// `.padding(7)` outside the surface.
    pub const PANEL_OUTER_PADDING: f32 = 7.;
    /// `.padding(16)` inside the surface.
    pub const PANEL_PADDING: f32 = 16.;
    /// `RoundedRectangle(cornerRadius: 18)`.
    pub const PANEL_RADIUS: f32 = 18.;
    /// `.padding(.bottom, 4)` on the scroll content (:2776).
    pub const CONTENT_BOTTOM_PADDING: f32 = 4.;
    /// Title `"舞台设置"`: size 16, weight .semibold (:2745).
    pub const TITLE_SIZE: f32 = 16.;
    /// Mode readout: size 12, `.white.opacity(0.64)` (:2747-2749).
    pub const MODE_SIZE: f32 = 12.;
    pub const MODE_TEXT: u32 = 0xffffffa3;
    /// Player-effects info label in space mode: `.white.opacity(0.72)` (:2766).
    pub const INFO_TEXT: u32 = 0xffffffb8;
    /// Outer `VStack(spacing: 12)` (:2742) and the player group spacing.
    /// (Was `metrics::GROUP_GAP`; renamed to avoid this module's transport
    /// `GROUP_GAP`.)
    pub const PANEL_GROUP_GAP: f32 = 12.;
    /// `motionGroup` / `activityGroup` `VStack(spacing: 10)` (:2823, :2883).
    pub const GROUP_ROW_GAP: f32 = 10.;
    /// `.font(.system(size: 12))` on the motion and activity groups (:2874, :2911).
    pub const GROUP_TEXT_SIZE: f32 = 12.;
    /// `pickerHeader`: size 14, weight .semibold, `.white.opacity(0.9)` (:3214-3221).
    pub const SECTION_TITLE_SIZE: f32 = 14.;

    // ---- visual grid: `LazyVGrid(columns: GridItem(.adaptive(minimum:)), spacing: 6)`
    // ---- (:2733-2735, :3038, :3056, :3108) ----
    pub const GRID_SPACING: f32 = 6.;
    pub const GRID_MIN_LYRICS: f32 = 90.;
    pub const GRID_MIN_POINT_CLOUD: f32 = 110.;
    pub const GRID_MIN_VIDEO: f32 = 108.;

    // ---- pickerButton (:3272-3316) ----
    pub const TILE_MIN_HEIGHT: f32 = 48.;
    pub const TILE_RADIUS: f32 = 13.;
    pub const TILE_GAP: f32 = 5.;
    pub const TILE_ICON_SIZE: f32 = 14.;
    /// Unselected text: `.white.opacity(0.62)`.
    pub const TILE_TEXT: u32 = 0xffffff9e;
    /// Selected text: the layer's one selected colour, [`super::scene::SELECTED`].
    pub const TILE_TEXT_SELECTED: u32 = super::scene::SELECTED;
    /// `.white.opacity(0.045)`.
    pub const TILE_FILL: u32 = 0xffffff0b;
    /// Selected tile fill: the layer's selected wash,
    /// [`super::scene::SELECTED_SOFT`].
    pub const TILE_FILL_SELECTED: u32 = super::scene::SELECTED_SOFT;
    /// `.white.opacity(0.07)`.
    pub const TILE_BORDER: u32 = 0xffffff12;
    /// Selected tile hairline: the layer's one selected colour,
    /// [`super::scene::SELECTED`].
    pub const TILE_BORDER_SELECTED: u32 = super::scene::SELECTED;
    pub const TILE_BORDER_WIDTH: f32 = 0.8;
    pub const TILE_BORDER_WIDTH_SELECTED: f32 = 1.;
    /// Hover/press fill: one step above the resting tile fill, still fixed.
    pub const TILE_FILL_HOVER: u32 = 0xffffff1a;

    // ---- world menu label (:2938-2963) ----
    pub const MENU_MIN_HEIGHT: f32 = 36.;
    pub const MENU_RADIUS: f32 = 12.;
    /// `.white.opacity(0.68)`.
    pub const MENU_TEXT: u32 = 0xffffffad;

    // ---- slider rows: particleSizeGroup (:3072-3102) / video brightness (:3135-3154) ----
    pub const SLIDER_ROW_H_PADDING: f32 = 10.;
    pub const SLIDER_ROW_MIN_HEIGHT: f32 = 36.;
    pub const READOUT_WIDTH: f32 = 38.;
    /// `.white.opacity(0.68)`.
    pub const READOUT_TEXT: u32 = 0xffffffad;

    // ---- avatarPlacementGroup (:2968-3010, :3223-3256) ----
    pub const AXIS_LABEL_WIDTH: f32 = 12.;
    /// `.white.opacity(0.52)`.
    pub const AXIS_LABEL_TEXT: u32 = 0xffffff85;
    pub const AXIS_READOUT_WIDTH: f32 = 42.;
    /// `.white.opacity(0.68)`.
    pub const AXIS_READOUT_TEXT: u32 = 0xffffffad;
    pub const AXIS_ROW_MIN_HEIGHT: f32 = 36.;
    pub const AXIS_ROW_GAP: f32 = 9.;
    pub const AXIS_STACK_GAP: f32 = 5.;

    // ---- row controls: motionGroup (:2839-2861) / activityGroup (:2887-2899) ----
    pub const ROW_PADDING: f32 = 10.;
    pub const ROW_RADIUS: f32 = 10.;
    pub const ROW_GAP: f32 = 10.;
    /// `.white.opacity(0.05)` row fill.
    pub const ROW_FILL: u32 = 0xffffff0d;
    pub const ROW_FILL_HOVER: u32 = 0xffffff1a;
    /// `.caption` on an incompatible motion's reason (:2850).
    pub const REASON_SIZE: f32 = 10.;
    /// The motion row's inner `VStack(alignment: .leading, spacing: 3)` (:2847).
    pub const ROW_STACK_GAP: f32 = 3.;

    // ---- loadingStatusGroup (:3012-3032) ----
    /// `Color.cyan.opacity(0.72)`.
    pub const LOADING_TEXT: u32 = 0x22d3eeb8;
    /// `Color.orange.opacity(0.78)`.
    pub const FAILURE_TEXT: u32 = 0xff9500c7;

    /// Destructive menu role, pinned: the original uses the system's
    /// `.destructive` tint, and a system tint is exactly what must not change
    /// when the OS flips appearance.
    pub const DANGER_TEXT: u32 = 0xff5a52f2;
}

/// 「我的物件」 — the original `ResidentPropEditorView`
/// (`VisualEngine/ResidentPropEditorView.swift`) plus
/// `StageWindowController.swift:1522` for the frame.
///
/// Moved verbatim from `stage_panels::metrics::props` (2026-10-08); `PANEL_WIDTH`
/// is the same 340 pt constraint as [`stage::PROP_EDITOR_WIDTH`], so it points at
/// that one value instead of declaring a second copy.
pub mod props {
    /// `propEditorPanel.widthAnchor.constraint(equalToConstant: 340)`.
    pub const PANEL_WIDTH: f32 = super::stage::PROP_EDITOR_WIDTH;
    /// `.frame(maxHeight: 390)` on the panel body.
    pub const PANEL_MAX_HEIGHT: f32 = 390.;
    /// The same body once 「还有 N 件」 is clicked: the pane may claim the whole
    /// extent the shell measured for it, and the shell's own ceiling for a
    /// non-chat pane is [`stage::PANEL_MAX_HEIGHT`]. Declared as that ceiling
    /// instead of a new number, so the window (小窗 / 全屏) still decides how
    /// tall the panel may become (`shell_ui.rs::panel_extent`).
    pub const PANEL_MAX_HEIGHT_EXPANDED: f32 = super::stage::PANEL_MAX_HEIGHT;
    /// The vertical band a bottom-right pane must stay out of: two
    /// [`super::shell::TRANSPORT_INSET`]s, the bar itself and the composer gap —
    /// the same subtraction `shell_ui.rs::panel_extent` makes before it caps the
    /// pane's container. The pane keeps its own copy because it must never draw
    /// taller than the box the shell clips it to: a panel that overflows the
    /// extent loses exactly its **bottom**, which is where the 「还有 N 件」
    /// footer lives (measured at 720×482: pane 390 pt inside a 374 pt box).
    pub const PANEL_VIEWPORT_BOTTOM_BAND: f32 = super::shell::TRANSPORT_INSET * 2.
        + super::shell::TRANSPORT_HEIGHT
        + super::shell::COMPOSER_GAP;
    /// `.padding(16)` on the content.
    pub const PANEL_PADDING: f32 = 16.;
    /// `RoundedRectangle(cornerRadius: 16)`.
    pub const PANEL_RADIUS: f32 = 16.;
    /// Outer `VStack(alignment: .leading, spacing: 14)` (:22).
    pub const GROUP_GAP: f32 = 14.;
    /// `.font(.system(size: 12))` on the whole body (:121).
    pub const BODY_SIZE: f32 = 12.;
    /// Header `Label("摆放")`: size 14, weight .semibold (:24).
    pub const TITLE_SIZE: f32 = 14.;
    /// `Button { … }.frame(width: 24, height: 24)` (:26).
    pub const CLOSE_BUTTON: f32 = 24.;
    /// Section rows `VStack(alignment: .leading, spacing: 8)` (:157).
    pub const SECTION_GAP: f32 = 8.;
    /// A section `VStack(alignment: .leading, spacing: 4)` (:178).
    pub const SECTION_ROW_GAP: f32 = 4.;
    /// A row `VStack(alignment: .leading, spacing: 3)` (:218).
    pub const ROW_GAP: f32 = 3.;
    /// `.padding(9).frame(maxWidth: .infinity)` (:239).
    pub const ROW_PADDING: f32 = 9.;
    /// `RoundedRectangle(cornerRadius: 8)` (:241).
    pub const ROW_RADIUS: f32 = 8.;
    /// Selected row: the layer's selected wash,
    /// [`super::scene::SELECTED_SOFT`] (was `Color.white.opacity(0.08)`; a
    /// selected row and a merely-hovered row must not both read as grey).
    pub const ROW_FILL_SELECTED: u32 = super::scene::SELECTED_SOFT;
    /// Resting row: `Color.white.opacity(0.03)`.
    pub const ROW_FILL: u32 = 0xffffff08;
    pub const ROW_FILL_HOVER: u32 = 0xffffff14;
    /// First line `HStack(alignment: .firstTextBaseline, spacing: 9)` (:219).
    pub const ROW_HEAD_GAP: f32 = 9.;
    /// Section heading `HStack(spacing: 6)` (:179).
    pub const HEADING_GAP: f32 = 6.;
    /// `.font(.system(size: 10, weight: .semibold))` on a heading (:197).
    pub const HEADING_SIZE: f32 = 10.;
    /// `row.statusText` `.font(.system(size: 10))` (:223).
    pub const STATUS_SIZE: f32 = 10.;
    /// Actions `HStack(spacing: 5)` / `HStack(spacing: 6)` (:234, :250).
    pub const ACTION_GAP: f32 = 6.;
    /// The empty-list sentence `.padding(.vertical, 14)` (:154).
    pub const EMPTY_PADDING_V: f32 = 14.;
    /// The held controls' `HStack(spacing: 8)` (:42, :52, :60).
    pub const CONTROL_GAP: f32 = 8.;
    /// `holdStep` nudge row `HStack(spacing: 7)` (:48).
    pub const NUDGE_GAP: f32 = 7.;
    /// Nudge distance: `.help("微调 2 厘米")` (:331).
    pub const NUDGE_METERS: f64 = 0.02;
    /// Rotation button step: `左转 15°` / `右转 15°` (:53-54).
    pub const ROTATE_DEGREES: i32 = 15;
    /// Reason text `.font(.system(size: 10))` (:69).
    pub const REASON_SIZE: f32 = 10.;
    /// Pointer hint `.font(.system(size: 11))` (:71-72).
    pub const HINT_SIZE: f32 = 11.;
    /// Legend `HStack(spacing: 10)` / entry `HStack(spacing: 4)` (:89, :95).
    pub const LEGEND_GAP: f32 = 10.;
    pub const LEGEND_ENTRY_GAP: f32 = 4.;
    /// `RoundedRectangle(cornerRadius: 2).frame(width: 8, height: 8)` (:96-102).
    pub const LEGEND_SWATCH: f32 = 8.;
    pub const LEGEND_SWATCH_RADIUS: f32 = 2.;
    /// Legend label `.font(.system(size: 10))` (:103).
    pub const LEGEND_SIZE: f32 = 10.;
    /// `Divider().overlay(.white.opacity(0.08))` (:40, :340).
    pub const DIVIDER: u32 = 0xffffff14;
    /// The size block's `HStack(spacing: 6)` / `HStack(spacing: 8)` (:342, :349).
    pub const SIZE_STEP_GAP: f32 = 6.;
    pub const SIZE_SLIDER_GAP: f32 = 8.;
    /// Size readouts `.font(.system(size: 11))` (:347, :359-360).
    pub const READOUT_SIZE: f32 = 11.;
    /// `Text(…).frame(width: 52, alignment: .trailing)` (:360).
    pub const READOUT_WIDTH: f32 = 52.;
    /// Size description `.font(.system(size: 10))` (:362).
    pub const DESCRIPTION_SIZE: f32 = 10.;
    /// `WorldPropSizePolicy.minimumExtentMeters ... maximumExtentMeters`.
    pub const SIZE_MIN: f32 = 0.02;
    pub const SIZE_MAX: f32 = 3.0;
    pub const SIZE_STEP: f32 = 0.01;
    /// The four `sizeStep` deltas (:343-344), in button order.
    pub const SIZE_DELTAS: [f64; 4] = [-0.10, -0.01, 0.01, 0.10];
    /// Slot picker `.frame(width: 156).controlSize(.small)` (:325-326).
    pub const SLOT_PICKER_WIDTH: f32 = 156.;
    pub const SLOT_PICKER_HEIGHT: f32 = 24.;

    /// State tints (`ownershipTint`, :301-308) and the selection check.
    /// `awaitingClaim` → `.cyan`; `inInventory` → `.orange.opacity(0.9)`;
    /// `failed` → `.red.opacity(0.9)`; the rest → `.secondary`.
    pub const TINT_AWAITING_CLAIM: u32 = 0x22d3ee;
    pub const TINT_IN_INVENTORY: u32 = 0xff9500e6;
    pub const TINT_FAILED: u32 = 0xff5a52e6;
    pub const TINT_NEUTRAL: u32 = 0xffffff73;
    /// The selected-row checkmark: the layer's one selected colour,
    /// [`super::scene::SELECTED`] (:225 records `.cyan`).
    pub const CHECK: u32 = super::scene::SELECTED;
}

/// 节目轨道 — the original `StageProgramRailView` / `StageProgramRailCard`
/// (`VisualEngine/StageOverlayView.swift:3353-4245`) plus
/// `StageWindowController.swift:1559-1560` for the frame.
///
/// Moved verbatim from `stage_panels::metrics::program` (2026-10-08). Where a
/// value is already declared for the same original constraint in
/// [`stage`] (`RAIL_WIDTH`/`RAIL_HEIGHT`, `TRACK_CARD_WIDTH`/`TRACK_CARD_HEIGHT`)
/// this module points at that one value instead of declaring a second copy.
pub mod program {
    /// `programRail.widthAnchor.constraint(equalToConstant: 350)` /
    /// `heightAnchor … 430`.
    pub const RAIL_WIDTH: f32 = super::stage::PROGRAM_RAIL_WIDTH;
    pub const RAIL_HEIGHT: f32 = super::stage::PROGRAM_RAIL_HEIGHT;
    /// `.padding(.top, 42).padding(.trailing, 10)` (:3638-3639).
    pub const RAIL_TOP: f32 = 42.;
    pub const RAIL_TRAILING: f32 = 10.;
    /// Outer `VStack(alignment: .trailing, spacing: 8)` (:3627).
    pub const RAIL_GAP: f32 = 8.;
    /// `.contentMargins(.vertical, 18)` (:3754, :3872).
    pub const CONTENT_MARGIN: f32 = 18.;

    /// Catalog `LazyVStack(alignment: .trailing, spacing: 4)` (:3657).
    pub const CATALOG_SPACING: f32 = 4.;
    /// Track `LazyVStack(alignment: .trailing, spacing: -7)` (:3820).
    pub const TRACK_SPACING: f32 = -7.;

    // ---- programCard / syncedPlaylistButton geometry (:3724, :3942, :4122) ----
    pub const CATALOG_CARD_WIDTH: f32 = 306.;
    pub const CATALOG_CARD_HEIGHT: f32 = 74.;
    pub const CATALOG_CARD_RADIUS: f32 = 22.;
    pub const TRACK_CARD_WIDTH: f32 = super::stage::PROGRAM_CARD_WIDTH;
    pub const TRACK_CARD_HEIGHT: f32 = super::stage::PROGRAM_CARD_HEIGHT;
    pub const TRACK_CARD_RADIUS: f32 = 23.;
    pub const CARD_H_PADDING: f32 = 14.;
    pub const CARD_GAP: f32 = 13.;
    /// `StageProgramRailCardLayout.horizontalOffset` (:3370-3380):
    /// focused -30, otherwise `min(2, |relativeIndex|) * 9`.
    pub const CARD_OFFSET_FOCUSED: f64 = -30.;
    pub const CARD_OFFSET_STEP: f64 = 9.;
    pub const CARD_OFFSET_LIMIT: i64 = 2;
    /// `rotation3DEffect` angles (:3742, :4195-4200).
    pub const CATALOG_ROTATION: f64 = -7.;
    pub const TRACK_ROTATION_FOCUSED: f64 = -4.;
    pub const TRACK_ROTATION_BASE: f64 = -10.;
    pub const TRACK_ROTATION_STEP: f64 = 2.5;
    pub const PERSPECTIVE: f64 = 0.72;
    /// `scaleEffect(isFocused ? card.scale + 0.055 : card.scale)` (:4189-4192).
    pub const FOCUS_SCALE_BUMP: f64 = 0.055;
    /// Card typography (:3676-3692, :4097-4111).
    pub const CARD_TITLE_SIZE: f64 = 16.;
    pub const CARD_TITLE_CURRENT_SIZE: f64 = 17.;
    pub const CARD_SUBTITLE_SIZE: f64 = 13.;
    pub const CARD_ARTIST_SIZE: f64 = 14.;
    pub const CARD_TITLE_COLOR: &str = "#ebeff2";
    pub const CARD_SUBTITLE_COLOR: &str = "#ffffff7a";
    /// `Circle().frame(width: 42/44)` artwork plate (:3666, :4093).
    pub const CARD_PLATE_CATALOG: f64 = 42.;
    pub const CARD_PLATE_TRACK: f64 = 44.;
    /// Energy trace `.frame(width: 28, height: 22)` with seven 2 pt bars
    /// (:4232-4243).
    pub const ENERGY_BARS: usize = 7;
    pub const ENERGY_BAR_WIDTH: f64 = 2.;
    pub const ENERGY_BASE: f32 = 5.;
    pub const ENERGY_SWING: f32 = 13.;
    pub const ENERGY_WAVE_BASE: f32 = 0.36;
    pub const ENERGY_WAVE_SWING: f32 = 0.64;
    /// Bound-video button `.frame(width: 26, height: 26).offset(x: -9, y: 8)`
    /// (:4180, :4184).
    pub const VIDEO_BUTTON: f32 = 26.;
    pub const VIDEO_OFFSET_RIGHT: f32 = 9.;
    pub const VIDEO_OFFSET_TOP: f32 = 8.;

    // ---- header: railHeader (:3884-3895) and trackList header (:3784-3816) ----
    pub const HEADER_CATALOG_GAP: f32 = 10.;
    pub const HEADER_TRACK_GAP: f32 = 8.;
    pub const HEADER_H_PADDING: f32 = 14.;
    pub const HEADER_SIZE: f32 = 14.;
    pub const HEADER_TEXT: u32 = 0xffffff9e;
    /// `replanButton`: `.frame(width: 28, height: 28)`, icon size 13 (:3975-3991).
    pub const REPLAN_BUTTON: f32 = 28.;
    pub const REPLAN_ICON: f32 = 13.;
    pub const REPLAN_FILL: u32 = 0xffffff0f;
    /// `.accessibilityLabel("重新编排后续歌曲")` (:4000).
    pub const REPLAN_LABEL: &str = "重新编排后续歌曲";
    /// Back chevron `.font(.system(size: 12, weight: .semibold))` (:3789).
    pub const BACK_ICON: f32 = 12.;
    pub const BACK_LABEL: &str = "返回节目单";
    /// Playlist spinner `.frame(width: 306, height: 44)` (:3863).
    pub const PAGING_WIDTH: f32 = 306.;
    pub const PAGING_HEIGHT: f32 = 44.;

    // ---- emptyState (:4030-4048) ----
    /// `HStack(spacing: 12)`; `.padding(.horizontal, 20)`;
    /// `.frame(height: 64)`; `RoundedRectangle(cornerRadius: 22)`.
    pub const EMPTY_GAP: f64 = 12.;
    pub const EMPTY_H_PADDING: f64 = 20.;
    pub const EMPTY_HEIGHT: f64 = 64.;
    pub const EMPTY_RADIUS: f64 = 22.;
    /// `Image(systemName: "waveform.path")` `.font(.system(size: 18, weight: .medium))`.
    pub const EMPTY_SYMBOL_SIZE: f64 = 18.;
    pub const EMPTY_SYMBOL_WIDTH: f64 = 26.;
    /// `Text(…).font(.system(size: 16, weight: .semibold, design: .rounded))`.
    pub const EMPTY_TEXT_SIZE: f64 = 16.;
    pub const EMPTY_TEXT: &str = "#ffffffd6";
    pub const EMPTY_STROKE: &str = "#00ffff";
    pub const EMPTY_STROKE_OPACITY: f64 = 0.24;
    /// The original `.padding(.top, 96)` above the empty state (:3650, :3779).
    pub const EMPTY_TOP_PADDING: f32 = 96.;
    /// Playlist loading `VStack(spacing: 10)` + `.font(.system(size: 13))`
    /// (:3764-3772).
    pub const LOADING_GAP: f32 = 10.;
    pub const LOADING_SIZE: f32 = 13.;
    pub const LOADING_TEXT: u32 = 0xffffff94;

    // ---- the catalog list itself (歌单 · N) ----------------------------------
    //
    // Source: the original Unity 「音乐库 / 歌单」 panel the 音乐与节目 control
    // opened — `apps/unity-player/Assets/GMGN/Resources/MusicLibrary.uss` plus
    // its builder `MusicLibraryPanel.cs` (`BuildList` / `BuildProgramList`).
    //
    // The macOS stage rail (the rest of this module) is a 350×430 floating card
    // column; the catalog the person actually opens is a **list** that fills its
    // panel. The 2026-10-09 report 「顶部一大片空白、内容挤在下半屏」 is what
    // happens when the floating-card geometry is used for the list: 306 pt cards
    // right-aligned inside a 590 pt panel, 42 + 18 pt of top inset, and the
    // bottom third of the panel empty.
    //
    /// `.music-library-playlist-slot { height: 84px; padding: 0 0 8px 0 }`.
    pub const LIST_SLOT_HEIGHT: f32 = 84.;
    pub const LIST_SLOT_PADDING: f32 = 8.;
    /// `.music-library-playlist { height: 76px; padding: 12px; border-radius:
    /// 18px; border-width: 1px }`.
    pub const LIST_ROW_HEIGHT: f32 = 76.;
    pub const LIST_ROW_PADDING: f32 = 12.;
    pub const LIST_ROW_RADIUS: f32 = 18.;
    pub const LIST_ROW_BORDER: f32 = 1.;
    /// `background-color: rgba(40, 44, 50, 0.86)`.
    pub const LIST_ROW_BG: u32 = 0x282c32db;
    /// `.music-library-current { background-color: #083b51 }`, re-toned onto the
    /// pinned overlay selection surface. The original literal is recorded here
    /// because the theme gate forbids drawing a control from the system theme —
    /// this is still a fixed overlay value, just the layer's own selected blue.
    pub const LIST_CURRENT_BG: u32 = super::scene::SELECTED_SOFT;
    /// `.music-library-cover { width: 44px; height: 44px; margin-right: 12px;
    /// border-radius: 12px; background-color: rgba(120, 70, 70, 0.2) }`.
    pub const LIST_COVER: f32 = 44.;
    pub const LIST_COVER_GAP: f32 = 12.;
    pub const LIST_COVER_RADIUS: f32 = 12.;
    pub const LIST_COVER_BG: u32 = 0x78464633;
    /// `.music-library-secondary { margin-top: 4px }`.
    pub const LIST_SECONDARY_GAP: f32 = 4.;
    /// `.music-library-trailing { margin-left: 8px }`, and
    /// `.music-library-playlist > .music-library-trailing { font-size: 22px }` —
    /// the 「›」 affordance.
    pub const LIST_TRAILING_GAP: f32 = 8.;
    pub const LIST_TRAILING_SIZE: f32 = 22.;
    /// `.music-library-track-slot { height: 64px; padding: 0 0 6px 0 }` and
    /// `.music-library-track { height: 58px; padding: 8px 12px; border-radius:
    /// 12px; background-color: rgba(40, 44, 50, 0.65) }`, with
    /// `.music-library-number { width: 24px; margin-right: 8px }` — the 序号
    /// column the list shows before the title.
    pub const LIST_TRACK_SLOT_HEIGHT: f32 = 64.;
    pub const LIST_TRACK_SLOT_PADDING: f32 = 6.;
    pub const LIST_TRACK_HEIGHT: f32 = 58.;
    pub const LIST_TRACK_PADDING_V: f32 = 8.;
    pub const LIST_TRACK_RADIUS: f32 = 12.;
    pub const LIST_TRACK_BG: u32 = 0x282c32a6;
    pub const LIST_NUMBER_WIDTH: f32 = 24.;
    pub const LIST_NUMBER_GAP: f32 = 8.;
    /// `.music-library-header { margin-bottom: 12px }`.
    pub const LIST_HEADER_GAP: f32 = 12.;
}

/// System inbox window.
///
/// Source: `Presence/ResidentSystemInboxUI.swift:109` (720×460), `:122`
/// (44 pt row), `:170-178` (10 pt window inset, 300 pt list column, 320×220
/// detail floor), `:218-256` (cell insets and typography) and `:136-153`
/// (detail inset, 12 pt body, 11 pt placeholder).
pub mod inbox {
    pub const WINDOW_WIDTH: f32 = 720.;
    pub const WINDOW_HEIGHT: f32 = 460.;
    /// The list column's preferred width in the pane's own 720×460 window.
    pub const LIST_WIDTH: f32 = 300.;
    /// Its floor when the pane is mounted in a narrower surface than that
    /// window — the media panel. The detail column keeps its
    /// [`DETAIL_MIN_WIDTH`] floor, so the list is the column that gives way
    /// (see [`PANE_MIN_WIDTH`] for the width the host has to hand the pane).
    /// The standalone 720×460 window still shows the full [`LIST_WIDTH`],
    /// because 720 pt has room for both.
    pub const LIST_MIN_WIDTH: f32 = 240.;

    /// The split's insets inside the content view (`:170-173`).
    pub const PANEL_INSET: f32 = 10.;
    /// The detail stack keeps 8 pt from the split's trailing edge (`:175`).
    pub const DETAIL_TRAILING: f32 = 8.;

    /// `tableView.rowHeight` (`:122`).
    pub const ROW_HEIGHT: f32 = 44.;
    /// Cell insets: 8 pt leading (`:241`) / trailing (`:249-250`) and 6 pt
    /// above the title (`:246`).
    pub const ROW_PADDING_H: f32 = 8.;
    pub const ROW_PADDING_V: f32 = 6.;
    /// Unread badge column: 10 pt wide (`:243`) with 6 pt before the title
    /// (`:244`); the glyph itself is 9 pt (`:223`).
    pub const DOT_WIDTH: f32 = 10.;
    pub const DOT_GAP: f32 = 6.;
    pub const DOT_SIZE: f32 = 9.;
    /// 6 pt between the title and the time (`:245`).
    pub const TITLE_TIME_GAP: f32 = 6.;

    /// Row typography: 12 pt medium title (`:225`), 10 pt status 2 pt under it
    /// (`:229,248`), 10 pt relative time (`:233`).
    pub const TITLE_SIZE: f32 = 12.;
    pub const TITLE_LINE_HEIGHT: f32 = 16.;
    pub const STATUS_SIZE: f32 = 10.;
    pub const STATUS_LINE_HEIGHT: f32 = 14.;
    pub const STATUS_GAP: f32 = 2.;
    pub const TIME_SIZE: f32 = 10.;

    /// Detail column: 8 pt stack spacing (`:158`), 12 pt text inset (`:136`),
    /// 12 pt body (`:137`), the 320×220 floor (`:176-177`) and the 11 pt
    /// placeholder (`:153`).
    pub const STACK_GAP: f32 = 8.;
    pub const DETAIL_PADDING: f32 = 12.;
    pub const DETAIL_SIZE: f32 = 12.;
    pub const DETAIL_LINE_HEIGHT: f32 = 18.;
    pub const DETAIL_MIN_WIDTH: f32 = 320.;
    pub const DETAIL_MIN_HEIGHT: f32 = 220.;
    pub const PLACEHOLDER_SIZE: f32 = 11.;

    /// The pane's own horizontal demand: both column floors plus the split's
    /// insets (240 + 320 + 2 × 10 = 580 pt). The pane's own 720 pt window has
    /// room to spare; **a host that mounts the pane has to hand it at least
    /// this much**, because the detail keeps its floor and the list will not go
    /// below its own. The media panel's floor is this plus the media surface's
    /// padding and its 1 pt border on both sides
    /// (`media_ui::PANEL_CONTENT_FLOOR` = 614), and that is the width the
    /// shell's panel extent really asks for — before it, the panel handed the
    /// pane 558 pt and the pane could not fit.
    pub const PANE_MIN_WIDTH: f32 = LIST_MIN_WIDTH + DETAIL_MIN_WIDTH + 2. * PANEL_INSET;

    /// The window forces `NSAppearance(named: .darkAqua)` (`:112`), so these
    /// stay fixed: the `systemBlue` badge (`:222`), a white title (`:226`),
    /// 0.6 status (`:230`), 0.88 detail (`:138`) and 0.4 placeholder (`:152`).
    /// The 0.45 time and empty labels reuse [`super::scene::TEXT_MUTED`].
    pub const UNREAD_DOT: u32 = 0x0a84ffff;
    pub const TITLE_TEXT: u32 = 0xffffffff;
    pub const STATUS_TEXT: u32 = 0xffffff99;
    pub const DETAIL_TEXT: u32 = 0xffffffe0;
    pub const PLACEHOLDER_TEXT: u32 = 0xffffff66;
}

/// Settings window.
///
/// Source: `docs/plans/2026-10-04-gpui-ui-parity.md:53` — the original system
/// settings window is 580×500 with a 540×440 minimum and a 330-wide five-segment
/// header 14 from the top and 8 above the content.
pub mod settings {
    pub const WINDOW_WIDTH: f32 = 580.;
    pub const WINDOW_HEIGHT: f32 = 500.;
    pub const MIN_WIDTH: f32 = 540.;
    pub const MIN_HEIGHT: f32 = 440.;
    pub const SEGMENT_WIDTH: f32 = 330.;
    pub const SEGMENT_TOP: f32 = 14.;
    pub const SEGMENT_BOTTOM: f32 = 8.;

    // ---- moved verbatim from `settings::metrics` (2026-10-08). Sources:
    // ---- `PresenceSettingsView.swift:180-219,258-433,435-458` — header, rows,
    // ---- preview, orb;
    // ---- `MusicAccountsView.swift:68-152` — header and provider rows;
    // ---- `AgentSettingsView.swift:226-472` — DJ sections and header;
    // ---- `GMGNKeyboardShortcuts.swift:625-732` — shortcut grid;
    // ---- `GMGNSettingsView.swift:127-251` +
    // ---- `PropGenerationSettingsSection.swift:23-62` — space page.

    /// A macOS regular-height `NSSegmentedControl` (what
    /// `.pickerStyle(.segmented)` resolves to) is 24 pt. Kit's segmented
    /// `small` tab bar is exactly 24, so the height is asserted here instead of
    /// being forced onto the element (v50: a fixed height fought the tab's own
    /// padding).
    pub const SEGMENT_HEIGHT: f32 = 24.;

    /// Page header: `padding(.horizontal, 20)` + `padding(.vertical, 18)`
    /// (`PresenceSettingsView.swift:217-218`, `MusicAccountsView.swift:77-78`,
    /// `GMGNSettingsView.swift:151-152`, `GMGNKeyboardShortcuts.swift:635-636`).
    /// `AgentSettingsView.swift:470-471` uses 14.
    pub const HEADER_PADDING_H: f32 = 20.;
    pub const HEADER_PADDING_V: f32 = 18.;
    pub const AGENT_HEADER_PADDING_V: f32 = 14.;
    /// `VStack(alignment: .leading, spacing: 3)` in every page header.
    pub const HEADER_TITLE_GAP: f32 = 3.;
    /// `HStack(spacing: 14)` for header actions (`PresenceSettingsView.swift:181`).
    pub const HEADER_ACTION_GAP: f32 = 14.;

    /// The grouped `Form` owns its own inset; the pane reproduces it as the
    /// single scroll area's padding.
    pub const CONTENT_PADDING_H: f32 = 20.;
    pub const CONTENT_PADDING_BOTTOM: f32 = 14.;
    /// Notice footer: `padding(.horizontal, 20)` + `padding(.bottom, 14)`
    /// (`PresenceSettingsView.swift:144-145`, `AgentSettingsView.swift:445-446`).
    pub const NOTICE_GAP: f32 = 7.;
    pub const NOTICE_MAX_HEIGHT: f32 = 42.;
    pub const NOTICE_ICON: f32 = 14.;

    /// Card surface for one original `Section`: token padding plus the section
    /// title/content gaps.
    pub const SECTION_PADDING: f32 = 15.;
    pub const SECTION_TITLE_GAP: f32 = 8.;
    pub const SECTION_CONTENT_GAP: f32 = 12.;
    /// Rows use `spacing: 12` and `padding(.vertical, 3)`
    /// (`PresenceSettingsView.swift:264,303,332,377`).
    pub const ROW_GAP: f32 = 12.;
    pub const ROW_PADDING_V: f32 = 3.;
    /// `MusicAccountsView.swift:129` uses `padding(.vertical, 4)`.
    pub const MUSIC_ROW_PADDING_V: f32 = 4.;

    /// `PresencePreview().frame(width: 44, height: 44)`, `cornerRadius: 11`,
    /// blue `opacity(0.07)` (`PresenceSettingsView.swift:265,427-431`).
    pub const PREVIEW_SIZE: f32 = 44.;
    pub const PREVIEW_RADIUS: f32 = 11.;
    pub const PREVIEW_ICON: f32 = 26.;
    pub const PREVIEW_BG_ALPHA: f32 = 0.07;
    pub const PREVIEW_GLYPH_ALPHA: f32 = 0.75;
    /// `OrbPreview().padding(3)` inside the 44 pt frame.
    pub const ORB_INSET: f32 = 3.;
    /// `Circle().stroke(.white.opacity(0.9), lineWidth: 1)`
    /// (`PresenceSettingsView.swift:453`).
    pub const ORB_STROKE: f32 = 1.;

    /// `MotionRow`: 40×40 icon plate, `cornerRadius: 10`, icon 18 pt,
    /// compatibility `opacity(0.10)` (`PresenceSettingsView.swift:333-343`).
    pub const MOTION_ICON_BOX: f32 = 40.;
    pub const MOTION_ICON_RADIUS: f32 = 10.;
    pub const MOTION_ICON_SIZE: f32 = 18.;
    pub const MOTION_ICON_ALPHA: f32 = 0.10;
    /// `PublishedMotionRow`: `frame(width: 28, height: 28)` icon
    /// (`PresenceSettingsView.swift:234`).
    pub const PUBLISHED_ICON_BOX: f32 = 28.;
    pub const PUBLISHED_ICON_SIZE: f32 = 18.;
    /// `Text("\(Int(flowIntensity * 100))%").frame(width: 42, alignment: .trailing)`
    /// (`PresenceSettingsView.swift:123-126`).
    pub const ORB_PERCENT_WIDTH: f32 = 42.;

    /// `MusicAccountRow`: 32×32 plate, `cornerRadius: 8`, `opacity(0.1)`
    /// (`MusicAccountsView.swift:90-94`).
    pub const PROVIDER_ICON_BOX: f32 = 32.;
    pub const PROVIDER_ICON_RADIUS: f32 = 8.;
    pub const PROVIDER_ICON_SIZE: f32 = 18.;
    pub const PROVIDER_ICON_ALPHA: f32 = 0.10;

    /// `AgentSettingsView.swift:228-235`: 32×32 plate, `cornerRadius: 8`,
    /// blue `opacity(0.12)`.
    pub const AGENT_ICON_BOX: f32 = 32.;
    pub const AGENT_ICON_RADIUS: f32 = 8.;
    pub const AGENT_ICON_SIZE: f32 = 18.;
    pub const AGENT_ICON_ALPHA: f32 = 0.12;
    /// `TextEditor(...).frame(minHeight: 150)` / `120`
    /// (`AgentSettingsView.swift:307,324`).
    pub const HOST_PROMPT_MIN_HEIGHT: f32 = 150.;
    pub const RESIDENT_PROMPT_MIN_HEIGHT: f32 = 120.;
    /// `TextField(...).frame(width: 220)` (`AgentSettingsView.swift:300`).
    pub const PLANNING_MODEL_WIDTH: f32 = 220.;
    /// `Picker(...).frame(width: 160)` (`AgentSettingsView.swift:408`).
    pub const BUDGET_WIDTH: f32 = 160.;
    /// The API-key fields sit in a 280 pt column (existing transport layout).
    pub const KEY_FIELD_WIDTH: f32 = 280.;

    /// `GMGNSettingsView.swift:172-176`: the Marble icon column is 28 pt wide.
    pub const MARBLE_ICON_COLUMN: f32 = 28.;
    pub const MARBLE_ICON_SIZE: f32 = 22.;

    /// `Column spacing: 16`, `frame(width: 112)` monospaced key text, row
    /// `padding(.vertical, 3)` (`GMGNKeyboardShortcuts.swift:640,669,727`).
    pub const SHORTCUT_GRID_GAP: f32 = 16.;
    pub const SHORTCUT_COLUMN_WIDTH: f32 = 136.;
    pub const SHORTCUT_TEXT_WIDTH: f32 = 112.;
    /// The original uses `.font(.body.monospaced())`, i.e. the 13 pt body face.
    /// This is the single type exception on this surface; the document scale has
    /// no monospaced role, so it is pinned here with its source.
    pub const SHORTCUT_TEXT_SIZE: f32 = 13.;
    /// The original `.monospaced()` family. GPUI resolves it through the system
    /// font stack; the name mirrors the existing `stage_panels` usage.
    pub const MONO_FAMILY: &str = "Menlo";

    /// Shortcut recording tint: the original applies `.tint(.cyan)`
    /// (`GMGNKeyboardShortcuts.swift:731`); the overlay accent is the same hue.
    pub const RECORDING_TINT_ALPHA: f32 = 0.14;
    pub const RECORDING_TINT_HOVER_ALPHA: f32 = 0.22;
    pub const RECORDING_TINT_ACTIVE_ALPHA: f32 = 0.30;

    /// `AddPresenceFromLinkSheet`: `.frame(width: 460, height: 230)`,
    /// `padding(24)` (`PresenceSettingsView.swift:500-501`).
    pub const LINK_SHEET_WIDTH: f32 = 460.;
    pub const LINK_SHEET_HEIGHT: f32 = 230.;
    pub const LINK_SHEET_PADDING: f32 = 24.;

    /// Unity settings window category sidebar (owned by the Unity host chrome,
    /// `gmgn-unity-settings.rs`).
    pub const SIDEBAR_WIDTH: f32 = 200.;
    /// The embedded stage panel needs a definite height inside the Unity
    /// window's scroll area; the previous layout pinned 380
    /// (`settings.rs` v51 embedded branch).
    pub const STAGE_EMBED_HEIGHT: f32 = 380.;

    /// The recorder's incomplete-combination copy. It has no i18n catalog entry
    /// yet (`i18n.rs` is owned elsewhere); the original string is used verbatim.
    pub const SHORTCUT_INCOMPLETE: &str = "请按一个完整的按键组合。";
}

/// Product shell: transport bar, destination button, task feedback, Live Cam.
///
/// Sources: `StageOverlayView.swift:2683-2694` (`transportWidth` is derived from
/// nine 44 pt buttons, the 68 pt settings button, two 4 pt side insets and the
/// extra control slot the stage view adds, plus a rounding term),
/// `StageWindowController.swift:1541-1542` (the original's 529×48 bar),
/// `:1533-1538` (22 from the right and bottom), `:1577-1590` (destination 112×38
/// at right 22 / top 28), `:1521` (task feedback 280 wide), `LiveCamPanel.swift:102`
/// (224×336).
///
/// The 529 in the original is the width of *its* control set under *its* spacing.
/// The rework runs a flex row that gaps every neighbouring pair of children —
/// the controls plus the 1 pt group hairlines — so the same eleven controls plus
/// one divider lay out at [`TRANSPORT_WIDTH`](shell::TRANSPORT_WIDTH) = 584 here.
/// The number that matters is that the derivation and the render agree; the
/// pixel-level check is `tests/transport_popover_geometry.rs`.
pub mod shell {
    /// The bar's real laid-out width for the product's eleven-control set — ten
    /// 44 pt slots + the 68 pt settings slot + the 1 pt group divider 下首 ends
    /// its group with + two 4 pt side insets + eleven 6 pt flex gaps + the
    /// original's rounding term = 584, which is exactly what
    /// [`super::shell::transport_width`] returns for those controls.
    ///
    /// It is **not** independent of the control set, and it used to be wrong:
    /// this constant held 529 while the bar it describes painted 584, because
    /// `transport_width` summed only two group gaps instead of the `n - 1` gaps
    /// a flex row really puts between its children. A host that places the bar by
    /// the derivation put a 584 pt bar inside a 529 pt budget — 55 pt of it off
    /// the canvas edge. The constant now agrees with the derivation, and
    /// `tests/transport_popover_geometry.rs` ties the derivation to the bar's own
    /// prepared-layout rect in pixels.
    pub const TRANSPORT_WIDTH: f32 = 584.;
    pub const TRANSPORT_HEIGHT: f32 = 48.;
    pub const TRANSPORT_INSET: f32 = 22.;
    /// 9 regular buttons + settings + the extra control slot + insets + gaps.
    pub const REGULAR_BUTTONS: usize = 9;
    /// The original's own `+ 1` term in `transportWidth` (rounding guard, see
    /// `StageOverlayView.swift:2693`).
    pub const TRANSPORT_ROUNDING: f32 = 1.;

    pub const DESTINATION_WIDTH: f32 = 112.;
    pub const DESTINATION_HEIGHT: f32 = 38.;
    pub const DESTINATION_TOP: f32 = 28.;

    pub const TASK_FEEDBACK_WIDTH: f32 = 280.;
    pub const TASK_FEEDBACK_INSET: f32 = 22.;

    pub const COMPACT_WIDTH: f32 = 224.;
    pub const COMPACT_HEIGHT: f32 = 336.;

    /// The original separates the transport groups with a 1×20 hairline.
    pub const TRANSPORT_DIVIDER: (f32, f32) = (1., 20.);

    /// Transport surface: `StageWindowController.swift:2839-2842`.
    pub const TRANSPORT_BG: u32 = 0x13161bfa;
    /// The original's transport hairline: white @ 0.12.
    pub const TRANSPORT_BORDER: u32 = 0xffffff1f;

    /// Destination button (`StageWindowController.swift:3165-3185`).
    pub const DESTINATION_BORDER: u32 = 0x47dbff7a;
    pub const DESTINATION_TEXT: u32 = 0x7af2ffff;

    /// Screen-operation banner (`:3003-3030`): 12 pt radius, 226×30, centred
    /// 12 above the bar.
    pub const SCREEN_BANNER: u32 = 0x0a4d6beb;
    pub const SCREEN_BANNER_BORDER: u32 = 0x22d3ee73;
    pub const SCREEN_BANNER_WIDTH: f32 = 226.;
    pub const SCREEN_BANNER_HEIGHT: f32 = 30.;
    pub const SCREEN_BANNER_RADIUS: f32 = 12.;

    /// Live Cam control column: 30 pt buttons, 6 pt gaps, 10 pt insets
    /// (`LiveCamPanel.swift:945-950`).
    pub const COMPACT_CONTROL: f32 = 30.;
    pub const COMPACT_CONTROL_GAP: f32 = 6.;
    pub const COMPACT_CONTROL_INSET: f32 = 10.;
    /// Compact reply bubble: expanded 136, collapsed at most 74, radius 12.
    pub const COMPACT_REPLY_EXPANDED: f32 = 136.;
    pub const COMPACT_REPLY_COLLAPSED: f32 = 74.;
    pub const COMPACT_REPLY_RADIUS: f32 = 12.;

    // ---- moved out of `main.rs::mod chrome` (2026-10-08): everything the
    // ---- floating bar, the destination control, the task banners and the Live
    // ---- Cam surfaces need that `scene`/`stage` did not already carry. Each
    // ---- entry keeps the Swift source the host had on it.

    /// Every transport button's own surface radius
    /// (`StageWindowController.swift:3056` and siblings).
    pub const CONTROL_RADIUS: f32 = 10.;
    /// 舞台设置 label (`StageVisualButton`, `:3100-3102`): size 12, 6 pt inset.
    pub const CONTROL_LABEL_SIZE: f32 = 12.;
    pub const CONTROL_LABEL_INSET: f32 = 6.;

    /// The destination control (`:3165-3185`): glyph point size, the original
    /// pill's own type size/gap (kept pinned for the original reading) and its
    /// 19 pt radius.
    pub const DESTINATION_ICON: f32 = 12.;
    pub const DESTINATION_FONT: f32 = 11.;
    pub const DESTINATION_GAP: f32 = 4.;
    pub const DESTINATION_RADIUS: f32 = 19.;

    /// 16 pt between the composer and the transport bar
    /// (`StageWindowController.swift:1529`).
    pub const COMPOSER_GAP: f32 = 16.;
    /// 12 pt between the screen banner and the transport bar (`:1546-1548`).
    pub const SCREEN_BANNER_GAP: f32 = 12.;
    /// The banner's 12 pt medium label (`:3003-3030`).
    pub const SCREEN_BANNER_FONT: f32 = 12.;

    /// Task-status banners: `StageOverlayView.swift:96-108` (speech error) and
    /// `:130-215` (`WishMachineTaskStatusView`). Their surface is
    /// `Color(white: 0.1).opacity(0.96)` — `scene::PANEL_BG` — so only the
    /// radius, the padding and the compact/normal type sizes live here.
    pub const BANNER_RADIUS: f32 = 10.;
    pub const BANNER_PADDING: f32 = 10.;
    pub const BANNER_PADDING_COMPACT: f32 = 6.;
    pub const BANNER_STACK_GAP: f32 = 6.;
    pub const BANNER_TITLE: f32 = 10.;
    pub const BANNER_TITLE_COMPACT: f32 = 9.;
    pub const BANNER_BODY: f32 = 9.;
    pub const NOTICE_FONT: f32 = 11.;
    pub const NOTICE_FONT_COMPACT: f32 = 9.;
    pub const DELIVERY_FONT: f32 = 10.;
    pub const STATUS_DETAIL_FONT: f32 = 9.;

    /// Unread badge on the 通知 entry (`ResidentSystemInboxUI.swift:28-46`):
    /// `systemRed.opacity(0.9)`, 7 pt radius, 14 pt square, 9 pt semibold.
    pub const BADGE_BG: u32 = 0xff453ae6;
    pub const BADGE_TEXT: u32 = 0xffffffff;
    pub const BADGE_RADIUS: f32 = 7.;
    pub const BADGE_SIZE: f32 = 14.;
    pub const BADGE_TOP: f32 = 1.;
    pub const BADGE_OFFSET: f32 = 4.;
    pub const BADGE_FONT: f32 = 9.;

    /// Live Cam control column (`LiveCamPanel.swift:700,860-877`: 30 pt entries
    /// 6 pt apart, 10 pt from the top/right edge). The surface is `:945-950`:
    /// `white 0.12 @0.94`, `white 0.18` border, `scene::CONTROL_RADIUS`.
    pub const COMPACT_MARGIN: f32 = 10.;
    pub const COMPACT_CONTROL_BG: u32 = 0x1f1f1ff0;
    pub const COMPACT_CONTROL_BORDER: u32 = 0xffffff2e;
    pub const COMPACT_TINT: u32 = 0xffffffff;
    /// Every Live Cam overlay stops 8 pt before the reserved control column
    /// (`LiveCamPanel.swift:889`).
    pub const COMPACT_COLUMN_GAP: f32 = 8.;
    /// Right edge shared by the Live Cam composer and the reply bubble:
    /// 10 pt margin + 30 pt control column + 8 pt reserved gap.
    pub const COMPACT_CONTENT_RIGHT: f32 = COMPACT_MARGIN + COMPACT_CONTROL + COMPACT_COLUMN_GAP;
    pub const COMPACT_NOTICE_GAP: f32 = 6.;
    /// Reply bubble (`LiveCamPanel.swift:828-834,902-918`): 10/8 padding, 5 pt
    /// gap, 12 pt text and a 20×20 dismiss button. Its 12 pt radius and 136/74
    /// heights are [`COMPACT_REPLY_RADIUS`] / [`COMPACT_REPLY_EXPANDED`] /
    /// [`COMPACT_REPLY_COLLAPSED`] above.
    pub const COMPACT_BUBBLE_PADDING: (f32, f32) = (10., 8.);
    pub const COMPACT_BUBBLE_GAP: f32 = 5.;
    pub const COMPACT_BUBBLE_FONT: f32 = 12.;
    pub const COMPACT_DISMISS: f32 = 20.;
}

#[cfg(test)]
mod tests {
    #[test]
    fn surface_metrics_match_the_original_sources() {
        use super::{inbox, settings, shell, stage};
        assert_eq!(stage::PANEL_MAX_WIDTH, 590.);
        assert_eq!(stage::PANEL_MAX_HEIGHT, 458.);
        assert_eq!(stage::PROP_EDITOR_WIDTH, 340.);
        assert_eq!(stage::PROGRAM_RAIL_WIDTH, 350.);
        assert_eq!(stage::PROGRAM_RAIL_HEIGHT, 430.);
        assert_eq!([stage::PROGRAM_CARD_WIDTH, stage::PROGRAM_CARD_HEIGHT], [294., 76.]);
        assert_eq!([stage::PROGRAM_EMPTY_WIDTH, stage::PROGRAM_EMPTY_HEIGHT], [142., 64.]);
        assert_eq!([inbox::WINDOW_WIDTH, inbox::WINDOW_HEIGHT, inbox::LIST_WIDTH], [720., 460., 300.]);
        // The pane's own floor is a derivation, and it is the number a host has
        // to hand the pane: both column floors plus the split's insets.
        assert_eq!(inbox::LIST_MIN_WIDTH, 240.);
        assert_eq!(inbox::DETAIL_MIN_WIDTH, 320.);
        assert_eq!(inbox::PANE_MIN_WIDTH, 580.);
        assert_eq!(
            inbox::PANE_MIN_WIDTH,
            inbox::LIST_MIN_WIDTH + inbox::DETAIL_MIN_WIDTH + 2. * inbox::PANEL_INSET
        );
        // The media panel is the narrow host of this pane, and its own floor is
        // the pane's demand plus the media surface's padding and border:
        // 580 + 2 × 16 + 2 × 1 = 614 pt, which is *wider* than the original
        // stage panel's 590 pt ceiling. The two column floors must never be
        // asked to fit less.
        assert!(
            inbox::PANE_MIN_WIDTH > stage::PANEL_MAX_WIDTH - 2. * inbox::PANEL_INSET,
            "the pane needs more than the original panel's outer width can give it"
        );
        assert_eq!([settings::WINDOW_WIDTH, settings::WINDOW_HEIGHT], [580., 500.]);
        assert_eq!([settings::MIN_WIDTH, settings::MIN_HEIGHT], [540., 440.]);
        assert_eq!(settings::SEGMENT_WIDTH, 330.);
        assert_eq!([shell::COMPACT_WIDTH, shell::COMPACT_HEIGHT], [224., 336.]);
        assert_eq!([shell::DESTINATION_WIDTH, shell::DESTINATION_HEIGHT], [112., 38.]);
        assert_eq!(shell::TASK_FEEDBACK_WIDTH, 280.);

        // The transport width is a derivation, not an independent number, and
        // the derivation counts the bar's **real flex children**: eleven control
        // slots (nine regular + settings + the extra control slot), one 1 pt
        // group divider, two 4 pt insets, one 6 pt gap between each neighbouring
        // pair of those twelve children, and the rounding term.
        let controls = shell::REGULAR_BUTTONS + 2;
        let dividers = 1;
        let children = controls + dividers;
        let derived = stage::CONTROL_SIZE * (shell::REGULAR_BUTTONS as f32 + 1.)
            + stage::SETTINGS_WIDTH
            + shell::TRANSPORT_DIVIDER.0 * dividers as f32
            + 2. * stage::SIDE_INSET
            + (children - 1) as f32 * stage::GROUP_GAP
            + shell::TRANSPORT_ROUNDING;
        assert_eq!(derived, shell::TRANSPORT_WIDTH);
        assert_eq!(shell::TRANSPORT_HEIGHT, 48.);
        assert_eq!(shell::TRANSPORT_INSET, 22.);
    }

    /// The surface readings that used to live in the four local `metrics`
    /// modules (`stage_panels::metrics`, its `props`/`program` children and
    /// `settings::metrics`) are now the single copy in `ui_tokens`; this pins
    /// enough of each to prove the move kept the values and their types.
    #[test]
    fn moved_surface_metrics_keep_their_original_readings() {
        use super::{program, props, settings, shell, stage};
        // stage_panels::metrics → stage
        assert_eq!([stage::PANEL_OUTER_PADDING, stage::PANEL_PADDING, stage::PANEL_RADIUS], [7., 16., 18.]);
        assert_eq!([stage::PANEL_GROUP_GAP, stage::GROUP_ROW_GAP, stage::GROUP_TEXT_SIZE], [12., 10., 12.]);
        assert_eq!([stage::GRID_SPACING, stage::GRID_MIN_LYRICS, stage::GRID_MIN_POINT_CLOUD, stage::GRID_MIN_VIDEO], [6., 90., 110., 108.]);
        assert_eq!([stage::TILE_MIN_HEIGHT, stage::TILE_RADIUS, stage::TILE_GAP, stage::TILE_ICON_SIZE], [48., 13., 5., 14.]);
        assert_eq!([stage::AXIS_ROW_GAP, stage::AXIS_STACK_GAP, stage::REASON_SIZE, stage::ROW_STACK_GAP], [9., 5., 10., 3.]);
        assert_eq!([stage::MODE_TEXT, stage::INFO_TEXT, stage::TILE_TEXT_SELECTED, stage::DANGER_TEXT], [0xffffffa3, 0xffffffb8, 0x3b9effff, 0xff5a52f2]);
        // Every selected-state token is the same bright blue, declared once.
        assert_eq!(stage::TILE_TEXT_SELECTED, super::scene::SELECTED);
        assert_eq!(stage::TILE_FILL_SELECTED, super::scene::SELECTED_SOFT);
        assert_eq!(stage::TILE_BORDER_SELECTED, super::scene::SELECTED);
        assert_eq!(props::ROW_FILL_SELECTED, super::scene::SELECTED_SOFT);
        assert_eq!(props::CHECK, super::scene::SELECTED);
        assert_eq!(super::scene::ICON_ACTIVE, super::scene::SELECTED);
        assert_eq!(super::scene::ACCENT, super::scene::SELECTED);
        // stage_panels::metrics::props → props (PANEL_WIDTH aliases stage)
        assert_eq!(props::PANEL_WIDTH, stage::PROP_EDITOR_WIDTH);
        assert_eq!([props::PANEL_MAX_HEIGHT, props::PANEL_PADDING, props::PANEL_RADIUS], [390., 16., 16.]);
        // 「还有 N 件」 expands to the shell's own ceiling for this pane — the
        // 390 pt body is the *collapsed* frame, never the ceiling.
        assert_eq!(props::PANEL_MAX_HEIGHT_EXPANDED, stage::PANEL_MAX_HEIGHT);
        assert!(props::PANEL_MAX_HEIGHT_EXPANDED > props::PANEL_MAX_HEIGHT);
        assert_eq!([props::ROW_GAP, props::ROW_PADDING, props::ROW_RADIUS], [3., 9., 8.]);
        assert_eq!(props::SIZE_DELTAS, [-0.10, -0.01, 0.01, 0.10]);
        assert_eq!([props::TINT_AWAITING_CLAIM, props::TINT_IN_INVENTORY, props::TINT_FAILED], [0x22d3ee, 0xff9500e6, 0xff5a52e6]);
        // stage_panels::metrics::program → program
        assert_eq!([program::RAIL_WIDTH, program::RAIL_HEIGHT], [350., 430.]);
        assert_eq!(program::TRACK_CARD_WIDTH, stage::PROGRAM_CARD_WIDTH);
        assert_eq!(program::TRACK_CARD_HEIGHT, stage::PROGRAM_CARD_HEIGHT);
        assert_eq!([program::CATALOG_CARD_WIDTH, program::CATALOG_CARD_HEIGHT, program::CATALOG_CARD_RADIUS], [306., 74., 22.]);
        assert_eq!(program::TRACK_SPACING, -7.);
        assert_eq!([program::CARD_OFFSET_FOCUSED, program::PERSPECTIVE], [-30., 0.72]);
        assert_eq!(program::ENERGY_BARS, 7);
        assert_eq!(program::EMPTY_HEIGHT, 64.);
        assert_eq!(program::EMPTY_TOP_PADDING, 96.);
        // settings::metrics → settings
        assert_eq!([settings::SEGMENT_HEIGHT, settings::HEADER_PADDING_H, settings::AGENT_HEADER_PADDING_V], [24., 20., 14.]);
        assert_eq!([settings::PREVIEW_SIZE, settings::PREVIEW_RADIUS, settings::ORB_INSET], [44., 11., 3.]);
        assert_eq!([settings::MOTION_ICON_BOX, settings::PROVIDER_ICON_BOX, settings::AGENT_ICON_BOX], [40., 32., 32.]);
        assert_eq!([settings::HOST_PROMPT_MIN_HEIGHT, settings::RESIDENT_PROMPT_MIN_HEIGHT], [150., 120.]);
        assert_eq!([settings::LINK_SHEET_WIDTH, settings::LINK_SHEET_HEIGHT, settings::LINK_SHEET_PADDING], [460., 230., 24.]);
        assert_eq!(settings::SHORTCUT_INCOMPLETE, "请按一个完整的按键组合。");
        // main.rs::mod chrome → shell
        assert_eq!([shell::CONTROL_RADIUS, shell::CONTROL_LABEL_SIZE, shell::CONTROL_LABEL_INSET], [10., 12., 6.]);
        assert_eq!([shell::DESTINATION_ICON, shell::DESTINATION_FONT, shell::DESTINATION_RADIUS], [12., 11., 19.]);
        assert_eq!([shell::TRANSPORT_BG, shell::TRANSPORT_BORDER], [0x13161bfa, 0xffffff1f]);
        assert_eq!(shell::BADGE_BG, 0xff453ae6);
        assert_eq!([shell::BADGE_RADIUS, shell::BADGE_SIZE, shell::BADGE_FONT], [7., 14., 9.]);
        assert_eq!([shell::SCREEN_BANNER_WIDTH, shell::SCREEN_BANNER_HEIGHT, shell::SCREEN_BANNER_GAP], [226., 30., 12.]);
        assert_eq!([shell::COMPACT_MARGIN, shell::COMPACT_CONTROL, shell::COMPACT_COLUMN_GAP, shell::COMPACT_CONTENT_RIGHT], [10., 30., 8., 48.]);
        assert_eq!([shell::COMPACT_REPLY_EXPANDED, shell::COMPACT_REPLY_COLLAPSED, shell::COMPACT_DISMISS], [136., 74., 20.]);
    }

    #[test]
    fn embedded_player_sections_show_distinct_real_controls(){
        use crate::stage_panels::player_section_includes as includes;
        assert!(includes("歌词","lyrics"));assert!(!includes("歌词","clouds"));
        assert!(includes("视觉效果","clouds"));assert!(!includes("视觉效果","videoModes"));
        assert!(includes("视频","videoModes"));assert!(!includes("视频","lyrics"));
    }
    #[test]
    fn kit_small_control_uses_shared_semantic_text_size() {
        use gpui_kit::{Styled, div};
        use gpui_kit::component::Size;
        use gpui_kit::component::StyleSized;
        let mut label = div().button_text_size(Size::Small);
        let mut semantic = div().text_sm();
        assert_eq!(label.style().text_style().font_size, semantic.style().text_style().font_size);
    }
    #[test]
    fn hierarchy_and_spacing_are_stable() {
        assert_eq!([super::CAPTION, super::BODY, super::SUBTITLE, super::TITLE], [12., 14., 16., 20.]);
        assert_eq!([super::SPACING_4, super::SPACING_8, super::SPACING_12, super::SPACING_16, super::SPACING_24], [4., 8., 12., 16., 24.]);
        assert_eq!(super::FONT_FAMILY, ".SystemUIFont");
    }

    #[test]
    fn stage_style_choices_have_named_button_roles() {
        let (role, label) = crate::stage_panels::style_choice_accessibility("字幕特效", "经典", true);
        assert_eq!(role, gpui_kit::Role::Button);
        assert_eq!(label, "字幕特效：经典，已选择");
        assert_eq!(crate::stage_panels::style_choice_accessibility("字幕特效", "经典", false).1, "字幕特效：经典");
    }

    /// The original composer numbers, pinned one by one. A local edit that
    /// "looks fine" but moves a panel off the original metrics fails here.
    #[test]
    fn chat_metrics_match_the_original_composer() {
        use super::chat as c;
        assert_eq!(c::PANEL_MAX_WIDTH, 620.);
        assert_eq!(c::PANEL_MAX_HEIGHT, 320.);
        assert_eq!(c::HISTORY_HEIGHT, 132.);
        assert_eq!([c::HISTORY_PADDING_H, c::HISTORY_PADDING_V], [16., 12.]);
        assert_eq!([c::HISTORY_RADIUS, c::CARD_RADIUS], [16., 20.]);
        assert_eq!(c::CARD_PADDING, 15.);
        assert_eq!([c::LABEL_SIZE, c::MESSAGE_SIZE, c::NOTICE_SIZE, c::STATUS_SIZE], [10., 13., 11., 11.]);
        assert_eq!([c::ATTACHMENT_WIDTH, c::ATTACHMENT_HEIGHT], [54., 46.]);
        assert_eq!(c::INPUT_ROWS, (1, 3));
        assert_eq!([c::INPUT_MIN_HEIGHT, c::INPUT_MAX_HEIGHT], [26., 64.]);
        assert_eq!([c::COMPACT_IDLE_HEIGHT, c::COMPACT_ATTACHED_HEIGHT], [70., 140.]);
    }

    /// Overlay chrome must stay theme-independent: these are the original's
    /// fixed dark surfaces, and none of them may equal its document text colour.
    #[test]
    fn scene_chrome_stays_fixed_dark_and_distinct() {
        use super::scene as s;
        assert_eq!(s::CARD_BG, 0x262626fa);
        assert_eq!(s::PANEL_BG, 0x1a1a1af5);
        assert_eq!(s::BORDER, 0xffffff1a);
        assert!(s::CARD_BG < 0x80000000, "card surface must stay dark");
        assert!(s::PANEL_BG < 0x80000000, "history surface must stay dark");
        assert_ne!(s::TEXT_MUTED, s::TEXT);
        assert_ne!(s::BORDER, s::BORDER_FOCUSED);
        assert_eq!(s::CONTROL_HEIGHT, 30.);
    }

    /// WCAG relative luminance of a resolved colour, so the contrast assertion
    /// below is computed from the pixels rather than restated as a constant.
    fn luminance(color: gpui_kit::gpui::Rgba) -> f64 {
        let channel = |value: f32| {
            let value = f64::from(value);
            if value <= 0.04045 {
                value / 12.92
            } else {
                ((value + 0.055) / 1.055).powf(2.4)
            }
        };
        0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
    }

    fn contrast(a: gpui_kit::gpui::Rgba, b: gpui_kit::gpui::Rgba) -> f64 {
        let (a, b) = (luminance(a), luminance(b));
        (a.max(b) + 0.05) / (a.min(b) + 0.05)
    }

    /// 选中态 must be a **bright blue**, written with all eight `0xRRGGBBAA`
    /// digits.
    ///
    /// The assertions read the colour GPUI's own `rgba` decodes — the value the
    /// renderer paints — and pin its channels to literal numbers, so this is not
    /// the constant compared with itself: put the old colour back (the six-digit
    /// `0x22d3ee`, which `rgba` reads as `rgb(0, 34, 211)` — a dark navy — or
    /// `0x7af2ff`, a cyan) and this test goes red.
    #[test]
    fn selected_blue_is_written_with_all_eight_digits() {
        use super::scene as s;
        let selected = gpui_kit::gpui::rgba(s::SELECTED);
        let channels = [
            (selected.r * 255.).round() as u32,
            (selected.g * 255.).round() as u32,
            (selected.b * 255.).round() as u32,
            (selected.a * 255.).round() as u32,
        ];
        assert_eq!(
            channels,
            [0x3b, 0x9e, 0xff, 0xff],
            "scene::SELECTED must resolve to the opaque bright blue #3B9EFF"
        );
        // Blue, not cyan and not a neutral: more blue than red, more green than
        // red, and bright enough to read as "lit" on the dark chrome.
        assert!(selected.b > selected.g && selected.g > selected.r, "got {channels:?}");
        assert!(selected.b >= 0.9 && selected.g >= 0.5, "the selected blue must be bright: {channels:?}");
        // Contrast on the fixed dark surfaces, computed from the pixels.
        for (name, surface) in [("CARD_BG", s::CARD_BG), ("PANEL_BG", s::PANEL_BG)] {
            let ratio = contrast(selected, gpui_kit::gpui::rgba(surface));
            assert!(ratio >= 4.5, "SELECTED must clear 4.5:1 on {name}, got {ratio:.2}:1");
        }
        // The six-digit trap: `rgba` reads the low byte as alpha, so a six-digit
        // literal is a *different, dark* colour. This is the bug that made the
        // old ACCENT paint `rgb(0, 34, 211)`.
        assert_ne!(
            gpui_kit::gpui::rgba(0x3b9eff),
            selected,
            "a six-digit literal is not SELECTED — `rgba` would read `ff` as alpha and drop the red channel"
        );
        // The wash keeps the same hue and is translucent.
        let soft = gpui_kit::gpui::rgba(s::SELECTED_SOFT);
        assert!(soft.a < 0.5 && soft.a > 0.05, "SELECTED_SOFT is a wash, got alpha {:.3}", soft.a);
        assert_eq!(
            [(soft.r * 255.).round() as u32, (soft.g * 255.).round() as u32, (soft.b * 255.).round() as u32],
            [0x3b, 0x9e, 0xff],
            "SELECTED_SOFT must be the same hue as SELECTED"
        );
    }
}
