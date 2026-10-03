//! UI-only state. The host owns transport, transcript persistence and synthesis.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatCommand {
    Send { request_id: u64, text: String },
    Cancel { request_id: u64 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TranscriptLine {
    pub speaker: String,
    pub text: String,
}

#[derive(Clone, Debug)]
struct Pending {
    id: u64,
    revision: u64,
    accepted: bool,
    submitted: String,
}

#[derive(Default)]
pub struct ChatState {
    pub draft: String,
    pub reply: String,
    pub transcript: Vec<TranscriptLine>,
    pub progress: Option<String>,
    pub status: Option<String>,
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
    pub fn can_send(&self) -> bool {
        !self.thinking() && !self.draft.trim().is_empty()
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
        });
        self.reply.clear();
        self.status = None;
        self.progress = Some("等待居民回应…".into());
        self.commands.push(ChatCommand::Send {
            request_id: self.next_id,
            text: self.draft.trim().into(),
        });
        true
    }
    /// Call only after the actual host accepts delivery. Never clear a newer edit.
    pub fn accepted(&mut self, id: u64) -> bool {
        let Some(pending) = self.pending.as_mut().filter(|p| p.id == id && !p.accepted) else {
            return false;
        };
        pending.accepted = true;
        if pending.revision == self.revision {
            self.draft.clear();
            self.revision += 1;
        }
        true
    }
    pub fn fail(&mut self, id: u64, notice: String) -> bool {
        if !self.pending.as_ref().is_some_and(|p| p.id == id) {
            return false;
        }
        let pending = self.pending.take().expect("matching pending request");
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
        if !self.pending.as_ref().is_some_and(|p| p.id == id && p.accepted) { return false; }
        self.pending = None;
        self.reply.clear();
        self.progress = None;
        self.status = None;
        true
    }
    pub fn cancel(&mut self) {
        if let Some(p) = self.pending.take() {
            self.commands.push(ChatCommand::Cancel { request_id: p.id });
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
        self.revision += 1;
        self.reply.clear();
        self.transcript.clear();
        self.status = None;
    }
    pub fn take_commands(&mut self) -> Vec<ChatCommand> {
        std::mem::take(&mut self.commands)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        assert!(matches!(s.take_commands().as_slice(), [ChatCommand::Cancel { request_id: 1 }]));
        s.edit("新世界".into());
        s.send();
        assert!(matches!(s.take_commands().as_slice(), [ChatCommand::Send { request_id: 2, .. }]));
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
