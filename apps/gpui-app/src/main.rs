use gmgn_gpui_ui::{ResidentChatPane, state::{ChatCommand, TranscriptLine}};
use gpui_kit::component::{button::*, *};
use gpui_kit::component::menu::*;
use gmgn_gpui_ui::settings::AgentSettingsPane;
use gpui_kit::*;
use raw_window_handle::{HasWindowHandle, RawWindowHandle};
use std::{cell::RefCell, rc::Rc, time::Duration};
mod host_events;
mod product_host;
use product_host::ProductHost;
gpui_kit::actions!(gmgn_product, [Quit]);

struct GMGNProductUI {
    host: Rc<RefCell<Option<ProductHost>>>,
    pane: Entity<ResidentChatPane>,
    settings_pane: Entity<AgentSettingsPane>,
    settings_open: bool,
    pending: Option<u64>,
    accepted: bool,
    transcript: Vec<TranscriptLine>,
    compact: bool,
    core_notice: Option<String>,
    runtime_state: serde_json::Value,
    surface_mounted: bool,
    _poll: Task<()>,
}

impl GMGNProductUI {
    fn fail(&mut self, id: u64, notice: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.pane.update(cx, |pane, cx| pane.failed(id, notice.into(), window, cx));
        self.pending = None;
        self.accepted = false;
    }
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
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
                ChatCommand::Send { request_id, text } => {
                    self.pending = Some(request_id);
                    self.accepted = false;
                    let sent = self.host.borrow().as_ref().is_some_and(|host| host.send(request_id, &text));
                    eprintln!("GMGN_GPUI_SUBMIT request_id={request_id} accepted={sent}");
                    if !sent { self.fail(request_id, "当前应用未能接收这条消息，文字已保留。", window, cx); }
                }
                ChatCommand::Cancel { request_id } => {
                    if let Some(host) = self.host.borrow().as_ref() { host.cancel(request_id); }
                    self.pending = None;
                    self.accepted = false;
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
            self.settings_pane.update(cx,|pane,cx|pane.update_snapshot(batch.state["settings"].clone(),window,cx));
            self.runtime_state = batch.state; cx.notify();
        }
        if self.transcript != batch.transcript {
            self.transcript = batch.transcript.clone();
            self.pane.update(cx, |pane, cx| pane.set_transcript(batch.transcript, cx));
        }
    }
    fn native_action(&mut self, action: &str, cx: &mut Context<Self>) {
        let success = self.host.borrow().as_ref().is_some_and(|host| host.action(action));
        if !success { self.core_notice = Some("这个原有功能入口暂未能打开，请检查应用启动状态。".into()); }
        cx.notify();
    }
    fn open_settings(&mut self,cx:&mut Context<Self>) {
        let pane=self.settings_pane.clone();
        let _=cx.open_window(WindowOptions {
            window_bounds:Some(WindowBounds::Windowed(Bounds::new(point(px(120.),px(100.)),size(px(720.),px(760.))))),
            ..Default::default()
        },move |window,cx| {window.set_window_title("Agent 与回复语音");cx.new(|cx|gpui_kit::base::Root::new(pane,window,cx))});
    }
}

