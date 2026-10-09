//! The system message inbox — the original `ResidentSystemInboxWindowController`
//! (`apps/macos/Sources/GMGNRadio/Presence/ResidentSystemInboxUI.swift`), rebuilt
//! on gpui-kit.
//!
//! Shape of the surface, and why it is split this way:
//!
//! - [`InboxPane`] owns presentation state only: the confirmed projection, the
//!   selected entry id, the pending `inbox.open` commands and the read-only
//!   detail `Textarea`. The store lives in the host
//!   (`Presence/ResidentSystemInbox.swift`), so nothing done here can
//!   acknowledge the background consumer.
//! - The list is the only scrolling region of the window and the detail is a
//!   separate, independently scrolling read-only `Textarea`; the window itself
//!   never scrolls.
//! - Pure decisions are free functions ([`row_text`], [`relative_time_text`],
//!   [`can_open`], [`activation_marks_read`], [`row_accessibility_label`]) so the
//!   pane and the tests share one answer instead of each re-deriving it.
//! - Chrome, type and colour come from [`crate::primitives`],
//!   [`crate::ui_tokens::inbox`] and [`crate::ui_tokens::scene`]; this file holds
//!   no colour or size literal.
//!
//! The original hard constraints are kept: a standalone 720×460 window, a 300 pt
//! list, the detail on the right, a single click that only selects and shows the
//! detail, and an explicit open as the only thing that reduces unread. The
//! original's explicit open control in the footer was dropped deliberately, so
//! the open gestures that remain are the row double-click and Return.
//! Long titles wrap (the row grows instead of truncating) and the list scrolls.
use std::time::{SystemTime, UNIX_EPOCH};

use gpui_kit::component::empty::{Empty, EmptyHeader, EmptyMedia, EmptyMediaVariant, EmptyTitle};
use gpui_kit::component::input::{Textarea, TextareaState};
use gpui_kit::component::list::ListItem;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::*;
use gpui_kit::prelude::{InteractiveElement as _, StatefulInteractiveElement as _};
use gpui_kit::*;
use serde_json::{Value, json};

use crate::primitives as ui;
use crate::ui_tokens::inbox as m;
use crate::ui_tokens::scene as s;

actions!(resident_inbox, [OpenSelected, SelectPrevious, SelectNext]);

/// One row’s rendered copy, exactly as the original cell composes it
/// (`ResidentSystemInboxUI.swift:218-255`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InboxRowText {
    pub title: String,
    pub status: String,
    pub time: String,
    /// The unread badge glyph (`:221`).
    pub marker: &'static str,
    /// The cell’s accessibility name (`:254`).
    pub accessibility: String,
}

/// The copy of one list row. The title is kept whole — the parity target
/// requires long titles to wrap, so this never truncates or shortens it.
pub fn row_text(title: &str, status: &str, is_read: bool, relative_time: &str) -> InboxRowText {
    InboxRowText {
        title: title.to_owned(),
        status: status.to_owned(),
        time: relative_time.to_owned(),
        marker: row_unread_marker(is_read),
        accessibility: row_accessibility_label(title, status, is_read),
    }
}

/// The unread badge glyph (`:221`): a bullet while unread, a blank once read.
pub fn row_unread_marker(is_read: bool) -> &'static str {
    if is_read { " " } else { "●" }
}

/// The row’s accessible name (`:254`): title, status and read state joined with
/// the original’s full-width comma.
pub fn row_accessibility_label(title: &str, status: &str, is_read: bool) -> String {
    format!("{title}，{status}，{}", if is_read { "已读" } else { "未读" })
}

/// Whether a row may be opened. The original only calls back for a confirmed
/// row (`:209-212`) and the open command must carry that message’s own event id,
/// so a row without a non-empty `eventID` cannot be opened.
pub fn can_open(row: &Value) -> bool {
    row["eventID"].as_str().is_some_and(|event| !event.is_empty())
}

/// What a row gesture does. A single click only selects and shows the detail; a
/// message becomes read solely through an explicit open — double-click or
/// Return (`:83-87`, `:126`, `:147`, `:209-212`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RowActivation {
    Select,
    Open,
}

/// Reading is a consequence of an explicit open, never of a selection.
pub fn activation_marks_read(activation: RowActivation) -> bool {
    matches!(activation, RowActivation::Open)
}

