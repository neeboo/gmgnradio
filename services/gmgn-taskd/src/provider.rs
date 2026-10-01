use crate::{
    files,
    model::{
        self, Job, Result, SizeIntent, SizeIntentSupport, COLLIDER_LIMIT, MODEL_LIMIT, PNG_LIMIT,
    },
};
use base64::Engine;
use reqwest::{Client, Method};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    future::Future,
    path::Path,
    pin::Pin,
    sync::Mutex,
    time::{Duration, Instant},
};

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
/// 提交 body 的**唯一**构造点。
///
/// `intent` 是**协商之后**才可能非 `None` 的那一份（见
/// [`RemoteHTTPProvider::accepted_size_intent`]）：调用方拿不准时一律传 `None`，
/// 于是键根本不出现，线上字节与改造前逐位相同。
fn submit_body(job: &Job, image_base64: String, intent: Option<&SizeIntent>) -> Result<Value> {
    let mut body = json!({
        "image_base64": image_base64,
        "name": job.name,
        "source": job.source,
        "height_meters": job.height_meters,
    });
    if let Some(intent) = intent {
        // 形状只有一处定义（`SizeIntent` 自己），线格式与提交契约、落盘 JSON 同一份。
        body["size_intent"] =
            serde_json::to_value(intent).map_err(|_| "invalid_size_intent")?;
    }
    Ok(body)
}

/// The wire layer behind [`RemoteHTTPProvider::submit`]/`status`/`cancel`: the
/// exact pre-trait implementation, kept verbatim as the reference the
/// fixture-driven regression test compares the trait path against.
///
/// 唯一的增量是 `intent`：它只在**协商声明收得下**时非 `None`，而录制基准
/// （`record_remote_wire`）与所有不带意图的调用都传 `None` —— 所以"缺失 ⇒ 字节不变"
/// 这件事是由这一条签名保证的，不是靠约定。
pub async fn request(
    client: &Client,
    job: &Job,
    token: &str,
    submit: bool,
    cancel: bool,
    intent: Option<&SizeIntent>,
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
            Some(submit_body(
                job,
                base64::engine::general_purpose::STANDARD.encode(bytes),
                intent,
            )?),
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

/// 下载并核验**碰撞代理**。与 [`download`] 逐条同构：路径钉死在同一 origin 的固定任务
/// 路径上、禁重定向、上限由契约给出、字节按 `collision_sha256`/`collision_bytes` 核验。
///
/// 调用方只在回执**声明了**代理时才会走到这里（`model::declares_collision`）。所以
/// 回执没有碰撞字段的旧服务连一条请求都不会多出来 —— 与今天逐字节一致。
pub async fn download_collision(client: &Client, job: &Job, token: &str) -> Result<Vec<u8>> {
    let receipt = job.receipt.as_ref().ok_or("missing_receipt")?;
    let id = model::remote_id(receipt)?;
    let collision = model::collision_descriptor(&receipt["result"])?
        .ok_or("missing_collision_descriptor")?;
    let expected_path = format!("/v1/jobs/{}/collider.glb", id);
    let expected = format!("{}{}", job.endpoint, expected_path);
    if collision.url != expected_path && collision.url != expected {
        return Err("unsafe_download");
    }
    let bytes = load(
        client,
        Method::GET,
        expected,
        Some(token),
        None,
        None,
        COLLIDER_LIMIT,
    )
    .await?;
    model::validate_collider_glb(&bytes, receipt)?;
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
    /// 「收得下尺寸意图」的自报。**纯增量**：缺失 ⇒ `None` ⇒ 我们**不发**
    /// `size_intent`，提交字节与今天逐位相同（老 DGX 服务正是这种）。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub size_intent: Option<SizeIntentSupport>,
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
        size_intent: size_intent_support(block)?,
    })
}

/// `provider` 块里的 `size_intent` 声明。与块里其它字段同一条口径：**键缺失或 `null`
/// ⇒ `None`**（"没声明"就是"收不下"，这正是老服务）；**键在但不合法 ⇒
/// `invalid_provider_capabilities`**（那一份声明整块不可信，绝不当成"能力很强"）。
///
/// 单独一个函数是为了让 `/health` 的**准入**解析（[`health`]）与**能力**解析
/// （[`probe_size_intent`]）读的是同一份形状，不会漂成两套。
fn size_intent_support(block: &Value) -> Result<Option<SizeIntentSupport>> {
    match block.get("size_intent") {
        None | Some(Value::Null) => Ok(None),
        Some(value) => serde_json::from_value(value.clone())
            .map(Some)
            .map_err(|_| "invalid_provider_capabilities"),
    }
}