impl Render for GMGNProductUI {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        if let Some(host)=self.host.borrow().as_ref() { host.ui_overlay(self.settings_open); }
        if self.settings_open {
            return div().size_full().flex().flex_col().bg(theme.tokens.background)
                .child(Button::new("close-agent-settings").label("返回生活空间").on_click(cx.listener(|this,_,_,cx|{this.settings_open=false;cx.notify();})))
                .child(div().flex_1().min_h(px(0.)).child(self.settings_pane.clone())).into_any_element();
        }
        let mut panel = div().flex().flex_col().gap_3().p_3()
            .bg(theme.tokens.background).text_color(theme.foreground)
            .child(div().text_lg().child("gmgn radio"));
        {
            let entries = [
                ("space", "空间", "showStage"), ("player", "音乐", "showPlayer"),
                ("livecam", "小窗", "showLiveCam"), ("settings", "设置", "showSettings"),
                ("decoration", "装修", "toggleDecoration"),
                ("notifications", "通知", "showNotifications"),
                ("presence", "居民设置", "showPresenceSettings"),
                ("space-settings", "空间设置", "showSpaceSettings"),
                ("music-settings", "音乐设置", "showMusicSettings"),
                ("agent-settings", "Agent 设置", "showAgentSettings"),
                ("toggle-playback", "播放 / 暂停", "togglePlayback"),
                ("previous", "上一首", "previousTrack"), ("next", "下一首", "nextTrack"),
                ("local-track", "导入音乐", "chooseLocalTrack"),
                ("stop-resident", "停止居民", "stopResident"),
            ];
            let weak=cx.entity().downgrade();
            panel=panel.child(div().flex().gap_2()
                .child(Button::new("gpui-agent-settings").label("Agent / 语音").on_click(cx.listener(|this,_,_,cx|this.open_settings(cx))))
                .child(Button::new("original-features").label("更多功能").dropdown_caret(true).dropdown_menu(move |mut menu,_,_| {
                    for (_,label,action) in entries { let weak=weak.clone();
                        menu=menu.item(PopupMenuItem::new(label).on_click(move |_,_,cx|{_ = weak.update(cx,|this,cx|this.native_action(action,cx));}));
                    } menu
                })));
            if !self.compact { panel=panel.child(div().text_sm().child("同窗摆放操作正在验收；更多功能保留原页面过渡")); }
        }
        let mut notices = div().id("product-runtime-notices").max_h(px(if self.compact { 32. } else { 64. })).overflow_y_scroll();
        for field in ["statusNotice", "ttsError", "speechError", "connectivityNotice", "inboxPersistenceError"] {
            if let Some(notice) = self.runtime_state[field].as_str().filter(|s| !s.is_empty()) {
                notices = notices.child(div().text_sm().child(notice.to_owned()));
            }
        }
        panel = panel.child(notices);
        if !self.compact {
            panel = panel.child(div().text_sm().child(format!("未读 {} · 播放 {} · 语音 {} · 居民 {}",
                self.runtime_state["inboxUnread"].as_u64().unwrap_or(0),
                self.runtime_state["playbackState"].as_str().unwrap_or("—"),
                if self.runtime_state["isSpeaking"].as_bool() == Some(true) { "播放中" } else { "空闲" },
                if self.runtime_state["autonomyStopped"].as_bool() == Some(true) { "已停止" } else { "运行中" })));
        }
        if let Some(notice) = &self.core_notice { panel = panel.child(div().text_sm().child(notice.clone())); }
        if self.compact {
            div().size_full().relative()
                .child(Button::new("compact-settings").label("设置").on_click(cx.listener(|this,_,_,cx|this.open_settings(cx))).absolute().top_0().right_0())
                .child(div().absolute().top(px(168.)).bottom_0().left_0().right_0().p_2().bg(theme.tokens.background).text_color(theme.foreground).overflow_hidden().child(self.pane.clone())).into_any_element()
        } else {
            div().size_full().child(div().w(px(340.)).h_full().flex().flex_col()
                .bg(theme.tokens.background).text_color(theme.foreground)
                .child(div().id("product-navigation-and-status").flex_1().min_h(px(0.)).overflow_y_scroll().child(panel))
                .child(div().flex_shrink_0().p_3().child(self.pane.clone()))).into_any_element()
        }
    }
}

fn main() {
    let host = Rc::new(RefCell::new(None::<ProductHost>));
    let reopen_host = host.clone();
    let application = gpui_kit::application();
    application.on_reopen(move |_| { if let Some(host) = reopen_host.borrow().as_ref() { host.reopen(); } });
    application.run(move |cx| {
        gpui_kit::init(cx);
        cx.on_action(|_: &Quit, cx| cx.quit());
        cx.bind_keys([KeyBinding::new("cmd-q", Quit, None)]);
        cx.set_menus([
            Menu::new("gmgn radio").items([MenuItem::action("退出 gmgn radio", Quit)]),
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
        cx.on_app_quit(move |_| {
            quit_host.borrow_mut().take();
            async {}
        }).detach();
        let compact = std::env::var("GMGN_GPUI_COMPACT").as_deref() == Ok("1");
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(80.), px(80.)),
                if compact { size(px(224.), px(336.)) } else { size(px(1100.), px(760.)) }))),
            kind: if compact { WindowKind::PopUp } else { WindowKind::Normal },
            titlebar: if compact { None } else { Some(TitlebarOptions::default()) },
            is_resizable: !compact,
            focus: !compact,
            window_background: WindowBackgroundAppearance::Transparent,
            ..Default::default()
        };
        cx.open_window(options, move |window, cx| {
            window.set_window_title("gmgn radio");
            let view = cx.new(|cx| {
                let pane = cx.new(|cx| ResidentChatPane::new(window, cx).compact(compact));
                let settings_pane=cx.new(|cx|AgentSettingsPane::new(window,cx));
                let poll = cx.spawn_in(window, async move |view, cx| {
                    loop {
                        cx.background_executor().timer(Duration::from_millis(100)).await;
                        if view.update_in(cx, |view: &mut GMGNProductUI, window, cx| view.tick(window, cx)).is_err() { break; }
                    }
                });
                GMGNProductUI { host: host.clone(), pane, settings_pane, settings_open:false, pending: None, accepted: false,
                    transcript: vec![], compact, core_notice, runtime_state: serde_json::Value::Null,
                    surface_mounted: false, _poll: poll }
            });
            cx.new(|cx| gpui_kit::base::Root::new(view, window, cx).bg(rgba(0x00000000)))
        }).expect("open gmgn product window");
    });
}
