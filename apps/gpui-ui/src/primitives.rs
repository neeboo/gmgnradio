//! Shared building blocks for the 2D UI layer that floats over the rendered
//! space.
//!
//! One surface, one place for chrome and type. Before this module each panel
//! spelled its own `div().rounded_lg().bg(theme.tokens.background)` and its own
//! literal font sizes, so the same visual role looked different in every panel
//! and every panel re-invented (or missed) the focus/active/drop states. The
//! rules are:
//!
//! 1. **Chrome comes from here** — [`scene_card`], [`scene_inset`], [`scene_bar`].
//! 2. **Type comes from here** — [`card_title`], [`section_title`], [`body`],
//!    [`muted`], [`notice`], [`empty_state`].
//! 3. **Controls are gpui-kit components.** [`icon_button`], [`bar_button`],
//!    [`primary_circle_button`] and [`capsule_button`] wrap
//!    `gpui_kit::component::button::Button`, which owns hover/press/focus,
//!    tooltips and the accessibility node. The one hand-rolled interactive
//!    element is push-to-talk ([`hold_button`]): kit's `Button` reports a click,
//!    and the original needs a press/release pair.
//! 4. **Overlay surfaces never read the system theme** (see
//!    [`crate::ui_tokens::scene`]); a light system theme must not invert a panel
//!    that sits on top of the scene.
//! 5. **Controls are icon-only.** Every button in this layer carries an icon;
//!    the words live in the tooltip and the accessibility label, never as a
//!    label inside the control. Text belongs to content — titles, section names,
//!    list rows, status lines, input placeholders, empty states — not to
//!    controls. [`bar_button`] therefore takes both an icon and a label, and the
//!    label is only ever the tooltip; [`capsule_button`] exists solely for the
//!    original's "停止说话" pill and must not be used for new controls.
//!
//! Helpers return the concrete `Div` so a surface can still add layout of its
//! own, and every helper that adds interaction takes the element id it needs —
//! an id is what makes a `Div` interactive in GPUI.
use gpui::{Div, ElementId, MouseButton, MouseDownEvent, MouseUpEvent, Rgba, SharedString, Stateful, px, rgba};
use gpui_kit::component::button::*;
use gpui_kit::component::slider::{Slider, SliderState};
use gpui_kit::component::switch::Switch;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::*;
use gpui_kit::prelude::{FluentBuilder as _, InteractiveElement as _, StatefulInteractiveElement as _};
use gpui_kit::*;

use crate::ui_tokens::FONT_FAMILY;
use crate::ui_tokens::scene as s;

/// The primary card of an overlay panel: fixed dark surface, hairline border.
pub fn scene_card() -> Div {
    div()
        .rounded(px(s::PANEL_RADIUS))
        .bg(rgba(s::CARD_BG))
        .border_1()
        .border_color(rgba(s::BORDER))
}

/// A secondary surface inside a panel (history block, inset list, footer).
pub fn scene_inset() -> Div {
    div()
        .rounded(px(s::PANEL_RADIUS_SMALL))
        .bg(rgba(s::PANEL_BG))
        .border_1()
        .border_color(rgba(s::BORDER))
}

/// A bar that rows of controls sit in (transport bar, panel header).
pub fn scene_bar() -> Div {
    div().rounded(px(s::PANEL_RADIUS)).bg(rgba(s::BAR_BG))
}

/// Window/panel title, one step above section titles.
pub fn card_title(text: impl Into<SharedString>) -> Div {
    div()
        .font_family(FONT_FAMILY)
        .text_size(px(crate::ui_tokens::SUBTITLE))
        .text_color(rgba(s::TEXT))
        .child(text.into())
}

/// Group heading inside a panel.
pub fn section_title(text: impl Into<SharedString>) -> Div {
    div()
        .font_family(FONT_FAMILY)
        .text_size(px(crate::ui_tokens::CAPTION))
        .text_color(rgba(s::TEXT_MUTED))
        .child(text.into())
}

/// Body copy over the scene.
pub fn body(text: impl Into<SharedString>) -> Div {
    div()
        .font_family(FONT_FAMILY)
        .text_size(px(crate::ui_tokens::BODY))
        .line_height(px(crate::ui_tokens::BODY_LINE_HEIGHT))
        .text_color(rgba(s::TEXT))
        .child(text.into())
}

/// Secondary copy: field descriptions, hints, readouts.
pub fn muted(text: impl Into<SharedString>) -> Div {
    div()
        .font_family(FONT_FAMILY)
        .text_size(px(crate::ui_tokens::CAPTION))
        .text_color(rgba(s::TEXT_MUTED))
        .child(text.into())
}

