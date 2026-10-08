//! Authenticated Codex app-server service. Codex owns its own model/tool loop.
//! No CLI discovery, inherited environment, credential reads, or shell evaluation.
use crate::{
    agent_runtime_tools::{BusinessOperationResolver, HostToolTransport, LedgerHostTools},
    agent_scheduler,
    store::Database,
};
use base64::Engine;
use gmgn_agent_runtime::{
    cli_transport::{CliConfig, OwnedCliTransport},
    codex_session::{CodexEvent, CodexReceipt, CodexSession, SessionState},
    CancellationToken, HostToolContext, HostToolExecutor, HostToolReceipt, HostToolStatus,
    ImageInput, ToolCall, ToolExecutionContext, TurnIdentity,
};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, HashMap},
    future::Future,
    path::PathBuf,
    pin::Pin,
    sync::Arc,
    time::Duration,
};
use tokio::sync::{oneshot, Mutex};
type Result<T> = std::result::Result<T, &'static str>;
fn tools_digest(tools: &Value) -> Result<String> {
    let bytes = crate::canonical_json::to_vec(tools).map_err(|_| "agent_cli_invalid_tools")?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}
pub fn schema(c: &rusqlite::Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS world_cli_threads(world TEXT NOT NULL,scope TEXT NOT NULL,thread TEXT,tool_digest TEXT,imported INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(world,scope));").map_err(|_| "storage_unavailable")
}
fn continuity(c: &rusqlite::Connection, i: &TurnIdentity) -> Result<Value> {
    use rusqlite::OptionalExtension;
    let row: Option<Option<String>> = c
        .query_row(
            "SELECT thread FROM world_cli_threads WHERE world=?1 AND scope=?2",
            rusqlite::params![i.world_id, i.scope_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let thread = row.flatten();
    Ok(json!({"freshSession":thread.is_none(),"threadID":thread}))
}
fn require_claim(c: &mut rusqlite::Connection, i: &TurnIdentity, event: &str) -> Result<()> {
    let p = params(i);
    let state = agent_scheduler::request(c, "agent_loop_read", &p)?;
    if state["config"]["hostSessionID"] != p["hostSessionID"] {
        return Err("agent_cli_stale_session");
    }
    if !state["events"].as_array().is_some_and(|events| {
        events.iter().any(|e| {
            e["eventID"] == event
                && e["runID"] == p["runID"]
                && e["hostSessionID"] == p["hostSessionID"]
                && e["state"] == "claimed"
        })
    }) {
        return Err("agent_cli_run_not_claimed");
    }
    Ok(())
}
fn images(p: &Value) -> Result<Vec<ImageInput>> {
    let Some(raw) = p.get("images") else {
        return Ok(vec![]);
    };
    let images = raw
        .as_array()
        .filter(|v| v.len() <= 4)
        .ok_or("agent_cli_image_limit")?;
    let mut total = 0usize;
    let mut decoded = Vec::new();
    for image in images {
        let media_type = image["mediaType"]
            .as_str()
            .ok_or("agent_cli_invalid_image")?
            .to_owned();
        let encoded = image["base64"]
            .as_str()
            .filter(|v| v.len() <= 6 * 1024 * 1024)
            .ok_or("agent_cli_image_limit")?;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| "agent_cli_invalid_image")?;
        total = total
            .checked_add(bytes.len())
            .ok_or("agent_cli_image_limit")?;
        if total > 4 * 1024 * 1024 || bytes.is_empty() {
            return Err("agent_cli_image_limit");
        }
        let valid = match media_type.as_str() {
            "image/png" => bytes.starts_with(b"\x89PNG\r\n\x1a\n"),
            "image/jpeg" => bytes.starts_with(b"\xff\xd8\xff"),
            "image/gif" => bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a"),
            "image/webp" => bytes.starts_with(b"RIFF") && bytes.get(8..12) == Some(b"WEBP"),
            _ => false,
        };
        if !valid {
            return Err("agent_cli_invalid_image");
        }
        decoded.push(ImageInput { bytes, media_type });
    }
    Ok(decoded)
}
type ToolFuture<T> = Pin<Box<dyn Future<Output = std::result::Result<T, String>> + Send + 'static>>;
const FEATURES: &[&str] = &[
    "plugins",
    "apps",
    "hooks",
    "multi_agent",
    "multi_agent_v2",
    "image_generation",
    "shell_tool",
];
fn text(p: &Value, k: &str) -> Result<String> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .map(str::to_owned)
        .ok_or("agent_cli_invalid_request")
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
fn arguments(names: &[String]) -> Result<Vec<String>> {
    let mut overrides = FEATURES
        .iter()
        .map(|v| format!("features.{v}=false"))
        .collect::<Vec<_>>();
    overrides.extend(
        [
            "agents.enabled=false",
            "notify=[]",
            "web_search=\"live\"",
            "cli_auth_credentials_store=\"file\"",
            "mcp_oauth_credentials_store=\"file\"",
        ]
        .into_iter()
        .map(str::to_owned),
    );
    if !names.is_empty() {
        let mut names = names.to_vec();
        names.sort();
        names.dedup();
        let names = names
            .iter()
            .map(|n| serde_json::to_string(n).map(|n| format!("{n}={{enabled=false}}")))
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|_| "agent_cli_invalid_configuration")?;
        overrides.push(format!("mcp_servers={{{}}}", names.join(",")));
    }
    let mut args = vec!["app-server".into(), "--stdio".into()];
    for v in overrides {
        args.push("-c".into());
        args.push(v);
    }
    Ok(args)
}
fn environment(value: &Value) -> Result<BTreeMap<String, String>> {
    let allowed = [
        "HOME",
        "CODEX_HOME",
        "PATH",
        "TMPDIR",
        "USER",
        "LOGNAME",
        "SHELL",
        "LANG",
        "LC_ALL",
        "HTTPS_PROXY",
        "HTTP_PROXY",
        "ALL_PROXY",
        "NO_PROXY",
        "https_proxy",
        "http_proxy",
        "all_proxy",
        "no_proxy",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
    ];
    let mut result = BTreeMap::new();
    let source = value
        .as_object()
        .filter(|v| v.len() <= 128)
        .ok_or("agent_cli_invalid_configuration")?;
    for (k, v) in source {
        let v = v.as_str().ok_or("agent_cli_invalid_configuration")?;
        if v.contains('\0') {
            return Err("agent_cli_invalid_configuration");
        }
        if allowed.contains(&k.as_str()) {
            result.insert(k.clone(), v.to_owned());
        }
    }
    let mut paths = vec![
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect::<Vec<_>>();
    if let Some(path) = result.get("PATH") {
        for directory in path.split(':').filter(|v| !v.is_empty()) {
            if !paths.iter().any(|v| v == directory) {
                paths.push(directory.to_owned());
            }
        }
    }
    result.insert("PATH".into(), paths.join(":"));
    result.insert("CODEX_EXEC_SERVER_URL".into(), "none".into());
    if result.iter().map(|(k, v)| k.len() + v.len()).sum::<usize>() > 65536 {
        return Err("agent_cli_invalid_configuration");
    }
    Ok(result)
}
struct Configuration {
    executable: PathBuf,
    environment: BTreeMap<String, String>,
    cwd: PathBuf,
    input: Value,
    tools: Value,
    resume: Option<String>,
    silent: bool,
}
impl Configuration {
    fn parse(p: &Value) -> Result<Self> {
        if p.to_string().len() > 2 * 1024 * 1024 {
            return Err("agent_cli_input_limit");
        }
        let executable = PathBuf::from(
            p["executable"]
                .as_str()
                .ok_or("agent_cli_invalid_configuration")?,
        );
        if !executable.is_absolute() {
            return Err("agent_cli_invalid_configuration");
        }
        let supplied = p["arguments"]
            .as_array()
            .ok_or("agent_cli_invalid_configuration")?
            .iter()
            .map(|v| {
                v.as_str()
                    .map(str::to_owned)
                    .ok_or("agent_cli_invalid_configuration")
            })
            .collect::<Result<Vec<_>>>()?;
        if supplied != arguments(&[])? {
            return Err("agent_cli_unsafe_arguments");
        }
        let root = PathBuf::from(
            p["root"]
                .as_str()
                .ok_or("agent_cli_invalid_configuration")?,
        );
        let cwd = PathBuf::from(p["cwd"].as_str().ok_or("agent_cli_invalid_configuration")?);
        if !root.is_absolute() || !cwd.is_absolute() {
            return Err("agent_cli_invalid_configuration");
        }
        let root = root
            .canonicalize()
            .map_err(|_| "agent_cli_invalid_configuration")?;
        let cwd = cwd
            .canonicalize()
            .map_err(|_| "agent_cli_invalid_configuration")?;
        if !cwd.starts_with(&root) || !cwd.is_dir() {
            return Err("agent_cli_unsafe_directory");
        }
        let input = p["input"]
            .as_array()
            .filter(|v| !v.is_empty() && v.len() <= 16)
            .ok_or("agent_cli_invalid_input")?;
        for item in input {
            match item["type"].as_str() {
                Some("text") => {
                    if !item["text"].is_string() {
                        return Err("agent_cli_invalid_input");
                    }
                }
                Some("image") => {
                    let url = item["url"].as_str().ok_or("agent_cli_invalid_input")?;
                    if !url.starts_with("data:image/") || !url.contains(";base64,") {
                        return Err("agent_cli_invalid_input");
                    }
                }
                Some("localImage") => {
                    let path =
                        PathBuf::from(item["path"].as_str().ok_or("agent_cli_invalid_input")?);
                    if !path.is_absolute() || !path.is_file() {
                        return Err("agent_cli_invalid_input");
                    }
                }
                _ => return Err("agent_cli_invalid_input"),
            }
        }
        let tools = p["tools"]
            .as_array()
            .filter(|v| !v.is_empty() && v.len() <= 64)
            .ok_or("agent_cli_invalid_tools")?;
        Ok(Self {
            executable,
            environment: environment(&p["environment"])?,
            cwd,
            input: json!(input),
            tools: json!(tools),
            resume: p["resumeThreadID"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= 256)
                .map(str::to_owned),
            silent: p["allowSilentCompletion"].as_bool().unwrap_or(false),
        })
    }
    fn process(&self, names: &[String], lifetime: Duration) -> Result<CliConfig> {
        Ok(CliConfig {
            executable: self.executable.clone(),
            arguments: arguments(names)?,
            environment: self.environment.clone(),
            working_directory: Some(self.cwd.clone()),
            lifetime,
        })
    }
}
async fn config_probe(config: CliConfig, cancel: &CancellationToken) -> Result<Vec<String>> {
    let mut transport = OwnedCliTransport::spawn(config)
        .await
        .map_err(|_| "agent_cli_launch_failed")?;
    let result = async {
        transport.send(&json!({"id":1,"method":"initialize","params":{"clientInfo":{"name":"gmgn_resident","version":"1"},"capabilities":{"experimentalApi":true}}})).await.map_err(|_|"agent_cli_preflight_failed")?;
        let mut initialized = false;
        loop {
            let frame = transport
                .receive()
                .await
                .map_err(|_| "agent_cli_preflight_failed")?;
            if frame.get("method").is_some() {
                if frame.get("id").is_some() {
                    transport.send(&json!({"id":frame["id"],"error":{"code":-32601,"message":"Resident tool unavailable"}})).await.map_err(|_|"agent_cli_preflight_failed")?;
                }
                continue;
            }
            if frame["error"].is_object() {
                return Err("agent_cli_preflight_failed");
            }
            if frame["id"] == 1 && !initialized {
                initialized = true;
                transport
                    .send(&json!({"method":"initialized","params":{}}))
                    .await
                    .map_err(|_| "agent_cli_preflight_failed")?;
                transport
                    .send(&json!({"id":2,"method":"config/read","params":{"includeLayers":false}}))
                    .await
                    .map_err(|_| "agent_cli_preflight_failed")?;
            } else if frame["id"] == 2 && initialized {
                let config = frame["result"]["config"]
                    .as_object()
                    .ok_or("agent_cli_invalid_configuration")?;
                let Some(servers) = config.get("mcp_servers") else {
                    return Ok(vec![]);
                };
                let mut names = servers
                    .as_object()
                    .ok_or("agent_cli_invalid_configuration")?
                    .keys()
                    .cloned()
                    .collect::<Vec<_>>();
                if names.len() > 64 || names.iter().any(|n| n.len() > 256) {
                    return Err("agent_cli_invalid_configuration");
                }
                names.sort();
                return Ok(names);
            }
        }
    };
    let result = tokio::select! {biased;_=cancel.cancelled()=>Err("agent_cli_cancelled"),r=tokio::time::timeout(Duration::from_secs(30),result)=>r.unwrap_or(Err("agent_cli_preflight_timeout"))};
    transport.cancel();
    transport.wait_closed().await;
    result
}
struct Approval {
    request: Value,
    tx: oneshot::Sender<std::result::Result<String, String>>,
}
struct Execution {
    request: Value,
    tx: oneshot::Sender<HostToolReceipt>,
}
#[derive(Default)]
struct Queue {
    approvals: Mutex<HashMap<String, Approval>>,
    executions: Mutex<HashMap<String, Execution>>,
    approvals_done: Mutex<HashMap<String, Value>>,
    executions_done: Mutex<HashMap<String, Value>>,
    bindings: Mutex<HashMap<String, (String, String)>>,
    event: Mutex<String>,
}
struct Cleanup {
    q: Arc<Queue>,
    call: String,
    approval: bool,
}
impl Drop for Cleanup {
    fn drop(&mut self) {
        let q = self.q.clone();
        let call = self.call.clone();
        let approval = self.approval;
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            handle.spawn(async move {
                if approval {
                    q.approvals.lock().await.remove(&call);
                } else {
                    q.executions.lock().await.remove(&call);
                }
            });
        }
    }
}
struct Resolver(Arc<Queue>);
impl BusinessOperationResolver for Resolver {
    fn resolve(&self, _: &TurnIdentity, _: &str, _: &Value) -> std::result::Result<String, String> {
        Err("host_authorization_required".into())
    }
    fn resolve_context(&self, c: HostToolContext) -> ToolFuture<String> {
        let q = self.0.clone();
        Box::pin(async move {
            let call = c.execution.call.tool_call_id.clone();
            let binding = q
                .bindings
                .lock()
                .await
                .get(&call)
                .cloned()
                .ok_or("host_call_binding_missing")?;
            let mut p = params(&c.identity);
            p["eventID"] = json!(q.event.lock().await.clone());
            p["callID"] = json!(call);
            p["threadID"] = json!(binding.0);
            p["turnID"] = json!(binding.1);
            p["toolName"] = json!(c.execution.call.tool_name);
            p["arguments"] = c.execution.call.input;
            p["phase"] = json!("authorize");
            let (tx, rx) = oneshot::channel();
            {
                let mut pending = q.approvals.lock().await;
                if pending.len() >= 32 || pending.contains_key(&call) {
                    return Err("host_queue_limit".into());
                }
                pending.insert(call.clone(), Approval { request: p, tx });
            }
            let _cleanup = Cleanup {
                q: q.clone(),
                call,
                approval: true,
            };
            tokio::select! {biased;_=c.execution.cancellation.cancelled()=>Err("host_authorization_cancelled".into()),r=tokio::time::timeout(Duration::from_secs(120),rx)=>match r{Ok(Ok(v))=>v,_=>Err("host_authorization_unknown".into())}}
        })
    }
}
struct Transport(Arc<Queue>);
impl HostToolTransport for Transport {
    fn dispatch(&self, c: HostToolContext, operation: String) -> ToolFuture<HostToolReceipt> {
        let q = self.0.clone();
        Box::pin(async move {
            let call = c.execution.call.tool_call_id.clone();
            let binding = q
                .bindings
                .lock()
                .await
                .get(&call)
                .cloned()
                .ok_or("host_call_binding_missing")?;
            let mut p = params(&c.identity);
            p["eventID"] = json!(q.event.lock().await.clone());
            p["callID"] = json!(call);
            p["threadID"] = json!(binding.0);
            p["turnID"] = json!(binding.1);
            p["toolName"] = json!(c.execution.call.tool_name);
            p["arguments"] = c.execution.call.input;
            p["operationID"] = json!(operation);
            p["phase"] = json!("execute");
            let (tx, rx) = oneshot::channel();
            {
                let mut pending = q.executions.lock().await;
                if pending.len() >= 32 || pending.contains_key(&call) {
                    return Err("host_queue_limit".into());
                }
                pending.insert(call.clone(), Execution { request: p, tx });
            }
            let _cleanup = Cleanup {
                q: q.clone(),
                call,
                approval: false,
            };
            tokio::select! {biased;_=c.execution.cancellation.cancelled()=>Err("host_tool_unknown".into()),r=tokio::time::timeout(Duration::from_secs(120),rx)=>match r{Ok(Ok(v))=>Ok(v),_=>Err("host_tool_unknown".into())}}
        })
    }
}
struct Session {
    identity: TurnIdentity,
    event: String,
    queue: Arc<Queue>,
    state: Mutex<String>,
    text: Mutex<String>,
    cancel: CancellationToken,
    cli_binding: Mutex<(Option<String>, Option<String>)>,
    user_cancelled: std::sync::atomic::AtomicBool,
}
pub struct CliService {
    db: Database,
    session: Mutex<Option<Arc<Session>>>,
}
impl CliService {
    pub fn new(db: Database) -> Self {
        Self {
            db,
            session: Mutex::new(None),
        }
    }
    async fn claimed(&self, i: &TurnIdentity, event: &str) -> Result<()> {
        let p = params(i);
        let event = event.to_owned();
        self.db
            .call(move |store| {
                let state = agent_scheduler::request(&mut store.connection, "agent_loop_read", &p)?;
                if state["config"]["hostSessionID"] != p["hostSessionID"] {
                    return Err("agent_cli_stale_session");
                }
                if !state["events"].as_array().is_some_and(|v| {
                    v.iter().any(|e| {
                        e["eventID"] == event
                            && e["runID"] == p["runID"]
                            && e["hostSessionID"] == p["hostSessionID"]
                            && e["state"] == "claimed"
                    })
                }) {
                    return Err("agent_cli_run_not_claimed");
                }
                Ok(())
            })
            .await
    }
    async fn current(&self, i: &TurnIdentity) -> Result<Arc<Session>> {
        let s = self
            .session
            .lock()
            .await
            .clone()
            .ok_or("agent_cli_not_started")?;
        if s.identity != *i {
            return Err("agent_cli_stale_session");
        }
        let p = params(i);
        self.db
            .call(move |store| {
                let state = agent_scheduler::request(&mut store.connection, "agent_loop_read", &p)?;
                if state["config"]["hostSessionID"] != p["hostSessionID"] {
                    return Err("agent_cli_stale_session");
                }
                Ok(())
            })
            .await?;
        Ok(s)
    }
    pub async fn request(&self, method: &str, p: &Value) -> Result<Value> {
        let i = identity(p)?;
        match method {
            "agent_cli_start" => {
                let event = text(p, "eventID")?;
                self.claimed(&i, &event).await?;
                let mut config = Configuration::parse(p)?;
                let trusted = i.clone();
                let claimed_event = event.clone();
                let digest = tools_digest(&config.tools)?;
                let legacy = p["importLegacyThreadID"].as_str().map(str::to_owned);
                if legacy.as_ref().is_some_and(|s| {
                    s.is_empty() || s.len() > 256 || s.chars().any(char::is_control)
                }) {
                    return Err("agent_cli_invalid_configuration");
                }
                if config.resume.is_some() {
                    return Err("agent_cli_host_resume_forbidden");
                }
                config.resume = self.db.call(move |store| {
                    require_claim(&mut store.connection,&trusted,&claimed_event)?;
                    use rusqlite::OptionalExtension;
                    let old:Option<(Option<String>,Option<String>)>=store.connection.query_row("SELECT thread,tool_digest FROM world_cli_threads WHERE world=?1 AND scope=?2",rusqlite::params![trusted.world_id,trusted.scope_id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
                    match old {
                        Some((thread,registered)) => {
                            if thread.is_some() && registered.as_ref().is_some_and(|old|old != &digest) { return Err("agent_cli_registry_changed"); }
                            if thread.is_some() && registered.is_none() {
                                store.connection.execute("UPDATE world_cli_threads SET tool_digest=?3 WHERE world=?1 AND scope=?2 AND tool_digest IS NULL",rusqlite::params![trusted.world_id,trusted.scope_id,digest]).map_err(|_|"storage_unavailable")?;
                            }
                            Ok(thread)
                        }
                        None => {
                            store.connection.execute("INSERT INTO world_cli_threads(world,scope,thread,tool_digest,imported) VALUES(?1,?2,?3,?4,1)",rusqlite::params![trusted.world_id,trusted.scope_id,legacy,digest]).map_err(|_|"storage_unavailable")?;
                            Ok(legacy)
                        }
                    }
                }).await?;
                CodexSession::new(
                    i.clone(),
                    config.cwd.to_string_lossy().into_owned(),
                    config.input.clone(),
                    config.tools.clone(),
                    config.resume.clone(),
                    config.silent,
                )
                .map_err(|_| "agent_cli_invalid_configuration")?;
                let mut current = self.session.lock().await;
                if let Some(old) = current.as_ref() {
                    let old_state = old.state.lock().await.clone();
                    let externally_verified = if old_state == "unknown" {
                        let identity = params(&old.identity);
                        let event = old.event.clone();
                        self.db.call(move|store|{
                            use rusqlite::OptionalExtension;
                            let state:Option<String>=store.connection.query_row("SELECT state FROM agent_loop_events WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND event=?5",rusqlite::params![identity["worldID"].as_str(),identity["residentScope"].as_str(),identity["runID"].as_str(),identity["hostSessionID"].as_str(),event],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
                            let unknown:i64=store.connection.query_row("SELECT count(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND state IN ('unknown','inflight')",rusqlite::params![identity["worldID"].as_str(),identity["residentScope"].as_str(),identity["runID"].as_str()],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                            Ok(unknown==0&&state.as_deref().is_some_and(|s|["completed","failed","cancelled"].contains(&s)))
                        }).await?
                    } else {
                        false
                    };
                    if old.identity == i
                        || (!externally_verified
                            && !["completed", "failed", "cancelled"].contains(&old_state.as_str()))
                    {
                        return Err("agent_cli_session_busy");
                    }
                }
                let s = Arc::new(Session {
                    identity: i,
                    event,
                    queue: Arc::new(Queue::default()),
                    state: Mutex::new("preflight".into()),
                    text: Mutex::new(String::new()),
                    cancel: CancellationToken::new(),
                    cli_binding: Mutex::new((None, None)),
                    user_cancelled: std::sync::atomic::AtomicBool::new(false),
                });
                *s.queue.event.lock().await = s.event.clone();
                *current = Some(s.clone());
                let db = self.db.clone();
                tokio::spawn(async move {
                    run(db, s, config).await;
                });
                Ok(json!({"started":true}))
            }
            "agent_cli_read" => {
                if p["continuity"] == true {
                    self.claimed(&i, &text(p, "eventID")?).await?;
                    let legacy = p["importLegacyThreadID"].as_str().map(str::to_owned);
                    let claimed_event = text(p, "eventID")?;
                    if legacy.as_ref().is_some_and(|s| {
                        s.is_empty() || s.len() > 256 || s.chars().any(char::is_control)
                    }) {
                        return Err("agent_cli_invalid_configuration");
                    }
                    return self.db.call(move |store| {
                        require_claim(&mut store.connection,&i,&claimed_event)?;
                        if let Some(thread)=legacy {
                            store.connection.execute("INSERT INTO world_cli_threads(world,scope,thread,tool_digest,imported) VALUES(?1,?2,?3,NULL,1) ON CONFLICT(world,scope) DO NOTHING",rusqlite::params![i.world_id,i.scope_id,thread]).map_err(|_|"storage_unavailable")?;
                        }
                        continuity(&store.connection,&i)
                    }).await;
                }
                let s = self.current(&i).await?;
                if p["eventID"] != s.event {
                    return Err("agent_cli_receipt_conflict");
                }
                let mut pending = s
                    .queue
                    .approvals
                    .lock()
                    .await
                    .values()
                    .map(|v| v.request.clone())
                    .collect::<Vec<_>>();
                pending.extend(
                    s.queue
                        .executions
                        .lock()
                        .await
                        .values()
                        .map(|v| v.request.clone()),
                );
                let state = s.state.lock().await.clone();
                let output = s.text.lock().await.clone();
                let binding = s.cli_binding.lock().await.clone();
                Ok(
                    json!({"state":state,"text":output,"pendingTools":pending,"threadID":binding.0,"turnID":binding.1}),
                )
            }
            "agent_cli_reset" => {
                if let Some(old) = self.session.lock().await.as_ref() {
                    if !["completed", "cancelled", "failed"]
                        .contains(&old.state.lock().await.as_str())
                    {
                        return Err("agent_cli_session_busy");
                    }
                }
                let event = text(p, "eventID")?;
                let trusted = i.clone();
                let bound = params(&i);
                self.db.call(move |store| {
                    use rusqlite::OptionalExtension;
                    let state=agent_scheduler::request(&mut store.connection,"agent_loop_read",&bound)?;
                    if state["config"]["hostSessionID"]!=bound["hostSessionID"] { return Err("agent_cli_stale_session"); }
                    let terminal:Option<String>=store.connection.query_row("SELECT state FROM agent_loop_events WHERE world=?1 AND scope=?2 AND event=?3 AND run=?4 AND session=?5",rusqlite::params![trusted.world_id,trusted.scope_id,event,trusted.run_id,trusted.session_id],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
                    if !terminal.as_deref().is_some_and(|s|["claimed","completed","cancelled","failed"].contains(&s)) { return Err("agent_cli_run_not_claimed"); }
                    store.connection.execute("INSERT INTO world_cli_threads(world,scope,thread,tool_digest,imported) VALUES(?1,?2,NULL,NULL,1) ON CONFLICT(world,scope) DO UPDATE SET thread=NULL,tool_digest=NULL,imported=1",rusqlite::params![trusted.world_id,trusted.scope_id]).map_err(|_|"storage_unavailable")?;
                    Ok(json!({"reset":true}))
                }).await
            }
            "agent_cli_authorize" => {
                let s = self.current(&i).await?;
                let call = text(p, "callID")?;
                let tool = text(p, "toolName")?;
                let decision = text(p, "decision")?;
                let operation = match decision.as_str() {
                    "approved" => Some(text(p, "operationID")?),
                    "rejected" => None,
                    _ => return Err("agent_cli_invalid_authorization"),
                };
                let answer = json!({"eventID":text(p,"eventID")?,"threadID":text(p,"threadID")?,"turnID":text(p,"turnID")?,"toolName":tool,"arguments":p["arguments"],"decision":decision,"operationID":operation});
                let mut pending = s.queue.approvals.lock().await;
                let mut done = s.queue.approvals_done.lock().await;
                if let Some(old) = done.get(&call) {
                    if *old != answer {
                        return Err("agent_cli_receipt_conflict");
                    }
                    return Ok(json!({"accepted":true,"duplicate":true}));
                }
                if s.cancel.is_cancelled() {
                    return Err("agent_cli_not_pending");
                }
                let proposal = pending.get(&call).ok_or("agent_cli_not_pending")?;
                for key in ["eventID", "threadID", "turnID"] {
                    if p[key] != proposal.request[key] {
                        return Err("agent_cli_receipt_conflict");
                    }
                }
                if proposal.request["toolName"] != tool
                    || proposal.request["arguments"] != p["arguments"]
                {
                    return Err("agent_cli_receipt_conflict");
                }
                let proposal = pending.remove(&call).unwrap();
                proposal
                    .tx
                    .send(operation.ok_or_else(|| "host_operation_rejected".into()))
                    .map_err(|_| "agent_cli_not_pending")?;
                done.insert(call, answer);
                Ok(json!({"accepted":true,"duplicate":false}))
            }
            "agent_cli_tool_receipt" => {
                let s = self.current(&i).await?;
                let call = text(p, "callID")?;
                let images = images(p)?;
                if p["output"].to_string().len() > 16384 {
                    return Err("agent_cli_invalid_receipt");
                }
                let answer = json!({"eventID":text(p,"eventID")?,"threadID":text(p,"threadID")?,"turnID":text(p,"turnID")?,"operationID":text(p,"operationID")?,"status":p["status"],"output":p["output"],"images":images.iter().map(|image|json!({"mediaType":image.media_type,"byteLength":image.bytes.len(),"sha256":format!("{:x}",Sha256::digest(&image.bytes))})).collect::<Vec<_>>()});
                let mut pending = s.queue.executions.lock().await;
                let mut done = s.queue.executions_done.lock().await;
                if let Some(old) = done.get(&call) {
                    if *old != answer {
                        return Err("agent_cli_receipt_conflict");
                    }
                    return Ok(json!({"accepted":true,"duplicate":true}));
                }
                let execution = pending.get(&call).ok_or("agent_cli_not_pending")?;
                let prior_count: usize = done
                    .values()
                    .filter_map(|v| v["images"].as_array())
                    .map(Vec::len)
                    .sum();
                let prior_bytes: u64 = done
                    .values()
                    .filter_map(|v| v["images"].as_array())
                    .flat_map(|v| v.iter())
                    .filter_map(|v| v["byteLength"].as_u64())
                    .sum();
                if prior_count + images.len() > 4
                    || prior_bytes
                        + images
                            .iter()
                            .map(|image| image.bytes.len() as u64)
                            .sum::<u64>()
                        > 4 * 1024 * 1024
                {
                    return Err("agent_cli_image_limit");
                }
                if p["eventID"] != execution.request["eventID"] {
                    return Err("agent_cli_receipt_conflict");
                }
                for key in ["threadID", "turnID", "operationID"] {
                    if answer[key] != execution.request[key] {
                        return Err("agent_cli_receipt_conflict");
                    }
                }
                let status = match p["status"].as_str() {
                    Some("completed") => HostToolStatus::Completed,
                    Some("unknown") => HostToolStatus::Unknown,
                    Some("rejected") => HostToolStatus::Rejected,
                    _ => return Err("agent_cli_invalid_receipt"),
                };
                let execution = pending.remove(&call).unwrap();
                execution
                    .tx
                    .send(HostToolReceipt {
                        identity: i,
                        call_id: call.clone(),
                        status,
                        output: p["output"].clone(),
                        images,
                    })
                    .map_err(|_| "agent_cli_not_pending")?;
                done.insert(call, answer);
                Ok(json!({"accepted":true,"duplicate":false}))
            }
            "agent_cli_cancel" => {
                let s = self.current(&i).await?;
                if p["eventID"] != s.event {
                    return Err("agent_cli_receipt_conflict");
                }
                let mut p = params(&i);
                p["eventID"] = json!(s.event);
                let result = self
                    .db
                    .call(move |store| {
                        agent_scheduler::request(&mut store.connection, "agent_loop_cancel", &p)
                    })
                    .await?;
                if result["cancelRequested"] == true {
                    s.user_cancelled
                        .store(true, std::sync::atomic::Ordering::Release);
                    *s.state.lock().await = "cancel_requested".into();
                    s.cancel.cancel();
                }
                Ok(result)
            }
            _ => Err("unknown_method"),
        }
    }
}
async fn run(db: Database, s: Arc<Session>, config: Configuration) {
    let tool_digest = tools_digest(&config.tools);
    let result = match &tool_digest {
        Ok(_) => drive(db.clone(), s.clone(), config).await,
        Err(error) => Err(*error),
    };
    let mut p = params(&s.identity);
    p["eventID"] = json!(s.event);
    let unknown_tools=db.call({let p=p.clone();move|store|store.connection.query_row("SELECT count(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND state IN ('inflight','unknown')",rusqlite::params![p["worldID"].as_str(),p["residentScope"].as_str(),p["runID"].as_str()],|r|r.get::<_,i64>(0)).map_err(|_|"storage_unavailable")}).await.unwrap_or(1)>0;
    let (terminal, reply) = result.unwrap_or((SessionState::Unknown, String::new()));
    if unknown_tools || terminal == SessionState::Unknown {
        let _=db.call(move|store|{store.connection.execute("UPDATE agent_loop_events SET state='unknown' WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND event=?5 AND state IN ('claimed','cancel_requested')",rusqlite::params![p["worldID"].as_str(),p["residentScope"].as_str(),p["runID"].as_str(),p["hostSessionID"].as_str(),p["eventID"].as_str()]).map_err(|_|"storage_unavailable")?;Ok(())}).await;
        *s.state.lock().await = "unknown".into();
        return;
    }
    let status = if s.user_cancelled.load(std::sync::atomic::Ordering::Acquire) {
        "cancelled"
    } else if terminal == SessionState::Completed {
        "completed"
    } else {
        "failed"
    };
    if reply.len() <= 1024 * 1024 {
        *s.text.lock().await = reply;
    }
    p["status"] = json!(status);
    p["receipt"] =
        json!({"source":"codex-app-server","status":status,"reply":s.text.lock().await.clone()});
    let method = if status == "cancelled" {
        "agent_loop_confirm_cancel"
    } else {
        "agent_loop_complete"
    };
    let thread = s.cli_binding.lock().await.0.clone();
    let settled = db
        .call(move |store| {
            agent_scheduler::request(&mut store.connection, method, &p)?;
            if status=="completed" {
                let tool_digest=tool_digest?;
                let thread=thread.ok_or("agent_cli_invalid_state")?;
                store.connection.execute("INSERT INTO world_cli_threads(world,scope,thread,tool_digest,imported) VALUES(?1,?2,?3,?4,1) ON CONFLICT(world,scope) DO UPDATE SET thread=excluded.thread,tool_digest=excluded.tool_digest,imported=1",rusqlite::params![p["worldID"].as_str(),p["residentScope"].as_str(),thread,tool_digest]).map_err(|_|"storage_unavailable")?;
            }
            Ok(())
        })
        .await;
    *s.state.lock().await = if settled.is_ok() { status } else { "unknown" }.into();
}
async fn drive(
    db: Database,
    s: Arc<Session>,
    config: Configuration,
) -> Result<(SessionState, String)> {
    let names = match config_probe(config.process(&[], Duration::from_secs(30))?, &s.cancel).await {
        Ok(names) => names,
        Err(_) => return Ok((SessionState::Failed, String::new())),
    };
    if s.cancel.is_cancelled() {
        return Ok((SessionState::Failed, String::new()));
    }
    let mut transport = OwnedCliTransport::spawn(config.process(&names, Duration::from_secs(180))?)
        .await
        .map_err(|_| "agent_cli_launch_failed")?;
    let executor = Arc::new(LedgerHostTools::new(
        db,
        Arc::new(Resolver(s.queue.clone())),
        Arc::new(Transport(s.queue.clone())),
    ));
    executor
        .register(&s.identity, config.tools.clone())
        .await
        .map_err(|_| "agent_cli_invalid_tools")?;
    let mut protocol = CodexSession::new(
        s.identity.clone(),
        config.cwd.to_string_lossy().into_owned(),
        config.input,
        config.tools,
        config.resume,
        config.silent,
    )
    .map_err(|_| "agent_cli_invalid_configuration")?;
    let initial = protocol
        .initialize()
        .map_err(|_| "agent_cli_protocol_failed")?;
    transport
        .send(&initial)
        .await
        .map_err(|_| "agent_cli_transport_failed")?;
    *s.state.lock().await = "running".into();
    let mut tools: tokio::task::JoinSet<(
        String,
        String,
        String,
        std::result::Result<HostToolReceipt, String>,
    )> = tokio::task::JoinSet::new();
    let mut model_started = false;
    let mut interrupted = false;
    let mut deadline = tokio::time::Instant::now() + Duration::from_secs(180);
    let terminal = loop {
        let events = tokio::select! {
               biased;
               _=s.cancel.cancelled(),if !interrupted=>{interrupted=true;deadline=tokio::time::Instant::now()+Duration::from_secs(10);protocol.interrupt()},
               _=tokio::time::sleep_until(deadline)=>protocol.disconnected(),
               result=tools.join_next(),if !tools.is_empty()=>{let (thread,turn,call,receipt)=match result{Some(Ok(r))=>r,_=>break (SessionState::Unknown,String::new())};let (success,output,images)=match receipt{Ok(r)=>(true,r.output,r.images),Err(reason) if reason=="host_operation_unavailable"=>(false,json!({"error":"resident_tool_unavailable"}),vec![]),Err(_)=>{s.cancel.cancel();continue;}};match protocol.tool_receipt(CodexReceipt{identity:s.identity.clone(),thread_id:thread,turn_id:turn,call_id:call,success,output,images}){Ok(frame)=>vec![CodexEvent::Send(frame)],Err(_)=>{if interrupted{continue;}break (SessionState::Unknown,String::new());}}},
        frame=transport.receive()=>match frame{Ok(frame)=>match protocol.receive(frame){Ok(events)=>events,Err(_)=>break (if model_started{SessionState::Unknown}else{SessionState::Failed},String::new())},Err(_)=>protocol.disconnected()},
               };
        *s.cli_binding.lock().await = (
            protocol.thread_id().map(str::to_owned),
            protocol.turn_id().map(str::to_owned),
        );
        let mut done = None;
        for event in events {
            match event {
                CodexEvent::Send(frame) => {
                    if frame["method"] == "turn/start" {
                        model_started = true;
                    }
                    if transport.send(&frame).await.is_err() {
                        done = Some((SessionState::Unknown, String::new()));
                        break;
                    }
                }
                CodexEvent::TextDelta { text, .. } => {
                    let mut output = s.text.lock().await;
                    if output.len() + text.len() > 1024 * 1024 {
                        done = Some((SessionState::Unknown, String::new()));
                        break;
                    }
                    output.push_str(&text);
                }
                CodexEvent::ToolRequest {
                    identity,
                    thread_id,
                    turn_id,
                    call_id,
                    name,
                    arguments,
                } => {
                    if identity != s.identity || tools.len() >= 32 {
                        done = Some((SessionState::Unknown, String::new()));
                        break;
                    }
                    s.queue
                        .bindings
                        .lock()
                        .await
                        .insert(call_id.clone(), (thread_id.clone(), turn_id.clone()));
                    let executor = executor.clone();
                    let token = s.cancel.clone();
                    tools.spawn(async move {
                        let receipt = executor
                            .execute(HostToolContext {
                                identity,
                                execution: ToolExecutionContext {
                                    call: ToolCall {
                                        tool_call_id: call_id.clone(),
                                        tool_name: name,
                                        input: arguments,
                                        provider_executed: None,
                                        dynamic: None,
                                        thought_signature: None,
                                    },
                                    cancellation: token,
                                },
                            })
                            .await;
                        (thread_id, turn_id, call_id, receipt)
                    });
                }
                CodexEvent::Terminal { state, reply } => done = Some((state, reply)),
            }
        }
        if let Some(done) = done {
            break done;
        }
    };
    tools.abort_all();
    while tools.join_next().await.is_some() {}
    transport.cancel();
    transport.wait_closed().await;
    Ok(if !model_started && terminal.0 == SessionState::Unknown {
        (SessionState::Failed, String::new())
    } else {
        terminal
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    const MOCK: &str = r#"#!/usr/bin/python3
import json,os,sys
disabled=any(a.startswith('mcp_servers={') for a in sys.argv)
features={k:False for k in ['plugins','apps','hooks','multi_agent','multi_agent_v2','image_generation','shell_tool']}
if disabled and os.environ.get('USER')=='unsafe': features['shell_tool']=True
config={'features':features,'agents':{'enabled':False},'notify':[],'web_search':'live','cli_auth_credentials_store':'file','mcp_oauth_credentials_store':'file','mcp_servers':{'fixture.server':{'enabled':not disabled}}}
def send(v): print(json.dumps(v),flush=True)
for line in sys.stdin:
 f=json.loads(line);m=f.get('method');i=f.get('id')
 if m:
  with open('mock-audit.txt','a') as audit:audit.write(m+'\n')
 if m=='initialize':send({'id':i,'result':{}})
 elif m=='config/read':send({'id':i,'result':{'config':config}})
 elif m in ('thread/start','thread/resume'):send({'id':i,'result':{'thread':{'id':'thread'}}})
 elif m=='turn/start':
  send({'id':i,'result':{'turn':{'id':'turn'}}})
  send({'id':'tool-request','method':'item/tool/call','params':{'threadId':'thread','turnId':'turn','callId':'call','tool':'move','arguments':{'target':'chair'}}})
 elif m=='turn/interrupt':send({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'interrupted'}}})
 elif i=='tool-request' and 'result' in f:
  with open('mock-tool-content.json','w') as content:json.dump(f['result']['contentItems'],content)
  send({'method':'item/agentMessage/delta','params':{'threadId':'thread','turnId':'turn','itemId':'final','delta':'done'}})
  send({'method':'item/completed','params':{'threadId':'thread','turnId':'turn','item':{'id':'final','type':'agentMessage','phase':'final_answer','text':'done'}}})
  send({'method':'turn/completed','params':{'threadId':'thread','turn':{'id':'turn','status':'completed'}}})
"#;
    async fn setup(unsafe_config: bool) -> (CliService, Value, PathBuf) {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-cli-service-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let executable = root.join("private-mock-cli");
        std::fs::write(&executable, MOCK).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        db.call(|store|{agent_scheduler::request(&mut store.connection,"agent_loop_configure",&json!({"worldID":"w","residentScope":"s","hostSessionID":"h","hourlyLimit":6,"minimumWakeIntervalSeconds":1}))?;store.connection.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','event','{}','claimed','run','h')",[]).map_err(|_|"storage_unavailable")?;Ok(())}).await.unwrap();
        let p = json!({"worldID":"w","residentScope":"s","hostSessionID":"h","runID":"run","eventID":"event","executable":executable,"arguments":arguments(&[]).unwrap(),"environment":{"USER":if unsafe_config{"unsafe"}else{"fixture"}},"root":root,"cwd":root,"input":[{"type":"text","text":"move","text_elements":[]}],"tools":[{"name":"move","description":"move","effect":"write","inputSchema":{"type":"object","properties":{"target":{"type":"string"}},"required":["target"]}}]});
        (CliService::new(db), p, root)
    }
    async fn wait(service: &CliService, p: &Value, phase: Option<&str>) -> Value {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let state = service.request("agent_cli_read", p).await.unwrap();
                if let Some(phase) = phase {
                    if state["pendingTools"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .any(|v| v["phase"] == phase)
                    {
                        return state;
                    }
                } else if ["completed", "failed", "cancelled", "unknown"]
                    .contains(&state["state"].as_str().unwrap())
                {
                    return state;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .unwrap()
    }
    fn pending(state: &Value, phase: &str) -> Value {
        state["pendingTools"]
            .as_array()
            .unwrap()
            .iter()
            .find(|v| v["phase"] == phase)
            .unwrap()
            .clone()
    }
    #[tokio::test]
    async fn private_mock_dual_config_real_ledger_receipt_and_terminal() {
        let (service, p, root) = setup(false).await;
        service.request("agent_cli_start", &p).await.unwrap();
        let proposal = pending(&wait(&service, &p, Some("authorize")).await, "authorize");
        assert_eq!(proposal["eventID"], "event");
        let n: i64 = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row("SELECT count(*) FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(n, 0);
        let mut approval = proposal;
        approval["decision"] = json!("approved");
        approval["operationID"] = json!("trusted-operation");
        let mut wrong = approval.clone();
        wrong["turnID"] = json!("other");
        assert!(service
            .request("agent_cli_authorize", &wrong)
            .await
            .is_err());
        service
            .request("agent_cli_authorize", &approval)
            .await
            .unwrap();
        assert_eq!(
            service
                .request("agent_cli_authorize", &approval)
                .await
                .unwrap()["duplicate"],
            true
        );
        let execute = pending(&wait(&service, &p, Some("execute")).await, "execute");
        let durable: String = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row("SELECT state FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(durable, "inflight");
        let mut receipt = execute;
        receipt["status"] = json!("completed");
        receipt["output"] = json!({"ok":true});
        wrong = receipt.clone();
        wrong["operationID"] = json!("wrong");
        assert!(service
            .request("agent_cli_tool_receipt", &wrong)
            .await
            .is_err());
        service
            .request("agent_cli_tool_receipt", &receipt)
            .await
            .unwrap();
        assert_eq!(
            service
                .request("agent_cli_tool_receipt", &receipt)
                .await
                .unwrap()["duplicate"],
            true
        );
        let done = wait(&service, &p, None).await;
        assert_eq!(done["state"], "completed");
        assert_eq!(done["text"], "done");
        assert_eq!(done["threadID"], "thread");
        let stored: Option<String> = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row(
                        "SELECT thread FROM world_cli_threads WHERE world='w' AND scope='s'",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(stored.as_deref(), Some("thread"));
        assert_eq!(done["turnID"], "turn");
        let audit = std::fs::read_to_string(root.join("mock-audit.txt")).unwrap();
        assert_eq!(audit.lines().filter(|s| *s == "config/read").count(), 2);
        assert_eq!(audit.lines().filter(|s| *s == "turn/start").count(), 1);
        assert!(service.request("agent_cli_start", &p).await.is_err());
        let expected = tools_digest(&p["tools"]).unwrap();
        let stored_digest: String = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row(
                        "SELECT tool_digest FROM world_cli_threads WHERE world='w' AND scope='s'",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(stored_digest, expected);
        // A new claimed turn must resume the actual stored thread despite schema key order.
        service.db.call(|store| {
            store.connection.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','event-reordered','{}','claimed','run-reordered','h')", []).map_err(|_| "storage_unavailable")?;
            Ok(())
        }).await.unwrap();
        let mut next = p.clone();
        next["runID"] = json!("run-reordered");
        next["eventID"] = json!("event-reordered");
        next["tools"] = reverse_objects(&p["tools"]);
        assert_ne!(next["tools"].to_string(), p["tools"].to_string());
        service.request("agent_cli_start", &next).await.unwrap();
        wait(&service, &next, Some("authorize")).await;
        service.request("agent_cli_cancel", &next).await.unwrap();
        assert_eq!(wait(&service, &next, None).await["state"], "cancelled");
        let audit = std::fs::read_to_string(root.join("mock-audit.txt")).unwrap();
        assert_eq!(audit.lines().filter(|s| *s == "thread/resume").count(), 1);
        service.db.call(|store| {
            store.connection.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','event-changed','{}','claimed','run-changed','h')", []).map_err(|_| "storage_unavailable")?;
            Ok(())
        }).await.unwrap();
        next["runID"] = json!("run-changed");
        next["eventID"] = json!("event-changed");
        next["tools"][0]["inputSchema"]["properties"]["target"]["type"] = json!("number");
        assert_eq!(
            service.request("agent_cli_start", &next).await.unwrap_err(),
            "agent_cli_registry_changed"
        );
        assert_eq!(
            std::fs::read_to_string(root.join("mock-audit.txt")).unwrap(),
            audit
        );
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    fn reverse_objects(value: &Value) -> Value {
        match value {
            Value::Object(map) => Value::Object(
                map.iter()
                    .rev()
                    .map(|(k, v)| (k.clone(), reverse_objects(v)))
                    .collect(),
            ),
            Value::Array(items) => Value::Array(items.iter().map(reverse_objects).collect()),
            _ => value.clone(),
        }
    }
    #[test]
    fn tools_digest_sorts_nested_objects_but_preserves_arrays_and_numbers() {
        let tools = json!([{"name":"a","inputSchema":{"properties":{"x":{"enum":[1,2],"type":"number"}},"type":"object"}},{"name":"b"}]);
        assert_eq!(tools_digest(&tools), tools_digest(&reverse_objects(&tools)));
        let mut changed = tools.clone();
        changed.as_array_mut().unwrap().reverse();
        assert_ne!(tools_digest(&tools), tools_digest(&changed));
        changed = tools.clone();
        changed[0]["inputSchema"]["properties"]["x"]["enum"][0] = json!(1.0);
        assert_ne!(tools_digest(&tools), tools_digest(&changed));
    }
    #[tokio::test]
    async fn private_mock_receives_native_tool_image_and_changed_image_conflicts() {
        let (service, p, root) = setup(false).await;
        service.request("agent_cli_start", &p).await.unwrap();
        let mut approval = pending(&wait(&service, &p, Some("authorize")).await, "authorize");
        approval["decision"] = json!("approved");
        approval["operationID"] = json!("trusted-operation");
        service
            .request("agent_cli_authorize", &approval)
            .await
            .unwrap();
        let mut receipt = pending(&wait(&service, &p, Some("execute")).await, "execute");
        receipt["status"] = json!("completed");
        receipt["output"] = json!({"visible":true});
        let png="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+c3x8AAAAASUVORK5CYII=";
        receipt["images"] = json!([{"mediaType":"image/png","base64":png}]);
        let mut invalid = receipt.clone();
        invalid["images"][0]["mediaType"] = json!("image/jpeg");
        assert_eq!(
            service
                .request("agent_cli_tool_receipt", &invalid)
                .await
                .unwrap_err(),
            "agent_cli_invalid_image"
        );
        service
            .request("agent_cli_tool_receipt", &receipt)
            .await
            .unwrap();
        assert_eq!(
            service
                .request("agent_cli_tool_receipt", &receipt)
                .await
                .unwrap()["duplicate"],
            true
        );
        let mut changed = receipt.clone();
        changed["images"][0]["base64"] =
            json!(base64::engine::general_purpose::STANDARD.encode(b"\x89PNG\r\n\x1a\nchanged"));
        assert_eq!(
            service
                .request("agent_cli_tool_receipt", &changed)
                .await
                .unwrap_err(),
            "agent_cli_receipt_conflict"
        );
        assert_eq!(wait(&service, &p, None).await["state"], "completed");
        let content: Value =
            serde_json::from_slice(&std::fs::read(root.join("mock-tool-content.json")).unwrap())
                .unwrap();
        assert_eq!(content[0]["type"], "inputText");
        assert_eq!(content[1]["type"], "inputImage");
        assert_eq!(
            content[1]["imageUrl"],
            format!("data:image/png;base64,{png}")
        );
        let stored: String = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row(
                        "SELECT receipt FROM agent_tool_calls WHERE call='call'",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert!(stored.contains("sha256"));
        assert!(!stored.contains(png));
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn unknown_host_receipt_interrupts_cli_without_continue_or_retry() {
        let (service, p, root) = setup(false).await;
        service.request("agent_cli_start", &p).await.unwrap();
        let mut approval = pending(&wait(&service, &p, Some("authorize")).await, "authorize");
        approval["decision"] = json!("approved");
        approval["operationID"] = json!("trusted-operation");
        service
            .request("agent_cli_authorize", &approval)
            .await
            .unwrap();
        let mut receipt = pending(&wait(&service, &p, Some("execute")).await, "execute");
        receipt["status"] = json!("unknown");
        receipt["output"] = json!({"unknown":true});
        service
            .request("agent_cli_tool_receipt", &receipt)
            .await
            .unwrap();
        assert_eq!(wait(&service, &p, None).await["state"], "unknown");
        let stored: Option<String> = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row(
                        "SELECT thread FROM world_cli_threads WHERE world='w' AND scope='s'",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(stored, None);
        let audit = std::fs::read_to_string(root.join("mock-audit.txt")).unwrap();
        assert!(audit.lines().any(|v| v == "turn/interrupt"));
        assert!(!root.join("mock-tool-content.json").exists());
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn continuity_is_claim_bound_import_once_and_reset_blocks_legacy_resurrection() {
        let (service, p, root) = setup(false).await;
        let mut query = p.clone();
        query["continuity"] = json!(true);
        assert_eq!(
            service.request("agent_cli_read", &query).await.unwrap()["freshSession"],
            true
        );
        query["importLegacyThreadID"] = json!("legacy-native-thread");
        assert_eq!(
            service.request("agent_cli_read", &query).await.unwrap()["threadID"],
            "legacy-native-thread"
        );
        query["importLegacyThreadID"] = json!("unrelated-replacement");
        assert_eq!(
            service.request("agent_cli_read", &query).await.unwrap()["threadID"],
            "legacy-native-thread"
        );
        let mut stale = query.clone();
        stale["hostSessionID"] = json!("stale");
        assert_eq!(
            service.request("agent_cli_read", &stale).await,
            Err("agent_cli_stale_session")
        );
        assert!(service.request("agent_cli_reset", &stale).await.is_err());
        assert_eq!(
            service.request("agent_cli_reset", &p).await.unwrap()["reset"],
            true
        );
        assert_eq!(
            service.request("agent_cli_read", &query).await.unwrap()["freshSession"],
            true
        );
        let mut unclaimed = query.clone();
        unclaimed["runID"] = json!("another-run");
        assert_eq!(
            service.request("agent_cli_read", &unclaimed).await,
            Err("agent_cli_run_not_claimed")
        );
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn effective_unsafe_second_config_never_starts_model() {
        let (service, p, root) = setup(true).await;
        service.request("agent_cli_start", &p).await.unwrap();
        assert_eq!(wait(&service, &p, None).await["state"], "failed");
        let audit = std::fs::read_to_string(root.join("mock-audit.txt")).unwrap();
        assert!(!audit.lines().any(|v| v == "turn/start"));
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn cancel_authorization_confirms_real_interrupt_without_dispatch() {
        let (service, p, root) = setup(false).await;
        service.request("agent_cli_start", &p).await.unwrap();
        wait(&service, &p, Some("authorize")).await;
        service.request("agent_cli_cancel", &p).await.unwrap();
        assert_eq!(wait(&service, &p, None).await["state"], "cancelled");
        let n: i64 = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row("SELECT count(*) FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(n, 0);
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn cancel_dispatched_tool_remains_unknown_and_cannot_replay() {
        let (service, p, root) = setup(false).await;
        service.request("agent_cli_start", &p).await.unwrap();
        let mut approval = pending(&wait(&service, &p, Some("authorize")).await, "authorize");
        approval["decision"] = json!("approved");
        approval["operationID"] = json!("trusted-operation");
        service
            .request("agent_cli_authorize", &approval)
            .await
            .unwrap();
        wait(&service, &p, Some("execute")).await;
        service.request("agent_cli_cancel", &p).await.unwrap();
        assert_eq!(wait(&service, &p, None).await["state"], "unknown");
        assert!(service.request("agent_cli_start", &p).await.is_err());
        let state: String = service
            .db
            .call(|store| {
                store
                    .connection
                    .query_row("SELECT state FROM agent_tool_calls", [], |r| r.get(0))
                    .map_err(|_| "storage_unavailable")
            })
            .await
            .unwrap();
        assert_eq!(state, "unknown");
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[tokio::test]
    async fn policy_is_exact_and_environment_has_no_inheritance() {
        let (service, mut p, root) = setup(false).await;
        p["arguments"]
            .as_array_mut()
            .unwrap()
            .push(json!("--dangerously-bypass-approvals-and-sandbox"));
        assert_eq!(
            service.request("agent_cli_start", &p).await.unwrap_err(),
            "agent_cli_unsafe_arguments"
        );
        let env=environment(&json!({"PATH":"/custom/bin:/usr/bin","OPENAI_API_KEY":"must-not-inherit","CODEX_EXEC_SERVER_URL":"remote"})).unwrap();
        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert_eq!(env["CODEX_EXEC_SERVER_URL"], "none");
        assert!(env["PATH"]
            .starts_with("/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"));
        drop(service);
        std::fs::remove_dir_all(root).unwrap();
    }
}
