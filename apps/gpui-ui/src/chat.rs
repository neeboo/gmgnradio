//! The resident chat surface: the original `StageResidentComposer`
//! (`apps/macos/Sources/GMGNRadio/VisualEngine/StageOverlayView.swift:228-438`
//! plus `Presence/ResidentImageAttachment.swift:483-508,672-710`), rebuilt on
//! gpui-kit.
//!
//! Shape of the surface, and why it is split this way:
//!
//! - [`ResidentChatPane`] owns the composer state ([`ChatState`]) and the kit
//!   `Textarea` entity, and renders two cards: the history card (a fixed 132 pt
//!   scroll of the last turns with the copy button beside it) and the composer
//!   card (drop hint, notices, attachment strip, input, control row).
//! - Only **the history scrolls**. The original's scroll view is inside the
//!   132 pt frame; the earlier GPUI version scrolled the whole pane, which let
//!   the input and the buttons scroll out of reach.
//! - Pure decisions live in free functions ([`speaker_label`],
//!   [`standalone_reply`], [`plain_text`], [`composer_chrome`],
//!   [`compact_composer_height`]) so the host and the tests share one answer
//!   instead of each re-deriving it.
//! - Chrome and type come from [`crate::primitives`] and
//!   [`crate::ui_tokens::chat`]; this file contains no colour or size literals.
use std::collections::HashMap;
use std::sync::Arc;

use base64::Engine as _;
use gpui_kit::component::alert::Alert;
use gpui_kit::component::button::*;
use gpui_kit::component::input::{InputEvent, Textarea, TextareaState};
use gpui_kit::component::*;
use gpui_kit::prelude::{FluentBuilder as _, InteractiveElement as _, StatefulInteractiveElement as _};
use gpui_kit::*;
use image::ImageDecoder as _;

use crate::primitives as ui;
use crate::state::{ChatAttachment, ChatCommand, ChatState, TranscriptLine};
use crate::ui_tokens::chat as m;
use crate::ui_tokens::scene as s;

/// Only fixed host diagnostic codes may reach the UI. Provider payloads, URLs
/// and arbitrary error descriptions are never rendered here.
pub fn safe_asr_error_code(code: Option<&str>) -> &'static str {
    match code {
        Some("asr_service_unavailable") => "asr_service_unavailable",
        Some("asr_protocol_failed") => "asr_protocol_failed",
        Some("asr_configuration_missing") => "asr_configuration_missing",
        Some("asr_connect_failed") => "asr_connect_failed",
        Some("asr_timeout") => "asr_timeout",
        Some("asr_provider_failed") => "asr_provider_failed",
        Some("asr_send_failed") => "asr_send_failed",
        Some("asr_commit_failed") => "asr_commit_failed",
        Some("asr_empty") => "asr_empty",
        Some("capture_backpressure") => "capture_backpressure",
        Some("capture_failed") => "capture_failed",
        Some("capture_empty") => "capture_empty",
        Some("microphone_permission") => "microphone_permission",
        Some("microphone_permission_pending") => "microphone_permission_pending",
        _ => "asr_failed",
    }
}

fn asr_error_notice(state: Option<&str>, code: Option<&str>) -> Option<String> {
    if state != Some("error") {
        return None;
    }
    let code = safe_asr_error_code(code);
    let message = match code {
        "microphone_permission" => "麦克风权限未开启，请检查系统隐私设置。",
        "microphone_permission_pending" => "麦克风授权尚未完成，请确认系统授权提示。",
        "asr_configuration_missing" => "语音识别尚未配置，请检查按住说话设置。",
        "asr_service_unavailable" => "语音识别服务暂不可用，请稍后重试。",
        "asr_timeout" => "语音识别超时，请重新按住说话。",
        "asr_empty" | "capture_empty" => "没有识别到语音，请重新按住说话。",
        "capture_failed" | "capture_backpressure" => "录音未完成，请检查麦克风后重试。",
        _ => "语音识别未完成，请检查设置或稍后重试。",
    };
    Some(format!("{message}（{code}）"))
}

