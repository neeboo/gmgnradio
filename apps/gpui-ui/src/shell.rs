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

/// The gap between the bar's top edge and a popover that opens above it.
///
/// The popover is anchored to the bar's own box (the bar is the relative
/// ancestor of every slot), so "up" is `TRANSPORT_HEIGHT + this` from the bar's
/// **bottom** edge: the panel sits one hairline gap above the bar's top and
/// never overlaps the panel area above it.
pub const TRANSPORT_POPOVER_GAP: f32 = 8.;
/// Width of a transport popover: the widest control it carries (the 音量 track's
/// own box, [`crate::primitives::VOLUME_TRACK_THICKNESS`]) plus the panel's
/// padding on both sides, so the card is a **column** around a vertical track
/// rather than a horizontal bar segment.
pub const TRANSPORT_POPOVER_WIDTH: f32 =
    crate::primitives::VOLUME_TRACK_THICKNESS + 2. * TRANSPORT_POPOVER_PADDING;
/// Inner padding of a transport popover.
pub const TRANSPORT_POPOVER_PADDING: f32 = 9.;

/// The dark surface every transport popover is drawn on.
///
/// Deliberately a plain `Div` with explicit overlay-palette values instead of
/// kit's themed surface variants: `Button::primary()`/`.custom(..)` derive their
/// fill from `cx.theme()`, which is what turns a control white under a light
/// system theme (the inbox's white button is that bug). An overlay surface that
/// floats over the rendered space must keep the fixed dark palette (see
/// `ui_tokens::scene`).
///
/// The panel is a **column**: its content stacks (音量's vertical track above
/// its mute icon), which is the shape the person asked for. A row layout here
/// is what made the panel read as a horizontal bar.
pub fn transport_popover(content: impl IntoElement) -> Div {
    div()
        .absolute()
        .bottom(px(m::TRANSPORT_HEIGHT + TRANSPORT_POPOVER_GAP))
        .right(px(0.))
        .flex()
        .flex_col()
        .items_center()
        .gap(px(s::PANEL_GAP / 2.))
        .w(px(TRANSPORT_POPOVER_WIDTH))
        .p(px(TRANSPORT_POPOVER_PADDING))
        .rounded(px(s::PANEL_RADIUS_SMALL))
        .bg(rgba(s::CARD_BG))
        .border_1()
        .border_color(rgba(s::BORDER))
        .child(content)
}

/// Opens a panel above one transport control.
///
/// A shared builder closure rather than a built [`AnyElement`] because a
/// [`TransportControl`] is `Clone + Debug + PartialEq` (the host clones and
/// compares control tables in its own tests) and `AnyElement` is none of those.
/// The closure keeps the panel out of the control's identity while still owning
/// the panel's content and its window-derived geometry: a clone shares the same
/// builder, so `Clone` stays cheap and `Debug`/`PartialEq` stay total.
#[derive(Clone)]
pub struct TransportPopover(
    std::rc::Rc<dyn Fn(&mut Window, &mut App) -> AnyElement + 'static>,
);

impl TransportPopover {
    pub fn new(build: impl Fn(&mut Window, &mut App) -> AnyElement + 'static) -> Self {
        Self(std::rc::Rc::new(build))
    }
    /// Build the panel for this frame. Takes `&self` so the bar can render a
    /// control it has already moved out of the list.
    pub fn element(&self, window: &mut Window, cx: &mut App) -> AnyElement {
        (self.0)(window, cx)
    }
}

impl PartialEq for TransportPopover {
    /// Two popovers are the same only when they share a builder; the panel's
    /// pixels are not part of a control's identity.
    fn eq(&self, other: &Self) -> bool {
        std::rc::Rc::ptr_eq(&self.0, &other.0)
    }
}