/// A recoverable problem the person must see (original `orange.opacity(0.95)`).
pub fn notice(text: impl Into<SharedString>) -> Div {
    div()
        .font_family(FONT_FAMILY)
        .text_size(px(crate::ui_tokens::CAPTION))
        .text_color(rgba(s::WARNING))
        .child(text.into())
}

/// The "there is nothing here yet" state of a list or panel.
pub fn empty_state(text: impl Into<SharedString>) -> Div {
    div()
        .font_family(FONT_FAMILY)
        .text_size(px(crate::ui_tokens::BODY))
        .text_color(rgba(s::TEXT_MUTED))
        .child(text.into())
}

/// A hairline divider between rows.
pub fn divider() -> Div {
    div().h(px(1.)).w_full().bg(rgba(s::BORDER))
}

/// **The one place an icon's colour is chosen.**
///
/// Every glyph in the overlay layer resolves through this function: the shared
/// controls below, and any call site that builds its own `Button::new(..).icon(..)`
/// or standalone `Icon::new(..)`. The mapping is the whole icon palette
/// (`ui_tokens::scene`), so a control can never fall back to a kit variant's
/// `cx.theme()` foreground and two controls on the same bar can never disagree:
///
/// * asserted/selected (`active`) → [`s::ICON_ACTIVE`], the bright blue;
/// * disabled (`!enabled`) → [`s::ICON_DISABLED`];
/// * otherwise → [`s::ICON`], the default bright glyph.
///
/// `active` is checked first on purpose: a control that marks the **current
/// selection** is usually also `.disabled(selected)` (there is nothing left to
/// click), and that control must still read as selected-blue rather than as a
/// greyed-out affordance.
///
/// [`s::ICON_ACTIVE`]: crate::ui_tokens::scene::ICON_ACTIVE
/// [`s::ICON_DISABLED`]: crate::ui_tokens::scene::ICON_DISABLED
/// [`s::ICON`]: crate::ui_tokens::scene::ICON
pub fn icon_color(active: bool, enabled: bool) -> Rgba {
    if active {
        rgba(s::ICON_ACTIVE)
    } else if !enabled {
        rgba(s::ICON_DISABLED)
    } else {
        rgba(s::ICON)
    }
}

/// A square icon control sized to the layer's control height.
///
/// `active` is the asserted state (toggled on / currently running); `enabled` is
/// the host's own condition — the two are separate because the colour they pick
/// is ([`icon_color`]). The control's colour and its disabled behaviour are set
/// **here**, so every call site passes its state instead of re-deriving a colour:
/// a caller that also calls `.disabled(..)` afterwards would only restate it.
pub fn icon_button(
    id: impl Into<ElementId>,
    icon: gpui_kit::assets::IconName,
    label: impl Into<SharedString>,
    active: bool,
    enabled: bool,
) -> Button {
    let label = label.into();
    Button::new(id)
        .ghost()
        .small()
        .icon(icon)
        .w(px(s::CONTROL_HEIGHT))
        .h(px(s::CONTROL_HEIGHT))
        .rounded(px(s::CONTROL_RADIUS))
        .text_color(icon_color(active, enabled))
        .disabled(!enabled)
        .tooltip(label.clone())
        .accessibility_label(label)
}

/// An icon-only control for a bar (transport, panel header).
///
/// `label` never renders inside the control: it becomes the tooltip and the
/// accessibility label, so the bar reads as icons while assistive tech and
/// hover still get the words. `icon` is required — there is no text face for a
/// control in this layer, so a `None` fallback would be a hole in the rule.
pub fn bar_button(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    icon: gpui_kit::assets::IconName,
    width: f32,
) -> Button {
    let label = label.into();
    Button::new(id)
        .ghost()
        .small()
        .w(px(width))
        .h(px(s::CONTROL_HEIGHT))
        .rounded(px(s::CONTROL_RADIUS))
        .text_color(icon_color(false, true))
        .tooltip(label.clone())
        .accessibility_label(label.clone())
        .icon(icon)
}

