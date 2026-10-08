//! GMGN host adapter for the pinned rutis-agent loop. No independent model loop.
pub use aimux_core::tool::ToolCall;
use aimux_core::LanguageModel;
use rutis::{BoxFuture, CordisError, Ctx, EventKey, Listener, Next, WaterfallListener};
pub use rutis_agent::ToolExecutionContext;
pub use tokio_util::sync::CancellationToken;
pub mod provider;
pub mod cli_transport;
mod owned_process;
pub mod oneshot_transport;
pub mod codex_session;
pub mod claude_session;
pub mod chat_cli;
pub mod chat_dsh;
pub mod dsh_session;
use rutis_agent::{
    agent_key, llm_key, Agent, AgentDriverPlugin, AgentError, AgentTextDelta, SessionSnapshot,
    ToolDef, ToolPreExecute, ToolsPlugin,
};
use std::{
    collections::HashSet,
    sync::{Arc, Mutex},
};
use tokio::sync::{broadcast, Mutex as AsyncMutex};

pub use rutis_agent::SteeringDelivery;
pub use rutis_agent::{LlmResponse, ScriptedLlm};

/// Supplied only by the trusted host, never parsed from model arguments.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnIdentity {
    pub world_id: String,
    pub scope_id: String,
    pub session_id: String,
    pub run_id: String,
}
pub struct HostToolContext {
    pub identity: TurnIdentity,
    pub execution: ToolExecutionContext,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostToolStatus {
    Completed,
    Rejected,
    Unknown,
}
pub struct HostToolReceipt {
    pub identity: TurnIdentity,
    pub call_id: String,
    pub status: HostToolStatus,
    pub output: serde_json::Value,
    pub images: Vec<ImageInput>,
}
#[derive(Clone)]
pub struct ImageInput {
    pub bytes: Vec<u8>,
    pub media_type: String,
}
impl std::fmt::Debug for ImageInput {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ImageInput")
            .field("media_type", &self.media_type)
            .field("byte_length", &self.bytes.len())
            .finish()
    }
}
pub struct UserInput {
    pub text: String,
    pub images: Vec<ImageInput>,
}
fn validate_images(images: &[ImageInput], supported: bool, limit: usize) -> Result<(), String> {
    if images.is_empty() {
        return Ok(());
    }
    if !supported {
        return Err("model_image_input_unsupported".into());
    }
    if images.len() > 4 {
        return Err("image_count_limit".into());
    }
    let mut total = 0usize;
    for image in images {
        total = total
            .checked_add(image.bytes.len())
            .ok_or("image_byte_limit")?;
        if total > limit || image.bytes.is_empty() {
            return Err("image_byte_limit".into());
        }
        let valid = match image.media_type.as_str() {
            "image/png" => image.bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            "image/jpeg" => image.bytes.starts_with(b"\xff\xd8\xff"),
            "image/gif" => image.bytes.starts_with(b"GIF87a") || image.bytes.starts_with(b"GIF89a"),
            "image/webp" => {
                image.bytes.starts_with(b"RIFF") && image.bytes.get(8..12) == Some(b"WEBP")
            }
            _ => false,
        };
        if !valid {
            return Err("image_format_invalid".into());
        }
    }
    Ok(())
}
pub trait HostToolExecutor: Send + Sync + 'static {
    fn execute(
        &self,
        context: HostToolContext,
    ) -> BoxFuture<'static, Result<HostToolReceipt, String>>;
}
pub struct HostToolSchema {
    pub name: String,
    pub description: String,
    pub parameters: serde_json::Value,
}
struct HostTurnState {
    active: Option<TurnIdentity>,
    used_runs: HashSet<String>,
    failure: Option<String>,
    image_bytes: usize,
    image_count: usize,
}
struct HostExecutionGuard {
    state: Arc<Mutex<HostTurnState>>,
    identity: TurnIdentity,
    execution: ToolExecutionContext,
    completed: bool,
}
impl Drop for HostExecutionGuard {
    fn drop(&mut self) {
        if self.completed {
            return;
        }
        let mut state = self.state.lock().unwrap();
        if state.active.as_ref() == Some(&self.identity) && state.failure.is_none() {
            state.failure = Some("host_tool_result_unknown".into());
        }
        self.execution.cancellation.cancel();
    }
}

