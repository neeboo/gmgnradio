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
use gpui_kit::base::Disableable as _;
use gpui_kit::component::{
    input::{Input, InputState},
    scroll::ScrollableElement,
};
use gpui_kit::*;
use serde_json::{Value, json};

const SECTIONS: [&str; 6] = ["library", "queue", "programs", "screen", "inbox", "wish"];
/// The header is a **readout** of the section the transport button (or a
/// `ui.music.open` / `ui.wish.open` command) already selected — never a
/// control. The original Swift media UI is a single rail whose content is
/// chosen entirely by the transport, so the panel owns no navigation of its
/// own; the early Rust port's in-panel segmented tab strip was a second entry
/// point and is deliberately gone. `section` has exactly one writer,
/// [`MediaPane::select_section`].
fn section_title(section: usize) -> &'static str {
    match SECTIONS.get(section) {
        Some(&"library") => "音乐库",
        Some(&"queue") => "队列",
        Some(&"programs") => "节目",
        Some(&"screen") => "电视",
        Some(&"inbox") => "消息",
        Some(&"wish") => "愿望",
        _ => "媒体",
    }
}
/// The rail's own routes, mirrored from `rail_route` in
/// `gmgn_gpui_ui::stage_panels::program`; the surface owns the route because the
/// production snapshot has no route of its own.
const ROUTE_PROGRAMS: &str = "programs";
const ROUTE_TRACKS: &str = "tracks";
const ROUTE_PLAYLIST_TRACKS: &str = "playlistTracks";

/// The id of the box the media panel hands the shared `InboxPane` (the 消息
/// section arm below). The geometry test reads this box's **real prepared
/// bounds**, so the width the panel gives the pane is never a copy of the width
/// in the test. (`the_inbox_body_is_clipped_inside_the_panel_box` scans the
/// source around the section arm; this comment must not repeat that marker.)
pub(crate) const INBOX_HOST_ID: &str = "media.inbox.host";

/// [`media_surface`]'s padding on every side — the document scale's `.p_4()`.
/// Named because the panel's own content floor is a sum that includes it.
pub(crate) const SURFACE_PADDING: f32 = 16.;

/// [`media_surface`]'s own border (`ui::scene_card()`'s `.border_1()`), one on
/// each side. The pane is laid out inside it, so the panel's content floor has
/// to carry it too: without it the pane is handed 578 pt of the 580 it needs
/// and the row overflows by exactly the border.
pub(crate) const SURFACE_BORDER: f32 = 1.;

/// The narrowest media panel box that can still show 「消息」 whole.
///
/// The pane is a complete surface of its own (see [`INBOX_HOST_ID`]): inside it
/// the list keeps `inbox::LIST_MIN_WIDTH` and the detail keeps
/// `inbox::DETAIL_MIN_WIDTH`, and the split adds `inbox::PANEL_INSET` on both
/// sides — `inbox::PANE_MIN_WIDTH` (580 pt). The media panel hosts the pane
/// inside [`media_surface`]'s own padding, so the panel needs
/// `PANEL_CONTENT_FLOOR = 580 + 2 × 16 + 2 × 1 = 614` pt (the card carries a 1 pt
/// border on each side). That is **wider** than the
/// stage panel's 590 pt ceiling: hosting a pane whose own floor is 580 pt means
/// the panel has to be able to be that wide, or one of the two columns is cut
/// off (「消息面板没显示完整，左边缺一块」).
pub(crate) const PANEL_CONTENT_FLOOR: f32 =
    ui_tokens::inbox::PANE_MIN_WIDTH + 2. * SURFACE_PADDING + 2. * SURFACE_BORDER;

// ---- 电视 / 屏幕面板的原始数值 ----------------------------------------------
//
// Source: `apps/unity-player/Assets/GMGN/Resources/ScreenVideo.uss` (the
// original Unity panel that the 电视 transport control opened) and
// `UnityScreenVideoController.cs` (`Initialize` / `RefreshPanel`). Every number
// here is a verbatim transcription; the comments carry the original selector.
//
// The panel is **not** the space-video settings page: it is the small surface
// that lists the screens, takes one link and reports what the selected screen is
// doing — including which item of a playlist that link expanded to.

