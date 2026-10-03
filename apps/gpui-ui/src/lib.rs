//! First reusable GPUI Kit migration slice; no network or production configuration access.
pub mod state;
use gpui_kit::prelude::FluentBuilder;

use gpui_kit::component::input::InputEvent;
use gpui_kit::component::{button::*, input::*, scroll::ScrollableElement, *};
use gpui_kit::*;
use state::{ChatCommand, ChatState, TranscriptLine};

pub struct ResidentChatPane {
    input: Entity<InputState>,
    state: ChatState,
    _subscription: Subscription,
    compact: bool,
}

impl ResidentChatPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| InputState::new(window, cx).placeholder("和居民聊聊…"));
        let subscription = cx.subscribe(&input, |this, input, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                this.state.edit(input.read(cx).value().to_string());
                cx.notify();
            } else if matches!(event, InputEvent::PressEnter { shift: false, .. }) {
                this.state.send();
                cx.notify();
            }
        });
        Self {
            input,
            state: ChatState::default(),
            _subscription: subscription,
            compact: false,
        }
    }
    pub fn compact(mut self, compact: bool) -> Self {
        self.compact = compact;
        self
    }
    pub fn take_commands(&mut self) -> Vec<ChatCommand> {
        self.state.take_commands()
    }
    pub fn accepted(&mut self, id: u64, window: &mut Window, cx: &mut Context<Self>) {
        if self.state.accepted(id) {
            let draft = self.state.draft.clone();
            self.input
                .update(cx, |input, cx| input.set_value(draft, window, cx));
            cx.notify();
        }
    }
    pub fn failed(&mut self, id: u64, notice: String, window: &mut Window, cx: &mut Context<Self>) {
        if self.state.fail(id, notice) {
            let draft = self.state.draft.clone();
            self.input
                .update(cx, |input, cx| input.set_value(draft, window, cx));
            cx.notify();
        }
    }
    pub fn reply(&mut self, id: u64, text: String, cx: &mut Context<Self>) {
        if self.state.finish(id, text) {
            cx.notify();
        }
    }
    pub fn progress(&mut self, id: u64, text: String, cx: &mut Context<Self>) {
        if self.state.update_progress(id, text) {
            cx.notify();
        }
    }
    pub fn set_transcript(&mut self, lines: Vec<TranscriptLine>, cx: &mut Context<Self>) {
        self.state.transcript = lines;
        cx.notify();
    }
    pub fn reset_context(&mut self, cx: &mut Context<Self>) {
        self.state.reset_context();
        cx.notify();
    }
}

impl Render for ResidentChatPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let mut history = div()
            .id("resident-transcript")
            .h(px(if self.compact { 64. } else { 132. }))
            .flex()
            .flex_col()
            .gap_2();
        for line in &self.state.transcript {
            history = history.child(
                div()
                    .child(line.speaker.clone())
                    .child(div().child(line.text.clone())),
            );
        }
        if !self.state.reply.is_empty()
            && !self
                .state
                .transcript
                .iter()
                .any(|l| l.speaker == "居民" && l.text == self.state.reply)
        {
            history = history.child(
                div()
                    .child("居民")
                    .child(div().child(self.state.reply.clone())),
            );
        }
        div()
            .p_3()
            .when(self.compact, |el| el.p_2().text_xs())
            .rounded_lg()
            .bg(theme.tokens.background)
            .text_color(theme.foreground)
            .flex()
            .flex_col()
            .gap_2()
            .when(self.compact, |el| el.gap_1())
            .children((!self.compact).then_some(history.overflow_y_scrollbar()))
            .children(
                (!self.compact).then_some(
                    Button::new("copy-resident-reply")
                        .label("复制最新回复")
                        .disabled(self.state.reply.is_empty())
                        .on_click(cx.listener(|this, _, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(
                                this.state.reply.clone(),
                            ))
                        })),
                ),
            )
            .children(self.state.status.clone().map(|status| {
                if self.compact {
                    let compact_notice = if let Some(reason) = status.strip_suffix("\n文字已保留。")
                    {
                        format!("文字已保留，可重试。\n{reason}")
                    } else {
                        status
                    };
                    div()
                        .id("resident-compact-notice")
                        .h(px(32.))
                        .child(compact_notice)
                        .overflow_y_scrollbar()
                        .into_any_element()
                } else {
                    div().child(status).into_any_element()
                }
            }))
            .child(Input::new(&self.input).when(self.compact, |input| input.small()))
            .child(
                div().child(
                    self.state
                        .progress
                        .clone()
                        .unwrap_or_else(|| "可以和居民聊聊".into()),
                ),
            )
            .child(
                div()
                    .flex()
                    .flex_wrap()
                    .gap_2()
                    .when(self.compact, |el| el.gap_1())
                    .children(
                        (!self.compact).then_some(
                            Button::new("resident-attachment")
                                .label("图片暂未迁移")
                                .disabled(true),
                        ),
                    )
                    .child(
                        Button::new("resident-send")
                            .when(self.compact, |button| button.small())
                            .primary()
                            .label("发送")
                            .disabled(!self.state.can_send())
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.state.send();
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("resident-cancel")
                            .when(self.compact, |button| button.small())
                            .label("停止")
                            .disabled(!self.state.thinking())
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.state.cancel();
                                cx.notify();
                            })),
                    ),
            )
    }
}
