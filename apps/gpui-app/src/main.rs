use gmgn_gpui_ui::{ResidentChatPane, state::{ChatCommand, TranscriptLine}};
use gpui_kit::component::{button::*, *};
use gpui_kit::component::menu::{DropdownMenu,PopupMenuItem};
use gmgn_gpui_ui::settings::AgentSettingsPane;
use gmgn_gpui_ui::inbox::InboxPane;
use gmgn_gpui_ui::stage_panels::{StagePanelsPane,StageProgramRailPane,ResidentPropEditorPane};
use gmgn_gpui_ui::lyrics::{StageLyricsPane,StageBoundVideoPromptPane};
use gpui_kit::*;
use gpui_kit::assets::IconName;
use gpui_kit::prelude::FluentBuilder;
use gmgn_gpui_ui::primitives as ui;
use gmgn_gpui_ui::shell::{self, TransportControl};
use gmgn_gpui_ui::ui_tokens::chat as chat_metrics;
use gmgn_gpui_ui::ui_tokens::scene as scene_tokens;
use gmgn_gpui_ui::ui_tokens::shell as shell_metrics;
use gmgn_gpui_ui::ui_tokens::stage as stage_metrics;
use gmgn_gpui_ui::ui_tokens::{BODY as BODY_SIZE, BODY_LINE_HEIGHT, CAPTION as CAPTION_SIZE, FONT_FAMILY};
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::{cell::RefCell, rc::Rc, time::Duration,ffi::{c_void,c_char,CStr}};
mod host_events;
mod product_host;
mod program_backdrop;
mod lyrics_layer;
mod system_symbol;
use product_host::ProductHost;
gpui_kit::actions!(gmgn_product, [Quit,ShowSettings,ShowActivities,ShowLiveCam,EscapeStage]);

fn window_still_registered<T: PartialEq>(cached: T, live: impl IntoIterator<Item=T>) -> bool {
    live.into_iter().any(|id| id == cached)
}

fn modal_owns_scene_input(menu: bool, dialog: bool, sheet: bool) -> bool {
    menu || dialog || sheet
}

#[derive(Debug, PartialEq)]
struct ProductErrorNotice { revision: u64, title: String, message: String }

fn next_error_notice(value: &serde_json::Value, consumed: u64) -> Option<ProductErrorNotice> {
    let revision = value["revision"].as_u64()?;
    if revision <= consumed { return None; }
    let title = value["title"].as_str()?;
    let message = value["message"].as_str()?;
    if title.trim().is_empty() { return None; }
    Some(ProductErrorNotice { revision, title: title.to_owned(), message: message.to_owned() })
}

fn user_status_notice(message: &str) -> String {
    if message.contains("原物件已摆放") {
        "物件已经摆好了，无需再次摆放。".into()
    } else if message.contains("revision_conflict") {
        "空间有新的保存记录，这次修改尚未保存，仍保留在当前窗口。请稍后重试保存。".into()
    } else {
        message.to_owned()
    }
}
unsafe extern "C" {
    fn gmgn_gpui_bitmap_drop_region(view:*mut c_void,x:f64,y:f64,w:f64,h:f64,enabled:i32);
    fn gmgn_gpui_take_bitmap_drop(view:*mut c_void)->*mut c_char;
    fn gmgn_gpui_bitmap_drop_string_free(value:*mut c_char);
}

/// The only two shell values the shared foundation deliberately does **not**
/// own.
///
/// Everything else this module used to carry now lives in `ui_tokens::shell`
/// (transport bar + divider, destination frame/border/tint/glyph size, task
/// banners, unread badge, screen banner and the Live Cam control column) and is
/// referenced through `shell_metrics`; `ui_tokens::stage`/`scene` keep the shared
/// control row and fixed dark palette. Each entry below names why it cannot move:
mod chrome {
    /// Cleared window background: the scene is composited natively underneath,
    /// so the GPUI root must stay fully transparent. This is a GPUI/AppKit
    /// compositing fact with no Swift `Color` to copy, so it has no
    /// `ui_tokens` source to cite.
    pub const WINDOW_CLEAR: u32 = 0x00000000;

    /// Scroll ceiling of the whole notice stack (host-side; the original's
    /// `maximumHeight: 132` is unused by the current `WishMachineTaskStatusView`).
    /// This is host scroll policy rather than an original reading, so it stays
    /// out of the foundation's original-sourced metrics.
    pub const TASK_MAX_HEIGHT: f32 = 220.;
}

/// The original transport row, in order (`StageWindowController.swift:2823-2828`):
/// 节目 ｜ 上首 ｜ 播放 ｜ 下首 ｜ ⋮ ｜ 语音 ｜ 聊天 ｜ 通知 ｜ 装修 ｜ 屏幕操作 ｜
/// 舞台设置 ｜ 窗口. The divider sits after 下首 (`:2868`).
const TRANSPORT_CONTROLS: [(&str, &str, &str); 11] = [
    ("program", "节目", "program"),
    ("previous", "上首", "previousTrack"),
    ("play", "播放", "togglePlayback"),
    ("next", "下首", "nextTrack"),
    ("voice", "语音", "voice"),
    ("chat", "聊天", "chat"),
    ("inbox", "通知", "showNotifications"),
    ("props", "装修", "toggleDecoration"),
    ("screen", "屏幕操作", "screen"),
    ("visual", "舞台设置", "visual"),
    ("mode", "窗口", "mode"),
];

/// The Live Cam entries, in order (`LiveCamPanel.swift:689-712`): 空间 ｜ 播放器
/// ｜ 文字聊天 ｜ 通知 ｜ 语音 ｜ 设置.
const COMPACT_CONTROLS: [(&str, &str, &str); 6] = [
    ("space", "空间", "showStage"),
    ("player", "音乐", "showPlayer"),
    ("chat", "聊天", "chat"),
    ("inbox", "通知", "showNotifications"),
    ("voice", "语音", "voice"),
    ("settings", "设置", "settings"),
];

/// One transport control's width (`StageOverlayView.swift:2686-2689`).
///
/// The host no longer derives this itself: [`TransportControl::slot_width`] in
/// `gmgn_gpui_ui::shell` is the one derivation, and `shell::transport_width`
/// sums it to place the bar.

/// The Live Cam composer height, read through the shared chat surface so the
/// host and the pane cannot answer this differently
/// (`apps/gpui-ui/src/chat.rs::compact_composer_height`, from
/// `LiveCamPanel.swift:744-749`: 70 pt idle, 140 pt with a pending attachment).
fn compact_composer_height(runtime_state: &serde_json::Value) -> f32 {
    let mut state = gmgn_gpui_ui::state::ChatState::default();
    if runtime_state["attachments"].as_array().is_some_and(|images| !images.is_empty()) {
        state.attachments.push(gmgn_gpui_ui::state::ChatAttachment {
            id: String::new(),
            file_name: String::new(),
            preview_path: None,
            thumbnail_png: None,
        });
    }
    state.attachments_preparing = runtime_state["attachmentsPreparing"].as_bool() == Some(true);
    state.attachments_error = runtime_state["attachmentError"]
        .as_str()
        .filter(|error| !error.is_empty())
        .map(str::to_owned);
    gmgn_gpui_ui::chat::compact_composer_height(&state)
}

/// Where the resident composer sits, as `[x, y, width, height]`.
///
/// Every number comes from the shared tokens and the shared compact height; the
/// host keeps no second copy of the composer's size, and the pane itself caps at
/// `chat_metrics::PANEL_MAX_WIDTH/MAX_HEIGHT`. Anchors in the original:
/// trailing/leading 22, bottom = transport top − 16, top ≥ 22
/// (`StageWindowController.swift:1526-1531`), and in the Live Cam window
/// leading 10, bottom 10, trailing at the reserved control column
/// (`LiveCamPanel.swift:880-890`).
fn composer_frame(compact: bool, width: f32, height: f32, compact_height: f32) -> [f32; 4] {
    if compact {
        let right = shell_metrics::COMPACT_CONTENT_RIGHT;
        let available = (height - shell_metrics::COMPACT_MARGIN - compact_height).max(0.);
        [
            shell_metrics::COMPACT_MARGIN,
            available,
            (width - right - shell_metrics::COMPACT_MARGIN).max(0.),
            compact_height,
        ]
    } else {
        let bottom = shell_metrics::TRANSPORT_INSET + shell_metrics::TRANSPORT_HEIGHT + shell_metrics::COMPOSER_GAP;
        let w = (width - 2. * shell_metrics::TRANSPORT_INSET).clamp(0., chat_metrics::PANEL_MAX_WIDTH);
        let h = (height - bottom - shell_metrics::TASK_FEEDBACK_INSET).clamp(0., chat_metrics::PANEL_MAX_HEIGHT);
        [width - shell_metrics::TRANSPORT_INSET - w, height - bottom - h, w, h]
    }
}
fn inbox_unread(state:&serde_json::Value)->usize {
    state["inbox"]["entries"].as_array().map_or(0,|entries|entries.iter().filter(|entry|entry["isRead"].as_bool()==Some(false)).count())
}
fn latest_reply_revision(state:&serde_json::Value)->Option<String> {
    if let Some(reply)=state["reply"].as_str().filter(|reply|!reply.trim().is_empty()) {
        return Some(format!("{}:{}:{}",state["contextID"].as_str().unwrap_or(""),state["replyRevision"],reply));
    }
    let reply=state["transcript"].as_array()?.iter().rev().find(|line|line["role"].as_str()==Some("agent"))?;
    Some(format!("{}:{}:{}",state["contextID"].as_str().unwrap_or(""),reply["turnID"].as_str().unwrap_or(""),reply["text"].as_str()?))
}
fn compact_reply_text(state:&serde_json::Value, transcript:&[TranscriptLine])->Option<String> {
    state["reply"].as_str().map(str::trim).filter(|text|!text.is_empty()).map(str::to_owned)
        .or_else(||transcript.iter().rev().find(|line|line.speaker=="居民").map(|line|line.text.clone()))
}
/// The expanded Live Cam reply: the whole history, plus the background reply
/// when it is not already the history's last resident line. Both decisions come
/// from the shared chat surface (`chat::plain_text`/`chat::standalone_reply`),
/// so the host and the pane label a notice exactly the same way.
fn expanded_reply_text(transcript:&[TranscriptLine], latest:&str)->String {
    let content=gmgn_gpui_ui::chat::plain_text(transcript);
    match gmgn_gpui_ui::chat::standalone_reply(latest,transcript) {
        Some(standalone) if content.is_empty()=>standalone,
        Some(standalone)=>{let mut content=content;content.push_str("\n\n");content.push_str(&standalone);content}
        None=>content,
    }
}
/// Kit icons for the transport and Live Cam entries.
///
/// Kit ships the whole Lucide set, so each kit icon names the original SF Symbol
/// it replaces (`StageWindowController.swift:2955-3760`, `LiveCamPanel.swift:689-712`).
/// `props`/`screen` used to fall back to `Package`/`Monitor`, which describe a
/// box and a display rather than the original `square.stack.3d.up`/`hand.tap`.
fn control_icon(id:&str)->IconName {
    match id {
        // cube.transparent · music.note · music.note.list
        "space"=>IconName::Globe,"player"=>IconName::Music,"program"=>IconName::FileText,
        // backward.end.fill · forward.end.fill · play.fill/pause.fill
        "previous"=>IconName::ChevronLeft,"next"=>IconName::ChevronRight,"play"=>IconName::Play,
        // mic.fill · bubble.left · envelope.badge
        "voice"=>IconName::Mic,"chat"=>IconName::Bot,"inbox"=>IconName::Bell,
        // square.stack.3d.up · hand.tap · slider.horizontal.3 · window mode
        "props"=>IconName::SquareStack,"screen"=>IconName::MousePointerClick,"visual"=>IconName::Settings,
        "mode"=>IconName::Maximize,_=>IconName::Settings,
    }
}
/// `StageVoiceButton.setState` (`StageWindowController.swift:3547-3576`): the
/// glyph follows the realtime voice state, not only the local press.
fn voice_icon(state:Option<&str>)->IconName {
    match state.unwrap_or("disconnected") {
        // hourglass
        state if state.starts_with("connecting")=>IconName::Hourglass,
        // waveform.circle.fill
        state if state.starts_with("listening")=>IconName::AudioWaveform,
        // speaker.wave.2.fill
        state if state.starts_with("speaking")=>IconName::Volume2,
        // exclamationmark.triangle.fill
        state if state.starts_with("failed")=>IconName::TriangleAlert,
        _=>IconName::Mic,
    }
}
/// The 窗口 entry is a two-state control (`StageWindowMode.swift:5-21`):
/// `arrow.up.left.and.arrow.down.right` + "进入全屏" while windowed,
/// `arrow.down.right.and.arrow.up.left` + "退出全屏" while full screen. Kit has
/// the Lucide `maximize`/`minimize` pair for exactly that.
fn window_mode_content(fullscreen:bool)->(IconName,&'static str) {
    if fullscreen {(IconName::Minimize,"退出全屏")} else {(IconName::Maximize,"进入全屏")}
}