/// The primary emphasis control: a filled circle with a dark glyph, exactly the
/// original's send button. `enabled` selects between the resting and the
/// disabled fill rather than merely dimming the element, so the affordance
/// matches the original's.
pub fn primary_circle_button(
    cx: &App,
    id: impl Into<ElementId>,
    icon: gpui_kit::assets::IconName,
    label: impl Into<SharedString>,
    enabled: bool,
) -> Button {
    let label = label.into();
    let variant = ButtonCustomVariant::new(cx)
        .color(rgba(if enabled { s::FILL } else { s::FILL_DISABLED }).into())
        .foreground(rgba(s::ON_FILL).into())
        .hover(rgba(s::FILL).into())
        .active(rgba(s::FILL_DISABLED).into())
        .shadow(false);
    Button::new(id)
        .custom(variant)
        .small()
        .icon(icon)
        .w(px(s::CONTROL_HEIGHT))
        .h(px(s::CONTROL_HEIGHT))
        .rounded(px(s::CONTROL_RADIUS))
        .disabled(!enabled)
        .tooltip(label.clone())
        .accessibility_label(label)
}

/// The original's text pill. Do **not** use for new controls: this layer's
/// controls are icon-only (see the module docs), and this exists only because
/// the original shows words on this one during speech.
pub fn capsule_button(id: impl Into<ElementId>, label: impl Into<SharedString>) -> Button {
    let label = label.into();
    Button::new(id)
        .ghost()
        .small()
        .label(label.clone())
        .h(px(s::CONTROL_HEIGHT))
        .rounded(px(s::CONTROL_RADIUS))
        .text_color(rgba(s::TEXT))
        .tooltip(label.clone())
        .accessibility_label(label)
}

/// Push-to-talk: press and release, not a click.
///
/// Kit's `Button` only reports activation, so this is the sole hand-rolled
/// interactive element in the layer. It keeps the accessible role, label and
/// tooltip a kit control would provide, and reports release even when the
/// pointer leaves the control mid-press (`on_mouse_up_out`) — the original's
/// `DragGesture(minimumDistance: 0)` plus `onDisappear` do the same, and a press
/// that never releases would otherwise leave the microphone open.
pub fn hold_button(
    id: impl Into<ElementId>,
    a11y_id: &'static str,
    icon: gpui_kit::assets::IconName,
    label: impl Into<SharedString>,
    active: bool,
    on_press: impl Fn(&MouseDownEvent, &mut Window, &mut App) + 'static,
    on_release: impl Fn(&MouseUpEvent, &mut Window, &mut App) + 'static,
) -> Stateful<Div> {
    let label = label.into();
    let release = std::rc::Rc::new(on_release);
    let up = release.clone();
    let up_out = release.clone();
    let tooltip = label.clone();
    div()
        .id(id.into())
        .role(Role::Button)
        .accessibility_id(a11y_id)
        .aria_label(label.clone())
        .cursor_pointer()
        .flex()
        .items_center()
        .justify_center()
        .w(px(s::CONTROL_HEIGHT))
        .h(px(s::CONTROL_HEIGHT))
        .rounded(px(s::CONTROL_RADIUS))
        .text_color(icon_color(active, true))
        .tooltip(move |window, cx| Tooltip::new(tooltip.clone()).build(window, cx))
        .child(Icon::new(icon).small())
        .on_mouse_down(MouseButton::Left, on_press)
        .on_mouse_up(MouseButton::Left, move |event, window, cx| {
            up(event, window, cx)
        })
        .on_mouse_up_out(MouseButton::Left, move |event, window, cx| {
            up_out(event, window, cx)
        })
}

/// The original centres a control row's status text and lets it shrink before
/// any control does; `min_w(0)` is what makes that true in a flex row.
pub fn flex_status(text: impl Into<SharedString>) -> Div {
    div()
        .flex_1()
        .min_w(px(0.))
        .text_size(px(crate::ui_tokens::CAPTION))
        .text_color(rgba(s::TEXT_DIM))
        .child(text.into())
}

/// A bounded horizontal strip for thumbnails and chips. The id is required
/// because scroll behaviour in GPUI belongs to a stateful element.
pub fn h_strip(id: impl Into<ElementId>) -> Stateful<Div> {
    div()
        .id(id.into())
        .flex()
        .items_center()
        .gap(px(crate::ui_tokens::SPACING_8))
        .overflow_x_scroll()
        .w_full()
}

// ---------------------------------------------------------------------------
// 选中态 — the layer's one selected colour, and the controls that paint it
// ---------------------------------------------------------------------------
//
// Why these are hand-drawn rather than kit components: kit's `TabBar`/`Tab`,
// `ListItem::selected`, `Switch`'s checked track and `Slider`'s filled bar all
// resolve their **selected** surface through `cx.theme()` (`tab_active`,
// `list_active`/`accent`, `primary`, `slider_bar`), and `Tab`/`ListItem`/`Switch`
// expose no way to override those particular fields from outside — `Tab`'s own
// `.bg()`/`.text_color()` lose to the `styles().selected(..)` state style it
// registers while rendering. A theme-derived selected face is exactly what the
// layer must not have, so the selected face is drawn here, from
// [`crate::ui_tokens::scene::SELECTED`] and
// [`crate::ui_tokens::scene::SELECTED_SOFT`], and the kit widget is used only
// where its selected state is not part of the picture.