impl std::fmt::Debug for TransportPopover {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("TransportPopover")
    }
}

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
    /// Surface painted while `active`, as an explicit override.
    ///
    /// `None` — the normal case — lets the bar paint its **own** selected wash
    /// ([`crate::ui_tokens::scene::SELECTED_SOFT`]) for an asserted control
    /// whose glyph is [`crate::ui_tokens::scene::SELECTED`]. The host must not
    /// substitute a system tint here: the original's `NSColor.systemBlue` is the
    /// "default blue" the overlay palette replaced, and a system colour follows
    /// the OS appearance, which is exactly what an overlay over the rendered
    /// space must not do.
    pub active_fill: Option<u32>,
    /// A panel that opens **above the bar**, anchored to this control's slot.
    ///
    /// The host fills it only while the control is open (click the icon → the
    /// panel appears above the bar, click again → `None` and nothing is drawn),
    /// so the bar owns the geometry and the host owns the open/closed state.
    /// The element is drawn through [`transport_popover`], which keeps the
    /// overlay palette regardless of the system theme.
    pub popover: Option<TransportPopover>,
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
            popover: None,
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
    /// Open a panel above this control's slot. `build` is called once per frame
    /// the panel is open, so the content (for 音量: one
    /// [`gpui_kit::component::slider::Slider`]) can read live entity state; the
    /// slot keeps its own geometry because the panel is absolutely positioned.
    pub fn popover(
        mut self,
        build: impl Fn(&mut Window, &mut App) -> AnyElement + 'static,
    ) -> Self {
        self.popover = Some(TransportPopover::new(build));
        self
    }
    /// Whether this control currently has a panel open above it. Used by the
    /// bar's tests; the host decides it from its own open/closed state.
    pub fn popover_open(&self) -> bool {
        self.popover.is_some()
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

/// Every flex child the bar really places, in order, as `(width, is_divider)`.
///
/// This is the **one list** both the layout and the width derivation read: the
/// bar's children are each control's slot plus the group divider a control with
/// [`TransportControl::ends_group`] paints after it, and the flex gap lies
/// between *every* neighbouring pair of them. A derivation that counts only
/// "group gaps" therefore disagrees with the bar the moment a control set has
/// more than one group boundary — which is exactly what a 735 pt bar derived as
/// 661 did, pushing the leftmost entry 37 pt off a 720 pt canvas.
fn transport_children(controls: &[TransportControl]) -> Vec<(f32, bool)> {
    let mut children = Vec::with_capacity(controls.len() + 1);
    for control in controls {
        children.push((control.slot_width(), false));
        if control.ends_group {
            children.push((m::TRANSPORT_DIVIDER.0, true));
        }
    }
    children
}

/// Total bar width for a control list — the original derives it rather than
/// hard-coding 529, so a change in the control set changes the bar with it.
///
/// Same source as the render: [`transport_children`] is the child sequence the
/// bar builds, so the derivation is its summed widths plus the flex gaps
/// *between those children* (`n - 1` of them), the bar's two side insets and the
/// original's rounding term. [`transport_bar_slots`] must keep `.gap(px(
/// stage::GROUP_GAP))` on the bar box for this to stay true.
pub fn transport_width(controls: &[TransportControl]) -> f32 {
    let children = transport_children(controls);
    children.iter().map(|(width, _)| *width).sum::<f32>()
        + 2. * stage::SIDE_INSET
        + (children.len().saturating_sub(1)) as f32 * stage::GROUP_GAP
        + m::TRANSPORT_ROUNDING
}

/// The transport bar, without a window: the original signature every existing
/// host mounts. It is [`transport_bar_in`] with no popover to build, so a host
/// that has no panel above the bar keeps the exact call it had.
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
    // No popover is buildable without a window, so this path never paints one;
    // the loop below still owns the geometry for hosts that do have one.
    let on_action: std::rc::Rc<dyn Fn(&str, &mut Window, &mut App)> = std::rc::Rc::new(on_action);
    let on_hold: std::rc::Rc<dyn Fn(&str, bool, &mut Window, &mut App)> = std::rc::Rc::new(on_hold);
    transport_bar_slots(controls, None, &on_action, &on_hold)
}

/// The transport bar with the window it is being rendered into, so a control
/// marked [`TransportControl::popover`] can build and paint its panel above the
/// bar on this frame. `on_action`/`on_hold` have the same meaning as in
/// [`transport_bar`].
pub fn transport_bar_in(
    controls: Vec<TransportControl>,
    window: &mut Window,
    cx: &mut App,
    on_action: impl Fn(&str, &mut Window, &mut App) + 'static,
    on_hold: impl Fn(&str, bool, &mut Window, &mut App) + 'static,
) -> AnyElement {
    let on_action: std::rc::Rc<dyn Fn(&str, &mut Window, &mut App)> = std::rc::Rc::new(on_action);
    let on_hold: std::rc::Rc<dyn Fn(&str, bool, &mut Window, &mut App)> = std::rc::Rc::new(on_hold);
    transport_bar_slots(controls, Some((window, cx)), &on_action, &on_hold)
}