struct GMGNProductUI {
    host: Rc<RefCell<Option<ProductHost>>>,
    pane: Entity<ResidentChatPane>,
    settings_pane: Entity<AgentSettingsPane>,
    settings_window: Option<WindowHandle<gpui_kit::base::Root>>,
    inbox_pane: Entity<InboxPane>,
    inbox_window: Option<WindowHandle<gpui_kit::base::Root>>,
    stage_pane: Entity<StagePanelsPane>,
    stage_panel_open: bool,
    program_pane: Entity<StageProgramRailPane>,
    program_open: bool,
    program_backdrop: Rc<RefCell<Option<program_backdrop::ProgramBackdrop>>>,
    lyrics_layer: Rc<RefCell<Option<lyrics_layer::LyricsLayer>>>,
    prop_pane: Entity<ResidentPropEditorPane>,
    lyrics_pane:Entity<StageLyricsPane>,
    lyrics_error_logged: Option<String>,
    bound_video_pane:Entity<StageBoundVideoPromptPane>,
    props_open: bool,
    chat_open: bool,
    composer_focus_pending: bool,
    voice_held: bool,
    pending: Option<u64>,
    accepted: bool,
    transcript: Vec<TranscriptLine>,
    compact: bool,
    core_notice: Option<String>,
    runtime_state: serde_json::Value,
    surface_mounted: bool,
    navigation_revision:u64,
    error_notice_revision:u64,
    main_window:Rc<RefCell<Option<AnyWindowHandle>>>,
    profile_switch_pending:bool,
    dismissed_reply_revision:Option<String>,
    player_menu_open:bool,
    program_visibility_reported:Option<bool>,
    _poll: Task<()>,
}

