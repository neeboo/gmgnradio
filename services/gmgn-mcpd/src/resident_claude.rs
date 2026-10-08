//! Restricted Claude JSONL adapter. This never uses the default MCP read exemption.
use crate::resident_claude_schema::{self as schema, SchemaError};
use gmgn_protocol::resident_grant::{
    forbidden_tool, uuid_v4, ClaudeError, ClaudeGrant, GrantIdentity, PinnedGrant,
};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    io::Read,
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio::{
    io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt},
    task::JoinSet,
};

const INPUT_LIMIT: usize = 1_048_576;
const OUTPUT_LIMIT: usize = 2_097_152;
const GRANT_LIMIT: usize = 65_536;
const HOST_LIMIT: usize = 4_194_304;
const TEXT_LIMIT: usize = 262_144;
const IMAGE_LIMIT: usize = 1_048_576;
const CONCURRENCY: usize = 4;

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

fn private_read(path: &Path, limit: usize) -> Result<Vec<u8>, &'static str> {
    if !path.is_absolute() {
        return Err("invalid private input");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
        let parent = std::fs::symlink_metadata(path.parent().ok_or("invalid private input")?)
            .map_err(|_| "invalid private input")?;
        if !parent.is_dir()
            || parent.mode() & 0o777 != 0o700
            || parent.uid() != unsafe { libc::geteuid() }
        {
            return Err("invalid private input");
        }
        let mut options = std::fs::OpenOptions::new();
        options
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        let file = options.open(path).map_err(|_| "invalid private input")?;
        let metadata = file.metadata().map_err(|_| "invalid private input")?;
        if !metadata.is_file()
            || metadata.mode() & 0o777 != 0o600
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.len() > limit as u64
        {
            return Err("invalid private input");
        }
        let mut bytes = Vec::new();
        file.take((limit + 1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|_| "invalid private input")?;
        if bytes.len() > limit {
            return Err("invalid private input");
        }
        Ok(bytes)
    }
    #[cfg(not(unix))]
    {
        let _ = limit;
        Err("unsupported private input")
    }
}

struct ReadGrant {
    grant: ClaudeGrant,
    endpoint: String,
    tools: Value,
}
fn read_grant(path: &Path) -> Result<ReadGrant, ClaudeError> {
    let bytes = private_read(path, GRANT_LIMIT).map_err(|_| ClaudeError::InvalidGrant)?;
    let v: Value = serde_json::from_slice(&bytes).map_err(|_| ClaudeError::InvalidGrant)?;
    let text = |key: &str| {
        v[key]
            .as_str()
            .map(str::to_owned)
            .ok_or(ClaudeError::InvalidGrant)
    };
    if v["protocol"] != 1 {
        return Err(ClaudeError::InvalidGrant);
    }
    let identity = GrantIdentity {
        world_id: text("worldID")?,
        scope_id: text("scope")?,
        session_id: text("hostSessionID")?,
        run_id: text("runID")?,
        event_id: text("eventID")?,
    };
    let secret = text("secret")?;
    let endpoint = v["endpoint"]["url"]
        .as_str()
        .ok_or(ClaudeError::InvalidGrant)?
        .to_owned();
    if v["endpoint"]["version"] != 2
        || v["endpoint"]["token"].as_str() != Some(secret.as_str())
        || !uuid_v4(&secret)
        || !valid_endpoint(&endpoint)
    {
        return Err(ClaudeError::InvalidGrant);
    }
    let tools = v["tools"].as_array().ok_or(ClaudeError::InvalidGrant)?;
    if tools.len() > 128
        || tools
            .iter()
            .any(|t| t["name"].as_str().is_none() || t["canonical"].as_str().is_none())
    {
        return Err(ClaudeError::InvalidGrant);
    }
    Ok(ReadGrant {
        grant: ClaudeGrant {
            identity,
            secret,
            round: text("round")?,
            expires_at_ms: v["expiresAt"].as_u64().ok_or(ClaudeError::InvalidGrant)?,
            armed: v["state"] == "armed",
        },
        endpoint,
        tools: Value::Array(tools.clone()),
    })
}
fn valid_endpoint(url: &str) -> bool {
    let Some(port) = url
        .strip_prefix("http://127.0.0.1:")
        .and_then(|s| s.strip_suffix("/rpc"))
    else {
        return false;
    };
    !port.starts_with('0')
        && port.bytes().all(|b| b.is_ascii_digit())
        && port.parse::<u16>().is_ok_and(|p| p > 0)
}

