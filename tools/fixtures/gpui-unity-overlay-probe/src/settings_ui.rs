//! Standard product settings, projected through the existing Unity host.
//! No second transport, preference writer, credential store, or optimistic ACK.
use crate::{enqueue_ui_command, UiCommandQueue};
use gmgn_gpui_ui::{settings::AgentSettingsPane, stage_panels::StagePanelsPane};
use gmgn_gpui_ui::{primitives as ui, ui_tokens::{self as tokens, scene as s}};
use gpui_kit::{component::{button::Button, Disableable}, *};
use serde_json::{json, Value};
use std::{
    collections::VecDeque,
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_PENDING: usize = 32;

pub struct SettingsPane {
    controls: Entity<AgentSettingsPane>,
    stage: Entity<StagePanelsPane>,
    commands: UiCommandQueue,
    waiting: VecDeque<Value>,
    pending: Option<String>,
    instance: String,
    sequence: u64,
    supported: Vec<String>,
    loaded: bool,
    notice: String,
    last_envelope: Value,
}

impl SettingsPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>, commands: UiCommandQueue) -> Self {
        let stage = cx.new(|cx| StagePanelsPane::new(window, cx));
        let controls = cx.new(|cx| AgentSettingsPane::new(window, cx));
        controls.update(cx, |view, cx| {
            view.set_unity_external(true, cx);
            view.set_stage_pane(stage.clone(), cx);
        });
        Self {
            controls,
            stage,
            commands,
            waiting: VecDeque::new(),
            pending: None,
            instance: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|d| d.as_nanos().to_string())
                .unwrap_or_default(),
            sequence: 0,
            supported: Vec::new(),
            loaded: false,
            notice: String::new(),
            last_envelope: Value::Null,
        }
    }

    fn collect(&mut self, cx: &mut Context<Self>) {
        let mut incoming = self.controls.update(cx, |view, _| view.take_commands());
        incoming.extend(self.stage.update(cx, |view, _| view.take_commands()));
        for command in incoming {
            if self.waiting.len() >= MAX_PENDING {
                self.notice = "待保存操作已满，请等待当前操作完成后再试。".into();
                continue;
            }
            self.waiting.push_back(command);
        }
    }

    fn dispatch(&mut self) {
        if self.instance.is_empty() {
            self.notice = "无法创建设置请求，请重新打开设置。".into();
            return;
        }
        if !self.loaded || self.pending.is_some() {
            return;
        }
        while let Some(command) = self.waiting.pop_front() {
            let Some(op) = command["op"].as_str() else {
                self.notice = "设置操作格式无效，未提交。".into();
                continue;
            };
            if !self.supported.iter().any(|candidate| candidate == op) {
                self.notice = format!("当前运行时不支持此操作：{op}");
                continue;
            }
            self.sequence = match self.sequence.checked_add(1) {
                Some(next) => next,
                None => {
                    self.notice = "设置会话已结束，请重新打开设置。".into();
                    return;
                }
            };
            let request = format!("gpui-settings:{}:{}", self.instance, self.sequence);
            if enqueue_ui_command(
                &self.commands,
                json!({"op":"ui.settings.command", "requestID":request, "command":command}),
            ) {
                self.pending = Some(request);
                self.notice = "正在等待保存确认…".into();
            } else {
                // Keep the user's original draft. No automatic command replay.
                self.notice = "操作队列已满，这次尚未提交，请稍后重试。".into();
            }
            return;
        }
    }

    /// `settings` is the unchanged full Unity settingsSnapshot envelope, not a
    /// locally synthesized candidate. All subpanes use the same main poll.
    pub fn update_snapshot(
        &mut self,
        snapshot: &Value,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let envelope = &snapshot["settings"];
        let before=(self.pending.clone(),self.notice.clone(),self.waiting.len());
        let projection=crate::settings_projection(envelope);
        let envelope_changed=self.last_envelope!=projection;
        if envelope_changed && envelope["settings"].is_object() {
            self.last_envelope=projection;
            self.loaded = true;
            self.supported = envelope["supportedCommands"]
                .as_array()
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            self.controls.update(cx, |view, cx| {
                view.set_supported_ops(self.supported.clone(), cx);
                view.update_snapshot(envelope["settings"].clone(), window, cx)
            });
            self.stage.update(cx, |view, cx| {
                view.set_supported_ops(self.supported.clone(), cx);
                view.update_snapshot(envelope["stage"].clone(), window, cx)
            });
        }
        let receipt = &snapshot["settingsCommandResult"];
        if self
            .pending
            .as_deref()
            .is_some_and(|id| receipt["requestID"].as_str() == Some(id))
        {
            match receipt["status"].as_str() {
                Some("accepted" | "completed") => {
                    self.pending = None;
                    self.notice = "操作已提交，请等待对应项目确认。".into();
                }
                Some("failed") => {
                    self.pending = None;
                    // The host names the rejected reason (`settings_command_rejected`,
                    // `camera_reset_unavailable`, …). Showing it keeps an
                    // ordinary failure distinguishable from "no handler exists
                    // for this op in this runtime" instead of one generic line.
                    let reason = receipt["code"]
                        .as_str()
                        .filter(|code| !code.is_empty())
                        .unwrap_or("settings_command_rejected");
                    self.notice = format!("设置未保存（{reason}），请检查对应项目的错误提示后重试。");
                }
                _ => {} // Accepted/pending/unknown never become success.
            }
        }
        self.collect(cx);
        self.dispatch();
        if envelope_changed || before!=(self.pending.clone(),self.notice.clone(),self.waiting.len()) {cx.notify();}
    }

    pub fn dismissed(&mut self, cx: &mut Context<Self>) {
        self.controls.update(cx, |view, cx| view.dismissed(cx));
        self.collect(cx);
        self.dispatch();
    }

    /// Already dispatched commands live in the host transport. Keep this
    /// window alive while later edits still depend on their acknowledgements.
    pub fn can_close(&mut self, cx: &mut Context<Self>) -> bool {
        self.collect(cx);
        self.dispatch();
        if self.waiting.is_empty() {return true;}
        self.notice = "还有设置正在保存，请稍后关闭窗口。".into();
        cx.notify();
        false
    }
}

impl Render for SettingsPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let content = if self.loaded {
            self.controls.clone().into_any_element()
        } else {
            div()
                .flex()
                .flex_col()
                .gap_3()
                .p_4()
                .child("正在读取当前设置…")
                .child("设置确认前不会覆盖现有配置。")
                .into_any_element()
        };
        div()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .flex()
            .flex_col()
            .font_family(tokens::FONT_FAMILY)
            .text_size(px(tokens::BODY))
            .bg(rgba(s::PANEL_BG))
            .text_color(rgba(s::TEXT))
            .child(
                div()
                    .flex_1()
                    .min_h(px(0.))
                    .min_w(px(0.))
                    .overflow_hidden()
                    .child(content),
            )
            .child(
                div()
                    .flex()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .border_t_1()
                    .border_color(rgba(s::BORDER))
                    .child(div().flex_1().min_w_0().child(ui::notice(self.notice.clone())))
                    .child(
                        Button::new("settings-refresh")
                            .label("重新读取")
                            .disabled(self.pending.is_some())
                            .on_click(cx.listener(|this, _, _, cx| {
                                if this.waiting.len() < MAX_PENDING {
                                    this.waiting.push_back(json!({"op":"settings.load"}));
                                }
                                this.dispatch();
                                cx.notify();
                            })),
                    ),
            )
    }
}
