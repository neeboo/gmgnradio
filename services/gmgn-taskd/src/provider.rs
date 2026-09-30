use crate::{
    files,
    model::{self, Job, Result, MODEL_LIMIT, PNG_LIMIT},
};
use base64::Engine;
use reqwest::{Client, Method};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{future::Future, path::Path, pin::Pin, time::Duration};

/// Boxed future so [`PropProvider`] stays object safe (`Arc<dyn PropProvider>`)
/// while each backend keeps writing plain `async fn` bodies. `Send` is required
/// because the daemon steps tasks on spawned Tokio workers.
pub type ProviderFuture<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub fn client() -> Result<Client> {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .timeout(Duration::from_secs(60))
        .connect_timeout(Duration::from_secs(15))
        .retry(reqwest::retry::never())
        .build()
        .map_err(|_| "http_unavailable")
}
async fn load(
    client: &Client,
    method: Method,
    url: String,
    token: Option<&str>,
    body: Option<Value>,
    key: Option<&str>,
    limit: usize,
) -> Result<Vec<u8>> {
    let mut req = client.request(method, &url);
    if let Some(token) = token {
        req = req.bearer_auth(token);
    }
    if let Some(body) = body {
        req = req.json(&body);
    }
    if let Some(key) = key {
        req = req.header("Idempotency-Key", key);
    }
    let mut response = req.send().await.map_err(|_| "network_unavailable")?;
    if !response.status().is_success() {
        return Err(match response.status().as_u16() {
            401 | 403 => "authentication_required",
            300..=399 => "redirect_rejected",
            400 | 409 | 422 => "request_rejected",
            _ => "remote_unavailable",
        });
    }
    if response.url().as_str() != url || response.content_length().is_some_and(|n| n > limit as u64)
    {
        return Err("response_too_large_or_unsafe");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "network_unavailable")? {
        if bytes.len() + chunk.len() > limit {
            return Err("response_too_large_or_unsafe");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
/// The wire layer behind [`RemoteHTTPProvider::submit`]/`status`/`cancel`: the
/// exact pre-trait implementation, kept verbatim as the reference the
/// fixture-driven regression test compares the trait path against.
pub async fn request(
    client: &Client,
    job: &Job,
    token: &str,
    submit: bool,
    cancel: bool,
) -> Result<Value> {
    let (method, url, body, key) = if submit {
        let path = job.image_path.clone();
        let bytes = tokio::task::spawn_blocking(move || files::read(Path::new(&path), PNG_LIMIT))
            .await
            .map_err(|_| "storage_unavailable")??;
        model::validate_png(&bytes)?;
        if model::digest(&bytes) != job.image_sha256 {
            return Err("image_integrity_failed");
        }
        (
            Method::POST,
            format!("{}/v1/jobs", job.endpoint),
            Some(
                json!({"image_base64":base64::engine::general_purpose::STANDARD.encode(bytes),"name":job.name,"source":job.source,"height_meters":job.height_meters}),
            ),
            Some(job.idempotency_key.as_str()),
        )
    } else {
        let id = model::remote_id(job.receipt.as_ref().ok_or("missing_receipt")?)?;
        if cancel {
            (
                Method::POST,
                format!("{}/v1/jobs/{}/cancel", job.endpoint, id),
                Some(json!({})),
                None,
            )
        } else {
            (
                Method::GET,
                format!("{}/v1/jobs/{}", job.endpoint, id),
                None,
                None,
            )
        }
    };
    let bytes = load(client, method, url, Some(token), body, key, 1024 * 1024).await?;
    if bytes.windows(token.len()).any(|w| w == token.as_bytes()) {
        return Err("invalid_response");
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| "invalid_response")?;
    if contains_secret(&value, token) {
        return Err("invalid_response");
    }
    model::receipt(&value, job)?;
    Ok(value)
}
pub fn contains_secret(value: &Value, token: &str) -> bool {
    match value {
        Value::String(s) => s.contains(token),
        Value::Array(a) => a.iter().any(|v| contains_secret(v, token)),
        Value::Object(m) => m
            .iter()
            .any(|(k, v)| k.contains(token) || contains_secret(v, token)),
        _ => false,
    }
}
pub async fn download(client: &Client, job: &Job, token: &str) -> Result<Vec<u8>> {
    let receipt = job.receipt.as_ref().ok_or("missing_receipt")?;
    let id = model::remote_id(receipt)?;
    let expected_path = format!("/v1/jobs/{}/model.glb", id);
    let expected = format!("{}{}", job.endpoint, expected_path);
    let actual = receipt["result"]["model_url"]
        .as_str()
        .ok_or("unsafe_download")?;
    if actual != expected_path && actual != expected {
        return Err("unsafe_download");
    }
    let bytes = load(
        client,
        Method::GET,
        expected,
        Some(token),
        None,
        None,
        MODEL_LIMIT,
    )
    .await?;
    model::validate_glb(&bytes, receipt)?;
    Ok(bytes)
}

/// Optional capability block that a `/health` response may carry at
/// `provider`. Every field is optional and every field is additive: a backend
/// that never sends the block (the DGX service shipped today) parses to
/// `ProviderCapabilities::default()`, which refuses nothing and therefore keeps
/// today's behaviour byte for byte.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct ProviderCapabilities {
    /// Stable backend identity, e.g. `remote-http`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    /// Backend family, e.g. `remote_http` or `local_mlx`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    /// Backend self-report. Absent means "usable" (today's behaviour).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ready: Option<bool>,
    /// Readable reason when `ready` is false. Never a credential.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// Pipeline stages the backend owns, e.g. `submit`/`cancel`/`fetch_model`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub stages: Option<Vec<String>>,
    /// Largest accepted input edge in pixels. Absent means no declared limit;
    /// the contract-wide 2048 px PNG bound in `model::validate_png` still holds.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_input_px: Option<u32>,
    /// Expected wall clock for one artifact, in seconds. Advisory only.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub est_seconds: Option<f64>,
    /// Whether the daemon must upload the image bytes with the request.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub uploads_data: Option<bool>,
    /// Free-form admission/quota block. Opaque to the daemon.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub quota: Option<Value>,
}

impl ProviderCapabilities {
    /// A missing or null `ready` is not a refusal: that is exactly how every
    /// backend behaved before the block existed.
    pub fn is_ready(&self) -> bool {
        self.ready.unwrap_or(true)
    }
    /// A missing `max_input_px` declares no limit, so the caller falls back to
    /// the contract-wide PNG bound alone.
    pub fn accepts_input_px(&self, px: u32) -> bool {
        self.max_input_px.is_none_or(|max| px <= max)
    }
}

/// Parses `/health` with the shipped contract first (`status == "api_ready"`
/// and nested `generation.ready`), then layers the optional `provider` block on
/// top. Only the block itself is new; without it the result is the default
/// capability set, so an existing DGX service is never refused for a missing
/// field.
pub fn health(value: &Value) -> Result<ProviderCapabilities> {
    if value["status"].as_str() != Some("api_ready") {
        return Err("provider_not_ready");
    }
    if value["generation"]["ready"].as_bool() != Some(true) {
        return Err("generation_not_ready");
    }
    match value.get("provider") {
        None | Some(Value::Null) => Ok(ProviderCapabilities::default()),
        Some(block) => capabilities(block),
    }
}

fn capabilities(block: &Value) -> Result<ProviderCapabilities> {
    let object = block.as_object().ok_or("invalid_provider_capabilities")?;
    let text = |key: &str| -> Result<Option<String>> {
        match object.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(s)) if !s.is_empty() && s.chars().count() <= 200 => Ok(Some(s.clone())),
            Some(Value::String(_)) => Err("invalid_provider_capabilities"),
            _ => Err("invalid_provider_capabilities"),
        }
    };
    let flag = |key: &str| -> Result<Option<bool>> {
        match object.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::Bool(b)) => Ok(Some(*b)),
            _ => Err("invalid_provider_capabilities"),
        }
    };
    let stages = match object.get("stages") {
        None | Some(Value::Null) => None,
        Some(Value::Array(items)) if items.len() <= 32 => {
            let mut parsed = Vec::with_capacity(items.len());
            for item in items {
                match item.as_str() {
                    Some(s) if !s.is_empty() && s.chars().count() <= 64 => parsed.push(s.to_owned()),
                    _ => return Err("invalid_provider_capabilities"),
                }
            }
            Some(parsed)
        }
        _ => return Err("invalid_provider_capabilities"),
    };
    let max_input_px = match object.get("max_input_px") {
        None | Some(Value::Null) => None,
        Some(Value::Number(number)) => Some(
            number
                .as_u64()
                .filter(|n| (1..=16384).contains(n))
                .ok_or("invalid_provider_capabilities")? as u32,
        ),
        _ => return Err("invalid_provider_capabilities"),
    };
    let est_seconds = match object.get("est_seconds") {
        None | Some(Value::Null) => None,
        Some(Value::Number(number)) => {
            let seconds = number.as_f64().ok_or("invalid_provider_capabilities")?;
            if !seconds.is_finite() || !(0.0..=86_400.0).contains(&seconds) {
                return Err("invalid_provider_capabilities");
            }
            Some(seconds)
        }
        _ => return Err("invalid_provider_capabilities"),
    };
    let quota = match object.get("quota") {
        None | Some(Value::Null) => None,
        Some(value) if value.is_object() => Some(value.clone()),
        _ => return Err("invalid_provider_capabilities"),
    };
    Ok(ProviderCapabilities {
        id: text("id")?,
        kind: text("kind")?,
        ready: flag("ready")?,
        reason: text("reason")?,
        stages,
        max_input_px,
        est_seconds,
        uploads_data: flag("uploads_data")?,
        quota,
    })
}