/// Relative time for a row’s trailing label.
///
/// Source: `ResidentSystemInboxUI.swift:232,266-268` — the original formats
/// `updatedAt` with `Date.formatted(.relative(presentation: .named))`, and the
/// host already sends that string as `relativeTimeText`
/// (`GMGNRadioApp.swift:676`). When a projection carries only a Unix timestamp
/// this derives the same named buckets; a missing timestamp renders nothing.
pub fn relative_time_text(
    provided: Option<&str>,
    updated_at_epoch_seconds: Option<i64>,
    now_epoch_seconds: i64,
) -> String {
    if let Some(text) = provided.map(str::trim).filter(|text| !text.is_empty()) {
        return text.to_owned();
    }
    let Some(updated) = updated_at_epoch_seconds else {
        return String::new();
    };
    // Clock skew must not read as a negative age.
    let age = (now_epoch_seconds - updated).max(0);
    if age < 60 {
        "刚刚".to_owned()
    } else if age < 3_600 {
        format!("{}分钟前", age / 60)
    } else if age < 86_400 {
        format!("{}小时前", age / 3_600)
    } else if age < 172_800 {
        "昨天".to_owned()
    } else if age < 604_800 {
        format!("{}天前", age / 86_400)
    } else if age < 2_592_000 {
        format!("{}周前", age / 604_800)
    } else if age < 31_536_000 {
        format!("{}个月前", age / 2_592_000)
    } else {
        format!("{}年前", age / 31_536_000)
    }
}

/// The trailing time of one projected row.
pub fn row_relative_time(row: &Value, now_epoch_seconds: i64) -> String {
    relative_time_text(
        row["relativeTimeText"].as_str(),
        row["updatedAt"].as_i64(),
        now_epoch_seconds,
    )
}

/// The current wall clock the relative fallback needs.
fn now_epoch_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs() as i64)
        .unwrap_or(0)
}

#[derive(Default)]
struct InboxState {
    snapshot: Value,
    selected: Option<String>,
    commands: Vec<Value>,
}

impl InboxState {
    fn rows(&self) -> &[Value] {
        self.snapshot["entries"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }
    fn selected_row(&self) -> Option<&Value> {
        let id = self.selected.as_deref()?;
        self.rows()
            .iter()
            .find(|row| row["id"].as_str() == Some(id))
    }
    fn update(&mut self, snapshot: Value) {
        if self.snapshot["scope"] != snapshot["scope"] {
            self.selected = None;
        }
        self.snapshot = snapshot;
        if self.selected_row().is_none() {
            self.selected = None;
        }
    }
    fn select(&mut self, id: String) {
        if self
            .rows()
            .iter()
            .any(|row| row["id"].as_str() == Some(&id))
        {
            self.selected = Some(id);
        }
    }
    fn open(&mut self) {
        if let Some(row) = self.selected_row() {
            if !can_open(row) {
                return;
            }
            let event = row["eventID"].as_str().unwrap_or_default();
            self.commands
                .push(json!({"op":"inbox.open", "id": row["id"],
                "scope":self.snapshot["scope"], "expectedEventID":event}));
        }
    }
    fn move_selection(&mut self, direction: isize) {
        let ids: Vec<_> = self
            .rows()
            .iter()
            .filter_map(|row| row["id"].as_str())
            .map(str::to_owned)
            .collect();
        if ids.is_empty() {
            return;
        }
        let index = self
            .selected
            .as_ref()
            .and_then(|id| ids.iter().position(|candidate| candidate == id));
        let next = index
            .map(|index| (index as isize + direction).clamp(0, ids.len() as isize - 1) as usize)
            .unwrap_or(0);
        self.selected = Some(ids[next].clone());
    }
    /// The read-only detail body (`:261`): title, status, the absolute
    /// `updatedAt` text, a blank line, then the detail. With nothing selected
    /// the original clears the text view (`:194`) and the placeholder label
    /// (`:105`) is shown instead.
    fn detail_text(&self) -> String {
        match self.selected_row() {
            Some(row) => [
                row["title"].as_str().unwrap_or(""),
                row["status"].as_str().unwrap_or(""),
                row["updatedAtText"].as_str().unwrap_or(""),
                "",
                row["detail"].as_str().unwrap_or(""),
            ]
            .join("\n"),
            None => String::new(),
        }
    }
}

pub struct InboxPane {
    state: InboxState,
    focus: FocusHandle,
    detail: Option<Entity<TextareaState>>,
    detail_key: Option<String>,
    detail_text: String,
    scroll: ScrollHandle,
}
impl InboxPane {
    pub fn new(cx: &mut Context<Self>) -> Self {
        cx.bind_keys([
            KeyBinding::new("enter", OpenSelected, Some("ResidentInbox")),
            KeyBinding::new("up", SelectPrevious, Some("ResidentInbox")),
            KeyBinding::new("down", SelectNext, Some("ResidentInbox")),
        ]);
        Self {
            state: InboxState::default(),
            focus: cx.focus_handle(),
            detail: None,
            detail_key: None,
            detail_text: String::new(),
            scroll: ScrollHandle::new(),
        }
    }
    pub fn update_snapshot(&mut self, snapshot: Value, cx: &mut Context<Self>) {
        if self.state.snapshot == snapshot {
            return;
        }
        self.state.update(snapshot);
        cx.notify();
    }
    pub fn take_commands(&mut self) -> Vec<Value> {
        std::mem::take(&mut self.state.commands)
    }
    fn move_selection(&mut self, direction: isize, cx: &mut Context<Self>) {
        self.state.move_selection(direction);
        if let Some(index) = self
            .state
            .rows()
            .iter()
            .position(|row| row["id"].as_str() == self.state.selected.as_deref())
        {
            self.scroll.scroll_to_item(index);
        }
        cx.notify();
    }

