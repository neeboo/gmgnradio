//! The original system inbox presentation. Selection never acknowledges a task.
use crate::ui_tokens as ui;
use gpui_kit::component::{
    button::*,
    input::{Textarea, TextareaState},
    list::ListItem,
    *,
};
use gpui_kit::*;
use serde_json::{Value, json};

actions!(resident_inbox, [OpenSelected, SelectPrevious, SelectNext]);

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
            let Some(event) = row["eventID"].as_str().filter(|event| !event.is_empty()) else {
                return;
            };
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
            None if self.rows().is_empty() => "暂无系统消息".into(),
            None => "选择一条消息查看完整内容；双击或按“打开”标记为已读".into(),
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
}
impl Focusable for InboxPane {
    fn focus_handle(&self, _: &App) -> FocusHandle {
        self.focus.clone()
    }
}
impl Render for InboxPane {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
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
        let theme = cx.theme();
        let mut list = div()
            .id("resident.system-inbox.list")
            .role(Role::List)
            .aria_label("系统消息列表")
            .w(px(300.))
            .h_full()
            .flex_shrink_0()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .border_r_1()
            .border_color(theme.border);
        for row in self.state.rows() {
            let Some(id) = row["id"].as_str().filter(|id| !id.is_empty()) else {
                continue;
            };
            let id = id.to_owned();
            let title = row["title"].as_str().unwrap_or("").to_owned();
            let status = row["status"].as_str().unwrap_or("").to_owned();
            let read = row["isRead"].as_bool() == Some(true);
            let time = row["relativeTimeText"].as_str().unwrap_or("").to_owned();
            list = list.child(
                ListItem::new(SharedString::from(id.clone()))
                    .selected(self.state.selected.as_deref() == Some(&id))
                    .accessibility_label(format!(
                        "{title}，{status}，{}",
                        if read { "已读" } else { "未读" }
                    ))
                    .h(px(44.))
                    .on_click(cx.listener(move |this, event: &ClickEvent, window, cx| {
                        this.state.select(id.clone());
                        if event.click_count() >= 2 {
                            this.state.open();
                        }
                        window.focus(&this.focus, cx);
                        cx.notify();
                    }))
                    .child(
                        div()
                            .w_full()
                            .flex()
                            .items_center()
                            .gap(px(ui::SPACING_8))
                            .child(
                                div()
                                    .w(px(10.))
                                    .flex_shrink_0()
                                    .text_size(px(9.))
                                    .text_color(rgb(0x0a84ff))
                                    .child(if read { "" } else { "●" }),
                            )
                            .child(
                                div()
                                    .flex_1()
                                    .min_w(px(0.))
                                    .flex()
                                    .flex_col()
                                    .child(
                                        div()
                                            .flex()
                                            .items_baseline()
                                            .gap(px(ui::SPACING_8))
                                            .child(
                                                div()
                                                    .flex_1()
                                                    .min_w(px(0.))
                                                    .text_size(px(ui::CAPTION))
                                                    .font_weight(FontWeight::MEDIUM)
                                                    .truncate()
                                                    .child(title),
                                            )
                                            .child(
                                                div()
                                                    .flex_shrink_0()
                                                    .text_size(px(10.))
                                                    .text_color(theme.muted_foreground)
                                                    .child(time),
                                            ),
                                    )
                                    .child(
                                        div()
                                            .text_size(px(10.))
                                            .text_color(theme.muted_foreground)
                                            .truncate()
                                            .child(status),
                                    ),
                            ),
                    ),
            );
        }
        let mut details = div()
            .flex_1()
            .min_w(px(320.))
            .h_full()
            .flex()
            .flex_col()
            .gap(px(ui::SPACING_8))
            .pl_2()
            .pr_2()
            .child(
                div()
                    .id("resident.system-inbox.detail")
                    .flex_1()
                    .min_h(px(220.))
                    .overflow_y_scroll()
                    .p(px(ui::SPACING_12))
                    .text_size(px(ui::CAPTION))
                    .child(
                        Textarea::new(self.detail.as_ref().expect("plain detail state"))
                            .readonly(true)
                            .appearance(false)
                            .bordered(false)
                            .h_full()
                            .w_full()
                            .aria_label("消息详情")
                            .accessibility_id("resident.system-inbox.detail-text"),
                    ),
            )
            .child(
                Button::new("resident.system-inbox.open")
                    .label("打开")
                    .tooltip("打开选中的系统消息并标记为已读")
                    .accessibility_label("打开选中的系统消息")
                    .disabled(!self.state.selected_row().is_some_and(|row| row["eventID"].as_str().is_some_and(|event| !event.is_empty())))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.state.open();
                        window.focus(&this.focus, cx);
                        cx.notify();
                    })),
            );
        if let Some(error) = self.state.snapshot["persistenceError"]
            .as_str()
            .filter(|s| !s.is_empty())
        {
            details = details.child(div().text_sm().child(error.to_owned()));
        }
        div()
            .font_family(theme.font_family.clone())
            .text_size(px(ui::BODY))
            .line_height(px(ui::BODY_LINE_HEIGHT))
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
            .size_full()
            .p(px(10.))
            .flex()
            .bg(theme.tokens.background)
            .text_color(theme.foreground)
            .child(list)
            .child(details)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot(scope: &str) -> Value {
        json!({"scope":scope,"entries":[{"id":"one","eventID":"event-one","isRead":false}]})
    }
    #[core::prelude::v1::test]
    fn selection_does_not_mark_read_or_send_command() {
        let mut state = InboxState::default();
        state.update(snapshot("world-a"));
        state.select("one".into());
        assert!(state.commands.is_empty());
        assert_eq!(state.selected_row().unwrap()["isRead"], false);
    }
    #[core::prelude::v1::test]
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
    #[core::prelude::v1::test]
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
    #[core::prelude::v1::test]
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
    #[core::prelude::v1::test]
    fn open_without_a_confirmed_display_event_cannot_mark_read() {
        let mut state = InboxState::default();
        state.update(json!({"scope":"world-a","entries":[{"id":"one","isRead":false}]}));
        state.select("one".into());
        state.open();
        assert!(state.commands.is_empty());
    }
    #[core::prelude::v1::test]
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
    #[core::prelude::v1::test]
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
}
