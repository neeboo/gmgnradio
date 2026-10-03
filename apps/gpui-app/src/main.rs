use gmgn_gpui_ui::{ResidentChatPane, state::{ChatCommand, TranscriptLine}};
use gpui_kit::component::{button::*, *};
use gmgn_gpui_ui::settings::AgentSettingsPane;
use gmgn_gpui_ui::inbox::InboxPane;
use gmgn_gpui_ui::stage_panels::{StagePanelsPane,StageProgramRailPane,ResidentPropEditorPane};
use gpui_kit::*;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::{cell::RefCell, rc::Rc, time::Duration};
mod host_events;
mod product_host;
use product_host::ProductHost;
gpui_kit::actions!(gmgn_product, [Quit,ShowSettings,ShowLiveCam,EscapeStage]);

fn composer_frame(compact:bool,width:f32,height:f32)->[f32;4] {
    if compact {[10.,height-80.,(width-58.).max(0.),70.]} else {
        let w=(width-44.).clamp(0.,620.);let h=(height-108.).clamp(0.,320.);
        [width-22.-w,height-86.-h,w,h]
    }
}
fn inbox_unread(state:&serde_json::Value)->usize {
    state["inbox"]["entries"].as_array().map_or(0,|entries|entries.iter().filter(|entry|entry["isRead"].as_bool()==Some(false)).count())
}
fn control_icon(id:&str)->gpui_kit::assets::IconName {
    use gpui_kit::assets::IconName;
    match id {
        "space"=>IconName::House,"player"=>IconName::Music,"program"=>IconName::ListMusic,
        "previous"=>IconName::SkipBack,"next"=>IconName::SkipForward,"play"=>IconName::Play,
        "voice"=>IconName::Mic,"chat"=>IconName::MessageCircle,"inbox"=>IconName::Mail,
        "props"=>IconName::Package,"screen"=>IconName::Monitor,"visual"=>IconName::Settings,
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
    prop_pane: Entity<ResidentPropEditorPane>,
    props_open: bool,
    chat_open: bool,
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
    _poll: Task<()>,
}

impl GMGNProductUI {
    fn fail(&mut self, id: u64, notice: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.pane.update(cx, |pane, cx| pane.failed(id, notice.into(), window, cx));
        self.pending = None;
        self.accepted = false;
    }
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let stage_commands=self.stage_pane.update(cx,|pane,_|pane.take_commands());
        let program_commands=self.program_pane.update(cx,|pane,_|pane.take_commands());
        let prop_commands=self.prop_pane.update(cx,|pane,_|pane.take_commands());
        for command in stage_commands.into_iter().chain(program_commands).chain(prop_commands) {
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
            if let Some(open)=batch.state["propEditor"]["isOpen"].as_bool() {self.props_open=open;}
            self.settings_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["settings"].clone(),window,cx));
            self.runtime_state = batch.state; cx.notify();
        }
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
    fn open_settings_page(&mut self,page:&str,cx:&mut Context<Self>) {
        self.settings_pane.update(cx,|pane,cx|pane.select_page(page,cx));
        if let Some(handle)=self.settings_window {
            if handle.update(cx,|_,window,_|window.activate_window()).is_ok() {return;}
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
            "chat" => {self.chat_open=!self.chat_open;if self.chat_open{self.stage_panel_open=false;self.program_open=false;self.props_open=false;}cx.notify();},
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
                    window.set_window_title("系统消息");cx.new(|cx|gpui_kit::base::Root::new(pane,window,cx))
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
        let label=if id=="screen" {
            if self.runtime_state["screenOperation"]["active"].as_bool()==Some(true){"完成操作（Esc）"}
            else if self.runtime_state["screenOperation"]["available"].as_bool()==Some(true){"操作电视"}
            else {"这块空间里还没有在放的电视"}
        }else{label};
        let button=Button::new(id).ghost().icon(if id=="play"&&self.runtime_state["playbackState"].as_str()==Some("playing"){gpui_kit::assets::IconName::Pause}else{control_icon(id)})
            .accessibility_label(label).tooltip(label).w(px(width)).h(px(height));
        let button=if id=="screen"{button.disabled(self.runtime_state["screenOperation"]["available"].as_bool()!=Some(true))}else{button};
        let button=if action=="voice" {
            button.on_mouse_down(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(true,cx)))
                .on_mouse_up(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(false,cx)))
                .on_mouse_up_out(MouseButton::Left,cx.listener(|this,_,_,cx|this.voice_gesture(false,cx)))
        } else {button.on_click(cx.listener(move |this,_,window,cx|{
            if action=="mode" {window.toggle_fullscreen();cx.notify();}
            else if action=="showStage" {this.switch_profile(false,Some("space"),window,cx);}
            else if action=="showPlayer" {this.switch_profile(false,Some("player"),window,cx);}
            else {this.overlay_action(action,cx);}
        }))};
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
        let background = cx.theme().tokens.background;
        let foreground = cx.theme().foreground;
        let mut notices = div().id("product-runtime-notices").max_h(px(220.)).overflow_y_scroll().p_2();
        let mut notice_count=0;
        for field in ["statusNotice", "ttsError", "speechError", "inboxPersistenceError"] {
            if let Some(notice) = self.runtime_state[field].as_str().filter(|s| !s.is_empty()) {
                notices = notices.child(div().text_sm().child(notice.to_owned()));
                notice_count+=1;
            }
        }
        if let Some(message)=self.runtime_state["autonomy"]["connectivityNotice"].as_str().filter(|s|!s.is_empty()) {
            notices=notices.child(div().id("resident.connectivity-banner").rounded(px(10.)).p(px(if self.compact{6.}else{10.})).bg(rgba(0x1a1a1af5)).text_size(px(if self.compact{9.}else{11.})).text_color(rgb(0xff9f0a)).child(message.to_owned()));notice_count+=1;
        }
        let autonomy=self.runtime_state["autonomy"]["switchOn"].as_bool();
        if autonomy==Some(false)||self.runtime_state["autonomy"]["stopped"].as_bool()==Some(true) {
            let enabled=autonomy==Some(true);
            let mut banner=div().id("resident.autonomy-banner").flex().flex_col().gap(px(4.)).rounded(px(10.)).p(px(if self.compact{6.}else{10.})).bg(rgba(0x1a1a1af5)).text_size(px(if self.compact{9.}else{10.})).child(div().flex().items_center().justify_between()
                .child(if enabled{"自主行动已停止"}else{"居民自主行动已关闭"})
                .child(Button::new("resident.autonomy.resume").ghost().small().label(if enabled{"恢复自主行动"}else{"打开自主行动"}).on_click(cx.listener(|this,_,_,cx|this.overlay_action("resume-autonomy",cx)))));
            if !self.compact {banner=banner.child(div().text_size(px(9.)).text_color(rgba(0xffffff8c)).child("不自主不等于不听话：直接下达的指令在任何开关状态下都会执行。"));}
            if let Some(message)=self.runtime_state["autonomy"]["resumeFailure"].as_str().filter(|s|!s.is_empty()) {
                banner=banner.child(div().id("resident.autonomy.resume-failure").text_size(px(9.)).text_color(rgb(0xff9f0a)).child(message.to_owned()));
            }
            notices=notices.child(banner);
            notice_count+=1;
        }
        if let Some(notice)=&self.core_notice { notices=notices.child(notice.clone());notice_count+=1; }
        let viewport=window.viewport_size();let width=viewport.width.as_f32();let height=viewport.height.as_f32();
        let mut root=div().size_full().relative().text_color(foreground);
        if self.compact {
            let mut controls=div().absolute().top(px(10.)).right(px(10.)).w(px(30.)).flex().flex_col().gap(px(6.));
            for (id,label,action) in [("space","空间","showStage"),("player","音乐","showPlayer"),("chat","聊天","chat"),("inbox","通知","showNotifications"),("voice","语音","voice"),("settings","设置","settings")] {
                controls=controls.child(self.control(id,label,action,30.,30.,cx));
            }
            root=root.child(controls);
            if notice_count>0 {
                root=root.child(notices.absolute().left(px(10.)).right(px(48.)).bottom(px(86.)).max_h(px(64.)).bg(background));
            }
            if self.chat_open {
                root=root.child(div().absolute().left(px(10.)).right(px(48.)).bottom(px(10.)).h(px(70.)).child(self.pane.clone()));
            } else if let Some(reply)=self.transcript.iter().rev().find(|line|line.speaker=="居民") {
                root=root.child(div().id("compact-reply-bubble").absolute().left(px(10.)).right(px(48.)).bottom(px(10.)).max_h(px(74.)).overflow_y_scroll().p_2().bg(background)
                    .on_click(cx.listener(|this,_,_,cx|{this.chat_open=true;cx.notify();})).child(reply.text.clone()));
            }
        } else {
            let mut transport=div().absolute().right(px(22.)).bottom(px(22.)).w(px(529.)).h(px(48.)).flex().items_center().px(px(4.)).rounded_xl().bg(background);
            for (id,label,action) in [("program","节目","program"),("previous","上首","previousTrack"),("play","播放","togglePlayback"),("next","下首","nextTrack"),("voice","语音","voice"),("chat","聊天","chat"),("inbox","通知","showNotifications"),("props","装修","toggleDecoration"),("screen","屏幕操作","screen"),("visual","舞台设置","visual"),("mode","窗口","mode")] {
                transport=transport.child(self.control(id,label,action,if id=="visual"{68.}else{44.},44.,cx));
                if id=="next" {transport=transport.child(div().w(px(13.)).flex_shrink_0());}
            }
            root=root.child(transport).child(Button::new("destination").label(if self.runtime_state["stage"]["mode"].as_str()==Some("space"){"回到播放器"}else{"进入空间"}).w(px(112.)).h(px(38.)).absolute().right(px(22.)).top(px(28.)).on_click(cx.listener(|this,_,_,cx|this.overlay_action("destination",cx))));
            if self.runtime_state["screenOperation"]["active"].as_bool()==Some(true) {
                root=root.child(div().id("stage.screen-operation-banner").absolute().right(px(173.5)).bottom(px(82.)).w(px(226.)).h(px(30.)).flex().items_center().justify_center().rounded_xl().bg(rgba(0x0a4d6beb)).text_sm().child("正在操作电视，按 Esc 退出"));
            }
            if notice_count>0 {
                root=root.child(notices.absolute().left(px(22.)).top(px(22.)).w(px(280.)).bg(background));
            }
            if self.chat_open {
                let frame=composer_frame(false,width,height);let composer_width=frame[2];let composer_height=frame[3];
                root=root.child(div().absolute().right(px(22.)).bottom(px(86.)).w(px(composer_width)).max_h(px(composer_height)).bg(background).rounded_xl().p_2().child(self.pane.clone()));
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
        }
        let host=self.host.clone();
        // The original screen-operation banner never takes scene pointer
        // events. All other overlay hit regions use actual computed bounds,
        // including wrapped notices and the complete autonomy card.
        let passive_banner=(!self.compact&&self.runtime_state["screenOperation"]["active"].as_bool()==Some(true)).then_some(2);
        root.on_children_prepainted(move |bounds,_,_| {
            let rects:Vec<[f32;4]>=bounds.into_iter().enumerate().filter(|(index,_)|Some(*index)!=passive_banner)
                .map(|(_,bounds)|[bounds.origin.x.as_f32(),bounds.origin.y.as_f32(),bounds.size.width.as_f32(),bounds.size.height.as_f32()]).collect();
            if let Some(host)=host.borrow().as_ref(){host.hit_regions(&rects);}
        }).into_any_element()
    }
}