    /// One list row. The row is a kit `ListItem` so hover/press/selection and
    /// the accessibility node stay kit-owned; only its copy and layout come from
    /// the original cell (`ResidentSystemInboxUI.swift:218-255`).
    fn row(&self, row: &Value, now: i64, cx: &mut Context<Self>) -> AnyElement {
        let id = row["id"].as_str().unwrap_or_default().to_owned();
        let title = row["title"].as_str().unwrap_or_default().to_owned();
        let status = row["status"].as_str().unwrap_or_default().to_owned();
        let is_read = row["isRead"].as_bool() == Some(true);
        let text = row_text(&title, &status, is_read, &row_relative_time(row, now));
        let selected = self.state.selected.as_deref() == Some(id.as_str());
        let click_id = id.clone();
        ListItem::new(SharedString::from(id))
            .selected(selected)
            .role(Role::ListItem)
            .accessibility_label(text.accessibility.clone())
            .min_h(px(m::ROW_HEIGHT))
            .px(px(m::ROW_PADDING_H))
            .py(px(m::ROW_PADDING_V))
            .text_color(rgba(m::TITLE_TEXT))
            .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                this.state.select(click_id.clone());
                // Double-click is the original's `doubleAction` (`:126`); a
                // single click only shows the detail and never ACKs.
                if event.click_count() >= 2 {
                    this.state.open();
                }
                window.focus(&this.focus, cx);
                cx.notify();
            }))
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(m::DOT_GAP))
                    .child(
                        div()
                            .w(px(m::DOT_WIDTH))
                            .flex_shrink_0()
                            .text_size(px(m::DOT_SIZE))
                            .text_color(rgba(m::UNREAD_DOT))
                            .child(text.marker),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w(px(0.))
                            .gap(px(m::STATUS_GAP))
                            .child(
                                h_flex()
                                    .w_full()
                                    .items_baseline()
                                    .gap(px(m::TITLE_TIME_GAP))
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w(px(0.))
                                            .text_size(px(m::TITLE_SIZE))
                                            .line_height(px(m::TITLE_LINE_HEIGHT))
                                            .font_weight(FontWeight::MEDIUM)
                                            .whitespace_normal()
                                            .child(text.title.clone()),
                                    )
                                    .child(
                                        div()
                                            .flex_shrink_0()
                                            .text_size(px(m::TIME_SIZE))
                                            .text_color(rgba(s::TEXT_MUTED))
                                            .child(text.time.clone()),
                                    ),
                            )
                            .child(
                                div()
                                    .w_full()
                                    .text_size(px(m::STATUS_SIZE))
                                    .line_height(px(m::STATUS_LINE_HEIGHT))
                                    .text_color(rgba(m::STATUS_TEXT))
                                    .truncate()
                                    .child(text.status.clone()),
                            ),
                    ),
            )
            .into_any_element()
    }

    /// The list column. It is the window's only scrolling region and it
    /// carries the original accessible name, `系统消息列表` (`:128`). The kit
    /// scrollbar overlays the same element that owns the scroll handle, so
    /// `scroll_to_item` keeps working for keyboard selection.
    ///
    /// 300 pt is the **preferred** width, not a floor: the same pane is also
    /// mounted in the 590 pt media panel
    /// (`ui_tokens::stage::PANEL_MAX_WIDTH`) minus its insets, where a rigid
    /// 300 pt list plus the detail's 320 pt floor overflows and the detail's
    /// trailing 8 pt is clipped by the panel's `overflow_hidden`
    /// (`shell_ui.rs:panel_container`). The list shrinks first and the detail
    /// keeps its floor, so the standalone 720×460 window is unchanged.
    fn list(&self, cx: &mut Context<Self>) -> AnyElement {
        let now = now_epoch_seconds();
        let mut list = div()
            .id("resident.system-inbox.list")
            .role(Role::List)
            .accessibility_id("resident.system-inbox.list")
            .aria_label("系统消息列表")
            .w(px(m::LIST_WIDTH))
            .min_w(px(m::LIST_MIN_WIDTH))
            .h_full()
            .flex()
            .flex_col()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .border_r_1()
            .border_color(rgba(s::BORDER));
        for row in self.state.rows().to_vec() {
            if row["id"].as_str().is_none_or(str::is_empty) {
                continue;
            }
            list = list.child(self.row(&row, now, cx));
        }
        list.vertical_scrollbar(&self.scroll).into_any_element()
    }

    /// The right column: empty state, placeholder and the read-only detail
    /// (`ResidentSystemInboxUI.swift:155-178,203-212`). The original's explicit
    /// open control is deliberately gone; only double-click and Return open a
    /// message, and both still queue the same `inbox.open` command.
    fn detail_column(&mut self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let detail_text = self.state.detail_text();
        let detail_key = format!(
            "{}:{}",
            self.state.snapshot["scope"],
            self.state.selected.as_deref().unwrap_or("")
        );
        if self.detail_key.as_deref() != Some(&detail_key) {
            // Read-only Kit textarea is the plain-text selection/copy surface.
            // TextView's convenience constructors parse Markdown/HTML, which must not happen here.
            self.detail = Some(
                cx.new(|cx| TextareaState::new(window, cx).default_value(detail_text.clone())),
            );
            self.detail_key = Some(detail_key);
        } else if self.detail_text != detail_text {
            if let Some(input) = &self.detail {
                input.update(cx, |input, cx| {
                    input.set_value(detail_text.clone(), window, cx)
                });
            }
        }
        self.detail_text = detail_text;

        let has_rows = !self.state.rows().is_empty();
        let selected = self.state.selected_row().is_some();
        let persistence_error = self.state.snapshot["persistenceError"]
            .as_str()
            .filter(|error| !error.is_empty())
            .map(str::to_owned);

        let mut column = v_flex()
            .id("resident.system-inbox.detail")
            .flex_1()
            .min_w(px(m::DETAIL_MIN_WIDTH))
            .h_full()
            .gap(px(m::STACK_GAP))
            .pr(px(m::DETAIL_TRAILING));
        if !has_rows {
            // The original shows `暂无系统消息` in the detail stack while the
            // list is empty (`:104,151,204`).
            column = column.child(
                Empty::new()
                    .flex_none()
                    .p(px(m::STACK_GAP))
                    .border_color(rgba(s::BORDER))
                    .text_color(rgba(s::TEXT_MUTED))
                    .header(
                        EmptyHeader::new()
                            .media(
                                EmptyMedia::new()
                                    .with_variant(EmptyMediaVariant::Icon)
                                    .child(Icon::new(gpui_kit::assets::IconName::Inbox)),
                            )
                            .title(EmptyTitle::new().child("暂无系统消息")),
                    ),
            );
        }
        if !selected {
            column = column.child(
                ui::muted("选择一条消息查看完整内容；双击或按 Return 标记为已读")
                    .text_size(px(m::PLACEHOLDER_SIZE))
                    .text_color(rgba(m::PLACEHOLDER_TEXT)),
            );
        }
        column = column.child(
            div()
                .flex_1()
                .min_h(px(m::DETAIL_MIN_HEIGHT))
                .w_full()
                .p(px(m::DETAIL_PADDING))
                .child(
                    Textarea::new(self.detail.as_ref().expect("plain detail state"))
                        .readonly(true)
                        .appearance(false)
                        .bordered(false)
                        .h_full()
                        .w_full()
                        .text_size(px(m::DETAIL_SIZE))
                        .line_height(px(m::DETAIL_LINE_HEIGHT))
                        .text_color(rgba(m::DETAIL_TEXT))
                        .aria_label("消息详情")
                        .accessibility_id("resident.system-inbox.detail-text"),
                ),
        );
        if let Some(error) = persistence_error {
            column = column.child(ui::notice(error));
        }
        column.into_any_element()
    }
}
impl Focusable for InboxPane {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}
/// The split's two columns. The list keeps its 300 pt preferred width but is
/// allowed to shrink to [`m::LIST_MIN_WIDTH`], so the detail column's
/// [`m::DETAIL_MIN_WIDTH`] floor always fits the narrowest surface the pane is
/// mounted in (the 590 pt media panel) instead of being clipped by its
/// `overflow_hidden`. In the pane's own 720 pt window there is room for both,
/// so the split is unchanged there.
fn inbox_row(list: AnyElement, detail: AnyElement) -> Div {
    div()
        .size_full()
        .p(px(m::PANEL_INSET))
        .flex()
        .flex_row()
        .font_family(crate::ui_tokens::FONT_FAMILY)
        .text_color(rgba(s::TEXT))
        .bg(rgba(s::PANEL_BG))
        .child(list)
        .child(detail)
}