/// Host thumbnails are at most 96 pixels and 32 KiB. This UI decoder accepts
/// that contract only; attachment import/send validation remains in the host.
fn decode_attachment_thumbnail(encoded: &str) -> Result<Arc<RenderImage>, &'static str> {
    if encoded.len() > 43_692 {
        return Err("无预览");
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| "无预览")?;
    if bytes.len() > 32 * 1024 {
        return Err("无预览");
    }
    let decoder =
        image::codecs::png::PngDecoder::new(std::io::Cursor::new(bytes)).map_err(|_| "无预览")?;
    let (width, height) = decoder.dimensions();
    if width == 0 || height == 0 || width > 96 || height > 96 {
        return Err("无预览");
    }
    let rgba = image::DynamicImage::from_decoder(decoder)
        .map_err(|_| "无预览")?
        .to_rgba8();
    crate::projective_card::RgbaTexture {
        width,
        height,
        pixels: rgba.into_raw(),
    }
    .into_render_image()
}

struct AttachmentThumbnail {
    encoded: String,
    image: Result<Arc<RenderImage>, &'static str>,
}

/// How a transcript line is labelled and coloured.
///
/// The original has three speakers (`user`/`resident`/`notice`) and no label at
/// all for `notice`; a notice is a system line and reads in the warning colour
/// (`StageOverlayView.swift:248-263`, `ResidentAgentLoop.swift:224-230`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SpeakerLabel<'a> {
    pub label: Option<&'a str>,
    pub notice: bool,
}

/// Map any speaker spelling that reaches the UI onto the original's label.
///
/// The host projects `user`/`agent`/`notice` into these labels
/// (`apps/gpui-app/src/host_events.rs`); unknown spellings keep their own text
/// as a label rather than silently turning a person's turn into a notice.
pub fn speaker_label(speaker: &str) -> SpeakerLabel<'_> {
    match speaker {
        "" | "系统" | "notice" | "提示" => SpeakerLabel {
            label: None,
            notice: true,
        },
        "你" | "user" => SpeakerLabel {
            label: Some("你"),
            notice: false,
        },
        "居民" | "resident" | "agent" => SpeakerLabel {
            label: Some("居民"),
            notice: false,
        },
        other => SpeakerLabel {
            label: Some(other),
            notice: false,
        },
    }
}

/// The standalone reply line, or `None` when the history already ends with it.
///
/// A background/driver turn has no user submission, so it is not part of the
/// history; it must still be visible, but only when it differs from the last
/// resident line (`ResidentAgentLoop.swift:242-250`).
pub fn standalone_reply(reply: &str, transcript: &[TranscriptLine]) -> Option<String> {
    let normalized = reply.trim();
    if normalized.is_empty() {
        return None;
    }
    let last_resident = transcript
        .iter()
        .rev()
        .find(|line| speaker_label(&line.speaker).label == Some("居民"))
        .map(|line| line.text.as_str());
    (last_resident != Some(normalized)).then(|| normalized.to_owned())
}

