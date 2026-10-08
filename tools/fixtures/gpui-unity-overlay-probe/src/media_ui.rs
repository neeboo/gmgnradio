//! Kit media surfaces consume the existing host's incremental projections.
//! Opening a pane does not play, claim an object, or acknowledge a notification.
//!
//! The catalog / playlist-song navigation / DJ-program surface is the shared
//! [`StageProgramRailPane`]; the system-message surface is the shared
//! [`InboxPane`]. Both are fed from the **existing** production snapshot
//! (`musicLibrary`, `music`, `inbox`, `screenVideo`) and their commands are
//! translated back onto the command names `UnityMediaHost` already dispatches —
//! no second snapshot key and no second op name is introduced here:
//!
//! * `music.library` / `music.program.history` — catalog
//! * `music.playlist` / `music.playlist.play`   — playlist + song navigation
//! * `music.program.play` / `music.select` / `music.choose` — queue
//! * `screen.list` / `screen.play` / `screen.stop`
//! * `inbox.list` / `inbox.read`
//! * `video.bound.play` (the bound-video prompt the host already exposes)
use crate::{UiCommandQueue, enqueue_ui_command};
use gmgn_gpui_ui::{
    inbox::InboxPane,
    primitives as ui,
    stage_panels::StageProgramRailPane,
    ui_tokens::{self, scene},
};
use gpui_kit::assets::IconName;
use gpui_kit::component::{
    Disableable,
    input::{Input, InputState},
    scroll::ScrollableElement,
    tab::{Tab, TabBar},
};
use gpui_kit::*;
use serde_json::{Value, json};

const SECTIONS: [&str; 6] = ["library", "queue", "programs", "screen", "inbox", "wish"];
const LABELS: [&str; 6] = ["音乐库", "队列", "节目", "电视", "消息", "愿望"];
/// The rail's own routes, mirrored from `rail_route` in
/// `gmgn_gpui_ui::stage_panels::program`; the surface owns the route because the
/// production snapshot has no route of its own.
const ROUTE_PROGRAMS: &str = "programs";
const ROUTE_TRACKS: &str = "tracks";
const ROUTE_PLAYLIST_TRACKS: &str = "playlistTracks";

fn media_surface() -> Div {
    ui::scene_card()
        .size_full()
        .min_w_0()
        .min_h_0()
        .overflow_hidden()
        .flex()
        .flex_col()
        .gap_3()
        .p_4()
        .font_family(ui_tokens::FONT_FAMILY)
        .text_size(px(ui_tokens::BODY))
        .text_color(rgba(scene::TEXT))
}
fn media_row(label: String, selected: bool, control: impl IntoElement) -> Div {
    let mut row = ui::scene_inset()
        .w_full()
        .min_w_0()
        .flex()
        .items_center()
        .gap_2()
        .p_2();
    if selected {
        row = row.border_color(rgba(scene::BORDER_ACTIVE));
    }
    row.child(ui::body(label).flex_1().min_w_0()).child(control)
}
fn command_icon(operation: &str) -> IconName {
    match operation {
        "music.choose" => IconName::FolderOpen,
        "screen.stop" => IconName::Square,
        "wish.claim" => IconName::Plus,
        "wish.inventory.retry" => IconName::RefreshCw,
        "ui.chat.open" => IconName::Bot,
        _ => IconName::Play,
    }
}

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

/// One row of the shared `InboxPane` projection, built only from the existing
/// `inbox` snapshot the world session already publishes
/// (`UnityInboxBridge.snapshot()`: `taskKey`/`lastEventID`/`title`/`status`/
/// `detail`/`isRead`/`updatedAt`).
fn inbox_projection(scope: &Value, inbox: &Value) -> Value {
    let entries: Vec<Value> = rows(inbox, "entries")
        .iter()
        .map(|entry| {
            // The host publishes `updatedAt` as `timeIntervalSince1970`, so a
            // JSON number may arrive as an integral float; `InboxPane` reads it
            // with `as_i64()`.
            let updated_at = entry["updatedAt"]
                .as_i64()
                .or_else(|| entry["updatedAt"].as_f64().map(|seconds| seconds as i64));
            json!({
                "id": entry["taskKey"],
                "eventID": entry["lastEventID"],
                "title": entry["title"],
                "status": entry["status"],
                "detail": entry["detail"],
                "isRead": entry["isRead"] == true,
                "updatedAt": updated_at,
            })
        })
        .collect();
    // `InboxPane` shows `persistenceError` as a notice; the production inbox
    // reports it as `message` on a `failed` response.
    let persistence_error = if inbox["status"] == "failed" {
        inbox["message"].clone()
    } else {
        Value::Null
    };
    json!({"scope": scope, "persistenceError": persistence_error, "entries": entries})
}