/// `GET /health` for a target backend. Read-only and never part of a task run.
/// The bearer header is only attached when the caller actually holds a
/// credential for that origin, so a local backend without auth is probed
/// unauthenticated instead of sending `Bearer `.
async fn probe_health(
    client: &Client,
    endpoint: &str,
    token: Option<&str>,
) -> Result<ProviderCapabilities> {
    let url = format!("{}/health", endpoint);
    let bytes = load(client, Method::GET, url, token, None, None, 1024 * 1024).await?;
    if let Some(token) = token {
        if bytes.windows(token.len()).any(|w| w == token.as_bytes()) {
            return Err("invalid_response");
        }
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| "invalid_response")?;
    if token.is_some_and(|token| contains_secret(&value, token)) {
        return Err("invalid_response");
    }
    health(&value)
}

/// Everything the daemon needs from a generation backend. The daemon owns
/// scheduling, cancellation bookkeeping, integrity checking and local storage;
/// a backend only owns the four remote calls plus its advertised capabilities.
pub trait PropProvider: Send + Sync {
    /// Static self-description of the backend this daemon is bound to.
    fn capabilities(&self) -> ProviderCapabilities;
    /// Reads a target backend's `/health` and negotiates its declared
    /// capabilities.
    fn probe<'a>(
        &'a self,
        endpoint: &'a str,
        token: Option<&'a str>,
    ) -> ProviderFuture<'a, Result<ProviderCapabilities>>;
    /// Opens one job. `job.idempotency_key` is the backend-side dedup key.
    fn submit<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>>;
    /// Polls one job by the remote id carried in `job.receipt`.
    fn status<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>>;
    /// Requests cancellation of the remote job.
    fn cancel<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>>;
    /// Streams the verified GLB. Implementations must re-check integrity.
    fn fetch_model<'a>(&'a self, job: &'a Job, token: &'a str)
        -> ProviderFuture<'a, Result<Vec<u8>>>;
}