/// One plain-text rendering of the whole transcript, shared by the Live Cam
/// expanded reply and the host so both surfaces agree
/// (`ResidentAgentLoop.swift:233-238`).
pub fn plain_text(transcript: &[TranscriptLine]) -> String {
    transcript
        .iter()
        .map(|line| {
            let entry = speaker_label(&line.speaker);
            match entry.label {
                Some(label) => format!("{label}：{}", line.text),
                None => line.text.clone(),
            }
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

/// Whether the history card is drawn at all.
///
/// The original shows the history block only once there is something to show —
/// an empty 132 pt hole was a reported v19 defect.
pub fn history_visible(state: &ChatState) -> bool {
    !state.transcript.is_empty() || !state.reply.is_empty()
}

/// The composer chrome for a given interaction state. The original changes the
/// surface when a drag is over the panel, and the hairline when the field has
/// focus (`StageOverlayView.swift:415-425`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ComposerChrome {
    pub background: u32,
    pub border: u32,
    pub border_width: f32,
}

pub fn composer_chrome(is_drop_target: bool, is_focused: bool) -> ComposerChrome {
    ComposerChrome {
        background: if is_drop_target {
            s::CARD_BG_ACTIVE
        } else {
            s::CARD_BG
        },
        border: if is_drop_target {
            s::BORDER_ACTIVE
        } else if is_focused {
            s::BORDER_FOCUSED
        } else {
            s::BORDER
        },
        border_width: if is_drop_target { 2. } else { 1. },
    }
}

/// The Live Cam composer height: idle, or the taller strip once an attachment is
/// pending, preparing or failed.
pub fn compact_composer_height(state: &ChatState) -> f32 {
    if !state.attachments.is_empty() || state.attachments_preparing || state.attachments_error.is_some()
    {
        m::COMPACT_ATTACHED_HEIGHT
    } else {
        m::COMPACT_IDLE_HEIGHT
    }
}

pub struct ResidentChatPane {
    input: Entity<TextareaState>,
    state: ChatState,
    _subscription: Subscription,
    compact: bool,
    thumbnails: HashMap<String, AttachmentThumbnail>,
    asr_error: Option<String>,
    input_focused: bool,
    drop_targeted: bool,
}

impl ResidentChatPane {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (min_rows, max_rows) = m::INPUT_ROWS;
        let input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(min_rows, max_rows)
                .submit_on_enter(true)
                .placeholder("发消息，或让居民做点什么…")
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
                    this.input_focused = true;
                    this.state.focus_input();
                    cx.notify();
                } else if matches!(event, InputEvent::Blur) {
                    this.input_focused = false;
                    cx.notify();
                }
            },
        );
        Self {
            input,
            state: ChatState::default(),
            _subscription: subscription,
            compact: false,
            thumbnails: HashMap::new(),
            asr_error: None,
            input_focused: false,
            drop_targeted: false,
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
    /// A native ASR result edits the current composer; it never submits a turn.
    pub fn append_voice_transcript(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let current = self.input.read(cx).value().to_string();
        let draft = if current.is_empty() {
            text.to_owned()
        } else {
            format!("{current}\n{text}")
        };
        self.state.edit(draft.clone());
        self.input
            .update(cx, |input, cx| input.set_value(draft, window, cx));
        cx.notify();
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
    /// The host reports an external drag entering/leaving the composer. The drop
    /// itself is delivered by the native bridge; this only drives the hint and
    /// the surface change while the drag is over the panel.
    pub fn set_drop_targeted(&mut self, targeted: bool, cx: &mut Context<Self>) {
        if self.drop_targeted != targeted {
            self.drop_targeted = targeted;
            cx.notify();
        }
    }
    pub fn update_snapshot(&mut self, snapshot: serde_json::Value, cx: &mut Context<Self>) {
        self.asr_error = asr_error_notice(
            snapshot["voiceState"].as_str(),
            snapshot["voiceErrorCode"].as_str(),
        );
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
                            thumbnail_png: item["thumbnailPNG"].as_str().map(str::to_string),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        self.state.set_attachments(
            attachments,
            snapshot["attachmentsPreparing"].as_bool().unwrap_or(false),
        );
        self.thumbnails
            .retain(|id, _| self.state.attachments.iter().take(4).any(|a| &a.id == id));
        for attachment in self.state.attachments.iter().take(4) {
            if let Some(encoded) = &attachment.thumbnail_png {
                if !self
                    .thumbnails
                    .get(&attachment.id)
                    .is_some_and(|cached| &cached.encoded == encoded)
                {
                    self.thumbnails.insert(
                        attachment.id.clone(),
                        AttachmentThumbnail {
                            encoded: encoded.clone(),
                            image: decode_attachment_thumbnail(encoded),
                        },
                    );
                }
            } else {
                self.thumbnails.remove(&attachment.id);
            }
        }
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
        self.asr_error = None;
        self.drop_targeted = false;
        let draft = self.state.draft.clone();
        self.input
            .update(cx, |input, cx| input.set_value(draft, window, cx));
        cx.notify();
    }

    /// The fixed 132 pt transcript plus the copy button that sits beside it.
    ///
    /// The helpers below return a boxed element on purpose: a GPUI element type
    /// carries its whole child tree in its type, and several cards nested inside
    /// one render function is enough generic depth to make the `#[test]`
    /// expansion in this crate blow the compiler's recursion budget.
    fn history_card(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut entries = v_flex().gap(px(m::TRANSCRIPT_GAP)).w_full();
        for line in &self.state.transcript {
            entries = entries.child(self.transcript_entry(line));
        }
        if let Some(standalone) = standalone_reply(&self.state.reply, &self.state.transcript) {
            entries = entries.child(
                v_flex()
                    .gap(px(m::ENTRY_GAP))
                    .w_full()
                    .child(ui::section_title("居民"))
                    .child(ui::body(standalone).text_size(px(m::MESSAGE_SIZE))),
            );
        }
        let reply = self.state.reply.clone();
        h_flex()
            .items_start()
            .gap(px(m::HISTORY_GAP))
            .px(px(m::HISTORY_PADDING_H))
            .py(px(m::HISTORY_PADDING_V))
            .rounded(px(m::HISTORY_RADIUS))
            .bg(rgba(s::PANEL_BG))
            .w_full()
            .child(
                div()
                    .id("resident-transcript")
                    .h(px(m::HISTORY_HEIGHT))
                    .flex_shrink_0()
                    .flex_grow_0()
                    .w(px(0.))
                    .flex_1()
                    .overflow_y_scroll()
                    .accessibility_id("stage.resident-transcript")
                    .child(entries),
            )
            .when(!self.state.reply.is_empty(), |row| {
                row.child(
                    Button::new("copy-resident-reply")
                        .ghost()
                        .icon(gpui_kit::assets::IconName::Copy)
                        .w(px(m::COPY_BUTTON))
                        .h(px(m::COPY_BUTTON))
                        .rounded(px(6.))
                        .text_color(rgba(s::ICON))
                        .tooltip("复制最新回复")
                        .accessibility_label("复制最新回复")
                        .on_click(cx.listener(move |_, _, _, cx| {
                            cx.write_to_clipboard(ClipboardItem::new_string(reply.clone()));
                        })),
                )
            })
            .into_any_element()
    }

    fn transcript_entry(&self, line: &TranscriptLine) -> AnyElement {
        let entry = speaker_label(&line.speaker);
        let mut column = v_flex().gap(px(m::ENTRY_GAP)).w_full();
        if let Some(label) = entry.label {
            column = column.child(ui::section_title(label).text_size(px(m::LABEL_SIZE)));
        }
        let text = div()
            .text_size(px(m::MESSAGE_SIZE))
            .line_height(px(m::MESSAGE_LINE_HEIGHT))
            .w_full()
            .child(line.text.clone());
        column
            .child(if entry.notice {
                text.text_color(rgba(s::WARNING))
            } else {
                text.text_color(rgba(s::TEXT))
            })
            .into_any_element()
    }

    fn attachment_strip(&self, cx: &mut Context<Self>) -> AnyElement {
        let mut strip = div()
            .id("resident-attachments")
            .flex()
            .items_center()
            .gap(px(m::ATTACHMENT_GAP))
            .overflow_x_scroll()
            .w_full();
        for attachment in self.state.attachments.clone() {
            let id = attachment.id.clone();
            let name = attachment.file_name.clone();
            let mut plate = div()
                .relative()
                .w(px(m::ATTACHMENT_WIDTH))
                .h(px(m::ATTACHMENT_HEIGHT))
                .flex_shrink_0()
                .rounded(px(m::ATTACHMENT_RADIUS))
                .bg(rgba(s::PLATE))
                .overflow_hidden();
            if let Some(thumbnail) = self.thumbnails.get(&id) {
                plate = match &thumbnail.image {
                    Ok(image) => plate.child(
                        img(image.clone())
                            .w(px(m::ATTACHMENT_WIDTH))
                            .h(px(m::ATTACHMENT_HEIGHT))
                            .object_fit(ObjectFit::Contain),
                    ),
                    Err(message) => plate.child(
                        div()
                            .flex()
                            .items_center()
                            .justify_center()
                            .w_full()
                            .h_full()
                            .text_size(px(m::NOTICE_SIZE))
                            .text_color(rgba(s::TEXT_MUTED))
                            .child(*message),
                    ),
                };
            } else if let Some(path) = &attachment.preview_path {
                plate = plate.child(
                    img(std::path::PathBuf::from(path))
                        .w(px(m::ATTACHMENT_WIDTH))
                        .h(px(m::ATTACHMENT_HEIGHT))
                        .object_fit(ObjectFit::Contain),
                );
            } else {
                plate = plate.child(
                    div()
                        .flex()
                        .items_center()
                        .justify_center()
                        .w_full()
                        .h_full()
                        .text_size(px(m::NOTICE_SIZE))
                        .text_color(rgba(s::TEXT_MUTED))
                        .child("无预览"),
                );
            }
            let remove_label = format!("移除 {name}");
            strip = strip.child(plate.child(
                Button::new(format!("remove-attachment-{id}"))
                    .ghost()
                    .icon(gpui_kit::assets::IconName::CircleX)
                    .w(px(16.))
                    .h(px(16.))
                    .rounded(px(8.))
                    .text_color(rgba(s::TEXT))
                    .tooltip(remove_label.clone())
                    .accessibility_label(remove_label)
                    .absolute()
                    .top(px(1.))
                    .right(px(1.))
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.state.remove_attachment(id.clone());
                        cx.notify();
                    })),
            ));
        }
        strip.into_any_element()
    }

    /// The control row: attach, status readout, push-to-talk, optional stop, and
    /// the primary action. Semantics are the original's
    /// (`StageOverlayView.swift:334-412`): the primary action stops while a turn
    /// is running and there is nothing to send, and otherwise sends.
    fn control_row(&self, cx: &mut Context<Self>) -> AnyElement {
        let status = self
            .state
            .status
            .clone()
            .unwrap_or_else(|| self.state.status_line());
        let stop_label = if self.state.is_speaking {
            "停止说话"
        } else {
            "停止当前任务"
        };
        let primary_stops = self.state.primary_stops();
        let primary_label = if primary_stops { stop_label } else { "发送消息" };
        let can_submit = primary_stops || self.state.can_send();
        let voice_active = self.state.voice_active;
        let mut row = h_flex()
            .items_center()
            .gap(px(m::CONTROL_GAP))
            .w_full()
            .child(
                Button::new("resident-attachment")
                    .ghost()
                    .icon(gpui_kit::assets::IconName::Plus)
                    .w(px(m::ATTACH_BUTTON))
                    .h(px(m::ATTACH_BUTTON))
                    .rounded(px(m::ATTACH_BUTTON_RADIUS))
                    .text_color(rgba(s::ICON_ACTIVE))
                    .tooltip("添加图片，也可以直接粘贴图片")
                    .accessibility_label("添加图片附件")
                    .disabled(
                        self.state.attachments_preparing || self.state.attachments.len() >= 4,
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.state.pick_attachments();
                        cx.notify();
                    })),
            )
            .child(div().max_w(px(m::PANEL_MAX_WIDTH / 2.)).child(ui::flex_status(status)))
            .child(div().flex_1())
            .child(ui::hold_button(
                "resident-push-to-talk",
                "stage.resident-push-to-talk",
                gpui_kit::assets::IconName::Mic,
                "按住说话，松开发送",
                voice_active,
                cx.listener(|this, _, _, cx| {
                    this.state.begin_voice();
                    cx.notify();
                }),
                cx.listener(|this, _, _, cx| {
                    this.state.finish_voice();
                    cx.notify();
                }),
            ));
        if self.state.can_stop() && self.state.has_draft() {
            row = row.child(
                Button::new("resident-stop")
                    .ghost()
                    .small()
                    .icon(gpui_kit::assets::IconName::Square)
                    .w(px(s::CONTROL_HEIGHT))
                    .h(px(s::CONTROL_HEIGHT))
                    .rounded(px(s::CONTROL_RADIUS))
                    .text_color(rgba(s::ICON_ACTIVE))
                    .tooltip(stop_label)
                    .accessibility_label(stop_label)
                    .accessibility_id("stage.resident-stop")
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
        // Icon-only, like every control in this layer: the words are the
        // tooltip and the accessibility label, so "停止说话" and "发送消息" stay
        // reachable without putting text inside the button.
        let primary = ui::primary_circle_button(
            cx,
            "resident-send",
            if primary_stops {
                gpui_kit::assets::IconName::Square
            } else {
                gpui_kit::assets::IconName::ArrowUp
            },
            primary_label,
            can_submit,
        );
        row.child(primary.on_click(cx.listener(|this, _, window, cx| {
            let previous = this.state.draft.clone();
            this.state.primary_action();
            let draft = this.state.draft.clone();
            if draft != previous {
                this.input
                    .update(cx, |input, cx| input.set_value(draft, window, cx));
            }
            cx.notify();
        })))
        .into_any_element()
    }

    /// The composer card: drop hint, notices, attachments, input, controls.
    fn composer_card(&self, cx: &mut Context<Self>) -> AnyElement {
        let chrome = composer_chrome(self.drop_targeted, self.input_focused);
        let mut card = v_flex()
            .gap(px(m::CARD_GAP))
            .p(px(m::CARD_PADDING))
            .rounded(px(m::CARD_RADIUS))
            .bg(rgba(chrome.background))
            .border(px(chrome.border_width))
            .border_color(rgba(chrome.border))
            .w_full();
        if self.drop_targeted {
            card = card.child(
                div()
                    .id("stage.resident-image-drop-hint")
                    .text_size(px(m::NOTICE_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(rgba(s::ACCENT))
                    .child("松手把图片加进这条消息"),
            );
        }
        if let Some(notice) = self.state.host_notice.as_ref() {
            card = card.child(
                ui::notice(format!("应用提示：{notice}"))
                    .id("stage.resident-status-notice"),
            );
        }
        if let Some(status) = self.state.status.as_ref() {
            card = card.child(
                ui::notice(status.clone()).id("stage.resident-delivery-notice"),
            );
        }
        if let Some(error) = self.state.tts_error.as_ref() {
            card = card.child(ui::notice(error.clone()));
        }
        if !self.state.attachments.is_empty() {
            card = card.child(self.attachment_strip(cx));
            if self.state.attachments.len() > 4 {
                card = card.child(ui::muted(
                    "图片已保留，请移除多余图片后再发送（最多4张）。",
                ));
            }
        }
        if self.state.attachments_preparing {
            card = card.child(ui::muted("正在准备图片…"));
        }
        if let Some(error) = self.state.attachments_error.as_ref() {
            card = card.child(ui::notice(error.clone()));
        }
        let input = Textarea::new(&self.input)
            .appearance(false)
            .bordered(false)
            .accessibility_id("stage.resident-input")
            .aria_label("给居民发消息")
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
        if let Some(error) = self.asr_error.as_ref() {
            card = card.child(
                Alert::error("resident-asr-error", error.clone())
                    .small()
                    .title("语音识别未完成"),
            );
        }
        card.child(input)
            .child(self.control_row(cx))
            .into_any_element()
    }
}

impl Render for ResidentChatPane {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let mut column = v_flex()
            .w_full()
            .max_w(px(m::PANEL_MAX_WIDTH))
            .max_h(px(m::PANEL_MAX_HEIGHT))
            .gap(px(s::PANEL_GAP))
            .font_family(crate::ui_tokens::FONT_FAMILY);
        if self.compact {
            // The Live Cam panel pins this to 70/140 pt; the composer card fills it.
            column = column.h_full();
        } else if history_visible(&self.state) {
            column = column.child(self.history_card(cx));
        }
        let drop_entity = cx.entity().downgrade();
        column
            .child(self.composer_card(cx))
            .drag_over::<ExternalPaths>(|style, _, _, _| {
                style
                    .border_2()
                    .border_color(rgba(s::BORDER_ACTIVE))
                    .bg(rgba(s::CARD_BG_ACTIVE))
            })
            .on_drag_move::<ExternalPaths>(move |event, _, cx| {
                let inside = event.bounds.contains(&event.event.position);
                let _ = drop_entity.update(cx, |this, cx| this.set_drop_targeted(inside, cx));
            })
    }
}

impl Drop for ResidentChatPane {
    fn drop(&mut self) {
        // A press that ends with the pane going away must not leave the
        // microphone open (the original releases in `onDisappear`).
        self.state.finish_voice();
    }
}

#[cfg(test)]
mod tests {
    // gpui re-exports a `test` attribute macro; `super::*` would shadow the
    // built-in one, so name it explicitly like the rest of this crate does.
    use core::prelude::v1::test;
    use super::*;
    use crate::state::ChatAttachment;

    fn line(speaker: &str, text: &str) -> TranscriptLine {
        TranscriptLine {
            speaker: speaker.into(),
            text: text.into(),
        }
    }

    #[test]
    fn speakers_map_to_the_original_labels_and_notices_read_as_system_lines() {
        assert_eq!(speaker_label("你").label, Some("你"));
        assert_eq!(speaker_label("居民").label, Some("居民"));
        for notice in ["", "系统", "notice", "提示"] {
            let entry = speaker_label(notice);
            assert_eq!(entry.label, None, "{notice} must not be labelled as a person");
            assert!(entry.notice, "{notice} must read in the warning colour");
        }
        assert_eq!(speaker_label("导演").label, Some("导演"));
        assert!(!speaker_label("导演").notice);
    }

    #[test]
    fn standalone_reply_is_only_shown_when_history_does_not_end_with_it() {
        let history = vec![line("你", "问题"), line("居民", "答案")];
        assert_eq!(standalone_reply("答案", &history), None);
        assert_eq!(standalone_reply("  答案  ", &history), None);
        assert_eq!(standalone_reply("另一条", &history).as_deref(), Some("另一条"));
        assert_eq!(standalone_reply("   ", &history), None);
        assert_eq!(standalone_reply("只有后台回复", &[]).as_deref(), Some("只有后台回复"));
    }

    #[test]
    fn plain_text_labels_people_and_leaves_notices_unlabelled() {
        let history = vec![line("你", "问题"), line("居民", "答案"), line("系统", "已经摆好了")];
        assert_eq!(plain_text(&history), "你：问题\n\n居民：答案\n\n已经摆好了");
    }

    #[test]
    fn empty_history_is_not_drawn() {
        let mut state = ChatState::default();
        assert!(!history_visible(&state));
        state.transcript.push(line("居民", "你好"));
        assert!(history_visible(&state));
        let mut reply_only = ChatState::default();
        reply_only.reply = "后台回复".into();
        assert!(history_visible(&reply_only));
    }

    #[test]
    fn composer_chrome_matches_the_original_focus_and_drop_states() {
        assert_eq!(composer_chrome(false, false).background, s::CARD_BG);
        assert_eq!(composer_chrome(false, false).border, s::BORDER);
        assert_eq!(composer_chrome(false, false).border_width, 1.);
        assert_eq!(composer_chrome(false, true).border, s::BORDER_FOCUSED);
        let dropped = composer_chrome(true, false);
        assert_eq!(dropped.background, s::CARD_BG_ACTIVE);
        assert_eq!(dropped.border, s::BORDER_ACTIVE);
        assert_eq!(dropped.border_width, 2.);
        assert_ne!(dropped.background, s::CARD_BG);
    }

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
            id: "one".into(),
            file_name: "one.png".into(),
            preview_path: None,
            thumbnail_png: None,
        });
        assert_eq!(compact_composer_height(&state), 140.);
        state.attachments.clear();
        assert_eq!(compact_composer_height(&state), 70.);
    }

    fn png(width: u32, height: u32) -> String {
        use image::ImageEncoder as _;
        let mut bytes = vec![];
        image::codecs::png::PngEncoder::new(&mut bytes)
            .write_image(
                &vec![255; width as usize * height as usize * 4],
                width,
                height,
                image::ExtendedColorType::Rgba8,
            )
            .unwrap();
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    #[test]
    fn native_inline_png_decodes_without_disk_or_uri_loader() {
        assert!(decode_attachment_thumbnail(&png(96, 80)).is_ok());
    }

    #[test]
    fn malformed_and_oversized_thumbnails_have_explicit_no_preview() {
        assert!(decode_attachment_thumbnail("not base64").is_err());
        assert!(
            decode_attachment_thumbnail(&base64::engine::general_purpose::STANDARD.encode(b"not PNG"))
                .is_err()
        );
        assert!(decode_attachment_thumbnail(&png(97, 1)).is_err());
        assert!(decode_attachment_thumbnail(&"A".repeat(43_693)).is_err());
    }

    #[test]
    fn invalid_thumbnail_does_not_block_valid_attachment_submission() {
        let mut state = ChatState::default();
        state.set_attachments(
            vec![ChatAttachment {
                id: "verified-host-id".into(),
                file_name: "照片.png".into(),
                preview_path: None,
                thumbnail_png: Some("invalid".into()),
            }],
            false,
        );
        assert!(state.can_send());
    }

    #[test]
    fn error_notice_is_safe_and_clears_on_new_capture_or_success() {
        let error = asr_error_notice(Some("error"), Some("microphone_permission")).unwrap();
        assert!(error.contains("麦克风权限"));
        assert!(error.contains("microphone_permission"));
        for state in [
            None,
            Some("idle"),
            Some("connecting"),
            Some("listening"),
            Some("transcribing"),
        ] {
            assert!(asr_error_notice(state, Some("microphone_permission")).is_none());
        }
        let unsafe_description = "https://provider.example/token=secret /private/credential";
        let error = asr_error_notice(Some("error"), Some(unsafe_description)).unwrap();
        assert!(error.contains("asr_failed"));
        assert!(!error.contains("secret") && !error.contains("provider.example") && !error.contains("/private"));
        assert_eq!(safe_asr_error_code(None), "asr_failed");
    }

    /// The pane must survive real GPUI window draws, and the composer must keep
    /// sending the same command sequence the host expects while it does.
    #[test]
    fn pane_draws_in_a_real_window_and_keeps_host_command_semantics() {
        use gpui_kit::{AppContext, TestAppContext};
        let mut cx = TestAppContext::single();
        cx.update(gpui_kit::init);
        let stored = std::rc::Rc::new(std::cell::RefCell::new(None));
        let entity = stored.clone();
        let handle = cx.add_window(move |window, cx| {
            let pane = cx.new(|cx| {
                let mut pane = super::ResidentChatPane::new(window, cx);
                pane.set_transcript(
                    vec![line("你", "问题"), line("居民", "答案"), line("系统", "已经摆好了")],
                    cx,
                );
                pane
            });
            *entity.borrow_mut() = Some(pane.clone());
            gpui_kit::base::Root::new(pane, window, cx)
        });
        // First paint: a three-turn history and an idle composer.
        cx.update_window(handle.into(), |_, window, cx| {
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
        let pane = stored.borrow().clone().expect("pane entity");
        // Second paint: submit, accept, reply, then a live turn with a notice and
        // a held microphone. This is where an unbounded layout, or a stop control
        // that never appears, would show up.
        cx.update_window(handle.into(), |_, window, cx| {
            pane.update(cx, |pane, cx| {
                pane.state.edit("发给居民".into());
                assert!(pane.state.send(), "a draft must produce exactly one send");
                assert!(matches!(
                    pane.take_commands().as_slice(),
                    [ChatCommand::Send { .. }]
                ));
                pane.accepted(1, window, cx);
                pane.reply(1, "答案".into(), cx);
                assert!(history_visible(&pane.state));
                assert_eq!(composer_chrome(false, false).background, s::CARD_BG);
                pane.state.host_thinking = true;
                pane.state.host_can_stop = true;
                pane.state.host_notice = Some("正在查询歌单…".into());
                pane.state.voice_active = true;
                assert!(pane.state.can_stop(), "a running host task offers the stop control");
                cx.notify();
            });
            window.refresh();
            window.draw(cx).clear(cx);
        })
        .unwrap();
    }
}