impl GMGNProductUI {
    fn sync_lyrics_layer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.compact || !self.surface_mounted {
            self.lyrics_layer.borrow_mut().take();
            return;
        }
        if self.lyrics_layer.borrow().is_some() { return; }
        let Ok(handle)=window.window_handle() else {return;};
        let RawWindowHandle::AppKit(handle)=handle.as_raw() else {return;};
        let Some(layer)=(unsafe {lyrics_layer::LyricsLayer::new(handle.ns_view.as_ptr())}) else {return;};
        *self.lyrics_layer.borrow_mut()=Some(layer);
        let context=self.lyrics_layer.clone();
        self.lyrics_pane.update(cx,|pane,_|pane.set_gpu_renderer(Rc::new(move |frame| {
            context.borrow_mut().as_mut().is_some_and(|layer|layer.apply(frame))
        })));
    }
    fn clear_program_backdrop(&mut self, cx: &mut Context<Self>) {
        self.program_pane.update(cx, |pane,cx| pane.set_native_material_renderer(None,cx));
        self.program_backdrop.borrow_mut().take();
    }
    fn sync_program_backdrop(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.compact || !self.program_open || !self.surface_mounted {
            if self.program_backdrop.borrow().is_some() { self.clear_program_backdrop(cx); }
            return;
        }
        if self.program_backdrop.borrow().is_some() { return; }
        let Ok(handle)=window.window_handle() else {return;};
        let RawWindowHandle::AppKit(handle)=handle.as_raw() else {return;};
        let Some(backdrop)=(unsafe {program_backdrop::ProgramBackdrop::new(handle.ns_view.as_ptr())}) else {return;};
        *self.program_backdrop.borrow_mut()=Some(backdrop);
        let context=self.program_backdrop.clone();
        self.program_pane.update(cx, |pane,cx| pane.set_native_material_renderer(Some(Rc::new(move |frame| {
            if frame.cards.is_empty() {
                return context.borrow_mut().as_mut().is_some_and(|backdrop|backdrop.clear());
            }
            let cards=frame.cards.iter().map(|card|program_backdrop::BackdropCard {
                width:card.width,height:card.height,radius:card.radius,opacity:card.opacity,priority:card.priority as f64,matrix:card.matrix,
            }).collect::<Vec<_>>();
            context.borrow_mut().as_mut().is_some_and(|backdrop|backdrop.set_fade_fraction(frame.fade_fraction)&&backdrop.apply(&cards,frame.viewport))
        })),cx));
    }
    fn fail(&mut self, id: u64, notice: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.pane.update(cx, |pane, cx| pane.failed(id, notice.into(), window, cx));
        self.pending = None;
        self.accepted = false;
    }
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Ok(handle)=HasWindowHandle::window_handle(window) {
            if let RawWindowHandle::AppKit(handle)=handle.as_raw() {
                for _ in 0..4 {
                    let packet=unsafe{gmgn_gpui_take_bitmap_drop(handle.ns_view.as_ptr())};
                    if packet.is_null(){break;}
                    let command=unsafe{serde_json::from_slice::<serde_json::Value>(CStr::from_ptr(packet).to_bytes())};
                    unsafe{gmgn_gpui_bitmap_drop_string_free(packet)};
                    let accepted=command.ok().filter(|command|command["op"].as_str()==Some("chat.attachments.bitmap"))
                        .is_some_and(|command|self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&command)));
                    if !accepted{self.core_notice=Some("这张拖入的图片未能导入，请重试。".into());cx.notify();}
                }
            }
        }
        if self.program_visibility_reported!=Some(self.program_open) {
            if self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&serde_json::json!({"op":"stage.overlay.state","isProgramRailVisible":self.program_open}))) {
                self.program_visibility_reported=Some(self.program_open);
            }
        }
        let stage_commands=self.stage_pane.update(cx,|pane,_|pane.take_commands());
        let program_commands=self.program_pane.update(cx,|pane,_|pane.take_commands());
        let prop_commands=self.prop_pane.update(cx,|pane,_|pane.take_commands());
        let bound_commands=self.bound_video_pane.update(cx,|pane,_|pane.take_commands());
        for command in stage_commands.into_iter().chain(program_commands).chain(prop_commands).chain(bound_commands) {
            if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&command)) {
                self.core_notice=Some("场景操作尚未确认完成，请检查当前状态。".into());cx.notify();
            }
        }
        let inbox_commands=self.inbox_pane.update(cx,|pane,_|pane.take_commands());
        for command in inbox_commands {
            if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&command)) {
                self.core_notice=Some("系统消息操作未完成，请重试。".into());cx.notify();
            }
        }
        let settings_commands=self.settings_pane.update(cx, |pane,_|pane.take_commands());
        for command in settings_commands {
            if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&command)) {
                self.core_notice=Some("设置操作尚未确认完成，请检查当前配置。".into());cx.notify();
            }
        }
        if !self.surface_mounted {
            if let Ok(handle) = window.window_handle() {
                if let RawWindowHandle::AppKit(handle) = handle.as_raw() {
                    if let Some(host) = self.host.borrow_mut().as_mut() {
                        self.surface_mounted = host.mount(handle.ns_view.as_ptr(), self.compact);
                        if self.surface_mounted {
                            eprintln!("GMGN_GPUI_PRODUCT_SURFACE mounted=true compact={}", self.compact);
                            self.core_notice = None;
                            cx.notify();
                        }
                    }
                }
            }
            if !self.surface_mounted { self.core_notice = Some("正在连接原应用场景…".into()); }
        }
        let commands = self.pane.update(cx, |pane, _| pane.take_commands());
        for command in commands {
            match command {
                ChatCommand::Send { request_id, text, attachment_ids } => {
                    self.pending = Some(request_id);
                    self.accepted = false;
                    let sent = self.host.borrow().as_ref().is_some_and(|host| {
                        host.settings_command(&serde_json::json!({"op":"chat.send","requestID":request_id,"text":text,"attachmentIDs":attachment_ids}))
                    });
                    eprintln!("GMGN_GPUI_SUBMIT request_id={request_id} accepted={sent}");
                    if !sent { self.fail(request_id, "当前应用未能接收这条消息，文字已保留。", window, cx); }
                }
                ChatCommand::Cancel { request_id } => {
                    if let Some(host) = self.host.borrow().as_ref() { host.cancel(request_id); }
                    self.pending = None;
                    self.accepted = false;
                }
                command => {
                    let value=match command {
                        ChatCommand::PickAttachments=>serde_json::json!({"op":"chat.attachments.pick"}),
                        ChatCommand::PasteAttachments=>serde_json::json!({"op":"chat.attachments.paste"}),
                        ChatCommand::ImportAttachments {paths}=>serde_json::json!({"op":"chat.attachments.import","paths":paths}),
                        ChatCommand::RemoveAttachment {id}=>serde_json::json!({"op":"chat.attachments.remove","id":id}),
                        ChatCommand::BeginVoice=>serde_json::json!({"op":"chat.voice.begin"}),
                        ChatCommand::FinishVoice=>serde_json::json!({"op":"chat.voice.finish"}),
                        ChatCommand::StopSpeech=>serde_json::json!({"op":"chat.speech.stop"}),
                        ChatCommand::StopTask=>serde_json::json!({"op":"chat.task.stop"}),
                        ChatCommand::FocusInput=>serde_json::json!({"op":"chat.focus"}),
                        _=>unreachable!(),
                    };
                    if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&value)) {
                        self.core_notice=Some("此操作暂未完成，请重试。".into());cx.notify();
                    }
                }
            }
        }
        let result = {
            let host = self.host.borrow();
            let Some(host) = host.as_ref() else { return; };
            host.update_visibility();
            host.poll().and_then(|bytes| host_events::parse(&bytes))
        };
        let Ok(batch) = result else {
            if let Some(id) = self.pending {
                if let Some(host) = self.host.borrow().as_ref() { host.cancel(id); }
                self.fail(id, "应用返回的对话状态无法读取，文字已保留。", window, cx);
            }
            return;
        };
        if !self.runtime_state.is_null() && self.runtime_state["contextID"] != batch.state["contextID"] {
            self.pane.update(cx, |pane, cx| pane.reset_context(window, cx));
            self.pending = None;
            self.accepted = false;
            self.transcript.clear();
        }
        for event in batch.events {
            eprintln!("GMGN_GPUI_EVENT request_id={} kind={} characters={}", event.id, event.kind,
                event.text.as_ref().map_or(0, |text| text.chars().count()));
            if self.pending != Some(event.id) { continue; }
            match event.kind.as_str() {
                "accepted" => {
                    self.accepted = true;
                    self.pane.update(cx, |pane, cx| pane.accepted(event.id, window, cx));
                }
                "reply" if self.accepted => {
                    if let Some(text) = event.text { self.pane.update(cx, |pane, cx| pane.reply(event.id, text, cx)); }
                    self.pending = None;
                    self.accepted = false;
                }
                "reply" => self.fail(event.id, "应用尚未确认接收，无法交付这条回复。", window, cx),
                "completed" if self.accepted => {
                    self.pane.update(cx, |pane, cx| pane.complete_without_reply(event.id, cx));
                    self.pending = None;
                    self.accepted = false;
                }
                "failure" | "cancelled" => self.fail(event.id, event.message.as_deref().unwrap_or("本次回复未完成。"), window, cx),
                "progress" => {
                    if let Some(text) = event.text { self.pane.update(cx, |pane, cx| pane.progress(event.id, text, cx)); }
                }
                _ => {}
            }
        }
        if self.runtime_state != batch.state {
            self.pane.update(cx,|pane,cx|pane.update_snapshot(batch.state.clone(),cx));
            self.inbox_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["inbox"].clone(),cx));
            self.stage_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["stage"].clone(),window,cx));
            self.program_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["stageProgramRail"].clone(),window,cx));
            self.prop_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["propEditor"].clone(),window,cx));
            self.lyrics_pane.update(cx,|pane,cx|{
                pane.set_visible(!self.compact,cx);
                pane.update_snapshot(batch.state["lyrics"].clone(),window,cx);
            });
            let lyrics_error = self.lyrics_pane.read(cx).render_error().map(str::to_owned);
            if lyrics_error != self.lyrics_error_logged {
                if let Some(error) = &lyrics_error { eprintln!("GMGN_LYRICS_RENDER_ERROR {error}"); }
                self.lyrics_error_logged = lyrics_error;
            }
            self.bound_video_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["boundVideoPrompt"].clone(),window,cx));
            if let Some(open)=batch.state["propEditor"]["isOpen"].as_bool() {self.props_open=open;}
            self.settings_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["settings"].clone(),window,cx));
            self.runtime_state = batch.state; cx.notify();
        }
        if !self.compact&&self.runtime_state["stage"]["presentation"]["chatAvailable"].as_bool()==Some(false){self.chat_open=false;}
        if self.runtime_state["stage"]["presentation"]["propsAvailable"].as_bool()==Some(false){self.props_open=false;}
        let navigation=self.runtime_state["uiNavigation"].clone();
        if let Some(revision)=navigation["revision"].as_u64().filter(|revision|*revision>self.navigation_revision) {
            self.navigation_revision=revision;
            match navigation["mode"].as_str() {
                Some("liveCam")=>self.switch_profile(true,None,window,cx),
                Some("space")=>self.switch_profile(false,Some("space"),window,cx),
                Some("player")=>self.switch_profile(false,Some("player"),window,cx),
                _=>{}
            }
            match navigation["panel"].as_str() {
                Some("presenceGuidance")=>self.show_presence_guidance(window,cx),
                Some("settings")=>self.open_settings_page(navigation["settingsPage"].as_str().unwrap_or("presence"),cx),
                Some("inbox")=>self.overlay_action("showNotifications",cx),
                _=>{}
            }
            if self.runtime_state["propEditor"]["isOpen"].as_bool()==Some(true) {
                self.props_open=true;self.chat_open=false;self.stage_panel_open=false;self.program_open=false;
            }
        }
        if self.transcript != batch.transcript {
            self.transcript = batch.transcript.clone();
            self.pane.update(cx, |pane, cx| pane.set_transcript(batch.transcript, cx));
        }
        if let Some(notice) = next_error_notice(&self.runtime_state["errorNotice"], self.error_notice_revision) {
            self.error_notice_revision = notice.revision;
            window.open_dialog(cx, move |dialog, _, _| {
                dialog.title(notice.title.clone()).w(px(460.))
                    .child(div().text_sm().child(notice.message.clone()))
                    .footer(div().flex().justify_end().child(
                        Button::new("product-error-close").label("关闭")
                            .on_click(|_, window, cx| window.close_dialog(cx))))
            });
        }
    }
    fn native_action(&mut self, action: &str, cx: &mut Context<Self>) {
        let success = self.host.borrow().as_ref().is_some_and(|host| host.action(action));
        if !success { self.core_notice = Some("这个原有功能入口暂未能打开，请检查应用启动状态。".into()); }
        else {self.core_notice=None;}
        cx.notify();
    }
    fn open_settings(&mut self,cx:&mut Context<Self>) {
        self.open_settings_page("player",cx);
    }
    fn show_presence_guidance(&mut self,window:&mut Window,cx:&mut Context<Self>) {
        let guidance=self.runtime_state["desktopPresence"]["guidance"].as_str().unwrap_or("").to_owned();
        let weak=cx.entity().downgrade();
        window.open_dialog(cx,move|dialog,_,_|{
            let settings=weak.clone();
            dialog.title("还没有可显示的角色").w(px(420.)).child(div().text_sm().child(guidance.clone()))
                .footer(div().flex().justify_end().gap_2()
                    .child(Button::new("presence-guidance-cancel").label("取消").on_click(|_,window,cx|window.close_dialog(cx)))
                    .child(Button::new("presence-guidance-settings").label("打开角色设置").on_click(move|_,window,cx|{
                        window.close_dialog(cx);
                        let settings=settings.clone();
                        cx.defer(move|cx|{_=settings.update(cx,|this,cx|this.open_settings_page("presence",cx));});
                    })))
        });
    }
    fn open_settings_page(&mut self,page:&str,cx:&mut Context<Self>) {
        self.stage_panel_open=false;
        self.settings_pane.update(cx,|pane,cx|pane.select_page(page,cx));
        if let Some(handle)=self.settings_window {
            // A dispatch callback may already lease this window. A failed
            // synchronous update does not imply that its singleton is closed.
            if window_still_registered(handle.window_id(),cx.windows().into_iter().map(|window|window.window_id())) {
                cx.defer(move |cx| {let _=handle.update(cx,|_,window,_|window.activate_window());});
                return;
            }
            self.settings_window=None;
        }
        let pane=self.settings_pane.clone();
        self.settings_window=cx.open_window(WindowOptions {
            window_bounds:Some(WindowBounds::Windowed(Bounds::new(point(px(120.),px(100.)),size(px(880.),px(640.))))),
            window_min_size:Some(size(px(760.),px(540.))),
            ..Default::default()
        },move |window,cx| {
            window.set_window_title("设置");
            window.defer(cx,|window,_| {
                if let Ok(handle)=HasWindowHandle::window_handle(window) {
                    if let RawWindowHandle::AppKit(handle)=handle.as_raw() {
                        product_host::set_window_outer_size(handle.ns_view.as_ptr(),880.,640.,760.,540.);
                    }
                }
            });
            let dismissed=pane.clone();
            window.on_window_should_close(cx,move |_,cx|{dismissed.update(cx,|pane,cx|pane.dismissed(cx));true});
            cx.new(|cx|gpui_kit::base::Root::new(pane,window,cx))
        }).ok();
    }
    fn overlay_action(&mut self,action:&str,cx:&mut Context<Self>) {
        if matches!(action,"chat"|"visual"|"program") && self.props_open {
            if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&serde_json::json!({"op":"stage.props.close"}))) {
                self.core_notice=Some("物件编辑尚未关闭，请重试。".into());cx.notify();return;
            }
            self.props_open=false;
        }
        match action {
            "chat" => {self.chat_open=!self.chat_open;if self.chat_open{self.composer_focus_pending=true;self.stage_panel_open=false;self.program_open=false;self.props_open=false;if self.compact{self.dismissed_reply_revision=None;}}cx.notify();},
            "visual" => {self.open_settings(cx);cx.notify();},
            "program" => {self.program_open=!self.program_open;if self.program_open{self.chat_open=false;self.stage_panel_open=false;self.props_open=false;}cx.notify();},
            "toggleDecoration" => {
                let value=serde_json::json!({"op":"stage.props.toggle"});
                if self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&value)) {
                    self.props_open=!self.props_open;
                    if self.props_open {self.chat_open=false;self.stage_panel_open=false;self.program_open=false;}
                }else{self.core_notice=Some("请先进入空间，再编辑物件。".into());}
                cx.notify();
            },
            "destination"|"resume-autonomy" => {
                let op=if action=="destination"{"stage.destination.toggle"}else{"stage.autonomy.resume"};
                if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&serde_json::json!({"op":op}))) {
                    self.core_notice=Some("本次操作未完成，原状态保持不变。".into());
                }cx.notify();
            },
            "settings" => self.open_settings(cx),
            "screen" => self.native_action("toggleScreenOperation",cx),
            "showNotifications" => {
                if let Some(handle)=self.inbox_window {
                    if handle.update(cx,|_,window,_|window.activate_window()).is_ok() {return;}
                }
                let pane=self.inbox_pane.clone();
                self.inbox_window=cx.open_window(WindowOptions{window_bounds:Some(WindowBounds::Windowed(Bounds::new(point(px(140.),px(120.)),size(px(720.),px(460.))))),..Default::default()},move |window,cx|{
                    window.set_window_title("系统消息");window.focus(&pane.focus_handle(cx),cx);cx.new(|cx|gpui_kit::base::Root::new(pane,window,cx))
                }).ok();
            },
            _ => self.native_action(action,cx),
        }
    }
    fn voice_gesture(&mut self,pressed:bool,cx:&mut Context<Self>) {
        if self.voice_held==pressed {return;}
        self.voice_held=pressed;
        let command=serde_json::json!({"op":if pressed{"chat.voice.begin"}else{"chat.voice.finish"}});
        if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&command)) {
            self.voice_held=false;self.core_notice=Some("语音操作未完成，请检查语音设置。".into());
        }
        cx.notify();
    }
    fn escape_stage(&mut self,cx:&mut Context<Self>) {
        if self.props_open {
            if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&serde_json::json!({"op":"stage.props.escape"}))) {
                self.core_notice=Some("未能取消物件编辑，请重试。".into());
            }
        } else {self.chat_open=false;self.program_open=false;self.stage_panel_open=false;}
        cx.notify();
    }
    fn switch_profile(&mut self, compact: bool, destination: Option<&str>, window: &mut Window, cx: &mut Context<Self>) {
        if self.profile_switch_pending {return;}
        if compact!=self.compact&&self.props_open {
            if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&serde_json::json!({"op":"stage.props.close"}))) {
                self.core_notice=Some("装修预览未关闭，当前窗口保持不变。".into());cx.notify();return;
            }
            self.props_open=false;
        }
        if let Some(destination)=destination {
            if self.runtime_state["stage"]["mode"].as_str()!=Some(destination) {
                if !self.host.borrow().as_ref().is_some_and(|host|host.settings_command(&serde_json::json!({"op":"stage.destination.toggle"}))) {
                    self.core_notice=Some("场景切换未完成，当前窗口保持不变。".into());cx.notify();return;
                }
            }
        }
        if compact==self.compact {if !compact {window.activate_window();}cx.notify();return;}
        // WindowKind allocates a different AppKit class (NSWindow vs NSPanel).
        // Create the real GPUI window shape while retaining this entity and all
        // product state; the next window-ready tick moves the single surface.
        let entity=cx.entity();let location=window.bounds().origin;
        let previous_window=Window::window_handle(window);
        self.profile_switch_pending=true;
        // Root::new installs observers on the content entity. It must run
        // after this entity lease and the current window update are released.
        App::defer(cx,move |cx| {
        let content=entity.clone();
        let handle=cx.open_window(WindowOptions {
            window_bounds:Some(WindowBounds::Windowed(Bounds::new(location,if compact{size(px(shell_metrics::COMPACT_WIDTH),px(shell_metrics::COMPACT_HEIGHT))}else{size(px(1180.),px(760.))}))),
            window_min_size:if compact{None}else{Some(size(px(760.),px(520.)))},
            kind:if compact{WindowKind::PopUp}else{WindowKind::Normal},
            titlebar:if compact{None}else{Some(TitlebarOptions{appears_transparent:true,..Default::default()})},
            is_resizable:!compact,focus:!compact,window_background:WindowBackgroundAppearance::Transparent,
            ..Default::default()
        },move |window,cx| {
            window.set_window_title("gmgn radio");
            cx.new(|cx|gpui_kit::base::Root::new(content,window,cx).bg(rgba(chrome::WINDOW_CLEAR)))
        });
        let Ok(handle)=handle else {entity.update(cx,|ui,cx|{ui.profile_switch_pending=false;ui.core_notice=Some("窗口切换未完成。".into());cx.notify();});return;};
        entity.update(cx,|ui,cx| {
        ui.compact=compact;
        ui.profile_switch_pending=false;
        ui.pane.update(cx,|pane,cx|pane.set_compact(compact,cx));
        ui.stage_panel_open=false;ui.program_open=false;ui.props_open=false;
        ui.surface_mounted=false;
        ui.clear_program_backdrop(cx);
        ui.lyrics_layer.borrow_mut().take();
        ui._poll=cx.spawn(async move |view,cx| {
            loop {
                cx.background_executor().timer(Duration::from_millis(100)).await;
                if handle.update(cx,|_,window,cx|view.update(cx,|view,cx|view.tick(window,cx))).is_err(){break;}
            }
        });
        *ui.main_window.borrow_mut()=Some(handle.into());
        if let Some(host)=ui.host.borrow_mut().as_mut(){host.clear_window_reference();}
        cx.notify();
        });
        let closed=previous_window.update(cx,|_,window,_|window.remove_window()).is_ok();
        eprintln!("GMGN_GPUI_PROFILE_WINDOW compact={compact} created=true previous_closed={closed}");
        });
    }
    /// One Live Cam column control, built from the shared primitive
    /// (`primitives::icon_button`); the host adds only the Live Cam surface the
    /// original draws (`LiveCamPanel.swift:945-950`). No control here is a
    /// hand-rolled `div`.
    ///
    /// The bottom transport bar is **not** built here: the host supplies state
    /// and semantics through [`Self::transport_controls`] and `shell::transport_bar`
    /// owns its rendering.
    fn compact_control(&self,id:&'static str,label:&'static str,action:&'static str,cx:&mut Context<Self>)->AnyElement {
        let icon=if id=="voice" {voice_icon(self.runtime_state["voiceState"].as_str())} else {control_icon(id)};
        let active=match id {"chat"=>self.chat_open,"props"=>self.props_open,_=>false};
        let button=ui::icon_button(id,icon,label,active)
            .w(px(shell_metrics::COMPACT_CONTROL)).h(px(shell_metrics::COMPACT_CONTROL))
            .rounded(px(scene_tokens::CONTROL_RADIUS))
            .bg(rgba(shell_metrics::COMPACT_CONTROL_BG))
            .border_1().border_color(rgba(shell_metrics::COMPACT_CONTROL_BORDER))
            .text_color(rgba(shell_metrics::COMPACT_TINT));
        let mut control=if id=="player" {
            let snapshot=self.runtime_state["liveCamPlayerMenu"].clone();let weak=cx.entity().downgrade();let popup_weak=weak.clone();
            button.dropdown_menu(move |menu,_,_| {
                let mut menu=menu.item(PopupMenuItem::new(snapshot["menuTitle"].as_str().unwrap_or("播放器尚未准备好").to_owned()).disabled(true)).separator();
                for (title,action,flag) in [("上一首","previousTrack","canSelectPrevious"),(snapshot["playPauseTitle"].as_str().unwrap_or("播放"),"togglePlayback","canTogglePlayback"),("下一首","nextTrack","canSelectNext")] {
                    let weak=weak.clone();
                    menu=menu.item(PopupMenuItem::new(title.to_owned()).disabled(snapshot[flag].as_bool()!=Some(true)).on_click(move |_,_,cx|{let _=weak.update(cx,|ui,cx|ui.native_action(action,cx));}));
                }
                let weak=weak.clone();menu.separator().item(PopupMenuItem::new("进入播放器").on_click(move |_,_,cx|{let _=weak.update(cx,|ui,cx|ui.native_action("showPlayer",cx));}))
            }).on_open_change(move |open,_,cx|{let _=popup_weak.update(cx,|ui,cx|{ui.player_menu_open=*open;cx.notify();});}).into_any_element()
        } else if action=="voice" {
            button.on_mouse_down(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(true,cx)))
                .on_mouse_up(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(false,cx)))
                .on_mouse_up_out(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(false,cx))).into_any_element()
        } else {button.on_click(cx.listener(move |this,_,window,cx|{
            if action=="mode" {window.toggle_fullscreen();cx.notify();}
            else if action=="showStage" {this.switch_profile(false,Some("space"),window,cx);}
            else if action=="showPlayer" {this.switch_profile(false,Some("player"),window,cx);}
            else {this.overlay_action(action,cx);}
        })).into_any_element()};
        let count=inbox_unread(&self.runtime_state);
        if id=="inbox"&&count>0 {
            control=div().relative().w(px(shell_metrics::COMPACT_CONTROL)).h(px(shell_metrics::COMPACT_CONTROL)).child(control)
                .child(div().absolute().top(px(shell_metrics::BADGE_TOP)).left(px(shell_metrics::COMPACT_CONTROL/2.+shell_metrics::BADGE_OFFSET))
                    .min_w(px(shell_metrics::BADGE_SIZE)).h(px(shell_metrics::BADGE_SIZE)).rounded(px(shell_metrics::BADGE_RADIUS))
                    .bg(rgba(shell_metrics::BADGE_BG)).text_color(rgba(shell_metrics::BADGE_TEXT)).text_size(px(shell_metrics::BADGE_FONT))
                    .flex().items_center().justify_center().child(if count>99{"99+".into()}else{count.to_string()})).into_any_element();
        }
        control.into_any_element()
    }

    /// The bottom transport row's **state and semantics** — the original order,
    /// each entry's action name, its enabled condition, its live label/icon and
    /// whether it toggles, holds or badged. `shell::transport_bar` owns how that
    /// becomes pixels (`StageWindowController.swift:2823-2884`).
    fn transport_controls(&self,fullscreen:bool)->Vec<TransportControl> {
        let chat_available=self.runtime_state["stage"]["presentation"]["chatAvailable"].as_bool();
        let screen=self.runtime_state["screenOperation"].clone();
        let player=self.runtime_state["liveCamPlayerMenu"].clone();
        let mut controls=Vec::with_capacity(TRANSPORT_CONTROLS.len());
        for (id,label,action) in TRANSPORT_CONTROLS {
            // The original tints the *asserted* entry cyan and, for 聊天, fills
            // it with system blue (`StageWindowController.swift:3058-3066,3141-3152`).
            let active=match id {
                "chat"=>self.chat_open,"props"=>self.props_open,"visual"=>self.stage_panel_open,"program"=>self.program_open,
                "screen"=>screen["active"].as_bool()==Some(true),_=>false,
            };
            let enabled=match id {
                "chat"=>chat_available==Some(true),
                "props"=>self.runtime_state["stage"]["presentation"]["propsAvailable"].as_bool()==Some(true),
                "screen"=>screen["available"].as_bool()==Some(true),
                "previous"=>player["canSelectPrevious"].as_bool()==Some(true),
                "play"=>player["canTogglePlayback"].as_bool()==Some(true),
                "next"=>player["canSelectNext"].as_bool()==Some(true),
                _=>true,
            };
            let label:String=if id=="chat"&&chat_available!=Some(true) {"进入空间后与居民聊天".into()}
                else if id=="visual" {if self.stage_panel_open{"收起设置".into()}else{"舞台设置：播放器、空间、角色与活动".into()}}
                else if id=="screen" {
                    if screen["active"].as_bool()==Some(true) {"完成操作（Esc）".into()}
                    else if screen["available"].as_bool()==Some(true) {"操作电视".into()}
                    else {"这块空间里还没有在放的电视".into()}
                } else if id=="chat" {if self.chat_open{"收起聊天".into()}else{"与居民聊天".into()}}
                else {label.to_owned()};
            let icon=if id=="visual"&&self.stage_panel_open {IconName::X}
                else if id=="play"&&self.runtime_state["playbackState"].as_str()==Some("playing") {IconName::Pause}
                else if id=="voice" {voice_icon(self.runtime_state["voiceState"].as_str())}
                else if id=="mode" {window_mode_content(fullscreen).0}
                else {control_icon(id)};
            let label=if id=="mode" {window_mode_content(fullscreen).1.to_owned()} else {label};
            let mut control=TransportControl::new(id,action,icon,label)
                .active(active).enabled(enabled).ends_group(id=="next").hold(id=="voice");
            if id=="visual" {control=control.face_text(if self.stage_panel_open{"收起"}else{"设置"});}
            if id=="chat"&&self.chat_open {control=control.active_fill(system_symbol::system_blue_background());}
            if id=="inbox" {
                let count=inbox_unread(&self.runtime_state);
                if count>0 {control=control.badge(if count>99{"99+".to_owned()}else{count.to_string()});}
            }
            controls.push(control);
        }
        controls
    }
}