/// `.screen-video-choice { margin-bottom: 8px }` — the gap under the screen
/// picker.
pub(crate) const CHOICE_GAP: f32 = 8.;
/// `.screen-video-url .unity-base-field__label { margin-bottom: 4px }`.
pub(crate) const URL_LABEL_GAP: f32 = 4.;
/// `.screen-video-choice .unity-base-field__input, .screen-video-url
/// .unity-base-field__input { height: 36px; padding: 6px 10px }`.
pub(crate) const FIELD_HEIGHT: f32 = 36.;
/// `.screen-video-actions { height: 36px; margin-top: 8px }`.
pub(crate) const ACTIONS_HEIGHT: f32 = 36.;
pub(crate) const ACTIONS_TOP: f32 = 8.;
/// `.screen-video-play { margin-right: 8px }`.
pub(crate) const PLAY_GAP: f32 = 8.;
/// `.screen-video-status { min-height: 20px; margin-top: 8px }`.
pub(crate) const STATUS_MIN_HEIGHT: f32 = 20.;
pub(crate) const STATUS_TOP: f32 = 8.;
/// `.screen-video-rows { min-height: 20px; margin-top: 8px }` and its Label.
pub(crate) const ROWS_MIN_HEIGHT: f32 = 20.;
pub(crate) const ROWS_TOP: f32 = 8.;
/// `.screen-video-status { color: #ff9c94 }` — the original's failure tint. It is
/// a fixed overlay value (`stage::DANGER_TEXT`), never the system theme's.
pub(crate) const STATUS_COLOR: u32 = ui_tokens::stage::DANGER_TEXT;

/// The playlist row [`screen_status_projection`] built for one screen, or
/// `Null`.
///
/// The host's own copy lives at `screenVideo.video.screens[]`
/// (`UnityScreenVideoBridge.settingsSnapshot()`); it is the **only** place the
/// backend's playlist facts live, because the outer `screenVideo.screens[]`
/// carries just `objectID` / `name` / `state`. The pane's own projection keeps
/// the same per-screen facts under `screenVideo.status[]`.
pub(crate) fn screen_status<'a>(snapshot: &'a Value, object_id: &str) -> &'a Value {
    snapshot["screenVideo"]["status"]
        .as_array()
        .and_then(|rows| {
            rows.iter()
                .find(|row| row["objectID"].as_str() == Some(object_id))
        })
        .unwrap_or(&Value::Null)
}

/// 「播放列表 2/10」 from the host's own `playlistIndex` / `playlistCount`
/// (`NativeScreenPlaybackCoordinator.Session.playlistText`, published at
/// `UnityScreenVideoBridge.swift:398-400`). The UI never re-counts a playlist it
/// did not import; a screen that is not on a playlist shows nothing.
pub(crate) fn playlist_line(row: &Value) -> Option<String> {
    let count = row["playlistCount"].as_u64()?;
    if count == 0 {
        return None;
    }
    let index = row["playlistIndex"].as_u64().unwrap_or(0);
    Some(format!("播放列表 {}/{}", (index + 1).min(count), count))
}

/// 「m:ss」 — the original's `Duration` formatting
/// (`MusicLibraryPanel.cs` `Duration`: `$"{(int)seconds / 60}:{(int)seconds % 60:00}"`).
pub(crate) fn clock(seconds: f64) -> String {
    let total = if seconds.is_finite() {
        seconds.max(0.).floor() as u64
    } else {
        0
    };
    format!("{}:{:02}", total / 60, total % 60)
}

/// 「01:23 / 04:05」 for a finite item, 「直播」 for a live one, and nothing at all
/// until the decoder reports a clock. The numbers are the host's
/// `currentSeconds` / `durationSeconds`; a missing duration is not invented as 0.
pub(crate) fn progress_line(row: &Value) -> Option<String> {
    if row["isLive"].as_bool() == Some(true) {
        return Some("直播".to_owned());
    }
    let current = row["currentSeconds"].as_f64()?;
    if !current.is_finite() || current < 0. {
        return None;
    }
    let duration = row["durationSeconds"]
        .as_f64()
        .filter(|value| value.is_finite() && *value > 0.);
    Some(match duration {
        Some(duration) => format!("{} / {}", clock(current), clock(duration)),
        None => clock(current),
    })
}

/// The 电视 panel's second half: the playlist position and the clock the host
/// publishes per screen in `screenVideo.video.screens[]`. Only the fields the
/// panel draws are projected, and the clock is quantized to whole seconds, so a
/// 60 Hz `currentSeconds` does not notify the pane 60 times a second.
pub(crate) fn screen_status_projection(snapshot: &Value) -> Vec<Value> {
    rows(&snapshot["screenVideo"]["video"], "screens")
        .iter()
        .map(|s| {
            json!({
                "objectID": s["objectID"],
                "state": s["state"],
                "playlistIndex": s["playlistIndex"],
                "playlistCount": s["playlistCount"],
                "playlistRevision": s["playlistRevision"],
                "currentSeconds": s["currentSeconds"].as_f64().map(|v| v.floor()),
                "durationSeconds": s["durationSeconds"].as_f64().map(|v| v.floor()),
                "isLive": s["isLive"] == true,
            })
        })
        .collect()
}

