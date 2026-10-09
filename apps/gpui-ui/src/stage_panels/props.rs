//! 「我的物件」 — the original `ResidentPropEditorView`
//! (`apps/macos/Sources/GMGNRadio/VisualEngine/ResidentPropEditorView.swift`,
//! frame from `VisualEngine/StageWindowController.swift:1522-1523`), rebuilt on
//! gpui-kit.
//!
//! Shape of the surface, and why it is split this way:
//!
//! - **Two mutually exclusive scopes, one projection.** 「我的物件」 and
//!   「房间里」 are the same list seen through `showsPlacedOnly`; the pair is
//!   decided once by [`ownership_scope`] instead of being re-spelled at the picker,
//!   at the empty state and at every row.
//! - **One content scroll, fixed header and fixed footer.** The title row (the
//!   current scope's name, [`panel_title`], + collapse) never scrolls, so the
//!   collapse control cannot be pushed out of the panel; everything below it
//!   scrolls inside the original 390 pt cap. The 「还有 N 件」 control is the
//!   footer, **outside** that scroll ([`ResidentPropEditorPane::remaining_toggle`]):
//!   it used to be a plain line after the last row inside the scroll, so on a
//!   small window it sat below the fold, had no click handler at all, and the
//!   pane's own 390 pt frame was 16 pt taller than the box the shell clips it to.
//!   One click now lifts the frame to the extent the window allows
//!   ([`m::PANEL_MAX_HEIGHT_EXPANDED`]); the single scroll still reaches the last
//!   row either way, and the host's own row budget is what the count states.
//! - **A built-in device is an object, not a second surface.** 音乐播放器 /
//!   许愿机 arrive as rows of the same list, in the same groups and with the
//!   same status words; the one difference the projection can state is that the
//!   world authority takes exactly one operation for them
//!   ([`SelectedControls::Device`]) and that 删除 does not exist for them
//!   ([`delete_entry_visible`]). The panel never draws a second device card
//!   beside itself, so two panels can never overlap.
//! - **The selected object is two mutually exclusive control sets**, chosen by
//!   [`selected_controls`]: in the hand it is 展示微调 + nudge + rotate + 放回;
//!   loose it is 拿着看 / 收回 with the hold-point picker on the same line. The
//!   size block only exists while the object is not held ([`size_controls_visible`]).
//! - **The size slider is a draft.** Dragging only changes the readout; the one
//!   `stage.props.resize` command is emitted on release (`SliderEvent::Release`).
//!   Which value the readout shows is [`slider_readout_value`] — the draft while
//!   it belongs to the selected object, otherwise that object's own longest edge.
//! - **Permanent delete asks once, in a real kit dialog** (`window.open_dialog`),
//!   never an inline red block, and never emits the delete command when the
//!   answer is 取消 or the host is saving.
//! - **Nothing here reads `cx.theme()`** for panel chrome: colours and sizes come
//!   from [`crate::ui_tokens::scene`], [`crate::primitives`] and
//!   [`crate::ui_tokens::props`]. Controls are kit components with an explicit
//!   custom variant, so hover/pressed/disabled chrome stays dark over the scene.
use gpui_kit::assets::IconName as AssetIcon;
use gpui_kit::component::empty::{
    Empty as KitEmpty, EmptyHeader as KitEmptyHeader, EmptyTitle as KitEmptyTitle,
};
use gpui_kit::component::{
    button::*,
    slider::{Slider, SliderEvent, SliderState},
    tab::{Tab, TabBar},
    *,
};
use gpui_kit::prelude::{FluentBuilder as _, InteractiveElement as _, StatefulInteractiveElement as _};
use gpui_kit::*;
use serde_json::{Value, json};

use crate::ui_tokens::props as m;
use super::scene_variant;
use crate::primitives as ui;
use crate::ui_tokens as doc;
use crate::ui_tokens::scene as s;

/// The pending permanent-delete command: emitted exactly once, and only when the
/// dialog was confirmed while the host was not saving.
fn finish_delete(pending: &mut Option<Value>, confirmed: bool, saving: bool) -> Option<Value> {
    pending.take().filter(|_| confirmed && !saving)
}
fn row_key_selects(selectable: bool, saving: bool, modified: bool, key: &str) -> bool {
    selectable && !saving && !modified && matches!(key, "enter" | "space")
}

/// The two mutually exclusive views of the ownership projection
/// (`showsPlacedOnly`, `ResidentPropEditorView.swift:29-38,151-153`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct OwnershipScope {
    /// The picker label.
    pub title: &'static str,
    /// The sentence shown when the projection has no rows at all.
    pub empty: &'static str,
}

pub fn ownership_scope(placed_only: bool) -> OwnershipScope {
    if placed_only {
        OwnershipScope {
            title: "房间里",
            empty: "房间里还没有摆放物件",
        }
    } else {
        OwnershipScope {
            title: "我的物件",
            empty: "还没有许愿。对居民说你想要什么，做好后会出现在这里。",
        }
    }
}

/// The picker index for a scope (`Picker(selection: $state.showsPlacedOnly)`).
pub fn ownership_scope_index(placed_only: bool) -> usize {
    usize::from(placed_only)
}

/// `ownershipIcon` (`:290-299`): the symbol carries the semantic group only, the
/// status word itself always comes from the projection's `statusText`.
pub fn ownership_icon(state: &str) -> AssetIcon {
    match state {
        "generating" => AssetIcon::Hourglass,
        "awaitingClaim" => AssetIcon::CircleArrowDown,
        "inInventory" => AssetIcon::Package,
        "placed" => AssetIcon::Box,
        "failed" => AssetIcon::TriangleAlert,
        _ => AssetIcon::Archive,
    }
}

/// `ownershipTint` (`:301-308`).
pub fn ownership_tint(state: &str) -> u32 {
    match state {
        "awaitingClaim" => m::TINT_AWAITING_CLAIM,
        "inInventory" => m::TINT_IN_INVENTORY,
        "failed" => m::TINT_FAILED,
        _ => m::TINT_NEUTRAL,
    }
}

/// Which control set the selected object shows (`:41-73`). They are mutually
/// exclusive: 展示微调 and 拿着看 can never both be on screen.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectedControls {
    /// In the resident's hand: 展示微调 + nudge + rotate + 放回.
    Held,
    /// Loose in the room: 拿着看 / 收回 + the hold-point picker.
    Loose,
    /// A built-in device (基础设备): it is an object like any other — it lives
    /// in the room, is selected and reads its status the same way — but the
    /// world authority takes exactly one operation for it. `world_device.rs`
    /// `can_place` accepts a device id whose only metadata is
    /// `gmgn.builtin-device.v1` and commits it through `world.device.place`,
    /// while every `world.prop.command` arm runs `world_prop::reduce`, whose
    /// first act is `generated(&before)?` → `world_prop_basic_object`
    /// (`services/gmgn-taskd/src/world_prop.rs:1884` → `:130-134`). So 摆放 /
    /// 重新摆放 (the host's own `ui.device.place`) is the whole set: no 收回,
    /// no hold point, and — the one difference the list must show — no 删除.
    Device,
    /// Nothing selected.
    None,
}

/// The selected control set. `is_device` is the projection's own fact
/// (`selected.deviceTemplateID`), so the device branch can never be guessed
/// from a name or an id prefix.
pub fn selected_controls_for(
    has_selection: bool,
    is_held: bool,
    is_device: bool,
) -> SelectedControls {
    if !has_selection {
        SelectedControls::None
    } else if is_device {
        SelectedControls::Device
    } else if is_held {
        SelectedControls::Held
    } else {
        SelectedControls::Loose
    }
}

pub fn selected_controls(has_selection: bool, is_held: bool) -> SelectedControls {
    selected_controls_for(has_selection, is_held, false)
}

/// A row/selection that is one of the world's own built-in devices. The
/// projection sets `deviceTemplateID` exactly when the object came from
/// `builtinDevices.templates` (`inventory_ui.rs`), never by inspecting an id.
pub fn is_device_selection(selected: &Value) -> bool {
    selected["deviceTemplateID"]
        .as_str()
        .is_some_and(|id| !id.is_empty())
}

/// 删除 is the one entry a built-in device must never show: the row would be
/// refused by name (`world_prop_basic_object`) after the click. The list shows
/// no delete entry for it at all instead of a disabled one, so nothing promises
/// an operation that cannot exist.
pub fn delete_entry_visible(is_device: bool) -> bool {
    !is_device
}