struct Adapter {
    path: PathBuf,
    pinned: PinnedGrant,
    endpoint: String,
    grant_tools: Value,
    tools: Value,
    schemas: BTreeMap<String, Value>,
    client: reqwest::Client,
}
impl Adapter {
    fn open(path: PathBuf, catalog: &Path) -> Result<Self, &'static str> {
        let initial = read_grant(&path).map_err(|_| "invalid grant")?;
        let pinned = PinnedGrant::pin(&initial.grant, now_ms()).map_err(|_| "invalid grant")?;
        let tools: Value = serde_json::from_slice(&private_read(catalog, INPUT_LIMIT)?)
            .map_err(|_| "invalid catalog")?;
        let list = tools.as_array().ok_or("invalid catalog")?;
        if list.is_empty() || list.len() > 128 {
            return Err("invalid catalog");
        }
        let mut schemas = BTreeMap::new();
        for tool in list {
            let name = tool["name"].as_str().ok_or("invalid catalog")?;
            let canonical = tool
                .get("canonical")
                .and_then(Value::as_str)
                .unwrap_or(name);
            if name.is_empty()
                || name.len() > 64
                || !name.bytes().enumerate().all(|(i, b)| {
                    b == b'_' || b.is_ascii_alphabetic() || (i > 0 && b.is_ascii_digit())
                })
                || forbidden_tool(name)
                || forbidden_tool(canonical)
                || !tool["description"].is_string()
                || tool["inputSchema"]["type"] != "object"
                || schema::supported(&tool["inputSchema"], 0).is_err()
                || schemas
                    .insert(name.into(), tool["inputSchema"].clone())
                    .is_some()
            {
                return Err("invalid catalog");
            }
            if !initial
                .tools
                .as_array()
                .unwrap()
                .iter()
                .any(|t| t["name"] == name && t["canonical"] == canonical)
            {
                return Err("invalid catalog");
            }
        }
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(120))
            .build()
            .map_err(|_| "bridge unavailable")?;
        Ok(Self {
            path,
            pinned,
            endpoint: initial.endpoint,
            grant_tools: initial.tools,
            tools,
            schemas,
            client,
        })
    }
    fn verify(&self, name: &str) -> Result<ReadGrant, &'static str> {
        let current = read_grant(&self.path).map_err(|_| "tool session is not authorized")?;
        self.pinned.verify(&current.grant, now_ms()).map_err(|e| {
            if e == ClaudeError::GrantExpired {
                "tool session expired"
            } else {
                "tool session is not authorized"
            }
        })?;
        if current.endpoint != self.endpoint
            || current.tools != self.grant_tools
            || !current
                .tools
                .as_array()
                .unwrap()
                .iter()
                .any(|t| t["name"] == name)
        {
            return Err("tool session is not authorized");
        }
        Ok(current)
    }
    async fn call(&self, id: Value, params: Value) -> Value {
        let Some(name) = params["name"].as_str() else {
            return rpc_error(id, -32602, "invalid tool call parameters");
        };
        let args = params.get("arguments").cloned().unwrap_or(json!({}));
        if !args.is_object() {
            return rpc_error(id, -32602, "invalid tool call parameters");
        }
        let Some(original) = self.schemas.get(name) else {
            return tool_error(id, "unknown tool");
        };
        if let Err(e) = schema::validate(original, &args) {
            return tool_error(
                id,
                if e == SchemaError::Unsupported {
                    "tool arguments are not supported"
                } else {
                    "invalid tool arguments"
                },
            );
        }
        let before = match self.verify(name) {
            Ok(g) => g,
            Err(e) => return tool_error(id, e),
        };
        let reply = self.host_call(&before, name, args).await;
        // Always reread before exposing even a late error: revoked work never returns results.
        if let Err(e) = self.verify(name) {
            return tool_error(id, e);
        }
        let reply = match reply {
            Ok(v) => v,
            Err(_) => return tool_error(id, "tool bridge unavailable"),
        };
        if reply["ok"] == true {
            let mut content = vec![
                json!({"type":"text","text":bound_text(reply.get("data").unwrap_or(&Value::Null))}),
            ];
            if let Some(images) = reply.get("images") {
                let images = match image_content(images) {
                    Ok(images) => images,
                    Err(()) => return tool_error(id, "tool bridge unavailable"),
                };
                content.extend(images);
            } else if let Some(image) = reply["image"]["base64"]
                .as_str()
                .filter(|s| !s.is_empty() && s.len() <= IMAGE_LIMIT)
            {
                content.push(json!({"type":"image","data":image,"mimeType":"image/png"}));
            }
            rpc_result(id, json!({"content":content,"isError":false}))
        } else if reply["error"]["code"] == "tool_error" && reply.get("data").is_some() {
            rpc_result(
                id,
                json!({"content":[{"type":"text","text":bound_text(&reply["data"])}],"isError":true}),
            )
        } else {
            tool_error(
                id,
                safe_error(reply["error"]["code"].as_str().unwrap_or("")),
            )
        }
    }
    async fn host_call(
        &self,
        grant: &ReadGrant,
        name: &str,
        arguments: Value,
    ) -> Result<Value, ()> {
        let body = serde_json::to_vec(&json!({"v":1,"callId":format!("mcp-{}",unique_call_id()),"name":name,"arguments":arguments})).map_err(|_| ())?;
        let mut response = self
            .client
            .post(&grant.endpoint)
            .header("Authorization", format!("Bearer {}", grant.grant.secret))
            .header("Content-Type", "application/json")
            .header("Connection", "close")
            .body(body)
            .send()
            .await
            .map_err(|_| ())?;
        if ![200, 403].contains(&response.status().as_u16())
            || !response
                .headers()
                .get("content-type")
                .and_then(|v| v.to_str().ok())
                .is_some_and(|s| {
                    s.split(';')
                        .next()
                        .is_some_and(|s| s.trim().eq_ignore_ascii_case("application/json"))
                })
            || response
                .content_length()
                .is_some_and(|n| n > HOST_LIMIT as u64)
        {
            return Err(());
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| ())? {
            if bytes.len() + chunk.len() > HOST_LIMIT {
                return Err(());
            }
            bytes.extend_from_slice(&chunk);
        }
        let value: Value = serde_json::from_slice(&bytes).map_err(|_| ())?;
        if !value.is_object() {
            return Err(());
        }
        Ok(value)
    }
}
fn unique_call_id() -> String {
    uuid::Uuid::new_v4().to_string()
}
fn image_content(images: &Value) -> Result<Vec<Value>, ()> {
    let images = images.as_array().ok_or(())?;
    if images.len() > 4 {
        return Err(());
    }
    let mut total = 0usize;
    let mut content = Vec::new();
    for image in images {
        let data = image["base64"].as_str().ok_or(())?;
        let mime = image["mimeType"].as_str().ok_or(())?;
        total = total.checked_add(data.len()).ok_or(())?;
        if data.is_empty()
            || total > IMAGE_LIMIT
            || !["image/png", "image/jpeg", "image/gif", "image/webp"].contains(&mime)
        {
            return Err(());
        }
        content.push(json!({"type":"image","data":data,"mimeType":mime}));
    }
    Ok(content)
}
fn bound_text(v: &Value) -> String {
    let text = v
        .as_str()
        .map(str::to_owned)
        .unwrap_or_else(|| serde_json::to_string(v).unwrap_or_else(|_| "null".into()));
    if text.len() <= TEXT_LIMIT {
        return text;
    }
    const MARKER: &str = "\n[truncated]";
    let mut end = TEXT_LIMIT - MARKER.len();
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}{MARKER}", &text[..end])
}
fn safe_error(code: &str) -> &'static str {
    match code {
        "grant_revoked" => "tool session is not authorized",
        "tool_session_expired" => "tool session expired",
        "invalid_call_id" => "invalid tool call",
        "tool_not_allowed" => "unknown tool",
        "invalid_arguments" => "invalid tool arguments",
        "schema_unsupported" => "tool arguments are not supported",
        "host_execution_timeout" => "tool bridge timed out",
        "tool_error" => "tool execution failed",
        _ => "tool bridge unavailable",
    }
}
fn rpc_error(id: Value, code: i32, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}
fn rpc_result(id: Value, result: Value) -> Value {
    json!({"jsonrpc":"2.0","id":id,"result":result})
}
fn tool_error(id: Value, text: &str) -> Value {
    rpc_result(
        id,
        json!({"content":[{"type":"text","text":text}],"isError":true}),
    )
}

