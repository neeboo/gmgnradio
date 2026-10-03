//! UI-only state. The host owns transport, transcript persistence and synthesis.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatCommand {
    Send {
        request_id: u64,
        text: String,
        attachment_ids: Vec<String>,
    },
    Cancel {
        request_id: u64,
    },
    PickAttachments,
    PasteAttachments,
    ImportAttachments {
        paths: Vec<String>,
    },
    RemoveAttachment {
        id: String,
    },
    BeginVoice,
    FinishVoice,
    StopSpeech,
    StopTask,
    FocusInput,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TranscriptLine {
    pub speaker: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ChatAttachment {
    pub id: String,
    pub file_name: String,
    pub preview_path: Option<String>,
}

#[derive(Clone, Debug)]
struct Pending {
    id: u64,
    revision: u64,
    accepted: bool,
    submitted: String,
    attachments: Vec<ChatAttachment>,
}

#[derive(Default)]
pub struct ChatState {
    pub draft: String,
    pub reply: String,
    pub transcript: Vec<TranscriptLine>,
    pub progress: Option<String>,
    pub status: Option<String>,
    pub attachments: Vec<ChatAttachment>,
    pub attachments_preparing: bool,
    pub attachments_error: Option<String>,
    pub voice_active: bool,
    pub is_speaking: bool,
    pub host_can_stop: bool,
    pub host_thinking: bool,
    pub host_progress: Option<String>,
    pub host_notice: Option<String>,
    pub tts_error: Option<String>,
    voice_pressed: bool,
    revision: u64,
    next_id: u64,
    pending: Option<Pending>,
    commands: Vec<ChatCommand>,
}

impl ChatState {
    pub fn edit(&mut self, text: String) {
        if self.draft != text {
            self.draft = text;
            self.revision += 1;
        }
    }
    pub fn thinking(&self) -> bool {
        self.pending.is_some()
    }
    pub fn has_draft(&self) -> bool {
        !self.draft.trim().is_empty() || !self.attachments.is_empty()
    }
    pub fn can_stop(&self) -> bool {
        self.thinking() || self.host_can_stop || self.is_speaking
    }
    pub fn primary_stops(&self) -> bool {
        self.can_stop() && !self.has_draft()
    }
    pub fn stop_reply(&mut self) {
        if self.is_speaking {
            self.stop_speech();
        } else {
            self.stop_task();
        }
    }
    pub fn primary_action(&mut self) {
        if self.primary_stops() {
            self.stop_reply();
        } else {
            self.send();
        }
    }
    pub fn can_send(&self) -> bool {
        !self
            .pending
            .as_ref()
            .is_some_and(|p| !p.accepted && p.revision == self.revision)
            && !self.attachments_preparing
            && self.attachments.len() <= 4
            && (!self.draft.trim().is_empty() || !self.attachments.is_empty())
    }
    pub fn send(&mut self) -> bool {
        if !self.can_send() {
            return false;
        }
        self.next_id += 1;
        self.pending = Some(Pending {
            id: self.next_id,
            revision: self.revision,
            accepted: false,
            submitted: self.draft.clone(),
            attachments: self.attachments.clone(),
        });
        self.reply.clear();
        self.status = None;
        self.progress = Some("等待居民回应…".into());
        self.commands.push(ChatCommand::Send {
            request_id: self.next_id,
            text: self.draft.trim().into(),
            attachment_ids: self.attachments.iter().map(|a| a.id.clone()).collect(),
        });
        true
    }
    pub fn submit_enter(&mut self, shift: bool, composing: bool) -> bool {
        !shift && !composing && self.send()
    }
    /// Call only after the actual host accepts delivery. Never clear a newer edit.
    pub fn accepted(&mut self, id: u64) -> bool {
        let Some(pending) = self.pending.as_mut().filter(|p| p.id == id && !p.accepted) else {
            return false;
        };
        pending.accepted = true;
        if pending.revision == self.revision {
            self.draft.clear();
            self.attachments.clear();
            self.revision += 1;
        }
        true
    }
    pub fn fail(&mut self, id: u64, notice: String) -> bool {
        if !self.pending.as_ref().is_some_and(|p| p.id == id) {
            return false;
        }
        let pending = self.pending.take().expect("matching pending request");
        self.restore_attachments(pending.attachments);
        if self.draft != pending.submitted {
            self.draft = if self.draft.is_empty() {
                pending.submitted
            } else {
                format!("{}\n{}", pending.submitted, self.draft)
            };
            self.revision += 1;
        }
        self.progress = None;
        self.status = Some(format!("{notice}\n文字已保留。"));
        true
    }
    pub fn finish(&mut self, id: u64, reply: String) -> bool {
        if !self
            .pending
            .as_ref()
            .is_some_and(|p| p.id == id && p.accepted)
        {
            return false;
        }
        self.pending = None;
        self.reply = reply;
        self.progress = None;
        self.status = None;
        true
    }
    pub fn update_progress(&mut self, id: u64, progress: String) -> bool {
        if !self.pending.as_ref().is_some_and(|p| p.id == id) {
            return false;
        }
        self.progress = Some(progress);
        true
    }
    pub fn complete_without_reply(&mut self, id: u64) -> bool {
        if !self
            .pending
            .as_ref()
            .is_some_and(|p| p.id == id && p.accepted)
        {
            return false;
        }
        self.pending = None;
        self.reply.clear();
        self.progress = None;
        self.status = None;
        true
    }
    pub fn cancel(&mut self) {
        if let Some(p) = self.pending.take() {
            self.commands.push(ChatCommand::Cancel { request_id: p.id });
            self.restore_attachments(p.attachments);
            if self.draft != p.submitted {
                self.draft = if self.draft.is_empty() {
                    p.submitted
                } else {
                    format!("{}\n{}", p.submitted, self.draft)
                };
                self.revision += 1;
            }
            self.progress = None;
            self.status = Some("已停止本次回复。\n文字已保留。".into());
        }
    }
    /// Context changes invalidate old callbacks without recycling request IDs.
    pub fn reset_context(&mut self) {
        self.cancel();
        self.draft.clear();
        self.attachments.clear();
        self.finish_voice();
        self.revision += 1;
        self.reply.clear();
        self.transcript.clear();
        self.status = None;
    }
    pub fn take_commands(&mut self) -> Vec<ChatCommand> {
        std::mem::take(&mut self.commands)
    }
    fn restore_attachments(&mut self, attachments: Vec<ChatAttachment>) {
        for attachment in attachments {
            if !self.attachments.iter().any(|a| a.id == attachment.id) {
                self.attachments.push(attachment);
            }
        }
    }
    pub fn set_attachments(&mut self, attachments: Vec<ChatAttachment>, preparing: bool) {
        if self.attachments != attachments {
            self.revision += 1;
        }
        self.attachments = attachments;
        self.attachments_preparing = preparing;
    }
    pub fn pick_attachments(&mut self) {
        if !self.attachments_preparing && self.attachments.len() < 4 {
            self.commands.push(ChatCommand::PickAttachments);
        }
    }
    pub fn paste_attachments(&mut self) {
        if !self.attachments_preparing && self.attachments.len() < 4 {
            self.commands.push(ChatCommand::PasteAttachments);
        }
    }
    pub fn import_attachments(&mut self, paths: Vec<String>) {
        if !paths.is_empty() && !self.attachments_preparing && self.attachments.len() < 4 {
            self.commands.push(ChatCommand::ImportAttachments { paths });
        }
    }
    pub fn remove_attachment(&mut self, id: String) {
        if self.attachments.iter().any(|a| a.id == id) {
            self.attachments.retain(|a| a.id != id);
            self.revision += 1;
            self.commands.push(ChatCommand::RemoveAttachment { id });
        }
    }
    pub fn begin_voice(&mut self) {
        if !self.voice_pressed {
            self.voice_pressed = true;
            self.commands.push(ChatCommand::BeginVoice);
        }
    }
    pub fn finish_voice(&mut self) {
        if self.voice_pressed {
            self.voice_pressed = false;
            self.commands.push(ChatCommand::FinishVoice);
        }
    }
    pub fn stop_speech(&mut self) {
        self.commands.push(ChatCommand::StopSpeech);
    }
    pub fn stop_task(&mut self) {
        if self.thinking() {
            self.cancel();
        } else if self.host_can_stop {
            self.commands.push(ChatCommand::StopTask);
        }
    }
    pub fn focus_input(&mut self) {
        self.commands.push(ChatCommand::FocusInput);
    }
    pub fn status_line(&self) -> String {
        if self.is_speaking {
            "🗣️ 正在说话…".into()
        } else if self.thinking() || self.host_thinking {
            format!(
                "🤔 {}",
                self.progress
                    .as_deref()
                    .or(self.host_progress.as_deref())
                    .unwrap_or("等待居民回应…")
            )
        } else if self.voice_active {
            "👂 正在听你说话…".into()
        } else {
            "你的居民".into()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ime_confirmation_and_shift_enter_do_not_submit() {
        let mut s = ChatState::default();
        s.edit("中文草稿".into());
        assert!(!s.submit_enter(false, true));
        assert!(!s.submit_enter(true, false));
        assert!(s.take_commands().is_empty());
        assert_eq!(s.draft, "中文草稿");
        assert!(s.submit_enter(false, false));
    }
    #[test]
    fn new_draft_supersedes_pending_without_accepting_old_callbacks() {
        let mut s = ChatState::default();
        s.edit("第一句".into());
        s.send();
        assert!(!s.send());
        s.edit("第二句".into());
        assert!(s.send());
        assert!(!s.accepted(1));
        assert!(s.accepted(2));
        assert!(!s.finish(1, "旧回复".into()));
        assert!(s.finish(2, "新回复".into()));
    }
    #[test]
    fn primary_stop_uses_voice_priority_and_draft_restores_send() {
        let mut s = ChatState::default();
        s.host_can_stop = true;
        s.is_speaking = true;
        assert!(s.primary_stops());
        s.primary_action();
        assert_eq!(s.take_commands(), vec![ChatCommand::StopSpeech]);
        s.edit("新消息".into());
        assert!(!s.primary_stops());
        s.primary_action();
        assert!(matches!(
            s.take_commands().as_slice(),
            [ChatCommand::Send { .. }]
        ));
        s.focus_input();
        assert_eq!(s.take_commands(), vec![ChatCommand::FocusInput]);
    }
    #[test]
    fn status_matches_original_voice_thinking_listening_priority() {
        let mut s = ChatState::default();
        assert_eq!(s.status_line(), "你的居民");
        s.voice_active = true;
        assert_eq!(s.status_line(), "👂 正在听你说话…");
        s.host_thinking = true;
        s.host_progress = Some("正在查询歌单…".into());
        assert_eq!(s.status_line(), "🤔 正在查询歌单…");
        s.is_speaking = true;
        assert_eq!(s.status_line(), "🗣️ 正在说话…");
    }
    fn attachment(id: &str) -> ChatAttachment {
        ChatAttachment {
            id: id.into(),
            file_name: format!("{id}.png"),
            preview_path: None,
        }
    }
    #[test]
    fn attachment_only_submission_and_failure_preserve_original_ids() {
        let mut s = ChatState::default();
        s.set_attachments(vec![attachment("image")], false);
        assert!(s.can_send());
        assert!(s.send());
        assert!(
            matches!(&s.take_commands()[0], ChatCommand::Send { text, attachment_ids, .. } if text.is_empty() && attachment_ids == &["image"])
        );
        s.accepted(1);
        assert!(s.attachments.is_empty());
        s.fail(1, "失败".into());
        assert_eq!(s.attachments, vec![attachment("image")]);
    }
    #[test]
    fn attachment_preparation_and_limit_gate_all_import_paths() {
        let mut s = ChatState::default();
        s.set_attachments(vec![attachment("a")], true);
        assert!(!s.can_send());
        s.pick_attachments();
        s.paste_attachments();
        assert!(s.take_commands().is_empty());
        s.set_attachments(
            (0..5).map(|id| attachment(&id.to_string())).collect(),
            false,
        );
        assert_eq!(s.attachments.len(), 5);
        assert!(!s.can_send());
        s.pick_attachments();
        s.import_attachments(vec!["/tmp/image.png".into()]);
        assert!(s.take_commands().is_empty());
        s.remove_attachment("0".into());
        assert_eq!(s.attachments.len(), 4);
    }
    #[test]
    fn concurrent_attachments_and_failed_submission_are_all_retained() {
        let mut s = ChatState::default();
        s.set_attachments(vec![attachment("old")], false);
        s.send();
        s.accepted(1);
        s.set_attachments(
            (0..4).map(|id| attachment(&id.to_string())).collect(),
            false,
        );
        s.pick_attachments();
        s.fail(1, "失败".into());
        assert_eq!(s.attachments.len(), 5);
        assert!(s.attachments.iter().any(|a| a.id == "old"));
        assert!(!s.can_send());
        s.remove_attachment("old".into());
        assert!(s.can_send());
    }
    #[test]
    fn push_to_talk_release_outside_is_single_and_separate_from_stop_speech() {
        let mut s = ChatState::default();
        s.begin_voice();
        s.begin_voice();
        s.finish_voice();
        s.finish_voice();
        s.stop_speech();
        assert_eq!(
            s.take_commands(),
            vec![
                ChatCommand::BeginVoice,
                ChatCommand::FinishVoice,
                ChatCommand::StopSpeech
            ]
        );
        s.begin_voice();
        s.reset_context();
        assert_eq!(
            s.take_commands(),
            vec![ChatCommand::BeginVoice, ChatCommand::FinishVoice]
        );
    }
    #[test]
    fn background_task_stop_is_available_without_pending_chat_and_does_not_stop_speech() {
        let mut s = ChatState::default();
        s.host_can_stop = true;
        s.is_speaking = true;
        s.stop_task();
        assert_eq!(s.take_commands(), vec![ChatCommand::StopTask]);
        s.stop_speech();
        assert_eq!(s.take_commands(), vec![ChatCommand::StopSpeech]);
    }
    #[test]
    fn failure_keeps_draft() {
        let mut s = ChatState::default();
        s.edit("你好".into());
        s.send();
        assert!(s.fail(1, "发送失败".into()));
        assert_eq!(s.draft, "你好");
        assert!(!s.fail(1, "重复".into()));
    }
    #[test]
    fn concurrent_edit_is_not_cleared() {
        let mut s = ChatState::default();
        s.edit("旧消息".into());
        s.send();
        s.edit("新草稿".into());
        assert!(s.accepted(1));
        assert_eq!(s.draft, "新草稿");
        assert!(!s.accepted(1));
    }
    #[test]
    fn stale_reply_cannot_finish_new_request() {
        let mut s = ChatState::default();
        s.edit("第一条".into());
        s.send();
        s.cancel();
        s.send();
        s.accepted(2);
        assert!(!s.finish(1, "旧回复".into()));
        assert!(s.finish(2, "新回复".into()));
        assert!(!s.finish(2, "重复回复".into()));
        assert_eq!(s.reply, "新回复");
    }
    #[test]
    fn whitespace_and_concurrent_send_are_rejected() {
        let mut s = ChatState::default();
        s.edit(" \n\t".into());
        assert!(!s.send());
        s.edit("消息".into());
        assert!(s.send());
        assert!(!s.send());
        assert_eq!(s.take_commands().len(), 1);
    }
    #[test]
    fn acceptance_clears_original_draft_only_once() {
        let mut s = ChatState::default();
        s.edit("消息".into());
        s.send();
        s.accepted(1);
        assert_eq!(s.draft, "");
        s.edit("下一条".into());
        assert!(!s.accepted(1));
        assert_eq!(s.draft, "下一条");
    }
    #[test]
    fn failure_after_acceptance_restores_original() {
        let mut s = ChatState::default();
        s.edit("  原文  ".into());
        s.send();
        s.accepted(1);
        assert!(s.fail(1, "回复失败".into()));
        assert_eq!(s.draft, "  原文  ");
        assert!(!s.thinking());
    }
    #[test]
    fn failure_preserves_new_edit_and_rejects_stale_callback() {
        let mut s = ChatState::default();
        s.edit("旧消息".into());
        s.send();
        s.accepted(1);
        s.edit("新草稿".into());
        assert!(s.fail(1, "失败".into()));
        assert_eq!(s.draft, "旧消息\n新草稿");
        assert!(!s.fail(1, "重复".into()));
        s.send();
        assert!(!s.fail(1, "过期".into()));
        assert!(s.thinking());
    }
    #[test]
    fn cancellation_restores_accepted_draft_and_rejects_late_reply() {
        let mut s = ChatState::default();
        s.edit("重试这条".into());
        s.send();
        s.accepted(1);
        s.cancel();
        assert_eq!(s.draft, "重试这条");
        assert!(!s.finish(1, "迟到回复".into()));
        assert!(!s.accepted(1));
        assert!(s.can_send());
        s.cancel();
        assert_eq!(s.draft, "重试这条");
    }
    #[test]
    fn cancellation_keeps_concurrent_edit_without_duplicate_original() {
        let mut s = ChatState::default();
        s.edit("旧文".into());
        s.send();
        s.cancel();
        assert_eq!(s.draft, "旧文");
        s.send();
        s.accepted(2);
        s.edit("新文".into());
        s.cancel();
        assert_eq!(s.draft, "旧文\n新文");
        assert!(!s.finish(2, "迟到".into()));
        assert!(!s.thinking());
    }
    #[test]
    fn scope_change_discards_old_draft_and_cancels_only_old_request() {
        let mut s = ChatState::default();
        s.edit("旧世界消息".into());
        s.send();
        s.take_commands();
        s.accepted(1);
        s.edit("旧世界草稿".into());
        s.reset_context();
        assert!(s.draft.is_empty());
        assert!(!s.thinking());
        assert!(!s.finish(1, "迟到".into()));
        assert!(matches!(
            s.take_commands().as_slice(),
            [ChatCommand::Cancel { request_id: 1 }]
        ));
        s.edit("新世界".into());
        s.send();
        assert!(matches!(
            s.take_commands().as_slice(),
            [ChatCommand::Send { request_id: 2, .. }]
        ));
    }
    #[test]
    fn silent_completed_turn_requires_acceptance_and_adds_no_reply() {
        let mut s = ChatState::default();
        s.edit("做一件事".into());
        s.send();
        assert!(!s.complete_without_reply(1));
        s.accepted(1);
        assert!(s.complete_without_reply(1));
        assert!(!s.thinking());
        assert!(s.reply.is_empty());
        assert!(!s.complete_without_reply(1));
    }
}