/// The panel's title is the content on screen, not a fixed word
/// (「面板标题按当前内容变」): both scopes come from [`ownership_scope`], so the
/// title can never drift from the picker or the empty sentence.
pub fn panel_title(placed_only: bool) -> &'static str {
    ownership_scope(placed_only).title
}

/// `sizeControl` visibility (`:338-339`): only a selected, not-held object with
/// its own generated prop can be resized.
pub fn size_controls_visible(has_selection: bool, is_held: bool, has_generated_prop: bool) -> bool {
    has_selection && !is_held && has_generated_prop
}

/// `String(format: "最长边 %.2f m", prop.longestEdge)` (`:346`).
pub fn longest_edge_readout(meters: f64) -> String {
    format!("最长边 {meters:.2} m")
}

/// `String(format: "%.2f m", …)` (`:359-360`).
pub fn size_readout(meters: f64) -> String {
    format!("{meters:.2} m")
}

/// The size a `sizeStep` button targets (`:375-380`): the object's current
/// longest edge plus the step — never the in-flight draft.
pub fn size_step_target(longest_edge: f64, delta: f64) -> f64 {
    longest_edge + delta
}

/// Which value the slider-side readout prints (`:351`, `:359`): the draft while
/// it belongs to the selected object, otherwise that object's longest edge. A
/// draft left over from another object must never leak into this one's readout.
pub fn slider_readout_value(
    selected_object: Option<&str>,
    draft_object: Option<&str>,
    draft: f64,
    longest_edge: f64,
) -> f64 {
    match (selected_object, draft_object) {
        (Some(selected), Some(draft_object)) if selected == draft_object => draft,
        _ => longest_edge,
    }
}

/// `"尺寸来源 · " + provenance` (`:368`).
pub fn size_provenance_readout(provenance: &str) -> String {
    format!("尺寸来源 · {provenance}")
}

/// The wall-placement sentence (`:111-114`). Zero derived wall faces must say so
/// rather than print a bare `0`, which reads as "there is a wall but you cannot
/// use it".
pub fn wall_placement_readout(wall_faces: u64, wall_placeable_cells: u64) -> String {
    if wall_faces == 0 {
        "靠墙 · 这个空间里没有识别到竖直面".to_owned()
    } else {
        format!("靠墙 · {wall_faces} 面墙，{wall_placeable_cells} 格可背朝墙放置")
    }
}

/// Whether a legend entry is drawn (`:92-94`): the wall-placeable swatch only
/// appears when the space really derived vertical faces — a flat room must not
/// advertise a wall to lean on that does not exist. Entries the host does not
/// classify are always drawn.
pub fn legend_entry_visible(state: Option<&str>, wall_faces: u64) -> bool {
    state != Some("wallPlaceable") || wall_faces > 0
}

/// The hold-point display name for the selected object (`PropAttachmentSlots.displayName(for:)`).
pub fn hold_point_name<'a>(points: &'a [Value], hold_point: &Value) -> &'a str {
    points
        .iter()
        .find(|slot| slot["id"] == *hold_point)
        .and_then(|slot| slot["name"].as_str())
        .unwrap_or("")
}