/// One face of a [`selected_tabs`] row.
#[derive(Clone)]
pub struct TabFace {
    /// The tooltip and the accessibility label — always present.
    pub label: SharedString,
    /// The glyph drawn on the face (an icon-only tab).
    pub icon: Option<gpui_kit::assets::IconName>,
    /// The words drawn on the face (a text tab). `None` for icon-only tabs.
    pub text: Option<SharedString>,
    /// A fixed width for an evenly divided row (the original's `n`-way slot
    /// picker). `None` lets the face grow.
    pub width: Option<f32>,
    /// The host's own condition; a disabled face still paints its selected
    /// colour when it is the current one.
    pub disabled: bool,
}

impl TabFace {
    /// A text face that grows to share the row.
    pub fn text(label: impl Into<SharedString>) -> Self {
        let label = label.into();
        Self {
            text: Some(label.clone()),
            label,
            icon: None,
            width: None,
            disabled: false,
        }
    }
    /// An icon-only face that grows to share the row.
    pub fn icon(icon: gpui_kit::assets::IconName, label: impl Into<SharedString>) -> Self {
        Self {
            label: label.into(),
            icon: Some(icon),
            text: None,
            width: None,
            disabled: false,
        }
    }
    pub fn width(mut self, width: f32) -> Self {
        self.width = Some(width);
        self
    }
    pub fn disabled(mut self, disabled: bool) -> Self {
        self.disabled = disabled;
        self
    }
}

/// One tab's face, styled from the layer's tokens. Public so a test can read the
/// style this really resolves to (the row below attaches the click and the
/// width; the *colour* lives here and nowhere else).
pub fn tab_face(id: impl Into<ElementId>, face: &TabFace, selected: bool) -> Stateful<Div> {
    // The selected face's fill and hairline are the layer's tokens; the resting
    // face is transparent so the row's own surface shows through.
    let mut tab = div()
        .id(id.into())
        .flex()
        .items_center()
        .justify_center()
        .gap(px(4.))
        .h_full()
        .min_w(px(0.))
        .rounded(px(s::CONTROL_RADIUS))
        .text_size(px(crate::ui_tokens::CAPTION))
        .text_color(rgba(if selected { s::SELECTED } else { s::TEXT_MUTED }))
        .role(Role::Button)
        .aria_label(face.label.clone())
        .when(selected, |tab| {
            tab.bg(rgba(s::SELECTED_SOFT))
                .border_1()
                .border_color(rgba(s::SELECTED))
        });
    if let Some(icon) = face.icon {
        tab = tab.child(Icon::new(icon).small());
    }
    if let Some(text) = &face.text {
        tab = tab.child(text.clone());
    }
    tab
}

/// A segmented selector whose **selected** face is painted from the layer's own
/// [`s::SELECTED_SOFT`]/[`s::SELECTED`] tokens, never from `cx.theme()`.
///
/// The geometry is the one the original's `NSSegmentedControl` resolves to
/// ([`crate::ui_tokens::settings::SEGMENT_HEIGHT`] = 24 pt), so it replaces a
/// kit `TabBar` without moving the pane. `selected` is an index into `faces`.
pub fn selected_tabs(
    id: impl Into<ElementId>,
    faces: Vec<TabFace>,
    selected: usize,
    on_select: impl Fn(usize, &mut Window, &mut App) + 'static,
) -> Stateful<Div> {
    let on_select = std::rc::Rc::new(on_select);
    let mut row = div()
        .id(id.into())
        .flex()
        .items_center()
        .gap(px(2.))
        .h(px(crate::ui_tokens::settings::SEGMENT_HEIGHT))
        .rounded(px(s::CONTROL_RADIUS))
        .bg(rgba(s::PANEL_BG));
    for (index, face) in faces.into_iter().enumerate() {
        let is_selected = index == selected;
        let click = on_select.clone();
        let mut tab = tab_face(("selected-tab", index), &face, is_selected)
            .when(!is_selected && !face.disabled, |tab| {
                tab.hover(|tab| tab.bg(rgba(s::SELECTED_SOFT)).opacity(0.6))
            })
            .when(!face.disabled, |tab| {
                tab.cursor_pointer().on_click(move |_, window, cx| {
                    click(index, window, cx);
                })
            });
        tab = match face.width {
            Some(width) => tab.w(px(width)),
            None => tab.flex_1(),
        };
        let label = face.label.clone();
        tab = tab.tooltip(move |window, cx| Tooltip::new(label.clone()).build(window, cx));
        row = row.child(tab);
    }
    row
}