/// The bar itself, shared by both entry points.
///
/// `live` is the window a popover is built in — `None` for a host that supplies
/// no popover (nothing is built, so no window is needed), `Some` for
/// [`transport_bar_in`]. Keeping one loop is what stops the two entry points
/// from drifting apart.
///
/// The bar is `absolute` and nothing else: it is pinned to the canvas'
/// bottom-right corner, which is what leaves the whole canvas above it
/// drawable. `.relative()` here would *replace* that (GPUI's position setters
/// share one field, so the last one wins), turning `right`/`bottom` into
/// relative offsets and laying the bar out in flow at the canvas' top-left —
/// where a popover that opens above it lands at negative `y` and is clipped
/// away. The popover does not need the bar to be its containing block: it hangs
/// off the control's own `relative` slot (see `transport_bar_slots`).
fn transport_bar_slots(
    controls: Vec<TransportControl>,
    live: Option<(&mut Window, &mut App)>,
    on_action: &std::rc::Rc<dyn Fn(&str, &mut Window, &mut App)>,
    on_hold: &std::rc::Rc<dyn Fn(&str, bool, &mut Window, &mut App)>,
) -> AnyElement {
    let mut live = live;
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
    // The child sequence the width derivation reads as well: one entry per
    // control's slot, plus a `(divider, true)` entry after a group's last
    // control. The `width` below and `transport_width` therefore cannot drift.
    let children = transport_children(&controls);
    // A control's own slot is at its index plus one entry for every divider a
    // *preceding* control ended its group with; the bar's child order is the
    // same sequence `transport_children` builds, so the two cannot drift.
    let mut slot_index = 0;
    for control in controls {
        let (width, is_divider) = children[slot_index];
        debug_assert!(!is_divider, "a control is always followed by its own slot");
        slot_index += 1 + usize::from(control.ends_group);
        let action = control.action.clone();
        let mut button = ui::icon_button(
            control.id.clone(),
            control.icon,
            control.label.clone(),
            control.active,
            control.enabled,
        )
        .w(px(width))
        .h(px(stage::CONTROL_SIZE))
        .flex_shrink_0()
        .rounded(px(m::CONTROL_RADIUS));
        // An asserted control paints the layer's selected wash behind its own
        // bright-blue glyph. The default is the **token**, not a host-supplied
        // colour: the host used to pass `NSColor.systemBlue`, which is the
        // "default blue" this layer must not show. `active_fill` stays as an
        // explicit override for a host that needs one, but the bar itself is
        // correct with none.
        let active_fill = control.active_fill.or(control.active.then_some(s::SELECTED_SOFT));
        if let Some(fill) = active_fill {
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
        // The control's own 44 pt face. Kept as its own box so the badge's
        // offsets stay measured from the face, not from the taller slot below.
        let mut face = div()
            .relative()
            .w(px(width))
            .h(px(stage::CONTROL_SIZE))
            .child(element);
        if let Some(badge) = &control.badge {
            face = face.child(
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
        // One slot's containing block is the **bar's own box**, not the 44 pt
        // face: the slot is `TRANSPORT_HEIGHT` tall (the row centers the face
        // inside it, so the control does not move) and therefore its bottom edge
        // is the bar's bottom edge. The popover below hangs off *this* box, so
        // its `bottom` anchor — [`m::TRANSPORT_HEIGHT`] + [`TRANSPORT_POPOVER_GAP`]
        // — really is measured from the bar's bottom edge, exactly as
        // [`transport_popover`] documents. A slot that stops at the face would
        // sit 2 pt inside the bar (the row centers a 44 pt face in a 48 pt bar)
        // and push the panel 2 pt further up than the gap says.
        let mut slot = div()
            .relative()
            .w(px(width))
            .h(px(m::TRANSPORT_HEIGHT))
            .flex()
            .items_center()
            .child(face);
        // A control with an open panel paints it from its own slot, so the
        // panel tracks the control it belongs to; its anchor is the bar's box
        // (an `absolute` child of the slot), which is what puts it above the
        // bar instead of inside it. A host that mounted the bar without a
        // window cannot build a panel, so it is skipped rather than faked.
        if let Some(popover) = &control.popover {
            if let Some((window, cx)) = live.as_mut() {
                slot = slot.child(transport_popover(popover.element(window, cx)));
            }
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
        .text_color(ui::icon_color(true, enabled))
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

    /// The bar derives its width from the controls, exactly like the original —
    /// but for the **product's** control set, divider included: ten 44 pt slots
    /// (the nine regular buttons plus the window-mode button the stage view
    /// accounts for separately), the 68 pt settings slot, the 1 pt group divider
    /// 下首 ends its group with, two 4 pt side insets, one 6 pt flex gap between
    /// each of the bar's twelve real children, and the original's rounding term.
    ///
    /// The gap count is the bar's, not a guess: the bar is a flex row that gaps
    /// *every* neighbouring pair of children, so the derivation counts the
    /// `n - 1` gaps of the child sequence [`transport_children`] returns. The old
    /// "two group gaps" reading was 55 pt short of the bar it described (529
    /// derived / 584 painted), which is the defect this pins — a host that placed
    /// the bar by the derivation put its left edge 55 pt too far right.
    ///
    /// That the *painted* bar really is 584 pt is not asserted here — a unit test
    /// cannot measure paint. `tests/transport_popover_geometry.rs` reads the
    /// rendered bar's own prepared-layout rect back and pins
    /// `transport_width(controls) == rendered width` in real pixels.
    #[test]
    fn transport_width_is_derived_from_the_control_set() {
        // 下首 carries the bar's only group divider, so the product set is
        // eleven slots **and** one hairline.
        let mut controls: Vec<_> = (0..10)
            .map(|_| control("regular", gpui_kit::assets::IconName::Music))
            .collect();
        controls[3] = controls[3].clone().ends_group(true);
        controls.push(control("visual", gpui_kit::assets::IconName::Settings));
        assert_eq!(controls.len(), m::REGULAR_BUTTONS + 2, "eleven controls, as in the original bar");
        assert_eq!(transport_children(&controls).len(), controls.len() + 1);
        assert_eq!(transport_width(&controls), m::TRANSPORT_WIDTH);
        assert_eq!(transport_width(&controls), 584.);
        // Removing a control moves the bar, rather than leaving a 584 pt bar
        // with a hole in it.
        assert!(transport_width(&controls[..controls.len() - 1]) < m::TRANSPORT_WIDTH);
    }

    /// A group divider is a real flex child, so it adds its own width **and** a
    /// gap on each side. The derivation that forgot this is what the painted
    /// width disagreed with.
    #[test]
    fn a_group_divider_costs_its_width_and_a_gap_on_each_side() {
        let plain = vec![
            control("a", gpui_kit::assets::IconName::Music),
            control("b", gpui_kit::assets::IconName::Music),
            control("c", gpui_kit::assets::IconName::Music),
        ];
        let mut grouped = plain.clone();
        grouped[0] = grouped[0].clone().ends_group(true);
        // One extra child: its 1 pt hairline plus one more flex gap.
        assert_eq!(
            transport_width(&grouped) - transport_width(&plain),
            m::TRANSPORT_DIVIDER.0 + stage::GROUP_GAP,
            "a divider is a child of the gap'ed flex row"
        );
    }

    /// An open panel hangs off the **bar's own box**, not the 44 pt control
    /// face.
    ///
    /// [`transport_popover`]'s `bottom` is `TRANSPORT_HEIGHT + TRANSPORT_POPOVER_GAP`
    /// measured from its containing block, and the panel is documented to land
    /// exactly one gap above the bar's top edge. That only holds while the
    /// popover's parent spans the bar's full height: the bar centers a 44 pt
    /// face inside its 48 pt box, so a slot that stops at the face sits 2 pt
    /// inside the bar and lifts the panel with it (the 音量 panel used to open
    /// with a 10 pt gap instead of the 8 pt one). The face keeps its own 44 pt
    /// box, so the badge's offsets are measured from the face they belong to.
    ///
    /// The assertions slice the real builder, so restoring the old 44 pt slot
    /// turns this red instead of passing on a constant.
    #[test]
    fn an_open_panel_hangs_off_the_bar_height_slot_not_the_control_face() {
        let source = include_str!("shell.rs");
        let builder = &source[source.find("fn transport_bar_slots").unwrap()..];
        let builder = &builder[..builder.find("bar.into_any_element()").unwrap()];
        let bodies = &builder[builder.find("let mut face = div()").expect(
            "the control's face must stay its own box, or the badge offsets move",
        )..];
        let split = bodies
            .find("let mut slot = div()")
            .expect("the popover needs a slot spanning the bar, not the face");
        let (face, slot) = bodies.split_at(split);
        assert!(
            face.contains(".h(px(stage::CONTROL_SIZE))"),
            "the control's face keeps its own 44 pt box: {face}"
        );
        assert!(
            slot.contains(".h(px(m::TRANSPORT_HEIGHT))"),
            "the slot the panel hangs off must span the bar's own height: {slot}"
        );
        assert!(
            slot.contains(".items_center()"),
            "the face must stay centered in the taller slot, or the control moves: {slot}"
        );
        let popover = &slot[..slot.find("bar = bar.child(slot)").unwrap()];
        assert!(
            popover.contains("slot = slot.child(transport_popover("),
            "the panel must hang off that slot: {popover}"
        );
        // The anchor is the bar plus the hairline gap; the slot's bottom edge is
        // the bar's bottom edge, so the panel lands one gap above the bar's top.
        assert_eq!(m::TRANSPORT_HEIGHT + TRANSPORT_POPOVER_GAP, 56.);
    }

    /// A bar's popover opens **above** the bar, not below it.
    ///
    /// This is the geometry of 音量's slider: the panel's `bottom` is the bar's
    /// own height plus [`TRANSPORT_POPOVER_GAP`], so its top edge is one gap
    /// above the bar's top edge. An `.top(..)` anchor (or a `bottom` smaller
    /// than the bar) would open it over the bar itself or over the panel area.
    ///
    /// The assertions read the element's resolved style, so they fail if the
    /// anchor is flipped, not merely if a constant is edited.
    #[test]
    fn a_popover_opens_above_the_bar_not_below_it() {
        let mut popover = transport_popover(div());
        let style = popover.style();
        // `bottom` is measured from the bar's own bottom edge, so the panel
        // clears the whole bar plus the gap above it.
        assert_eq!(
            style.inset.bottom,
            Some(gpui_kit::Length::Definite(
                px(m::TRANSPORT_HEIGHT + TRANSPORT_POPOVER_GAP).into()
            )),
            "the popover must anchor above the bar"
        );
        assert_eq!(style.inset.top, None, "an upward popover has no top anchor");
        // Sanity: the anchor really is outside the bar's own box, so it can
        // never cover the bar or the panel that sits one composer gap above it.
        assert!(m::TRANSPORT_HEIGHT + TRANSPORT_POPOVER_GAP > m::TRANSPORT_HEIGHT);
    }

    /// An open popover must not paint a themed surface: a light system theme
    /// may not turn it white (the inbox's white button is that defect). The
    /// surface colours come from the fixed overlay palette.
    #[test]
    fn a_popover_keeps_the_fixed_overlay_surface() {
        let mut popover = transport_popover(div());
        let style = popover.style();
        assert_eq!(
            style.background,
            Some(rgba(s::CARD_BG).into()),
            "the popover surface is the overlay card colour, not a theme colour"
        );
        assert_eq!(
            style.border_color,
            Some(rgba(s::BORDER).into()),
            "hairline from the overlay palette"
        );
        // The overlay palette is dark and translucent; a theme-derived surface
        // would not satisfy both.
        assert!(s::CARD_BG < 0x80000000, "dark surface");
        assert!(s::CARD_BG & 0xff < 0xff, "translucent surface");
    }

    /// The panel is a **column around a vertical track**, not a horizontal bar
    /// segment: it stacks its content and its width is the track's own box plus
    /// the padding, so it cannot be the wide strip a horizontal slider needs.
    ///
    /// Both numbers are read off the element the bar really mounts, and the
    /// track's axis is the same value the panel's only control lays itself out
    /// with, so putting 音量 back on a horizontal track turns this red.
    #[test]
    fn the_popover_is_a_column_around_a_vertical_track() {
        assert_eq!(
            crate::primitives::volume_track_axis(),
            gpui_kit::Axis::Vertical,
            "the panel is a column around a *vertical* track; a horizontal track \
             is the wide strip that was rejected"
        );
        assert_eq!(
            TRANSPORT_POPOVER_WIDTH,
            crate::primitives::VOLUME_TRACK_THICKNESS + 2. * TRANSPORT_POPOVER_PADDING
        );
        let mut popover = transport_popover(div());
        let style = popover.style();
        assert_eq!(
            style.flex_direction,
            Some(gpui_kit::FlexDirection::Column),
            "the panel stacks its controls; a row is the horizontal bar that was rejected"
        );
        assert_eq!(
            style.size.width,
            Some(gpui_kit::Length::Definite(px(TRANSPORT_POPOVER_WIDTH).into()))
        );
        // A vertical track (24 pt across) plus padding is a narrow card; the
        // rejected horizontal slider's panel had to be 132 pt wide to hold it.
        assert!(TRANSPORT_POPOVER_WIDTH < 132.);
        assert!(TRANSPORT_POPOVER_WIDTH > crate::primitives::VOLUME_TRACK_THICKNESS);
    }

    /// The open/closed state is the presence of the panel, and a control that
    /// carries one still clones and compares like every other control (the host
    /// stores and clones its control table).
    #[test]
    fn a_popover_is_the_controls_open_state_and_survives_clone_and_compare() {
        let closed = control("volume", gpui_kit::assets::IconName::Volume2);
        assert!(!closed.popover_open());
        let open = closed
            .clone()
            .popover(|_, _| div().into_any_element());
        assert!(open.popover_open(), "a built panel is the open state");
        assert_ne!(closed, open, "open and closed are distinct controls");
        // The builder is shared by a clone, so the two agree.
        let same = open.clone();
        assert_eq!(open, same);
        assert!(format!("{open:?}").contains("TransportPopover"));
    }

    /// The two entry points must stay one bar: the window-less
    /// [`transport_bar`] and the window-carrying [`transport_bar_in`] share the
    /// same loop, so a host that supplies no popover keeps the exact bar.
    #[test]
    fn both_bar_entry_points_share_one_geometry() {
        let source = include_str!("shell.rs");
        let no_window = &source[source.find("pub fn transport_bar(").unwrap()..];
        let no_window = &no_window[..no_window.find("\n}").unwrap()];
        assert!(
            no_window.contains("transport_bar_slots(controls, None"),
            "the window-less bar must reuse the shared loop: {no_window}"
        );
        let with_window = &source[source.find("pub fn transport_bar_in(").unwrap()..];
        let with_window = &with_window[..with_window.find("\n}").unwrap()];
        assert!(
            with_window.contains("transport_bar_slots(controls, Some((window, cx))"),
            "the window-carrying bar must reuse the shared loop: {with_window}"
        );
        // Both return the same element type, so a host can swap them freely.
        assert!(no_window.contains("-> AnyElement") && with_window.contains("-> AnyElement"));
    }

    /// 音量 and 小窗 live in the bar now. The panel's own footer is gone, so the
    /// bar's control table is the only place either one is named; the two panel
    /// ids the duplicate row used must not come back, and neither control may
    /// steal the wide settings slot.
    #[test]
    fn the_panel_footer_is_gone_and_its_controls_are_ordinary_bar_slots() {
        let source = include_str!("shell.rs");
        // The ids are assembled at run time so this test's own source (including
        // its doc comment) cannot satisfy the search, which would make the
        // assertion pass for the wrong reason.
        for suffix in ["-lyrics", "-compact"] {
            let id = format!("media{suffix}");
            assert!(
                !source.contains(&id),
                "the panel footer's `{id}` must not return to the bar"
            );
        }
        // The two moved controls are ordinary 44 pt slots: expanding the bar
        // moved every slot after 歌词, and the derivation must follow. Each new
        // child costs its own slot **and** the flex gap that precedes it, so the
        // bar grows by `44 + 6` per control — a derivation that forgot the gap
        // would report 88.
        let mut before: Vec<_> = (0..11).map(|_| control("regular", gpui_kit::assets::IconName::Music)).collect();
        before.push(control("visual", gpui_kit::assets::IconName::Settings));
        let mut after = before.clone();
        after.push(control("volume", gpui_kit::assets::IconName::Music));
        after.push(control("compact", gpui_kit::assets::IconName::Minimize));
        assert_eq!(after.len(), before.len() + 2);
        assert_eq!(
            transport_width(&after) - transport_width(&before),
            2. * (stage::CONTROL_SIZE + stage::GROUP_GAP),
            "each moved control is one 44 pt slot plus the flex gap it brings"
        );
        assert_eq!(after[after.len() - 1].slot_width(), stage::CONTROL_SIZE);
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