pub struct ResidentPropEditorPane {
    snapshot: Value,
    commands: Vec<Value>,
    confirming_delete: Option<Value>,
    size: Entity<SliderState>,
    /// The object the slider value currently belongs to — the original
    /// `sizeDraftObjectID` (`:17`). Cleared when the draft is committed.
    draft_object: Option<String>,
    /// Whether 「还有 N 件」 has been clicked. The panel's own click state, like
    /// [`Self::draft_object`]: it changes the frame's height ceiling
    /// ([`m::PANEL_MAX_HEIGHT`] ⇄ [`m::PANEL_MAX_HEIGHT_EXPANDED`]) and nothing
    /// else, so it never travels to the host as an invented command.
    list_expanded: bool,
    _subscriptions: Vec<Subscription>,
}
impl ResidentPropEditorPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let size = cx.new(|_| {
            SliderState::new()
                .min(m::SIZE_MIN)
                .max(m::SIZE_MAX)
                .step(m::SIZE_STEP)
        });
        let subscription = cx.subscribe(&size, |this, _, event: &SliderEvent, cx| {
            match event {
                SliderEvent::Change(_) => {
                    // The drag is a draft: it changes the readout only.
                    if let Some(object) = this.snapshot["selected"]["objectID"].as_str() {
                        this.draft_object = Some(object.to_owned());
                    }
                    cx.notify();
                }
                SliderEvent::Release(value) => {
                    if this.snapshot["isSaving"].as_bool() != Some(true)
                        && !this.snapshot["selected"].is_null()
                        && this.snapshot["selected"]["held"].as_bool() != Some(true)
                    {
                        this.commands
                            .push(json!({"op":"stage.props.resize","value":value.start()}));
                    }
                    this.draft_object = None;
                    cx.notify();
                }
            }
        });
        let owner = Window::window_handle(window);
        let weak = cx.entity().downgrade();
        let escape = cx.intercept_keystrokes(move |event, window, cx| {
            if event.keystroke.key == "escape" && Window::window_handle(window) == owner {
                _ = weak.update(cx, |this, cx| {
                    if this.confirming_delete.take().is_some() {
                        window.close_dialog(cx);
                        cx.stop_propagation();
                        cx.notify();
                    }
                });
            }
        });
        Self {
            snapshot: Value::Null,
            commands: vec![json!({"op":"stage.props.load"})],
            confirming_delete: None,
            size,
            draft_object: None,
            list_expanded: false,
            _subscriptions: vec![subscription, escape],
        }
    }
    pub fn update_snapshot(
        &mut self,
        snapshot: Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.snapshot != snapshot {
            let object_changed = self.snapshot["selected"]["objectID"] != snapshot["selected"]["objectID"];
            if object_changed
                || self.snapshot["selected"]["longestEdge"] != snapshot["selected"]["longestEdge"]
            {
                if let Some(value) = snapshot["selected"]["longestEdge"].as_f64() {
                    self.size
                        .update(cx, |size, cx| size.set_value(value as f32, window, cx));
                }
            }
            if object_changed {
                self.draft_object = None;
            }
            self.snapshot = snapshot;
            cx.notify();
        }
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.commands)
    }

    /// The permanent-delete confirmation: a real kit dialog, opened from the one
    /// click that asks, confirmed by 「永久删除」.
    fn open_delete(&mut self, command: Value, window: &mut Window, cx: &mut Context<Self>) {
        let id = command["objectID"].clone();
        let name = self.snapshot["sections"]
            .as_array()
            .into_iter()
            .flatten()
            .flat_map(|s| s["rows"].as_array().into_iter().flatten())
            .find(|row| row["objectID"] == id)
            .and_then(|r| r["name"].as_str())
            .or_else(|| {
                (self.snapshot["selected"]["objectID"] == id)
                    .then(|| self.snapshot["selected"]["name"].as_str())
                    .flatten()
            })
            .unwrap_or("这一件")
            .to_owned();
        self.confirming_delete = Some(command);
        let weak = cx.entity().downgrade();
        window.open_dialog(cx, move |dialog, _, cx| {
            let saving = weak
                .upgrade()
                .is_none_or(|entity| entity.read(cx).snapshot["isSaving"].as_bool() == Some(true));
            let cancel = weak.clone();
            let confirm = weak.clone();
            let closed = weak.clone();
            dialog
                .title(format!("永久删除「{name}」？"))
                .close_button(false)
                .overlay_closable(false)
                .child("删除后不能恢复，它也不会再出现在「我的物件」里。")
                .footer(
                    div()
                        .flex()
                        .justify_end()
                        .gap_2()
                        .child(
                            Button::new("prop-cancel-delete")
                                .label("取消")
                                .on_click(move |_, window, cx| {
                                    _ = cancel.update(cx, |this, cx| {
                                        let _ = finish_delete(&mut this.confirming_delete, false, false);
                                        cx.notify();
                                    });
                                    window.close_dialog(cx);
                                }),
                        )
                        .child(
                            Button::new("prop-confirm-delete")
                                .danger()
                                .disabled(saving)
                                .label("永久删除")
                                .on_click(move |_, window, cx| {
                                    _ = confirm.update(cx, |this, cx| {
                                        if let Some(command) = finish_delete(
                                            &mut this.confirming_delete,
                                            true,
                                            this.snapshot["isSaving"].as_bool() == Some(true),
                                        ) {
                                            this.commands.push(command);
                                        }
                                        cx.notify();
                                    });
                                    window.close_dialog(cx);
                                }),
                        ),
                )
                .on_cancel(move |_, window, cx| {
                    _ = closed.update(cx, |this, cx| {
                        this.confirming_delete = None;
                        cx.notify();
                    });
                    window.close_dialog(cx);
                    true
                })
        });
    }

    /// A labelled control with the panel's fixed chrome. `icon` is the control's
    /// whole face: `label` is only ever the tooltip and the accessibility label.
    fn control(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        icon: AssetIcon,
        command: Value,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        self.control_with_a11y(id, label, icon, None, command, disabled, cx)
    }

    /// The same control, carrying the original Swift accessibility identifier.
    fn control_with_a11y(
        &self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        icon: AssetIcon,
        a11y_id: Option<String>,
        command: Value,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let label: SharedString = label.into();
        let disabled = disabled || self.snapshot["isSaving"].as_bool() == Some(true);
        let text = if disabled { s::TEXT_DIM } else { s::TEXT };
        Button::new(id)
            .custom(scene_variant(cx, 0x00000000, 0xffffff14, text))
            .small()
            .icon(icon)
            .rounded(px(m::ROW_RADIUS))
            .text_color(rgba(text))
            .disabled(disabled)
            .tooltip(label.clone())
            .accessibility_label(label)
            .when_some(a11y_id, |button, a11y| button.accessibility_id(a11y))
            .on_click(cx.listener(move |this, _, window, cx| {
                cx.stop_propagation();
                if command["op"] == "stage.props.delete" {
                    this.open_delete(command.clone(), window, cx);
                } else {
                    this.commands.push(command.clone());
                }
                cx.notify();
            }))
            .into_any_element()
    }

    /// The section heading: a folding button for 「已结束」, plain text otherwise
    /// (`ownershipSection`, `:177-202`).
    fn section_heading(
        &self,
        group: &str,
        title: String,
        folded: bool,
        saving: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let text = if saving { s::TEXT_DIM } else { s::TEXT_MUTED };
        let mut heading = h_flex()
            .w_full()
            .items_center()
            .gap(px(m::HEADING_GAP))
            .text_size(px(m::HEADING_SIZE))
            .font_weight(FontWeight::SEMIBOLD)
            .text_color(rgba(s::TEXT_MUTED));
        if folded {
            let command = json!({"op":"stage.props.fold","group":group,"folded":false});
            heading = heading.child(
                Button::new(format!("props-group-{group}"))
                    .custom(scene_variant(cx, 0x00000000, 0xffffff14, text))
                    .small()
                    .icon(AssetIcon::ChevronRight)
                    .tooltip(title.clone())
                    .rounded(px(m::ROW_RADIUS))
                    .text_color(rgba(text))
                    .disabled(saving)
                    .accessibility_id(format!("resident.ownership-section.{group}"))
                    .accessibility_label(title)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.commands.push(command.clone());
                        cx.notify();
                    })),
            );
        } else {
            heading = heading.child(div().child(title));
            if group == "ended" {
                heading = heading.child(
                    Button::new("props-ended-fold")
                        .custom(scene_variant(cx, 0x00000000, 0xffffff14, text))
                        .small()
                        .icon(AssetIcon::ChevronUp)
                        .tooltip("收起")
                        .rounded(px(m::ROW_RADIUS))
                        .text_color(rgba(text))
                        .disabled(saving)
                        .accessibility_label("收起已结束")
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.commands
                                .push(json!({"op":"stage.props.fold","group":"ended","folded":true}));
                            cx.notify();
                        })),
                );
            }
        }
        heading.child(div().flex_1()).into_any_element()
    }

    /// One ownership row (`ownershipRow`, `:216-245`): name, status sentence,
    /// check when selected, then the actions the projection allows.
    fn ownership_row(&self, row: &Value, cx: &mut Context<Self>) -> AnyElement {
        let id = row["id"].as_str().unwrap_or("").to_owned();
        let object = row["objectID"].clone();
        let selected = self.snapshot["selected"]["objectID"] == object && !object.is_null();
        let selectable = row["actions"]
            .as_array()
            .is_some_and(|a| a.iter().any(|v| v == "place" || v == "withdraw"));
        let saving = self.snapshot["isSaving"].as_bool() == Some(true);
        let state = row["state"].as_str().unwrap_or("");
        let name = row["name"].as_str().unwrap_or("");
        let status = row["statusText"].as_str().unwrap_or("");
        let label = format!("{name}，{status}{}", if selected { "，已选中" } else { "" });
        let select_command = json!({"op":"stage.props.select","objectID":object});
        let keyboard_command = select_command.clone();
        let head = Button::new(format!("props-row-{id}"))
            .custom(scene_variant(
                cx,
                if selected { m::ROW_FILL_SELECTED } else { m::ROW_FILL },
                m::ROW_FILL_HOVER,
                s::TEXT,
            ))
            .w_full()
            .px(px(m::ROW_PADDING / 2.))
            .rounded(px(m::ROW_RADIUS))
            .accessibility_id(format!("resident.ownership-row.{id}"))
            .accessibility_label(label)
            .text_color(rgba(s::TEXT))
            .disabled(saving)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(m::ROW_HEAD_GAP))
                    .child(
                        Icon::new(ownership_icon(state))
                            .size(px(m::STATUS_SIZE))
                            .text_color(rgba(s::TEXT)),
                    )
                    .child(div().flex_1().min_w(px(0.)).overflow_hidden().whitespace_nowrap().child(name.to_owned()))
                    .child(
                        div()
                            .text_size(px(m::STATUS_SIZE))
                            .text_color(rgba(ownership_tint(state)))
                            .overflow_hidden()
                            .whitespace_nowrap()
                            .child(status.to_owned()),
                    )
                    .when(selected, |line| {
                        line.child(
                            Icon::new(AssetIcon::Check)
                                .size(px(m::STATUS_SIZE))
                                .text_color(rgba(m::CHECK)),
                        )
                    }),
            )
            .on_key_down(cx.listener(move |this, event: &KeyDownEvent, _, cx| {
                if row_key_selects(
                    selectable,
                    this.snapshot["isSaving"].as_bool() == Some(true),
                    event.keystroke.modifiers.modified(),
                    event.keystroke.key.as_str(),
                ) {
                    this.commands.push(keyboard_command.clone());
                    cx.stop_propagation();
                    cx.notify();
                }
            }))
            .on_click(cx.listener(move |this, _, _, cx| {
                if selectable && !saving && this.snapshot["isSaving"].as_bool() != Some(true) {
                    this.commands.push(select_command.clone());
                    cx.notify();
                }
            }));
        let mut actions = h_flex()
            .w_full()
            .justify_end()
            .flex_wrap()
            .gap(px(m::ACTION_GAP))
            .child(div().flex_1());
        for action in row["actions"].as_array().into_iter().flatten() {
            let action = action.as_str().unwrap_or("");
            let label = match action {
                "claim" => "领取",
                "askResidentToFetch" => "让居民去取",
                "retry" => "重试",
                "retryInventoryRegistration" => "重试入库",
                "withdraw" => "收回",
                "delete" => "删除",
                _ => continue,
            };
            // The face is the icon only; `label` carries the words as tooltip and
            // accessibility label.
            let icon = match action {
                "askResidentToFetch" => AssetIcon::User,
                "retry" | "retryInventoryRegistration" => AssetIcon::RefreshCw,
                "withdraw" => AssetIcon::Inbox,
                "delete" => AssetIcon::Delete,
                _ => AssetIcon::ArrowDown,
            };
            if action == "askResidentToFetch" {
                // 「领取」够不到许愿机 ⇒ 按钮可见但置灰，并给出「让居民去取」。
                actions = actions.child(
                    Button::new(format!("props-{id}-claim-unavailable"))
                        .small()
                        .icon(AssetIcon::ArrowDown)
                        .tooltip("领取")
                        .rounded(px(m::ROW_RADIUS))
                        .disabled(true)
                        .accessibility_id(format!("resident.ownership-row.{id}.claim-unavailable"))
                        .accessibility_label("领取（当前够不到）"),
                );
            }
            let a11y = match action {
                "claim" => format!("resident.ownership-row.{id}.claim"),
                "askResidentToFetch" => format!("resident.ownership-row.{id}.ask-resident"),
                "retry" => format!("resident.ownership-row.{id}.retry"),
                "retryInventoryRegistration" => {
                    format!("resident.ownership-row.{id}.retry-inventory")
                }
                other => format!("resident.ownership-row.{id}.{other}"),
            };
            let command = json!({"op":format!("stage.props.{action}"),"objectID":object,"jobID":row["jobID"]});
            actions = actions.child(self.control_with_a11y(
                format!("props-{id}-{action}"),
                label,
                icon,
                Some(a11y),
                command,
                false,
                cx,
            ));
        }
        v_flex()
            .w_full()
            .gap(px(m::ROW_GAP))
            .p(px(m::ROW_PADDING))
            .rounded(px(m::ROW_RADIUS))
            .bg(rgba(if selected {
                m::ROW_FILL_SELECTED
            } else {
                m::ROW_FILL
            }))
            .child(head)
            .child(actions)
            .into_any_element()
    }

    /// The selected panel's 永久删除 entry — and for a built-in device there is
    /// no entry at all ([`delete_entry_visible`]): the world authority answers
    /// `world_prop_basic_object` (`world_prop.rs:1884` → `:130-134`), so a
    /// visible control would be a click that can only fail. Built as its own
    /// function so the absence is a render-level fact a test can check, not
    /// just a predicate.
    fn delete_entry(&self, visible: bool, cx: &mut Context<Self>) -> Option<AnyElement> {
        if !visible {
            return None;
        }
        let saving = self.snapshot["isSaving"].as_bool() == Some(true);
        Some(
            h_flex()
                .w_full()
                .gap(px(m::CONTROL_GAP))
                .child(
                    Button::new("prop-delete")
                        .custom(scene_variant(
                            cx,
                            0x00000000,
                            m::TINT_FAILED,
                            m::TINT_FAILED,
                        ))
                        .small()
                        .rounded(px(m::ROW_RADIUS))
                        .text_color(rgba(m::TINT_FAILED))
                        .disabled(saving)
                        .tooltip("永久删除这一件生成资产：不可恢复。正在摆放或拿在手里的会先收场再删。")
                        .accessibility_label("永久删除")
                        .child(
                            h_flex()
                                .items_center()
                                .gap(px(m::LEGEND_ENTRY_GAP))
                                .child(Icon::new(AssetIcon::Delete).size(px(m::STATUS_SIZE)))
                                .child("删除"),
                        )
                        .on_click(cx.listener(|this, _, window, cx| {
                            let object = this.snapshot["selected"]["objectID"].clone();
                            this.open_delete(
                                json!({"op":"stage.props.delete","objectID":object}),
                                window,
                                cx,
                            );
                            cx.notify();
                        })),
                )
                .child(div().flex_1())
                .into_any_element(),
        )
    }

    /// 「还有 N 件」 as the control it reads like.
    ///
    /// The host's row budget is what produces `remainingCount`, and it publishes
    /// no "give me the rest" op (`apps/macos/.../GMGNRadioApp.swift::gpuiPropCommand`
    /// has no budget arm, so an invented op would be an op the host refuses) —
    /// therefore the one honest, in-panel expansion is height: one click lifts
    /// this pane's ceiling from the original's `.frame(maxHeight: 390)` to the
    /// extent the shell measured for it ([`m::PANEL_MAX_HEIGHT_EXPANDED`]), so
    /// every row the projection delivered is on screen at once and the existing
    /// scroll can reach the last one. A second click puts the frame back.
    ///
    /// The count is never recomputed here: it stays the host's own statement
    /// about rows it withheld. Nothing is cut either way — the collapsed panel
    /// keeps the same scroll, so all delivered rows stay reachable.
    fn remaining_toggle(&self, count: u64, cx: &mut Context<Self>) -> AnyElement {
        let expanded = self.list_expanded;
        let text = format!("还有 {count} 件");
        let action = if expanded { "收起列表" } else { "展开列表" };
        Button::new("props-remaining-toggle")
            .custom(scene_variant(cx, 0x00000000, 0xffffff14, s::TEXT_MUTED))
            .small()
            .w_full()
            .rounded(px(m::ROW_RADIUS))
            .text_size(px(m::HEADING_SIZE))
            .text_color(rgba(s::TEXT_MUTED))
            .tooltip(action)
            .accessibility_id("resident.ownership.remaining")
            .accessibility_label(format!("{text}，{action}"))
            .child(
                h_flex()
                    .items_center()
                    .gap(px(m::LEGEND_ENTRY_GAP))
                    .child(
                        Icon::new(if expanded {
                            AssetIcon::ChevronUp
                        } else {
                            AssetIcon::ChevronDown
                        })
                        .size(px(m::STATUS_SIZE))
                        .text_color(rgba(s::TEXT_MUTED)),
                    )
                    .child(text),
            )
            .on_click(cx.listener(|this, _, _, cx| {
                this.list_expanded = !this.list_expanded;
                cx.notify();
            }))
            .into_any_element()
    }

    /// The hold-point picker (`slotPicker`, `:314-327`): one segmented control,
    /// 156 pt wide, in whichever control row is on screen.
    fn slot_picker(
        &self,
        points: &[Value],
        selected: &Value,
        saving: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let active = points
            .iter()
            .position(|slot| slot["id"] == selected["holdPoint"]);
        let width = m::SLOT_PICKER_WIDTH / (points.len().max(1) as f32);
        let points = points.to_vec();
        TabBar::new("prop-hold-points")
            .segmented()
            .small()
            .w(px(m::SLOT_PICKER_WIDTH))
            .h(px(m::SLOT_PICKER_HEIGHT))
            .when_some(active, |bar, index| bar.selected_index(index))
            .children(points.iter().map(|slot| {
                Tab::new()
                    .label(slot["name"].as_str().unwrap_or("").to_owned())
                    .w(px(width))
                    .disabled(saving)
            }))
            .on_click(cx.listener(move |this, index: &usize, _, cx| {
                if let Some(point) = points.get(*index) {
                    this.commands
                        .push(json!({"op":"stage.props.hold","point":point["id"]}));
                    cx.notify();
                }
            }))
            .into_any_element()
    }

    /// The size block (`sizeControl`, `:338-373`): step buttons with the
    /// snapshot reading, then the slider with the draft reading.
    fn size_control(&self, selected: &Value, cx: &mut Context<Self>) -> AnyElement {
        let longest = selected["longestEdge"].as_f64().unwrap_or(0.);
        let object = selected["objectID"].as_str();
        let draft = self.size.read(cx).value().start() as f64;
        let reading = slider_readout_value(
            object,
            self.draft_object.as_deref(),
            draft,
            longest,
        );
        let mut steps = h_flex()
            .w_full()
            .items_center()
            .gap(px(m::SIZE_STEP_GAP));
        for (label, delta) in [
            ("−10 cm", m::SIZE_DELTAS[0]),
            ("−1 cm", m::SIZE_DELTAS[1]),
            ("+1 cm", m::SIZE_DELTAS[2]),
            ("+10 cm", m::SIZE_DELTAS[3]),
        ] {
            steps = steps.child(self.control(
                format!("prop-size-{label}"),
                label,
                if delta < 0. {
                    AssetIcon::Minus
                } else {
                    AssetIcon::Plus
                },
                json!({"op":"stage.props.resize","value":size_step_target(longest, delta)}),
                false,
                cx,
            ));
        }
        steps = steps.child(div().flex_1().min_w(px(0.))).child(
            div()
                .flex_shrink_0()
                .whitespace_nowrap()
                .font_family(doc::FONT_FAMILY)
                .text_size(px(m::READOUT_SIZE))
                .child(longest_edge_readout(longest)),
        );
        let mut column = v_flex()
            .w_full()
            .gap(px(m::CONTROL_GAP))
            .child(divider())
            .child(
                div()
                    .text_color(rgba(s::TEXT_MUTED))
                    .child("尺寸"),
            )
            .child(steps)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(m::SIZE_SLIDER_GAP))
                    .child(
                        div()
                            .id("prop-size-slider")
                            .flex_1()
                            .min_w(px(0.))
                            .role(Role::Slider)
                            .aria_label("物件最长边")
                            .child(
                                Slider::new(&self.size)
                                    .disabled(self.snapshot["isSaving"].as_bool() == Some(true)),
                            ),
                    )
                    .child(
                        div()
                            .w(px(m::READOUT_WIDTH))
                            .text_right()
                            .font_family(doc::FONT_FAMILY)
                            .text_size(px(m::READOUT_SIZE))
                            .child(size_readout(reading)),
                    ),
            );
        if let Some(description) = selected["sizeDescription"].as_str() {
            column = column.child(
                ui::muted(description).text_size(px(m::DESCRIPTION_SIZE)),
            );
        }
        if let Some(provenance) = selected["sizeProvenance"].as_str() {
            column = column.child(
                ui::muted(size_provenance_readout(provenance))
                    .id("resident.prop-editor.size-provenance")
                    .text_size(px(m::DESCRIPTION_SIZE)),
            );
        }
        column.into_any_element()
    }
}