/// The only backend shipped so far: the remote job API the DGX service speaks.
/// Every method delegates to the unchanged `request`/`download` functions
/// above, so the wire behaviour is identical to the pre-trait daemon.
pub struct RemoteHTTPProvider {
    client: Client,
}

impl RemoteHTTPProvider {
    pub fn new(client: Client) -> Self {
        Self { client }
    }
}

impl PropProvider for RemoteHTTPProvider {
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            id: Some("remote-http".into()),
            kind: Some("remote_http".into()),
            ready: Some(true),
            reason: None,
            stages: Some(
                ["submit", "status", "cancel", "fetch_model"]
                    .iter()
                    .map(|stage| (*stage).to_owned())
                    .collect(),
            ),
            max_input_px: Some(2048),
            est_seconds: None,
            uploads_data: Some(true),
            quota: None,
        }
    }
    fn probe<'a>(
        &'a self,
        endpoint: &'a str,
        token: Option<&'a str>,
    ) -> ProviderFuture<'a, Result<ProviderCapabilities>> {
        Box::pin(async move { probe_health(&self.client, endpoint, token).await })
    }
    fn submit<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>> {
        Box::pin(async move { request(&self.client, job, token, true, false).await })
    }
    fn status<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>> {
        Box::pin(async move { request(&self.client, job, token, false, false).await })
    }
    fn cancel<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>> {
        Box::pin(async move { request(&self.client, job, token, false, true).await })
    }
    fn fetch_model<'a>(
        &'a self,
        job: &'a Job,
        token: &'a str,
    ) -> ProviderFuture<'a, Result<Vec<u8>>> {
        Box::pin(async move { download(&self.client, job, token).await })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };

    fn fixture_path(name: &str) -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures")
            .join(name)
    }

    fn read_fixture(name: &str) -> Value {
        let path = fixture_path(name);
        let bytes = std::fs::read(&path)
            .unwrap_or_else(|e| panic!("missing recorded fixture {}: {e}", path.display()));
        serde_json::from_slice(&bytes)
            .unwrap_or_else(|e| panic!("malformed recorded fixture {}: {e}", path.display()))
    }

    /// One-shot HTTP/1.1 server: records the raw request bytes, then answers with
    /// the canned response and closes. Every provider call opens exactly one
    /// connection (redirects are never followed), so one accept per call is
    /// enough and keeps the recording unambiguous.
    pub(crate) struct Captured {
        head: String,
        body: String,
    }

    pub(crate) async fn serve_once(
        status: u16,
        extra: Vec<(&'static str, String)>,
        body: Vec<u8>,
    ) -> (String, tokio::task::JoinHandle<Captured>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let origin = format!("http://127.0.0.1:{port}");
        let handle = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut raw = Vec::new();
            let mut buffer = [0u8; 8192];
            let mut head_end = None;
            let mut content_length = 0usize;
            loop {
                let count = socket.read(&mut buffer).await.unwrap();
                if count == 0 {
                    break;
                }
                raw.extend_from_slice(&buffer[..count]);
                if head_end.is_none() {
                    if let Some(at) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                        head_end = Some(at + 4);
                        let head = String::from_utf8_lossy(&raw[..at]).to_ascii_lowercase();
                        content_length = head
                            .lines()
                            .find_map(|line| line.strip_prefix("content-length:"))
                            .and_then(|value| value.trim().parse().ok())
                            .unwrap_or(0);
                    }
                }
                if head_end.is_some_and(|at| raw.len() >= at + content_length) {
                    break;
                }
            }
            let at = head_end.expect("request head");
            let head = String::from_utf8_lossy(&raw[..at]).into_owned();
            let request_body = String::from_utf8_lossy(&raw[at..]).into_owned();
            let reason = match status {
                200 => "OK",
                302 => "Found",
                400 => "Bad Request",
                401 => "Unauthorized",
                403 => "Forbidden",
                409 => "Conflict",
                422 => "Unprocessable Entity",
                _ => "Error",
            };
            let mut response = format!("HTTP/1.1 {status} {reason}\r\n");
            for (key, value) in extra {
                response.push_str(&format!("{key}: {value}\r\n"));
            }
            response.push_str(&format!(
                "Content-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            ));
            let mut bytes = response.into_bytes();
            bytes.extend_from_slice(&body);
            let _ = socket.write_all(&bytes).await;
            let _ = socket.flush().await;
            Captured { head, body: request_body }
        });
        (origin, handle)
    }

    /// Canonical view of what actually went over the socket: request line, all
    /// headers (lowercased, sorted) with the ephemeral host normalised, and the
    /// exact body bytes.
    pub(crate) fn wire(captured: &Captured, origin: &str) -> Value {
        let mut lines = captured.head.lines();
        let request = lines.next().unwrap_or_default();
        let mut parts = request.split(' ');
        let method = parts.next().unwrap_or_default();
        let path = parts.next().unwrap_or_default();
        let host = origin.trim_start_matches("http://");
        let mut headers: Vec<String> = lines
            .filter(|line| !line.trim().is_empty())
            .map(|line| line.trim_end().to_ascii_lowercase().replace(host, "{{HOST}}"))
            .collect();
        headers.sort();
        json!({"method": method, "path": path, "headers": headers, "body": captured.body})
    }

    fn temp_root() -> std::path::PathBuf {
        let root =
            std::env::temp_dir().join(format!("gmgn-provider-{}", uuid::Uuid::new_v4().simple()));
        files::directory(&root).unwrap();
        root
    }

    fn job_from_fixture(fixture: &Value, root: &std::path::Path) -> Job {
        let png = base64::engine::general_purpose::STANDARD
            .decode(fixture["png_base64"].as_str().unwrap())
            .unwrap();
        let job = &fixture["job"];
        let id = job["id"].as_str().unwrap().to_owned();
        let path = root.join(format!("{id}.png"));
        files::publish(&path, &png).unwrap();
        Job {
            id,
            name: job["name"].as_str().unwrap().into(),
            endpoint: "http://127.0.0.1:1".into(),
            image_path: path.to_string_lossy().into(),
            image_sha256: fixture["png_sha256"].as_str().unwrap().into(),
            height_meters: job["height_meters"].as_f64().unwrap(),
            source: serde_json::from_value(job["source"].clone()).unwrap(),
            idempotency_key: job["idempotency_key"].as_str().unwrap().into(),
            receipt: None,
            local_model_path: None,
            last_error: None,
            backend_stage: "queued".into(),
            cancel_requested: false,
            context: None,
            source_wish_id: job["sourceWishID"].as_str().map(str::to_owned),
            workflow_profile: job["workflowProfile"].as_str().map(str::to_owned),
        }
    }

    /// Records today's exact wire behaviour into `tests/fixtures/remote_http.json`.
    /// Run explicitly with `GMGN_RECORD_TASKD_FIXTURES=1 cargo test record_remote_wire`.
    #[tokio::test]
    async fn record_remote_wire() {
        if std::env::var("GMGN_RECORD_TASKD_FIXTURES").as_deref() != Ok("1") {
            return;
        }
        let fixture = read_fixture("remote_http.json");
        let token = fixture["token"].as_str().unwrap();
        let receipt = fixture["receipt"].clone();
        let glb = base64::engine::general_purpose::STANDARD
            .decode(fixture["glb_base64"].as_str().unwrap())
            .unwrap();
        let root = temp_root();
        let client = client().unwrap();

        let mut job = job_from_fixture(&fixture, &root);
        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            serde_json::to_vec(&receipt).unwrap(),
        )
        .await;
        job.endpoint = origin.clone();
        let submitted = request(&client, &job, token, true, false).await.unwrap();
        let submit_wire = wire(&server.await.unwrap(), &origin);

        let mut polling = job.clone();
        polling.receipt = Some(receipt.clone());
        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            serde_json::to_vec(&receipt).unwrap(),
        )
        .await;
        polling.endpoint = origin.clone();
        let status = request(&client, &polling, token, false, false).await.unwrap();
        let status_wire = wire(&server.await.unwrap(), &origin);

        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            serde_json::to_vec(&receipt).unwrap(),
        )
        .await;
        polling.endpoint = origin.clone();
        let cancelled = request(&client, &polling, token, false, true).await.unwrap();
        let cancel_wire = wire(&server.await.unwrap(), &origin);

        let (origin, server) = serve_once(200, vec![], glb.clone()).await;
        polling.endpoint = origin.clone();
        let model = download(&client, &polling, token).await.unwrap();
        let download_wire = wire(&server.await.unwrap(), &origin);

        let recorded = json!({
            "token": token,
            "job": fixture["job"].clone(),
            "png_base64": fixture["png_base64"].clone(),
            "png_sha256": fixture["png_sha256"].clone(),
            "glb_base64": fixture["glb_base64"].clone(),
            "glb_sha256": model::digest(&model),
            "remote_id": fixture["remote_id"].clone(),
            "receipt": receipt,
            "wire": {
                "submit": submit_wire,
                "status": status_wire,
                "cancel": cancel_wire,
                "download": download_wire,
            },
            "expected": {
                "submit_receipt": submitted,
                "status_receipt": status,
                "cancel_receipt": cancelled,
                "model_sha256": model::digest(&model),
                "model_bytes": model.len(),
            }
        });
        std::fs::create_dir_all(fixture_path("")).unwrap();
        let mut encoded = serde_json::to_vec_pretty(&recorded).unwrap();
        encoded.push(b'\n');
        std::fs::write(fixture_path("remote_http.json"), encoded).unwrap();
        std::fs::remove_dir_all(&root).unwrap();
    }
    fn json_headers() -> Vec<(&'static str, String)> {
        vec![("Content-Type", "application/json".into())]
    }

    /// Reports the exact JSON pointer where two receipts disagree, so a
    /// per-field regression names the drifting field instead of dumping blobs.
    fn assert_fields_equal(path: &str, left: &Value, right: &Value) {
        match (left, right) {
            (Value::Object(a), Value::Object(b)) => {
                let mut keys: Vec<&String> = a.keys().chain(b.keys()).collect();
                keys.sort();
                keys.dedup();
                for key in keys {
                    let pointer = format!(
                        "{path}/{}",
                        key.replace('~', "~0").replace('/', "~1")
                    );
                    assert_fields_equal(
                        &pointer,
                        a.get(key).unwrap_or(&Value::Null),
                        b.get(key).unwrap_or(&Value::Null),
                    );
                }
            }
            (Value::Array(a), Value::Array(b)) => {
                assert_eq!(a.len(), b.len(), "field {path} length");
                for (index, (x, y)) in a.iter().zip(b).enumerate() {
                    assert_fields_equal(&format!("{path}/{index}"), x, y);
                }
            }
            _ => assert_eq!(left, right, "field {path}"),
        }
    }

    /// The regression lock: the trait path must put the exact same bytes on the
    /// wire as the pre-trait implementation recorded, and must hand back a
    /// receipt that is equal field by field.
    #[tokio::test]
    async fn remote_trait_wire_and_receipt_match_the_recorded_fixture() {
        let recorded = read_fixture("remote_http.json");
        let token = recorded["token"].as_str().unwrap();
        let glb = base64::engine::general_purpose::STANDARD
            .decode(recorded["glb_base64"].as_str().unwrap())
            .unwrap();
        let provider = RemoteHTTPProvider::new(client().unwrap());
        let root = temp_root();

        let mut job = job_from_fixture(&recorded, &root);
        let (origin, server) = serve_once(
            200,
            json_headers(),
            serde_json::to_vec(&recorded["receipt"]).unwrap(),
        )
        .await;
        job.endpoint = origin.clone();
        let submitted = provider.submit(&job, token).await.unwrap();
        assert_eq!(wire(&server.await.unwrap(), &origin), recorded["wire"]["submit"]);
        assert_fields_equal("", &submitted, &recorded["expected"]["submit_receipt"]);
        assert_fields_equal("", &submitted, &recorded["receipt"]);

        let mut polling = job.clone();
        polling.receipt = Some(recorded["receipt"].clone());

        let (origin, server) = serve_once(
            200,
            json_headers(),
            serde_json::to_vec(&recorded["receipt"]).unwrap(),
        )
        .await;
        polling.endpoint = origin.clone();
        let status = provider.status(&polling, token).await.unwrap();
        assert_eq!(wire(&server.await.unwrap(), &origin), recorded["wire"]["status"]);
        assert_fields_equal("", &status, &recorded["expected"]["status_receipt"]);

        let (origin, server) = serve_once(
            200,
            json_headers(),
            serde_json::to_vec(&recorded["receipt"]).unwrap(),
        )
        .await;
        polling.endpoint = origin.clone();
        let cancelled = provider.cancel(&polling, token).await.unwrap();
        assert_eq!(wire(&server.await.unwrap(), &origin), recorded["wire"]["cancel"]);
        assert_fields_equal("", &cancelled, &recorded["expected"]["cancel_receipt"]);

        let (origin, server) = serve_once(200, vec![], glb.clone()).await;
        polling.endpoint = origin.clone();
        let model = provider.fetch_model(&polling, token).await.unwrap();
        assert_eq!(wire(&server.await.unwrap(), &origin), recorded["wire"]["download"]);
        assert_eq!(model, glb);
        assert_eq!(
            model::digest(&model),
            recorded["expected"]["model_sha256"].as_str().unwrap()
        );
        assert_eq!(model.len() as u64, recorded["expected"]["model_bytes"].as_u64().unwrap());

        // The daemon's own description of this backend is static, not probed.
        let capabilities = provider.capabilities();
        assert_eq!(capabilities.kind.as_deref(), Some("remote_http"));
        assert!(capabilities.is_ready());
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// Error classification is part of the contract too: the trait must return
    /// the same code the pre-trait free function does, for every status family.
    #[tokio::test]
    async fn remote_error_taxonomy_is_unchanged_and_shared_by_the_trait() {
        let recorded = read_fixture("remote_http.json");
        let token = recorded["token"].as_str().unwrap();
        let provider = RemoteHTTPProvider::new(client().unwrap());
        for (status, expected) in [
            (401u16, "authentication_required"),
            (403, "authentication_required"),
            (302, "redirect_rejected"),
            (400, "request_rejected"),
            (409, "request_rejected"),
            (422, "request_rejected"),
            (500, "remote_unavailable"),
        ] {
            let root = temp_root();
            let mut job = job_from_fixture(&recorded, &root);
            let (origin, server) = serve_once(
                status,
                vec![("Location", "/leak".into())],
                b"{}".to_vec(),
            )
            .await;
            job.endpoint = origin.clone();
            let via_trait = provider.submit(&job, token).await;
            let _ = server.await;

            let mut job = job_from_fixture(&recorded, &root);
            let (origin, server) = serve_once(
                status,
                vec![("Location", "/leak".into())],
                b"{}".to_vec(),
            )
            .await;
            job.endpoint = origin.clone();
            let via_free = request(&client().unwrap(), &job, token, true, false).await;
            let _ = server.await;

            assert_eq!(via_trait, Err(expected), "status {status}");
            assert_eq!(via_trait, via_free, "status {status} diverged from the free function");
        }
    }

    /// Missing `provider` block (and missing optional fields inside a present
    /// block) must behave exactly as today: usable, no declared limit, no
    /// refusal.
    #[test]
    fn health_without_the_provider_block_is_exactly_todays_behaviour() {
        let legacy = read_fixture("health_legacy.json");
        let capabilities = health(&legacy).unwrap();
        assert_eq!(capabilities, ProviderCapabilities::default());
        assert!(capabilities.is_ready());
        assert!(capabilities.accepts_input_px(2048));
        assert!(capabilities.accepts_input_px(65_535));

        let bare = json!({"status":"api_ready","generation":{"ready":true},"provider":{}});
        assert_eq!(health(&bare).unwrap(), ProviderCapabilities::default());

        assert_eq!(
            health(&json!({"status":"starting","generation":{"ready":true}})),
            Err("provider_not_ready")
        );
        assert_eq!(
            health(&json!({"status":"api_ready","generation":{"ready":false}})),
            Err("generation_not_ready")
        );
    }

    /// A present block decides readiness and input limits by field.
    #[test]
    fn health_provider_block_is_honoured_when_present() {
        let present = read_fixture("health_provider.json");
        let capabilities = health(&present).unwrap();
        assert_eq!(capabilities.id.as_deref(), Some("dgx-trellis"));
        assert_eq!(capabilities.kind.as_deref(), Some("remote_http"));
        assert_eq!(capabilities.ready, Some(true));
        assert_eq!(
            capabilities.stages.as_deref(),
            Some(["submit", "status", "cancel", "fetch_model"].map(String::from).as_slice())
        );
        assert_eq!(capabilities.max_input_px, Some(512));
        assert_eq!(capabilities.est_seconds, Some(420.0));
        assert_eq!(capabilities.uploads_data, Some(true));
        assert_eq!(capabilities.quota, Some(json!({"jobs_per_hour": 6})));
        assert!(capabilities.accepts_input_px(512));
        assert!(!capabilities.accepts_input_px(513));

        let not_ready = json!({"status":"api_ready","generation":{"ready":true},"provider":{"ready":false,"reason":"gpu busy"}});
        let capabilities = health(&not_ready).unwrap();
        assert!(!capabilities.is_ready());
        assert_eq!(capabilities.reason.as_deref(), Some("gpu busy"));

        assert_eq!(
            health(&json!({"status":"api_ready","generation":{"ready":true},"provider":{"max_input_px":"big"}})),
            Err("invalid_provider_capabilities")
        );
    }

    /// Negotiation over the wire: the probe reads `/health` with the credential
    /// only when one exists, and reports the parsed capabilities.
    #[tokio::test]
    async fn probe_reads_health_and_negotiates_over_the_wire() {
        let provider = RemoteHTTPProvider::new(client().unwrap());
        let legacy = read_fixture("health_legacy.json");
        let (origin, server) = serve_once(
            200,
            json_headers(),
            serde_json::to_vec(&legacy).unwrap(),
        )
        .await;
        let capabilities = provider
            .probe(&origin, Some("offline-secret-do-not-persist"))
            .await
            .unwrap();
        let seen = wire(&server.await.unwrap(), &origin);
        assert_eq!(seen["method"], "GET");
        assert_eq!(seen["path"], "/health");
        assert_eq!(capabilities, ProviderCapabilities::default());

        let present = read_fixture("health_provider.json");
        let (origin, server) = serve_once(
            200,
            json_headers(),
            serde_json::to_vec(&present).unwrap(),
        )
        .await;
        let capabilities = provider.probe(&origin, None).await.unwrap();
        let seen = wire(&server.await.unwrap(), &origin);
        assert!(!seen["headers"]
            .as_array()
            .unwrap()
            .iter()
            .any(|header| header.as_str().unwrap().starts_with("authorization")));
        assert_eq!(capabilities.max_input_px, Some(512));

        let (origin, server) = serve_once(
            200,
            json_headers(),
            br#"{"status":"ok","backend":"mlx"}"#.to_vec(),
        )
        .await;
        assert_eq!(
            provider.probe(&origin, None).await,
            Err("provider_not_ready")
        );
        let _ = server.await;
    }
}

#[cfg(test)]
pub(crate) mod testwire {
    /// One-shot loopback HTTP recorder shared with the daemon tests.
    pub(crate) use super::tests::serve_once;
}