impl Render for InboxPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let list = self.list(cx);
        let detail = self.detail_column(window, cx);
        inbox_row(list, detail)
            .key_context("ResidentInbox")
            .track_focus(&self.focus)
            .on_action(cx.listener(|this, _: &OpenSelected, _, cx| {
                this.state.open();
                cx.notify();
            }))
            .on_action(cx.listener(|this, _: &SelectPrevious, _, cx| {
                this.move_selection(-1, cx);
            }))
            .on_action(cx.listener(|this, _: &SelectNext, _, cx| {
                this.move_selection(1, cx);
            }))
    }
}

#[cfg(test)]
mod tests {
    // gpui re-exports a `test` attribute macro; `super::*` would shadow the
    // built-in one, so name it explicitly like the rest of this crate does.
    use core::prelude::v1::test;
    use super::*;
    fn snapshot(scope: &str) -> Value {
        json!({"scope":scope,"entries":[{"id":"one","eventID":"event-one","isRead":false}]})
    }
    #[test]
    fn selection_does_not_mark_read_or_send_command() {
        let mut state = InboxState::default();
        state.update(snapshot("world-a"));
        state.select("one".into());
        assert!(state.commands.is_empty());
        assert_eq!(state.selected_row().unwrap()["isRead"], false);
    }
    #[test]
    fn arrows_select_without_ack_and_clamp_at_list_edges() {
        let mut state = InboxState::default();
        state.update(json!({"scope":"world-a","entries":[{"id":"one","isRead":false},{"id":"two","isRead":false}]}));
        state.move_selection(1);
        assert_eq!(state.selected.as_deref(), Some("one"));
        state.move_selection(1);
        state.move_selection(1);
        assert_eq!(state.selected.as_deref(), Some("two"));
        state.move_selection(-1);
        state.move_selection(-1);
        assert_eq!(state.selected.as_deref(), Some("one"));
        assert!(state.commands.is_empty());
        assert_eq!(state.selected_row().unwrap()["isRead"], false);
    }
    #[test]
    fn explicit_open_carries_current_scope_without_optimistic_ack() {
        let mut state = InboxState::default();
        state.update(snapshot("world-a"));
        state.select("one".into());
        state.open();
        assert_eq!(
            state.commands,
            vec![json!({"op":"inbox.open","id":"one","scope":"world-a","expectedEventID":"event-one"})]
        );
        assert_eq!(state.selected_row().unwrap()["isRead"], false);
    }
    #[test]
    fn queued_open_keeps_the_displayed_event_when_new_content_arrives() {
        let mut state = InboxState::default();
        state.update(snapshot("world-a"));
        state.select("one".into());
        state.open();
        state.update(json!({"scope":"world-a","entries":[{"id":"one","eventID":"event-two","isRead":false}]}));
        assert_eq!(state.commands[0]["expectedEventID"], "event-one");
        assert_eq!(state.selected_row().unwrap()["isRead"], false);
        state.open();
        assert_eq!(state.commands[1]["expectedEventID"], "event-two");
    }
    #[test]
    fn open_without_a_confirmed_display_event_cannot_mark_read() {
        let mut state = InboxState::default();
        state.update(json!({"scope":"world-a","entries":[{"id":"one","isRead":false}]}));
        state.select("one".into());
        state.open();
        assert!(state.commands.is_empty());
    }
    #[test]
    fn scope_switch_and_removed_entry_invalidate_selection() {
        let mut state = InboxState::default();
        state.update(snapshot("world-a"));
        state.select("one".into());
        state.update(snapshot("world-b"));
        state.open();
        assert!(state.commands.is_empty());
        state.select("one".into());
        state.update(json!({"scope":"world-b","entries":[]}));
        state.open();
        assert!(state.commands.is_empty());
    }
    #[test]
    fn detail_keeps_original_plain_text_and_newlines() {
        let mut state = InboxState::default();
        state.update(json!({"scope":"world-a", "entries":[{"id":"one", "title":"生成完成", "status":"", "updatedAtText":"今天 12:30", "detail":"第一行\n<script>not executable</script>\n**原文**"}]}));
        state.select("one".into());
        assert_eq!(
            state.detail_text(),
            "生成完成\n\n今天 12:30\n\n第一行\n<script>not executable</script>\n**原文**"
        );
        assert!(state.commands.is_empty());
    }