enum Line {
    Bytes(Vec<u8>),
    TooLarge,
    End,
}
#[derive(Default)]
struct InputState {
    bytes: Vec<u8>,
    too_large: bool,
}
async fn next_line<R: AsyncBufRead + Unpin>(
    input: &mut R,
    state: &mut InputState,
) -> std::io::Result<Line> {
    loop {
        let available = input.fill_buf().await?;
        if available.is_empty() {
            return Ok(Line::End);
        }
        let newline = available.iter().position(|b| *b == b'\n');
        let count = newline.map(|n| n + 1).unwrap_or(available.len());
        if !state.too_large {
            let piece = &available[..newline.unwrap_or(count)];
            if state.bytes.len() + piece.len() > INPUT_LIMIT {
                state.too_large = true;
                state.bytes.clear();
            } else {
                state.bytes.extend_from_slice(piece);
            }
        }
        input.consume(count);
        if newline.is_some() {
            let result = if state.too_large {
                Line::TooLarge
            } else {
                Line::Bytes(std::mem::take(&mut state.bytes))
            };
            state.too_large = false;
            return Ok(result);
        }
    }
}
async fn write<W: AsyncWrite + Unpin>(output: &mut W, response: Value) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(&response)?;
    if bytes.len() > OUTPUT_LIMIT {
        bytes = serde_json::to_vec(&rpc_error(
            response["id"].clone(),
            -32603,
            "response too large",
        ))?;
    }
    bytes.push(b'\n');
    output.write_all(&bytes).await?;
    output.flush().await
}
async fn serve<R: AsyncBufRead + Unpin, W: AsyncWrite + Unpin>(
    adapter: Arc<Adapter>,
    mut input: R,
    mut output: W,
) -> std::io::Result<()> {
    let mut calls = JoinSet::new();
    let mut input_state = InputState::default();
    loop {
        tokio::select! {
            completed=calls.join_next(), if !calls.is_empty() => {
                if let Some(Ok(response))=completed { write(&mut output,response).await?; }
            }
            line=next_line(&mut input,&mut input_state) => {
                let bytes=match line? { Line::End => { calls.abort_all(); return Ok(()); }, Line::TooLarge => { write(&mut output,rpc_error(Value::Null,-32700,"request too large")).await?; continue; }, Line::Bytes(b) => b };
                if bytes.iter().all(u8::is_ascii_whitespace) { continue; }
                let message:Value=match serde_json::from_slice(&bytes) { Ok(v)=>v,Err(_)=>{write(&mut output,rpc_error(Value::Null,-32700,"parse error")).await?;continue;} };
                if !message.is_object() || message["jsonrpc"]!="2.0" {write(&mut output,rpc_error(Value::Null,-32600,"invalid request")).await?;continue;}
                let Some(id)=message.get("id").cloned() else {continue;};
                if !(id.is_string() || id.as_i64().is_some() || id.as_u64().is_some() || id.as_f64().is_some_and(|n| n.is_finite() && n.fract()==0.0)) || !message["method"].is_string() {write(&mut output,rpc_error(Value::Null,-32600,"invalid request")).await?;continue;}
                if message.get("params").is_some_and(|v|!v.is_object()) {write(&mut output,rpc_error(id,-32602,"invalid params")).await?;continue;}
                let immediate=match message["method"].as_str().unwrap() {
                    "initialize" => Some(rpc_result(id.clone(),json!({"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"gmgn-resident-tools","version":"1.0.0"}}))),
                    "ping" => Some(rpc_result(id.clone(),json!({}))),
                    "tools/list" => Some(rpc_result(id.clone(),json!({"tools":adapter.tools}))),
                    "tools/call" if calls.len()>=CONCURRENCY => Some(tool_error(id.clone(),"tool bridge busy")),
                    "tools/call" => {let adapter=Arc::clone(&adapter);let params=message["params"].clone();calls.spawn(async move{adapter.call(id,params).await});None},
                    _=>Some(rpc_error(id.clone(),-32601,"method not found")),
                };
                if let Some(response)=immediate {write(&mut output,response).await?;}
            }
        }
    }
}

pub fn main(args: impl Iterator<Item = String>) -> std::process::ExitCode {
    let mut args = args;
    let mut grant = None;
    let mut tools = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--grant" => grant = args.next().map(PathBuf::from),
            "--tools" => tools = args.next().map(PathBuf::from),
            _ => return std::process::ExitCode::from(2),
        }
    }
    let (Some(grant), Some(tools)) = (grant, tools) else {
        return std::process::ExitCode::from(2);
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(r) => r,
        Err(_) => return std::process::ExitCode::FAILURE,
    };
    runtime.block_on(async {
        let adapter = match Adapter::open(grant, &tools) {
            Ok(a) => Arc::new(a),
            Err(_) => {
                eprintln!("gmgn-mcpd: resident bridge unavailable");
                return std::process::ExitCode::FAILURE;
            }
        };
        match serve(
            adapter,
            tokio::io::BufReader::new(tokio::io::stdin()),
            tokio::io::stdout(),
        )
        .await
        {
            Ok(()) => std::process::ExitCode::SUCCESS,
            Err(_) => std::process::ExitCode::FAILURE,
        }
    })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use tokio::io::{AsyncReadExt, BufReader};
    use tokio::sync::{mpsc, Semaphore};

    struct Fixture {
        root: PathBuf,
        grant: PathBuf,
        catalog: PathBuf,
        document: Value,
    }
    impl Fixture {
        fn new(port: u16) -> Self {
            let root = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("gmgn-claude-adapter-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&root).unwrap();
            std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
            let grant = root.join("grant.json");
            let catalog = root.join("tools.json");
            let secret = uuid::Uuid::new_v4().to_string();
            let document = json!({"protocol":1,"state":"armed","secret":secret,"round":"round","scope":"resident","worldID":"world","hostSessionID":"session","runID":"run","eventID":"event","expiresAt":now_ms()+60000,"endpoint":{"version":2,"url":format!("http://127.0.0.1:{port}/rpc"),"token":secret},"tools":[{"name":"read_world","canonical":"read_world"}]});
            let fixture = Self {
                root,
                grant,
                catalog,
                document,
            };
            fixture.write(&fixture.grant, &fixture.document);
            fixture.write(&fixture.catalog,&json!([{"name":"read_world","description":"world read","inputSchema":{"type":"object","properties":{"value":{"type":"integer"}},"additionalProperties":false}}]));
            fixture
        }
        fn write(&self, path: &Path, value: &Value) {
            std::fs::write(path, serde_json::to_vec(value).unwrap()).unwrap();
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        fn adapter(&self) -> Arc<Adapter> {
            Arc::new(Adapter::open(self.grant.clone(), &self.catalog).unwrap())
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    async fn host(
        count: usize,
        reply: Value,
        gate: Arc<Semaphore>,
    ) -> (u16, mpsc::Receiver<Vec<u8>>, tokio::task::JoinHandle<()>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (tx, rx) = mpsc::channel(count.max(1));
        let task = tokio::spawn(async move {
            let mut workers = JoinSet::new();
            for _ in 0..count {
                let (mut stream, _) = listener.accept().await.unwrap();
                let tx = tx.clone();
                let gate = gate.clone();
                let reply = reply.clone();
                workers.spawn(async move {
                    let mut bytes=Vec::new(); let mut block=[0u8;4096];
                    loop {
                        let n=stream.read(&mut block).await.unwrap(); assert!(n>0); bytes.extend_from_slice(&block[..n]); assert!(bytes.len()<=INPUT_LIMIT+8192);
                        if let Some(end)=bytes.windows(4).position(|w|w==b"\r\n\r\n") {
                            let header=String::from_utf8_lossy(&bytes[..end]).to_ascii_lowercase();
                            let len=header.lines().find_map(|l|l.strip_prefix("content-length: ")).unwrap().parse::<usize>().unwrap();
                            if bytes.len()>=end+4+len {break;}
                        }
                    }
                    tx.send(bytes).await.unwrap();
                    let _permit=gate.acquire().await.unwrap();
                    let body=serde_json::to_vec(&reply).unwrap();
                    let header=format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",body.len());
                    stream.write_all(header.as_bytes()).await.unwrap(); stream.write_all(&body).await.unwrap();
                });
            }
            while workers.join_next().await.is_some() {}
        });
        (port, rx, task)
    }
    async fn bounded<T>(future: impl std::future::Future<Output = T>) -> T {
        tokio::time::timeout(Duration::from_secs(5), future)
            .await
            .expect("bounded private fixture")
    }

    #[tokio::test]
    async fn read_tool_requires_grant_and_uses_only_native_flat_http() {
        let (port, mut requests, server) = host(
            1,
            json!({"ok":true,"data":{"actual":true},"images":[{"base64":"iVBORw0KGgo=","mimeType":"image/png"},{"base64":"/9j/","mimeType":"image/jpeg"}]}),
            Arc::new(Semaphore::new(1)),
        )
        .await;
        let f = Fixture::new(port);
        let adapter = f.adapter();
        let response = bounded(adapter.call(
            json!(1),
            json!({"name":"read_world","arguments":{"value":3}}),
        ))
        .await;
        assert_eq!(response["result"]["isError"], false);
        assert_eq!(response["result"]["content"][1]["mimeType"], "image/png");
        assert_eq!(response["result"]["content"][2]["mimeType"], "image/jpeg");
        let bytes = bounded(requests.recv()).await.unwrap();
        let end = bytes.windows(4).position(|w| w == b"\r\n\r\n").unwrap();
        let headers = String::from_utf8_lossy(&bytes[..end]);
        assert!(headers
            .to_ascii_lowercase()
            .starts_with("post /rpc http/1.1"));
        assert!(headers.contains(f.document["secret"].as_str().unwrap()));
        let body: Value = serde_json::from_slice(&bytes[end + 4..]).unwrap();
        assert_eq!(body["v"], 1);
        assert_eq!(body["name"], "read_world");
        assert_eq!(body["arguments"], json!({"value":3}));
        assert!(body["callId"].as_str().unwrap().starts_with("mcp-"));
        assert!(body.get("method").is_none());
        bounded(server).await.unwrap();
        let mut revoked = f.document.clone();
        revoked["state"] = json!("revoked");
        f.write(&f.grant, &revoked);
        let rejected = adapter.call(json!(2), json!({"name":"read_world"})).await;
        assert_eq!(rejected["result"]["isError"], true);
        assert_eq!(
            rejected["result"]["content"][0]["text"],
            "tool session is not authorized"
        );
    }

    #[tokio::test]
    async fn rotation_during_http_drops_late_output_and_never_rearms_old_process() {
        let gate = Arc::new(Semaphore::new(0));
        let (port, mut requests, server) = host(
            1,
            json!({"ok":true,"data":"must never escape"}),
            gate.clone(),
        )
        .await;
        let f = Fixture::new(port);
        let adapter = f.adapter();
        let worker = adapter.clone();
        let call =
            tokio::spawn(async move { worker.call(json!(1), json!({"name":"read_world"})).await });
        bounded(requests.recv()).await.unwrap();
        let mut next = f.document.clone();
        let secret = uuid::Uuid::new_v4().to_string();
        next["secret"] = json!(secret);
        next["endpoint"]["token"] = next["secret"].clone();
        next["round"] = json!("new-round");
        f.write(&f.grant, &next);
        gate.add_permits(1);
        let response = bounded(call).await.unwrap();
        assert_eq!(response["result"]["isError"], true);
        assert!(!response.to_string().contains("must never escape"));
        assert_eq!(
            adapter.call(json!(2), json!({"name":"read_world"})).await["result"]["isError"],
            true
        );
        bounded(server).await.unwrap();
    }

    #[tokio::test]
    async fn jsonl_four_calls_are_bounded_and_fifth_is_busy() {
        let gate = Arc::new(Semaphore::new(0));
        let (port, mut requests, server) =
            host(4, json!({"ok":true,"data":"done"}), gate.clone()).await;
        let f = Fixture::new(port);
        let adapter = f.adapter();
        let (client, transport) = tokio::io::duplex(16384);
        let (r, w) = tokio::io::split(transport);
        let service = tokio::spawn(serve(adapter, BufReader::new(r), w));
        let (r, mut w) = tokio::io::split(client);
        let mut reader = BufReader::new(r);
        for id in 1..=5 {
            w.write_all(format!("{{\"jsonrpc\":\"2.0\",\"id\":{id},\"method\":\"tools/call\",\"params\":{{\"name\":\"read_world\"}}}}\n").as_bytes()).await.unwrap();
        }
        let mut line = String::new();
        bounded(reader.read_line(&mut line)).await.unwrap();
        let response: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["id"], 5);
        assert_eq!(response["result"]["content"][0]["text"], "tool bridge busy");
        for _ in 0..4 {
            bounded(requests.recv()).await.unwrap();
        }
        gate.add_permits(4);
        for _ in 0..4 {
            line.clear();
            bounded(reader.read_line(&mut line)).await.unwrap();
            assert_eq!(
                serde_json::from_str::<Value>(&line).unwrap()["result"]["isError"],
                false
            );
        }
        w.shutdown().await.unwrap();
        bounded(service).await.unwrap().unwrap();
        bounded(server).await.unwrap();
    }

    #[tokio::test]
    async fn malformed_stdio_notifications_and_oversize_lines_do_not_dispatch() {
        let f = Fixture::new(1);
        let adapter = f.adapter();
        let (client, transport) = tokio::io::duplex(INPUT_LIMIT + 4096);
        let (r, w) = tokio::io::split(transport);
        let service = tokio::spawn(serve(adapter, BufReader::new(r), w));
        let (r, mut w) = tokio::io::split(client);
        let mut reader = BufReader::new(r);
        for bytes in [
            b"not json\n".to_vec(),
            b"{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}\n".to_vec(),
            b"{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":null}\n".to_vec(),
            vec![b'x'; INPUT_LIMIT + 1]
                .into_iter()
                .chain([b'\n'])
                .collect(),
        ] {
            w.write_all(&bytes).await.unwrap();
            let mut line = String::new();
            bounded(reader.read_line(&mut line)).await.unwrap();
            assert!(serde_json::from_str::<Value>(&line)
                .unwrap()
                .get("error")
                .is_some());
        }
        w.write_all(b"{\"jsonrpc\":\"2.0\",\"method\":\"tools/call\",\"params\":{\"name\":\"read_world\"}}\n{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"ping\"}\n").await.unwrap();
        let mut line = String::new();
        bounded(reader.read_line(&mut line)).await.unwrap();
        assert_eq!(serde_json::from_str::<Value>(&line).unwrap()["id"], 9);
        w.shutdown().await.unwrap();
        bounded(service).await.unwrap().unwrap();
    }

    #[test]
    fn grant_and_catalog_files_are_private_and_no_local_or_web_tools_register() {
        let f = Fixture::new(1);
        for name in ["shell", "mcp__x__read_file", "gmgn_web_fetch"] {
            f.write(&f.catalog,&json!([{"name":name,"description":"unsafe","inputSchema":{"type":"object","properties":{}}}]));
            assert!(Adapter::open(f.grant.clone(), &f.catalog).is_err());
        }
        std::fs::set_permissions(&f.grant, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_grant(&f.grant).is_err());
        std::fs::set_permissions(&f.grant, std::fs::Permissions::from_mode(0o600)).unwrap();
        let link = f.root.join("grant-link.json");
        std::os::unix::fs::symlink(&f.grant, &link).unwrap();
        assert!(read_grant(&link).is_err());
        let mut legacy = f.document.clone();
        legacy.as_object_mut().unwrap().remove("hostSessionID");
        f.write(&f.grant, &legacy);
        assert!(read_grant(&f.grant).is_err());
        for endpoint in [
            "https://127.0.0.1:1/rpc",
            "http://localhost:1/rpc",
            "http://127.0.0.1:0/rpc",
            "http://127.0.0.1:65536/rpc",
            "http://127.0.0.1:1/rpc?x=1",
        ] {
            assert!(!valid_endpoint(endpoint));
        }
    }

    #[tokio::test]
    async fn expired_scope_changed_and_removed_read_authorizations_fail_closed() {
        let f = Fixture::new(1);
        let adapter = f.adapter();
        for (field, value) in [
            ("scope", json!("other")),
            ("worldID", json!("other")),
            ("hostSessionID", json!("other")),
            ("runID", json!("other")),
            ("eventID", json!("other")),
            ("tools", json!([])),
            ("expiresAt", json!(now_ms() - 1)),
        ] {
            let mut changed = f.document.clone();
            changed[field] = value;
            f.write(&f.grant, &changed);
            let response = adapter.call(json!(1), json!({"name":"read_world"})).await;
            assert_eq!(response["result"]["isError"], true, "{field}");
        }
        f.write(&f.grant, &f.document);
        let invalid = adapter
            .call(
                json!(2),
                json!({"name":"read_world","arguments":{"value":true}}),
            )
            .await;
        assert_eq!(
            invalid["result"]["content"][0]["text"],
            "invalid tool arguments"
        );
        let text = bound_text(&json!("中".repeat(TEXT_LIMIT)));
        assert!(text.len() <= TEXT_LIMIT);
        assert!(text.ends_with("[truncated]"));
    }
    #[test]
    fn images_are_bounded_as_one_reply_not_per_image() {
        let half = "A".repeat(IMAGE_LIMIT / 2 + 1);
        assert!(image_content(
            &json!([{"base64":half,"mimeType":"image/png"},{"base64":half,"mimeType":"image/png"}])
        )
        .is_err());
        assert!(image_content(&json!([{"base64":"A","mimeType":"text/html"}])).is_err());
        assert!(image_content(&Value::Array(vec![
            json!({"base64":"A","mimeType":"image/png"});
            5
        ]))
        .is_err());
    }
}
