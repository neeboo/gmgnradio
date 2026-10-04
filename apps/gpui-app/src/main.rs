use gmgn_gpui_ui::{ResidentChatPane, state::{ChatCommand, TranscriptLine}};
use gpui_kit::component::{button::*, *};
use gpui_kit::component::menu::{DropdownMenu,PopupMenuItem};
use gmgn_gpui_ui::settings::AgentSettingsPane;
use gmgn_gpui_ui::inbox::InboxPane;
use gmgn_gpui_ui::stage_panels::{StagePanelsPane,StageProgramRailPane,ResidentPropEditorPane};
use gmgn_gpui_ui::lyrics::{StageLyricsPane,StageBoundVideoPromptPane};
use gpui_kit::*;
use gpui_kit::prelude::FluentBuilder;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::{cell::RefCell, rc::Rc, time::Duration,ffi::{c_void,c_char,CStr}};
mod host_events;
mod product_host;
mod program_backdrop;
mod lyrics_layer;
mod system_symbol;
use product_host::ProductHost;
gpui_kit::actions!(gmgn_product, [Quit,ShowSettings,ShowLiveCam,EscapeStage]);

fn window_still_registered<T: PartialEq>(cached: T, live: impl IntoIterator<Item=T>) -> bool {
    live.into_iter().any(|id| id == cached)
}

fn modal_owns_scene_input(menu: bool, dialog: bool, sheet: bool) -> bool {
    menu || dialog || sheet
}
unsafe extern "C" {
    fn gmgn_gpui_bitmap_drop_region(view:*mut c_void,x:f64,y:f64,w:f64,h:f64,enabled:i32);
    fn gmgn_gpui_take_bitmap_drop(view:*mut c_void)->*mut c_char;
    fn gmgn_gpui_bitmap_drop_string_free(value:*mut c_char);
}