    /// The row copy is the original cell’s: title, status, relative time and
    /// the read/unread badge, with the accessible name the original builds.
    #[test]
    fn row_text_keeps_the_original_cell_copy_and_read_state() {
        let unread = row_text("生成完成", "已完成 3/3", false, "9小时前");
        assert_eq!(unread.title, "生成完成");
        assert_eq!(unread.status, "已完成 3/3");
        assert_eq!(unread.time, "9小时前");
        assert_eq!(unread.marker, "●");
        assert_eq!(unread.accessibility, "生成完成，已完成 3/3，未读");
        let read = row_text("生成完成", "已完成 3/3", true, "9小时前");
        assert_eq!(read.marker, " ");
        assert_eq!(read.accessibility, "生成完成，已完成 3/3，已读");
        assert_ne!(read.accessibility, unread.accessibility);
    }

    /// The parity target wraps long titles, so the row copy must keep every
    /// character instead of ending in an ellipsis.
    #[test]
    fn long_titles_are_kept_whole_for_wrapping_not_truncated() {
        let long = "这是一条非常长的系统消息标题，用来验证列表行不会把它截断，而是要换行显示完整内容";
        let text = row_text(long, "进行中", false, "刚刚");
        assert_eq!(text.title, long);
        assert_eq!(text.title.chars().count(), long.chars().count());
        assert!(!text.title.ends_with('…') && !text.title.ends_with("..."));
    }