/// The shared inbox opens a row with `inbox.open`; the production bridge owns
/// `inbox.read` and matches on `taskKey` + `expectedEventID`
/// (`UnityInboxBridge.swift:80-142`). A row without a confirmed event id cannot
/// be opened at all (`inbox.rs:83-85`).
fn inbox_read_command(command: &Value) -> Option<Value> {
    let task_key = command["id"].as_str().filter(|value| !value.is_empty())?;
    let expected = command["expectedEventID"]
        .as_str()
        .filter(|value| !value.is_empty())?;
    Some(json!({"op":"inbox.read","taskKey":task_key,"expectedEventID":expected}))
}

/// The two production reads that serve the rail's catalog
/// (`UnityMediaHost.swift` `music.library` / `music.program.history`). The
/// rail's bootstrap request (`stage.program.load`) and the section switch both
/// resolve to exactly these; keeping the pair in one place means the bootstrap
/// cannot silently become a no-op again.
fn catalog_load_commands() -> [Value; 2] {
    [
        json!({"op":"music.library"}),
        json!({"op":"music.program.history"}),
    ]
}

/// The rail's track play command, resolved onto the production source that is
/// actually open: a DJ program plays its own slot, a playlist plays its own
/// index (`UnityMediaHost.swift:1101-1118`).
fn rail_play_command(    route: &str,
    program: &Option<String>,
    playlist: &Option<String>,
    slot: i64,
) -> Option<Value> {
    match route {
        ROUTE_TRACKS => program
            .as_ref()
            .map(|id| json!({"op":"music.program.play","programID":id,"slotIndex":slot})),
        ROUTE_PLAYLIST_TRACKS => playlist
            .as_ref()
            .map(|id| json!({"op":"music.playlist.play","playlistID":id,"index":slot})),
        _ => None,
    }
}

/// One projected track card. Layout numbers are the production host's own
/// `StageProgramRailModel` rule (`StageOverlayView.swift:3382-3460`); the
/// business fields come from the production track rows unchanged. Per-track
/// `energy` is not part of the Unity host's library projection, so it stays 0
/// rather than being invented.
fn track_card(track: &Value, absolute: i64, active: Option<i64>, pending: &Value) -> Value {
    let relative = match active {
        Some(active) => absolute - active,
        None => absolute,
    };
    let distance = relative.unsigned_abs().min(2) as f64;
    let current = active == Some(absolute);
    json!({
        "slotIndex": absolute,
        "trackID": track["id"],
        "title": track["title"],
        "artist": track["artist"],
        "isCurrent": current,
        // `pendingBoundVideo` is only ever published for the current track, so
        // the track id comparison is the whole confirmation.
        "hasBoundVideo": pending["trackID"].as_str() == track["id"].as_str(),
        "relativeIndex": relative,
        "depth": distance * -72.,
        "opacity": if current { 1. } else { f64::max(if relative < 0 { 0.34 } else { 0.46 }, 1. - distance * 0.16) },
        "scale": if current { 1. } else { f64::max(0.78, 1. - distance * 0.055) },
    })
}