/// The panel's hairline: the shared 1 pt divider in the original's
/// `Divider().overlay(.white.opacity(0.08))`.
fn divider() -> AnyElement {
    ui::divider().bg(rgba(m::DIVIDER)).into_any_element()
}

/// The ownership projection's empty sentence, as the kit `Empty` state.
fn empty_list(message: &str) -> AnyElement {
    KitEmpty::new()
        .items_start()
        .text_left()
        .py(px(m::EMPTY_PADDING_V))
        .header(
            KitEmptyHeader::new().items_start().title(
                KitEmptyTitle::new()
                    .text_size(px(m::BODY_SIZE))
                    .font_weight(FontWeight::NORMAL)
                    .text_color(rgba(s::TEXT_MUTED))
                    .child(message.to_owned()),
            ),
        )
        .into_any_element()
}

#[cfg(test)]
mod tests {
    // gpui re-exports a `test` attribute macro; `super::*` would shadow the
    // built-in one, so name it explicitly like the rest of this crate does.
    use core::prelude::v1::test;
    use serde_json::json;

    use super::*;

    #[test]
    fn cancellation_never_emits_delete_and_clears_confirmation() {
        let mut pending = Some(json!({"op":"stage.props.delete","objectID":"test-only"}));
        assert!(finish_delete(&mut pending, false, false).is_none());
        assert!(pending.is_none());
    }
    #[test]
    fn confirm_emits_original_command_once_only_when_not_saving() {
        let command = json!({"op":"stage.props.delete","objectID":"test-only"});
        let mut pending = Some(command.clone());
        assert_eq!(finish_delete(&mut pending, true, false), Some(command));
        assert!(finish_delete(&mut pending, true, false).is_none());
        pending = Some(json!({"op":"stage.props.delete"}));
        assert!(finish_delete(&mut pending, true, true).is_none());
    }
    #[test]
    fn row_keyboard_selects_only_enabled_unmodified_enter_or_space() {
        assert!(row_key_selects(true, false, false, "enter"));
        assert!(row_key_selects(true, false, false, "space"));
        assert!(!row_key_selects(false, false, false, "enter"));
        assert!(!row_key_selects(true, true, false, "space"));
        assert!(!row_key_selects(true, false, true, "enter"));
        assert!(!row_key_selects(true, false, false, "escape"));
    }

