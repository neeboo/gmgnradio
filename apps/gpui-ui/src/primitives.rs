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
use gpui::{Div, ElementId, MouseButton, MouseDownEvent, MouseUpEvent, SharedString, Stateful, px, rgba};
use gpui_kit::component::button::*;
use gpui_kit::component::slider::{Slider, SliderState};
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::*;
use gpui_kit::prelude::{InteractiveElement as _, StatefulInteractiveElement as _};
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

/// A square icon control sized to the layer's control height.
///
/// `active` is the asserted state (toggled on / currently running); it paints
/// the accent colour and does not change what a click does.
pub fn icon_button(
    id: impl Into<ElementId>,
    icon: gpui_kit::assets::IconName,
    label: impl Into<SharedString>,
    active: bool,
) -> Button {
    let label = label.into();
    Button::new(id)
        .ghost()
        .small()
        .icon(icon)
        .w(px(s::CONTROL_HEIGHT))
        .h(px(s::CONTROL_HEIGHT))
        .rounded(px(s::CONTROL_RADIUS))
        .text_color(if active {
            rgba(s::ACCENT)
        } else {
            rgba(s::ICON_ACTIVE)
        })
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
        .text_color(rgba(s::ICON_ACTIVE))
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
        .text_color(if active {
            rgba(s::ACCENT)
        } else {
            rgba(s::ICON_ACTIVE)
        })
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
    let slider = match axis {
        Axis::Vertical => Slider::new(state).vertical(),
        Axis::Horizontal => Slider::new(state).horizontal(),
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
    )
    .w(px(VOLUME_TRACK_THICKNESS))
    .h(px(VOLUME_TRACK_THICKNESS))
    .disabled(!enabled)
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
        let mut reference = icon_button("reference", unmuted, "音量", false);
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
}