/// The layer's **"this is the current one"** marker: the bright-blue glyph on
/// the selected wash, the shape the settings rows show for 使用中.
///
/// It is deliberately not a kit `Button`: the current item has nothing left to
/// click, and every kit variant paints its disabled/selected fill from
/// `cx.theme()`, so the selected face would stop being the layer's colour.
pub fn selected_marker(
    id: impl Into<ElementId>,
    icon: gpui_kit::assets::IconName,
    label: impl Into<SharedString>,
) -> Stateful<Div> {
    let label = label.into();
    div()
        .id(id.into())
        .role(Role::Button)
        .aria_label(label.clone())
        .flex()
        .items_center()
        .justify_center()
        .w(px(s::CONTROL_HEIGHT))
        .h(px(s::CONTROL_HEIGHT))
        .flex_shrink_0()
        .rounded(px(s::CONTROL_RADIUS))
        .bg(rgba(s::SELECTED_SOFT))
        .border_1()
        .border_color(rgba(s::SELECTED))
        .text_color(rgba(s::SELECTED))
        .child(Icon::new(icon).small())
        .tooltip(move |window, cx| Tooltip::new(label.clone()).build(window, cx))
}

/// The selected face of a kit [`Switch`]: its **checked** track, from the
/// layer's own token.
///
/// `Switch` is kept because its thumb travel is the control's affordance, but
/// the checked track would otherwise be `cx.theme().tokens.primary` — a
/// near-white bar under the dark theme — so every switch in the layer is built
/// through this function. The *unchecked* track and the thumb are still kit's
/// own neutral tokens (not accents); see the module docs.
pub fn selected_switch(id: impl Into<ElementId>) -> Switch {
    Switch::new(id).color(rgba(s::SELECTED))
}

/// A kit [`Slider`] whose **filled** (active) part and thumb are the layer's
/// selected colour, so the 音量 track and the panel sliders cannot inherit
/// `cx.theme().tokens.slider_bar`.
pub fn scene_slider(state: &gpui_kit::Entity<SliderState>) -> Slider {
    Slider::new(state)
        .bg(rgba(s::SELECTED))
        .text_color(rgba(s::SELECTED))
}

// ---------------------------------------------------------------------------
// 音量 — the transport bar's one slider, and its mute face
// ---------------------------------------------------------------------------

/// Thickness of the 音量 track's own box, across its axis.
///
/// 24 pt is kit's own vertical track width (`SliderTrack` is `w_6` in the
/// vertical mode), so the layer does not invent a second geometry for it.
pub const VOLUME_TRACK_THICKNESS: f32 = 24.;

/// Length of the 音量 track along its axis (kit's vertical mode is 120 pt long).
pub const VOLUME_TRACK_LENGTH: f32 = 120.;

/// The direction the 音量 track runs: **vertical, growing upward**.
///
/// This one value decides both the box the track is laid out in
/// ([`volume_track_box`]: longer than it is wide) and the mode kit's slider is
/// built in ([`volume_slider`]), so a horizontal 音量 bar cannot be built by
/// changing only one of them. Vertical is bottom-up because kit measures the
/// pointer from the track's **bottom** edge on the vertical axis
/// (`SliderState::update_value_by_position`), so dragging up raises the level.
pub const fn volume_track_axis() -> Axis {
    Axis::Vertical
}

/// The box a 音量 track is laid out in when it runs along `axis`: the long side
/// is always [`VOLUME_TRACK_LENGTH`], so a vertical track's resolved style is
/// taller than it is wide.
pub fn volume_track_box(axis: Axis) -> Div {
    let (width, height) = match axis {
        Axis::Vertical => (VOLUME_TRACK_THICKNESS, VOLUME_TRACK_LENGTH),
        Axis::Horizontal => (VOLUME_TRACK_LENGTH, VOLUME_TRACK_THICKNESS),
    };
    div()
        .flex()
        .items_center()
        .justify_center()
        .w(px(width))
        .h(px(height))
}