/// `GET /health` for a target backend, parsed to JSON. Read-only and never part
/// of a task run. The bearer header is only attached when the caller actually
/// holds a credential for that origin, so a local backend without auth is probed
/// unauthenticated instead of sending `Bearer `.
async fn read_health(client: &Client, endpoint: &str, token: Option<&str>) -> Result<Value> {
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
    Ok(value)
}

/// 准入判据：`status`/`generation.ready` 都要过，再看 `provider` 块。
async fn probe_health(
    client: &Client,
    endpoint: &str,
    token: Option<&str>,
) -> Result<ProviderCapabilities> {
    health(&read_health(client, endpoint, token).await?)
}

/// **只问能力**的一次探测：读 `/health` 的 `provider.size_intent`，但**不**把
/// "服务忙不忙"当成"收不收得下这个键"。
///
/// 为什么不复用 [`probe_health`]：`health()` 是**准入**判据（GPU 忙 ⇒
/// `generation_not_ready`），而协商问的是另一件事。若把两者混在一起，同一件任务在
/// Comfy 空闲时会带上轴、在忙时不带 —— 线上字节随机器负载漂移，那是最难查的一类不一致。
///
/// 任何失败（网络、非 200、JSON 不合法、`provider` 块不合法）都映射成 `None`：
/// **协商的问题绝不升级成任务失败**（fail-closed 的方向是"这条不发"，不是"提交不发"）。
async fn probe_size_intent(
    client: &Client,
    endpoint: &str,
    token: Option<&str>,
) -> Option<SizeIntentSupport> {
    let value = read_health(client, endpoint, token).await.ok()?;
    match value.get("provider") {
        None | Some(Value::Null) => None,
        Some(block) => size_intent_support(block).ok().flatten(),
    }
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
    /// Streams the verified **collision proxy** GLB. Only called when the receipt
    /// declared one, so a backend that never returns collision fields never sees
    /// this call. Implementations must re-check integrity.
    ///
    /// The default is a **visible refusal**, not a silent "no proxy": if a
    /// receipt declares a proxy and the bound backend cannot fetch it, the job
    /// must fail with a readable reason rather than quietly fall back to the yaw
    /// box (that fallback would change collision geometry behind the user's back).
    fn fetch_collision<'a>(&'a self, _job: &'a Job, _token: &'a str)
        -> ProviderFuture<'a, Result<Vec<u8>>> {
        Box::pin(async move { Err("collision_not_supported") })
    }
}

/// 尺寸意图协商结果的缓存时长。
///
/// 只有**带意图**的提交才会问一次 `/health`：没有意图的老任务连一个多出来的请求都不发。
/// 所以这个窗口只决定"DGX 补丁上线后多久自动生效"（不必改任何配置），不决定稳态开销
/// （每个 endpoint 最多每 60 s 一次）。缓存**正负都存**：老服务没有声明这件事本身也要记住，
/// 否则每一件带意图的任务都要多花一次往返去确认同一个"没有"。
const SIZE_INTENT_NEGOTIATION_TTL: Duration = Duration::from_secs(60);

/// The only backend shipped so far: the remote job API the DGX service speaks.
/// Every method delegates to the unchanged `request`/`download` functions
/// above, so the wire behaviour is identical to the pre-trait daemon.
pub struct RemoteHTTPProvider {
    client: Client,
    /// endpoint → 上一次协商到的 `size_intent` 声明（`None` = 问过了，收不下），
    /// 以及记下它的时刻。进程内共享，与 `daemon.rs` 里唯一那个 `Arc<dyn PropProvider>`
    /// 同寿命。
    size_intent: Mutex<HashMap<String, (Option<SizeIntentSupport>, Instant)>>,
}

impl RemoteHTTPProvider {
    pub fn new(client: Client) -> Self {
        Self {
            client,
            size_intent: Mutex::new(HashMap::new()),
        }
    }