pub struct RuntimeConfig {
    pub system_prompt: String,
    pub allowed_tools: HashSet<String>,
    pub max_steps: usize,
    pub max_tool_calls: usize,
    pub token_budget: u64,
    pub supports_images: bool,
    pub max_image_bytes: usize,
}
impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            system_prompt: String::new(),
            allowed_tools: HashSet::new(),
            max_steps: 16,
            max_tool_calls: 32,
            token_budget: 32_000,
            supports_images: false,
            max_image_bytes: 4 * 1024 * 1024,
        }
    }
}
struct GateState {
    seen: HashSet<String>,
    calls_this_turn: usize,
}
struct AuthorizationGate {
    allowed: HashSet<String>,
    max_calls: usize,
    state: Arc<Mutex<GateState>>,
}
impl WaterfallListener<ToolPreExecute> for AuthorizationGate {
    fn call<'a>(
        &'a self,
        _: &'a Ctx,
        event: &'a ToolPreExecute,
        next: Next<'a, ToolPreExecute>,
    ) -> BoxFuture<'a, Result<Option<String>, CordisError>> {
        Box::pin(async move {
            let rejection = {
                let mut state = self.state.lock().unwrap();
                if !self.allowed.contains(&event.call.tool_name) {
                    Some("gmgn_tool_not_authorized")
                } else if event.call.tool_call_id.is_empty()
                    || state.seen.contains(&event.call.tool_call_id)
                {
                    Some("gmgn_duplicate_or_empty_call_id")
                } else if state.calls_this_turn >= self.max_calls {
                    Some("gmgn_tool_budget_exceeded")
                } else {
                    state.seen.insert(event.call.tool_call_id.clone());
                    state.calls_this_turn += 1;
                    None
                }
            };
            if let Some(reason) = rejection {
                return Ok(Some(reason.into()));
            }
            next.call().await
        })
    }
}
struct TextEvents(broadcast::Sender<String>);
impl Listener<AgentTextDelta> for TextEvents {
    fn call<'a>(
        &'a self,
        _: &'a Ctx,
        event: &'a AgentTextDelta,
    ) -> BoxFuture<'a, Result<Option<()>, CordisError>> {
        Box::pin(async move {
            let _ = self.0.send(event.delta.clone());
            Ok(None)
        })
    }
}