/// One slot of the overlay stack, in the order the children are added.
///
/// `on_children_prepainted` returns one bounds per *grown child* in that order,
/// so the hit-region indices are derived from this list rather than written out
/// by hand: a hand-written index silently points at the wrong rectangle the
/// moment a child moves, and the drop target or the scene passthrough would be
/// wrong without failing loudly. `layout_tests` pins the same list.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum OverlaySlot {
    Lyrics,
    Transport,
    Destination,
    ScreenBanner,
    Notices,
    Composer,
    StagePanel,
    Program,
    Props,
    BoundVideo,
    CompactControls,
    CompactReply,
}

impl OverlaySlot {
    /// Regions the original never forwards to the scene: the GPU lyrics layer
    /// and the screen-operation banner (`StageScreenOperationBanner.hitTest`
    /// returns nil; `LiveCamPanel.isPassiveDecoration`).
    fn passive(self) -> bool {
        matches!(self, Self::Lyrics | Self::ScreenBanner)
    }
}

/// What the current window shows, in the order the shell draws it.
struct OverlayState {
    compact: bool,
    chat_open: bool,
    stage_panel_open: bool,
    program_open: bool,
    props_open: bool,
    bound_video: bool,
    notices: bool,
    screen_active: bool,
    reply: bool,
}