    /// 「我的物件」 and 「房间里」 are mutually exclusive: different labels, and an
    /// empty list must say which of the two is empty.
    #[test]
    fn ownership_scopes_are_mutually_exclusive_with_distinct_empty_copy() {
        let mine = ownership_scope(false);
        let placed = ownership_scope(true);
        assert_eq!(mine.title, "我的物件");
        assert_eq!(placed.title, "房间里");
        assert_ne!(mine, placed);
        assert_eq!(placed.empty, "房间里还没有摆放物件");
        assert_eq!(
            mine.empty,
            "还没有许愿。对居民说你想要什么，做好后会出现在这里。"
        );
        assert_ne!(mine.empty, placed.empty);
        assert_eq!(ownership_scope_index(false), 0);
        assert_eq!(ownership_scope_index(true), 1);
        assert_ne!(ownership_scope_index(false), ownership_scope_index(true));
    }

    /// `ownershipIcon` / `ownershipTint` for each projected state; an unknown
    /// state must fall back to the neutral 「已结束」 pair, never to a claim tint.
    #[test]
    fn ownership_state_symbols_and_tints_match_the_original_projection() {
        assert_eq!(ownership_icon("generating"), AssetIcon::Hourglass);
        assert_eq!(ownership_icon("awaitingClaim"), AssetIcon::CircleArrowDown);
        assert_eq!(ownership_icon("inInventory"), AssetIcon::Package);
        assert_eq!(ownership_icon("placed"), AssetIcon::Box);
        assert_eq!(ownership_icon("failed"), AssetIcon::TriangleAlert);
        assert_eq!(ownership_icon("ended"), AssetIcon::Archive);
        assert_eq!(ownership_icon("nonsense"), AssetIcon::Archive);

        assert_eq!(ownership_tint("awaitingClaim"), m::TINT_AWAITING_CLAIM);
        assert_eq!(ownership_tint("inInventory"), m::TINT_IN_INVENTORY);
        assert_eq!(ownership_tint("failed"), m::TINT_FAILED);
        for neutral in ["generating", "placed", "ended", "nonsense"] {
            assert_eq!(ownership_tint(neutral), m::TINT_NEUTRAL);
        }
        assert_ne!(ownership_tint("failed"), ownership_tint("inInventory"));
    }

    /// The selected object's controls are mutually exclusive (`:41-73`).
    #[test]
    fn selected_object_controls_are_mutually_exclusive() {
        assert_eq!(selected_controls(false, false), SelectedControls::None);
        assert_eq!(selected_controls(false, true), SelectedControls::None);
        assert_eq!(selected_controls(true, true), SelectedControls::Held);
        assert_eq!(selected_controls(true, false), SelectedControls::Loose);
        assert_ne!(SelectedControls::Held, SelectedControls::Loose);
    }

    /// 基础设备 is its own control set: the device fact outranks the held bit,
    /// and it is never one of the two generated-prop sets (`Device` would
    /// otherwise draw 收回 / 挂点 / 尺寸, all of which the world authority
    /// refuses with `world_prop_basic_object`).
    #[test]
    fn a_builtin_device_is_its_own_control_set() {
        assert_eq!(
            selected_controls_for(true, false, true),
            SelectedControls::Device
        );
        assert_eq!(
            selected_controls_for(true, true, true),
            SelectedControls::Device
        );
        assert_ne!(SelectedControls::Device, SelectedControls::Loose);
        assert_ne!(SelectedControls::Device, SelectedControls::Held);
        assert_eq!(selected_controls_for(false, false, true), SelectedControls::None);
        // The projection's marker is the only thing that turns the branch on.
        assert!(is_device_selection(&json!({"deviceTemplateID":"prop.jukebox"})));
        assert!(!is_device_selection(&json!({"objectID":"prop.jukebox"})));
        assert!(!is_device_selection(&json!({"deviceTemplateID":""})));
        assert!(!is_device_selection(&json!(null)));
    }

    /// 删除 has no entry for a built-in device: the row-level actions never
    /// carry it (`inventory_ui.rs`) and the selected panel must not build the
    /// button either — a visible-but-refused control is exactly the "点了才失败"
    /// the product forbids.
    #[test]
    fn a_builtin_device_has_no_delete_entry() {
        assert!(!delete_entry_visible(true));
        assert!(delete_entry_visible(false));
        assert_ne!(delete_entry_visible(true), delete_entry_visible(false));
    }