/// The 音量 popover's slider: kit's [`Slider`] in the track's own direction,
/// sized to the track's box.
///
/// `enabled` is the host's connectivity — the level cannot be published while
/// the music host is gone, so the control is disabled rather than silently
/// ignored. Dragging still reports through `SliderEvent`, which the caller
/// turns into the one `music.volume` command.
pub fn volume_slider(state: &gpui_kit::Entity<SliderState>, enabled: bool) -> impl IntoElement {
    let axis = volume_track_axis();
    // The track's filled part is the layer's selected colour, so the level is
    // read in the same bright blue as every other "current" state
    // ([`scene_slider`]); kit's default would be `theme.tokens.slider_bar`.
    let slider = match axis {
        Axis::Vertical => scene_slider(state).vertical(),
        Axis::Horizontal => scene_slider(state).horizontal(),
    };
    volume_track_box(axis).child(
        slider
            .w(px(VOLUME_TRACK_THICKNESS))
            .h(px(VOLUME_TRACK_LENGTH))
            .disabled(!enabled),
    )
}

/// The glyph a 音量 mute control paints: lucide's `volume-x` while muted and
/// `volume-2` while not.
///
/// Both are names the product's asset source embeds
/// (`gpui_kit::assets::AllAssets` in `apps/gpui-app/src/main.rs`), so neither
/// face paints an empty square — and both are glyphs, never a switch, a track
/// or a bar.
pub fn volume_mute_icon(muted: bool) -> gpui_kit::assets::IconName {
    if muted {
        gpui_kit::assets::IconName::VolumeX
    } else {
        gpui_kit::assets::IconName::Volume2
    }
}

/// The 音量 popover's mute control: a **small square icon button**, the same
/// [`icon_button`] every other control in this layer is — never a switch and
/// never a bar.
///
/// The words are only the tooltip and the accessibility label; the face is
/// [`volume_mute_icon`]'s glyph, which is what makes the muted and unmuted
/// states tell apart at a glance. It is one track wide
/// ([`VOLUME_TRACK_THICKNESS`]) rather than the bar's own control height, so the
/// popover stays a narrow column around its track. `enabled` follows the
/// slider's: the levels it writes are the same one `music.volume` command.
pub fn volume_mute_button(muted: bool, enabled: bool) -> Button {
    icon_button(
        "volume-mute",
        volume_mute_icon(muted),
        if muted { "取消静音" } else { "静音" },
        muted,
        enabled,
    )
    .w(px(VOLUME_TRACK_THICKNESS))
    .h(px(VOLUME_TRACK_THICKNESS))
}

#[cfg(test)]
mod tests {
    // gpui re-exports a `test` attribute macro; `super::*` would shadow the
    // built-in one, so name it explicitly like the rest of this crate does.
    use core::prelude::v1::test;
    use super::*;

    /// Chrome and type roles must resolve to the fixed overlay palette: a panel
    /// over the scene can never inherit a theme colour.
    #[test]
    fn overlay_helpers_use_fixed_scene_tokens() {
        assert_eq!(s::CARD_BG, 0x262626fa);
        assert_eq!(s::PANEL_BG, 0x1a1a1af5);
        assert!(s::CARD_BG < 0x80000000);
        assert!(s::TEXT != s::TEXT_MUTED && s::TEXT_MUTED != s::TEXT_DIM);
        assert_eq!(s::CONTROL_HEIGHT, 30.);
    }

    /// The disabled emphasis fill and the enabled one must differ, or a
    /// disabled send button would look pressable.
    #[test]
    fn emphasis_fill_distinguishes_enabled_from_disabled() {
        assert_ne!(s::FILL, s::FILL_DISABLED);
        assert!(s::FILL_DISABLED & 0xff < s::FILL & 0xff);
    }