/// The `StageProgramRailPane` projection, built only from the merged
/// `musicLibrary` delta the host already publishes:
/// `{playlists:[{id,name,provider,count,artworkURL}]}` (`:370-374`),
/// `{programs:[{id,name,count,active,pending,activeSlotIndex,tracks:[…]}]}`
/// (`UnityDJProgramBridge.swift:26-38`) and
/// `{playlistID,name,total,loaded,tracks:[{index,id,title,artist,…}]}`
/// (`UnityMusicLibraryBridge.swift:433-437`).
fn rail_projection(
    library: &Value,
    route: &str,
    program: &Option<String>,
    playlist: &Option<String>,
    pending_bound_video: &Value,
) -> Value {
    let programs: Vec<Value> = rows(library, "programs")
        .iter()
        .map(|entry| {
            json!({
                "id": entry["id"],
                "title": entry["name"],
                "subtitle": format!("{} 首", entry["count"].as_u64().unwrap_or(0)),
                "isCurrent": entry["active"] == true,
                "isPending": entry["pending"] == true,
            })
        })
        .collect();
    let playlists: Vec<Value> = rows(library, "playlists")
        .iter()
        .map(|entry| {
            json!({
                "id": entry["id"],
                "title": entry["name"],
                "subtitle": format!("{} 首", entry["count"].as_u64().unwrap_or(0)),
                "artworkURL": entry["artworkURL"],
            })
        })
        .collect();
    let mut title = Value::Null;
    let mut is_playlist = false;
    let mut tracks: Vec<Value> = Vec::new();
    let mut loaded = 0_u64;
    let mut total = 0_u64;
    if route == ROUTE_TRACKS {
        if let Some(id) = program.as_deref() {
            if let Some(entry) = rows(library, "programs")
                .into_iter()
                .find(|entry| entry["id"].as_str() == Some(id))
            {
                title = entry["name"].clone();
                // Only the program that owns playback has an active slot; a
                // merely-selected program must not highlight a track.
                let active = if entry["active"] == true {
                    entry["activeSlotIndex"].as_i64()
                } else {
                    None
                };
                for track in rows(&entry, "tracks") {
                    let absolute = track["index"].as_i64().unwrap_or(0);
                    tracks.push(track_card(&track, absolute, active, pending_bound_video));
                }
                loaded = tracks.len() as u64;
                total = loaded;
            }
        }
    } else if route == ROUTE_PLAYLIST_TRACKS {
        is_playlist = true;
        if let Some(id) = playlist.as_deref() {
            // A playlist page only belongs to the playlist the host confirmed;
            // a pending read must not show the previous playlist's rows.
            if library["playlistID"].as_str() == Some(id) {
                title = library["name"].clone();
                let active = library["currentTrackID"]
                    .as_str()
                    .filter(|id| !id.is_empty())
                    .and_then(|id| {
                        rows(library, "tracks")
                            .iter()
                            .position(|track| track["id"].as_str() == Some(id))
                    })
                    .map(|index| index as i64);
                for (index, track) in rows(library, "tracks").into_iter().enumerate() {
                    let absolute = track["index"].as_i64().unwrap_or(index as i64);
                    tracks.push(track_card(&track, absolute, active, pending_bound_video));
                }
                loaded = library["loaded"].as_u64().unwrap_or(tracks.len() as u64);
                total = library["total"].as_u64().unwrap_or(loaded);
            }
        }
    }
    json!({
        "route": route,
        "title": title,
        "isPlaylist": is_playlist,
        // `readPlaylist` hydrates the whole playlist before publishing
        // (`UnityMusicLibraryBridge.swift:404-442`), so there is never a next page.
        "hasMore": false,
        "playlistID": playlist,
        "loadedTrackCount": loaded,
        "totalTrackCount": total,
        "playlistLoading": is_playlist && tracks.is_empty(),
        "reduceMotion": false,
        "planning": false,
        "programs": programs,
        "playlists": playlists,
        "tracks": tracks,
    })
}