    /// The same rule as a **render-level** fact: the frames the pane actually
    /// paints contain no 删除 target for a device selection, while a generated
    /// prop keeps exactly the one it always had. Dropping the gate fails here,
    /// not only in the predicate above.
    #[test]
    fn the_delete_entry_is_not_built_for_a_builtin_device() {
        use gpui_kit::test::TestWindowExt as _;
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| super::ResidentPropEditorPane::new(window, cx));
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        let device = json!({
            "objectID": "prop.jukebox", "name": "音乐播放器", "held": false,
            "enabled": true, "deviceTemplateID": "prop.jukebox", "holdPoint": "hand"
        });
        let prop = json!({
            "objectID": "o1", "name": "长剑", "held": false, "enabled": true,
            "longestEdge": 1.4, "holdPoint": "hand"
        });
        cx.update_window(handle.into(), |_, window, cx| {
            let pane = stored.borrow().as_ref().unwrap().clone();
            for (selected, expected) in [(device.clone(), false), (prop.clone(), true)] {
                pane.update(cx, |pane, cx| {
                    assert_eq!(is_device_selection(&selected), !expected, "{selected} marker");
                    assert_eq!(
                        pane.delete_entry(delete_entry_visible(is_device_selection(&selected)), cx)
                            .is_some(),
                        expected,
                        "{selected} must {} a 删除 entry",
                        if expected { "have" } else { "not have" }
                    );
                    let mut snapshot = pane.snapshot.clone();
                    if !snapshot.is_object() {
                        snapshot = json!({});
                    }
                    snapshot["selected"] = selected.clone();
                    snapshot["placedOnly"] = json!(false);
                    snapshot["isSaving"] = json!(false);
                    snapshot["rowCount"] = json!(1);
                    snapshot["sections"] = json!([]);
                    pane.update_snapshot(snapshot, window, cx);
                    let _ = pane.take_commands();
                });
                // What the frame really painted: no 删除 target to click.
                window.render_frame(cx);
                assert_eq!(
                    window.try_find("prop-delete").is_some(),
                    expected,
                    "{selected} must {} the 删除 control in the painted frame",
                    if expected { "have" } else { "not have" }
                );
                window.draw(cx).clear(cx);
            }
        })
        .unwrap();
    }

    /// The panel title is the content on screen, so it can never contradict the
    /// scope picker or the empty sentence of the same scope.
    #[test]
    fn the_panel_title_follows_the_current_scope() {
        assert_eq!(panel_title(false), "我的物件");
        assert_eq!(panel_title(true), "房间里");
        assert_eq!(panel_title(false), ownership_scope(false).title);
        assert_eq!(panel_title(true), ownership_scope(true).title);
        assert_ne!(panel_title(false), panel_title(true));
    }

    /// The size block exists only for a selected, loose object with a generated
    /// prop (`:338-339`).
    #[test]
    fn size_controls_require_a_selected_loose_generated_prop() {
        assert!(size_controls_visible(true, false, true));
        assert!(!size_controls_visible(true, true, true));
        assert!(!size_controls_visible(true, false, false));
        assert!(!size_controls_visible(false, false, true));
    }

    /// The two readouts print the original formats, so a slider value can never
    /// be mistaken for the object's stored size.
    #[test]
    fn size_readouts_use_the_original_format() {
        assert_eq!(longest_edge_readout(1.4), "最长边 1.40 m");
        assert_eq!(longest_edge_readout(0.0), "最长边 0.00 m");
        assert_eq!(size_readout(1.4), "1.40 m");
        assert_ne!(longest_edge_readout(1.4), size_readout(1.4));
        assert_eq!(size_provenance_readout("手动改过"), "尺寸来源 · 手动改过");
    }

    /// The step buttons always step the *stored* longest edge, never the draft.
    #[test]
    fn size_steps_target_the_stored_longest_edge() {
        assert_eq!(size_step_target(1.0, -0.1), 0.9);
        assert_eq!(size_step_target(1.0, 0.1), 1.1);
        assert_eq!(size_step_target(0.02, -0.1), -0.08);
        assert_ne!(size_step_target(1.0, 0.1), size_step_target(1.0, 0.01));
    }

    /// The draft readout belongs to one object only: a draft carried over from a
    /// different object must fall back to the newly selected object's own size.
    #[test]
    fn slider_readout_uses_the_draft_only_for_its_own_object() {
        assert_eq!(
            slider_readout_value(Some("sword"), Some("sword"), 2.0, 1.0),
            2.0
        );
        assert_eq!(
            slider_readout_value(Some("sword"), Some("lamp"), 2.0, 1.0),
            1.0
        );
        assert_eq!(slider_readout_value(Some("sword"), None, 2.0, 1.0), 1.0);
        assert_eq!(slider_readout_value(None, Some("sword"), 2.0, 1.0), 1.0);
    }

    #[test]
    fn wall_placement_text_never_prints_a_bare_zero() {
        assert_eq!(
            wall_placement_readout(0, 0),
            "靠墙 · 这个空间里没有识别到竖直面"
        );
        assert_eq!(wall_placement_readout(2, 7), "靠墙 · 2 面墙，7 格可背朝墙放置");
        // Zero faces is one sentence no matter how many cells were projected,
        // and it never prints "0 面墙".
        assert_eq!(wall_placement_readout(0, 5), wall_placement_readout(0, 0));
        assert!(!wall_placement_readout(0, 5).contains("0 面墙"));
        assert_ne!(wall_placement_readout(1, 0), wall_placement_readout(0, 0));
    }

    /// A flat room must not draw the wall-placeable legend entry; every other
    /// entry (and anything the host does not classify) stays.
    #[test]
    fn legend_hides_the_wall_swatch_only_without_derived_faces() {
        assert!(!legend_entry_visible(Some("wallPlaceable"), 0));
        assert!(legend_entry_visible(Some("wallPlaceable"), 1));
        for other in ["placeable", "blocked", "occupied"] {
            assert!(legend_entry_visible(Some(other), 0));
        }
        assert!(legend_entry_visible(None, 0));
        assert_ne!(
            legend_entry_visible(Some("wallPlaceable"), 0),
            legend_entry_visible(Some("wallPlaceable"), 2)
        );
    }

    #[test]
    fn hold_point_name_reads_the_projection_and_falls_back_empty() {
        let points = vec![json!({"id":"hand","name":"右手"}), json!({"id":"back","name":"背后"})];
        assert_eq!(hold_point_name(&points, &json!("hand")), "右手");
        assert_eq!(hold_point_name(&points, &json!("back")), "背后");
        assert_eq!(hold_point_name(&points, &json!("gone")), "");
        assert_eq!(hold_point_name(&[], &json!("hand")), "");
    }

    /// Permanent delete asks through a real kit dialog (never an inline red
    /// block): the click opens the dialog, keeps the command pending, and the
    /// command is only emitted after a confirmation.
    #[test]
    fn permanent_delete_opens_the_kit_dialog_and_keeps_the_command_pending() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| super::ResidentPropEditorPane::new(window, cx));
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        cx.update_window(handle.into(), |_, window, cx| {
            let pane = stored.borrow().as_ref().unwrap().clone();
            pane.update(cx, |pane, cx| {
                pane.open_delete(
                    json!({"op":"stage.props.delete","objectID":"o1"}),
                    window,
                    cx,
                );
                assert!(pane.confirming_delete.is_some());
                assert!(
                    !pane
                        .take_commands()
                        .iter()
                        .any(|command| command["op"] == "stage.props.delete"),
                    "opening the dialog must not emit the delete command"
                );
            });
            assert!(
                window.has_active_dialog(cx),
                "the confirmation is a real kit dialog, not an inline block"
            );
            window.close_dialog(cx);
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }

    /// The panel draws in a real GPUI window for each mutually exclusive
    /// selected-object branch, so a branch that cannot render shows up here.
    #[test]
    fn panel_draws_every_selected_object_branch_in_a_real_window() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| {
                let mut pane = super::ResidentPropEditorPane::new(window, cx);
                let base = json!({
                    "isSaving": false,
                    "placedOnly": false,
                    "canUndo": true,
                    "rowCount": 1,
                    "remainingCount": 2,
                    "notice": "已更新",
                    "wallFaces": 2,
                    "wallPlaceableCells": 7,
                    "holdPoints": [{"id":"hand","name":"右手"},{"id":"back","name":"背后"},{"id":"waist","name":"腰间"}],
                    "legend": [{"red":0.1,"green":0.8,"blue":0.9,"label":"可放置"}],
                    "sections": [
                        {"group":"wish","title":"许愿中","isFolded":false,"rows":[
                            {"id":"r1","objectID":"o1","name":"长剑","state":"awaitingClaim","statusText":"可以领取","jobID":"j1","actions":["claim","retry"]}
                        ]},
                        {"group":"ended","title":"已结束","isFolded":true,"rows":[]}
                    ],
                    "selected": {
                        "objectID":"o1","name":"长剑","held":false,"enabled":true,
                        "longestEdge":1.4,"holdPoint":"hand",
                        "sizeDescription":"长 1.40 × 高 0.20 × 深 0.05 m（等比缩放；0.02–3.00 m）",
                        "sizeProvenance":"手动改过尺寸"
                    }
                });
                pane.update_snapshot(base.clone(), window, cx);
                pane
            });
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        let held = std::rc::Rc::new(std::cell::RefCell::new(json!({})));
        for state in ["loose", "held", "device", "none"] {
            let held_slot = held.clone();
            cx.update_window(handle.into(), |_, window, cx| {
                let pane = stored.borrow().as_ref().unwrap().clone();
                pane.update(cx, |pane, cx| {
                    let mut snapshot = pane.snapshot.clone();
                    match state {
                        "held" => {
                            snapshot["selected"]["held"] = json!(true);
                            snapshot["selected"]["holdUnavailableReason"] = json!(null);
                        }
                        // A built-in device: no longest edge (nothing to resize),
                        // no hold point, and no delete entry anywhere.
                        "device" => {
                            snapshot["selected"] = json!({
                                "objectID": "prop.jukebox",
                                "name": "音乐播放器",
                                "held": false,
                                "enabled": true,
                                "deviceTemplateID": "prop.jukebox",
                                "holdPoint": "hand"
                            });
                        }
                        "none" => {
                            snapshot["selected"] = json!(null);
                            snapshot["rowCount"] = json!(0);
                        }
                        _ => {
                            snapshot["selected"]["held"] = json!(false);
                            snapshot["selected"]["holdUnavailableReason"] =
                                json!("这个人形没有右手骨骼");
                        }
                    }
                    *held_slot.borrow_mut() = snapshot.clone();
                    pane.update_snapshot(snapshot, window, cx);
                });
                window.refresh();
                window.draw(cx).clear(cx);
            })
            .unwrap();
        }
        // The picker moves between the two scopes and the projection follows it.
        cx.update_window(handle.into(), |_, window, cx| {
            let pane = stored.borrow().as_ref().unwrap().clone();
            pane.update(cx, |pane, cx| {
                assert_eq!(
                    ownership_scope_index(pane.snapshot["placedOnly"].as_bool() == Some(true)),
                    0
                );
                let mut placed = held.borrow().clone();
                placed["placedOnly"] = json!(true);
                pane.update_snapshot(placed, window, cx);
                assert_eq!(
                    ownership_scope_index(pane.snapshot["placedOnly"].as_bool() == Some(true)),
                    1
                );
                assert!(pane.draft_object.is_none());
                let _ = pane.take_commands();
            });
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }
}