    /// The icon palette is the **only** source of a glyph colour, and the three
    /// states resolve to three different **real styles**.
    ///
    /// This reads each built control's own resolved `style().text.color` rather
    /// than re-comparing the constants: changing `icon_color` back to the old
    /// `scene::ACCENT`/`scene::ICON_ACTIVE` white, or letting a control fall
    /// back to a kit variant default, turns this test red.
    #[test]
    fn every_icon_state_resolves_to_its_scene_token() {
        use gpui::Hsla;

        let palette = |value: u32| Some(Hsla::from(rgba(value)));
        let tone = |button: &mut Button| button.style().text.color;

        let mut resting = icon_button("resting", gpui_kit::assets::IconName::Play, "x", false, true);
        let mut active = icon_button("active", gpui_kit::assets::IconName::Play, "x", true, true);
        let mut disabled =
            icon_button("disabled", gpui_kit::assets::IconName::Play, "x", false, false);
        let resting = tone(&mut resting);
        let active = tone(&mut active);
        let disabled = tone(&mut disabled);

        assert_eq!(resting, palette(s::ICON), "a resting icon is `scene::ICON`");
        assert_eq!(
            active,
            palette(s::ICON_ACTIVE),
            "an asserted icon is `scene::ICON_ACTIVE` (the bright blue)"
        );
        assert_eq!(
            disabled,
            palette(s::ICON_DISABLED),
            "a disabled icon is `scene::ICON_DISABLED`"
        );
        // Three visibly different states, or the palette would not tell them
        // apart.
        assert_ne!(resting, active);
        assert_ne!(resting, disabled);
        assert_ne!(active, disabled);
        // The asserted tone is the bright blue, not the old white "interactive"
        // tone (`0xffffffb8`). `scene::ACCENT` is now an alias of the same
        // selected colour (`scene::SELECTED`), so it is checked through
        // `ICON_ACTIVE` above rather than compared here.
        assert_ne!(active, palette(0xffffffb8));
        assert_ne!(resting, palette(s::ICON_ACTIVE));

        // The other shared controls take the palette too.
        let mut bar = bar_button("bar", "x", gpui_kit::assets::IconName::Play, 30.);
        assert_eq!(bar.style().text.color, palette(s::ICON));
        let mut muted = volume_mute_button(true, true);
        assert_eq!(muted.style().text.color, palette(s::ICON_ACTIVE));
        // `active` wins over `!enabled`: a mute control that is both muted and
        // host-disabled still shows the asserted blue (see `icon_color`).
        let mut muted_disabled = volume_mute_button(true, false);
        assert_eq!(muted_disabled.style().text.color, palette(s::ICON_ACTIVE));
        let mut unmuted_disabled = volume_mute_button(false, false);
        assert_eq!(
            unmuted_disabled.style().text.color,
            palette(s::ICON_DISABLED)
        );
    }

    /// A style length as the pixels the element really resolves to, so an
    /// assertion reads the shape that was built rather than a copied constant.
    fn definite(length: Option<gpui_kit::Length>) -> gpui_kit::Pixels {
        match length {
            Some(gpui_kit::Length::Definite(value)) => {
                value.to_pixels(gpui_kit::AbsoluteLength::Pixels(px(0.)), px(16.))
            }
            other => panic!("expected a definite length, got {other:?}"),
        }
    }

    /// 音量 is a **vertical** slider: the box the track is laid out in resolves
    /// to a shape that is taller than it is wide, and the track's own axis is
    /// the vertical one. Turning it back into the rejected horizontal bar
    /// (`volume_track_axis` → `Axis::Horizontal`) flips both, and moving only
    /// kit's slider to its horizontal mode without the box is caught by the
    /// pixel harness in `tests/transport_popover_geometry.rs`.
    #[test]
    fn the_volume_track_is_vertical_and_bottom_up() {
        assert_eq!(
            volume_track_axis(),
            Axis::Vertical,
            "音量 is a vertical slider, not a horizontal bar"
        );
        let mut track = volume_track_box(volume_track_axis());
        let style = track.style();
        let width = definite(style.size.width);
        let height = definite(style.size.height);
        assert!(
            height > width,
            "a vertical 音量 track is taller than it is wide: {width:?} x {height:?}"
        );
        assert_eq!(height, px(VOLUME_TRACK_LENGTH));
        assert_eq!(width, px(VOLUME_TRACK_THICKNESS));
        // The other axis is a real, different shape, so the assertion above is
        // not true of any box this helper can build.
        let mut horizontal = volume_track_box(Axis::Horizontal);
        let horizontal = horizontal.style();
        assert!(definite(horizontal.size.width) > definite(horizontal.size.height));
    }

    /// 静音 is a **small icon button**, not a switch and not a bar: the two
    /// states are two different glyphs of the layer's square icon control
    /// (`icon_button`: 30 pt, icon face, words only in the tooltip).
    #[test]
    fn the_volume_mute_control_is_a_small_icon_not_a_switch() {
        let muted = volume_mute_icon(true);
        let unmuted = volume_mute_icon(false);
        assert_eq!(muted, gpui_kit::assets::IconName::VolumeX);
        assert_eq!(unmuted, gpui_kit::assets::IconName::Volume2);
        assert_ne!(muted, unmuted, "the two states must be distinguishable");
        let mut button = volume_mute_button(true, true);
        let style = button.style();
        assert_eq!(style.size.width, style.size.height, "square, not a bar");
        assert_eq!(definite(style.size.width), px(VOLUME_TRACK_THICKNESS));
        assert!(
            definite(style.size.height) < px(s::CONTROL_HEIGHT),
            "静音 is a small icon, not a bar-sized control"
        );
        // The very same control shape the layer's other icon controls have:
        // 静音 is a control of this layer, not a settings row's switch.
        let mut reference = icon_button("reference", unmuted, "音量", false, true);
        let reference = reference.style();
        assert_eq!(style.corner_radii, reference.corner_radii);
        // 静音 is the asserted state, so it takes the accent glyph colour; the
        // unmuted face keeps the resting one — the two states are visible.
        let mut resting = volume_mute_button(false, true);
        assert_eq!(resting.style().text.color, reference.text.color);
        assert_ne!(
            style.text.color,
            resting.style().text.color,
            "静音 and 取消静音 must not look the same"
        );
    }

