//! Kit media surfaces consume the existing host's incremental projections.
//! Opening a pane does not play, claim an object, or acknowledge a notification.
use crate::{UiCommandQueue, enqueue_ui_command};
use gpui_kit::component::{
    Disableable,
    ActiveTheme,
    button::Button,
    input::{Input, InputState},
    scroll::ScrollableElement,
    tab::{Tab, TabBar},
};
use gpui_kit::*;
use serde_json::{Value, json};

const SECTIONS: [&str; 6] = ["library", "queue", "programs", "screen", "inbox", "wish"];
const LABELS: [&str; 6] = ["音乐库", "队列", "节目", "电视", "消息", "愿望"];

fn text(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap_or("").to_owned()
}
fn rows(value: &Value, key: &str) -> Vec<Value> {
    value[key].as_array().cloned().unwrap_or_default()
}
fn merge_projection(target: &mut Value, patch: &Value) -> bool {
    let mut changed = false;
    if let Some(map) = patch.as_object() {
        if !target.is_object() {
            *target = json!({});
        }
        for (key, value) in map {
            if target[key] != *value {
                target[key] = value.clone();
                changed = true;
            }
        }
    }
    changed
}

pub struct MediaPane {
    snapshot: Value,
    library: Value,
    inbox: Value,
    wish: Value,
    queue: Vec<Value>,
    commands: UiCommandQueue,
    section: usize,
    playlist: Option<String>,
    program: Option<String>,
    selected_screen: Option<String>,
    selected_message: Option<String>,
    url: Entity<InputState>,
    notice: String,
    sequence: u64,
}

