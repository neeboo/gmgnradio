//! ACP session control only. DSH's native plugin owns its model/tool loop;
//! host tool dispatch travels over the authenticated HTTP seam, never text.
use crate::{TurnIdentity, UserInput};
use base64::Engine;
use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DshState {
    New,
    Initializing,
    Opening,
    Prompting,
    Cancelling,
    Completed,
    Cancelled,
    Failed,
    Unknown,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DshError {
    InvalidState,
    InvalidFrame,
    InputLimit,
    ImagesUnsupported,
    IdentityMismatch,
}
pub enum DshEvent {
    Send(Value),
    SessionReady {
        session_id: String,
        image_capability: bool,
    },
    TextDelta(String),
    Terminal {
        state: DshState,
        reply: String,
    },
}
/// No Debug: user input and streamed text remain private.
pub struct DshSession<I = TurnIdentity> {
    identity: I,
    cwd: String,
    input: Option<UserInput>,
    state: DshState,
    session: Option<String>,
    image_capability: bool,
    pending: Option<(u64, &'static str)>,
    next_id: u64,
    text: String,
    allow_silent: bool,
}
impl DshSession<TurnIdentity> {
    pub fn new(
        identity: TurnIdentity,
        cwd: String,
        input: UserInput,
        allow_silent: bool,
    ) -> Result<Self, DshError> {
        if [
            &identity.world_id,
            &identity.scope_id,
            &identity.session_id,
            &identity.run_id,
        ]
        .iter()
        .any(|v| v.is_empty() || v.len() > 256)
            || !cwd.starts_with('/')
            || input.text.len() > 65536
            || (input.text.trim().is_empty() && input.images.is_empty())
        {
            return Err(DshError::InvalidFrame);
        }
        crate::validate_images(&input.images, true, 4 * 1024 * 1024)
            .map_err(|_| DshError::InputLimit)?;
        Self::create(identity, cwd, input, allow_silent)
    }
}
pub use crate::chat_dsh::ChatDshIdentity as ChatIdentity;
impl DshSession<ChatIdentity> {
    pub fn new_chat(
        identity: ChatIdentity,
        cwd: String,
        input: UserInput,
    ) -> Result<Self, DshError> {
        if [
            &identity.scope_id,
            &identity.host_session_id,
            &identity.request_id,
        ]
        .iter()
        .any(|v| v.is_empty() || v.len() > 256 || v.contains('\0'))
        {
            return Err(DshError::InvalidFrame);
        }
        Self::create(identity, cwd, input, false)
    }
    pub fn next_chat_turn(
        &mut self,
        identity: ChatIdentity,
        input: UserInput,
    ) -> Result<Value, DshError> {
        if identity.scope_id != self.identity.scope_id
            || identity.host_session_id != self.identity.host_session_id
            || identity.request_id == self.identity.request_id
            || identity.request_id.is_empty()
            || identity.request_id.len() > 256
            || identity.request_id.contains('\0')
        {
            return Err(DshError::IdentityMismatch);
        }
        if self.state != DshState::Completed {
            return Err(DshError::InvalidState);
        }
        Self::validate_input(&self.cwd, &input)?;
        if !input.images.is_empty() && !self.image_capability {
            return Err(DshError::ImagesUnsupported);
        }
        let mut blocks=input.images.into_iter().map(|image|json!({"type":"image","data":base64::engine::general_purpose::STANDARD.encode(image.bytes),"mimeType":image.media_type})).collect::<Vec<_>>();
        if !input.text.is_empty() {
            blocks.push(json!({"type":"text","text":input.text}));
        }
        self.identity = identity;
        self.text.clear();
        self.state = DshState::Prompting;
        Ok(self.request(
            "session/prompt",
            json!({"sessionId":self.session,"prompt":blocks}),
        ))
    }
}
impl<I> DshSession<I> {
    fn validate_input(cwd: &str, input: &UserInput) -> Result<(), DshError> {
        if !cwd.starts_with('/')
            || input.text.len() > 65536
            || (input.text.trim().is_empty() && input.images.is_empty())
        {
            return Err(DshError::InvalidFrame);
        }
        crate::validate_images(&input.images, true, 4 * 1024 * 1024)
            .map_err(|_| DshError::InputLimit)
    }
    fn create(
        identity: I,
        cwd: String,
        input: UserInput,
        allow_silent: bool,
    ) -> Result<Self, DshError> {
        Self::validate_input(&cwd, &input)?;
        Ok(Self {
            identity,
            cwd,
            input: Some(input),
            state: DshState::New,
            session: None,
            image_capability: false,
            pending: None,
            next_id: 0,
            text: String::new(),
            allow_silent,
        })
    }
    pub fn state(&self) -> DshState {
        self.state
    }
    pub fn identity(&self) -> &I {
        &self.identity
    }
    pub fn session_id(&self) -> Option<&str> {
        self.session.as_deref()
    }
    fn done(&self) -> bool {
        matches!(
            self.state,
            DshState::Completed | DshState::Cancelled | DshState::Failed | DshState::Unknown
        )
    }
    fn request(&mut self, method: &'static str, params: Value) -> Value {
        self.next_id += 1;
        self.pending = Some((self.next_id, method));
        json!({"jsonrpc":"2.0","id":self.next_id,"method":method,"params":params})
    }
    pub fn initialize(&mut self) -> Result<Value, DshError> {
        if self.state != DshState::New {
            return Err(DshError::InvalidState);
        }
        self.state = DshState::Initializing;
        Ok(self.request(
            "initialize",
            json!({"protocolVersion":1,"clientCapabilities":{}}),
        ))
    }
    fn terminal(&mut self, state: DshState) -> Vec<DshEvent> {
        if self.done() {
            return vec![];
        }
        self.state = state;
        self.pending = None;
        self.input = None;
        let reply = if state == DshState::Completed {
            self.text.clone()
        } else {
            String::new()
        };
        vec![DshEvent::Terminal { state, reply }]
    }
    pub fn disconnected(&mut self) -> Vec<DshEvent> {
        self.terminal(DshState::Unknown)
    }
    pub fn cancel(&mut self) -> Vec<DshEvent> {
        if self.done() || self.state == DshState::Cancelling {
            return vec![];
        }
        if self.state == DshState::Prompting {
            self.state = DshState::Cancelling;
            vec![DshEvent::Send(
                json!({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":self.session}}),
            )]
        } else {
            self.terminal(DshState::Cancelled)
        }
    }
    pub fn receive(&mut self, frame: Value) -> Result<Vec<DshEvent>, DshError> {
        let result = self.receive_inner(frame);
        if result.is_err() && !self.done() {
            self.state = DshState::Failed;
            self.pending = None;
            self.input = None;
        }
        result
    }
    fn receive_inner(&mut self, frame: Value) -> Result<Vec<DshEvent>, DshError> {
        if self.done() {
            return Ok(vec![]);
        }
        if !frame.is_object()
            || serde_json::to_vec(&frame)
                .map_err(|_| DshError::InvalidFrame)?
                .len()
                > 1024 * 1024
        {
            return Err(DshError::InvalidFrame);
        }
        if let Some(method) = frame["method"].as_str() {
            if let Some(id) = frame.get("id") {
                if !(id.is_string() || id.as_i64().is_some() || id.as_u64().is_some()) {
                    return Err(DshError::InvalidFrame);
                }
                // Every permission/server request is denied. This cannot dispatch tools.
                let reject = frame["params"]["options"]
                    .as_array()
                    .and_then(|v| {
                        v.iter()
                            .find(|v| v["kind"].as_str().is_some_and(|k| k.starts_with("reject")))
                    })
                    .and_then(|v| v["optionId"].as_str());
                let outcome = reject
                    .map(|id| json!({"outcome":"selected","optionId":id}))
                    .unwrap_or(json!({"outcome":"cancelled"}));
                return Ok(vec![DshEvent::Send(
                    json!({"jsonrpc":"2.0","id":id,"result":{"outcome":outcome}}),
                )]);
            }
            if method == "session/update"
                && matches!(self.state, DshState::Prompting | DshState::Cancelling)
            {
                let p = &frame["params"];
                if p["sessionId"].as_str() != self.session.as_deref() {
                    return Ok(vec![]);
                }
                let update = &p["update"];
                if update["sessionUpdate"] != "agent_message_chunk"
                    || update["content"]["type"] != "text"
                    || self.state == DshState::Cancelling
                {
                    return Ok(vec![]);
                }
                let text = update["content"]["text"]
                    .as_str()
                    .ok_or(DshError::InvalidFrame)?;
                if self.text.len() + text.len() > 1024 * 1024 {
                    return Err(DshError::InputLimit);
                }
                self.text.push_str(text);
                return Ok(vec![DshEvent::TextDelta(text.into())]);
            }
            return Ok(vec![]);
        }
        let Some((id, method)) = self.pending else {
            return Ok(vec![]);
        };
        if frame["id"].as_u64() != Some(id) {
            return Ok(vec![]);
        }
        self.pending = None;
        if frame["error"].is_object() {
            return Ok(self.terminal(DshState::Failed));
        }
        let result = frame.get("result").ok_or(DshError::InvalidFrame)?;
        match method {
            "initialize" => {
                let cap = result["agentCapabilities"]["promptCapabilities"]
                    .as_object()
                    .ok_or(DshError::InvalidFrame)?;
                self.image_capability = cap.get("image").and_then(Value::as_bool).unwrap_or(false);
                self.state = DshState::Opening;
                Ok(vec![DshEvent::Send(self.request(
                    "session/new",
                    json!({"cwd":self.cwd,"mcpServers":[]}),
                ))])
            }
            "session/new" => {
                let session = result["sessionId"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 256)
                    .ok_or(DshError::InvalidFrame)?
                    .to_owned();
                self.session = Some(session.clone());
                let input = self.input.take().ok_or(DshError::InvalidState)?;
                if !input.images.is_empty() && !self.image_capability {
                    return Err(DshError::ImagesUnsupported);
                }
                let mut blocks=input.images.into_iter().map(|image|json!({"type":"image","data":base64::engine::general_purpose::STANDARD.encode(image.bytes),"mimeType":image.media_type})).collect::<Vec<_>>();
                if !input.text.is_empty() {
                    blocks.push(json!({"type":"text","text":input.text}));
                }
                self.state = DshState::Prompting;
                Ok(vec![
                    DshEvent::SessionReady {
                        session_id: session.clone(),
                        image_capability: self.image_capability,
                    },
                    DshEvent::Send(self.request(
                        "session/prompt",
                        json!({"sessionId":session,"prompt":blocks}),
                    )),
                ])
            }
            "session/prompt" => {
                let reason = result["stopReason"]
                    .as_str()
                    .ok_or(DshError::InvalidFrame)?;
                let state = if reason == "cancelled"
                    || (self.state == DshState::Cancelling && reason == "end_turn")
                {
                    DshState::Cancelled
                } else if reason == "end_turn"
                    && (!self.text.trim().is_empty() || self.allow_silent)
                {
                    DshState::Completed
                } else {
                    DshState::Failed
                };
                Ok(self.terminal(state))
            }
            _ => Err(DshError::InvalidFrame),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn session(images: bool) -> DshSession {
        DshSession::new(
            TurnIdentity {
                world_id: "world".into(),
                scope_id: "scope".into(),
                session_id: "host".into(),
                run_id: "run".into(),
            },
            "/private/workspace".into(),
            UserInput {
                text: "hello".into(),
                images: if images {
                    vec![crate::ImageInput {
                        bytes: b"\x89PNG\r\n\x1a\n".to_vec(),
                        media_type: "image/png".into(),
                    }]
                } else {
                    vec![]
                },
            },
            false,
        )
        .unwrap()
    }
    fn open(s: &mut DshSession, image_capability: bool) -> Vec<DshEvent> {
        assert_eq!(s.initialize().unwrap()["method"], "initialize");
        s.receive(json!({"jsonrpc":"2.0","id":1,"result":{"agentCapabilities":{"promptCapabilities":{"image":image_capability}}}})).unwrap();
        s.receive(json!({"jsonrpc":"2.0","id":2,"result":{"sessionId":"session"}}))
            .unwrap()
    }
    fn text(s: &mut DshSession, id: &str, value: &str) -> Vec<DshEvent> {
        s.receive(json!({"method":"session/update","params":{"sessionId":id,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":value}}}})).unwrap()
    }
    #[test]
    fn only_native_end_turn_delivers_text_and_late_text_is_ignored() {
        let mut s = session(false);
        open(&mut s, false);
        assert!(text(&mut s, "other", "foreign").is_empty());
        text(&mut s, "session", "hello");
        let events = s
            .receive(json!({"id":3,"result":{"stopReason":"end_turn"}}))
            .unwrap();
        assert!(
            matches!(&events[0],DshEvent::Terminal{state:DshState::Completed,reply}if reply=="hello")
        );
        assert!(text(&mut s, "session", "late").is_empty());
    }
    #[test]
    fn incomplete_or_missing_stop_is_never_success() {
        for reason in ["max_tokens", "tool_use", "cancelled"] {
            let mut s = session(false);
            open(&mut s, false);
            text(&mut s, "session", "partial");
            s.receive(json!({"id":3,"result":{"stopReason":reason}}))
                .unwrap();
            assert_ne!(s.state(), DshState::Completed);
        }
        let mut s = session(false);
        open(&mut s, false);
        assert!(s.receive(json!({"id":3,"result":{}})).is_err());
    }
    #[test]
    fn permission_asks_reject_and_text_json_never_becomes_a_tool() {
        let mut s = session(false);
        open(&mut s, false);
        let events=s.receive(json!({"id":"ask","method":"session/request_permission","params":{"options":[{"kind":"allow_once","optionId":"allow"},{"kind":"reject_once","optionId":"reject"}]}})).unwrap();
        assert!(
            matches!(&events[0],DshEvent::Send(frame)if frame["result"]["outcome"]["optionId"]=="reject")
        );
        assert!(matches!(
            &text(&mut s, "session", r#"{"tool":"write","arguments":{}}"#)[0],
            DshEvent::TextDelta(_)
        ));
    }
    #[test]
    fn real_image_blocks_require_advertised_capability() {
        let mut s = session(true);
        let events = open(&mut s, true);
        let frame = events
            .into_iter()
            .find_map(|e| match e {
                DshEvent::Send(f) => Some(f),
                _ => None,
            })
            .unwrap();
        assert_eq!(frame["params"]["prompt"][0]["type"], "image");
        assert_eq!(frame["params"]["prompt"][0]["mimeType"], "image/png");
        let mut s = session(true);
        s.initialize().unwrap();
        s.receive(
            json!({"id":1,"result":{"agentCapabilities":{"promptCapabilities":{"image":false}}}}),
        )
        .unwrap();
        assert_eq!(
            s.receive(json!({"id":2,"result":{"sessionId":"session"}}))
                .err(),
            Some(DshError::ImagesUnsupported)
        );
    }
    #[test]
    fn cancellation_needs_actual_terminal_and_disconnect_is_unknown() {
        let mut s = session(false);
        open(&mut s, false);
        assert!(matches!(&s.cancel()[0],DshEvent::Send(f)if f["method"]=="session/cancel"));
        assert_eq!(s.state(), DshState::Cancelling);
        assert!(s.cancel().is_empty());
        s.disconnected();
        assert_eq!(s.state(), DshState::Unknown);
        let mut s = session(false);
        open(&mut s, false);
        s.cancel();
        s.receive(json!({"id":3,"result":{"stopReason":"cancelled"}}))
            .unwrap();
        assert_eq!(s.state(), DshState::Cancelled);
    }
}