    // -----------------------------------------------------------------------
    // 选中态 — the assertions read the style the element really resolves to
    // -----------------------------------------------------------------------

    /// The resolved channel bytes of a colour, so a test can pin what the
    /// renderer paints rather than compare a constant with itself.
    fn bytes(color: gpui_kit::gpui::Rgba) -> [u32; 4] {
        [
            (color.r * 255.).round() as u32,
            (color.g * 255.).round() as u32,
            (color.b * 255.).round() as u32,
            (color.a * 255.).round() as u32,
        ]
    }

    /// The solid background a resolved style carries.
    fn solid(style: &gpui_kit::gpui::StyleRefinement) -> gpui_kit::gpui::Hsla {
        style
            .background
            .as_ref()
            .and_then(|fill| fill.color())
            .and_then(|background| background.as_solid())
            .expect("a selected surface must carry a solid background")
    }

    /// Every **selected/active** surface in the layer reads
    /// `ui_tokens::scene::SELECTED` (or its wash), and the value it paints is the
    /// bright blue — not the kit theme's colour, and not the old six-digit
    /// accent that resolved to a dark navy.
    ///
    /// The assertions read `Styled::style()` on the elements the shipping code
    /// builds, so rebuilding one of them on a kit variant (whose selected face
    /// comes from `cx.theme()`) turns this red, and so does changing the token's
    /// value — the last two assertions pin the literal channels.
    #[test]
    fn the_selected_state_is_the_scene_token_not_a_theme_colour() {
        // The asserted control's glyph: `icon_button(active = true)`.
        let mut active = icon_button("active", gpui_kit::assets::IconName::Play, "播放", true, true);
        assert_eq!(active.style().text.color, Some(gpui_kit::gpui::Hsla::from(rgba(s::SELECTED))));
        let mut resting = icon_button("resting", gpui_kit::assets::IconName::Play, "播放", false, true);
        assert_eq!(resting.style().text.color, Some(gpui_kit::gpui::Hsla::from(rgba(s::ICON))));
        assert_ne!(active.style().text.color, resting.style().text.color);

        // Push-to-talk's asserted face reads the same token.
        let mut hold = hold_button(
            "hold",
            "test.hold",
            gpui_kit::assets::IconName::Mic,
            "语音",
            true,
            |_, _, _| {},
            |_, _, _| {},
        );
        assert_eq!(hold.style().text.color, Some(gpui_kit::gpui::Hsla::from(rgba(s::SELECTED))));

        // 使用中 — bright-blue glyph on the selected wash.
        let mut marker = selected_marker("marker", gpui_kit::assets::IconName::Check, "使用中");
        let marker_style = marker.style();
        assert_eq!(marker_style.text.color, Some(gpui_kit::gpui::Hsla::from(rgba(s::SELECTED))));
        assert_eq!(solid(marker_style), rgba(s::SELECTED_SOFT).into());

        // A selected tab face: bright-blue label on the wash; the resting face
        // keeps the muted label and no fill of its own.
        let mut selected_face = tab_face("tab", &TabFace::text("当前"), true);
        let selected_style = selected_face.style();
        assert_eq!(selected_style.text.color, Some(gpui_kit::gpui::Hsla::from(rgba(s::SELECTED))));
        assert_eq!(solid(selected_style), rgba(s::SELECTED_SOFT).into());
        let mut resting_face = tab_face("tab", &TabFace::text("其他"), false);
        let resting_style = resting_face.style();
        assert_eq!(resting_style.text.color, Some(gpui_kit::gpui::Hsla::from(rgba(s::TEXT_MUTED))));
        assert!(
            resting_style.background.is_none(),
            "a resting tab face must not paint a fill of its own"
        );

        // The pinned value, independent of any token: the selected state is the
        // opaque bright blue #3B9EFF over the 18% wash. Put the old colour back
        // (`0x7af2ff`, cyan) and this goes red.
        assert_eq!(bytes(rgba(s::SELECTED)), [0x3b, 0x9e, 0xff, 0xff]);
        assert_eq!(bytes(rgba(s::SELECTED_SOFT)), [0x3b, 0x9e, 0xff, 0x2e]);
    }
}