#[cfg(test)]
mod layout_tests {
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
    let application = gpui_kit::application().with_assets(gpui_kit::assets::AllAssets);
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
        let compact = std::env::var("GMGN_GPUI_COMPACT").as_deref() == Ok("1");
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
                let poll = cx.spawn_in(window, async move |view, cx| {
                    loop {
                        cx.background_executor().timer(Duration::from_millis(100)).await;
                        if view.update_in(cx, |view: &mut GMGNProductUI, window, cx| view.tick(window, cx)).is_err() { break; }
                    }
                });
                GMGNProductUI { host: host.clone(), pane, settings_pane, settings_window:None, inbox_pane, inbox_window:None, stage_pane,stage_panel_open:false,
                    program_pane,program_open:false,prop_pane,props_open:false,chat_open:false, voice_held:false, pending: None, accepted: false,
                    transcript: vec![], compact, core_notice, runtime_state: serde_json::Value::Null,
                    surface_mounted: false,navigation_revision:0,main_window:main_window.clone(),profile_switch_pending:false, _poll: poll }
            });
            *main_ui.borrow_mut()=Some(view.clone());
            cx.new(|cx| gpui_kit::base::Root::new(view, window, cx).bg(rgba(0x00000000)))
        }).expect("open gmgn product window");
    });
}
