//! The fixed floating bar that sits over the rendered space: the transport
//! controls (bottom-right) and the destination button (top-right).
//!
//! It lives in the UI crate rather than in the product host because it is not
//! host policy — it is the layer's chrome, and keeping it here is what lets the
//! shot harness, the tests and the host all mount **one** bar. The host supplies
//! the ordered controls and the current state; this module owns the geometry and
//! the presentation.
//!
//! Original sources: `StageOverlayView.swift:2683-2694`
//! (`StageControlPanelLayout`: 44 pt control slots, a 68 pt settings slot, 4 pt
//! side insets, 6 pt group gaps, 590×458 maximum panel) and
//! `StageWindowController.swift:1541-1542` (529×48), `:1533-1538` (22 from the
//! right and bottom), `:1577-1590` (destination 112×38 at right 22 / top 28).
use gpui::{AnyElement, IntoElement, SharedString, px, rgba};
use gpui_kit::component::button::*;
use gpui_kit::component::*;
use gpui_kit::prelude::InteractiveElement as _;
use gpui_kit::*;

use crate::primitives as ui;
use crate::ui_tokens::scene as s;
use crate::ui_tokens::shell as m;
use crate::ui_tokens::stage;

/// One control in the transport bar.
///
/// `label` is the tooltip and the accessibility label — never the control's
/// face: every control in this layer is icon-only, and the only text face is
/// [`TransportControl::face_text`] on the original's wide settings slot.
#[derive(Clone, Debug, PartialEq)]
pub struct TransportControl {
    pub id: SharedString,
    /// Host action name, echoed back through the bar's callback.
    pub action: SharedString,
    pub icon: gpui_kit::assets::IconName,
    pub label: SharedString,
    pub active: bool,
    pub enabled: bool,
    /// Paint the group divider **after** this control (the original separates
    /// the playback group from the space tools).
    pub ends_group: bool,
    /// Push-to-talk (the original 语音 entry): the bar reports press/release
    /// through `on_hold` instead of routing a click.
    pub hold: bool,
    /// The wide 68 pt settings slot's label (舞台设置 / 收起). Every other
    /// control keeps its words out of band.
    pub face_text: Option<SharedString>,
    /// Unread count drawn on the control's trailing shoulder (通知).
    pub badge: Option<SharedString>,
    /// Surface painted while `active`. The host resolves the live system tint
    /// where the original used `NSColor.systemBlue` and passes it here; `None`
    /// keeps the resting surface (the asserted glyph is accent either way).
    pub active_fill: Option<u32>,
}

impl TransportControl {
    pub fn new(
        id: impl Into<SharedString>,
        action: impl Into<SharedString>,
        icon: gpui_kit::assets::IconName,
        label: impl Into<SharedString>,
    ) -> Self {
        Self {
            id: id.into(),
            action: action.into(),
            icon,
            label: label.into(),
            active: false,
            enabled: true,
            ends_group: false,
            hold: false,
            face_text: None,
            badge: None,
            active_fill: None,
        }
    }
    pub fn active(mut self, active: bool) -> Self {
        self.active = active;
        self
    }
    pub fn enabled(mut self, enabled: bool) -> Self {
        self.enabled = enabled;
        self
    }
    pub fn ends_group(mut self, ends_group: bool) -> Self {
        self.ends_group = ends_group;
        self
    }
    pub fn hold(mut self, hold: bool) -> Self {
        self.hold = hold;
        self
    }
    pub fn face_text(mut self, text: impl Into<SharedString>) -> Self {
        self.face_text = Some(text.into());
        self
    }
    pub fn badge(mut self, badge: impl Into<SharedString>) -> Self {
        self.badge = Some(badge.into());
        self
    }
    pub fn active_fill(mut self, fill: u32) -> Self {
        self.active_fill = Some(fill);
        self
    }
    /// The original's wide slot is the settings control (68 pt); everything else
    /// is a 44 pt slot.
    pub fn slot_width(&self) -> f32 {
        if self.id.as_ref() == "visual" {
            stage::SETTINGS_WIDTH
        } else {
            stage::CONTROL_SIZE
        }
    }
}

/// Total bar width for a control list — the original derives it rather than
/// hard-coding 529, so a change in the control set changes the bar with it.
pub fn transport_width(controls: &[TransportControl]) -> f32 {
    controls.iter().map(TransportControl::slot_width).sum::<f32>()
        + 2. * stage::SIDE_INSET
        + 2. * stage::GROUP_GAP
        + m::TRANSPORT_ROUNDING
}