/// The only ops the 电视 panel may send. Every one of them is in
/// `UnityScreenVideoBridge.supportedCommands`; the backend has **no**
/// skip-to-playlist-item op (a playlist advances on the player's own EOF
/// receipt), so the panel must not offer one.
pub(crate) const SCREEN_OPS: [&str; 3] = ["screen.list", "screen.play", "screen.stop"];

fn media_surface() -> Div {
    ui::scene_card()
        .size_full()
        .min_w_0()
        .min_h_0()
        .overflow_hidden()
        .flex()
        .flex_col()
        .gap_3()
        .p(px(SURFACE_PADDING))
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
            3 => self.submit(json!({"op": SCREEN_OPS[0]}), cx),
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
            .map(|s| json!({"objectID":s["objectID"],"name":s["name"],"state":s["state"],"playing":s["playing"] == true}))
            .collect();
        // The 电视 panel's second half: the playlist position and the clock the
        // host publishes per screen in `screenVideo.video.screens[]`. Only the
        // fields the panel draws are projected, and the clock is quantized to
        // whole seconds, so a 60 Hz `currentSeconds` does not notify the pane
        // 60 times a second.
        let screen_status = screen_status_projection(snapshot);
        // The original panel is usable the moment it opens: its `DropdownField`
        // selects the first screen (`UnityScreenVideoController.RefreshPanel`:
        // `screenChoice.index = index >= 0 ? index : screenIDs.Count > 0 ? 0 : -1`).
        // Without this the panel listed 「客厅电视」 and simultaneously told the
        // person 「空间中尚无屏幕，请先放置屏幕物件。」, and 播放/停止 stayed dead
        // until a screen was clicked by hand.
        let selected_still_exists = self.selected_screen.as_deref().is_some_and(|id| {
            screens
                .iter()
                .any(|screen| screen["objectID"].as_str() == Some(id))
        });
        if !selected_still_exists {
            self.selected_screen = screens
                .first()
                .and_then(|screen| screen["objectID"].as_str())
                .map(str::to_owned);
        }
        let projection = json!({"world":{"worldID":snapshot["world"]["worldID"]},
            "music":{"queueIndex":snapshot["music"]["queueIndex"]},
            "screenVideo":{"screens":screens,"commandNotice":snapshot["screenVideo"]["commandNotice"],
                "status":screen_status,
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
        let control = ui::icon_button(SharedString::from(id), icon, label.clone(), false, !disabled)
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
    /// 电视 — the original `screen-video-panel`
    /// (`UnityScreenVideoController.Initialize` + `Resources/ScreenVideo.uss`):
    /// a screen picker, one 36 pt link field, a 36 pt 播放 / 停止 row, the command
    /// status line, and the selected screen's own readout.
    ///
    /// The readout is where the backend's playlist was missing: the outer
    /// `screenVideo.screens[]` carries only a pre-joined `state` string, while the
    /// structured `playlistIndex` / `playlistCount` / `playlistRevision` and the
    /// `currentSeconds` / `durationSeconds` / `isLive` clock live in
    /// `screenVideo.video.screens[]` — published by the host since the playlist
    /// work, and read by **nothing** in this UI until now. The panel only reads
    /// them: there is no skip-to-item op in the backend, so the panel does not
    /// invent one (a playlist advances on the player's own EOF receipt).
    fn screen(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut choice = div().flex().flex_col().gap_2().mb(px(CHOICE_GAP));
        for screen in rows(&self.snapshot["screenVideo"], "screens") {
            let id = text(&screen, "objectID");
            let selected = self.selected_screen.as_deref() == Some(&id);
            let playing = screen["playing"] == true;
            let label = format!(
                "{}{} · {}{}",
                if selected { "已选择 · " } else { "" },
                text(&screen, "name"),
                text(&screen, "state"),
                if playing { " ▶" } else { "" }
            );
            choice = choice.child(media_row(
                label,
                selected || playing,
                ui::icon_button(
                    SharedString::from(format!("screen:{id}")),
                    IconName::PanelRight,
                    "选择此屏幕",
                    selected,
                    true,
                )
                .on_click(cx.listener(move |this, _, _, cx| {
                    this.selected_screen = Some(id.clone());
                    cx.notify();
                })),
            ));
        }
        if self.selected_screen.is_none() {
            choice = choice.child("空间中尚无屏幕，请先放置屏幕物件。");
        }
        let disabled = self.selected_screen.is_none();
        let link = div()
            .flex()
            .flex_col()
            .child(
                div()
                    .mb(px(URL_LABEL_GAP))
                    .child(ui::muted("视频链接")),
            )
            .child(
                div()
                    .h(px(FIELD_HEIGHT))
                    .flex()
                    .items_center()
                    .child(Input::new(&self.url).disabled(disabled)),
            );
        let actions = div()
            .flex()
            .items_center()
            .h(px(ACTIONS_HEIGHT))
            .mt(px(ACTIONS_TOP))
            // The original's two labelled buttons, each `flex-grow: 1` in a 36 pt
            // row with an 8 pt gap (`.screen-video-actions Button { flex-grow: 1 }`,
            // `.screen-video-play { margin-right: 8px }`). An icon-only control
            // would drop the words 播放 / 停止 the original prints.
            .child(
                ui::capsule_button("screen-play", "播放")
                    .flex_1()
                    .h(px(ACTIONS_HEIGHT))
                    .disabled(disabled)
                    .on_click(cx.listener(|this, _, _, cx| {
                        let url = this.url.read(cx).value().trim().to_owned();
                        if url.trim().is_empty() {
                            this.notice = "请填写视频链接".into();
                            cx.notify();
                            return;
                        }
                        this.submit(
                            json!({"op": SCREEN_OPS[1],"objectID":this.selected_screen,"url":url}),
                            cx,
                        );
                    })),
            )
            .child(div().w(px(PLAY_GAP)).flex_shrink_0())
            .child(
                ui::capsule_button("screen-stop", "停止")
                    .flex_1()
                    .h(px(ACTIONS_HEIGHT))
                    .disabled(disabled)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.submit(
                            json!({"op": SCREEN_OPS[2],"objectID":this.selected_screen}),
                            cx,
                        );
                    })),
            );
        let command_notice = text(&self.snapshot["screenVideo"], "commandNotice");
        let status = div()
            .flex_shrink_0()
            .min_h(px(STATUS_MIN_HEIGHT))
            .mt(px(STATUS_TOP))
            .text_size(px(ui_tokens::BODY))
            .text_color(rgba(STATUS_COLOR))
            .child(command_notice);
        // The selected screen's playlist item and clock, exactly as the host
        // publishes them. A screen the host has not reported yet shows nothing
        // rather than a fabricated 「播放列表 1/1」.
        let status_row = self
            .selected_screen
            .as_deref()
            .map(|id| screen_status(&self.snapshot, id).clone())
            .unwrap_or(Value::Null);
        let mut readout = div()
            .flex()
            .flex_col()
            .gap_2()
            .mt(px(ROWS_TOP))
            .min_h(px(ROWS_MIN_HEIGHT))
            .text_size(px(ui_tokens::BODY))
            .text_color(rgba(scene::TEXT));
        if let Some(playlist) = playlist_line(&status_row) {
            readout = readout.child(playlist);
        }
        if let Some(progress) = progress_line(&status_row) {
            readout = readout.child(progress);
        }
        div()
            .flex()
            .flex_col()
            .gap_3()
            .child(choice)
            .child(link)
            .child(actions)
            .child(status)
            .child(readout)
            .child(ui::muted(
                "支持视频、直播与 YouTube 播放列表。播放进度以屏幕回执为准。",
            ))
            .into_any_element()
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
                // `InboxPane` itself is the shared surface and is mounted whole,
                // so its own box is the only place its content can be stopped:
                // the media panel is 590×`panel_extent` and the extent it hands
                // this body is shorter than the detail column's floor (see
                // `the_media_body_is_shorter_than_the_inbox_detail_floor`), so
                // without this clip the column paints over the panel's pinned
                // notice row below it. Clipping here leaves the list's own
                // scrolling and the detail's hit-testing untouched.
                //
                // The id is what the geometry test reads: this box is the width
                // the panel really hands the pane, and the one the two columns
                // have to fit inside.
                div()
                    .id(INBOX_HOST_ID)
                    .w_full()
                    .flex_1()
                    .min_h_0()
                    .min_w_0()
                    .overflow_hidden()
                    .child(self.inbox_pane.clone())
                    .test_support()
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
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(ui::card_title(section_title(self.section)))
                    .child(
                        ui::icon_button(
                            "media-refresh",
                            IconName::RefreshCw,
                            "刷新",
                            false,
                            !(state["pending"] == true || self.section == 1),
                        )
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

    /// The header must read out the transport-selected section, so every
    /// section the transport (or a `ui.*.open` command) can name has a title.
    #[test]
    fn section_header_reads_out_every_ownable_section() {
        for (index, name) in SECTIONS.iter().enumerate() {
            let title = section_title(index);
            assert_ne!(title, "媒体", "{name} must have its own readout title");
            assert!(!title.is_empty());
        }
        assert_eq!(section_title(SECTIONS.len()), "媒体");
    }

    /// Regression guard for the user-reported defect: the media panel is one
    /// rail whose content is chosen by the transport, so it must never grow a
    /// second navigation entry. The source scan excludes this test module (it
    /// names the very symbols it forbids).
    #[test]
    fn media_panel_renders_no_pagination_control() {
        let source = include_str!("media_ui.rs");
        let production = source
            .split("#[cfg(test)]")
            .next()
            .expect("production source precedes the test module");
        for forbidden in ["TabBar", "Tab::new", "LABELS", "selected_index"] {
            assert!(
                !production.contains(forbidden),
                "media panel must not draw its own pagination ({forbidden})"
            );
        }
        // `section` has exactly one writer: the transport-driven setter. The
        // trailing space separates the assignment from `self.section == 1`.
        assert_eq!(production.matches("self.section = ").count(), 1);
        assert!(production.contains("pub fn select_section(&mut self, section: &str"));
    }

    /// Regression guard for the user-reported defect: the media panel is one
    /// surface mounted inside the floating bar's panel frame, and the frame's
    /// own row (音量 + slider + 歌词 + 小窗) is the **bar's** chrome
    /// (`shell_ui.rs` `media_controls`), not this surface's. This panel keeps
    /// exactly two header children — its section readout and its own refresh
    /// action — so the volume slider, the lyrics button and the window
    /// (小窗/全屏) controls must never reappear here.
    ///
    /// The full guard lands together with the `shell_ui.rs` fix; this half pins
    /// the panel side so the old row cannot be "fixed" by moving it back in.
    #[test]
    fn media_panel_draws_no_volume_lyrics_or_window_controls() {
        let source = include_str!("media_ui.rs");
        let production = source
            .split("#[cfg(test)]")
            .next()
            .expect("production source precedes the test module");
        for forbidden in [
            "音量",
            "Slider",
            "media-lyrics",
            "media-compact",
            "ui.lyrics.toggle",
            "ui.window.fullscreen",
            "ui.window.compact",
        ] {
            assert!(
                !production.contains(forbidden),
                "the media panel must not draw the floating bar's own row ({forbidden})"
            );
        }
        // The panel header is exactly the readout plus its refresh action.
        assert!(production.contains("ui::card_title(section_title(self.section))"));
        assert!(production.contains("\"media-refresh\""));
    }

    /// The shared `InboxPane` is mounted whole, so its host box is the only
    /// place its content can be stopped. The panel gives that box less height
    /// than the pane's detail column needs (next test), so the host must clip;
    /// without `.overflow_hidden()` the column paints out of the pane, over the
    /// panel's pinned notice row below it. The scan drops the test module, so
    /// only the production arm can satisfy it.
    #[test]
    fn the_inbox_body_is_clipped_inside_the_panel_box() {
        let source = include_str!("media_ui.rs");
        let production = source
            .split("#[cfg(test)]")
            .next()
            .expect("production source precedes the test module");
        let body = production
            .split("4 => (")
            .nth(1)
            .expect("the inbox section still has its own arm")
            .split(", false,")
            .next()
            .expect("the arm still carries its non-scrolling flag");
        assert!(
            body.contains(concat!(".overflow", "_hidden()")),
            "the inbox body must clip content to its own box, otherwise the pane \
             paints over the panel's notice row"
        );
        assert!(
            body.contains("self.inbox_pane.clone()"),
            "the clip must sit on the element that hosts the shared inbox pane"
        );
    }

    /// The clip above is load-bearing, and this is the arithmetic that says so:
    /// on the product's 720×482 window the media panel is `panel_extent` tall,
    /// and after the surface's padding, header and pinned notice row this body
    /// is shorter than the inbox detail column's own floor — so before the clip
    /// the column painted below itself and over that notice row. Every term is a
    /// shared token or a documented literal from `media_surface()`, so moving
    /// either side of the comparison moves the assertion.
    #[test]
    fn the_media_body_is_shorter_than_the_inbox_detail_floor() {
        use ui_tokens::{inbox, shell as bar, stage};
        // `panel_extent` at 720×482, then the media panel's own ceiling.
        let panel_height = (482.
            - bar::TRANSPORT_INSET * 2.
            - bar::TRANSPORT_HEIGHT
            - bar::COMPOSER_GAP)
            .min(stage::PANEL_MAX_HEIGHT);
        assert_eq!(panel_height, 374.);
        // `media_surface()`: `.p_4()` (16) all round, `.gap_3()` (12) between
        // the header, the body and the notice row. The header is the refresh
        // control; the notice row is one `CAPTION` line.
        let body_height = panel_height
            - 2. * 16.
            - scene::CONTROL_HEIGHT
            - 2. * 12.
            - ui_tokens::CAPTION * 1.25;
        // The detail column's floor with the empty state the inbox opens in:
        // the pane's own inset, the empty block's padding and icon, the
        // placeholder line, and the read-only detail's `DETAIL_MIN_HEIGHT`.
        // (The empty block's title only makes this floor larger.)
        let detail_floor = inbox::PANEL_INSET * 2.
            + 2. * inbox::STACK_GAP
            + 16.
            + inbox::STACK_GAP
            + inbox::PLACEHOLDER_SIZE * 1.25
            + inbox::STACK_GAP
            + inbox::DETAIL_MIN_HEIGHT;
        assert!(
            body_height < detail_floor,
            "the media body ({body_height} pt) must stay shorter than the inbox detail floor \
             ({detail_floor} pt); if that ever stops being true, the clip in the section arm is \
             no longer the thing keeping the content inside the panel"
        );
    }

    /// The whole chain in a real GPUI window: the shell's panel at the report's
    /// 720×482 window, 「消息」 selected, and the **real prepared bounds** of the
    /// box the panel hands the pane ([`INBOX_HOST_ID`]) together with both
    /// `InboxPane` columns inside it.
    ///
    /// The defect this pins (2026-10-09, 「消息面板没显示完整，左边缺一块」):
    /// `panel_extent` gave the media panel
    /// `min(viewport − 2 × TRANSPORT_INSET, stage::PANEL_MAX_WIDTH)` = 590 pt,
    /// `media_surface`'s own 16 pt padding took that to 558 pt for the pane, and
    /// the pane's two column floors need `inbox::PANE_MIN_WIDTH` (580 pt). The
    /// panel could not show both columns at once, and because its content is
    /// pinned to the bottom-right corner (`panel_container`'s `items_end`) the
    /// missing strip came off the **left** of the message surface.
    ///
    /// Nothing here reads a constant as the measured width: `host`, `list` and
    /// `detail` are the boxes GPUI really laid out in the window this test
    /// opened.
    #[test]
    fn the_media_panel_hands_the_inbox_a_box_that_holds_both_columns() {
        use gmgn_gpui_ui::ui_tokens::inbox;
        use gpui_kit::test::TestWindowExt as _;
        use gpui_kit::{AppContext, TestAppContext};
        let commands: UiCommandQueue = std::rc::Rc::new(std::cell::RefCell::new(
            std::collections::VecDeque::new(),
        ));
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let handle = cx.open_window(size(px(720.), px(482.)), move |window, cx| {
            let media = cx.new(|cx| MediaPane::new(window, cx, commands.clone()));
            media.update(cx, |pane, cx| {
                pane.update_snapshot(
                    &json!({"world":{"worldID":"world-a"},
                        "inbox":{"status":"completed","pending":false,"entries":[
                            {"taskKey":"t1","lastEventID":"e1","title":"生成完成","status":"3/3",
                             "detail":"已完成 3/3","isRead":false,"updatedAt":1_700_000_000}]}}),
                    window,
                    cx,
                );
                pane.select_section("inbox", cx);
            });
            let panes = vec![("音乐与空间".to_string(), media.into())];
            let shell = cx.new(|cx| crate::shell_ui::ShellPane::new(window, cx, commands.clone(), panes));
            shell.update(cx, |shell, cx| shell.open_panel("音乐与空间", window, cx));
            gpui_kit::base::Root::new(shell, window, cx)
        });
        cx.update_window(handle.into(), |_, window, cx| {
            window.render_frame(cx);
            let host = window.find(INBOX_HOST_ID).bounds();
            let list = window.find("resident.system-inbox.list").bounds();
            let detail = window.find("resident.system-inbox.detail").bounds();
            eprintln!(
                "[inbox-fit] viewport=720x482 host={:?} list={:?} detail={:?}",
                (
                    f32::from(host.origin.x),
                    f32::from(host.origin.y),
                    f32::from(host.size.width),
                    f32::from(host.size.height)
                ),
                (
                    f32::from(list.origin.x),
                    f32::from(list.origin.y),
                    f32::from(list.size.width),
                    f32::from(list.size.height)
                ),
                (
                    f32::from(detail.origin.x),
                    f32::from(detail.origin.y),
                    f32::from(detail.size.width),
                    f32::from(detail.size.height)
                ),
            );
            // 1. The panel really gave the pane the box it derived: the width
            //    `panel_box` decided, minus the media surface's own padding, at
            //    the panel's own left edge. This is the assertion the old width
            //    policy fails — the panel was 590 pt, so the box the pane could
            //    have had is 558 pt, and it measured 640 (its own content width)
            //    instead, hanging 83 pt off the panel's left.
            let (panel_width, _) = crate::shell_ui::panel_box(
                size(px(720.), px(482.)),
                false,
                "音乐与空间",
            );
            let panel_right = 720. - gmgn_gpui_ui::ui_tokens::shell::TRANSPORT_INSET;
            let inner_width = panel_width - 2. * SURFACE_PADDING - 2. * SURFACE_BORDER;
            assert_eq!(
                f32::from(host.size.width),
                inner_width,
                "the message body must be the panel's inner width ({inner_width} pt), not its \
                 own content width: host={:?}",
                f32::from(host.size.width)
            );
            assert_eq!(
                f32::from(host.origin.x),
                panel_right - panel_width + SURFACE_PADDING + SURFACE_BORDER,
                "the message body must start at the panel's left padding, not left of the \
                 panel: host={:?}",
                f32::from(host.origin.x)
            );
            // …which is at least the pane's own floor: both column floors plus
            // the split's insets.
            assert!(
                host.size.width >= px(inbox::PANE_MIN_WIDTH),
                "the panel hands the inbox {} pt, but the pane's own floor is {} pt \
                 (list floor {} + detail floor {} + split insets {})",
                f32::from(host.size.width),
                inbox::PANE_MIN_WIDTH,
                inbox::LIST_MIN_WIDTH,
                inbox::DETAIL_MIN_WIDTH,
                2. * inbox::PANEL_INSET,
            );
            // 2. The two columns really fit that box: the list gives way down to
            //    its floor, the detail keeps its own, and neither is painted
            //    outside the host box (which is what clips them).
            assert!(
                list.origin.x >= host.origin.x,
                "the list starts inside the host box: host={host:?} list={list:?}"
            );
            assert!(
                list.size.width >= px(inbox::LIST_MIN_WIDTH),
                "the list keeps its floor: list={:?}",
                f32::from(list.size.width)
            );
            assert!(
                detail.size.width >= px(inbox::DETAIL_MIN_WIDTH),
                "the detail keeps its floor: detail={:?}",
                f32::from(detail.size.width)
            );
            assert!(
                detail.origin.x >= list.origin.x + list.size.width,
                "the two columns do not overlap: list={list:?} detail={detail:?}"
            );
            assert!(
                detail.origin.x + detail.size.width <= host.origin.x + host.size.width,
                "the detail column is painted inside the panel's host box: \
                 detail ends at {} but the host box ends at {}",
                f32::from(detail.origin.x + detail.size.width),
                f32::from(host.origin.x + host.size.width),
            );
            // 3. The box is inside the panel *and* the panel is inside the
            //    window. The panel is pinned to the bottom-right corner, so an
            //    over-wide pane used to take its right edge from that corner and
            //    push the box off the panel's left — the strip the report saw
            //    missing.
            assert!(
                f32::from(host.origin.x) >= panel_right - panel_width,
                "the message surface must not start left of the panel's own left edge: host={:?}",
                f32::from(host.origin.x)
            );
            assert!(
                host.origin.x + host.size.width <= px(panel_right),
                "the message surface must stay inside the window's right inset: host={host:?}"
            );
        })
        .unwrap();
    }

    /// The backend already publishes the playlist the 电视 panel was built to
    /// drive: `screenVideo.video.screens[]` carries `playlistIndex`,
    /// `playlistCount`, `playlistRevision`, `currentSeconds`, `durationSeconds`
    /// and `isLive` (`UnityScreenVideoBridge.swift:387-401`). Until this change
    /// **no** Rust UI read any of those keys, so the panel could not say which
    /// item of a playlist was playing. This is the field-level wire.
    #[test]
    fn the_tv_panel_projects_every_playlist_field_the_host_publishes() {
        let host = json!({
            "screenVideo": {
                "screens": [{"objectID": "tv", "name": "电视", "state": "播放中 · 播放列表 2/10",
                             "playing": true}],
                "commandNotice": "",
                "video": {
                    "screens": [{
                        "objectID": "tv", "state": "播放中",
                        "currentSeconds": 83.7, "durationSeconds": 245.2,
                        "playbackRate": 1, "timeControlStatus": "playing",
                        "waitingReason": null, "decodedFrames": 1234,
                        "playbackEndCount": 1, "isLive": false,
                        "playlistIndex": 1, "playlistCount": 10, "playlistRevision": 3
                    }],
                    "pendingBoundVideo": null
                }
            }
        });
        let projected = screen_status_projection(&host);
        assert_eq!(projected.len(), 1, "one row per published screen");
        let row = &projected[0];
        for key in [
            "playlistIndex",
            "playlistCount",
            "playlistRevision",
            "currentSeconds",
            "durationSeconds",
            "isLive",
        ] {
            assert!(
                row.get(key).is_some(),
                "the projection must carry `{key}`; it carried {row}"
            );
        }
        assert_eq!(row["playlistIndex"], 1);
        assert_eq!(row["playlistCount"], 10);
        assert_eq!(row["playlistRevision"], 3);
        // The clock is quantized: the panel draws m:ss, and a 60 Hz float would
        // notify the pane 60 times a second for no visible change.
        assert_eq!(row["currentSeconds"], 83.0);
        assert_eq!(row["durationSeconds"], 245.0);
        assert_eq!(row["isLive"], false);
        // …and it is the row the panel actually looks up.
        let live = json!({"screenVideo": {"status": projected}});
        let found = screen_status(&live, "tv");
        assert_eq!(found["playlistRevision"], 3);
        assert!(
            screen_status(&live, "gone").is_null(),
            "an unknown screen reads as Null, never as another screen's playlist"
        );
    }

    /// 「播放列表 2/10」 is the host's own index/count — the panel never re-counts
    /// a playlist it did not import, and a screen that is not on a playlist shows
    /// no line at all.
    #[test]
    fn the_playlist_and_clock_lines_are_the_hosts_own_numbers() {
        let on_playlist = json!({"playlistIndex": 1, "playlistCount": 10,
            "currentSeconds": 83.0, "durationSeconds": 245.0, "isLive": false});
        assert_eq!(playlist_line(&on_playlist).as_deref(), Some("播放列表 2/10"));
        assert_eq!(progress_line(&on_playlist).as_deref(), Some("1:23 / 4:05"));
        assert_eq!(clock(0.), "0:00");
        assert_eq!(clock(59.9), "0:59");
        assert_eq!(clock(60.), "1:00");
        assert_eq!(clock(3599.), "59:59");
        assert_eq!(clock(f64::NAN), "0:00");

        // Live: no clock, one word.
        let live = json!({"isLive": true, "currentSeconds": 12.0, "durationSeconds": null});
        assert_eq!(progress_line(&live).as_deref(), Some("直播"));

        // Not a playlist / nothing reported yet: no invented 「1/1」.
        assert_eq!(playlist_line(&json!({"playlistCount": 0})), None);
        assert_eq!(playlist_line(&json!({"playlistCount": null})), None);
        assert_eq!(
            playlist_line(&json!({"playlistIndex": 0, "playlistCount": 1})).as_deref(),
            Some("播放列表 1/1"),
            "a one-item playlist the host really imported is still a playlist"
        );
        assert_eq!(progress_line(&json!({"currentSeconds": null})), None);
        assert_eq!(
            progress_line(&json!({"currentSeconds": 30.0, "durationSeconds": 0.0})).as_deref(),
            Some("0:30"),
            "a duration the decoder has not reported is not turned into 0:00"
        );
    }

    /// The panel sends only ops the host already dispatches, and it sends them
    /// with the fields `UnityScreenVideoBridge.command` validates. There is no
    /// skip-to-item op in the backend, so 上一集/下一集 must not exist here.
    #[test]
    fn the_tv_panel_only_sends_the_hosts_existing_screen_ops() {
        assert_eq!(
            SCREEN_OPS,
            ["screen.list", "screen.play", "screen.stop"],
            "the panel's op set is the host's supported set, not a new one"
        );
        let play = json!({"op": SCREEN_OPS[1], "objectID": "tv", "url": "https://example.test/v"});
        assert!(play["objectID"].is_string() && play["url"].is_string());
        let stop = json!({"op": SCREEN_OPS[2], "objectID": "tv"});
        assert!(stop["objectID"].is_string());
        for op in SCREEN_OPS {
            assert!(
                !op.starts_with("screen.next")
                    && !op.starts_with("screen.previous")
                    && !op.starts_with("screen.playlist"),
                "no playlist-stepping op exists in `UnityScreenVideoBridge.supportedCommands`"
            );
        }
    }

    /// The 电视 panel's own metrics are the original `ScreenVideo.uss`
    /// selectors, so a re-layout that drifts from the original numbers fails
    /// here instead of only being visible on a device.
    #[test]
    fn the_tv_panel_metrics_are_the_original_stylesheet_values() {
        // `.screen-video-choice { margin-bottom: 8px }`.
        assert_eq!(CHOICE_GAP, 8.);
        // `.screen-video-url .unity-base-field__label { margin-bottom: 4px }`.
        assert_eq!(URL_LABEL_GAP, 4.);
        // `… .unity-base-field__input { height: 36px; padding: 6px 10px }`.
        assert_eq!(FIELD_HEIGHT, 36.);
        // `.screen-video-actions { height: 36px; margin-top: 8px }` and
        // `.screen-video-play { margin-right: 8px }`.
        assert_eq!(ACTIONS_HEIGHT, 36.);
        assert_eq!(ACTIONS_TOP, 8.);
        assert_eq!(PLAY_GAP, 8.);
        // `.screen-video-status { min-height: 20px; margin-top: 8px;
        //  color: #ff9c94 }` — the tint is the pinned overlay danger token, not
        //  a raw literal and not the system theme's.
        assert_eq!(STATUS_MIN_HEIGHT, 20.);
        assert_eq!(STATUS_TOP, 8.);
        assert_eq!(STATUS_COLOR, ui_tokens::stage::DANGER_TEXT);
        // `.screen-video-rows { min-height: 20px; margin-top: 8px }`.
        assert_eq!(ROWS_MIN_HEIGHT, 20.);
        assert_eq!(ROWS_TOP, 8.);
    }
}