impl MediaPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>, commands: UiCommandQueue) -> Self {
        Self {
            snapshot: Value::Null,
            library: json!({}),
            inbox: json!({}),
            wish: json!({}),
            queue: vec![],
            commands,
            section: 0,
            playlist: None,
            program: None,
            selected_screen: None,
            selected_message: None,
            url: cx.new(|cx| InputState::new(window, cx).placeholder("粘贴视频或播放列表链接")),
            notice: String::new(),
            sequence: 0,
        }
    }
    pub fn select_section(&mut self, section: &str, cx: &mut Context<Self>) {
        self.section = SECTIONS.iter().position(|s| *s == section).unwrap_or(0);
        self.refresh(cx);
    }
    fn submit(&mut self, mut command: Value, cx: &mut Context<Self>) {
        if command["op"]
            .as_str()
            .is_some_and(|op| op.starts_with("wish."))
        {
            self.sequence = self.sequence.wrapping_add(1);
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or_default();
            command["requestID"] = json!(format!(
                "gpui-wish:{}:{nonce}:{}",
                std::process::id(),
                self.sequence
            ));
        }
        self.notice = if enqueue_ui_command(&self.commands, command) {
            "请求已发送，等待回执".into()
        } else {
            "操作队列已满，请稍后重试".into()
        };
        cx.notify();
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        let op = match self.section {
            0 => "music.library",
            2 => "music.program.history",
            3 => "screen.list",
            4 => "inbox.list",
            5 => "wish.status",
            _ => return,
        };
        self.submit(json!({"op":op}), cx);
    }
    pub fn update_snapshot(&mut self, snapshot: &Value, _: &mut Window, cx: &mut Context<Self>) {
        // Audio feature/texture frames change continuously. They are not media
        // form state and must not relayout catalog lists on each host frame.
        let screens: Vec<_> = rows(&snapshot["screenVideo"], "screens")
            .iter()
            .map(|s| json!({"objectID":s["objectID"],"name":s["name"],"state":s["state"]}))
            .collect();
        let projection = json!({"world":{"worldID":snapshot["world"]["worldID"]},
            "music":{"queueIndex":snapshot["music"]["queueIndex"]},
            "screenVideo":{"screens":screens,"commandNotice":snapshot["screenVideo"]["commandNotice"]}});
        if self.snapshot["world"]["worldID"] != snapshot["world"]["worldID"] {
            self.inbox = json!({});
            self.wish = json!({});
            self.selected_message = None;
        }
        let library_changed = merge_projection(&mut self.library, &snapshot["musicLibrary"]);
        let inbox_changed = merge_projection(&mut self.inbox, &snapshot["inbox"]);
        let wish_changed = merge_projection(&mut self.wish, &snapshot["wish"]);
        let mut queue_changed = false;
        if let Some(queue) = snapshot["music"]["queue"].as_array() {
            if &self.queue != queue {
                self.queue = queue.clone();
                queue_changed = true;
            }
        }
        let screens = rows(&projection["screenVideo"], "screens");
        if !screens
            .iter()
            .any(|s| s["objectID"].as_str() == self.selected_screen.as_deref())
        {
            self.selected_screen = screens
                .first()
                .and_then(|s| s["objectID"].as_str())
                .map(str::to_owned);
        }
        let changed = self.snapshot != projection
            || library_changed
            || inbox_changed
            || wish_changed
            || queue_changed;
        self.snapshot = projection;
        if changed {
            cx.notify();
        }
    }
    fn button(
        &self,
        id: String,
        label: String,
        command: Value,
        disabled: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        Button::new(SharedString::from(id))
            .label(label)
            .disabled(disabled)
            .on_click(cx.listener(move |this, _, _, cx| this.submit(command.clone(), cx)))
            .into_any_element()
    }
    fn library(&self, cx: &mut Context<Self>) -> AnyElement {
        let busy = self.library["pending"] == true;
        let mut body = div().flex().flex_col().gap_2();
        if self.section == 2 {
            for entry in rows(&self.library, "programs") {
                let id = text(&entry, "id");
                let selected = self.program.as_deref() == Some(&id);
                body = body.child(
                    Button::new(SharedString::from(format!("program:{id}")))
                        .label(text(&entry, "name"))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.program = Some(id.clone());
                            cx.notify();
                        })),
                );
                if selected {
                    for track in rows(&entry, "tracks") {
                        body=body.child(self.button(format!("program-track:{}:{}",text(&entry,"id"),track["index"]),
                        format!("{} · {}",text(&track,"title"),text(&track,"artist")),
                        json!({"op":"music.program.play","programID":entry["id"],"slotIndex":track["index"]}),busy,cx));
                    }
                }
            }
            if rows(&self.library, "programs").is_empty() {
                body = body.child("暂无节目，刷新可载入已保存的节目");
            }
        } else if let Some(id) = &self.playlist {
            body = body.child(
                Button::new("media-playlists-back")
                    .label("返回歌单")
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.playlist = None;
                        cx.notify();
                    })),
            );
            if self.library["playlistID"].as_str() == Some(id) {
                body = body.child(text(&self.library, "name"));
                for track in rows(&self.library, "tracks") {
                    body = body.child(self.button(
                        format!("playlist-track:{id}:{}", track["index"]),
                        format!("{} · {}", text(&track, "title"), text(&track, "artist")),
                        json!({"op":"music.playlist.play","playlistID":id,"index":track["index"]}),
                        busy,
                        cx,
                    ));
                }
                if rows(&self.library, "tracks").is_empty() {
                    body = body.child(if busy {
                        "正在载入歌曲"
                    } else {
                        "歌单暂无可播放歌曲"
                    });
                }
            } else {
                body = body.child("正在载入所选歌单");
            }
        } else {
            for entry in rows(&self.library, "playlists") {
                let id = text(&entry, "id");
                body = body.child(
                    Button::new(SharedString::from(format!("playlist:{id}")))
                        .label(format!("{} · {} 首", text(&entry, "name"), entry["count"]))
                        .disabled(busy)
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.playlist = Some(id.clone());
                            this.submit(json!({"op":"music.playlist","playlistID":id}), cx);
                        })),
                );
            }
            if rows(&self.library, "playlists").is_empty() {
                body = body.child(if busy {
                    "正在载入音乐库"
                } else {
                    "暂无歌单，请先在设置中连接音乐账户并同步"
                });
            }
        }
        body.into_any_element()
    }
    fn queue(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut body = div().flex().flex_col().gap_2();
        for entry in &self.queue {
            let prefix = if entry["index"] == self.snapshot["music"]["queueIndex"] {
                "当前歌曲 · "
            } else {
                ""
            };
            body = body.child(self.button(
                format!("queue:{}", entry["index"]),
                format!("{prefix}{}", text(entry, "title")),
                json!({"op":"music.select","index":entry["index"]}),
                false,
                cx,
            ));
        }
        if self.queue.is_empty() {
            body = body.child("还没有音乐，可选择本地音乐或从音乐库播放歌单。");
        }
        body.child(self.button(
            "choose-music".into(),
            "选择本地音乐…".into(),
            json!({"op":"music.choose"}),
            false,
            cx,
        ))
        .into_any_element()
    }
    fn screen(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut body = div().flex().flex_col().gap_3().child("空间屏幕");
        for screen in rows(&self.snapshot["screenVideo"], "screens") {
            let id = text(&screen, "objectID");
            let selected = self.selected_screen.as_deref() == Some(&id);
            body = body.child(
                Button::new(SharedString::from(format!("screen:{id}")))
                    .label(format!(
                        "{}{} · {}",
                        if selected { "已选择 · " } else { "" },
                        text(&screen, "name"),
                        text(&screen, "state")
                    ))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected_screen = Some(id.clone());
                        cx.notify();
                    })),
            );
        }
        if self.selected_screen.is_none() {
            body = body.child("空间中尚无屏幕，请先放置屏幕物件。");
        }
        let disabled = self.selected_screen.is_none();
        body=body.child(div().flex().flex_col().gap_2().child("视频链接").child(Input::new(&self.url).disabled(disabled)))
            .child("支持视频、直播与 YouTube 播放列表。播放进度以屏幕回执为准。")
            .child(div().flex().gap_2()
                .child(Button::new("screen-play").label("播放链接").disabled(disabled)
                    .on_click(cx.listener(|this,_,_,cx|{
                        let url=this.url.read(cx).value().trim().to_owned();
                        if url.trim().is_empty() {this.notice="请填写视频链接".into();cx.notify();return;}
                        this.submit(json!({"op":"screen.play","objectID":this.selected_screen,"url":url}),cx);
                    })))
                .child(self.button("screen-stop".into(),"停止播放".into(),json!({"op":"screen.stop","objectID":self.selected_screen}),disabled,cx)));
        let notice = text(&self.snapshot["screenVideo"], "commandNotice");
        if !notice.is_empty() {
            body = body.child(notice);
        }
        body.into_any_element()
    }
    fn inbox(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut body = div().flex().flex_col().gap_2();
        let entries = rows(&self.inbox, "entries");
        for entry in &entries {
            let key = text(entry, "taskKey");
            let event = entry["lastEventID"].clone();
            body = body.child(
                Button::new(SharedString::from(format!("inbox:{key}")))
                    .label(format!(
                        "{} · {}",
                        text(entry, "title"),
                        if entry["isRead"] == true {
                            "已读"
                        } else {
                            "未读"
                        }
                    ))
                    .disabled(self.inbox["pending"] == true)
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected_message = Some(key.clone());
                        this.submit(
                            json!({"op":"inbox.read","taskKey":key,"expectedEventID":event}),
                            cx,
                        );
                    })),
            );
        }
        if entries.is_empty() {
            body = body.child(if self.inbox["pending"] == true {
                "正在载入系统消息"
            } else {
                "暂无系统消息"
            });
        }
        if let Some(entry) = entries
            .iter()
            .find(|e| e["taskKey"].as_str() == self.selected_message.as_deref())
        {
            body = body.child(
                div()
                    .border_t_1()
                    .border_color(cx.theme().border)
                    .pt_3()
                    .flex()
                    .flex_col()
                    .gap_2()
                    .child(text(entry, "title"))
                    .child(text(entry, "status"))
                    .child(text(entry, "detail")),
            );
        }
        body.into_any_element()
    }
    fn wish(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut body = div().flex().flex_col().gap_3();
        let entries = rows(&self.wish, "entries");
        let busy = self.wish["pending"] == true;
        for entry in &entries {
            let registered = entry["inventoryRegistered"] == true;
            let stage = text(entry, "stage");
            let mut row = div()
                .flex()
                .flex_col()
                .gap_2()
                .child(text(entry, "name"))
                .child(if registered {
                    "已加入物品列表".into()
                } else {
                    stage.clone()
                });
            if !registered && (stage == "claimed" || stage == "ready") {
                row=row.child(self.button(format!("claim:{}",entry["wishID"]),
                    if stage=="claimed" {"重试加入物品列表".into()} else {"领取物品".into()},
                    json!({"op":if stage=="claimed" {"wish.inventory.retry"} else {"wish.claim"},"wishID":entry["wishID"]}),
                    busy || (stage!="claimed"&&entry["claimAvailable"]!=true),cx));
            }
            body = body.child(row);
        }
        if entries.is_empty() {
            body = body.child(if busy {
                "正在查询愿望任务"
            } else {
                "暂无愿望任务，可在聊天中描述想要的物品。"
            });
        }
        body.child(self.button(
            "wish-open-chat".into(),
            "在聊天中许愿".into(),
            json!({"op":"ui.chat.open"}),
            false,
            cx,
        ))
        .into_any_element()
    }
}