/// The transport bar. `on_action` receives the control's action name for a
/// click; `on_hold` receives `(action, pressed)` for the controls marked
/// [`TransportControl::hold`], so push-to-talk stays in the host without a
/// second copy of the row.
///
/// Every icon here is one gpui-kit embeds (see `BUNDLED_ICONS` in the tests):
/// `ListMusic`, `SkipBack`, `MessageCircle`, `Mail`, `Package` and `Monitor` all
/// exist as names but are not embedded, so they paint an empty square — the
/// original v12 defect. The host's own control table must use the same set.
pub fn transport_bar(
    controls: Vec<TransportControl>,
    on_action: impl Fn(&str, &mut Window, &mut App) + 'static,
    on_hold: impl Fn(&str, bool, &mut Window, &mut App) + 'static,
) -> AnyElement {
    let on_action = std::rc::Rc::new(on_action);
    let on_hold = std::rc::Rc::new(on_hold);
    let mut bar = div()
        .id("stage.transport")
        .absolute()
        .right(px(m::TRANSPORT_INSET))
        .bottom(px(m::TRANSPORT_INSET))
        .h(px(m::TRANSPORT_HEIGHT))
        .px(px(stage::SIDE_INSET))
        .flex()
        .items_center()
        .gap(px(stage::GROUP_GAP))
        .rounded(px(s::PANEL_RADIUS_SMALL))
        .bg(rgba(m::TRANSPORT_BG))
        .border_1()
        .border_color(rgba(m::TRANSPORT_BORDER));
    for control in controls {
        let width = control.slot_width();
        let action = control.action.clone();
        let mut button = ui::icon_button(
            control.id.clone(),
            control.icon,
            control.label.clone(),
            control.active,
        )
        .w(px(width))
        .h(px(stage::CONTROL_SIZE))
        .flex_shrink_0()
        .rounded(px(m::CONTROL_RADIUS))
        .disabled(!control.enabled);
        if let Some(fill) = control.active_fill {
            button = button.bg(rgba(fill));
        }
        if let Some(text) = &control.face_text {
            button = button.px(px(m::CONTROL_LABEL_INSET)).child(
                div()
                    .text_size(px(m::CONTROL_LABEL_SIZE))
                    .whitespace_nowrap()
                    .child(text.clone()),
            );
        }
        let element: AnyElement = if control.hold {
            let down = on_hold.clone();
            let up = on_hold.clone();
            let out = on_hold.clone();
            let down_action = action.clone();
            let up_action = action.clone();
            button
                .on_mouse_down(MouseButton::Left, move |_, window, cx| {
                    down(down_action.as_ref(), true, window, cx)
                })
                .on_mouse_up(MouseButton::Left, move |_, window, cx| {
                    up(up_action.as_ref(), false, window, cx)
                })
                .on_mouse_up_out(MouseButton::Left, move |_, window, cx| {
                    out(action.as_ref(), false, window, cx)
                })
                .into_any_element()
        } else {
            let click = on_action.clone();
            button
                .on_click(move |_, window, cx| click(action.as_ref(), window, cx))
                .into_any_element()
        };
        let mut slot = div()
            .relative()
            .w(px(width))
            .h(px(stage::CONTROL_SIZE))
            .child(element);
        if let Some(badge) = &control.badge {
            slot = slot.child(
                div()
                    .absolute()
                    .top(px(m::BADGE_TOP))
                    .left(px(width / 2. + m::BADGE_OFFSET))
                    .min_w(px(m::BADGE_SIZE))
                    .h(px(m::BADGE_SIZE))
                    .rounded(px(m::BADGE_RADIUS))
                    .bg(rgba(m::BADGE_BG))
                    .text_color(rgba(m::BADGE_TEXT))
                    .text_size(px(m::BADGE_FONT))
                    .flex()
                    .items_center()
                    .justify_center()
                    .child(badge.clone()),
            );
        }
        bar = bar.child(slot);
        if control.ends_group {
            bar = bar.child(
                div()
                    .w(px(m::TRANSPORT_DIVIDER.0))
                    .h(px(m::TRANSPORT_DIVIDER.1))
                    .flex_shrink_0()
                    .bg(rgba(m::TRANSPORT_BORDER)),
            );
        }
    }
    bar.into_any_element()
}

