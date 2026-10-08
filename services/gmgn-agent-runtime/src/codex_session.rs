//! Pure app-server protocol state. Owns no process, credentials, or model loop.
use crate::{ImageInput, TurnIdentity};
use base64::Engine;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SessionState {
    New,
    Initializing,
    Configuring,
    ThreadStarting,
    TurnStarting,
    Active,
    Interrupting,
    Completed,
    Failed,
    Unknown,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProtocolError {
    InvalidState,
    InvalidFrame,
    InvalidTools,
    UnsafeConfiguration,
    IdentityMismatch,
    DuplicateCall,
    BudgetExceeded,
    UnmatchedReceipt,
}
pub enum CodexEvent {
    Send(Value),
    TextDelta {
        item_id: String,
        text: String,
    },
    ToolRequest {
        identity: TurnIdentity,
        thread_id: String,
        turn_id: String,
        call_id: String,
        name: String,
        arguments: Value,
    },
    Terminal {
        state: SessionState,
        reply: String,
    },
}
/// Deliberately has no Debug: prompt, arguments, and receipts can contain private data.
pub struct CodexReceipt {
    pub identity: TurnIdentity,
    pub thread_id: String,
    pub turn_id: String,
    pub call_id: String,
    pub success: bool,
    pub output: Value,
    pub images: Vec<ImageInput>,
}
pub struct CodexSession {
    identity: TurnIdentity,
    state: SessionState,
    tools: Value,
    names: HashSet<String>,
    cwd: String,
    input: Value,
    resume: Option<String>,
    thread: Option<String>,
    turn: Option<String>,
    next_id: u64,
    pending: Option<(u64, &'static str)>,
    calls: HashSet<String>,
    receipts: HashMap<String, Value>,
    finals: Vec<(String, String)>,
    text_bytes: usize,
    early_terminal: Option<Value>,
    allow_silent: bool,
    successful_tool: bool,
}
impl CodexSession {
    pub fn new(
        identity: TurnIdentity,
        cwd: String,
        input: Value,
        tools: Value,
        resume: Option<String>,
        allow_silent: bool,
    ) -> Result<Self, ProtocolError> {
        if [
            &identity.world_id,
            &identity.scope_id,
            &identity.session_id,
            &identity.run_id,
        ]
        .iter()
        .any(|v| v.is_empty())
            || cwd.is_empty()
            || !input.is_array()
        {
            return Err(ProtocolError::InvalidFrame);
        }
        let list = tools
            .as_array()
            .filter(|a| !a.is_empty())
            .ok_or(ProtocolError::InvalidTools)?;
        let mut names = HashSet::new();
        let mut registered = Vec::new();
        for tool in list {
            let name = tool["name"].as_str().ok_or(ProtocolError::InvalidTools)?;
            let valid = name.len() <= 64
                && !name.is_empty()
                && name.bytes().enumerate().all(|(i, b)| {
                    b == b'_' || b.is_ascii_alphabetic() || (i > 0 && b.is_ascii_digit())
                });
            if !valid
                || !names.insert(name.to_owned())
                || !tool["description"].is_string()
                || tool["inputSchema"]["type"] != "object"
            {
                return Err(ProtocolError::InvalidTools);
            }
            registered.push(json!({"type":"function","name":name,"description":tool["description"],"inputSchema":tool["inputSchema"]}));
        }
        let s = Self {
            identity,
            state: SessionState::New,
            tools: Value::Array(registered),
            names,
            cwd,
            input,
            resume: resume.filter(|s| !s.is_empty()),
            thread: None,
            turn: None,
            next_id: 0,
            pending: None,
            calls: HashSet::new(),
            receipts: HashMap::new(),
            finals: Vec::new(),
            text_bytes: 0,
            early_terminal: None,
            allow_silent,
            successful_tool: false,
        };
        if serde_json::to_vec(&s.input)
            .map_err(|_| ProtocolError::InvalidFrame)?
            .len()
            > 1_048_576
            || serde_json::to_vec(&s.tools)
                .map_err(|_| ProtocolError::InvalidTools)?
                .len()
                > 1_048_576
        {
            return Err(ProtocolError::BudgetExceeded);
        }
        Ok(s)
    }
    pub fn state(&self) -> SessionState {
        self.state
    }
    pub fn thread_id(&self) -> Option<&str> {
        self.thread.as_deref()
    }
    pub fn turn_id(&self) -> Option<&str> {
        self.turn.as_deref()
    }
    fn done(&self) -> bool {
        matches!(
            self.state,
            SessionState::Completed | SessionState::Failed | SessionState::Unknown
        )
    }
    fn request(&mut self, method: &'static str, params: Value) -> Value {
        self.next_id += 1;
        self.pending = Some((self.next_id, method));
        json!({"id":self.next_id,"method":method,"params":params})
    }
    pub fn initialize(&mut self) -> Result<Value, ProtocolError> {
        if self.state != SessionState::New {
            return Err(ProtocolError::InvalidState);
        }
        self.state = SessionState::Initializing;
        Ok(self.request("initialize", json!({"clientInfo":{"name":"gmgn_resident","version":"1"},"capabilities":{"experimentalApi":true}})))
    }
    fn terminal(&mut self, state: SessionState, reply: String) -> Vec<CodexEvent> {
        if self.done() {
            return vec![];
        }
        self.state = state;
        self.pending = None;
        self.receipts.clear();
        vec![CodexEvent::Terminal { state, reply }]
    }
    /// EOF/timeout/write failure is unknown, never a successful receipt or replay request.
    pub fn disconnected(&mut self) -> Vec<CodexEvent> {
        self.terminal(SessionState::Unknown, String::new())
    }
    pub fn interrupt(&mut self) -> Vec<CodexEvent> {
        if self.done() || self.state == SessionState::Interrupting {
            return vec![];
        }
        self.state = SessionState::Interrupting;
        match (&self.thread, &self.turn) {
            (Some(thread), Some(turn)) => vec![CodexEvent::Send(
                json!({"method":"turn/interrupt","params":{"threadId":thread,"turnId":turn}}),
            )],
            _ => self.disconnected(),
        }
    }
    pub fn receive(&mut self, frame: Value) -> Result<Vec<CodexEvent>, ProtocolError> {
        let result = self.receive_inner(frame);
        if result.is_err() {
            self.terminal(SessionState::Failed, String::new());
        }
        result
    }
    fn receive_inner(&mut self, frame: Value) -> Result<Vec<CodexEvent>, ProtocolError> {
        if self.done() {
            return Ok(vec![]);
        }
        if serde_json::to_vec(&frame)
            .map_err(|_| ProtocolError::InvalidFrame)?
            .len()
            > 1_048_576
        {
            return Err(ProtocolError::BudgetExceeded);
        }
        if !frame.is_object() {
            return Err(ProtocolError::InvalidFrame);
        }
        if let Some(method) = frame["method"].as_str() {
            let p = &frame["params"];
            if let Some(id) = frame.get("id") {
                if !(id.is_string() || id.as_i64().is_some() || id.as_u64().is_some()) {
                    return Err(ProtocolError::InvalidFrame);
                }
                if method != "item/tool/call" {
                    return Ok(vec![CodexEvent::Send(
                        json!({"id":id,"error":{"code":-32601,"message":"Resident tool unavailable"}}),
                    )]);
                }
                let reject = || {
                    vec![CodexEvent::Send(
                        json!({"id":id,"result":{"success":false,"contentItems":[{"type":"inputText","text":"Resident tool rejected"}]}}),
                    )]
                };
                if !matches!(
                    self.state,
                    SessionState::Active | SessionState::TurnStarting
                ) || !self.matches(p)
                    || !p["namespace"].is_null()
                {
                    return Ok(reject());
                }
                let call = p["callId"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 256);
                let name = p["tool"].as_str();
                let (Some(call), Some(name)) = (call, name) else {
                    return Ok(reject());
                };
                if !self.names.contains(name) || !p["arguments"].is_object() {
                    return Ok(reject());
                }
                if self.calls.contains(call) {
                    return Ok(reject());
                }
                if self.receipts.values().any(|pending| pending == id) {
                    return Ok(reject());
                }
                if self.calls.len() >= 128 {
                    return Err(ProtocolError::BudgetExceeded);
                }
                self.calls.insert(call.to_owned());
                self.receipts.insert(call.to_owned(), id.clone());
                return Ok(vec![CodexEvent::ToolRequest {
                    identity: self.identity.clone(),
                    thread_id: self.thread.clone().unwrap(),
                    turn_id: self.turn.clone().unwrap(),
                    call_id: call.to_owned(),
                    name: name.to_owned(),
                    arguments: p["arguments"].clone(),
                }]);
            }
            if p["threadId"].as_str() != self.thread.as_deref() || self.thread.is_none() {
                return Ok(vec![]);
            }
            if method == "turn/started" && self.state == SessionState::TurnStarting {
                let id = p["turn"]["id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or(ProtocolError::InvalidFrame)?;
                if self.turn.as_deref().is_some_and(|t| t != id) {
                    return Err(ProtocolError::IdentityMismatch);
                }
                self.turn = Some(id.into());
                return Ok(vec![]);
            }
            if !matches!(
                self.state,
                SessionState::TurnStarting | SessionState::Active | SessionState::Interrupting
            ) {
                return Ok(vec![]);
            }
            if method == "turn/completed" {
                if p["turn"]["id"].as_str() != self.turn.as_deref() || self.turn.is_none() {
                    return Ok(vec![]);
                }
                if self.state == SessionState::TurnStarting {
                    self.early_terminal = Some(p.clone());
                    return Ok(vec![]);
                }
                return Ok(self.finish_turn(p));
            }
            if !self.matches(p) {
                return Ok(vec![]);
            }
            if method == "error" {
                if p["willRetry"] == true {
                    return Ok(vec![]);
                }
                return Ok(self.terminal(SessionState::Failed, String::new()));
            }
            if method == "item/agentMessage/delta" && self.state != SessionState::Interrupting {
                let item = p["itemId"].as_str().ok_or(ProtocolError::InvalidFrame)?;
                let text = p["delta"].as_str().ok_or(ProtocolError::InvalidFrame)?;
                self.budget(text.len())?;
                return Ok(vec![CodexEvent::TextDelta {
                    item_id: item.into(),
                    text: text.into(),
                }]);
            }
            if method == "item/completed" {
                let item = &p["item"];
                if item["type"] != "agentMessage"
                    || !(item["phase"].is_null() || item["phase"] == "final_answer")
                {
                    return Ok(vec![]);
                }
                let id = item["id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or(ProtocolError::InvalidFrame)?;
                let text = item["text"].as_str().ok_or(ProtocolError::InvalidFrame)?;
                if !text.trim().is_empty() {
                    self.budget(text.len())?;
                    if let Some(old) = self.finals.iter_mut().find(|(i, _)| i == id) {
                        old.1 = text.into();
                    } else {
                        self.finals.push((id.into(), text.into()));
                    }
                }
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
        if frame.get("error").is_some() {
            return Ok(self.terminal(SessionState::Failed, String::new()));
        }
        let result = frame.get("result").ok_or(ProtocolError::InvalidFrame)?;
        match method {
            "initialize" => {
                self.state = SessionState::Configuring;
                let request = self.request("config/read", json!({"includeLayers":false}));
                Ok(vec![
                    CodexEvent::Send(json!({"method":"initialized","params":{}})),
                    CodexEvent::Send(request),
                ])
            }
            "config/read" => {
                verify_configuration(result)?;
                self.state = SessionState::ThreadStarting;
                let mut p = json!({"cwd":self.cwd,"approvalPolicy":"never","sandbox":"read-only","runtimeWorkspaceRoots":[]});
                let method = if let Some(resume) = &self.resume {
                    p["threadId"] = json!(resume);
                    "thread/resume"
                } else {
                    p["environments"] = json!([]);
                    p["dynamicTools"] = self.tools.clone();
                    p["selectedCapabilityRoots"] = json!([]);
                    "thread/start"
                };
                Ok(vec![CodexEvent::Send(self.request(method, p))])
            }
            "thread/start" | "thread/resume" => {
                let id = result["thread"]["id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or(ProtocolError::InvalidFrame)?;
                if self.resume.as_deref().is_some_and(|r| r != id) {
                    return Err(ProtocolError::IdentityMismatch);
                }
                self.thread = Some(id.into());
                self.state = SessionState::TurnStarting;
                Ok(vec![CodexEvent::Send(self.request("turn/start",json!({"threadId":id,"environments":[],"approvalPolicy":"never","cwd":self.cwd,"runtimeWorkspaceRoots":[],"input":self.input})))])
            }
            "turn/start" => {
                let id = result["turn"]["id"]
                    .as_str()
                    .filter(|s| !s.is_empty())
                    .ok_or(ProtocolError::InvalidFrame)?;
                if self.turn.as_deref().is_some_and(|t| t != id) {
                    self.terminal(SessionState::Failed, String::new());
                    return Err(ProtocolError::IdentityMismatch);
                }
                self.turn = Some(id.into());
                if self.state != SessionState::Interrupting {
                    self.state = SessionState::Active;
                }
                Ok(if let Some(p) = self.early_terminal.take() {
                    self.finish_turn(&p)
                } else {
                    vec![]
                })
            }
            _ => Err(ProtocolError::InvalidFrame),
        }
    }
    fn budget(&mut self, bytes: usize) -> Result<(), ProtocolError> {
        self.text_bytes = self
            .text_bytes
            .checked_add(bytes)
            .ok_or(ProtocolError::BudgetExceeded)?;
        if self.text_bytes > 1_048_576 {
            return Err(ProtocolError::BudgetExceeded);
        }
        Ok(())
    }
    fn matches(&self, p: &Value) -> bool {
        self.thread.is_some()
            && self.turn.is_some()
            && p["threadId"].as_str() == self.thread.as_deref()
            && p["turnId"].as_str() == self.turn.as_deref()
    }
    fn finish_turn(&mut self, p: &Value) -> Vec<CodexEvent> {
        let reply = self
            .finals
            .iter()
            .map(|(_, t)| t.as_str())
            .collect::<Vec<_>>()
            .join("\n\n");
        if self.state == SessionState::Interrupting {
            return self.terminal(SessionState::Failed, String::new());
        }
        if p["turn"]["status"] != "completed"
            || !self.receipts.is_empty()
            || (reply.is_empty() && !(self.allow_silent && self.successful_tool))
        {
            return self.terminal(SessionState::Failed, String::new());
        }
        self.terminal(SessionState::Completed, reply)
    }
    pub fn tool_receipt(&mut self, r: CodexReceipt) -> Result<Value, ProtocolError> {
        if !matches!(
            self.state,
            SessionState::Active | SessionState::TurnStarting
        ) || r.identity != self.identity
            || Some(r.thread_id.as_str()) != self.thread.as_deref()
            || Some(r.turn_id.as_str()) != self.turn.as_deref()
        {
            return Err(ProtocolError::IdentityMismatch);
        }
        let id = self
            .receipts
            .get(&r.call_id)
            .ok_or(ProtocolError::UnmatchedReceipt)?;
        let text = serde_json::to_string(&r.output).map_err(|_| ProtocolError::InvalidFrame)?;
        if text.len() > 512 * 1024 {
            return Err(ProtocolError::BudgetExceeded);
        }
        crate::validate_images(&r.images, true, 4 * 1024 * 1024).map_err(|code| {
            if code == "image_byte_limit" || code == "image_count_limit" {
                ProtocolError::BudgetExceeded
            } else {
                ProtocolError::InvalidFrame
            }
        })?;
        let mut content = vec![json!({"type":"inputText","text":text})];
        for image in r.images {
            let encoded = base64::engine::general_purpose::STANDARD.encode(image.bytes);
            content.push(json!({"type":"inputImage","imageUrl":format!("data:{};base64,{}", image.media_type, encoded)}));
        }
        let frame = json!({"id":id,"result":{"success":r.success,"contentItems":content}});
        self.receipts.remove(&r.call_id);
        self.successful_tool |= r.success;
        Ok(frame)
    }
}
/// Verify the effective configuration, not requested flags. Never retains raw config.
pub fn verify_configuration(response: &Value) -> Result<(), ProtocolError> {
    let c = response
        .get("config")
        .filter(|c| c.is_object())
        .ok_or(ProtocolError::InvalidFrame)?;
    for key in [
        "plugins",
        "apps",
        "hooks",
        "multi_agent",
        "multi_agent_v2",
        "image_generation",
        "shell_tool",
    ] {
        if c["features"][key] != false {
            return Err(ProtocolError::UnsafeConfiguration);
        }
    }
    if c["agents"]["enabled"] != false
        || c["notify"].as_array().is_none_or(|a| !a.is_empty())
        || c["web_search"]
            .as_str()
            .is_none_or(|s| s.is_empty() || s == "disabled")
        || c["cli_auth_credentials_store"] != "file"
        || c["mcp_oauth_credentials_store"] != "file"
    {
        return Err(ProtocolError::UnsafeConfiguration);
    }
    if let Some(servers) = c.get("mcp_servers") {
        let servers = servers
            .as_object()
            .ok_or(ProtocolError::UnsafeConfiguration)?;
        if servers.values().any(|s| s["enabled"] != false) {
            return Err(ProtocolError::UnsafeConfiguration);
        }
    }
    Ok(())
}