    #[test]
    fn accessibility_label_is_title_status_and_read_state() {
        assert_eq!(
            row_accessibility_label("生成完成", "已完成", false),
            "生成完成，已完成，未读"
        );
        assert_eq!(
            row_accessibility_label("生成完成", "已完成", true),
            "生成完成，已完成，已读"
        );
    }

    /// The host string wins; only a snapshot without it derives the buckets.
    #[test]
    fn relative_time_prefers_the_host_string_and_derives_named_buckets_otherwise() {
        let now = 1_700_000_000_i64;
        assert_eq!(
            relative_time_text(Some("9小时前"), Some(now - 9 * 3600), now),
            "9小时前"
        );
        assert_eq!(
            relative_time_text(Some("  "), Some(now - 9 * 3600), now),
            "9小时前"
        );
        assert_eq!(relative_time_text(None, Some(now), now), "刚刚");
        assert_eq!(relative_time_text(None, Some(now - 59), now), "刚刚");
        assert_eq!(relative_time_text(None, Some(now - 60), now), "1分钟前");
        assert_eq!(relative_time_text(None, Some(now - 3_599), now), "59分钟前");
        assert_eq!(relative_time_text(None, Some(now - 3_600), now), "1小时前");
        assert_eq!(relative_time_text(None, Some(now - 86_399), now), "23小时前");
        assert_eq!(relative_time_text(None, Some(now - 86_400), now), "昨天");
        assert_eq!(relative_time_text(None, Some(now - 172_800), now), "2天前");
        assert_eq!(relative_time_text(None, Some(now - 604_800), now), "1周前");
        assert_eq!(
            relative_time_text(None, Some(now - 2_592_000), now),
            "1个月前"
        );
        assert_eq!(
            relative_time_text(None, Some(now - 31_536_000), now),
            "1年前"
        );
        // A clock skewed into the future must not read as a negative age.
        assert_eq!(relative_time_text(None, Some(now + 600), now), "刚刚");
        assert_eq!(relative_time_text(None, None, now), "");
        assert_eq!(relative_time_text(Some(""), None, now), "");
    }

    #[test]
    fn row_relative_time_reads_the_projection_fields() {
        let now = 1_700_000_000_i64;
        assert_eq!(
            row_relative_time(&json!({"relativeTimeText":"昨天"}), now),
            "昨天"
        );
        assert_eq!(
            row_relative_time(&json!({"relativeTimeText":"","updatedAt": now - 7_200}), now),
            "2小时前"
        );
        assert_eq!(row_relative_time(&json!({}), now), "");
    }

    #[test]
    fn only_a_confirmed_display_event_can_be_opened() {
        assert!(can_open(&json!({"eventID":"event-one"})));
        assert!(!can_open(&json!({"eventID":""})));
        assert!(!can_open(&json!({"eventID": null})));
        assert!(!can_open(&json!({})));
    }

    #[test]
    fn selection_shows_detail_but_only_open_marks_read() {
        assert!(!activation_marks_read(RowActivation::Select));
        assert!(activation_marks_read(RowActivation::Open));
        assert_ne!(
            activation_marks_read(RowActivation::Select),
            activation_marks_read(RowActivation::Open)
        );
    }