/// Session-owning runtime. Caller supplies a LanguageModel and GMGN tool
/// definitions; bash/replace_text/minimal_tools are never registered here.
pub struct RutisRuntime {
    root: Ctx,
    agent: Arc<dyn Agent>,
    text: broadcast::Sender<String>,
    gate: Arc<Mutex<GateState>>,
    turn: AsyncMutex<()>,
    host: Option<Arc<Mutex<HostTurnState>>>,
    supports_images: bool,
    max_image_bytes: usize,
}
impl RutisRuntime {
    pub async fn new(
        model: Arc<dyn LanguageModel>,
        tools: Vec<ToolDef>,
        config: RuntimeConfig,
    ) -> Result<Self, String> {
        if config.max_steps == 0
            || config.max_tool_calls == 0
            || config.token_budget == 0
            || config.max_image_bytes == 0
        {
            return Err("invalid_runtime_budget".into());
        }
        let mut definitions = HashSet::new();
        for tool in &tools {
            if !tool.is_contextual()
                || tool.name().is_empty()
                || !definitions.insert(tool.name().to_owned())
                || !config.allowed_tools.contains(tool.name())
            {
                return Err("invalid_or_unauthorized_tool_definition".into());
            }
        }
        if definitions != config.allowed_tools {
            return Err("missing_authorized_tool_definition".into());
        }
        let root = Ctx::root().map_err(|_| "rutis_root_failed")?;
        let gate = Arc::new(Mutex::new(GateState {
            seen: HashSet::new(),
            calls_this_turn: 0,
        }));
        let (text, _) = broadcast::channel(256);
        root.events()
            .on_waterfall(
                &root,
                &EventKey::of(),
                AuthorizationGate {
                    allowed: config.allowed_tools,
                    max_calls: config.max_tool_calls,
                    state: gate.clone(),
                },
            )
            .map_err(|_| "rutis_gate_failed")?;
        root.events()
            .on(&root, &EventKey::of(), TextEvents(text.clone()))
            .map_err(|_| "rutis_observer_failed")?;
        root.provide_as(llm_key(), model)
            .map_err(|_| "rutis_model_registration_failed")?;
        let tools_view = root.plugin(ToolsPlugin::new(tools));
        if (&tools_view).await.is_err() {
            let _ = root.shutdown().await;
            return Err("rutis_tools_load_failed".into());
        }
        let driver = root.plugin(
            AgentDriverPlugin::new(config.max_steps)
                .with_token_budget(config.token_budget)
                .with_system_prompt(config.system_prompt),
        );
        if (&driver).await.is_err() {
            let _ = root.shutdown().await;
            return Err("rutis_driver_load_failed".into());
        }
        let agent = root
            .get_as::<dyn Agent>(agent_key())
            .ok_or("rutis_agent_unavailable")?;
        Ok(Self {
            root,
            agent,
            text,
            gate,
            turn: AsyncMutex::new(()),
            host: None,
            supports_images: config.supports_images,
            max_image_bytes: config.max_image_bytes,
        })
    }
    pub async fn new_host(
        model: Arc<dyn LanguageModel>,
        schemas: Vec<HostToolSchema>,
        executor: Arc<dyn HostToolExecutor>,
        config: RuntimeConfig,
    ) -> Result<Self, String> {
        let host = Arc::new(Mutex::new(HostTurnState {
            active: None,
            used_runs: HashSet::new(),
            failure: None,
            image_bytes: 0,
            image_count: 0,
        }));
        let mut tools = Vec::new();
        let supports_images = config.supports_images;
        let image_limit = config.max_image_bytes;
        for schema in schemas {
            let state = host.clone();
            let executor = executor.clone();
            tools.push(ToolDef::new_contextual_output(
                &schema.name,
                &schema.description,
                schema.parameters,
                move |execution| {
                    let state = state.clone();
                    let executor = executor.clone();
                    async move {
                        let identity = {
                            let guard = state.lock().unwrap();
                            if guard.failure.is_some() {
                                return Err("host_turn_failed".into());
                            }
                            guard.active.clone().ok_or("missing_host_turn_identity")?
                        };
                        let call_id = execution.call.tool_call_id.clone();
                        let cancellation = execution.cancellation.clone();
                        let mut attempt = HostExecutionGuard {
                            state: state.clone(),
                            identity: identity.clone(),
                            execution: execution.clone(),
                            completed: false,
                        };
                        let receipt = executor
                            .execute(HostToolContext {
                                identity: identity.clone(),
                                execution,
                            })
                            .await;
                        let mut guard = state.lock().unwrap();
                        let failure = if cancellation.is_cancelled() {
                            Some("host_tool_cancelled")
                        } else if guard.active.as_ref() != Some(&identity) {
                            Some("host_turn_identity_changed")
                        } else {
                            match &receipt {
                                Err(_) => Some("host_tool_result_unknown"),
                                Ok(receipt)
                                    if receipt.identity != identity
                                        || receipt.call_id != call_id =>
                                {
                                    Some("host_tool_receipt_identity_mismatch")
                                }
                                Ok(receipt) if receipt.status != HostToolStatus::Completed => {
                                    Some("host_tool_not_completed")
                                }
                                Ok(receipt)
                                    if guard.image_count.saturating_add(receipt.images.len())
                                        > 4
                                        || validate_images(
                                            &receipt.images,
                                            supports_images,
                                            image_limit.saturating_sub(guard.image_bytes),
                                        )
                                        .is_err() =>
                                {
                                    Some("host_tool_image_invalid_or_unsupported")
                                }
                                _ => None,
                            }
                        };
                        if let Some(reason) = failure {
                            guard.failure = Some(reason.into());
                            cancellation.cancel();
                            attempt.completed = true;
                            return Err(reason.into());
                        }
                        attempt.completed = true;
                        let receipt = receipt.unwrap();
                        guard.image_bytes += receipt
                            .images
                            .iter()
                            .map(|image| image.bytes.len())
                            .sum::<usize>();
                        guard.image_count += receipt.images.len();
                        Ok(rutis_agent::ToolOutput {
                            ok: true,
                            output: receipt.output.to_string(),
                            images: receipt
                                .images
                                .into_iter()
                                .map(|image| rutis_agent::ToolImage {
                                    bytes: image.bytes,
                                    media_type: image.media_type,
                                })
                                .collect(),
                        })
                    }
                },
            ));
        }
        let mut runtime = Self::new(model, tools, config).await?;
        runtime.host = Some(host);
        Ok(runtime)
    }
    pub fn subscribe_text(&self) -> broadcast::Receiver<String> {
        self.text.subscribe()
    }
    pub fn validate_user_input(&self, input: &UserInput) -> Result<(), String> {
        if input.text.len() > 65536 || (input.text.trim().is_empty() && input.images.is_empty()) {
            return Err("invalid_user_input".into());
        }
        validate_images(&input.images, self.supports_images, self.max_image_bytes)
    }
    pub async fn followup(&self, input: &str) -> Result<String, AgentError> {
        if self.host.is_some() {
            return Err(AgentError::Pipeline("missing_host_turn_identity".into()));
        }
        let _turn = self.turn.lock().await;
        self.gate.lock().unwrap().calls_this_turn = 0;
        self.agent.followup(input).await
    }
    pub async fn followup_with_identity(
        &self,
        input: &str,
        identity: TurnIdentity,
    ) -> Result<String, AgentError> {
        self.followup_input_with_identity(
            UserInput {
                text: input.into(),
                images: vec![],
            },
            identity,
        )
        .await
    }
    pub async fn followup_input_with_identity(
        &self,
        input: UserInput,
        identity: TurnIdentity,
    ) -> Result<String, AgentError> {
        self.validate_user_input(&input)
            .map_err(AgentError::Pipeline)?;
        let image_bytes = input.images.iter().map(|image| image.bytes.len()).sum();
        let image_count = input.images.len();
        let mut parts = vec![aimux_core::content::ContentPart::text(input.text)];
        parts.extend(input.images.into_iter().map(|image| {
            aimux_core::content::ContentPart::Image {
                image: image.bytes,
                media_type: image.media_type,
                provider_options: None,
            }
        }));
        let _turn = self.turn.lock().await;
        let host = self
            .host
            .as_ref()
            .ok_or_else(|| AgentError::Pipeline("host_executor_not_configured".into()))?;
        if [
            &identity.world_id,
            &identity.scope_id,
            &identity.session_id,
            &identity.run_id,
        ]
        .iter()
        .any(|id| id.is_empty())
        {
            return Err(AgentError::Pipeline("invalid_host_turn_identity".into()));
        }
        {
            let mut guard = host.lock().unwrap();
            if !guard.used_runs.insert(identity.run_id.clone()) {
                return Err(AgentError::Pipeline("duplicate_host_run_id".into()));
            }
            guard.active = Some(identity);
            guard.failure = None;
            guard.image_bytes = image_bytes;
            guard.image_count = image_count;
        }
        self.gate.lock().unwrap().calls_this_turn = 0;
        let result = self.agent.followup_parts(parts).await;
        let mut guard = host.lock().unwrap();
        guard.active = None;
        match guard.failure.take() {
            Some(reason) => Err(AgentError::Pipeline(reason)),
            None => result,
        }
    }
    pub fn cancel(&self) {
        self.agent.cancel();
    }
    /// Guidance for the exact currently active host turn. Never starts a turn
    /// or changes its ledger grants; changed operations still need host grants.
    pub fn steer(&self, expected: &TurnIdentity, text: String) -> SteeringDelivery {
        let Some(host) = &self.host else {
            return SteeringDelivery::NotDelivered;
        };
        let guard = host.lock().unwrap();
        if guard.active.as_ref() != Some(expected) || guard.failure.is_some() {
            return SteeringDelivery::NotDelivered;
        }
        self.agent.steer(text)
    }
    pub fn session(&self) -> SessionSnapshot {
        self.agent.session()
    }
    pub async fn shutdown(&self) -> Result<(), String> {
        self.cancel();
        self.root
            .shutdown()
            .await
            .map_err(|_| "rutis_shutdown_failed".into())
    }
}
