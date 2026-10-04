use gmgn_gpui_ui::{settings::AgentSettingsPane, stage_panels::StagePanelsPane, ui_tokens};
use gpui_kit::{*, prelude::FluentBuilder};
use gpui_kit::component::{ActiveTheme, Theme, ThemeMode};
use std::time::Duration;
#[path = "../unity_settings_transport.rs"] mod unity_settings_transport;

struct UnitySettings {
    pane: Entity<AgentSettingsPane>, stage: Entity<StagePanelsPane>,
    transport: Option<unity_settings_transport::SettingsTransport>,
    notice: Option<String>, _poll: Task<()>,
}
impl UnitySettings {
    fn tick(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let commands = self.pane.update(cx, |pane, _| pane.take_commands());
        let stage_commands = self.stage.update(cx, |stage, _| stage.take_commands());
        for command in commands.into_iter().chain(stage_commands) {
            let op = command["op"].as_str().unwrap_or("");
            if matches!(op, "settings.load" | "stage.load" | "presence.load" | "speech.settings.load") { continue; }
            if op != "stage.player.lyrics" {
                self.notice = Some("此功能尚未接入 Unity，原设置保持不变。".into()); cx.notify(); continue;
            }
            if !self.transport.as_ref().is_some_and(|transport| transport.commands.send(command).is_ok()) {
                self.notice = Some("Unity 设置连接不可用，请从 Unity 重新打开。".into()); cx.notify();
            }
        }
        let mut latest = None;
        if let Some(transport) = &self.transport { while let Ok(update) = transport.updates.try_recv() { latest = Some(update); } }
        if let Some(update) = latest {
            match update {
                Ok(state) => {
                    self.pane.update(cx, |pane, cx| pane.update_snapshot(state["settings"].clone(), window, cx));
                    self.stage.update(cx, |stage, cx| stage.update_snapshot(state["stage"].clone(), window, cx));
                    self.notice = None;
                }
                Err(error) => self.notice = Some(error),
            }
            cx.notify();
        }
    }
}
impl Render for UnitySettings {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        div().size_full().flex().flex_col().bg(cx.theme().background).text_color(cx.theme().foreground)
            .font_family(ui_tokens::FONT_FAMILY).text_size(px(ui_tokens::BODY))
            .when_some(self.notice.clone(), |view, notice| view.child(div().px_4().py_2().text_size(px(ui_tokens::CAPTION)).text_color(cx.theme().danger).child(notice)))
            .child(div().flex_1().min_h_0().child(self.pane.clone()))
    }
}
fn main() {
    let endpoint = std::env::var("GMGN_UNITY_SETTINGS_ENDPOINT").ok();
    gpui_kit::application().with_assets(gpui_kit::assets::AllAssets).run(move |cx| {
        gpui_kit::init(cx); Theme::change(ThemeMode::Dark, None, cx);
        cx.open_window(WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(Bounds::new(point(px(120.), px(100.)), size(px(880.), px(640.))))),
            window_min_size: Some(size(px(760.), px(540.))), ..Default::default()
        }, move |window, cx| {
            window.set_window_title("设置 · Unity 播放器");
            let view = cx.new(|cx| {
                let stage = cx.new(|cx| StagePanelsPane::new(window, cx));
                let pane = cx.new(|cx| AgentSettingsPane::new(window, cx));
                pane.update(cx, |pane, cx| { pane.set_unity_external(true, cx); pane.set_stage_pane(stage.clone(), cx); pane.select_page("player", cx); });
                let result = endpoint.as_deref().ok_or_else(|| "请从 Unity 播放器打开设置。".to_owned()).and_then(unity_settings_transport::start);
                let (transport, notice) = match result { Ok(value) => (Some(value), None), Err(error) => (None, Some(error)) };
                let poll = cx.spawn_in(window, async move |view, cx| {
                    loop {
                        cx.background_executor().timer(Duration::from_millis(100)).await;
                        if view.update_in(cx, |view: &mut UnitySettings, window, cx| view.tick(window, cx)).is_err() { break; }
                    }
                });
                UnitySettings { pane, stage, transport, notice, _poll: poll }
            });
            window.on_window_should_close(cx, |_, cx| { cx.quit(); true });
            cx.new(|cx| gpui_kit::base::Root::new(view, window, cx))
        }).expect("open Unity settings window");
        cx.activate(true);
    });
}