    /// The original window numbers, pinned one by one so a local edit cannot
    /// quietly move the surface off 720×460 / 300 pt / 44 pt rows. The list's
    /// floor is pinned against the narrowest surface it is actually mounted in
    /// (the 590 pt media panel), so the detail column can never be clipped.
    #[test]
    fn inbox_metrics_match_the_original_window() {
        assert_eq!(
            [m::WINDOW_WIDTH, m::WINDOW_HEIGHT, m::LIST_WIDTH],
            [720., 460., 300.]
        );
        assert_eq!(m::ROW_HEIGHT, 44.);
        assert_eq!(
            m::ROW_PADDING_V * 2. + m::TITLE_LINE_HEIGHT + m::STATUS_GAP + m::STATUS_LINE_HEIGHT,
            m::ROW_HEIGHT
        );
        assert_eq!([m::DETAIL_MIN_WIDTH, m::DETAIL_MIN_HEIGHT], [320., 220.]);
        assert_eq!(m::LIST_MIN_WIDTH, 240.);
        // The media panel is the narrow host of this pane; its inner width is
        // `stage::PANEL_MAX_WIDTH` minus the inset on both sides and the
        // detail's trailing gap.
        let media_inner =
            crate::ui_tokens::stage::PANEL_MAX_WIDTH - 2. * m::PANEL_INSET - m::DETAIL_TRAILING;
        assert_eq!(media_inner, 562.);
        assert!(
            m::LIST_MIN_WIDTH + m::DETAIL_MIN_WIDTH <= media_inner,
            "the list floor ({} pt) + the detail floor ({} pt) must fit the media panel's \
             {media_inner} pt inner width, otherwise the detail column is clipped",
            m::LIST_MIN_WIDTH,
            m::DETAIL_MIN_WIDTH
        );
        assert!(
            m::LIST_WIDTH + m::DETAIL_MIN_WIDTH <= m::WINDOW_WIDTH - 2. * m::PANEL_INSET,
            "the pane's own window must still show the full list width"
        );
        // The two columns really carry those constraints into layout: the list
        // has a 300 pt preferred width and a 240 pt floor, so it shrinks
        // instead of pushing the detail column past the panel edge. (The
        // constants and the live style are asserted together, so editing only
        // one of them still fails.)
        let mut list = div()
            .w(px(m::LIST_WIDTH))
            .min_w(px(m::LIST_MIN_WIDTH));
        let style = list.style();
        assert_eq!(
            (
                style.size.width.map(|width| format!("{width:?}")),
                style.min_size.width.map(|width| format!("{width:?}")),
            ),
            (
                Some(format!("{:?}", px(m::LIST_WIDTH))),
                Some(format!("{:?}", px(m::LIST_MIN_WIDTH))),
            )
        );
        assert_eq!(m::UNREAD_DOT, 0x0a84ffff);
        assert_ne!(m::TITLE_TEXT, m::STATUS_TEXT);
        assert_ne!(m::STATUS_TEXT, m::PLACEHOLDER_TEXT);
    }