fn composer_frame(compact:bool,width:f32,height:f32)->[f32;4] {
    if compact {[10.,height-80.,(width-58.).max(0.),70.]} else {
        let w=(width-44.).clamp(0.,620.);let h=(height-108.).clamp(0.,320.);
        [width-22.-w,height-86.-h,w,h]
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
fn expanded_reply_text(transcript:&[TranscriptLine], latest:&str)->String {
    let mut content=transcript.iter().map(|line|if line.speaker.is_empty(){line.text.clone()}else{format!("{}：{}",line.speaker,line.text)}).collect::<Vec<_>>().join("\n\n");
    let normalized=latest.trim();
    if !normalized.is_empty() && transcript.iter().rev().find(|line|line.speaker=="居民").map(|line|line.text.as_str())!=Some(normalized) {
        if !content.is_empty(){content.push_str("\n\n");}
        content.push_str(normalized);
    }
    content
}
fn control_icon(id:&str)->gpui_kit::assets::IconName {
    use gpui_kit::assets::IconName;
    match id {
        "space"=>IconName::House,"player"=>IconName::Music,"program"=>IconName::ListMusic,
        "previous"=>IconName::SkipBack,"next"=>IconName::SkipForward,"play"=>IconName::Play,
        "voice"=>IconName::Mic,"chat"=>IconName::MessageCircle,"inbox"=>IconName::Mail,
        "props"=>IconName::Package,"screen"=>IconName::Monitor,"visual"=>IconName::SlidersHorizontal,
        "mode"=>IconName::Maximize,_=>IconName::Settings,
    }
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
                self.core_notice=Some("场景操作未完成，原状态保持不变。".into());cx.notify();
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
                self.core_notice=Some("设置操作未能被原应用接收，原配置保持不变。".into());cx.notify();
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
    }
    fn native_action(&mut self, action: &str, cx: &mut Context<Self>) {
        let success = self.host.borrow().as_ref().is_some_and(|host| host.action(action));
        if !success { self.core_notice = Some("这个原有功能入口暂未能打开，请检查应用启动状态。".into()); }
        else {self.core_notice=None;}
        cx.notify();
    }
    fn open_settings(&mut self,cx:&mut Context<Self>) {
        self.open_settings_page("presence",cx);
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
            window_bounds:Some(WindowBounds::Windowed(Bounds::new(point(px(120.),px(100.)),size(px(580.),px(500.))))),
            window_min_size:Some(size(px(540.),px(440.))),
            ..Default::default()
        },move |window,cx| {
            window.set_window_title("设置");
            window.defer(cx,|window,_| {
                if let Ok(handle)=HasWindowHandle::window_handle(window) {
                    if let RawWindowHandle::AppKit(handle)=handle.as_raw() {
                        product_host::set_window_outer_size(handle.ns_view.as_ptr(),580.,500.,540.,440.);
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
            "visual" => {self.stage_panel_open=!self.stage_panel_open;if self.stage_panel_open{self.chat_open=false;self.program_open=false;self.props_open=false;}cx.notify();},
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
            window_bounds:Some(WindowBounds::Windowed(Bounds::new(location,if compact{size(px(224.),px(336.))}else{size(px(1180.),px(760.))}))),
            window_min_size:if compact{None}else{Some(size(px(760.),px(520.)))},
            kind:if compact{WindowKind::PopUp}else{WindowKind::Normal},
            titlebar:if compact{None}else{Some(TitlebarOptions{appears_transparent:true,..Default::default()})},
            is_resizable:!compact,focus:!compact,window_background:WindowBackgroundAppearance::Transparent,
            ..Default::default()
        },move |window,cx| {
            window.set_window_title("gmgn radio");
            cx.new(|cx|gpui_kit::base::Root::new(content,window,cx).bg(rgba(0x00000000)))
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
    fn control(&self,id:&'static str,label:&'static str,action:&'static str,width:f32,height:f32,cx:&mut Context<Self>)->impl IntoElement {
        let label=if id=="chat"&&!self.compact&&self.runtime_state["stage"]["presentation"]["chatAvailable"].as_bool()!=Some(true){"进入空间后与居民聊天"}else if id=="visual" {if self.stage_panel_open{"收起设置"}else{"舞台设置：播放器、空间、角色与活动"}}else if id=="screen" {
            if self.runtime_state["screenOperation"]["active"].as_bool()==Some(true){"完成操作（Esc）"}
            else if self.runtime_state["screenOperation"]["available"].as_bool()==Some(true){"操作电视"}
            else {"这块空间里还没有在放的电视"}
        }else if id=="chat"&&!self.compact {if self.chat_open{"收起聊天"}else{"与居民聊天"}}else{label};
        let button=Button::new(id).ghost();
        let button=if id=="chat"&&!self.compact {
            button.when_some(system_symbol::tinted_image(if self.chat_open{"bubble.left.fill"}else{"bubble.left"},if self.chat_open{1}else{2}),|button,image|button.child(img(image).w(px(16.)).h(px(16.)).object_fit(ObjectFit::Contain)))
                .when(self.chat_open,|button|button.bg(rgba(system_symbol::system_blue_background())))
        }else{button.icon(if id=="visual"&&self.stage_panel_open {gpui_kit::assets::IconName::X}else if id=="play"&&self.runtime_state["playbackState"].as_str()==Some("playing"){gpui_kit::assets::IconName::Pause}else{control_icon(id)})};
        let button=button
            .accessibility_label(label).tooltip(label).w(px(width)).h(px(height));
        let button=if id=="visual"{button.px(px(6.)).child(div().text_size(px(12.)).whitespace_nowrap().child(if self.stage_panel_open{"收起"}else{"设置"}))}else{button};
        let button=if self.compact {button.rounded(px(15.)).bg(rgba(0x1f1f1ff0)).border_1().border_color(rgba(0xffffff2e)).text_color(rgb(0xffffff))}else{button};
        let button=if id=="screen"{button.disabled(self.runtime_state["screenOperation"]["available"].as_bool()!=Some(true))}else{button};
        let button=if id=="chat"&&!self.compact{button.disabled(self.runtime_state["stage"]["presentation"]["chatAvailable"].as_bool()!=Some(true))}else if id=="props"{button.disabled(self.runtime_state["stage"]["presentation"]["propsAvailable"].as_bool()!=Some(true))}else{button};
        let button=if !self.compact {
            match id {
                "previous"=>button.disabled(self.runtime_state["liveCamPlayerMenu"]["canSelectPrevious"].as_bool()!=Some(true)),
                "play"=>button.disabled(self.runtime_state["liveCamPlayerMenu"]["canTogglePlayback"].as_bool()!=Some(true)),
                "next"=>button.disabled(self.runtime_state["liveCamPlayerMenu"]["canSelectNext"].as_bool()!=Some(true)),
                _=>button
            }
        }else{button};
        let button=if id=="player"&&self.compact {
            let snapshot=self.runtime_state["liveCamPlayerMenu"].clone();let weak=cx.entity().downgrade();let popup_weak=weak.clone();
            button.dropdown_menu(move |menu,_,_| {
                let mut menu=menu.item(PopupMenuItem::new(snapshot["menuTitle"].as_str().unwrap_or("播放器尚未准备好").to_owned()).disabled(true)).separator();
                for (title,action,flag) in [("上一首","previousTrack","canSelectPrevious"),(snapshot["playPauseTitle"].as_str().unwrap_or("播放"),"togglePlayback","canTogglePlayback"),("下一首","nextTrack","canSelectNext")] {
                    let weak=weak.clone();
                    menu=menu.item(PopupMenuItem::new(title.to_owned()).disabled(snapshot[flag].as_bool()!=Some(true)).on_click(move |_,_,cx|{let _=weak.update(cx,|ui,cx|ui.native_action(action,cx));}));
                }
                let weak=weak.clone();menu.separator().item(PopupMenuItem::new("进入播放器").on_click(move |_,_,cx|{let _=weak.update(cx,|ui,cx|ui.native_action("showPlayer",cx));}))
            }).on_open_change(move |open,_,cx|{let _=popup_weak.update(cx,|ui,cx|{ui.player_menu_open=*open;cx.notify();});}).into_any_element()
        }else if action=="voice" {
            button.on_mouse_down(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(true,cx)))
                .on_mouse_up(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(false,cx)))
                .on_mouse_up_out(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(false,cx))).into_any_element()
        } else {button.on_click(cx.listener(move |this,_,window,cx|{
            if action=="mode" {window.toggle_fullscreen();cx.notify();}
            else if action=="showStage" {this.switch_profile(false,Some("space"),window,cx);}
            else if action=="showPlayer" {this.switch_profile(false,Some("player"),window,cx);}
            else {this.overlay_action(action,cx);}
        })).into_any_element()};
        let mut control=div().relative().w(px(width)).h(px(height)).child(button);
        let count=inbox_unread(&self.runtime_state);
        if id=="inbox"&&count>0 {
            control=control.child(div().absolute().top(px(1.)).left(px(width/2.+4.)).min_w(px(14.)).h(px(14.)).rounded(px(7.)).bg(rgba(0xff453ae6)).text_color(rgb(0xffffff)).text_size(px(9.)).flex().items_center().justify_center().child(if count>99{"99+".into()}else{count.to_string()}));
        }
        control
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
        let background = cx.theme().tokens.background;
        let foreground = cx.theme().foreground;
        let mut notices = if self.compact {
            div().id("product-runtime-notices").flex().flex_col().gap(px(6.)).text_size(px(10.))
        }else{div().id("product-runtime-notices").max_h(px(220.)).overflow_y_scroll().p_2().text_sm().line_height(relative(1.4))};
        let mut notice_count=0;
        let task_feedback_visible=self.compact||self.runtime_state["stage"]["presentation"]["taskFeedbackVisible"].as_bool()==Some(true);
        let mut seen_notices=Vec::new();
        let notice_fields=if self.compact {["ttsError","speechError","inboxPersistenceError","statusNotice"]}else{["statusNotice","ttsError","speechError","inboxPersistenceError"]};
        for field in notice_fields {
            if let Some(notice) = self.runtime_state[field].as_str().filter(|s| !s.is_empty()) {
                if seen_notices.contains(&notice){continue;}
                seen_notices.push(notice);
                let item=if self.compact {
                    let item=div().min_h(px(24.)).px(px(8.)).py(px(8.)).rounded(px(10.)).bg(rgba(0x1f1f1ff0)).text_size(px(if field=="statusNotice"{10.}else{11.})).text_color(rgb(0xff9f0a)).child(notice.to_owned());
                    if field=="statusNotice"{item}else{item.line_clamp(3)}
                }else{div().text_xs().text_color(cx.theme().muted_foreground).child(notice.to_owned())};
                notices = notices.child(item);
                notice_count+=1;
            }
        }
        if let Some(message)=self.runtime_state["autonomy"]["connectivityNotice"].as_str().filter(|s|task_feedback_visible&&!s.is_empty()) {
            notices=notices.child(div().id("resident.connectivity-banner").rounded(px(10.)).p(px(if self.compact{6.}else{10.})).bg(rgba(0x1a1a1af5)).text_size(px(if self.compact{9.}else{11.})).text_color(rgb(0xff9f0a)).line_clamp(if self.compact{2}else{3}).child(message.to_owned()));notice_count+=1;
        }
        let autonomy=self.runtime_state["autonomy"]["switchOn"].as_bool();
        if task_feedback_visible&&(autonomy==Some(false)||self.runtime_state["autonomy"]["stopped"].as_bool()==Some(true)) {
            let enabled=autonomy==Some(true);
            let mut banner=div().id("resident.autonomy-banner").flex().flex_col().gap_1().rounded_lg().p_2().bg(cx.theme().muted).text_xs().child(div().flex().items_center().justify_between().text_color(cx.theme().warning)
                .child(if enabled{"自主行动已停止"}else{"居民自主行动已关闭"})
                .child(Button::new("resident.autonomy.resume").ghost().xsmall().flex_shrink_0().label(if enabled{"恢复自主行动"}else{"打开自主行动"}).on_click(cx.listener(|this,_,_,cx|this.overlay_action("resume-autonomy",cx)))));
            if !self.compact {banner=banner.child(div().text_xs().line_height(relative(1.4)).text_color(cx.theme().muted_foreground).child("关闭后，居民暂停自主安排；你发送的指令仍会执行。"));}
            if let Some(message)=self.runtime_state["autonomy"]["resumeFailure"].as_str().filter(|s|!s.is_empty()) {
                banner=banner.child(div().id("resident.autonomy.resume-failure").text_size(px(9.)).text_color(rgb(0xff9f0a)).child(message.to_owned()));
            }
            notices=notices.child(banner);
            notice_count+=1;
        }
        if let Some(notice)=&self.core_notice {
            notices=if self.compact{notices.child(div().rounded(px(10.)).p(px(8.)).bg(rgba(0x1f1f1ff0)).text_size(px(10.)).text_color(rgb(0xff9f0a)).child(notice.clone()))}else{notices.child(notice.clone())};notice_count+=1;
        }
        let viewport=window.viewport_size();let width=viewport.width.as_f32();let height=viewport.height.as_f32();
        let compact_composer_height=if self.runtime_state["attachments"].as_array().is_some_and(|images|!images.is_empty()) || self.runtime_state["attachmentsPreparing"].as_bool()==Some(true) || self.runtime_state["attachmentError"].as_str().is_some_and(|error|!error.is_empty()){140.}else{70.};
        let mut root=div().size_full().relative().font_family(cx.theme().font_family.clone()).text_size(px(gmgn_gpui_ui::ui_tokens::BODY)).line_height(px(gmgn_gpui_ui::ui_tokens::BODY_LINE_HEIGHT)).text_color(foreground);
        self.lyrics_pane.update(cx,|pane,cx|pane.set_visible(!self.compact,cx));
        if !self.compact {
            self.lyrics_pane.update(cx,|pane,_|pane.set_viewport_size(width,height));
            root=root.child(div().absolute().size_full().child(self.lyrics_pane.clone()));
        }
        if self.compact {
            let mut controls=div().absolute().top(px(10.)).right(px(10.)).w(px(30.)).flex().flex_col().gap(px(6.));
            for (id,label,action) in [("space","空间","showStage"),("player","音乐","showPlayer"),("chat","聊天","chat"),("inbox","通知","showNotifications"),("voice","语音","voice"),("settings","设置","settings")] {
                controls=controls.child(self.control(id,label,action,30.,30.,cx));
            }
            root=root.child(controls);
            if notice_count>0 {
                root=root.child(notices.absolute().left(px(10.)).right(px(48.)).bottom(px(compact_composer_height+16.)));
            }
            if self.chat_open {
                root=root.child(div().absolute().left(px(10.)).right(px(48.)).bottom(px(10.)).h(px(compact_composer_height)).child(self.pane.clone()));
            }
            if let Some(reply)=compact_reply_text(&self.runtime_state,&self.transcript).filter(|_|latest_reply_revision(&self.runtime_state)!=self.dismissed_reply_revision) {
                let content=if self.chat_open{div().id("livecam.full-reply").flex_1().min_w(px(0.)).min_h(px(0.)).overflow_y_scroll().text_size(px(12.)).child(expanded_reply_text(&self.transcript,&reply)).into_any_element()}else{div().flex_1().min_w(px(0.)).text_size(px(12.)).line_clamp(3).child(reply).into_any_element()};
                let bubble=div().id("compact-reply-bubble").absolute().left(px(10.)).right(px(48.)).top(px(10.)).p_2().rounded(px(10.)).bg(background).flex().items_start().gap(px(5.));
                let bubble=if self.chat_open{bubble.h(px(136.))}else{bubble.max_h(px(74.))};
                root=root.child(bubble
                    .on_click(cx.listener(|this,_,_,cx|{this.chat_open=true;this.composer_focus_pending=true;cx.notify();}))
                    .child(content)
                    .child(Button::new("livecam.reply-dismiss").ghost().icon(gpui_kit::assets::IconName::X).w(px(20.)).h(px(20.)).accessibility_label("关闭回复气泡").tooltip("关闭回复气泡").on_click(cx.listener(|this,_,_,cx|{cx.stop_propagation();this.dismissed_reply_revision=latest_reply_revision(&this.runtime_state);cx.notify();}))));
            }
        } else {
            let mut transport=div().absolute().right(px(22.)).bottom(px(22.)).w(px(529.)).h(px(48.)).flex().items_center().px(px(4.)).rounded_xl().bg(background);
            for (id,label,action) in [("program","节目","program"),("previous","上首","previousTrack"),("play","播放","togglePlayback"),("next","下首","nextTrack"),("voice","语音","voice"),("chat","聊天","chat"),("inbox","通知","showNotifications"),("props","装修","toggleDecoration"),("screen","屏幕操作","screen"),("visual","舞台设置","visual"),("mode","窗口","mode")] {
                transport=transport.child(self.control(id,label,action,if id=="visual"{68.}else{44.},44.,cx));
                if id=="next" {transport=transport.child(div().w(px(13.)).flex_shrink_0().flex().items_center().justify_center().child(div().w(px(1.)).h(px(20.)).bg(rgba(0xffffff1f))));}
            }
            let in_space=self.runtime_state["stage"]["mode"].as_str()==Some("space");
            root=root.child(transport).child(Button::new("destination").ghost()
                .child(div().flex().items_center().gap(px(4.)).when_some(system_symbol::image(if in_space{"circle.hexagongrid.fill"}else{"cube.transparent"}),|view,image|view.child(img(image).w(px(12.)).h(px(12.)).object_fit(ObjectFit::Contain))).child(if in_space{"播放器"}else{"空间"}))
                .accessibility_label(if in_space{"切换到播放器"}else{"进入空间"})
                .tooltip(if in_space{"返回播放器"}else{"进入空间"})
                .w(px(112.)).h(px(38.)).rounded(px(19.)).bg(rgba(0x0a0a0ab8))
                .border_1().border_color(rgba(0x47dbff7a)).text_color(rgb(0x7af2ff)).text_size(px(gmgn_gpui_ui::ui_tokens::BODY)).font_weight(FontWeight::SEMIBOLD)
                .absolute().right(px(22.)).top(px(28.)).on_click(cx.listener(|this,_,_,cx|this.overlay_action("destination",cx))));
            if self.runtime_state["screenOperation"]["active"].as_bool()==Some(true) {
                root=root.child(div().id("stage.screen-operation-banner").absolute().right(px(173.5)).bottom(px(82.)).w(px(226.)).h(px(30.)).flex().items_center().justify_center().rounded_xl().bg(rgba(0x0a4d6beb)).text_sm().child("正在操作电视，按 Esc 退出"));
            }
            if notice_count>0 {
                root=root.child(notices.absolute().left(px(22.)).top(px(22.)).w(px(280.)).bg(background));
            }
            if self.chat_open {
                let frame=composer_frame(false,width,height);let composer_width=frame[2];let composer_height=frame[3];
                root=root.child(div().absolute().right(px(22.)).bottom(px(86.)).w(px(composer_width)).max_h(px(composer_height)).overflow_hidden().bg(background).rounded_xl().child(self.pane.clone()));
            }
            if self.stage_panel_open {
                let panel_width=(width-36.).clamp(0.,590.);let panel_height=(height-92.).clamp(0.,458.);
                root=root.child(div().absolute().right(px(18.)).bottom(px(80.)).w(px(panel_width)).h(px(panel_height)).child(self.stage_pane.clone()));
            }
            if self.program_open {
                let w=350_f32.min(width-36.);let h=430_f32.min(height-80.);
                root=root.child(div().absolute().right(px(18.)).bottom(px(80.)).w(px(w)).h(px(h)).child(self.program_pane.clone()));
            }
            if self.props_open {
                let h=390_f32.min(height-98.);
                root=root.child(div().absolute().right(px(22.)).bottom(px(82.)).w(px(340.)).h(px(h)).child(self.prop_pane.clone()));
            }
            if self.bound_video_pane.read(cx).is_visible() {
                root=root.child(div().absolute().top(px(28.)).right(px(32.)).w(px(330.)).h(px(58.)).child(self.bound_video_pane.clone()));
            }
        }
        let host=self.host.clone();
        let menu_open=self.player_menu_open;
        let composer_index=if self.chat_open {
            Some(if self.compact{1+usize::from(notice_count>0)}else{3+usize::from(self.runtime_state["screenOperation"]["active"].as_bool()==Some(true))+usize::from(notice_count>0)})
        }else{None};
        // The original screen-operation banner never takes scene pointer
        // events. All other overlay hit regions use actual computed bounds,
        // including wrapped notices and the complete autonomy card.
        let mut passive_indices=Vec::new();
        if !self.compact {passive_indices.push(0);if self.runtime_state["screenOperation"]["active"].as_bool()==Some(true){passive_indices.push(3);}}
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
    use super::{composer_frame,control_icon};
    #[test]
    fn stage_composer_preserves_original_margins_and_maximums() {
        assert_eq!(composer_frame(false,1100.,760.),[458.,354.,620.,320.]);
        let frame=composer_frame(false,600.,400.);
        assert_eq!(frame,[22.,22.,556.,292.]);
        assert_eq!(600.-frame[0]-frame[2],22.);
        assert_eq!(400.-frame[1]-frame[3],86.);
    }
    #[test]
    fn compact_composer_never_enters_the_original_control_column() {
        let frame=composer_frame(true,224.,336.);
        assert_eq!(frame,[10.,256.,166.,70.]);
        assert_eq!(184.-frame[0]-frame[2],8.);
        assert_eq!(336.-frame[1]-frame[3],10.);
    }
    #[test]
    fn every_production_toolbar_icon_has_embedded_svg_bytes() {
        use gpui_kit::AssetSource;
        let assets=gpui_kit::assets::AllAssets;
        for id in ["space","player","program","previous","next","play","voice","chat","inbox","props","screen","visual","mode","settings"] {
            let path=control_icon(id).path();
            let bytes=assets.load(path.as_ref()).unwrap().expect("embedded icon");
            assert!(matches!(bytes,std::borrow::Cow::Borrowed(_)),"debug product must embed icons");
            assert!(std::str::from_utf8(&bytes).unwrap().contains("<svg"));
        }
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
        cx.set_menus([
            Menu::new("gmgn radio").items([MenuItem::action("显示小窗",ShowLiveCam),MenuItem::action("设置…",ShowSettings),MenuItem::separator(),MenuItem::action("退出 gmgn radio", Quit)]),
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
                if compact { size(px(224.), px(336.)) } else { size(px(1180.), px(760.)) }))),
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
                    surface_mounted: false,navigation_revision:0,main_window:main_window.clone(),profile_switch_pending:false,dismissed_reply_revision:None,player_menu_open:false,program_visibility_reported:None, _poll: poll }
            });
            *main_ui.borrow_mut()=Some(view.clone());
            cx.new(|cx| gpui_kit::base::Root::new(view, window, cx).bg(rgba(0x00000000)))
        }).expect("open gmgn product window");
    });
}
