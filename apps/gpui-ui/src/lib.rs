//! First reusable GPUI Kit migration slice; no network or production configuration access.
pub mod inbox;
pub mod lyrics;
pub mod projective_card;
pub mod settings;
pub mod stage_panels;
pub mod state;
pub mod ui_tokens;

use gpui_kit::component::input::InputEvent;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{button::*, input::*, scroll::ScrollableElement, *};
use gpui_kit::*;
use state::{ChatAttachment, ChatCommand, ChatState, TranscriptLine};

fn compact_composer_height(state: &ChatState) -> f32 {
    if !state.attachments.is_empty() || state.attachments_preparing || state.attachments_error.is_some() {
        140.
    } else {
        70.
    }
}

pub struct ResidentChatPane {
    input: Entity<TextareaState>,
    state: ChatState,
    _subscription: Subscription,
    compact: bool,
}

impl ResidentChatPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(2)
                .submit_on_enter(true)
                .placeholder("和居民聊聊…")
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this, input, event: &InputEvent, window, cx| {
                if matches!(event, InputEvent::Change) {
                    this.state.edit(input.read(cx).value().to_string());
                    cx.notify();
                } else if let InputEvent::PressEnter { shift, .. } = event {
                    let composing = input.update(cx, |input, cx| {
                        input.marked_text_range(window, cx).is_some()
                    });
                    this.state.submit_enter(*shift, composing);
                    cx.notify();
                } else if matches!(event, InputEvent::Focus) {
                    this.state.focus_input();
                    cx.notify();
                }
            },
        );
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
    pub fn set_compact(&mut self, compact: bool, cx: &mut Context<Self>) {
        if self.compact != compact {
            self.compact = compact;
            cx.notify();
        }
    }
    pub fn take_commands(&mut self) -> Vec<ChatCommand> {
        self.state.take_commands()
    }
    pub fn focus_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        window.focus(&self.input.read(cx).focus_handle(cx), cx);
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
    pub fn complete_without_reply(&mut self, id: u64, cx: &mut Context<Self>) {
        if self.state.complete_without_reply(id) {
            cx.notify();
        }
    }
    pub fn set_transcript(&mut self, lines: Vec<TranscriptLine>, cx: &mut Context<Self>) {
        self.state.transcript = lines;
        cx.notify();
    }
    pub fn update_snapshot(&mut self, snapshot: serde_json::Value, cx: &mut Context<Self>) {
        let attachments = snapshot["attachments"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        Some(ChatAttachment {
                            id: item["id"].as_str()?.to_string(),
                            file_name: item["fileName"].as_str().unwrap_or("图片").to_string(),
                            preview_path: item["previewPath"].as_str().map(str::to_string),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        self.state.set_attachments(
            attachments,
            snapshot["attachmentsPreparing"].as_bool().unwrap_or(false),
        );
        self.state.attachments_error = snapshot["attachmentError"].as_str().map(str::to_string);
        self.state.voice_active = snapshot["voiceActive"].as_bool().unwrap_or(false);
        self.state.is_speaking = snapshot["isSpeaking"].as_bool().unwrap_or(false);
        self.state.host_can_stop = snapshot["canStop"].as_bool().unwrap_or(false);
        self.state.host_thinking = snapshot["isThinking"].as_bool().unwrap_or(false);
        self.state.host_progress = snapshot["progress"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        self.state.host_notice = snapshot["statusNotice"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        self.state.tts_error = snapshot["ttsError"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        if !self.state.thinking() {
            if let Some(reply) = snapshot["reply"].as_str() {
                self.state.reply = reply.to_string();
            }
        }
        cx.notify();
    }
    pub fn reset_context(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.state.reset_context();
        let draft = self.state.draft.clone();
        self.input
            .update(cx, |input, cx| input.set_value(draft, window, cx));
        cx.notify();
    }
}

impl Render for ResidentChatPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let mut history = div()
            .id("resident-transcript")
            .h(px(132.))
            .flex_shrink_0()
            .flex_1()
            .flex()
            .flex_col()
            .gap_2();
        for line in &self.state.transcript {
            history = history.child(
                div()
                    .text_sm()
                    .child(line.speaker.clone())
                    .child(div().child(line.text.clone())),
            );
        }
        if !self.state.reply.is_empty()
            && !self
                .state
                .transcript
                .iter()
                .any(|line| line.speaker == "居民" && line.text == self.state.reply)
        {
            history = history.child(
                div()
                    .text_sm()
                    .child("居民")
                    .child(self.state.reply.clone()),
            );
        }
        let mut previews = div().id("resident-attachments").h(px(46.)).flex().gap_2();
        for attachment in self.state.attachments.clone() {
            let id = attachment.id.clone();
            let mut card = div().relative().w(px(54.)).h(px(46.)).flex_shrink_0();
            if let Some(path) = &attachment.preview_path {
                card = card.child(
                    img(std::path::PathBuf::from(path))
                        .w(px(54.))
                        .h(px(46.))
                        .object_fit(ObjectFit::Contain),
                );
            }
            previews = previews.child(
                card.child(
                    div().absolute().top_0().right_0().child(
                        Button::new(format!("remove-attachment-{id}"))
                            .small()
                            .label("×")
                            .tooltip(format!("移除 {}", attachment.file_name))
                            .accessibility_label(format!("移除 {}", attachment.file_name))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.state.remove_attachment(id.clone());
                                cx.notify();
                            })),
                    ),
                ),
            );
        }
        let input = Textarea::new(&self.input)
            .small()
            .h(px(if self.compact { 26. } else { 40. }))
            .on_paste({
                let entity = cx.entity().downgrade();
                move |clipboard, _, cx| {
                    if clipboard.entries.iter().any(|entry| {
                        matches!(
                            entry,
                            ClipboardEntry::Image(_) | ClipboardEntry::ExternalPaths(_)
                        )
                    }) {
                        let _ = entity.update(cx, |this, cx| {
                            this.state.paste_attachments();
                            cx.notify();
                        });
                        true
                    } else {
                        false
                    }
                }
            });
        let status = self
            .state
            .status
            .clone()
            .unwrap_or_else(|| self.state.status_line());
        let voice = div()
            .id("resident-push-to-talk")
            .role(Role::Button)
            .aria_label("按住说话，松开发送")
            .accessibility_id("stage.resident-push-to-talk")
            .cursor_pointer()
            .px_2()
            .rounded_md()
            .text_sm()
            .text_color(if self.state.voice_active {
                rgb(0x22d3ee).into()
            } else {
                theme.foreground
            })
            .child(Icon::new(gpui_kit::assets::IconName::Mic).small())
            .tooltip(|window, cx| Tooltip::new("按住说话，松开发送").build(window, cx))
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    this.state.begin_voice();
                    cx.notify();
                }),
            )
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    this.state.finish_voice();
                    cx.notify();
                }),
            )
            .on_mouse_up_out(
                MouseButton::Left,
                cx.listener(|this, _, _, cx| {
                    this.state.finish_voice();
                    cx.notify();
                }),
            );
        let primary_stops = self.state.primary_stops();
        let stop_label = if self.state.is_speaking {
            "停止说话"
        } else {
            "停止当前任务"
        };
        let primary_label = if primary_stops {
            stop_label
        } else {
            "发送消息"
        };
        let send = Button::new("resident-send")
            .small()
            .primary()
            .label(
                if primary_stops && self.state.is_speaking && !self.compact {
                    "停止说话"
                } else {
                    ""
                },
            )
            .icon(if primary_stops {
                gpui_kit::assets::IconName::Square
            } else {
                gpui_kit::assets::IconName::ArrowUp
            })
            .tooltip(primary_label)
            .accessibility_label(primary_label)
            .disabled(!primary_stops && !self.state.can_send())
            .on_click(cx.listener(|this, _, window, cx| {
                let previous = this.state.draft.clone();
                this.state.primary_action();
                let draft = this.state.draft.clone();
                if draft != previous {
                    this.input
                        .update(cx, |input, cx| input.set_value(draft, window, cx));
                }
                cx.notify();
            }));
        let mut controls = div().flex().items_center().gap(px(ui_tokens::SPACING_4));
        controls = controls
                .child(
                    Button::new("resident-attachment")
                        .small()
                        .ghost()
                        .icon(gpui_kit::assets::IconName::Plus)
                        .tooltip("添加图片，也可以直接粘贴图片")
                        .accessibility_label("添加图片附件")
                        .disabled(
                            self.state.attachments_preparing || self.state.attachments.len() >= 4,
                        )
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.state.pick_attachments();
                            cx.notify();
                        })),
                );
        if !self.compact {
            controls = controls.child(div().flex_1().text_size(px(ui_tokens::CAPTION)).line_height(px(ui_tokens::CAPTION_LINE_HEIGHT)).child(self.state.status_line()));
        } else {
            controls = controls.child(div().flex_1());
        }
        controls = controls.child(voice);
        if self.state.can_stop() && self.state.has_draft() {
            controls = controls.child(
                Button::new("resident-cancel")
                    .small()
                    .icon(gpui_kit::assets::IconName::Square)
                    .tooltip(stop_label)
                    .accessibility_label(stop_label)
                    .on_click(cx.listener(|this, _, window, cx| {
                        let previous = this.state.draft.clone();
                        this.state.stop_reply();
                        let draft = this.state.draft.clone();
                        if draft != previous {
                            this.input
                                .update(cx, |input, cx| input.set_value(draft, window, cx));
                        }
                        cx.notify();
                    })),
            );
        }
        controls = controls.child(send);
        let mut pane = div()
            .id("resident-composer")
            .font_family(theme.font_family.clone())
            .text_size(px(ui_tokens::BODY))
            .line_height(px(ui_tokens::BODY_LINE_HEIGHT))
            .w_full()
            .max_w(px(620.))
            .max_h(px(320.))
            .p(px(ui_tokens::SPACING_8))
            .rounded_lg()
            .bg(theme.tokens.background)
            .text_color(theme.foreground)
            .flex()
            .flex_col()
            .gap(px(ui_tokens::SPACING_8))
            .drag_over::<ExternalPaths>(|style, _, _, _| {
                style
                    .border_2()
                    .border_color(rgb(0x22d3ee))
                    .bg(rgb(0x1a4757))
            })
            .on_drop::<ExternalPaths>(cx.listener(|this, paths: &ExternalPaths, _, cx| {
                this.state.import_attachments(
                    paths
                        .paths()
                        .iter()
                        .map(|path| path.to_string_lossy().into_owned())
                        .collect(),
                );
                cx.notify();
            }));
        if !self.compact {
            pane = pane.overflow_y_scroll();
            if !self.state.transcript.is_empty() || !self.state.reply.is_empty() {
            pane = pane.child(
                div()
                    .flex()
                    .flex_shrink_0()
                    .gap_2()
                    .child(history.overflow_y_scrollbar())
                    .child(
                        Button::new("copy-resident-reply")
                            .small()
                            .ghost()
                            .icon(gpui_kit::assets::IconName::Copy)
                            .tooltip("复制最新回复")
                            .accessibility_label("复制最新回复")
                            .disabled(self.state.reply.is_empty())
                            .on_click(cx.listener(|this, _, _, cx| {
                                cx.write_to_clipboard(ClipboardItem::new_string(
                                    this.state.reply.clone(),
                                ));
                            })),
                    ),
            );
            }
            if self.state.status.is_some() && self.state.host_notice.as_deref() != Some(status.as_str()) {
                pane = pane.child(div().text_xs().child(status));
            }
            if let Some(error) = &self.state.tts_error {
                pane = pane.child(div().text_xs().child(error.clone()));
            }
            if let Some(notice) = &self.state.host_notice {
                pane = pane.child(div().text_xs().child(format!("应用提示：{notice}")));
            }
        } else {
            pane = pane.p_1().gap_1().h(px(compact_composer_height(&self.state)));
        }
        if !self.state.attachments.is_empty() {
            pane = pane.child(previews.flex_shrink_0().overflow_x_scrollbar());
            if self.state.attachments.len() > 4 {
                pane = pane.child(div().text_xs().child(
                    "图片已保留，请移除多余图片后再发送（最多4张）。",
                ));
            }
        }
        if self.state.attachments_preparing {
            pane = pane.child(div().text_xs().child("正在准备图片…"));
        }
        if let Some(error) = &self.state.attachments_error {
            pane = pane.child(div().text_xs().text_color(rgb(0xfb923c)).child(error.clone()));
        }
        pane.child(input).child(controls)
    }
}

#[cfg(test)]
mod compact_attachment_tests {
    use super::{compact_composer_height, ChatAttachment, ChatState};

    #[test]
    fn compact_height_matches_original_attachment_strip_visibility() {
        let mut state = ChatState::default();
        assert_eq!(compact_composer_height(&state), 70.);
        state.attachments_preparing = true;
        assert_eq!(compact_composer_height(&state), 140.);
        state.attachments_preparing = false;
        state.attachments_error = Some("图片无法读取".into());
        assert_eq!(compact_composer_height(&state), 140.);
        state.attachments_error = None;
        state.attachments.push(ChatAttachment {
            id: "one".into(), file_name: "one.png".into(), preview_path: None,
        });
        assert_eq!(compact_composer_height(&state), 140.);
        state.attachments.clear();
        assert_eq!(compact_composer_height(&state), 70.);
    }
}
