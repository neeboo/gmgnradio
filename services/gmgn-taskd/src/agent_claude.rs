//! Native one-shot Claude service; the CLI owns its MCP/model loop.
use crate::{
    agent_runtime_tools::{BusinessOperationResolver, HostToolTransport, LedgerHostTools},
    agent_scheduler, files,
    store::Database,
};
use base64::Engine;
use gmgn_agent_runtime::{
    claude_session::{self, ClaudeGrant, ClaudeHistory, ClaudePolicy, GrantIdentity, PinnedGrant},
    oneshot_transport::{self, OneshotConfig},
    CancellationToken, HostToolContext, HostToolExecutor, HostToolReceipt, HostToolStatus,
    ImageInput, ToolCall, ToolExecutionContext, TurnIdentity,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    future::Future,
    path::PathBuf,
    pin::Pin,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::sync::{oneshot, Mutex};
type Result<T> = std::result::Result<T, &'static str>;
type ToolFuture<T> = Pin<Box<dyn Future<Output = std::result::Result<T, String>> + Send + 'static>>;
fn text(p: &Value, key: &str) -> Result<String> {
    p[key]
        .as_str()
        .filter(|v| !v.is_empty() && v.len() <= 256)
        .map(str::to_owned)
        .ok_or("agent_claude_invalid_request")
}
fn identity(p: &Value) -> Result<TurnIdentity> {
    Ok(TurnIdentity {
        world_id: text(p, "worldID")?,
        scope_id: text(p, "residentScope")?,
        session_id: text(p, "hostSessionID")?,
        run_id: text(p, "runID")?,
    })
}
fn params(i: &TurnIdentity) -> Value {
    json!({"worldID":i.world_id,"residentScope":i.scope_id,"hostSessionID":i.session_id,"runID":i.run_id})
}
fn now() -> Result<u64> {
    u64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| "agent_claude_clock_unavailable")?
            .as_millis(),
    )
    .map_err(|_| "agent_claude_clock_unavailable")
}
fn image_blocks(p: &Value) -> Result<Vec<ImageInput>> {
    let Some(raw) = p.get("images") else {
        return Ok(vec![]);
    };
    let raw = raw
        .as_array()
        .filter(|a| a.len() <= 4)
        .ok_or("agent_claude_image_limit")?;
    let mut images = vec![];
    let mut bytes = 0usize;
    for v in raw {
        let media = text(v, "mediaType")?;
        let encoded = v["base64"]
            .as_str()
            .filter(|v| v.len() <= 1_048_576)
            .ok_or("agent_claude_image_limit")?;
        let data = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| "agent_claude_invalid_image")?;
        bytes = bytes
            .checked_add(data.len())
            .ok_or("agent_claude_image_limit")?;
        if bytes > 786_432 {
            return Err("agent_claude_image_limit");
        }
        images.push(ImageInput {
            bytes: data,
            media_type: media,
        });
    }
    claude_session::mcp_tool_result(&Value::Null, &images, true)
        .map_err(|_| "agent_claude_invalid_image")?;
    Ok(images)
}
struct Configuration {
    executable: PathBuf,
    adapter: PathBuf,
    environment: BTreeMap<String, String>,
    input: String,
    user: Option<String>,
    memory: Option<String>,
    tools: Value,
    catalog: Value,
    names: HashMap<String, String>,
    endpoint: String,
    silent: bool,
}
impl Configuration {
    fn parse(p: &Value) -> Result<Self> {
        let executable = PathBuf::from(
            p["executable"]
                .as_str()
                .ok_or("agent_claude_invalid_configuration")?,
        );
        let adapter = PathBuf::from(
            p["adapterExecutable"]
                .as_str()
                .ok_or("agent_claude_invalid_configuration")?,
        );
        if !executable.is_absolute()
            || !adapter.is_absolute()
            || p.get("arguments").is_some()
            || p.get("mcpConfig").is_some()
        {
            return Err("agent_claude_unsafe_configuration");
        }
        let endpoint = text(p, "hostEndpoint")?;
        let address = endpoint
            .strip_prefix("http://127.0.0.1:")
            .and_then(|s| s.strip_suffix("/rpc"))
            .and_then(|s| s.parse::<u16>().ok())
            .filter(|p| *p > 0)
            .ok_or("agent_claude_invalid_configuration")?;
        if endpoint != format!("http://127.0.0.1:{address}/rpc") {
            return Err("agent_claude_invalid_configuration");
        }
        let environment = p["environment"]
            .as_object()
            .ok_or("agent_claude_invalid_configuration")?
            .iter()
            .map(|(k, v)| {
                Ok((
                    k.clone(),
                    v.as_str()
                        .ok_or("agent_claude_invalid_configuration")?
                        .to_owned(),
                ))
            })
            .collect::<Result<BTreeMap<_, _>>>()?;
        // Only supplied memory values; no ambient key, config or login discovery.
        claude_session::environment(&environment, "/private/placeholder")
            .map_err(|_| "agent_claude_missing_credential")?;
        let input = p["input"]
            .as_str()
            .filter(|s| !s.trim().is_empty() && s.len() <= 1_048_576)
            .ok_or("agent_claude_invalid_input")?
            .to_owned();
        let user = p
            .get("durableUserText")
            .and_then(Value::as_str)
            .map(str::to_owned);
        let memory = p
            .get("memoryContext")
            .and_then(Value::as_str)
            .map(str::to_owned);
        if user.as_ref().is_some_and(|s| s.len() > 65536)
            || memory.as_ref().is_some_and(|s| s.len() > 262144)
        {
            return Err("agent_claude_input_limit");
        }
        if p.get("images").is_some() {
            return Err("agent_claude_unsupported_input");
        }
        let tools = p["tools"]
            .as_array()
            .filter(|a| a.len() <= 64)
            .ok_or("agent_claude_invalid_tools")?;
        let mut catalog = vec![];
        let mut names = HashMap::new();
        for t in tools {
            let canonical = text(t, "name")?;
            let name = format!("gmgn_{canonical}");
            if canonical.starts_with("gmgn_")
                || names.insert(name.clone(), canonical.clone()).is_some()
            {
                return Err("agent_claude_invalid_tools");
            }
            catalog.push(json!({"name":name,"canonical":canonical,"description":t["description"],"inputSchema":t["inputSchema"]}));
        }
        let catalog = json!(catalog);
        ClaudePolicy::new(catalog.clone()).map_err(|_| "agent_claude_invalid_tools")?;
        Ok(Self {
            executable,
            adapter,
            environment,
            input,
            user,
            memory,
            tools: json!(tools),
            catalog,
            names,
            endpoint,
            silent: p["allowSilentCompletion"].as_bool().unwrap_or(false),
        })
    }
}
struct PendingApproval {
    request: Value,
    tx: oneshot::Sender<std::result::Result<String, String>>,
}
struct PendingExecution {
    request: Value,
    tx: oneshot::Sender<HostToolReceipt>,
}
struct Queue {
    event: String,
    round: String,
    approval: Mutex<HashMap<String, PendingApproval>>,
    execution: Mutex<HashMap<String, PendingExecution>>,
    approved: Mutex<HashMap<String, Value>>,
    completed: Mutex<HashMap<String, Value>>,
}
struct QueueCleanup {
    queue: Arc<Queue>,
    call: String,
    approval: bool,
}
impl Drop for QueueCleanup {
    fn drop(&mut self) {
        let q = self.queue.clone();
        let call = self.call.clone();
        let approval = self.approval;
        if let Ok(h) = tokio::runtime::Handle::try_current() {
            h.spawn(async move {
                if approval {
                    q.approval.lock().await.remove(&call);
                } else {
                    q.execution.lock().await.remove(&call);
                }
            });
        }
    }
}
fn proposal(q: &Queue, c: &HostToolContext, phase: &str) -> Value {
    let mut p = params(&c.identity);
    p["eventID"] = json!(q.event);
    p["round"] = json!(q.round);
    p["callID"] = json!(c.execution.call.tool_call_id);
    p["toolName"] = json!(c.execution.call.tool_name);
    p["arguments"] = c.execution.call.input.clone();
    p["phase"] = json!(phase);
    p
}
struct Broker(Arc<Queue>);
impl BusinessOperationResolver for Broker {
    fn resolve(&self, _: &TurnIdentity, _: &str, _: &Value) -> std::result::Result<String, String> {
        Err("host_authorization_required".into())
    }
    fn resolve_context(&self, c: HostToolContext) -> ToolFuture<String> {
        let q = self.0.clone();
        Box::pin(async move {
            let call = c.execution.call.tool_call_id.clone();
            let request = proposal(&q, &c, "authorize");
            let (tx, rx) = oneshot::channel();
            {
                let mut pending = q.approval.lock().await;
                if pending.len() >= 4 || pending.contains_key(&call) {
                    return Err("host_queue_limit".into());
                }
                pending.insert(call.clone(), PendingApproval { request, tx });
            }
            let _cleanup = QueueCleanup {
                queue: q,
                call,
                approval: true,
            };
            tokio::select! {biased;_=c.execution.cancellation.cancelled()=>Err("host_authorization_cancelled".into()),r=tokio::time::timeout(Duration::from_secs(120),rx)=>match r{Ok(Ok(v))=>v,_=>Err("host_authorization_unavailable".into())}}
        })
    }
}
impl HostToolTransport for Broker {
    fn dispatch(&self, c: HostToolContext, operation: String) -> ToolFuture<HostToolReceipt> {
        let q = self.0.clone();
        Box::pin(async move {
            let call = c.execution.call.tool_call_id.clone();
            let mut request = proposal(&q, &c, "execute");
            request["operationID"] = json!(operation);
            let (tx, rx) = oneshot::channel();
            {
                let mut pending = q.execution.lock().await;
                if pending.len() >= 4 || pending.contains_key(&call) {
                    return Err("host_queue_limit".into());
                }
                pending.insert(call.clone(), PendingExecution { request, tx });
            }
            let _cleanup = QueueCleanup {
                queue: q,
                call,
                approval: false,
            };
            tokio::select! {biased;_=c.execution.cancellation.cancelled()=>Err("host_tool_unknown".into()),r=tokio::time::timeout(Duration::from_secs(120),rx)=>match r{Ok(Ok(v))=>Ok(v),_=>Err("host_tool_unknown".into())}}
        })
    }
}
struct PrivateFiles {
    directory: PathBuf,
    grant: PathBuf,
}
impl Drop for PrivateFiles {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.grant);
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
struct Session {
    identity: TurnIdentity,
    event: String,
    grant: Mutex<ClaudeGrant>,
    pin: PinnedGrant,
    files: PrivateFiles,
    policy: ClaudePolicy,
    names: HashMap<String, String>,
    queue: Arc<Queue>,
    executor: Arc<LedgerHostTools>,
    state: Mutex<String>,
    reply: Mutex<String>,
    cancel: CancellationToken,
    user_cancelled: AtomicBool,
    active: AtomicUsize,
    success: AtomicUsize,
    calls: Mutex<HashSet<String>>,
    secrets: Vec<String>,
}
pub struct ClaudeService {
    db: Database,
    session: Mutex<Option<Arc<Session>>>,
    history: Arc<Mutex<ClaudeHistory>>,
}
impl ClaudeService {
    pub fn new(db: Database) -> Self {
        Self {
            db,
            session: Mutex::new(None),
            history: Arc::new(Mutex::new(ClaudeHistory::default())),
        }
    }
    async fn claimed(&self, i: &TurnIdentity, event: &str) -> Result<()> {
        let p = params(i);
        let event = event.to_owned();
        self.db
            .call(move |store| {
                let state = agent_scheduler::request(&mut store.connection, "agent_loop_read", &p)?;
                if state["config"]["hostSessionID"] != p["hostSessionID"] {
                    return Err("agent_claude_stale_session");
                }
                if !state["events"].as_array().is_some_and(|v| {
                    v.iter().any(|e| {
                        e["eventID"] == event
                            && e["runID"] == p["runID"]
                            && e["hostSessionID"] == p["hostSessionID"]
                            && e["state"] == "claimed"
                    })
                }) {
                    return Err("agent_claude_run_not_claimed");
                }
                Ok(())
            })
            .await
    }
    async fn current(&self, p: &Value) -> Result<Arc<Session>> {
        let i = identity(p)?;
        let s = self
            .session
            .lock()
            .await
            .clone()
            .ok_or("agent_claude_not_started")?;
        if i != s.identity || p["eventID"] != s.event {
            return Err("agent_claude_stale_session");
        }
        let binding = params(&i);
        self.db
            .call(move |store| {
                let state =
                    agent_scheduler::request(&mut store.connection, "agent_loop_read", &binding)?;
                if state["config"]["hostSessionID"] != binding["hostSessionID"] {
                    return Err("agent_claude_stale_session");
                }
                Ok(())
            })
            .await?;
        Ok(s)
    }
    pub async fn request(&self, method: &str, p: &Value) -> Result<Value> {
        match method {
            "agent_claude_start" => {
                let i = identity(p)?;
                let event = text(p, "eventID")?;
                self.claimed(&i, &event).await?;
                let ip = params(&i);
                let unresolved=self.db.call(move|store|store.connection.query_row("SELECT count(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND state IN ('inflight','unknown')",rusqlite::params![ip["worldID"].as_str(),ip["residentScope"].as_str()],|r|r.get::<_,i64>(0)).map_err(|_|"storage_unavailable")).await?;
                if unresolved > 0 {
                    return Err("agent_claude_unresolved_tools");
                }
                let config = Configuration::parse(p)?;
                let mut current = self.session.lock().await;
                if let Some(old) = current.as_ref() {
                    if old.identity == i
                        || !["completed", "failed", "cancelled"]
                            .contains(&old.state.lock().await.as_str())
                    {
                        return Err("agent_claude_session_busy");
                    }
                }
                let directory = self
                    .db
                    .root
                    .join(format!("claude-{}", uuid::Uuid::new_v4()));
                files::directory(&directory)?;
                let private = PrivateFiles {
                    grant: directory.join("grant.json"),
                    directory: directory.clone(),
                };
                let cwd = directory.join("cwd");
                let configdir = directory.join("config");
                files::directory(&cwd)?;
                files::directory(&configdir)?;
                let expiry = now()?
                    .checked_add(300000)
                    .ok_or("agent_claude_clock_unavailable")?;
                let grant = ClaudeGrant {
                    identity: GrantIdentity {
                        world_id: i.world_id.clone(),
                        scope_id: i.scope_id.clone(),
                        session_id: i.session_id.clone(),
                        run_id: i.run_id.clone(),
                        event_id: event.clone(),
                    },
                    secret: uuid::Uuid::new_v4().to_string(),
                    round: uuid::Uuid::new_v4().to_string(),
                    expires_at_ms: expiry,
                    armed: true,
                };
                let pin = PinnedGrant::pin(&grant, now()?)
                    .map_err(|_| "agent_claude_invalid_configuration")?;
                let catalogpath = directory.join("tools.json");
                files::publish(
                    &catalogpath,
                    &serde_json::to_vec(&config.catalog)
                        .map_err(|_| "agent_claude_invalid_tools")?,
                )?;
                let grantjson = json!({"protocol":1,"state":"armed","secret":grant.secret,"round":grant.round,"expiresAt":expiry,"worldID":i.world_id,"scope":i.scope_id,"hostSessionID":i.session_id,"runID":i.run_id,"eventID":event,"endpoint":{"version":2,"url":config.endpoint,"token":grant.secret},"tools":config.catalog.as_array().unwrap().iter().map(|t|json!({"name":t["name"],"canonical":t["canonical"]})).collect::<Vec<_>>()});
                files::publish(
                    &private.grant,
                    &serde_json::to_vec(&grantjson)
                        .map_err(|_| "agent_claude_invalid_configuration")?,
                )?;
                let mut mcp = json!({"mcpServers":{}});
                if !config.names.is_empty() {
                    mcp["mcpServers"][claude_session::MCP_SERVER] = json!({"type":"stdio","command":config.adapter,"args":["resident-claude","--grant",private.grant,"--tools",catalogpath]});
                }
                let mcppath = directory.join("mcp.json");
                files::publish(
                    &mcppath,
                    &serde_json::to_vec(&mcp).map_err(|_| "agent_claude_invalid_configuration")?,
                )?;
                let policy = ClaudePolicy::new(config.catalog.clone())
                    .map_err(|_| "agent_claude_invalid_tools")?;
                let arguments = policy
                    .arguments(&mcppath.to_string_lossy())
                    .map_err(|_| "agent_claude_invalid_configuration")?;
                let environment =
                    claude_session::environment(&config.environment, &configdir.to_string_lossy())
                        .map_err(|_| "agent_claude_missing_credential")?;
                let queue = Arc::new(Queue {
                    event: event.clone(),
                    round: grant.round.clone(),
                    approval: Mutex::new(HashMap::new()),
                    execution: Mutex::new(HashMap::new()),
                    approved: Mutex::new(HashMap::new()),
                    completed: Mutex::new(HashMap::new()),
                });
                let broker = Arc::new(Broker(queue.clone()));
                let executor = Arc::new(LedgerHostTools::new(
                    self.db.clone(),
                    broker.clone(),
                    broker,
                ));
                if !config.tools.as_array().unwrap().is_empty() {
                    executor
                        .register(&i, config.tools.clone())
                        .await
                        .map_err(|_| "agent_claude_invalid_tools")?;
                }
                let prompt = self
                    .history
                    .lock()
                    .await
                    .prompt(&i, &config.input, config.memory.as_deref())
                    .map_err(|_| "agent_claude_input_limit")?;
                let secrets = vec![
                    grant.secret.clone(),
                    environment["ANTHROPIC_API_KEY"].clone(),
                ];
                if secrets.iter().any(|secret| prompt.contains(secret)) {
                    return Err("secret_in_input");
                }
                let s = Arc::new(Session {
                    identity: i,
                    event,
                    grant: Mutex::new(grant),
                    pin,
                    files: private,
                    policy,
                    names: config.names,
                    queue,
                    executor,
                    state: Mutex::new("running".into()),
                    reply: Mutex::new(String::new()),
                    cancel: CancellationToken::new(),
                    user_cancelled: AtomicBool::new(false),
                    active: AtomicUsize::new(0),
                    success: AtomicUsize::new(0),
                    calls: Mutex::new(HashSet::new()),
                    secrets,
                });
                *current = Some(s.clone());
                let db = self.db.clone();
                let history = self.history.clone();
                let process = OneshotConfig {
                    executable: config.executable,
                    arguments,
                    environment,
                    working_directory: Some(cwd),
                    lifetime: Duration::from_secs(300),
                };
                tokio::spawn(run(
                    db,
                    history,
                    s,
                    process,
                    prompt,
                    config.user,
                    config.silent,
                ));
                Ok(json!({"started":true}))
            }
            "agent_claude_read" => {
                let s = self.current(p).await?;
                let mut pending = s
                    .queue
                    .approval
                    .lock()
                    .await
                    .values()
                    .map(|v| v.request.clone())
                    .collect::<Vec<_>>();
                pending.extend(
                    s.queue
                        .execution
                        .lock()
                        .await
                        .values()
                        .map(|v| v.request.clone()),
                );
                Ok(
                    json!({"state":s.state.lock().await.clone(),"text":s.reply.lock().await.clone(),"pendingTools":pending,"round":s.queue.round}),
                )
            }
            "agent_claude_authorize" => {
                let s = self.current(p).await?;
                let call = text(p, "callID")?;
                let decision = text(p, "decision")?;
                let operation = match decision.as_str() {
                    "approved" => Some(text(p, "operationID")?),
                    "rejected" => None,
                    _ => return Err("agent_claude_invalid_authorization"),
                };
                let answer = json!({"round":text(p,"round")?,"toolName":text(p,"toolName")?,"arguments":p["arguments"],"decision":decision,"operationID":operation});
                let mut pending = s.queue.approval.lock().await;
                let mut done = s.queue.approved.lock().await;
                if let Some(old) = done.get(&call) {
                    if *old != answer {
                        return Err("agent_claude_receipt_conflict");
                    }
                    return Ok(json!({"accepted":true,"duplicate":true}));
                }
                verify_live(&s).await?;
                let request = pending.get(&call).ok_or("agent_claude_not_pending")?;
                for k in ["round", "toolName", "arguments"] {
                    if request.request[k] != answer[k] {
                        return Err("agent_claude_receipt_conflict");
                    }
                }
                let request = pending.remove(&call).unwrap();
                request
                    .tx
                    .send(operation.ok_or_else(|| "host_operation_rejected".into()))
                    .map_err(|_| "agent_claude_not_pending")?;
                done.insert(call, answer);
                Ok(json!({"accepted":true,"duplicate":false}))
            }
            "agent_claude_tool_receipt" => {
                let s = self.current(p).await?;
                let call = text(p, "callID")?;
                let images = image_blocks(p)?;
                if p["output"].to_string().len() > 16384 {
                    return Err("agent_claude_invalid_receipt");
                }
                if s.secrets
                    .iter()
                    .any(|secret| p["output"].to_string().contains(secret))
                {
                    return Err("agent_claude_unsafe_result");
                }
                let answer = json!({"round":text(p,"round")?,"operationID":text(p,"operationID")?,"status":p["status"],"output":p["output"],"images":images.iter().map(|v|json!({"mediaType":v.media_type,"byteLength":v.bytes.len(),"sha256":format!("{:x}",Sha256::digest(&v.bytes))})).collect::<Vec<_>>()});
                let mut pending = s.queue.execution.lock().await;
                let mut done = s.queue.completed.lock().await;
                if let Some(old) = done.get(&call) {
                    if *old != answer {
                        return Err("agent_claude_receipt_conflict");
                    }
                    return Ok(json!({"accepted":true,"duplicate":true}));
                }
                verify_live(&s).await?;
                let request = pending.get(&call).ok_or("agent_claude_not_pending")?;
                for k in ["round", "operationID"] {
                    if request.request[k] != answer[k] {
                        return Err("agent_claude_receipt_conflict");
                    }
                }
                let prior_count = done
                    .values()
                    .filter_map(|v| v["images"].as_array())
                    .map(Vec::len)
                    .sum::<usize>();
                let prior_bytes = done
                    .values()
                    .filter_map(|v| v["images"].as_array())
                    .flatten()
                    .filter_map(|v| v["byteLength"].as_u64())
                    .sum::<u64>();
                if prior_count + images.len() > 4
                    || prior_bytes + images.iter().map(|v| v.bytes.len() as u64).sum::<u64>()
                        > 4 * 1024 * 1024
                {
                    return Err("agent_claude_image_limit");
                }
                let status = match p["status"].as_str() {
                    Some("completed") => HostToolStatus::Completed,
                    Some("unknown") => HostToolStatus::Unknown,
                    Some("rejected") => HostToolStatus::Rejected,
                    _ => return Err("agent_claude_invalid_receipt"),
                };
                let request = pending.remove(&call).unwrap();
                request
                    .tx
                    .send(HostToolReceipt {
                        identity: s.identity.clone(),
                        call_id: call.clone(),
                        status,
                        output: p["output"].clone(),
                        images,
                    })
                    .map_err(|_| "agent_claude_not_pending")?;
                done.insert(call, answer);
                Ok(json!({"accepted":true,"duplicate":false}))
            }
            "agent_claude_cancel" => {
                let s = self.current(p).await?;
                let mut cancel = params(&s.identity);
                cancel["eventID"] = json!(s.event);
                let result = self
                    .db
                    .call(move |store| {
                        agent_scheduler::request(
                            &mut store.connection,
                            "agent_loop_cancel",
                            &cancel,
                        )
                    })
                    .await?;
                if result["cancelRequested"] == true {
                    s.user_cancelled.store(true, Ordering::Release);
                    revoke(&s).await;
                    *s.state.lock().await = "cancel_requested".into();
                    s.cancel.cancel();
                }
                Ok(result)
            }
            _ => Err("unknown_method"),
        }
    }
    pub async fn accepts_grant(&self, token: &str) -> bool {
        let Some(s) = self.session.lock().await.clone() else {
            return false;
        };
        let matches = s.grant.lock().await.secret == token;
        matches && verify_live(&s).await.is_ok()
    }
    /// This private token only authorizes registered MCP tools, never control RPCs.
    pub async fn host_call(&self, token: &str, p: &Value) -> Result<Value> {
        let s = self
            .session
            .lock()
            .await
            .clone()
            .ok_or("agent_claude_not_started")?;
        if s.grant.lock().await.secret != token {
            return Err("agent_claude_host_unauthorized");
        }
        verify_live(&s).await?;
        self.claimed(&s.identity, &s.event).await?;
        if p.as_object().is_none_or(|m| {
            m.len() != 4
                || !["v", "callId", "name", "arguments"]
                    .iter()
                    .all(|k| m.contains_key(*k))
        }) || p["v"] != 1
        {
            return Err("agent_claude_invalid_request");
        }
        let call = text(p, "callId")?;
        let name = text(p, "name")?;
        if s.secrets
            .iter()
            .any(|secret| p["arguments"].to_string().contains(secret))
        {
            return Err("secret_in_input");
        }
        s.policy
            .validate_call(&name, &p["arguments"])
            .map_err(|_| "agent_claude_tool_not_authorized")?;
        let tool = s
            .names
            .get(&name)
            .cloned()
            .ok_or("agent_claude_tool_not_authorized")?;
        {
            let mut calls = s.calls.lock().await;
            if calls.len() >= 128 || !calls.insert(call.clone()) {
                return Err("agent_claude_duplicate_call");
            }
        }
        if s.active.fetch_add(1, Ordering::AcqRel) >= 4 {
            s.active.fetch_sub(1, Ordering::AcqRel);
            return Err("agent_claude_queue_limit");
        }
        struct Active(Arc<Session>);
        impl Drop for Active {
            fn drop(&mut self) {
                self.0.active.fetch_sub(1, Ordering::AcqRel);
            }
        }
        let _active = Active(s.clone());
        let result = s
            .executor
            .execute(HostToolContext {
                identity: s.identity.clone(),
                execution: ToolExecutionContext {
                    call: ToolCall {
                        tool_call_id: call,
                        tool_name: tool,
                        input: p["arguments"].clone(),
                        provider_executed: None,
                        dynamic: None,
                        thought_signature: None,
                    },
                    cancellation: s.cancel.clone(),
                },
            })
            .await;
        if let Err(code) = verify_live(&s).await {
            revoke(&s).await;
            s.cancel.cancel();
            return Err(code);
        }
        if let Err(code) = self.claimed(&s.identity, &s.event).await {
            revoke(&s).await;
            s.cancel.cancel();
            return Err(code);
        }
        match result {
            Ok(receipt) => {
                if s.secrets
                    .iter()
                    .any(|secret| receipt.output.to_string().contains(secret))
                {
                    revoke(&s).await;
                    s.cancel.cancel();
                    return Err("agent_claude_unsafe_result");
                }
                claude_session::mcp_tool_result(&receipt.output, &receipt.images, true)
                    .map_err(|_| "agent_claude_invalid_receipt")?;
                s.success.fetch_add(1, Ordering::AcqRel);
                Ok(
                    json!({"ok":true,"data":receipt.output,"images":receipt.images.iter().map(|i|json!({"base64":base64::engine::general_purpose::STANDARD.encode(&i.bytes),"mimeType":i.media_type})).collect::<Vec<_>>() }),
                )
            }
            Err(reason) => {
                if reason != "host_operation_unavailable" {
                    revoke(&s).await;
                    s.cancel.cancel();
                }
                Ok(
                    json!({"ok":false,"error":{"code":"host_tool_unavailable","message":"宿主工具未能完成。"}}),
                )
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn config() -> Value {
        json!({"executable":"/private/claude","adapterExecutable":"/private/gmgn-mcpd","hostEndpoint":"http://127.0.0.1:12345/rpc","environment":{"ANTHROPIC_API_KEY":"dummy-explicit"},"input":"inspect","durableUserText":"inspect","tools":[{"name":"inspect_world","description":"world","effect":"read","inputSchema":{"type":"object","additionalProperties":false,"properties":{}}}]})
    }
    #[test]
    fn configuration_rejects_builtin_override_and_missing_credentials() {
        assert!(Configuration::parse(&config()).is_ok());
        for change in [
            json!({"arguments":["--tools","Bash"]}),
            json!({"mcpConfig":"/external"}),
            json!({"hostEndpoint":"http://example.com:12345/rpc"}),
            json!({"environment":{}}),
            json!({"tools":[{"name":"shell","description":"bad","effect":"read","inputSchema":{"type":"object"}}]}),
        ] {
            let mut p = config();
            for (k, v) in change.as_object().unwrap() {
                p[k] = v.clone();
            }
            assert!(Configuration::parse(&p).is_err());
        }
    }
    async fn fixture() -> (Arc<ClaudeService>, Value, String, PathBuf) {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "gmgn-claude-ledger-fixture-{}",
            uuid::Uuid::new_v4()
        ));
        files::directory(&root).unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        db.call(|store|{agent_scheduler::request(&mut store.connection,"agent_loop_configure",&json!({"worldID":"w","residentScope":"s","hostSessionID":"h","hourlyLimit":6,"minimumWakeIntervalSeconds":1}))?;store.connection.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','e','{}','claimed','r','h')",[]).map_err(|_|"storage_unavailable")?;Ok(())}).await.unwrap();
        let service = Arc::new(ClaudeService::new(db.clone()));
        let p = json!({"worldID":"w","residentScope":"s","hostSessionID":"h","runID":"r","eventID":"e"});
        let i = identity(&p).unwrap();
        let configuration = Configuration::parse(&config()).unwrap();
        let directory = root.join(format!("claude-{}", uuid::Uuid::new_v4()));
        files::directory(&directory).unwrap();
        let private = PrivateFiles {
            grant: directory.join("grant.json"),
            directory,
        };
        let grant = ClaudeGrant {
            identity: GrantIdentity {
                world_id: "w".into(),
                scope_id: "s".into(),
                session_id: "h".into(),
                run_id: "r".into(),
                event_id: "e".into(),
            },
            secret: uuid::Uuid::new_v4().to_string(),
            round: uuid::Uuid::new_v4().to_string(),
            expires_at_ms: now().unwrap() + 60000,
            armed: true,
        };
        let token = grant.secret.clone();
        let pin = PinnedGrant::pin(&grant, now().unwrap()).unwrap();
        files::publish(&private.grant,&serde_json::to_vec(&json!({"protocol":1,"state":"armed","secret":grant.secret,"round":grant.round,"expiresAt":grant.expires_at_ms,"worldID":"w","scope":"s","hostSessionID":"h","runID":"r","eventID":"e"})).unwrap()).unwrap();
        let queue = Arc::new(Queue {
            event: "e".into(),
            round: grant.round.clone(),
            approval: Mutex::new(HashMap::new()),
            execution: Mutex::new(HashMap::new()),
            approved: Mutex::new(HashMap::new()),
            completed: Mutex::new(HashMap::new()),
        });
        let broker = Arc::new(Broker(queue.clone()));
        let executor = Arc::new(LedgerHostTools::new(db, broker.clone(), broker));
        executor.register(&i, configuration.tools).await.unwrap();
        let session = Arc::new(Session {
            identity: i,
            event: "e".into(),
            grant: Mutex::new(grant),
            pin,
            files: private,
            policy: ClaudePolicy::new(configuration.catalog).unwrap(),
            names: configuration.names,
            queue,
            executor,
            state: Mutex::new("running".into()),
            reply: Mutex::new(String::new()),
            cancel: CancellationToken::new(),
            user_cancelled: AtomicBool::new(false),
            active: AtomicUsize::new(0),
            success: AtomicUsize::new(0),
            calls: Mutex::new(HashSet::new()),
            secrets: vec![token.clone(), "dummy-explicit".into()],
        });
        *service.session.lock().await = Some(session);
        (service, p, token, root)
    }
    async fn pending(service: &ClaudeService, p: &Value, phase: &str) -> Value {
        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let read = service.request("agent_claude_read", p).await.unwrap();
                if let Some(v) = read["pendingTools"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|v| v["phase"] == phase)
                {
                    break v.clone();
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap()
    }
    #[tokio::test]
    async fn read_tool_requires_real_host_authorization_and_strict_receipt_identity() {
        let (service, p, token, root) = fixture().await;
        assert!(service.accepts_grant(&token).await);
        let request = json!({"v":1,"callId":"call","name":"gmgn_inspect_world","arguments":{}});
        let job = tokio::spawn({
            let service = service.clone();
            let token = token.clone();
            let request = request.clone();
            async move { service.host_call(&token, &request).await }
        });
        let mut approval = pending(&service, &p, "authorize").await;
        let persisted = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row("SELECT count(*) FROM agent_tool_calls", [], |r| {
                        r.get::<_, i64>(0)
                    })
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(
            persisted, 0,
            "read is not dispatched before host authorization"
        );
        approval["decision"] = json!("approved");
        approval["operationID"] = json!("host-derived-read-op");
        service
            .request("agent_claude_authorize", &approval)
            .await
            .unwrap();
        let mut execution = pending(&service, &p, "execute").await;
        execution["status"] = json!("completed");
        execution["output"] = json!({"ok":true});
        let mut wrong = execution.clone();
        wrong["round"] = json!("old-round");
        assert_eq!(
            service
                .request("agent_claude_tool_receipt", &wrong)
                .await
                .unwrap_err(),
            "agent_claude_receipt_conflict"
        );
        service
            .request("agent_claude_tool_receipt", &execution)
            .await
            .unwrap();
        assert_eq!(job.await.unwrap().unwrap()["ok"], true);
        assert_eq!(
            service.host_call(&token, &request).await.unwrap_err(),
            "agent_claude_duplicate_call"
        );
        let state = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row(
                        "SELECT state FROM agent_tool_calls WHERE call='call'",
                        [],
                        |r| r.get::<_, String>(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(state, "finished");
        drop(service);
        let _ = std::fs::remove_dir_all(root);
    }
    #[tokio::test]
    async fn private_grant_revocation_and_secret_input_fail_before_tool_dispatch() {
        let (service, p, token, root) = fixture().await;
        assert_eq!(service.host_call(&token,&json!({"v":1,"callId":"secret","name":"gmgn_inspect_world","arguments":{"value":token}})).await.unwrap_err(),"secret_in_input");
        let s = service.session.lock().await.clone().unwrap();
        revoke(&s).await;
        assert!(!service.accepts_grant(&token).await);
        assert_eq!(
            service
                .host_call(
                    &token,
                    &json!({"v":1,"callId":"call","name":"gmgn_inspect_world","arguments":{}})
                )
                .await
                .unwrap_err(),
            "agent_claude_grant_revoked"
        );
        assert!(
            service.request("agent_claude_read", &p).await.unwrap()["pendingTools"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        drop(s);
        drop(service);
        let _ = std::fs::remove_dir_all(root);
    }
}
async fn verify_live(s: &Session) -> Result<()> {
    if s.cancel.is_cancelled() || *s.state.lock().await != "running" {
        return Err("agent_claude_host_unauthorized");
    }
    let grant = s.grant.lock().await;
    s.pin
        .verify(&grant, now()?)
        .map_err(|_| "agent_claude_grant_revoked")?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if std::fs::symlink_metadata(&s.files.grant)
            .map_err(|_| "agent_claude_grant_revoked")?
            .permissions()
            .mode()
            & 0o077
            != 0
        {
            return Err("agent_claude_grant_revoked");
        }
    }
    let bytes = files::read(&s.files.grant, 65536).map_err(|_| "agent_claude_grant_revoked")?;
    let file: Value = serde_json::from_slice(&bytes).map_err(|_| "agent_claude_grant_revoked")?;
    if file["protocol"] != 1
        || file["state"] != "armed"
        || file["secret"] != grant.secret
        || file["round"] != grant.round
        || file["expiresAt"].as_u64() != Some(grant.expires_at_ms)
        || file["worldID"] != grant.identity.world_id
        || file["scope"] != grant.identity.scope_id
        || file["hostSessionID"] != grant.identity.session_id
        || file["runID"] != grant.identity.run_id
        || file["eventID"] != grant.identity.event_id
    {
        return Err("agent_claude_grant_revoked");
    }
    Ok(())
}
async fn revoke(s: &Session) {
    s.grant.lock().await.armed = false;
    let _ = std::fs::remove_file(&s.files.grant);
}
async fn run(
    db: Database,
    history: Arc<Mutex<ClaudeHistory>>,
    s: Arc<Session>,
    process: OneshotConfig,
    prompt: String,
    user: Option<String>,
    allow_silent: bool,
) {
    let outcome = oneshot_transport::run(process, prompt, s.cancel.clone()).await;
    revoke(&s).await;
    s.cancel.cancel();
    let settling = tokio::time::Instant::now() + Duration::from_secs(2);
    while s.active.load(Ordering::Acquire) > 0 && tokio::time::Instant::now() < settling {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    let _ = std::fs::remove_dir_all(&s.files.directory);
    let i = params(&s.identity);
    let unknown=db.call(move|store|store.connection.query_row("SELECT count(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND state IN ('unknown','inflight')",rusqlite::params![i["worldID"].as_str(),i["residentScope"].as_str(),i["runID"].as_str()],|r|r.get::<_,i64>(0)).map_err(|_|"storage_unavailable")).await.unwrap_or(1)>0;
    if unknown || s.active.load(Ordering::Acquire) > 0 {
        let mut p = params(&s.identity);
        p["eventID"] = json!(s.event);
        let _=db.call(move|store|{store.connection.execute("UPDATE agent_loop_events SET state='unknown' WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND event=?5 AND state IN ('claimed','cancel_requested')",rusqlite::params![p["worldID"].as_str(),p["residentScope"].as_str(),p["runID"].as_str(),p["hostSessionID"].as_str(),p["eventID"].as_str()]).map_err(|_|"storage_unavailable")?;Ok(())}).await;
        *s.state.lock().await = "unknown".into();
        return;
    }
    let reply = outcome
        .ok()
        .and_then(|o| {
            claude_session::parse_result(o.status.code().unwrap_or(-1), o.stdout.as_bytes()).ok()
        })
        .filter(|reply| !s.secrets.iter().any(|secret| reply.contains(secret)));
    let cancelled = s.user_cancelled.load(Ordering::Acquire);
    let completed = !cancelled
        && reply.as_ref().is_some_and(|r| {
            !r.is_empty() || (allow_silent && s.success.load(Ordering::Acquire) > 0)
        });
    let status = if cancelled {
        "cancelled"
    } else if completed {
        "completed"
    } else {
        "failed"
    };
    let mut p = params(&s.identity);
    p["eventID"] = json!(s.event);
    p["status"] = json!(status);
    p["receipt"] = json!({"source":"native-claude-oneshot","status":status,"reply":reply.as_deref().unwrap_or("")});
    let method = if cancelled {
        "agent_loop_confirm_cancel"
    } else {
        "agent_loop_complete"
    };
    let settled = db
        .call(move |store| agent_scheduler::request(&mut store.connection, method, &p))
        .await;
    if settled.is_ok() {
        if completed {
            let reply = reply.unwrap();
            history
                .lock()
                .await
                .record(&s.identity, user.as_deref(), &reply);
            *s.reply.lock().await = reply;
        }
        *s.state.lock().await = status.into();
    } else {
        *s.state.lock().await = "unknown".into();
    }
}