/// The top-right destination control: one host-supplied icon in a round 38 pt
/// button, with the words in the tooltip and the accessibility label.
///
/// `icon` is an element, not an [`gpui_kit::assets::IconName`], because the
/// original draws an SF Symbol (`circle.hexagongrid.fill` /
/// `cube.transparent`) and the product host renders exactly that through
/// `system_symbol::image`. Kit's Lucide set has no equivalent glyph, and a
/// substituted one would be a different picture; the bar keeps the geometry.
///
/// The original draws a 112×38 pill because it carries text next to the symbol.
/// Controls in this layer are icon-only, and a 112 pt pill around a single glyph
/// reads as an empty black capsule with a glowing ring, so the control collapses
/// to the round button the rest of the layer uses — same height, same surface,
/// hairline instead of the accent ring, accent kept for the glyph itself.
pub fn destination_button(
    icon: impl IntoElement,
    label: impl Into<SharedString>,
    enabled: bool,
    on_click: impl Fn(&ClickEvent, &mut Window, &mut App) + 'static,
) -> AnyElement {
    let label = label.into();
    Button::new("destination")
        .ghost()
        .absolute()
        .right(px(m::TRANSPORT_INSET))
        .top(px(m::DESTINATION_TOP))
        .w(px(m::DESTINATION_HEIGHT))
        .h(px(m::DESTINATION_HEIGHT))
        .rounded(px(m::DESTINATION_HEIGHT / 2.))
        .bg(rgba(s::BAR_BG))
        .border_1()
        .border_color(rgba(s::BORDER))
        .text_color(rgba(s::ACCENT))
        .child(div().flex().items_center().justify_center().child(icon))
        .tooltip(label.clone())
        .accessibility_label(label)
        .disabled(!enabled)
        .on_click(on_click)
        .into_any_element()
}

#[cfg(test)]
mod tests {
    use core::prelude::v1::test;
    use super::*;

    fn control(id: &'static str, icon: gpui_kit::assets::IconName) -> TransportControl {
        TransportControl::new(id, id, icon, id)
    }

    /// The bar derives its width from the controls, exactly like the original:
    /// ten 44 pt slots (the nine regular buttons plus the window-mode button the
    /// stage view accounts for separately), the 68 pt settings slot, two 4 pt
    /// side insets, two 6 pt group gaps and the original's own rounding term.
    #[test]
    fn transport_width_is_derived_from_the_control_set() {
        let mut controls: Vec<_> = (0..10)
            .map(|_| control("regular", gpui_kit::assets::IconName::Music))
            .collect();
        controls.push(control("visual", gpui_kit::assets::IconName::Settings));
        assert_eq!(controls.len(), m::REGULAR_BUTTONS + 2, "eleven controls, as in the original bar");
        assert_eq!(transport_width(&controls), m::TRANSPORT_WIDTH);
        assert_eq!(transport_width(&controls), 529.);
        // Removing a control moves the bar, rather than leaving a 529 pt bar
        // with a hole in it.
        assert!(transport_width(&controls[..controls.len() - 1]) < m::TRANSPORT_WIDTH);
    }

    /// The destination control is a square icon button: the original's 112 pt
    /// width belongs to a text pill, and keeping it with an icon-only face is
    /// what produced the empty black capsule with a cyan ring.
    #[test]
    fn destination_is_a_square_icon_control_not_a_text_pill() {
        assert_eq!(m::DESTINATION_HEIGHT, 38.);
        assert_eq!(m::DESTINATION_TOP, 28.);
        let source = include_str!("shell.rs");
        let body = &source[source.find("pub fn destination_button").unwrap()..];
        let body = &body[..body.find("\n}").unwrap_or(body.len())];
        // `.label(` is kit's face-text API; tooltips and accessibility labels
        // are how this control carries its words.
        assert!(!body.contains(".label("), "the destination control must not draw text");
        assert!(!body.contains("DESTINATION_WIDTH"), "width must collapse to the round button");
        assert!(body.contains("BORDER)"), "hairline, not the accent ring");
        assert!(!body.contains("BORDER_ACTIVE"), "the glowing accent ring is what looked wrong");
    }

    #[test]
    fn the_wide_slot_is_the_settings_control_only() {
        let settings = control("visual", gpui_kit::assets::IconName::Settings);
        assert_eq!(settings.slot_width(), stage::SETTINGS_WIDTH);
        let playback = control("play", gpui_kit::assets::IconName::Play);
        assert_eq!(playback.slot_width(), stage::CONTROL_SIZE);
    }