    /// 这一条意图现在能不能发给这个 endpoint。
    ///
    /// 三道闸，任何一道不过就是 `None`（= 不发那个键，提交照常）：
    /// 1. 任务上**没有**意图 ⇒ 立刻返回，连一次 `/health` 都不发；
    /// 2. 缓存新鲜 ⇒ 直接用；
    /// 3. 否则尽力探一次 `/health`，失败/缺失/不合法一律当"收不下"，并把结论缓存起来。
    async fn accepted_size_intent(&self, job: &Job, token: &str) -> Option<SizeIntent> {
        let intent = job.size_intent?;
        // 独立作用域：`MutexGuard` 必须在任何 `.await` 之前析构，否则 future 不再是 Send。
        let cached = {
            let cache = self.size_intent.lock().ok()?;
            cache.get(&job.endpoint).cloned()
        };
        if let Some((support, at)) = cached {
            if at.elapsed() < SIZE_INTENT_NEGOTIATION_TTL {
                return support.filter(|support| support.accepts(&intent)).map(|_| intent);
            }
        }
        let support = probe_size_intent(&self.client, &job.endpoint, Some(token)).await;
        if let Ok(mut cache) = self.size_intent.lock() {
            cache.insert(job.endpoint.clone(), (support.clone(), Instant::now()));
        }
        support
            .filter(|support| support.accepts(&intent))
            .map(|_| intent)
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
                ["submit", "status", "cancel", "fetch_model", "fetch_collision"]
                    .iter()
                    .map(|stage| (*stage).to_owned())
                    .collect(),
            ),
            max_input_px: Some(2048),
            est_seconds: None,
            uploads_data: Some(true),
            quota: None,
            // 静态自述不替任何 endpoint 声明能力：这一位只由 `/health` 协商填。
            size_intent: None,
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
        Box::pin(async move {
            let intent = self.accepted_size_intent(job, token).await;
            request(&self.client, job, token, true, false, intent.as_ref()).await
        })
    }
    fn status<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>> {
        Box::pin(async move { request(&self.client, job, token, false, false, None).await })
    }
    fn cancel<'a>(&'a self, job: &'a Job, token: &'a str) -> ProviderFuture<'a, Result<Value>> {
        Box::pin(async move { request(&self.client, job, token, false, true, None).await })
    }
    fn fetch_model<'a>(
        &'a self,
        job: &'a Job,
        token: &'a str,
    ) -> ProviderFuture<'a, Result<Vec<u8>>> {
        Box::pin(async move { download(&self.client, job, token).await })
    }
    fn fetch_collision<'a>(
        &'a self,
        job: &'a Job,
        token: &'a str,
    ) -> ProviderFuture<'a, Result<Vec<u8>>> {
        Box::pin(async move { download_collision(&self.client, job, token).await })
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
            accept_one(&listener, status, extra, body).await
        });
        (origin, handle)
    }

    /// 同一端口上**按顺序**应答 N 个连接，逐条录下原始请求。
    ///
    /// 用在"一次 `submit()` 其实会先说一句 `/health`"的路径上：协商与提交必须落在
    /// **同一个 origin**，否则缓存键不同、录下来的也不是同一条链路。
    pub(crate) async fn serve_many(
        responses: Vec<(u16, Vec<(&'static str, String)>, Vec<u8>)>,
    ) -> (String, tokio::task::JoinHandle<Vec<Captured>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let origin = format!("http://127.0.0.1:{port}");
        let handle = tokio::spawn(async move {
            let mut captured = Vec::new();
            for (status, extra, body) in responses {
                captured.push(accept_one(&listener, status, extra, body).await);
            }
            captured
        });
        (origin, handle)
    }

    /// Accepts exactly one connection on an already-bound listener, records the
    /// request bytes, answers with the canned response and closes.
    ///
    /// `accept` 带超时：录制器与断言都靠"第 N 个连接真的来了"来表达事实，
    /// 期望的连接没来时必须**当场失败**，而不是把测试挂死到 CI 超时。
    async fn accept_one(
        listener: &TcpListener,
        status: u16,
        extra: Vec<(&'static str, String)>,
        body: Vec<u8>,
    ) -> Captured {
        let (mut socket, _) = tokio::time::timeout(Duration::from_secs(10), listener.accept())
            .await
            .expect("no further request arrived on this listener (a probe or call is missing)")
            .unwrap();
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
        Captured {
            head,
            body: request_body,
        }
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
            size_intent: job
                .get("sizeIntent")
                .filter(|value| !value.is_null())
                .and_then(|value| serde_json::from_value(value.clone()).ok()),
            source: serde_json::from_value(job["source"].clone()).unwrap(),
            idempotency_key: job["idempotency_key"].as_str().unwrap().into(),
            receipt: None,
            local_model_path: None,
            local_collision_path: None,
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
        let submitted = request(&client, &job, token, true, false, None).await.unwrap();
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
        let status = request(&client, &polling, token, false, false, None).await.unwrap();
        let status_wire = wire(&server.await.unwrap(), &origin);

        let (origin, server) = serve_once(
            200,
            vec![("Content-Type", "application/json".into())],
            serde_json::to_vec(&receipt).unwrap(),
        )
        .await;
        polling.endpoint = origin.clone();
        let cancelled = request(&client, &polling, token, false, true, None).await.unwrap();
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

    /// 碰撞代理的取回与模型**逐条同构**：同一 origin、钉死的任务路径、禁重定向、
    /// 声明字节数与摘要都要对得上。
    ///
    /// 关键断言是第一条：回执**没有**碰撞字段时 `download_collision` 连一条请求都不发
    /// —— 这也正是 `fetch_artifact` 的行为（它先问 `declares_collision`）。
    #[tokio::test]
    async fn collision_download_is_pinned_and_byte_verified_or_refused() {
        let recorded = read_fixture("remote_http.json");
        let token = recorded["token"].as_str().unwrap();
        let glb = base64::engine::general_purpose::STANDARD
            .decode(recorded["glb_base64"].as_str().unwrap())
            .unwrap();
        let provider = RemoteHTTPProvider::new(client().unwrap());
        let root = temp_root();
        let mut job = job_from_fixture(&recorded, &root);
        let mut receipt = recorded["receipt"].clone();

        // 1) 没有碰撞字段：直接是 `missing_collision_descriptor`，不发任何请求。
        job.receipt = Some(receipt.clone());
        assert_eq!(
            provider.fetch_collision(&job, token).await,
            Err("missing_collision_descriptor")
        );

        // 2) 声明了代理：请求打到唯一合法的固定路径上。
        let collider = glb.clone();
        let remote_id = recorded["remote_id"].as_str().unwrap();
        receipt["result"]["collision_url"] = json!(format!("/v1/jobs/{remote_id}/collider.glb"));
        receipt["result"]["collision_format"] = json!("glb-hull");
        receipt["result"]["collision_sha256"] = json!(model::digest(&collider));
        receipt["result"]["collision_bytes"] = json!(collider.len() as u64);
        receipt["result"]["collision_triangles"] = json!(1024);
        job.receipt = Some(receipt.clone());
        let (origin, server) = serve_once(200, vec![], collider.clone()).await;
        job.endpoint = origin.clone();
        assert_eq!(provider.fetch_collision(&job, token).await, Ok(collider.clone()));
        let captured = wire(&server.await.unwrap(), &origin);
        assert_eq!(captured["method"], "GET");
        assert_eq!(captured["path"], format!("/v1/jobs/{remote_id}/collider.glb"));
        assert_eq!(
            captured["headers"],
            recorded["wire"]["download"]["headers"],
            "认证头必须与模型下载逐字一致"
        );

        // 3) 路径换到别的 origin / 别的 id：`unsafe_download`，连请求都不发。
        for hostile in [
            "/v1/jobs/ffffffffffffffffffffffffffffffff/collider.glb",
            "/v1/jobs/0123456789abcdef0123456789abcdef/model.glb",
            "https://evil.invalid/v1/jobs/0123456789abcdef0123456789abcdef/collider.glb",
        ] {
            let mut value = receipt.clone();
            value["result"]["collision_url"] = json!(hostile);
            job.receipt = Some(value);
            job.endpoint = origin.clone();
            assert_eq!(
                provider.fetch_collision(&job, token).await,
                Err("unsafe_download"),
                "接受了 {hostile}"
            );
        }

        // 4) 摘要不符 / 类型非法的声明：取回被拒，且错误码可读。
        let mut wrong = receipt.clone();
        wrong["result"]["collision_sha256"] = json!("d".repeat(64));
        job.receipt = Some(wrong);
        let (origin, server) = serve_once(200, vec![], collider.clone()).await;
        job.endpoint = origin.clone();
        assert_eq!(
            provider.fetch_collision(&job, token).await,
            Err("collision_integrity_failed")
        );
        let _ = server.await;

        let mut illegal = receipt.clone();
        illegal["result"]["collision_triangles"] = json!("1024");
        job.receipt = Some(illegal);
        assert_eq!(
            provider.fetch_collision(&job, token).await,
            Err("invalid_collision_descriptor")
        );

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
            let via_free = request(&client().unwrap(), &job, token, true, false, None).await;
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

    /// 生成服务自报的「收得下尺寸意图」声明，与 DGX 补丁写进 `/health` 的那一份逐字相同。
    /// 录制 fixture 与 DGX 补丁共用这一个形状：两边不会各自漂一套。
    fn declared_health() -> Value {
        json!({
            "status": "api_ready",
            "generation": {"ready": true, "available_gib": 88.0, "profile": "trellis2-prop-low-v1"},
            "provider": {
                "id": "gmgn-prop-service",
                "kind": "remote_http",
                "size_intent": {
                    "axes": ["height", "longest"],
                    "min_meters": 0.01,
                    "max_meters": 3.0,
                    "applies": "echo",
                },
            },
        })
    }

    fn job_with_intent(recorded: &Value, root: &std::path::Path) -> Job {
        job_from_fixture(recorded, root)
    }

    fn intent_value() -> Value {
        json!({"axis": "longest", "meters": 1.1, "source": "user"})
    }

    /// `provider` 块口径的断言：**键缺失/null ⇒ 没声明**（老服务），**在但不合法 ⇒
    /// 整块不可信**。两条都不会退化成"随便发"。
    #[test]
    fn the_provider_block_declaration_is_additive_and_strict() {
        for block in [
            json!({}),
            json!({"size_intent": null}),
            json!({"id": "dgx", "max_input_px": 512}),
        ] {
            assert_eq!(size_intent_support(&block), Ok(None), "{block}");
        }
        let declared = declared_health();
        assert_eq!(
            size_intent_support(&declared["provider"]),
            Ok(Some(SizeIntentSupport {
                axes: vec![
                    crate::model::SizeIntentAxis::Height,
                    crate::model::SizeIntentAxis::Longest,
                ],
                min_meters: 0.01,
                max_meters: 3.0,
                applies: crate::model::SizeIntentApplies::Echo,
            }))
        );
        // 兼容性证据：老 fixture（没有 `provider` 块）解析结果与改造前**逐位相同**。
        assert_eq!(
            health(&read_fixture("health_legacy.json")).unwrap(),
            ProviderCapabilities::default()
        );
        // 在但不合法 ⇒ 整块不可信，而不是"能力很强"。
        for block in [
            json!({"size_intent": {"axes": ["height"], "min_meters": 0.01, "max_meters": 3.0}}),
            json!({"size_intent": {"axes": ["width"], "min_meters": 0.01, "max_meters": 3.0, "applies": "echo"}}),
            json!({"size_intent": 2048}),
        ] {
            assert_eq!(
                size_intent_support(&block),
                Err("invalid_provider_capabilities"),
                "{block}"
            );
            assert_eq!(
                capabilities(&block),
                Err("invalid_provider_capabilities"),
                "{block}"
            );
        }
        // 合法的声明要能一路穿过 `health()`（也就是 `provider_probe` 报给 app 的那一份）。
        assert_eq!(
            health(&declared_health()).unwrap().size_intent,
            size_intent_support(&declared_health()["provider"]).unwrap()
        );
    }

    /// Records the exact wire bytes of an **intent-bearing** submission into
    /// `tests/fixtures/remote_http_size_intent.json`: the negotiation probe and
    /// the submit, recorded from a real socket in order.
    /// Run explicitly with `GMGN_RECORD_TASKD_FIXTURES=1 cargo test record_remote_size_intent_wire`.
    #[tokio::test]
    async fn record_remote_size_intent_wire() {
        if std::env::var("GMGN_RECORD_TASKD_FIXTURES").as_deref() != Ok("1") {
            return;
        }
        let baseline = read_fixture("remote_http.json");
        let token = baseline["token"].as_str().unwrap();
        let receipt = baseline["receipt"].clone();
        let root = temp_root();

        // 共享基线里的那一张图与那一份回执：新录的链路**只**多了"意图"这一件事。
        let mut fixture = baseline.clone();
        let mut job_json = baseline["job"].clone();
        job_json["sizeIntent"] = intent_value();
        fixture["job"] = job_json;

        let capability = declared_health();
        let mut job = job_with_intent(&fixture, &root);
        let provider = RemoteHTTPProvider::new(client().unwrap());
        let (origin, server) = serve_many(vec![
            (
                200,
                json_headers(),
                serde_json::to_vec(&capability).unwrap(),
            ),
            (200, json_headers(), serde_json::to_vec(&receipt).unwrap()),
        ])
        .await;
        job.endpoint = origin.clone();
        let submitted = provider.submit(&job, token).await.unwrap();
        let captured = server.await.unwrap();
        assert_eq!(captured.len(), 2, "带意图的提交必须先协商一次 /health");

        let recorded = json!({
            "token": token,
            "job": fixture["job"].clone(),
            "png_base64": fixture["png_base64"].clone(),
            "png_sha256": fixture["png_sha256"].clone(),
            "glb_base64": baseline["glb_base64"].clone(),
            "glb_sha256": baseline["glb_sha256"].clone(),
            "remote_id": baseline["remote_id"].clone(),
            "receipt": receipt,
            "capability": capability,
            "wire": {
                "health": wire(&captured[0], &origin),
                "submit": wire(&captured[1], &origin),
            },
            "expected": {"submit_receipt": submitted},
        });
        let mut encoded = serde_json::to_vec_pretty(&recorded).unwrap();
        encoded.push(b'\n');
        std::fs::write(fixture_path("remote_http_size_intent.json"), encoded).unwrap();
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// 断言 1（**存在 ⇒ 按它发**）：服务端声明收得下 ⇒ 提交字节**逐位**等于录制值，
    /// 而且**先**问了一次 `/health`。
    /// 断言 2（**缺失 ⇒ 字节不变**）：同一件任务去掉意图 ⇒ 一个多出来的请求都不发，
    /// 字节逐位等于 `remote_http.json` 的录制值。
    #[tokio::test]
    async fn the_size_intent_is_sent_only_when_declared_and_absent_keeps_todays_bytes() {
        let recorded = read_fixture("remote_http_size_intent.json");
        let baseline = read_fixture("remote_http.json");
        let token = recorded["token"].as_str().unwrap();
        let root = temp_root();

        // ---- 断言 2a，纯文本，不经过任何代码路径：把录制下来的那一份 body 去掉
        // `size_intent` 成员，剩下的字节与基线**逐位**相同。也就是说这次改动只多了这一个键，
        // 别的字节（`height_meters`、`name`、`source`、base64 图片）一个都没动。
        let mut members: serde_json::Map<String, Value> = serde_json::from_str(
            recorded["wire"]["submit"]["body"].as_str().unwrap(),
        )
        .unwrap();
        assert_eq!(
            members.remove("size_intent").unwrap(),
            intent_value(),
            "发出去的轴必须就是任务上那一份"
        );
        assert_eq!(
            serde_json::to_string(&Value::Object(members)).unwrap(),
            baseline["wire"]["submit"]["body"].as_str().unwrap(),
            "去掉 size_intent 之后与基线不再逐位相同"
        );

        // ---- 断言 2b，真实 trait 路径：不带意图 ⇒ 连 `/health` 都不问（`serve_once`
        // 只应答一个连接，多问一次就会把回执吃掉 ⇒ 提交直接失败）。
        let mut plain = job_with_intent(&recorded, &root);
        plain.size_intent = None;
        let provider = RemoteHTTPProvider::new(client().unwrap());
        let (origin, server) = serve_once(
            200,
            json_headers(),
            serde_json::to_vec(&recorded["receipt"]).unwrap(),
        )
        .await;
        plain.endpoint = origin.clone();
        let unchanged = provider.submit(&plain, token).await.unwrap();
        let seen = wire(&server.await.unwrap(), &origin);
        assert_eq!(seen["path"], "/v1/jobs");
        assert_eq!(
            seen["body"],
            baseline["wire"]["submit"]["body"],
            "没有意图的提交字节必须与今天逐位相同"
        );
        assert_fields_equal("", &unchanged, &baseline["expected"]["submit_receipt"]);

        // ---- 断言 1：声明了 ⇒ 先协商、再按意图发，两条线上字节都与录制值相同。
        let provider = RemoteHTTPProvider::new(client().unwrap());
        let capability = recorded["capability"].clone();
        let (origin, server) = serve_many(vec![
            (
                200,
                json_headers(),
                serde_json::to_vec(&capability).unwrap(),
            ),
            (
                200,
                json_headers(),
                serde_json::to_vec(&recorded["receipt"]).unwrap(),
            ),
        ])
        .await;
        let mut job = job_with_intent(&recorded, &root);
        job.endpoint = origin.clone();
        let submitted = provider.submit(&job, token).await.unwrap();
        let captured = server.await.unwrap();
        assert_eq!(captured.len(), 2, "带意图的提交必须先协商一次 /health");
        assert_eq!(wire(&captured[0], &origin), recorded["wire"]["health"]);
        assert_eq!(wire(&captured[1], &origin), recorded["wire"]["submit"]);
        assert_fields_equal("", &submitted, &recorded["expected"]["submit_receipt"]);
        let sent: Value =
            serde_json::from_str(captured[1].body.as_str()).unwrap();
        assert_eq!(sent["size_intent"], intent_value());
        assert_eq!(sent["height_meters"], baseline["job"]["height_meters"]);
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// 协商的结果只有两种，**都不许把任务弄失败**：声明对不上（轴/区间/形状/探测失败）
    /// ⇒ 不发那个键、提交照常；而且"问过了仍然不发"这件事是要看到那次 `/health` 才成立的。
    #[tokio::test]
    async fn a_missing_or_unusable_declaration_never_breaks_the_submission() {
        let recorded = read_fixture("remote_http_size_intent.json");
        let baseline = read_fixture("remote_http.json");
        let token = recorded["token"].as_str().unwrap();
        let root = temp_root();

        let mut legacy_health = declared_health();
        legacy_health.as_object_mut().unwrap().remove("provider");
        let mut only_height = declared_health();
        only_height["provider"]["size_intent"]["axes"] = json!(["height"]);
        let mut narrow = declared_health();
        narrow["provider"]["size_intent"]["min_meters"] = json!(0.2);
        narrow["provider"]["size_intent"]["max_meters"] = json!(0.8);
        let mut malformed = declared_health();
        malformed["provider"]["size_intent"]["applies"] = json!("maybe");
        let mut wrong_axis_word = declared_health();
        wrong_axis_word["provider"]["size_intent"]["axes"] = json!(["width"]);

        for (label, status, health) in [
            ("老服务没有 provider 块", 200, legacy_health),
            ("只声明了 height 这一根轴", 200, only_height),
            ("声明的区间盖不住 1.1 m", 200, narrow),
            ("声明不合法（applies 不认识）", 200, malformed),
            ("声明里有个我们不认识的轴", 200, wrong_axis_word),
            ("/health 直接 500", 500, json!({"error": "internal_error"})),
        ] {
            let provider = RemoteHTTPProvider::new(client().unwrap());
            let (origin, server) = serve_many(vec![
                (status, json_headers(), serde_json::to_vec(&health).unwrap()),
                (
                    200,
                    json_headers(),
                    serde_json::to_vec(&recorded["receipt"]).unwrap(),
                ),
            ])
            .await;
            let mut job = job_with_intent(&recorded, &root);
            job.endpoint = origin.clone();
            let submitted = provider.submit(&job, token).await.unwrap_or_else(|e| {
                panic!("{label}：协商的问题被升级成了任务失败（{e}）")
            });
            let captured = server.await.unwrap();
            assert_eq!(captured.len(), 2, "{label}：应当先问一次 /health");
            assert_eq!(wire(&captured[0], &origin)["path"], "/health", "{label}");
            let seen = wire(&captured[1], &origin);
            assert_eq!(seen["path"], "/v1/jobs", "{label}");
            assert_eq!(
                seen["body"],
                baseline["wire"]["submit"]["body"],
                "{label}：不该发 size_intent，字节必须与今天逐位相同"
            );
            assert_fields_equal("", &submitted, &baseline["expected"]["submit_receipt"]);
        }
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// 一次协商管一段时间：同一 endpoint 的连续提交只问一次 `/health`（缓存），
    /// 不会每件任务都多一次往返。
    #[tokio::test]
    async fn one_declaration_is_negotiated_once_per_endpoint() {
        let recorded = read_fixture("remote_http_size_intent.json");
        let token = recorded["token"].as_str().unwrap();
        let root = temp_root();
        let provider = RemoteHTTPProvider::new(client().unwrap());
        let (origin, server) = serve_many(vec![
            (
                200,
                json_headers(),
                serde_json::to_vec(&recorded["capability"]).unwrap(),
            ),
            (
                200,
                json_headers(),
                serde_json::to_vec(&recorded["receipt"]).unwrap(),
            ),
            (
                200,
                json_headers(),
                serde_json::to_vec(&recorded["receipt"]).unwrap(),
            ),
        ])
        .await;
        for _ in 0..2 {
            let mut job = job_with_intent(&recorded, &root);
            job.endpoint = origin.clone();
            provider.submit(&job, token).await.unwrap();
        }
        let captured = server.await.unwrap();
        assert_eq!(captured.len(), 3, "第二次提交不该再问一次 /health");
        assert_eq!(wire(&captured[0], &origin)["path"], "/health");
        for index in [1, 2] {
            assert_eq!(
                wire(&captured[index], &origin),
                recorded["wire"]["submit"],
                "第 {index} 次提交的字节应当与录制值相同"
            );
        }
        std::fs::remove_dir_all(&root).unwrap();
    }

    /// 断言（任务书第 3 条，线上那一半）：回执回显的意图与发出去的不一致 ⇒ 明确错误码。
    /// app 侧意图优先于权威尺寸，所以矛盾的那一份**不会被任何人看见** —— 必须在这里断住。
    #[tokio::test]
    async fn a_conflicting_echo_in_the_receipt_is_a_named_error() {
        let recorded = read_fixture("remote_http_size_intent.json");
        let token = recorded["token"].as_str().unwrap();
        let root = temp_root();
        let capability = recorded["capability"].clone();

        for (label, echo, expected) in [
            (
                "回显的米数不是我们要的",
                Some(json!({"axis": "longest", "meters": 1.2, "source": "user"})),
                Err("size_intent_echo_conflict"),
            ),
            (
                "回显的轴不是我们要的",
                Some(json!({"axis": "height", "meters": 1.1, "source": "user"})),
                Err("size_intent_echo_conflict"),
            ),
            (
                "原样回显",
                Some(intent_value()),
                Ok(()),
            ),
            ("不回显", None, Ok(())),
        ] {
            let mut receipt = recorded["receipt"].clone();
            if let Some(echo) = echo {
                receipt["size_intent"] = echo;
            }
            let provider = RemoteHTTPProvider::new(client().unwrap());
            let (origin, server) = serve_many(vec![
                (
                    200,
                    json_headers(),
                    serde_json::to_vec(&capability).unwrap(),
                ),
                (200, json_headers(), serde_json::to_vec(&receipt).unwrap()),
            ])
            .await;
            let mut job = job_with_intent(&recorded, &root);
            job.endpoint = origin.clone();
            assert_eq!(
                provider.submit(&job, token).await.map(|_| ()),
                expected,
                "{label}"
            );
            let captured = server.await.unwrap();
            // 无论回执怎么回事，发出去的字节都按意图走 —— 冲突只在**收**的时候判。
            assert_eq!(wire(&captured[1], &origin), recorded["wire"]["submit"], "{label}");
        }
        std::fs::remove_dir_all(&root).unwrap();
    }
}

#[cfg(test)]
pub(crate) mod testwire {
    /// One-shot loopback HTTP recorder shared with the daemon tests.
    pub(crate) use super::tests::serve_once;
}