/// The child order of the overlay root. One function so the render and the
/// prepaint indices cannot disagree.
fn overlay_plan(state: &OverlayState) -> Vec<OverlaySlot> {
    if state.compact {
        let mut slots = vec![OverlaySlot::CompactControls];
        if state.notices { slots.push(OverlaySlot::Notices); }
        if state.chat_open { slots.push(OverlaySlot::Composer); }
        if state.reply { slots.push(OverlaySlot::CompactReply); }
        slots
    } else {
        let mut slots = vec![OverlaySlot::Lyrics, OverlaySlot::Transport, OverlaySlot::Destination];
        if state.screen_active { slots.push(OverlaySlot::ScreenBanner); }
        if state.notices { slots.push(OverlaySlot::Notices); }
        if state.chat_open { slots.push(OverlaySlot::Composer); }
        if state.stage_panel_open { slots.push(OverlaySlot::StagePanel); }
        if state.program_open { slots.push(OverlaySlot::Program); }
        if state.props_open { slots.push(OverlaySlot::Props); }
        if state.bound_video { slots.push(OverlaySlot::BoundVideo); }
        slots
    }
}

impl Render for GMGNProductUI {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.sync_program_backdrop(window,cx);
        self.sync_lyrics_layer(window,cx);
        if self.composer_focus_pending {
            self.composer_focus_pending=false;
            let pane=self.pane.downgrade();
            window.on_next_frame(move |window,cx| { let _=pane.update(cx, |pane,cx|pane.focus_composer(window,cx)); });
        }
        let mut notices = if self.compact {
            div().id("product-runtime-notices").flex().flex_col().gap(px(shell_metrics::BANNER_STACK_GAP)).text_size(px(shell_metrics::NOTICE_FONT_COMPACT))
        }else{div().id("product-runtime-notices").max_h(px(chrome::TASK_MAX_HEIGHT)).overflow_y_scroll().p_2().text_size(px(CAPTION_SIZE)).line_height(relative(1.4))};
        let mut notice_count=0;
        let task_feedback_visible=self.compact||self.runtime_state["stage"]["presentation"]["taskFeedbackVisible"].as_bool()==Some(true);
        let mut seen_notices=Vec::new();
        let notice_fields=if self.compact {["ttsError","speechError","inboxPersistenceError","statusNotice"]}else{["statusNotice","ttsError","speechError","inboxPersistenceError"]};
        for field in notice_fields {
            if let Some(notice) = self.runtime_state[field].as_str().filter(|s| !s.is_empty()) {
                if seen_notices.contains(&notice){continue;}
                seen_notices.push(notice);
                let item=if self.compact {
                    // Live Cam banner: `Color(white: 0.1).opacity(0.96)` with a
                    // 10 pt radius and orange 0.95 text (`StageOverlayView.swift:96-108`,
                    // `LiveCamPanel.swift:785-790`).
                    let item=div().px(px(shell_metrics::BANNER_PADDING)).py(px(shell_metrics::BANNER_PADDING)).rounded(px(shell_metrics::BANNER_RADIUS))
                        .bg(rgba(scene_tokens::PANEL_BG))
                        .text_size(px(if field=="statusNotice"{shell_metrics::DELIVERY_FONT}else{shell_metrics::NOTICE_FONT}))
                        .text_color(rgba(scene_tokens::WARNING)).child(notice.to_owned());
                    if field=="statusNotice"{item}else{item.line_clamp(3)}
                }else{div().text_size(px(CAPTION_SIZE)).text_color(rgba(scene_tokens::TEXT_MUTED)).child(user_status_notice(notice))};
                notices = notices.child(item);
                notice_count+=1;
            }
        }
        if let Some(message)=self.runtime_state["autonomy"]["connectivityNotice"].as_str().filter(|s|task_feedback_visible&&!s.is_empty()) {
            // `WishMachineTaskStatusView.connectivityBanner` (`StageOverlayView.swift:151-165`):
            // wifi.exclamationmark, orange 0.95 on `Color(white: 0.1).opacity(0.96)`.
            notices=notices.child(div().id("resident.connectivity-banner").flex().items_center().gap(px(shell_metrics::BANNER_STACK_GAP))
                .rounded(px(shell_metrics::BANNER_RADIUS)).p(px(if self.compact{shell_metrics::BANNER_PADDING_COMPACT}else{shell_metrics::BANNER_PADDING}))
                .bg(rgba(scene_tokens::PANEL_BG)).text_size(px(if self.compact{shell_metrics::NOTICE_FONT_COMPACT}else{shell_metrics::NOTICE_FONT}))
                .text_color(rgba(scene_tokens::WARNING)).line_clamp(if self.compact{2}else{3})
                .child(Icon::new(IconName::WifiOff).small()).child(message.to_owned()));notice_count+=1;
        }
        let autonomy=self.runtime_state["autonomy"]["switchOn"].as_bool();
        if task_feedback_visible&&(autonomy==Some(false)||self.runtime_state["autonomy"]["stopped"].as_bool()==Some(true)) {
            let enabled=autonomy==Some(true);
            // `WishMachineTaskStatusView.autonomyBanner` (`StageOverlayView.swift:184-215`):
            // pause.circle / hand.raised, orange 0.95 title, one resume action.
            let mut banner=div().id("resident.autonomy-banner").flex().flex_col().gap_1()
                .rounded(px(shell_metrics::BANNER_RADIUS)).p(px(if self.compact{shell_metrics::BANNER_PADDING_COMPACT}else{shell_metrics::BANNER_PADDING}))
                .bg(rgba(scene_tokens::PANEL_BG)).text_size(px(if self.compact{shell_metrics::BANNER_TITLE_COMPACT}else{shell_metrics::BANNER_TITLE}))
                .child(div().flex().items_center().justify_between().gap(px(shell_metrics::BANNER_STACK_GAP)).text_color(rgba(scene_tokens::WARNING))
                    .child(div().flex().items_center().gap(px(shell_metrics::BANNER_STACK_GAP))
                        .child(Icon::new(if enabled{IconName::CirclePause}else{IconName::Hand}).small())
                        .child(if enabled{"自主行动已停止"}else{"居民自主行动已关闭"}))
                    .child(Button::new("resident.autonomy.resume").ghost().xsmall().flex_shrink_0()
                        // Icon-only face; the words live in the tooltip and the
                        // accessibility label (`primitives::icon_button`'s rule).
                        .icon(if enabled{IconName::Play}else{IconName::Settings})
                        .tooltip(if enabled{"恢复自主行动"}else{"打开自主行动"})
                        .accessibility_label(if enabled{"恢复自主行动"}else{"打开自主行动"})
                        .on_click(cx.listener(|this,_,_,cx|this.overlay_action("resume-autonomy",cx)))));
            if !self.compact {banner=banner.child(div().text_size(px(shell_metrics::BANNER_BODY)).line_height(relative(1.4)).text_color(rgba(scene_tokens::TEXT_MUTED)).child("不自主不等于不听话：直接下达的指令在任何开关状态下都会执行。"));}
            if let Some(message)=self.runtime_state["autonomy"]["resumeFailure"].as_str().filter(|s|!s.is_empty()) {
                banner=banner.child(div().id("resident.autonomy.resume-failure").text_size(px(shell_metrics::STATUS_DETAIL_FONT)).text_color(rgba(scene_tokens::WARNING)).child(message.to_owned()));
            }
            notices=notices.child(banner);
            notice_count+=1;
        }
        if let Some(notice)=&self.core_notice {
            notices=if self.compact{notices.child(div().px(px(shell_metrics::BANNER_PADDING)).py(px(shell_metrics::BANNER_PADDING)).rounded(px(shell_metrics::BANNER_RADIUS)).bg(rgba(scene_tokens::PANEL_BG)).text_size(px(shell_metrics::NOTICE_FONT_COMPACT)).text_color(rgba(scene_tokens::WARNING)).child(notice.clone()))}else{notices.child(notice.clone())};notice_count+=1;
        }
        // The stack is moved into its one child slot below; the slot may be
        // absent, so it is optioned rather than cloned (a `Stateful<Div>` is not
        // `Clone`).
        let mut notices=Some(notices);
        let viewport=window.viewport_size();let width=viewport.width.as_f32();let height=viewport.height.as_f32();let fullscreen=window.is_fullscreen();
        let compact_height=compact_composer_height(&self.runtime_state);
        let mut root=div().size_full().relative().font_family(FONT_FAMILY).text_size(px(BODY_SIZE)).line_height(px(BODY_LINE_HEIGHT)).text_color(rgba(scene_tokens::TEXT));
        self.lyrics_pane.update(cx,|pane,cx|pane.set_visible(!self.compact,cx));
        if !self.compact {
            self.lyrics_pane.update(cx,|pane,_|pane.set_viewport_size(width,height));
        }
        let bound_video=self.bound_video_pane.read(cx).is_visible();
        let reply=compact_reply_text(&self.runtime_state,&self.transcript)
            .filter(|_|self.compact)
            .filter(|_|latest_reply_revision(&self.runtime_state)!=self.dismissed_reply_revision);
        let screen_active=self.runtime_state["screenOperation"]["active"].as_bool()==Some(true);
        let plan=overlay_plan(&OverlayState{compact:self.compact,chat_open:self.chat_open,stage_panel_open:self.stage_panel_open,
            program_open:self.program_open,props_open:self.props_open,bound_video,notices:notice_count>0,screen_active,reply:reply.is_some()});
        for slot in &plan {
            root=match slot {
                OverlaySlot::Lyrics=>root.child(div().absolute().size_full().child(self.lyrics_pane.clone())),
                OverlaySlot::CompactControls=>{
                    // Live Cam control column (`LiveCamPanel.swift:700,860-877`):
                    // 30 pt entries, 6 pt apart, 10 pt from the top/right edge.
                    let mut controls=div().absolute().top(px(shell_metrics::COMPACT_MARGIN)).right(px(shell_metrics::COMPACT_MARGIN))
                        .w(px(shell_metrics::COMPACT_CONTROL)).flex().flex_col().gap(px(shell_metrics::COMPACT_CONTROL_GAP));
                    for (id,label,action) in COMPACT_CONTROLS { controls=controls.child(self.compact_control(id,label,action,cx)); }
                    root.child(controls)
                }
                OverlaySlot::Transport=>{
                    // `StageWindowController.swift:2835-2884`: the bar, its row
                    // and the 1×20 divider are rendered by
                    // `shell::transport_bar`; this host supplies only each
                    // control's state and semantics.
                    let controls=self.transport_controls(fullscreen);
                    let click=cx.entity().downgrade();
                    let hold=click.clone();
                    root.child(shell::transport_bar(controls,
                        move |action,window,cx|{
                            let _=click.update(cx,|this,cx|{
                                if action=="mode" {window.toggle_fullscreen();cx.notify();}
                                else if action=="showStage" {this.switch_profile(false,Some("space"),window,cx);}
                                else if action=="showPlayer" {this.switch_profile(false,Some("player"),window,cx);}
                                else {this.overlay_action(action,cx);}
                            });
                        },
                        move |action,pressed,_window,cx|{
                            let _=hold.update(cx,|this,cx|{if action=="voice"{this.voice_gesture(pressed,cx);}});
                        }))
                }
                OverlaySlot::Destination=>{
                    // `StageWindowController.swift:3165-3185`: the two-state
                    // `circle.hexagongrid.fill` / `cube.transparent` SF Symbol,
                    // which the host renders through `system_symbol` (gpui-kit
                    // has no equivalent glyph); `shell::destination_button`
                    // owns the round 38 pt frame, surface and hairline.
                    let in_space=self.runtime_state["stage"]["mode"].as_str()==Some("space");
                    let icon=div().flex().items_center().justify_center().when_some(
                        system_symbol::image(if in_space{"circle.hexagongrid.fill"}else{"cube.transparent"}),
                        |view,image|view.child(img(image).w(px(shell_metrics::DESTINATION_ICON)).h(px(shell_metrics::DESTINATION_ICON)).object_fit(ObjectFit::Contain)));
                    root.child(shell::destination_button(icon,
                        if in_space{"返回播放器"}else{"进入空间"},true,
                        cx.listener(|this,_,_,cx|this.overlay_action("destination",cx))))
                }
                OverlaySlot::ScreenBanner=>{
                    // `StageWindowController.swift:3003-3030` + `:1544-1548`:
                    // centred over the transport bar, 12 pt above it, 12 pt
                    // radius, 0.04/0.30/0.42 at 0.92, systemCyan 0.45 hairline.
                    let right=shell_metrics::TRANSPORT_INSET+(shell_metrics::TRANSPORT_WIDTH-shell_metrics::SCREEN_BANNER_WIDTH)/2.;
                    let bottom=shell_metrics::TRANSPORT_INSET+shell_metrics::TRANSPORT_HEIGHT+shell_metrics::SCREEN_BANNER_GAP;
                    root.child(div().id("stage.screen-operation-banner").absolute().right(px(right)).bottom(px(bottom))
                        .w(px(shell_metrics::SCREEN_BANNER_WIDTH)).h(px(shell_metrics::SCREEN_BANNER_HEIGHT))
                        .flex().items_center().justify_center().rounded(px(shell_metrics::SCREEN_BANNER_RADIUS))
                        .bg(rgba(shell_metrics::SCREEN_BANNER)).border_1().border_color(rgba(shell_metrics::SCREEN_BANNER_BORDER))
                        .text_size(px(shell_metrics::SCREEN_BANNER_FONT)).font_weight(FontWeight::MEDIUM)
                        .child("正在操作电视，按 Esc 退出"))
                }
                OverlaySlot::Notices=>match notices.take() {
                    // 任务状态区: top-left 280 pt at 22/22 in the stage window,
                    // above the Live Cam composer in the compact window
                    // (`StageWindowController.swift:1533-1535`, `LiveCamPanel.swift:849-857`).
                    // No host background: every banner draws its own surface.
                    Some(notices)=>root.child(if self.compact {
                        notices.absolute().left(px(shell_metrics::COMPACT_MARGIN)).right(px(shell_metrics::COMPACT_CONTENT_RIGHT))
                            .bottom(px(compact_height+shell_metrics::COMPACT_MARGIN+shell_metrics::COMPACT_NOTICE_GAP))
                    }else{
                        notices.absolute().left(px(shell_metrics::TASK_FEEDBACK_INSET)).top(px(shell_metrics::TASK_FEEDBACK_INSET)).w(px(shell_metrics::TASK_FEEDBACK_WIDTH))
                    }),
                    None=>root,
                }
                OverlaySlot::Composer=>{
                    // The pane draws its own card (radius 20, its own surface and
                    // max width/height); the host only places it. The former
                    // The former `bg + rounded_xl + overflow_hidden` wrapper
                    // doubled the chrome chat.rs already paints and clipped the
                    // card shadow.
                    let [left,top,w,h]=composer_frame(self.compact,width,height,compact_height);
                    let overlay=div().absolute().right(px(width-left-w)).bottom(px(height-top-h)).w(px(w));
                    // The Live Cam composer is an exact 70/140 pt surface the pane
                    // fills (`LiveCamPanel.swift:748`); the stage composer is a
                    // ceiling, because it hugs its content (`:1530`).
                    let overlay=if self.compact{overlay.h(px(h))}else{overlay.max_h(px(h))};
                    root.child(overlay.child(self.pane.clone()))
                }
                OverlaySlot::StagePanel=>{
                    let panel_width=(width-36.).clamp(0.,stage_metrics::PANEL_MAX_WIDTH);let panel_height=(height-92.).clamp(0.,stage_metrics::PANEL_MAX_HEIGHT);
                    root.child(div().absolute().right(px(18.)).bottom(px(80.)).w(px(panel_width)).h(px(panel_height)).child(self.stage_pane.clone()))
                }
                OverlaySlot::Program=>{
                    let panel_width=stage_metrics::PROGRAM_RAIL_WIDTH.min(width-36.);let panel_height=stage_metrics::PROGRAM_RAIL_HEIGHT.min(height-80.);
                    root.child(div().absolute().right(px(18.)).bottom(px(80.)).w(px(panel_width)).h(px(panel_height)).child(self.program_pane.clone()))
                }
                OverlaySlot::Props=>{
                    let panel_height=390_f32.min(height-98.);
                    root.child(div().absolute().right(px(22.)).bottom(px(82.)).w(px(stage_metrics::PROP_EDITOR_WIDTH)).h(px(panel_height)).child(self.prop_pane.clone()))
                }
                OverlaySlot::BoundVideo=>root.child(div().absolute().top(px(28.)).right(px(32.)).w(px(330.)).h(px(58.)).child(self.bound_video_pane.clone())),
                OverlaySlot::CompactReply=>match &reply {
                    Some(reply)=>{
                        // `LiveCamPanel.swift:828-834,902-918`: 12 pt radius,
                        // 136 pt while the composer is open, ≤74 pt collapsed,
                        // a 20×20 dismiss button and the same dedup rule
                        // (`shouldPresentReply`: one bubble per turn).
                        let content=if self.chat_open{div().id("livecam.full-reply").flex_1().min_w(px(0.)).min_h(px(0.)).overflow_y_scroll().text_size(px(shell_metrics::COMPACT_BUBBLE_FONT)).child(expanded_reply_text(&self.transcript,reply)).into_any_element()}else{div().flex_1().min_w(px(0.)).text_size(px(shell_metrics::COMPACT_BUBBLE_FONT)).line_clamp(3).child(reply.clone()).into_any_element()};
                        let bubble=div().id("compact-reply-bubble").absolute().left(px(shell_metrics::COMPACT_MARGIN)).right(px(shell_metrics::COMPACT_CONTENT_RIGHT)).top(px(shell_metrics::COMPACT_MARGIN))
                            .px(px(shell_metrics::COMPACT_BUBBLE_PADDING.0)).py(px(shell_metrics::COMPACT_BUBBLE_PADDING.1))
                            .rounded(px(shell_metrics::COMPACT_REPLY_RADIUS)).bg(rgba(scene_tokens::PANEL_BG))
                            .flex().items_start().gap(px(shell_metrics::COMPACT_BUBBLE_GAP));
                        let bubble=if self.chat_open{bubble.h(px(shell_metrics::COMPACT_REPLY_EXPANDED))}else{bubble.max_h(px(shell_metrics::COMPACT_REPLY_COLLAPSED))};
                        root.child(bubble
                            .on_click(cx.listener(|this,_,_,cx|{this.chat_open=true;this.composer_focus_pending=true;cx.notify();}))
                            .child(content)
                            .child(ui::icon_button("livecam.reply-dismiss",IconName::X,"关闭回复气泡",false)
                                .w(px(shell_metrics::COMPACT_DISMISS)).h(px(shell_metrics::COMPACT_DISMISS))
                                .on_click(cx.listener(|this,_,_,cx|{cx.stop_propagation();this.dismissed_reply_revision=latest_reply_revision(&this.runtime_state);cx.notify();}))))
                    }
                    None=>root,
                },
            };
        }
        let host=self.host.clone();
        let menu_open=self.player_menu_open;
        // Both indices come from the same plan the children were built from, so
        // a moved child can never leave them pointing at another rectangle.
        let composer_index=plan.iter().position(|slot|*slot==OverlaySlot::Composer);
        // The original screen-operation banner never takes scene pointer events
        // (`StageScreenOperationBanner.hitTest` returns nil); the lyrics layer
        // is GPU-composited and likewise eats nothing. All other overlay hit
        // regions use actual computed bounds, including wrapped notices and the
        // complete autonomy card.
        let passive_indices:Vec<usize>=plan.iter().enumerate().filter(|(_,slot)|slot.passive()).map(|(index,_)|index).collect();
        root.on_children_prepainted(move |bounds,window,cx| {
            // Read Kit's real modal stack at paint time: all close routes
            // restore passthrough without maintaining a second modal flag.
            let modal_open=modal_owns_scene_input(menu_open,window.has_active_dialog(cx),window.has_active_sheet(cx));
            if let Ok(handle)=HasWindowHandle::window_handle(window) {
                if let RawWindowHandle::AppKit(handle)=handle.as_raw() {
                    let region=composer_index.and_then(|index|bounds.get(index)).filter(|_|!modal_open);
                    let (x,y,w,h,enabled)=region.map_or((0.,0.,0.,0.,0),|bounds|(bounds.origin.x.as_f32() as f64,bounds.origin.y.as_f32() as f64,bounds.size.width.as_f32() as f64,bounds.size.height.as_f32() as f64,1));
                    unsafe{gmgn_gpui_bitmap_drop_region(handle.ns_view.as_ptr(),x,y,w,h,enabled)};
                }
            }
            let rects:Vec<[f32;4]>=if modal_open {
                // Like the original NSMenu, a live Kit popup owns pointer
                // dismissal while open. Restore scene passthrough on close.
                let viewport=window.viewport_size();vec![[0.,0.,viewport.width.as_f32(),viewport.height.as_f32()]]
            }else{bounds.into_iter().enumerate().filter(|(index,_)|!passive_indices.contains(index))
                .map(|(_,bounds)|[bounds.origin.x.as_f32(),bounds.origin.y.as_f32(),bounds.size.width.as_f32(),bounds.size.height.as_f32()]).collect()
            };
            if let Some(host)=host.borrow().as_ref(){host.hit_regions(&rects);}
        }).into_any_element()
    }
}