    /// The icons gpui-kit actually embeds. `IconName` carries every lucide name,
    /// but only the bundled ones paint — an unbundled name compiles and renders
    /// blank, which is exactly the original v12 "bottom bar icons empty" defect.
    ///
    /// Copied from gpui-kit's `crates/assets/default-icons.txt` at the pinned
    /// revision (`c1bda59`): 106 slugs. The registry is consulted first, so this
    /// list is only the fallback when the asset source cannot enumerate; keeping
    /// it complete is what stops a valid icon from being reported as unbundled.
    const BUNDLED_ICONS: &[&str] = &[
        "a-large-small", "arrow-down", "arrow-left", "arrow-right", "arrow-up", "asterisk",
        "ban", "battery-charging", "battery-full", "battery-low", "battery-medium", "battery-warning",
        "battery", "bell", "book-open", "bot", "building-2", "calendar",
        "case-sensitive", "chart-pie", "check", "chevron-down", "chevron-left", "chevron-right",
        "chevron-up", "chevrons-up-down", "circle-alert", "circle-check", "circle-user", "circle-x",
        "close", "copy", "cpu", "dash", "delete", "ellipsis-vertical",
        "ellipsis", "external-link", "eye-off", "eye", "file-text", "file",
        "folder-closed", "folder-open", "folder", "frame", "gallery-vertical-end", "github",
        "globe", "hard-drive", "heart-off", "heart", "inbox", "info",
        "inspector", "layout-dashboard", "loader-circle", "loader", "map", "maximize",
        "memory-stick", "menu", "mic", "minimize", "minus", "moon",
        "network", "palette", "panel-bottom-open", "panel-bottom", "panel-left-close", "panel-left-open",
        "panel-left", "panel-right-close", "panel-right-open", "panel-right", "pause", "play",
        "plus", "redo-2", "redo", "refresh-cw", "replace", "resize-corner",
        "rotate-cw", "search", "settings-2", "settings", "sort-ascending", "sort-descending",
        "square-terminal", "square", "star-fill", "star-off", "star", "sun",
        "thumbs-down", "thumbs-up", "triangle-alert", "undo-2", "undo", "user",
        "window-close", "window-maximize", "window-minimize", "window-restore",
    ];

    /// The slug gpui-kit embeds for this icon, and a hard failure when it is not
    /// in the embedded set. The registry is consulted first; `BUNDLED_ICONS` is
    /// the fallback when the source cannot enumerate (it is copied from
    /// gpui-kit's `crates/assets/default-icons.txt` and must be kept in sync).
    fn embedded_icon(icon: gpui_kit::assets::IconName) -> String {
        use gpui_kit::AssetSource as _;
        let debug = format!("{icon:?}");
        let mut slug = String::new();
        for ch in debug.chars() {
            if ch.is_ascii_uppercase() {
                if !slug.is_empty() && !slug.ends_with('-') {
                    slug.push('-');
                }
                slug.extend(ch.to_lowercase());
            } else {
                slug.push(ch);
            }
        }
        let path = format!("icons/{slug}.svg");
        let source = gpui_kit::assets::Assets;
        let embedded = match source.list("icons/") {
            Ok(paths) if !paths.is_empty() => paths.iter().any(|entry| entry.as_ref() == path),
            _ => BUNDLED_ICONS.contains(&slug.as_str()),
        };
        assert!(
            embedded,
            "{path} is not embedded; the control would paint an empty square"
        );
        path
    }

    /// Every control in the bar is icon-only and carries its words as a tooltip
    /// and an accessibility label, so the icon-only rule cannot silently turn
    /// the bar into a row of unexplained glyphs.
    #[test]
    fn every_transport_control_carries_its_words_out_of_band() {
        let controls = [
            control("program", gpui_kit::assets::IconName::FileText),
            control("previous", gpui_kit::assets::IconName::ChevronLeft),
            control("play", gpui_kit::assets::IconName::Play),
            control("next", gpui_kit::assets::IconName::ChevronRight),
            control("voice", gpui_kit::assets::IconName::Mic),
            control("chat", gpui_kit::assets::IconName::Bot),
            control("inbox", gpui_kit::assets::IconName::Bell),
            control("props", gpui_kit::assets::IconName::Frame),
            control("screen", gpui_kit::assets::IconName::PanelRight),
            control("visual", gpui_kit::assets::IconName::Settings),
            control("mode", gpui_kit::assets::IconName::Maximize),
        ];
        assert_eq!(controls.len(), m::REGULAR_BUTTONS + 2, "the original bar has eleven controls");
        for item in controls {
            assert!(!item.label.is_empty(), "{} must carry a label", item.id);
            assert!(!item.action.is_empty(), "{} must carry an action", item.id);
            embedded_icon(item.icon);
        }
        embedded_icon(gpui_kit::assets::IconName::Globe);
        embedded_icon(gpui_kit::assets::IconName::Play);
        assert!(BUNDLED_ICONS.contains(&"globe") && BUNDLED_ICONS.contains(&"mic"));
    }
}