impl Render for ResidentPropEditorPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let placed_only = self.snapshot["placedOnly"].as_bool() == Some(true);
        let scope = ownership_scope(placed_only);
        let saving = self.snapshot["isSaving"].as_bool() == Some(true);
        let mut content = v_flex().w_full().gap(px(m::SECTION_GAP));
        content = content.child(
            TabBar::new("props-filter")
                .segmented()
                .small()
                .w_full()
                .selected_index(ownership_scope_index(placed_only))
                .children([ownership_scope(false), ownership_scope(true)].map(|scope| {
                    // The scope picker is a control: icon on the face, words in
                    // the accessibility label and the tooltip.
                    Tab::new()
                        .icon(if scope.title == "房间里" {
                            AssetIcon::Map
                        } else {
                            AssetIcon::Folder
                        })
                        .aria_label(scope.title)
                        .flex_1()
                        .min_w(px(0.))
                        .tooltip(move |window, cx| {
                            gpui_kit::component::tooltip::Tooltip::new(scope.title).build(window, cx)
                        })
                }))
                .on_click(cx.listener(|this, index: &usize, _, cx| {
                    this.commands
                        .push(json!({"op":"stage.props.filter","placedOnly":*index==1}));
                    cx.notify();
                })),
        );
        let sections = self.snapshot["sections"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        // Rows the projection withheld (`inventory_ui.rs`'s row budget). The
        // number is the host's own statement, so it stays; what changed is that
        // it is now the face of a control, not a sentence inside the scroll.
        let remaining = self.snapshot["remainingCount"]
            .as_u64()
            .filter(|count| *count > 0);
        if self.snapshot["rowCount"].as_u64() == Some(0) {
            let message = self.snapshot["emptyMessage"]
                .as_str()
                .unwrap_or(scope.empty);
            content = content.child(empty_list(message));
        } else {
            for section in &sections {
                let group = section["group"].as_str().unwrap_or("").to_owned();
                let folded = section["isFolded"].as_bool() == Some(true);
                let title = section["title"].as_str().unwrap_or("").to_owned();
                let mut block = v_flex()
                    .w_full()
                    .gap(px(m::SECTION_ROW_GAP))
                    .child(self.section_heading(&group, title, folded, saving, cx));
                for row in section["rows"].as_array().into_iter().flatten() {
                    block = block.child(self.ownership_row(row, cx));
                }
                content = content.child(block);
            }
        }
        let selected = self.snapshot["selected"].clone();
        let has_selection = !selected.is_null();
        let device_selected = has_selection && is_device_selection(&selected);
        let controls = if device_selected {
            SelectedControls::Device
        } else {
            selected_controls(has_selection, selected["held"].as_bool() == Some(true))
        };
        match controls {
            SelectedControls::None => {}
            SelectedControls::Held => {
                content = content.child(divider());
                let points = self.snapshot["holdPoints"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let slot_title =
                    hold_point_name(&points, &selected["holdPoint"]).to_owned();
                content = content.child(
                    h_flex()
                        .w_full()
                        .items_center()
                        .gap(px(m::CONTROL_GAP))
                        .child(
                            div()
                                .text_color(rgba(s::TEXT_MUTED))
                                .child(format!("{slot_title}展示微调")),
                        )
                        .child(div().flex_1())
                        .child(self.slot_picker(&points, &selected, saving, cx)),
                );
                let mut nudges = h_flex().gap(px(m::NUDGE_GAP));
                for (label, y, z) in [
                    ("向前", 0., -m::NUDGE_METERS),
                    ("向后", 0., m::NUDGE_METERS),
                    ("向上", m::NUDGE_METERS, 0.),
                    ("向下", -m::NUDGE_METERS, 0.),
                ] {
                    nudges = nudges.child(self.control(
                        format!("prop-nudge-{label}"),
                        label,
                        match label {
                            "向前" => AssetIcon::ArrowRight,
                            "向后" => AssetIcon::ArrowLeft,
                            "向上" => AssetIcon::ArrowUp,
                            _ => AssetIcon::ArrowDown,
                        },
                        json!({"op":"stage.props.nudge","y":y,"z":z}),
                        false,
                        cx,
                    ));
                }
                let rotate = h_flex()
                    .w_full()
                    .gap(px(m::CONTROL_GAP))
                    .child(self.control(
                        "prop-left",
                        &format!("左转 {}°", m::ROTATE_DEGREES),
                        AssetIcon::Undo,
                        json!({"op":"stage.props.rotate","direction":-1}),
                        false,
                        cx,
                    ))
                    .child(self.control(
                        "prop-right",
                        &format!("右转 {}°", m::ROTATE_DEGREES),
                        AssetIcon::RotateCw,
                        json!({"op":"stage.props.rotate","direction":1}),
                        false,
                        cx,
                    ))
                    .child(div().flex_1())
                    .child(self.control(
                        "prop-return",
                        "放回",
                        AssetIcon::Undo2,
                        json!({"op":"stage.props.return"}),
                        false,
                        cx,
                    ));
                content = content.child(nudges).child(rotate);
            }
            SelectedControls::Loose => {
                content = content.child(divider());
                let points = self.snapshot["holdPoints"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                let hold_disabled = selected["holdUnavailableReason"]
                    .as_str()
                    .is_some_and(|s| !s.is_empty());
                content = content.child(
                    h_flex()
                        .w_full()
                        .items_center()
                        .gap(px(m::CONTROL_GAP))
                        .child(self.control(
                            "prop-hold",
                            "拿着看",
                            AssetIcon::Eye,
                            json!({"op":"stage.props.hold"}),
                            hold_disabled,
                            cx,
                        ))
                        .child(self.control(
                            "prop-withdraw",
                            "收回",
                            AssetIcon::Inbox,
                            json!({"op":"stage.props.withdraw"}),
                            selected["enabled"].as_bool() != Some(true),
                            cx,
                        ))
                        .child(div().flex_1())
                        .child(self.slot_picker(&points, &selected, saving, cx)),
                );
                if let Some(reason) = selected["holdUnavailableReason"].as_str() {
                    content = content.child(
                        div()
                            .text_size(px(m::REASON_SIZE))
                            .text_color(rgba(s::TEXT_MUTED))
                            .child(reason.to_owned()),
                    );
                }
                content = content.child(
                    div()
                        .text_size(px(m::HINT_SIZE))
                        .text_color(rgba(s::TEXT_MUTED))
                        .child("移动指针选位置，左键放下，右键转 45°，Esc 放回。"),
                );
            }
            SelectedControls::Device => {
                // 基础设备 is placed (or moved) through the one op the world
                // authority takes for a device — the same
                // `ui.device.place`/`world.device.place` path the world's own
                // device placement uses (`UnityDevicePlacementBridge.place`,
                // `world_device.rs::can_place`). 收回 / 挂点 / 尺寸 would each be
                // answered `world_prop_basic_object`, so they are not drawn.
                content = content.child(divider());
                let placed = selected["enabled"].as_bool() == Some(true);
                content = content.child(
                    h_flex()
                        .w_full()
                        .items_center()
                        .gap(px(m::CONTROL_GAP))
                        .child(self.control(
                            "prop-device-place",
                            if placed { "重新摆放" } else { "摆放" },
                            // The bundled glyph the row's own `place` action
                            // already uses; the old device strip's `Box` is not
                            // in the icon bundle (`icon_gates.rs`), so it painted
                            // an empty square.
                            AssetIcon::ArrowDown,
                            // The placement entry is the component's one
                            // placement op; the adapter routes it to
                            // `ui.device.place` for a device and to
                            // `ui.inventory.place` for a generated prop.
                            json!({"op":"stage.props.hold"}),
                            false,
                            cx,
                        ))
                        .child(div().flex_1()),
                );
                content = content.child(
                    div()
                        .text_size(px(m::HINT_SIZE))
                        .text_color(rgba(s::TEXT_MUTED))
                        .child("移动指针选位置，左键放下，右键转 45°，Esc 放回。"),
                );
            }
        }
        if has_selection {
            if let Some(entry) = self.delete_entry(delete_entry_visible(device_selected), cx) {
                content = content.child(entry);
            }
        }
        // The size block is a generated-asset operation (`world.prop.command`
        // 「resize」): a built-in device has no generated prop to resize, and
        // the projection never gives it a longest edge.
        if has_selection
            && !device_selected
            && size_controls_visible(
                has_selection,
                selected["held"].as_bool() == Some(true),
                selected["longestEdge"].as_f64().is_some(),
            )
        {
            content = content.child(self.size_control(&selected, cx));
        }
        let wall_faces = self.snapshot["wallFaces"].as_u64().unwrap_or(0);
        let mut legend = h_flex().w_full().gap(px(m::LEGEND_GAP));
        for item in self.snapshot["legend"].as_array().into_iter().flatten() {
            if !legend_entry_visible(item["state"].as_str(), wall_faces) {
                continue;
            }
            if let (Some(r), Some(g), Some(b), Some(label)) = (
                item["red"].as_f64(),
                item["green"].as_f64(),
                item["blue"].as_f64(),
                item["label"].as_str(),
            ) {
                legend = legend.child(
                    h_flex()
                        .items_center()
                        .gap(px(m::LEGEND_ENTRY_GAP))
                        .child(
                            div()
                                .w(px(m::LEGEND_SWATCH))
                                .h(px(m::LEGEND_SWATCH))
                                .rounded(px(m::LEGEND_SWATCH_RADIUS))
                                .bg(Rgba {
                                    r: r as f32,
                                    g: g as f32,
                                    b: b as f32,
                                    a: 1.,
                                }),
                        )
                        .child(
                            div()
                                .text_size(px(m::LEGEND_SIZE))
                                .text_color(rgba(s::TEXT_MUTED))
                                .child(label.to_owned()),
                        ),
                );
            }
        }
        legend = legend.child(div().flex_1());
        content = content.child(legend);
        if let Some(notice) = self.snapshot["notice"].as_str().filter(|s| !s.is_empty()) {
            content = content.child(ui::muted(notice).text_size(px(m::HINT_SIZE)));
        }
        let wall_text = self.snapshot["wallPlacementText"]
            .as_str()
            .map(str::to_owned)
            .or_else(|| {
                Some(wall_placement_readout(
                    self.snapshot["wallFaces"].as_u64().unwrap_or(0),
                    self.snapshot["wallPlaceableCells"].as_u64().unwrap_or(0),
                ))
            });
        if let Some(wall) = wall_text {
            content = content.child(
                div()
                    .id("resident.prop-editor.wall-placement")
                    .text_size(px(m::DESCRIPTION_SIZE))
                    .text_color(rgba(s::TEXT_MUTED))
                    .child(wall),
            );
        }
        content = content.child(
            h_flex()
                .w_full()
                .child(self.control(
                    "props-undo",
                    "撤销上次",
                    AssetIcon::Undo2,
                    json!({"op":"stage.props.undo"}),
                    self.snapshot["canUndo"].as_bool() != Some(true),
                    cx,
                ))
                .child(div().flex_1()),
        );
        // One panel, one content scroll: the title row never scrolls.
        //
        // No `.h_full()`: the panel is content-sized and the shell pins its
        // extent to the bottom-right corner, exactly like the transport bar
        // (`StageWindowController.swift:1521-1526` pins
        // `propEditorPanel.trailing == transportControls.trailing` and
        // `bottom == transportControls.top - 12`). Stretching to the container's
        // full height is what used to push the panel's content to the window's
        // top-left. `max_h` + the inner scroll still bound a long list.
        //
        // The cap is also the *live viewport's* band: the shell clips this pane
        // to `panel_extent(viewport)`, so a pane taller than that loses its
        // bottom — which is where the 「还有 N 件」 footer sits. 390 pt inside the
        // 374 pt box of a 720×482 window was exactly that case (measured), which
        // is why the line could not be clicked even when scrolled to.
        let viewport_band = (f32::from(window.viewport_size().height)
            - m::PANEL_VIEWPORT_BOTTOM_BAND)
            .max(0.);
        let panel_max_height = if self.list_expanded {
            m::PANEL_MAX_HEIGHT_EXPANDED
        } else {
            m::PANEL_MAX_HEIGHT
        }
        .min(viewport_band);
        let mut panel = v_flex()
            // The original's `propEditorPanel.widthAnchor.constraint(
            // equalToConstant: 340)` is a *width*, not a ceiling. With `max_w`
            // alone the pane shrink-to-fit itself inside the shell's content
            // wrapper (measured: 190 pt wide), which is the reported
            // 「窗口很小」; the shell's container still clips anything wider than
            // the extent it measured.
            .w(px(m::PANEL_WIDTH))
            // Collapsed is the original's `.frame(maxHeight: 390)`. 「还有 N 件」
            // lifts the panel to the ceiling the shell allows this pane, which is
            // the extent the window's own size produced — never a number the pane
            // invents for a window it cannot see.
            .max_h(px(panel_max_height))
            .gap(px(m::GROUP_GAP))
            .p(px(m::PANEL_PADDING))
            .rounded(px(m::PANEL_RADIUS))
            .bg(rgba(s::CARD_BG))
            .border_1()
            .border_color(rgba(s::BORDER))
            .text_color(rgba(s::TEXT))
            .text_size(px(m::BODY_SIZE))
            .font_family(doc::FONT_FAMILY)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(m::HEADING_GAP))
                    .child(
                        Icon::new(AssetIcon::Layers)
                            .size(px(m::TITLE_SIZE))
                            .text_color(rgba(s::TEXT)),
                    )
                    .child(
                        div()
                            .id("props-panel-title")
                            .text_size(px(m::TITLE_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            // The title is the content on screen (我的物件 /
                            // 房间里), never a fixed word that the picker below
                            // would contradict.
                            .child(panel_title(placed_only)),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("props-close")
                            .custom(scene_variant(
                                cx,
                                0x00000000,
                                0xffffff14,
                                s::TEXT,
                            ))
                            .w(px(m::CLOSE_BUTTON))
                            .h(px(m::CLOSE_BUTTON))
                            .rounded(px(m::CLOSE_BUTTON / 2.))
                            .text_color(rgba(s::TEXT))
                            .icon(AssetIcon::X)
                            .tooltip("收起摆放")
                            .accessibility_label("收起摆放")
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.commands.push(json!({"op":"stage.props.close"}));
                                cx.notify();
                            })),
                    ),
            )
            .child(
                div()
                    .id("props-panel-scroll")
                    .w_full()
                    .flex_1()
                    .min_h(px(0.))
                    .overflow_y_scroll()
                    .child(content),
            );
        // 「还有 N 件」 is a control in the panel's own footer, **outside** the
        // scroll. It used to be a plain `div` sitting after the last row inside
        // the scroll content: on a small window it was below the fold and could
        // not be reached at all, and even in view it had no click handler. A
        // fixed footer can never be scrolled away — the same argument that keeps
        // the title row out of the scroll.
        if let Some(count) = remaining {
            panel = panel.child(self.remaining_toggle(count, cx));
        }
        // The shell's content box (`shell_ui.rs::panel_content`) is 100 % of the
        // panel box, and a 340 pt card inside a 590 pt box must still take its
        // trailing edge from the bottom-right corner — the original's
        // `propEditorPanel.trailing == transportControls.trailing`
        // (`StageWindowController.swift:1521-1523`). One row wrapper ends the card
        // at that corner whether the box hugs its child or spans the extent
        // (measured 2026-10-09: a box pinned to 100 % left the card at x=108 in a
        // 1280 pt-wide window instead of x=358, 250 pt off the corner).
        h_flex()
            .w_full()
            .justify_end()
            .child(panel)
            .into_any_element()
    }
}