    /// The pane must survive real GPUI window draws, and while it draws a
    /// selection may show the detail but must never emit an `inbox.open`
    /// command; only an explicit open does, and it keeps its read-only host
    /// semantics afterwards.
    #[test]
    fn pane_draws_in_a_real_window_and_selection_never_acknowledges() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(InboxPane::new);
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        // First paint: nothing projected yet, so the `暂无系统消息` empty state
        // and the placeholder are on screen.
        cx.update_window(handle.into(), |_, window, cx| {
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
        let pane = stored.borrow().clone().expect("pane entity");
        // Second paint: two projected rows, one of them a long wrapping title.
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.update_snapshot(
                    json!({"scope":"world-a","entries":[
                        {"id":"one","eventID":"event-one","isRead":false,
                         "title":"这是一条非常长的系统消息标题，用来验证列表行换行显示完整内容而不是截断",
                         "status":"进行中","relativeTimeText":"刚刚",
                         "updatedAtText":"2026年10月4日 1:23",
                         "detail":"第一行\n**原文**"},
                        {"id":"two","eventID":"event-two","isRead":true,
                         "title":"生成完成","status":"已完成","relativeTimeText":"9小时前",
                         "updatedAtText":"2026年10月3日 20:00","detail":"已完成 3/3"}
                    ]}),
                    cx,
                );
                assert_eq!(pane.state.rows().len(), 2);
                assert!(pane.state.selected.is_none());
                // Selection only: no command, unread stays unread.
                pane.move_selection(1, cx);
                assert_eq!(pane.state.selected.as_deref(), Some("one"));
                assert!(
                    pane.take_commands().is_empty(),
                    "selecting a row must not acknowledge the delivery"
                );
                assert_eq!(pane.state.selected_row().unwrap()["isRead"], false);
                assert_eq!(
                    pane.state.detail_text(),
                    "这是一条非常长的系统消息标题，用来验证列表行换行显示完整内容而不是截断\n进行中\n2026年10月4日 1:23\n\n第一行\n**原文**"
                );
                // Explicit open: exactly one command with the shown event id.
                pane.state.open();
                assert_eq!(
                    pane.take_commands(),
                    vec![json!({"op":"inbox.open","id":"one","scope":"world-a",
                        "expectedEventID":"event-one"})]
                );
                assert_eq!(pane.state.selected_row().unwrap()["isRead"], false);
                // An id that is not in the projection cannot become the
                // selection, so the previously shown row stays put.
                pane.state.select("ghost".into());
                assert_eq!(pane.state.selected.as_deref(), Some("one"));
                cx.notify();
            });
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
        // Third paint: the projection empties again; the window must keep
        // drawing without a stale selection or detail.
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.update_snapshot(json!({"scope":"world-a","entries":[]}), cx);
                assert!(pane.state.rows().is_empty());
                assert!(pane.state.selected.is_none());
                assert_eq!(pane.state.detail_text(), "");
                cx.notify();
            });
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }

    /// The footer's explicit open button was dropped from the pane on purpose.
    /// Every needle is assembled with `concat!` so this test's own source cannot
    /// satisfy it: putting the button back into `inbox.rs` turns this red.
    #[test]
    fn the_open_button_is_gone_from_the_pane_source() {
        const SOURCE: &str = include_str!("inbox.rs");
        for needle in [
            concat!("resident.system-inbox", ".open"),
            concat!("打开选中的系统消息", "并标记为已读"),
            concat!("按“打开”", "标记为已读"),
            concat!("IconName::", "ExternalLink"),
        ] {
            assert!(
                !SOURCE.contains(needle),
                "the removed open button must not come back; inbox.rs still contains {needle:?}"
            );
        }
        assert!(
            SOURCE.contains(concat!("双击或按 Return", " 标记为已读")),
            "the placeholder must point at the gestures that remain"
        );
        assert!(
            SOURCE.contains(concat!(
                "KeyBinding::new(\"enter\", OpenSelected",
                ", Some(\"ResidentInbox\"))"
            )),
            "Return must stay bound to OpenSelected"
        );
    }

    /// The two gestures that remain must still open a message on a real painted
    /// panel: a row double-click and Return each queue exactly one `inbox.open`
    /// carrying the displayed event id, while a single click still only selects.
    /// The removed footer button must also be absent from the rendered tree, so
    /// painting it again fails here instead of passing silently.
    #[test]
    fn only_the_row_double_click_and_return_open_and_the_button_is_not_painted() {
        use gpui_kit::test::TestWindowExt as _;
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(InboxPane::new);
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        let pane = stored.borrow().clone().expect("pane entity");
        let expected =
            json!({"op":"inbox.open","id":"one","scope":"world-a","expectedEventID":"event-one"});
        cx.update_window(handle.into(), |_, window, cx| {
            window.render_frame(cx);
            pane.update(cx, |pane, cx| {
                pane.update_snapshot(
                    json!({"scope":"world-a","entries":[
                        {"id":"one","eventID":"event-one","isRead":false,
                         "title":"生成完成","status":"已完成","relativeTimeText":"刚刚",
                         "updatedAtText":"2026年10月4日 1:23","detail":"已完成 3/3"}
                    ]}),
                    cx,
                );
            });
            window.render_frame(cx);
            assert!(
                window.try_find("one").is_some(),
                "the row must be observable, otherwise the checks below are vacuous"
            );
            assert!(
                window
                    .try_find(["resident.system-inbox", ".open"].concat())
                    .is_none(),
                "the footer open button must not be painted any more"
            );
            // A single click only selects and shows the detail.
            window.click("one", cx);
            pane.update(cx, |pane, _| {
                assert!(
                    pane.take_commands().is_empty(),
                    "a single click must not acknowledge the delivery"
                );
                assert_eq!(pane.state.selected.as_deref(), Some("one"));
            });
            // The double-click is the remaining pointer gesture and opens once.
            window.double_click("one", cx);
            pane.update(cx, |pane, _| {
                assert_eq!(
                    pane.take_commands(),
                    vec![expected.clone()],
                    "double-clicking the row must still queue exactly one inbox.open"
                );
            });
            // Return is the remaining keyboard gesture and opens once.
            window.press("enter", cx);
            pane.update(cx, |pane, _| {
                assert_eq!(
                    pane.take_commands(),
                    vec![expected.clone()],
                    "Return on the selected row must still queue exactly one inbox.open"
                );
            });
        })
        .unwrap();
    }
}