pub struct MediaPane {
    snapshot: Value,
    library: Value,
    inbox: Value,
    wish: Value,
    queue: Vec<Value>,
    commands: UiCommandQueue,
    section: usize,
    /// The rail's route and the production source it belongs to. The rail reads
    /// its route from this projection and every navigation is confirmed against
    /// the production catalog before it is accepted.
    rail_route: &'static str,
    rail_program: Option<String>,
    rail_playlist: Option<String>,
    rail: Entity<StageProgramRailPane>,
    inbox_pane: Entity<InboxPane>,
    selected_screen: Option<String>,
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
            rail_route: ROUTE_PROGRAMS,
            rail_program: None,
            rail_playlist: None,
            rail: cx.new(|cx| StageProgramRailPane::new(window, cx)),
            inbox_pane: cx.new(InboxPane::new),
            selected_screen: None,
            url: cx.new(|cx| InputState::new(window, cx).placeholder("粘贴视频或播放列表链接")),
            notice: String::new(),
            sequence: 0,
        }
    }
    pub fn select_section(&mut self, section: &str, cx: &mut Context<Self>) {
        self.section = SECTIONS.iter().position(|s| *s == section).unwrap_or(0);
        // Entering the catalog (「音乐库」/「节目」) always starts at the merged
        // program + playlist catalog, like opening the original rail.
        if matches!(self.section, 0 | 2) {
            self.rail_route = ROUTE_PROGRAMS;
            self.rail_program = None;
            self.rail_playlist = None;
        }
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
    /// The catalog lives in the host's single `musicLibrary` response, one
    /// operation at a time: playlists come from `music.library`, programs from
    /// `music.program.history`.
    fn load_catalog(&mut self, cx: &mut Context<Self>) {
        let mut library = true;
        let mut programs = true;
        for command in catalog_load_commands() {
            if !enqueue_ui_command(&self.commands, command) {
                library = false;
                programs = false;
            }
        }
        self.notice = if library && programs {
            "请求已发送，等待回执".into()
        } else {
            "操作队列已满，请稍后重试".into()
        };
        cx.notify();
    }
    fn refresh(&mut self, cx: &mut Context<Self>) {
        match self.section {
            0 | 2 => self.load_catalog(cx),
            3 => self.submit(json!({"op":"screen.list"}), cx),
            4 => self.submit(json!({"op":"inbox.list"}), cx),
            5 => self.submit(json!({"op":"wish.status"}), cx),
            _ => {}
        }
    }
    /// Both shared components are command producers, never command senders: the
    /// surface drains them into the same bounded transport the rest of the
    /// overlay uses, after translating onto the existing production ops.
    fn drain_children(&mut self, cx: &mut Context<Self>) {
        let mut outgoing = self.rail.update(cx, |pane, _| pane.take_commands());
        outgoing.extend(self.inbox_pane.update(cx, |pane, _| pane.take_commands()));
        for command in outgoing {
            self.dispatch_child_command(command, cx);
        }
    }
    fn dispatch_child_command(&mut self, command: Value, cx: &mut Context<Self>) {
        match command["op"].as_str().unwrap_or_default() {
            "inbox.open" => {
                if let Some(read) = inbox_read_command(&command) {
                    self.submit(read, cx);
                }
            }
            // The rail's bootstrap request is a catalog read: answer it with
            // the two ops that actually serve the catalog instead of dropping
            // it. The program rail mounts once per process, so this is the
            // same single read the section switch performs, not a periodic
            // reload (the polling loop never re-emits it).
            "stage.program.load" => self.load_catalog(cx),
            "stage.program.open" => {
                let Some(id) = command["id"].as_str().filter(|id| !id.is_empty()) else {
                    return;
                };
                if rows(&self.library, "programs")
                    .iter()
                    .any(|entry| entry["id"].as_str() == Some(id))
                {
                    self.rail_program = Some(id.to_owned());
                    self.rail_playlist = None;
                    self.rail_route = ROUTE_TRACKS;
                    self.notice = "已选择节目，选择歌曲开始播放。".into();
                    cx.notify();
                }
            }
            "stage.playlist.open" => {
                let Some(id) = command["id"].as_str().filter(|id| !id.is_empty()) else {
                    return;
                };
                if rows(&self.library, "playlists")
                    .iter()
                    .any(|entry| entry["id"].as_str() == Some(id))
                {
                    self.rail_playlist = Some(id.to_owned());
                    self.rail_program = None;
                    self.rail_route = ROUTE_PLAYLIST_TRACKS;
                    self.submit(json!({"op":"music.playlist","playlistID":id}), cx);
                }
            }
            "stage.program.back" => {
                self.rail_route = ROUTE_PROGRAMS;
                self.rail_program = None;
                self.rail_playlist = None;
                cx.notify();
            }
            "stage.program.more" => {
                if let Some(id) = self.rail_playlist.clone() {
                    self.submit(json!({"op":"music.playlist","playlistID":id}), cx);
                }
            }
            "stage.program.play" => {
                let Some(slot) = command["slotIndex"].as_i64() else {
                    return;
                };
                if let Some(play) =
                    rail_play_command(self.rail_route, &self.rail_program, &self.rail_playlist, slot)
                {
                    self.submit(play, cx);
                }
            }
            "stage.program.video" => {
                let Some(track) = command["trackID"].as_str() else {
                    return;
                };
                // The host already publishes the pending bound-video prompt;
                // only that confirmed prompt may be played (`video.bound.play`).
                let prompt = &self.snapshot["screenVideo"]["pendingBoundVideo"];
                if prompt["trackID"].as_str() == Some(track) {
                    if let Some(id) = prompt["id"].as_str() {
                        self.submit(json!({"op":"video.bound.play","id":id}), cx);
                    }
                }
            }
            // `UnityHost` has no UI replan op: production replanning is the
            // resident agent's `replan_program` tool. Say so instead of
            // inventing a command name the host would reject.
            "stage.program.replan" => {
                self.notice = "重新编排由居民代理执行：请在聊天中让 DJ 重新排歌。".into();
                cx.notify();
            }
            _ => {}
        }
    }
    pub fn update_snapshot(&mut self, snapshot: &Value, window: &mut Window, cx: &mut Context<Self>) {
        // Audio feature/texture frames change continuously. They are not media
        // form state and must not relayout catalog lists on each host frame.
        let screens: Vec<_> = rows(&snapshot["screenVideo"], "screens")
            .iter()
            .map(|s| json!({"objectID":s["objectID"],"name":s["name"],"state":s["state"]}))
            .collect();
        let projection = json!({"world":{"worldID":snapshot["world"]["worldID"]},
            "music":{"queueIndex":snapshot["music"]["queueIndex"]},
            "screenVideo":{"screens":screens,"commandNotice":snapshot["screenVideo"]["commandNotice"],
                "pendingBoundVideo":snapshot["screenVideo"]["video"]["pendingBoundVideo"]}});
        if self.snapshot["world"]["worldID"] != snapshot["world"]["worldID"] {
            self.inbox = json!({});
            self.wish = json!({});
            self.rail_route = ROUTE_PROGRAMS;
            self.rail_program = None;
            self.rail_playlist = None;
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
        let changed = self.snapshot != projection
            || library_changed
            || inbox_changed
            || wish_changed
            || queue_changed;
        self.snapshot = projection;
        // Feed both shared components from the production projections. Their
        // snapshot comparison is their own; the surface feeds them every host
        // frame so a delta merge is never missed.
        let rail = rail_projection(
            &self.library,
            self.rail_route,
            &self.rail_program,
            &self.rail_playlist,
            &self.snapshot["screenVideo"]["pendingBoundVideo"],
        );
        self.rail
            .update(cx, |pane, cx| pane.update_snapshot(rail, window, cx));
        let inbox = inbox_projection(&self.snapshot["world"]["worldID"], &self.inbox);
        self.inbox_pane
            .update(cx, |pane, cx| pane.update_snapshot(inbox, cx));
        self.drain_children(cx);
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
        let icon = command_icon(command["op"].as_str().unwrap_or(""));
        let control = ui::icon_button(SharedString::from(id), icon, label.clone(), false)
            .disabled(disabled)
            .on_click(cx.listener(move |this, _, _, cx| this.submit(command.clone(), cx)));
        media_row(label, false, control).into_any_element()
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
            body = body.child(media_row(
                format!(
                    "{}{} · {}",
                    if selected { "已选择 · " } else { "" },
                    text(&screen, "name"),
                    text(&screen, "state")
                ),
                selected,
                ui::icon_button(
                    SharedString::from(format!("screen:{id}")),
                    IconName::PanelRight,
                    "选择此屏幕",
                    selected,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.selected_screen = Some(id.clone());
                    cx.notify();
                })),
            ));
        }
        if self.selected_screen.is_none() {
            body = body.child("空间中尚无屏幕，请先放置屏幕物件。");
        }
        let disabled = self.selected_screen.is_none();
        body=body.child(div().flex().flex_col().gap_2().child("视频链接").child(Input::new(&self.url).disabled(disabled)))
            .child("支持视频、直播与 YouTube 播放列表。播放进度以屏幕回执为准。")
            .child(div().flex().gap_2()
                .child(ui::icon_button("screen-play", IconName::Play, "播放链接", false).disabled(disabled)
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
    fn wish(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut body = div().flex().flex_col().gap_3();
        let entries = rows(&self.wish, "entries");
        let busy = self.wish["pending"] == true;
        for entry in &entries {
            let registered = entry["inventoryRegistered"] == true;
            let stage = text(entry, "stage");
            let mut row = ui::scene_inset()
                .p_3()
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
        // The catalog rail and the system inbox own their own scrolling and
        // hit-testing regions: they are mounted whole, never nested inside the
        // surface's scroll container.
        let (content, scrolls) = match self.section {
            0 | 2 => (
                div()
                    .w_full()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .flex()
                    .justify_end()
                    .child(self.rail.clone())
                    .into_any_element(),
                false,
            ),
            1 => (self.queue(cx), true),
            3 => (self.screen(cx), true),
            4 => (
                div()
                    .w_full()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .child(self.inbox_pane.clone())
                    .into_any_element(),
                false,
            ),
            _ => (self.wish(cx), true),
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
        let body = if scrolls {
            div()
                .id("media-content")
                .flex_1()
                .min_h_0()
                .min_w_0()
                .w_full()
                .overflow_y_scrollbar()
                .child(content)
                .into_any_element()
        } else {
            content
        };
        media_surface()
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
                    .child(ui::card_title(LABELS[self.section]))
                    .child(
                        ui::icon_button("media-refresh", IconName::RefreshCw, "刷新", false)
                            .disabled(state["pending"] == true || self.section == 1)
                            .on_click(cx.listener(|this, _, _, cx| this.refresh(cx))),
                    ),
            )
            .child(body)
            .child(
                div()
                    .flex_shrink_0()
                    .text_size(px(ui_tokens::CAPTION))
                    // The pinned destructive tint from the token layer; the
                    // system theme colour is `Hsla` and cannot share the branch
                    // with the `Rgba` token above.
                    .text_color(if error.is_empty() {
                        rgba(scene::TEXT_MUTED)
                    } else {
                        rgba(ui_tokens::stage::DANGER_TEXT)
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
    #[test]
    fn inbox_projection_keeps_the_production_row_identity_and_read_state() {
        let inbox = json!({"status":"completed","pending":false,"entries":[
            {"taskKey":"t1","lastEventID":"e1","title":"生成完成","status":"3/3","detail":"详情",
             "isRead":false,"updatedAt":1_700_000_000}]});
        let projection = inbox_projection(&json!("world-a"), &inbox);
        assert_eq!(projection["scope"], "world-a");
        assert_eq!(projection["entries"][0]["id"], "t1");
        assert_eq!(projection["entries"][0]["eventID"], "e1");
        assert_eq!(projection["entries"][0]["isRead"], false);
        assert_eq!(projection["entries"][0]["updatedAt"], 1_700_000_000);
        assert_eq!(projection["persistenceError"], Value::Null);
        let failed = inbox_projection(&json!("world-a"), &json!({"status":"failed","message":"已读状态尚未确认"}));
        assert_eq!(failed["persistenceError"], "已读状态尚未确认");
        assert!(failed["entries"].as_array().unwrap().is_empty());
    }
    #[test]
    fn inbox_open_becomes_the_existing_read_op_with_its_confirmed_event_only() {
        let mapped = inbox_read_command(
            &json!({"op":"inbox.open","id":"t1","scope":"world-a","expectedEventID":"e1"}),
        )
        .expect("confirmed row opens");
        assert_eq!(mapped, json!({"op":"inbox.read","taskKey":"t1","expectedEventID":"e1"}));
        assert!(inbox_read_command(&json!({"op":"inbox.open","id":"t1","scope":"world-a"})).is_none());
        assert!(inbox_read_command(&json!({"op":"inbox.open","id":"","expectedEventID":"e1"})).is_none());
    }
    #[test]
    fn rail_play_resolves_onto_the_open_production_source() {
        let program = Some("p1".to_owned());
        let playlist = Some("l1".to_owned());
        assert_eq!(
            rail_play_command(ROUTE_TRACKS, &program, &playlist, 2),
            Some(json!({"op":"music.program.play","programID":"p1","slotIndex":2}))
        );
        assert_eq!(
            rail_play_command(ROUTE_PLAYLIST_TRACKS, &program, &playlist, 4),
            Some(json!({"op":"music.playlist.play","playlistID":"l1","index":4}))
        );
        assert!(rail_play_command(ROUTE_PROGRAMS, &program, &playlist, 0).is_none());
        assert!(rail_play_command(ROUTE_TRACKS, &None, &playlist, 0).is_none());
    }
    #[test]
    fn rail_projection_reads_only_the_production_library_snapshot() {
        let library = json!({
            "programs":[{"id":"p1","name":"夜跑","count":2,"active":true,"activeSlotIndex":1,
                "tracks":[{"index":0,"id":"t0","title":"A","artist":"a"},
                          {"index":1,"id":"t1","title":"B","artist":"b"}]}],
            "playlists":[{"id":"l1","name":"我的歌单","provider":"netease","count":3,
                "artworkURL":"https://example.test/a.png"}],
            "playlistID":"l1","name":"我的歌单","loaded":2,"total":3,"currentTrackID":"t1",
            "tracks":[{"index":0,"id":"t0","title":"A","artist":"a"},
                      {"index":1,"id":"t1","title":"B","artist":"b"}]
        });
        let catalog = rail_projection(&library, ROUTE_PROGRAMS, &None, &None, &Value::Null);
        assert_eq!(catalog["route"], ROUTE_PROGRAMS);
        assert_eq!(catalog["programs"][0]["title"], "夜跑");
        assert_eq!(catalog["programs"][0]["subtitle"], "2 首");
        assert_eq!(catalog["programs"][0]["isCurrent"], true);
        assert_eq!(catalog["playlists"][0]["artworkURL"], "https://example.test/a.png");
        assert!(catalog["tracks"].as_array().unwrap().is_empty());

        let program = Some("p1".to_owned());
        let tracks = rail_projection(&library, ROUTE_TRACKS, &program, &None, &Value::Null);
        assert_eq!(tracks["isPlaylist"], false);
        assert_eq!(tracks["title"], "夜跑");
        assert_eq!(tracks["tracks"][0]["relativeIndex"], -1);
        assert_eq!(tracks["tracks"][1]["isCurrent"], true);
        assert_eq!(tracks["tracks"][1]["slotIndex"], 1);
        assert_eq!(tracks["tracks"][1]["opacity"], 1.0);

        let playlist = Some("l1".to_owned());
        let list = rail_projection(&library, ROUTE_PLAYLIST_TRACKS, &None, &playlist, &Value::Null);
        assert_eq!(list["isPlaylist"], true);
        assert_eq!(list["loadedTrackCount"], 2);
        assert_eq!(list["totalTrackCount"], 3);
        assert_eq!(list["tracks"][1]["isCurrent"], true);

        // A playlist the host has not confirmed yet keeps its previous rows out.
        let pending = rail_projection(
            &library,
            ROUTE_PLAYLIST_TRACKS,
            &None,
            &Some("other".to_owned()),
            &Value::Null,
        );
        assert!(pending["tracks"].as_array().unwrap().is_empty());
        assert_eq!(pending["playlistLoading"], true);
    }
    #[test]
    fn rail_projection_binds_video_only_to_the_current_production_track() {
        let library = json!({
            "programs":[{"id":"p1","name":"夜跑","count":2,"active":true,"activeSlotIndex":1,
                "tracks":[{"index":0,"id":"t0","title":"A","artist":"a"},
                          {"index":1,"id":"t1","title":"B","artist":"b"}]}]
        });
        let program = Some("p1".to_owned());
        let prompt = json!({"id":"prompt-1","trackID":"t1"});
        let tracks = rail_projection(&library, ROUTE_TRACKS, &program, &None, &prompt);
        assert_eq!(tracks["tracks"][0]["hasBoundVideo"], false);
        assert_eq!(tracks["tracks"][1]["hasBoundVideo"], true);
        let unknown = rail_projection(&library, ROUTE_TRACKS, &program, &None, &json!({"id":"x","trackID":"t9"}));
        assert_eq!(unknown["tracks"][1]["hasBoundVideo"], false);
    }

    /// The rail's mount request is a real catalog read, not a swallowed
    /// bootstrap: it resolves to the two production ops the section switch
    /// sends, and those are the surfaces `UnityMediaHost` serves
    /// (`music.library` / `music.program.history`).
    #[test]
    fn rail_bootstrap_asks_for_the_production_catalog() {
        assert_eq!(
            catalog_load_commands(),
            [
                json!({"op":"music.library"}),
                json!({"op":"music.program.history"}),
            ]
        );
    }
}