#[cfg(test)]
mod layout_tests {
    #[test]
    fn product_errors_consume_each_revision_once_and_preserve_text() {
        let value=serde_json::json!({"revision":1,"title":"音乐资源连接失败","message":"音乐服务返回了不安全的播放地址，应用已阻止连接。"});
        let notice=super::next_error_notice(&value,0).unwrap();
        assert_eq!(notice.title,"音乐资源连接失败");
        assert_eq!(notice.message,"音乐服务返回了不安全的播放地址，应用已阻止连接。");
        assert!(super::next_error_notice(&value,notice.revision).is_none());
        assert!(super::next_error_notice(&value,2).is_none());
        let mut next=value.clone();next["revision"]=2.into();
        assert!(super::next_error_notice(&next,1).is_some());
    }
    #[test]
    fn incomplete_error_snapshot_does_not_consume_revision() {
        for value in [serde_json::Value::Null,serde_json::json!({"revision":0,"title":"错误","message":"详情"}),
            serde_json::json!({"revision":1,"title":"  ","message":"详情"}),
            serde_json::json!({"revision":1,"title":"错误"}),
            serde_json::json!({"revision":"1","title":"错误","message":"详情"})] {
            assert!(super::next_error_notice(&value,0).is_none());
        }
        assert!(super::next_error_notice(&serde_json::json!({"revision":1,"title":"错误","message":""}),0).is_some());
    }
    #[test]
    fn compact_background_reply_is_visible_without_fabricating_transcript() {
        let state=serde_json::json!({"contextID":"world-a","reply":"后台回复","replyRevision":3});
        let transcript=vec![];
        assert_eq!(super::compact_reply_text(&state,&transcript).as_deref(),Some("后台回复"));
        assert_eq!(super::expanded_reply_text(&transcript,"后台回复"),"后台回复");
        let next=serde_json::json!({"contextID":"world-a","reply":"后台回复","replyRevision":4});
        assert_ne!(super::latest_reply_revision(&state),super::latest_reply_revision(&next));
        assert!(transcript.is_empty());
        let transcript=vec![super::TranscriptLine{speaker:"居民".into(),text:"后台回复".into()}];
        assert_eq!(super::expanded_reply_text(&transcript,"后台回复"),"居民：后台回复");
        assert_eq!(super::expanded_reply_text(&transcript,"另一条回复"),"居民：后台回复\n\n另一条回复");
    }
    #[test]
    fn configured_gpui_http_client_can_fetch_artwork_without_null_client() {
        use std::{io::{Read,Write},time::Duration};
        use gpui_kit::http_client::{HttpClient,AsyncBody};
        let listener=std::net::TcpListener::bind("127.0.0.1:0").unwrap();let address=listener.local_addr().unwrap();
        let server=std::thread::spawn(move||{let (mut stream,_)=listener.accept().unwrap();stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();let mut buffer=[0;4096];let n=stream.read(&mut buffer).unwrap();let request=std::str::from_utf8(&buffer[..n]).unwrap();assert!(request.starts_with("GET /artwork.png "));assert!(request.to_ascii_lowercase().contains("user-agent: gmgn radio"));stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntest").unwrap();});
        let client=reqwest_client::ReqwestClient::user_agent("gmgn radio").unwrap();
        let response=reqwest_client::runtime().block_on(client.get(&format!("http://{address}/artwork.png"),AsyncBody::empty(),true)).unwrap();
        assert_eq!(response.status(),200);assert_eq!(response.headers()["content-type"],"image/png");server.join().unwrap();
    }
    #[test]
    fn kit_modal_stack_blocks_scene_and_restores_after_last_close() {
        assert!(!super::modal_owns_scene_input(false,false,false));
        assert!(super::modal_owns_scene_input(false,true,false));
        assert!(super::modal_owns_scene_input(false,true,true));
        assert!(super::modal_owns_scene_input(false,false,true));
        assert!(!super::modal_owns_scene_input(false,false,false));
        assert!(super::modal_owns_scene_input(true,false,false));
    }
    #[test]
    fn singleton_uses_window_inventory_not_reentrant_update_result() {
        assert!(super::window_still_registered(7_u64,[3,7]));
        assert!(!super::window_still_registered(7_u64,[3]));
        assert!(!super::window_still_registered(7_u64,[]));
    }
    #[test]
    fn closing_reply_keeps_history_and_only_hides_that_real_turn() {
        let original=serde_json::json!({"contextID":"world-a","transcript":[{"role":"agent","turnID":"turn-a","text":"相同回复"}]});
        let dismissed=super::latest_reply_revision(&original);
        assert_eq!(super::latest_reply_revision(&original),dismissed);
        let next=serde_json::json!({"contextID":"world-a","transcript":[{"role":"agent","turnID":"turn-a","text":"相同回复"},{"role":"agent","turnID":"turn-b","text":"相同回复"}]});
        assert_ne!(super::latest_reply_revision(&next),dismissed);
        assert_eq!(original["transcript"].as_array().unwrap().len(),1);
    }
    #[test]
    fn inbox_badge_uses_read_state_not_delivery_ack() {
        assert_eq!(super::inbox_unread(&serde_json::json!({"inbox":{"entries":[
            {"isRead":false,"acknowledged":true},{"isRead":true,"acknowledged":false},
            {"isRead":false,"acknowledged":false},{}
        ]}})),2);
        assert_eq!(super::inbox_unread(&serde_json::Value::Null),0);
    }
    use super::{compact_composer_height,composer_frame,control_icon,overlay_plan,voice_icon,window_mode_content,COMPACT_CONTROLS,OverlaySlot,OverlayState,TransportControl,TRANSPORT_CONTROLS};
    use super::{scene_tokens,shell_metrics,stage_metrics};
    use super::IconName;
    fn overlay_state(compact:bool,chat_open:bool,notices:bool,screen_active:bool,reply:bool)->OverlayState {
        OverlayState{compact,chat_open,stage_panel_open:false,program_open:false,props_open:false,bound_video:false,notices,screen_active,reply}
    }
    #[test]
    fn stage_composer_preserves_original_margins_and_maximums() {
        assert_eq!(composer_frame(false,1100.,760.,70.),[458.,354.,620.,320.]);
        let frame=composer_frame(false,600.,400.,70.);
        assert_eq!(frame,[22.,22.,556.,292.]);
        assert_eq!(600.-frame[0]-frame[2],22.);
        assert_eq!(400.-frame[1]-frame[3],86.);
    }
    #[test]
    fn compact_composer_never_enters_the_original_control_column() {
        let frame=composer_frame(true,224.,336.,compact_composer_height(&serde_json::json!({})));
        assert_eq!(frame,[10.,256.,166.,70.]);
        assert_eq!(184.-frame[0]-frame[2],8.);
        assert_eq!(336.-frame[1]-frame[3],10.);
        // The attached strip grows upward from the same bottom edge.
        let frame=composer_frame(true,224.,336.,compact_composer_height(&serde_json::json!({"attachments":[{"id":"a"}]})));
        assert_eq!(frame,[10.,186.,166.,140.]);
        assert_eq!(336.-frame[1]-frame[3],10.);
    }
    /// The Live Cam height is the shared chat surface's answer, not a second
    /// copy of the 70/140 rule kept in this file.
    #[test]
    fn compact_composer_height_reads_the_shared_chat_surface() {
        assert_eq!(compact_composer_height(&serde_json::json!({})),70.);
        for state in [serde_json::json!({"attachments":[{"id":"a"}]}),serde_json::json!({"attachmentsPreparing":true}),serde_json::json!({"attachmentError":"读取失败"})] {
            assert_eq!(compact_composer_height(&state),140.);
        }
        assert_eq!(compact_composer_height(&serde_json::json!({"attachmentError":""})),70.);
        let mut chat=gmgn_gpui_ui::state::ChatState::default();
        assert_eq!(gmgn_gpui_ui::chat::compact_composer_height(&chat),70.);
        chat.attachments_preparing=true;
        assert_eq!(gmgn_gpui_ui::chat::compact_composer_height(&chat),140.);
    }
    /// The transport row is the original 11 controls and its 529×48 bar; the
    /// divider is 1×20 and sits after 下首 (`StageWindowController.swift:2851-2884`).
    #[test]
    fn transport_controls_pin_the_original_order_widths_and_divider() {
        assert_eq!(TRANSPORT_CONTROLS.map(|(id,_,_)|id),["program","previous","play","next","voice","chat","inbox","props","screen","visual","mode"]);
        assert_eq!(TRANSPORT_CONTROLS[3].0,"next");
        assert_eq!(COMPACT_CONTROLS.map(|(id,_,_)|id),["space","player","chat","inbox","voice","settings"]);
        // 窗口 is a two-state entry, not a fixed glyph (`StageWindowMode.swift:5-21`).
        assert_eq!(window_mode_content(false),(IconName::Maximize,"进入全屏"));
        assert_eq!(window_mode_content(true),(IconName::Minimize,"退出全屏"));
        assert_eq!(shell_metrics::TRANSPORT_DIVIDER,(1.,20.));
        // The slot widths come from the shared shell control, not a second
        // host-side derivation (`StageOverlayView.swift:2686-2689`).
        let next=TransportControl::new("next","nextTrack",IconName::ChevronRight,"下首").ends_group(true);
        let visual=TransportControl::new("visual","visual",IconName::Settings,"舞台设置");
        assert_eq!(next.slot_width(),44.);
        assert_eq!(visual.slot_width(),68.);
        assert_eq!([next.slot_width(),visual.slot_width()],[stage_metrics::CONTROL_SIZE,stage_metrics::SETTINGS_WIDTH]);
        assert_eq!([stage_metrics::SIDE_INSET,stage_metrics::GROUP_GAP],[4.,6.]);
        // The bar width the shell places is the foundation's own derivation:
        // 9 regular buttons + the settings slot + the extra control slot +
        // two 4 pt insets + two 6 pt gaps + the rounding term.
        let derived=stage_metrics::CONTROL_SIZE*(shell_metrics::REGULAR_BUTTONS as f32+1.)+stage_metrics::SETTINGS_WIDTH
            +2.*stage_metrics::SIDE_INSET+2.*stage_metrics::GROUP_GAP+shell_metrics::TRANSPORT_ROUNDING;
        assert_eq!(derived,shell_metrics::TRANSPORT_WIDTH);
        let mut controls=(0..10).map(|_|TransportControl::new("regular","regular",IconName::Music,"regular")).collect::<Vec<_>>();
        controls.push(visual);
        assert_eq!(gmgn_gpui_ui::shell::transport_width(&controls),shell_metrics::TRANSPORT_WIDTH);
        assert_eq!([shell_metrics::TRANSPORT_WIDTH,shell_metrics::TRANSPORT_HEIGHT,scene_tokens::PANEL_RADIUS_SMALL],[529.,48.,16.]);
        assert_eq!(shell_metrics::TRANSPORT_INSET,22.);
    }
    /// 目的地 and 任务状态区 keep the original frames; 小窗 keeps 224×336.
    #[test]
    fn destination_task_status_and_compact_window_pin_the_original_frames() {
        assert_eq!([shell_metrics::DESTINATION_WIDTH,shell_metrics::DESTINATION_HEIGHT,shell_metrics::DESTINATION_RADIUS],[112.,38.,19.]);
        assert_eq!([shell_metrics::TRANSPORT_INSET,shell_metrics::DESTINATION_TOP,shell_metrics::DESTINATION_FONT],[22.,28.,11.]);
        assert_eq!([shell_metrics::TASK_FEEDBACK_WIDTH,shell_metrics::TASK_FEEDBACK_INSET],[280.,22.]);
        assert_eq!([shell_metrics::COMPACT_WIDTH,shell_metrics::COMPACT_HEIGHT],[224.,336.]);
        assert_eq!([shell_metrics::COMPACT_MARGIN,shell_metrics::COMPACT_CONTROL,shell_metrics::COMPACT_CONTROL_GAP],[10.,30.,6.]);
        assert_eq!(shell_metrics::COMPACT_CONTENT_RIGHT,48.);
        assert_eq!([shell_metrics::COMPACT_REPLY_COLLAPSED,shell_metrics::COMPACT_REPLY_EXPANDED,shell_metrics::COMPACT_DISMISS],[74.,136.,20.]);
    }
    /// `on_children_prepainted` indexes the grown children, so the composer's
    /// drop region is only correct while the plan is the real child order. A
    /// reordered child fails here instead of pointing the region elsewhere.
    #[test]
    fn overlay_plan_pins_the_composer_index_to_the_real_child_order() {
        use OverlaySlot::*;
        let plan=overlay_plan(&overlay_state(false,true,true,true,false));
        assert_eq!(plan.iter().position(|slot|*slot==Composer),Some(5));
        assert_eq!(plan,[Lyrics,Transport,Destination,ScreenBanner,Notices,Composer]);
        let plan=overlay_plan(&overlay_state(true,true,true,false,true));
        assert_eq!(plan.iter().position(|slot|*slot==Composer),Some(2));
        assert_eq!(plan,[CompactControls,Notices,Composer,CompactReply]);
        // The stage/program/props panels come after the composer and never move it.
        let mut state=overlay_state(false,true,true,false,false);
        state.stage_panel_open=true;state.program_open=true;state.props_open=true;state.bound_video=true;
        let plan=overlay_plan(&state);
        assert_eq!(plan.iter().position(|slot|*slot==Composer),Some(4));
        assert_eq!(plan,[Lyrics,Transport,Destination,Notices,Composer,StagePanel,Program,Props,BoundVideo]);
        // No chat panel, no drop region.
        assert_eq!(overlay_plan(&overlay_state(false,false,false,false,false)).iter().position(|slot|*slot==Composer),None);
        assert_eq!(overlay_plan(&overlay_state(true,false,false,false,false)),[CompactControls]);
    }
    /// The passthrough regions are the same indices as before, now derived from
    /// the plan instead of hand-written (the old `[0]`/`[3]` literals).
    #[test]
    fn passive_hit_regions_are_the_lyrics_layer_and_the_screen_banner() {
        let plan=overlay_plan(&overlay_state(false,true,true,true,false));
        let passive:Vec<usize>=plan.iter().enumerate().filter(|(_,slot)|slot.passive()).map(|(index,_)|index).collect();
        assert_eq!(passive,[0,3]);
        let plan=overlay_plan(&overlay_state(true,true,true,false,true));
        assert!(plan.iter().all(|slot|!slot.passive()));
    }
    /// Every surface the shell paints is a fixed original literal, so a light
    /// system theme can never invert a panel that floats over the scene.
    #[test]
    fn overlay_colours_are_fixed_scene_surfaces_not_theme_colours() {
        use gmgn_gpui_ui::ui_tokens::scene as s;
        assert_eq!(s::PANEL_BG,0x1a1a1af5);
        assert_eq!(s::BAR_BG,0x0a0a0ab8);
        assert_eq!(s::WARNING,0xff9500f2);
        assert_eq!(shell_metrics::TRANSPORT_BG,0x13161bfa);
        assert_eq!(shell_metrics::COMPACT_CONTROL_BG,0x1f1f1ff0);
        assert_eq!(shell_metrics::COMPACT_CONTROL_BORDER,0xffffff2e);
        assert_eq!(shell_metrics::DESTINATION_TEXT,0x7af2ffff);
        assert_eq!(shell_metrics::DESTINATION_BORDER,0x47dbff7a);
        assert_eq!(shell_metrics::SCREEN_BANNER,0x0a4d6beb);
        assert_eq!(shell_metrics::SCREEN_BANNER_BORDER,0x22d3ee73);
        assert_eq!(shell_metrics::BADGE_BG,0xff453ae6);
    }
    fn assert_embedded_icon(icon:gpui_kit::assets::IconName) {
        use gpui_kit::AssetSource;
        let assets=gpui_kit::assets::AllAssets;
        let path=icon.path();
        let bytes=assets.load(path.as_ref()).unwrap().expect("embedded icon");
        assert!(matches!(bytes,std::borrow::Cow::Borrowed(_)),"debug product must embed icons");
        assert!(std::str::from_utf8(&bytes).unwrap().contains("<svg"));
    }
    #[test]
    fn every_production_icon_has_embedded_svg_bytes() {
        for id in ["space","player","program","previous","next","play","voice","chat","inbox","props","screen","visual","mode","settings"] {
            assert_embedded_icon(control_icon(id));
        }
        // The realtime voice glyph (`StageVoiceButton.setState`) and the task
        // status symbols (`WishMachineTaskStatusView`) live in the same row.
        for state in ["disconnected","connecting","listening","speaking","failed(boom)"] {
            assert_embedded_icon(voice_icon(Some(state)));
        }
        assert_embedded_icon(gpui_kit::assets::IconName::WifiOff);
        assert_embedded_icon(gpui_kit::assets::IconName::CirclePause);
        assert_embedded_icon(gpui_kit::assets::IconName::Hand);
        assert_embedded_icon(window_mode_content(false).0);
        assert_embedded_icon(window_mode_content(true).0);
        assert_embedded_icon(gpui_kit::assets::IconName::SquareStack);
        assert_embedded_icon(gpui_kit::assets::IconName::MousePointerClick);
    }
}

fn main() {
    let host = Rc::new(RefCell::new(None::<ProductHost>));
    let main_ui=Rc::new(RefCell::new(None::<Entity<GMGNProductUI>>));
    let main_window=Rc::new(RefCell::new(None::<AnyWindowHandle>));
    let reopen_host = host.clone();
    let http_client=reqwest_client::ReqwestClient::user_agent("gmgn radio").expect("initialize GPUI HTTP client");
    let application = gpui_kit::application().with_http_client(std::sync::Arc::new(http_client)).with_assets(gpui_kit::assets::AllAssets);
    application.on_reopen(move |_| { if let Some(host) = reopen_host.borrow().as_ref() { host.reopen(); } });
    application.run(move |cx| {
        gpui_kit::init(cx);
        cx.on_action(|_: &Quit, cx| cx.quit());
        let settings_ui=main_ui.clone();
        cx.on_action(move |_:&ShowSettings,cx| {
            if let Some(ui)=settings_ui.borrow().as_ref() {ui.update(cx,|ui,cx|ui.open_settings(cx));}
        });
        let compact_host=host.clone();let compact_ui=main_ui.clone();
        cx.on_action(move |_:&ShowLiveCam,cx| {
            // App actions run while their dispatch window is already borrowed.
            // Do not re-enter that WindowHandle and silently discard its error.
            // The real product navigation revision is applied by the next
            // window-owned tick, exactly like the original status-item menu.
            let accepted=compact_host.borrow().as_ref().is_some_and(|host|host.action("showLiveCam"));
            eprintln!("GMGN_GPUI_NAV_ACTION mode=liveCam accepted={accepted}");
            if !accepted {if let Some(ui)=compact_ui.borrow().as_ref(){ui.update(cx,|ui,cx|{ui.core_notice=Some("小窗切换未完成，请重试。".into());cx.notify();});}}
        });
        let escape_ui=main_ui.clone();let escape_window=main_window.clone();
        cx.on_action(move |_:&EscapeStage,cx| {
            if let (Some(ui),Some(handle))=(escape_ui.borrow().as_ref(),*escape_window.borrow()) {
                if cx.active_window().is_some_and(|active|active.window_id()==handle.window_id()) {
                    ui.update(cx,|ui,cx|ui.escape_stage(cx));
                }
            }
        });
        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None),KeyBinding::new("cmd-,",ShowSettings,None),KeyBinding::new("escape",EscapeStage,None)]);
        let activities_ui=main_ui.clone();
        cx.on_action(move |_:&ShowActivities,cx| {
            if let Some(ui)=activities_ui.borrow().as_ref(){ui.update(cx,|ui,cx|ui.open_settings_page("activities",cx));}
        });
        cx.set_menus([
            Menu::new("gmgn radio").items([MenuItem::action("显示小窗",ShowLiveCam),MenuItem::action("角色活动…",ShowActivities),MenuItem::action("设置…",ShowSettings),MenuItem::separator(),MenuItem::action("退出 gmgn radio", Quit)]),
            Menu::new("编辑").items([
                MenuItem::action("撤销", gpui_kit::component::input::Undo),
                MenuItem::action("重做", gpui_kit::component::input::Redo),
                MenuItem::separator(),
                MenuItem::action("剪切", gpui_kit::component::input::Cut),
                MenuItem::action("复制", gpui_kit::component::input::Copy),
                MenuItem::action("粘贴", gpui_kit::component::input::Paste),
                MenuItem::action("全选", gpui_kit::component::input::SelectAll),
            ]),
        ]);
        Theme::change(ThemeMode::Dark, None, cx);
        let core_notice = match ProductHost::load() {
            Ok(product) => { *host.borrow_mut() = Some(product); None }
            Err(error) => Some(error),
        };
        let quit_host = host.clone();
        let quit_ui=main_ui.clone();
        cx.on_app_quit(move |_| {
            quit_ui.borrow_mut().take();
            quit_host.borrow_mut().take();
            async {}
        }).detach();
        // Initial compact requests use the same real avatar guard as the menu.
        if std::env::var("GMGN_GPUI_COMPACT").as_deref() == Ok("1") {
            if let Some(host)=host.borrow().as_ref(){host.action("showLiveCam");}
        }
        let compact = false;
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(80.), px(80.)),
                if compact { size(px(shell_metrics::COMPACT_WIDTH), px(shell_metrics::COMPACT_HEIGHT)) } else { size(px(1180.), px(760.)) }))),
            window_min_size: if compact {None}else{Some(size(px(760.),px(520.)))},
            kind: if compact { WindowKind::PopUp } else { WindowKind::Normal },
            titlebar: if compact { None } else { Some(TitlebarOptions{appears_transparent:true,..Default::default()}) },
            is_resizable: !compact,
            focus: !compact,
            window_background: WindowBackgroundAppearance::Transparent,
            ..Default::default()
        };
        cx.open_window(options, move |window, cx| {
            *main_window.borrow_mut()=Some(Window::window_handle(window));
            window.set_window_title("gmgn radio");
            let view = cx.new(|cx| {
                let pane = cx.new(|cx| ResidentChatPane::new(window, cx).compact(compact));
                let settings_pane=cx.new(|cx|AgentSettingsPane::new(window,cx));
                let inbox_pane=cx.new(InboxPane::new);
                let stage_pane=cx.new(|cx|StagePanelsPane::new(window,cx));
                settings_pane.update(cx,|pane,cx|pane.set_stage_pane(stage_pane.clone(),cx));
                let program_pane=cx.new(|cx|StageProgramRailPane::new(window,cx));
                let prop_pane=cx.new(|cx|ResidentPropEditorPane::new(window,cx));
                let lyrics_pane=cx.new(|cx|StageLyricsPane::new(window,cx));
                let bound_video_pane=cx.new(|cx|StageBoundVideoPromptPane::new(window,cx));
                let poll = cx.spawn_in(window, async move |view, cx| {
                    loop {
                        cx.background_executor().timer(Duration::from_millis(100)).await;
                        if view.update_in(cx, |view: &mut GMGNProductUI, window, cx| view.tick(window, cx)).is_err() { break; }
                    }
                });
                GMGNProductUI { host: host.clone(), pane, settings_pane, settings_window:None, inbox_pane, inbox_window:None, stage_pane,stage_panel_open:false,
                    program_pane,program_open:false,program_backdrop:Rc::new(RefCell::new(None)),lyrics_layer:Rc::new(RefCell::new(None)),prop_pane,lyrics_pane,lyrics_error_logged:None,bound_video_pane,props_open:false,chat_open:false,composer_focus_pending:false, voice_held:false, pending: None, accepted: false,
                    transcript: vec![], compact, core_notice, runtime_state: serde_json::Value::Null,
                    surface_mounted: false,navigation_revision:0,error_notice_revision:0,main_window:main_window.clone(),profile_switch_pending:false,dismissed_reply_revision:None,player_menu_open:false,program_visibility_reported:None, _poll: poll }
            });
            *main_ui.borrow_mut()=Some(view.clone());
            cx.new(|cx| gpui_kit::base::Root::new(view, window, cx).bg(rgba(chrome::WINDOW_CLEAR)))
        }).expect("open gmgn product window");
    });
}