impl Render for MediaPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let content = match self.section {
            0 | 2 => self.library(cx),
            1 => self.queue(cx),
            3 => self.screen(cx),
            4 => self.inbox(cx),
            _ => self.wish(cx),
        };
        let state = match self.section {
            0 | 2 => &self.library,
            4 => &self.inbox,
            5 => &self.wish,
            _ => &self.snapshot["screenVideo"],
        };
        let error = if state["status"] == "failed" {
            text(state, "message")
        } else {
            String::new()
        };
        div()
            .size_full()
            .min_w_0()
            .flex()
            .flex_col()
            .gap_3()
            .text_size(px(14.))
            .p_4()
            .child(
                TabBar::new("media-sections")
                    .selected_index(self.section)
                    .on_click(cx.listener(|this, index: &usize, _, cx| {
                        this.section = *index;
                        this.refresh(cx);
                    }))
                    .children(LABELS.iter().map(|label| Tab::new().label(*label))),
            )
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(LABELS[self.section])
                    .child(
                        Button::new("media-refresh")
                            .label("刷新")
                            .disabled(state["pending"] == true || self.section == 1)
                            .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                    ),
            )
            .child(
                div()
                    .id("media-content")
                    .flex_1()
                    .min_h_0()
                    .w_full()
                    .overflow_y_scrollbar()
                    .child(content),
            )
            .child(
                div()
                    .text_color(if error.is_empty() {
                        cx.theme().muted_foreground
                    } else {
                        cx.theme().danger
                    })
                    .child(if error.is_empty() {
                        self.notice.clone()
                    } else {
                        error
                    }),
            )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::prelude::v1::test;
    #[test]
    fn incremental_host_pulse_preserves_lists_without_fabricating_results() {
        let mut state = json!({"entries":[{"taskKey":"one","isRead":false}]});
        merge_projection(&mut state, &json!({"pending":true,"generation":2}));
        assert_eq!(rows(&state, "entries").len(), 1);
        assert_eq!(state["entries"][0]["isRead"], false);
        merge_projection(&mut state, &json!({"entries":[],"pending":false}));
        assert!(rows(&state, "entries").is_empty());
    }
}
