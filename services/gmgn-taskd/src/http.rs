//! Authenticated loopback HTTP authority. JSON RPC and SSE are separate routes;
//! no newline-TCP reader or compatibility business endpoint remains.
use crate::{
    daemon::{self, OutboundFrame, Service},
    model::{Result, FRAME_LIMIT},
    store::Database,
    voice,
};
use bytes::Bytes;
use futures_util::Stream;
use gmgn_protocol::{failure, valid_request_id, Request};
use http_body_util::{combinators::BoxBody, BodyExt, Full, StreamBody};
use hyper::{
    body::{Frame, Incoming},
    header,
    server::conn::http1,
    service::service_fn,
    Method, Request as HttpRequest, Response, StatusCode,
};
use hyper_util::rt::TokioIo;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    convert::Infallible,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context, Poll},
    time::Duration,
};
use tokio::{
    net::TcpListener,
    sync::{mpsc, Mutex as AsyncMutex, Semaphore},
    task::AbortHandle,
};

type Body = BoxBody<Bytes, Infallible>;
type VoiceMap = Arc<Mutex<HashMap<String, VoiceEntry>>>;
#[derive(Clone)]
struct VoiceEntry {
    generation: uuid::Uuid,
    connection: Arc<AsyncMutex<voice::Connection>>,
}
#[derive(Clone)]
pub(crate) struct HttpService {
    service: Service,
    token: Arc<str>,
    voices: VoiceMap,
    streams: Arc<Semaphore>,
    #[cfg(test)]
    test_tts_factory: Option<voice::TestTtsFactory>,
}
struct StreamGuard {
    task: AbortHandle,
    voice: Option<(VoiceMap, String, uuid::Uuid)>,
    _permit: tokio::sync::OwnedSemaphorePermit,
}
impl Drop for StreamGuard {
    fn drop(&mut self) {
        self.task.abort();
        if let Some((map, client, generation)) = &self.voice {
            let mut map = map.lock().expect("voice map poisoned");
            if map
                .get(client)
                .is_some_and(|entry| entry.generation == *generation)
            {
                // Removing the stream-owned Connection drops Active and aborts
                // its provider task. In-flight command requests own only a brief
                // lock; their cancellation-safe future releases it on disconnect.
                map.remove(client);
            }
        }
    }
}
struct Events {
    receiver: mpsc::Receiver<OutboundFrame>,
    heartbeat: tokio::time::Interval,
    _guard: StreamGuard,
}
impl Stream for Events {
    type Item = std::result::Result<Frame<Bytes>, Infallible>;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        match self.receiver.poll_recv(cx) {
            Poll::Ready(Some(frame)) => {
                let _ = frame.completion.send(Ok(()));
                return Poll::Ready(Some(Ok(Frame::data(Bytes::from(frame.bytes)))));
            }
            Poll::Ready(None) => return Poll::Ready(None),
            Poll::Pending => {}
        }
        if self.heartbeat.poll_tick(cx).is_ready() {
            return Poll::Ready(Some(Ok(Frame::data(Bytes::from_static(
                b": heartbeat\n\n",
            )))));
        }
        Poll::Pending
    }
}
fn response(status: StatusCode, value: Value) -> Response<Body> {
    let bytes = serde_json::to_vec(&value).expect("JSON value serializes");
    if bytes.len() > FRAME_LIMIT {
        return response(
            StatusCode::INTERNAL_SERVER_ERROR,
            failure(value["id"].clone(), "frame_too_large"),
        );
    }
    Response::builder()
        .status(status)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::CACHE_CONTROL, "no-store")
        .body(Full::new(Bytes::from(bytes)).boxed())
        .expect("static HTTP response")
}
fn reject(status: StatusCode, code: &str) -> Response<Body> {
    response(status, failure(Value::Null, code))
}
fn streaming(method: &str) -> bool {
    matches!(
        method,
        "subscribe"
            | "subscribe_messages"
            | "world_subscribe"
            | "voice_tts_start"
            | "voice_asr_start"
    )
}
fn client_id(request: &HttpRequest<Incoming>) -> Result<String> {
    let value = request
        .headers()
        .get("x-gmgn-client-id")
        .and_then(|v| v.to_str().ok())
        .ok_or("invalid_client_id")?;
    let id = uuid::Uuid::parse_str(value).map_err(|_| "invalid_client_id")?;
    if id.get_version_num() != 4 {
        return Err("invalid_client_id");
    }
    Ok(id.to_string())
}
impl HttpService {
    #[cfg(test)]
    fn with_test_tts_factory(service: Service, token: String, factory: voice::TestTtsFactory) -> Self {
        let mut http = Self::new(service, token);
        http.test_tts_factory = Some(factory);
        http
    }
    fn voice_connection(&self) -> voice::Connection {
        #[cfg(test)]
        if let Some(factory) = &self.test_tts_factory {
            return voice::Connection::with_test_tts_factory(self.service.speech_delivery.clone(), factory.clone());
        }
        voice::Connection::with_delivery(self.service.speech_delivery.clone())
    }
    pub(crate) fn new(service: Service, token: String) -> Self {
        Self {
            service,
            token: token.into(),
            voices: Arc::new(Mutex::new(HashMap::new())),
            streams: Arc::new(Semaphore::new(64)),
            #[cfg(test)]
            test_tts_factory: None,
        }
    }
    async fn voice_reply(&self, request: Request, client: Option<String>) -> Result<Value> {
        let connection = match client {
            Some(client) => self
                .voices
                .lock()
                .expect("voice map poisoned")
                .get(&client)
                .map(|entry| entry.connection.clone())
                .ok_or("voice_session_not_found")?,
            None => Arc::new(AsyncMutex::new(self.voice_connection())),
        };
        let (writer, mut receiver) = daemon::response_queue(false);
        let operation = async {
            connection
                .lock()
                .await
                .handle(&request.method, request.params, request.id, &writer)
                .await
        };
        let read = async {
            let frame = receiver.recv().await.ok_or("client_disconnected")?;
            let value = serde_json::from_slice(&frame.bytes).map_err(|_| "invalid_response")?;
            let _ = frame.completion.send(Ok(()));
            Ok::<Value, &'static str>(value)
        };
        let (_, reply) = tokio::try_join!(operation, read)?;
        Ok(reply)
    }
    fn events(&self, request: Request, client: Option<String>) -> Response<Body> {
        let Ok(permit) = self.streams.clone().try_acquire_owned() else {
            return reject(StatusCode::TOO_MANY_REQUESTS, "stream_limit_exceeded");
        };
        let (writer, receiver) = daemon::response_queue(true);
        let id = request.id.clone();
        let service = self.service.clone();
        let voice_entry = if let Some(client) = client {
            let mut map = self.voices.lock().expect("voice map poisoned");
            if map.contains_key(&client) {
                return response(StatusCode::CONFLICT, failure(id, "voice_client_busy"));
            }
            if map.len() >= 64 {
                return response(
                    StatusCode::TOO_MANY_REQUESTS,
                    failure(id, "stream_limit_exceeded"),
                );
            }
            let entry = VoiceEntry {
                generation: uuid::Uuid::new_v4(),
                connection: Arc::new(AsyncMutex::new(self.voice_connection())),
            };
            map.insert(client.clone(), entry.clone());
            Some((client, entry))
        } else {
            None
        };
        let owner = voice_entry
            .as_ref()
            .map(|(client, entry)| (self.voices.clone(), client.clone(), entry.generation));
        let task = tokio::spawn(async move {
            let outcome = if let Some((_, entry)) = voice_entry {
                // The lock and session live across HTTP requests, bound to this
                // event stream rather than a transient /rpc connection.
                entry
                    .connection
                    .lock()
                    .await
                    .handle(&request.method, request.params, request.id, &writer)
                    .await
            } else {
                service.stream_events(request, writer.clone()).await
            };
            if let Err(code) = outcome {
                let _ = daemon::write(&writer, &failure(id, code)).await;
            }
        });
        let mut heartbeat = tokio::time::interval(Duration::from_secs(15));
        heartbeat.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let events = Events {
            receiver,
            heartbeat,
            _guard: StreamGuard {
                task: task.abort_handle(),
                voice: owner,
                _permit: permit,
            },
        };
        Response::builder()
            .status(StatusCode::OK)
            .header(header::CONTENT_TYPE, "text/event-stream")
            .header(header::CACHE_CONTROL, "no-store")
            .header("x-accel-buffering", "no")
            .body(StreamBody::new(events).boxed())
            .expect("static SSE response")
    }
    pub(crate) async fn handle(
        &self,
        request: HttpRequest<Incoming>,
    ) -> std::result::Result<Response<Body>, Infallible> {
        // Native clients do not send Origin. Reject browser origins before body
        // reads and business dispatch; this authority intentionally offers no CORS.
        if request.headers().contains_key(header::ORIGIN) {
            return Ok(reject(StatusCode::FORBIDDEN, "http_origin_forbidden"));
        }
        if request.method() == Method::GET && request.uri().path().starts_with("/media-live/") {
            let parts: Vec<_> = request.uri().path().split('/').collect();
            if parts.len() != 4 {
                return Ok(reject(StatusCode::NOT_FOUND, "http_route_not_found"));
            }
            return Ok(
                match self.service.media.live_resource(parts[2], parts[3]).await {
                    Ok((mime, bytes)) => Response::builder()
                        .status(StatusCode::OK)
                        .header(header::CONTENT_TYPE, mime)
                        .header(header::CACHE_CONTROL, "no-store")
                        .body(Full::new(Bytes::from(bytes)).boxed())
                        .expect("live resource response"),
                    Err(code) => reject(StatusCode::BAD_GATEWAY, code),
                },
            );
        }
        let authorized = request
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .is_some_and(|value| value.strip_prefix("Bearer ") == Some(&self.token))
            && request
                .headers()
                .get_all(header::AUTHORIZATION)
                .iter()
                .count()
                == 1;
        let dsh_grant = if !authorized && request.method() == Method::POST
            && request.uri().path() == "/rpc"
            && request.headers().get_all(header::AUTHORIZATION).iter().count() == 1 {
            match request.headers().get(header::AUTHORIZATION).and_then(|v| v.to_str().ok())
                .and_then(|v| v.strip_prefix("Bearer ")) {
                Some(token) if self.service.accepts_dsh_grant(token).await => Some((token.to_owned(), false)),
                Some(token) if self.service.accepts_claude_grant(token).await => Some((token.to_owned(), true)),
                _ => None,
            }
        } else { None };
        if !authorized && dsh_grant.is_none() {
            return Ok(reject(StatusCode::UNAUTHORIZED, "http_unauthorized"));
        }
        if request.method() == Method::GET && request.uri().path() == "/health" {
            return Ok(response(
                StatusCode::OK,
                json!({"version":2,"transport":"http"}),
            ));
        }
        let path = request.uri().path().to_owned();
        if request.method() == Method::GET && path.starts_with("/media/") {
            let parts: Vec<_> = path.split('/').collect();
            let range = request
                .headers()
                .get(header::RANGE)
                .and_then(|v| v.to_str().ok())
                .unwrap_or("");
            if parts.len() != 4 {
                return Ok(reject(StatusCode::NOT_FOUND, "http_route_not_found"));
            }
            let mut upstream = match self
                .service
                .media
                .playback_range(parts[2], parts[3], range)
                .await
            {
                Ok(upstream) => upstream,
                Err(code) => return Ok(reject(StatusCode::BAD_GATEWAY, code)),
            };
            let mut builder = Response::builder().status(upstream.status());
            for name in [
                header::CONTENT_TYPE,
                header::CONTENT_LENGTH,
                header::CONTENT_RANGE,
                header::ACCEPT_RANGES,
            ] {
                if let Some(value) = upstream.headers().get(&name) {
                    builder = builder.header(name, value);
                }
            }
            let expected = upstream.content_length();
            let mut data = Vec::new();
            loop {
                match upstream.chunk().await {
                    Ok(Some(chunk)) if data.len() + chunk.len() <= 1024 * 1024 => {
                        data.extend_from_slice(&chunk)
                    }
                    Ok(None) => break,
                    _ => return Ok(reject(StatusCode::BAD_GATEWAY, "media_download_failed")),
                }
            }
            if expected.is_some_and(|length| length != data.len() as u64) {
                return Ok(reject(StatusCode::BAD_GATEWAY, "media_invalid_range"));
            }
            return Ok(builder
                .header(header::CACHE_CONTROL, "no-store")
                .body(Full::new(Bytes::from(data)).boxed())
                .expect("media response"));
        }
        if !matches!(path.as_str(), "/rpc" | "/events") {
            return Ok(reject(StatusCode::NOT_FOUND, "http_route_not_found"));
        }
        if request.method() != Method::POST {
            return Ok(reject(
                StatusCode::METHOD_NOT_ALLOWED,
                "http_method_not_allowed",
            ));
        }
        if request
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .is_none_or(|v| v.split(';').next().map(str::trim) != Some("application/json"))
        {
            return Ok(reject(
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "http_content_type_required",
            ));
        }
        if request
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .is_some_and(|n| n > FRAME_LIMIT as u64)
        {
            return Ok(reject(StatusCode::PAYLOAD_TOO_LARGE, "frame_too_large"));
        }
        let client = client_id(&request);
        let mut body = request.into_body();
        let collected = tokio::time::timeout(Duration::from_secs(30), async {
            let mut bytes = Vec::new();
            while let Some(frame) = body.frame().await {
                let frame = frame.map_err(|_| "invalid_request")?;
                if let Ok(data) = frame.into_data() {
                    if bytes.len() + data.len() > FRAME_LIMIT {
                        return Err("frame_too_large");
                    }
                    bytes.extend_from_slice(&data);
                }
            }
            Ok::<_, &'static str>(bytes)
        })
        .await;
        let bytes = match collected {
            Ok(Ok(bytes)) => bytes,
            Ok(Err(code)) => {
                return Ok(reject(
                    if code == "frame_too_large" {
                        StatusCode::PAYLOAD_TOO_LARGE
                    } else {
                        StatusCode::BAD_REQUEST
                    },
                    code,
                ))
            }
            Err(_) => return Ok(reject(StatusCode::REQUEST_TIMEOUT, "client_timeout")),
        };
        if let Some((token, claude)) = dsh_grant {
            let flat: Value = match serde_json::from_slice(&bytes) {
                Ok(value) => value,
                Err(_) => return Ok(reject(StatusCode::BAD_REQUEST, "invalid_request")),
            };
            let result = if claude {
                self.service.claude_host_call(&token, &flat).await
            } else {
                self.service.dsh_host_call(&token, &flat).await
            };
            return Ok(match result {
                Ok(value) => response(StatusCode::OK, value),
                Err(code) => reject(StatusCode::BAD_REQUEST, code),
            });
        }
        let envelope: Request = match serde_json::from_slice(&bytes) {
            Ok(request) => request,
            Err(_) => return Ok(reject(StatusCode::BAD_REQUEST, "invalid_request")),
        };
        if !valid_request_id(&envelope.id) {
            return Ok(reject(StatusCode::BAD_REQUEST, "invalid_request_id"));
        }
        let id = envelope.id.clone();
        if path == "/events" {
            if !streaming(&envelope.method) {
                return Ok(response(
                    StatusCode::BAD_REQUEST,
                    failure(id, "http_stream_method_required"),
                ));
            }
            let client = if envelope.method.starts_with("voice_") {
                match client {
                    Ok(client) => Some(client),
                    Err(code) => return Ok(response(StatusCode::BAD_REQUEST, failure(id, code))),
                }
            } else {
                None
            };
            return Ok(self.events(envelope, client));
        }
        if streaming(&envelope.method) {
            return Ok(response(
                StatusCode::BAD_REQUEST,
                failure(id, "http_events_route_required"),
            ));
        }
        let outcome = tokio::time::timeout(Duration::from_secs(60), async {
            if envelope.method.starts_with("voice_") {
                let client = match envelope.method.as_str() {
                    "voice_audio_append" | "voice_asr_commit" | "voice_cancel" => Some(client?),
                    _ => None,
                };
                self.voice_reply(envelope, client).await
            } else {
                self.service
                    .request(&envelope.method, envelope.params)
                    .await
                    .map(|result| json!({"id":id,"result":result}))
            }
        })
        .await;
        Ok(match outcome {
            Ok(Ok(reply)) => response(StatusCode::OK, reply),
            Ok(Err(code)) => response(StatusCode::OK, failure(id, code)),
            Err(_) => response(StatusCode::GATEWAY_TIMEOUT, failure(id, "client_timeout")),
        })
    }
}

pub async fn run_with_media(
    listener: TcpListener,
    db: Database,
    concurrency: usize,
    token: String,
    helpers: Option<crate::media::Helpers>,
) -> Result<()> {
    let service = Service::new(db)?;
    service.media.initialize(helpers).await?;
    let mut scheduler = tokio::spawn(service.clone().schedule(concurrency));
    let http = HttpService::new(service, token);
    // Keep a command-connection budget beside the 64 long-lived event streams;
    // saturating ASR streams must not prevent their /rpc append/commit/cancel.
    let clients = Arc::new(Semaphore::new(128));
    loop {
        tokio::select! {
            result = tokio::signal::ctrl_c() => return result.map_err(|_| "signal_unavailable"),
            result = &mut scheduler => return result.map_err(|_| "worker_failed")?,
            accepted = listener.accept() => {
                let (stream, peer) = accepted.map_err(|_| "socket_unavailable")?;
                if !peer.ip().is_loopback() { continue; }
                let Ok(permit) = clients.clone().try_acquire_owned() else { continue; };
                let http = http.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    let io = TokioIo::new(stream);
                    let _ = http1::Builder::new().max_buf_size(32*1024).timer(hyper_util::rt::TokioTimer::new())
                        .header_read_timeout(Duration::from_secs(30)).serve_connection(io,service_fn(move |request| {
                            let http = http.clone();
                            async move {http.handle(request).await}
                        })).await;
                });
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    struct Server {
        base: String,
        token: String,
        http: HttpService,
        task: tokio::task::JoinHandle<()>,
        root: PathBuf,
    }
    impl Drop for Server {
        fn drop(&mut self) {
            self.task.abort();
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    async fn server() -> Server {
        server_with_tts(None).await
    }
    async fn server_with_tts(factory: Option<voice::TestTtsFactory>) -> Server {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-http-{}", uuid::Uuid::new_v4()));
        crate::files::directory(&root).unwrap();
        let service = Service::new(Database::open(root.clone(), None).unwrap()).unwrap();
        let token = uuid::Uuid::new_v4().to_string();
        let http = match factory {
            Some(factory) => HttpService::with_test_tts_factory(service, token.clone(), factory),
            None => HttpService::new(service, token.clone()),
        };
        let serving = http.clone();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let mut connections = tokio::task::JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let (stream,_) = accepted.unwrap();
                        let serving = serving.clone();
                        connections.spawn(async move {
                            let _ = http1::Builder::new().serve_connection(TokioIo::new(stream),service_fn(move |request| {
                                let serving = serving.clone(); async move {serving.handle(request).await}
                            })).await;
                        });
                    }
                    _ = connections.join_next(), if !connections.is_empty() => {}
                }
            }
        });
        Server {
            base,
            token,
            http,
            task,
            root,
        }
    }
    fn post(server: &Server, path: &str, method: &str, params: Value) -> reqwest::RequestBuilder {
        reqwest::Client::new()
            .post(format!("{}{path}", server.base))
            .bearer_auth(&server.token)
            .json(&json!({"id":"test","method":method,"params":params}))
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    #[ignore = "requires explicitly compiled GMGN_TEST_SWIFT_CONSUMER; mock PCM only"]
    async fn speech_delivery_http_actual_swift_pcm_fifo_stop_and_generation() {
        // The test provider is a real loopback HTTP response, not invented SSE.
        // Its PCM bytes pass through Connection/run_tts/DeliveryEmitter unchanged.
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let provider_url = format!("http://{}/pcm", listener.local_addr().unwrap());
        let provider = tokio::spawn(async move {
            loop {
                let (socket, _) = listener.accept().await.unwrap();
                tokio::spawn(async move {
                    let _ = http1::Builder::new().serve_connection(TokioIo::new(socket), service_fn(|request| async move {
                        assert_eq!(request.uri().path(), "/pcm");
                        Ok::<_, Infallible>(Response::new(Full::new(Bytes::from_static(&[0, 0, 1, 0]))))
                    })).await;
                });
            }
        });
        struct ProviderGuard(tokio::task::JoinHandle<()>);
        impl Drop for ProviderGuard { fn drop(&mut self) { self.0.abort(); } }
        let _provider = ProviderGuard(provider);
        let calls = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let count = calls.clone();
        let factory: voice::TestTtsFactory = Arc::new(move |_| {
            count.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let (sender, receiver) = mpsc::channel(2);
            let url = provider_url.clone();
            tokio::spawn(async move {
                let client = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none())
                    .timeout(Duration::from_secs(5)).build().unwrap();
                let result = async {
                    let mut response = client.get(url).send().await.map_err(|_| "voice_transport_error")?
                        .error_for_status().map_err(|_| "voice_provider_error")?;
                    let mut total = 0usize;
                    while let Some(bytes) = response.chunk().await.map_err(|_| "voice_transport_error")? {
                        total += bytes.len();
                        if total > 8192 { return Err("voice_protocol_error"); }
                        for chunk in bytes.chunks(4096) {
                            sender.send(Ok(chunk.to_vec())).await.map_err(|_| "voice_session_not_found")?;
                        }
                    }
                    if total != 4 { return Err("voice_protocol_error"); }
                    Ok::<(), &'static str>(())
                }.await;
                if let Err(error) = result { let _ = sender.send(Err(error)).await; }
                // Only successful HTTP EOF closes the source without an error.
            });
            receiver
        });
        let server = server_with_tts(Some(factory)).await;
        let descriptor = server.root.join("speech-private.endpoint.json");
        std::fs::write(&descriptor, serde_json::to_vec(&json!({"version":2,
            "address":server.base.strip_prefix("http://").unwrap(),"token":server.token})).unwrap()).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&descriptor, std::fs::Permissions::from_mode(0o600)).unwrap();
        }
        let binary = std::env::var_os("GMGN_TEST_SWIFT_CONSUMER").expect("compile private Swift consumer first");
        let child = tokio::process::Command::new(binary).arg(&descriptor)
            .kill_on_drop(true).stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped())
            .spawn().unwrap();
        let output = tokio::time::timeout(Duration::from_secs(30), child.wait_with_output()).await
            .expect("Swift private consumer timeout").unwrap();
        assert!(output.status.success(), "stdout={} stderr={}", String::from_utf8_lossy(&output.stdout), String::from_utf8_lossy(&output.stderr));
        assert!(String::from_utf8_lossy(&output.stdout).contains("PASS actual private Rust HTTP/SSE/SQLite"));
        assert_eq!(calls.load(std::sync::atomic::Ordering::SeqCst), 3);
        // Independent durable readback, not a Swift-local outcome assertion.
        let db = rusqlite::Connection::open(server.root.join("tasks.sqlite3")).unwrap();
        let payload: String = db.query_row("SELECT payload FROM speech_delivery_lanes WHERE scope='swift-http'", [], |row| row.get(0)).unwrap();
        let lane: Value = serde_json::from_str(&payload).unwrap();
        assert_eq!(lane["states"][0]["status"], "delivered");
        assert_eq!(lane["states"][0]["playedFrames"], 2);
        assert_eq!(lane["states"][2]["status"], "delivered");
        assert_eq!(lane["states"][2]["playedFrames"], 2);
        assert_eq!(lane["states"][1]["status"], "stopped");
    }
    async fn dsh_phase(server: &Server, params: &Value, phase: &str) -> Value {
        tokio::time::timeout(Duration::from_secs(10), async {
            loop {
                let response: Value = post(server, "/rpc", "agent_dsh_read", params.clone())
                    .send().await.unwrap().json().await.unwrap();
                let result = &response["result"];
                if result["state"] == phase || result["pendingTools"].as_array()
                    .is_some_and(|tools| tools.iter().any(|tool| tool["phase"] == phase)) {
                    return result.clone();
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.unwrap()
    }

    #[cfg(unix)]
    const MOCK_CLAUDE_MCP: &str = r#"#!/usr/bin/python3
import json,sys,subprocess,os,signal
# Failed assertions in the parent test still leave only a bounded fixture lifetime.
signal.alarm(20)
# This fixture consumes exactly the native whole-stdin/EOF protocol.
prompt=json.loads(sys.stdin.read())
argv=sys.argv[1:]
assert argv[argv.index('--tools')+1]==''
assert '--bare' in argv and '--strict-mcp-config' in argv
assert '--no-session-persistence' in argv and '--resume' not in argv
assert argv[argv.index('--permission-mode')+1]=='dontAsk'
config=json.load(open(argv[argv.index('--mcp-config')+1]))
native=config['mcpServers']['gmgn-resident-tools']
grant=json.load(open(native['args'][native['args'].index('--grant')+1]))
fd=os.open(prompt['auditPath'],os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
with os.fdopen(fd,'w') as f: json.dump({'secret':grant['secret'],'round':grant['round']},f)
adapter=subprocess.Popen([native['command']]+native['args'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True)
def request(id,method,params):
 adapter.stdin.write(json.dumps({'jsonrpc':'2.0','id':id,'method':method,'params':params})+'\n');adapter.stdin.flush()
 line=adapter.stdout.readline()
 assert line, 'native adapter must reply'
 reply=json.loads(line)
 assert reply.get('id')==id and 'error' not in reply
 return reply['result']
try:
 initialized=request(1,'initialize',{'protocolVersion':'2024-11-05','capabilities':{},'clientInfo':{'name':'private-fixture','version':'1'}})
 assert 'tools' in initialized['capabilities']
 adapter.stdin.write(json.dumps({'jsonrpc':'2.0','method':'notifications/initialized','params':{}})+'\n');adapter.stdin.flush()
 catalog=request(2,'tools/list',{})
 assert [t['name'] for t in catalog['tools']]==['gmgn_inspect_world']
 result=request(3,'tools/call',{'name':'gmgn_inspect_world','arguments':{}})
 assert result['isError'] is False
 assert result['content'][0]['type']=='text'
 assert json.loads(result['content'][0]['text'])=={'observed':True}
 assert result['content'][1]['type']=='image' and result['content'][1]['mimeType']=='image/png'
finally:
 adapter.stdin.close()
 adapter.wait(timeout=5)
print(json.dumps({'type':'result','subtype':'success','is_error':False,'result':'done','session_id':'must-not-be-resumed'}),flush=True)
"#;

    #[cfg(unix)]
    async fn claude_native_fixture(server: &Server) -> Value {
        use std::os::unix::fs::PermissionsExt;
        let adapter = std::env::var_os("GMGN_TEST_MCP_ADAPTER")
            .map(PathBuf::from)
            .expect("set GMGN_TEST_MCP_ADAPTER to the separately built native gmgn-mcpd");
        assert!(adapter.is_absolute() && adapter.is_file());
        let executable = server.root.join("private-mock-claude");
        crate::files::publish(&executable, MOCK_CLAUDE_MCP.as_bytes()).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        server.http.service.db.call(|store| {
            crate::agent_scheduler::request(&mut store.connection,"agent_loop_configure",&json!({"worldID":"w","residentScope":"s","hostSessionID":"h","hourlyLimit":6,"minimumWakeIntervalSeconds":1}))?;
            store.connection.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','event','{}','claimed','run','h')",[]).map_err(|_|"storage_unavailable")?;
            Ok(())
        }).await.unwrap();
        json!({"worldID":"w","residentScope":"s","hostSessionID":"h","runID":"run","eventID":"event","executable":executable,"adapterExecutable":adapter,"hostEndpoint":format!("{}/rpc",server.base),"environment":{"ANTHROPIC_API_KEY":"fixture-explicit-never-real"},"input":serde_json::to_string(&json!({"auditPath":server.root.join("native-audit.json")})).unwrap(),"durableUserText":"inspect world","tools":[{"name":"inspect_world","description":"world","effect":"read","inputSchema":{"type":"object","properties":{},"additionalProperties":false}}]})
    }
    #[cfg(unix)]
    async fn claude_phase(server: &Server, params: &Value, phase: &str) -> Value {
        tokio::time::timeout(Duration::from_secs(10),async {
            loop {
                let response:Value=post(server,"/rpc","agent_claude_read",params.clone()).send().await.unwrap().json().await.unwrap();
                assert!(response.get("error").is_none(),"Claude read must retain the trusted binding");
                let result=&response["result"];
                if result["state"]==phase || result["pendingTools"].as_array().is_some_and(|tools|tools.iter().any(|tool|tool["phase"]==phase)){return result.clone();}
                assert!(!["failed","unknown"].iter().any(|state|result["state"]==*state),"native fixture failed before requested phase");
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.unwrap()
    }
    #[cfg(unix)]
    fn claude_fixture_token(server: &Server) -> String {
        let audit:Value=serde_json::from_slice(&crate::files::read(&server.root.join("native-audit.json"),65536).unwrap()).unwrap();
        audit["secret"].as_str().unwrap().to_owned()
    }
    #[cfg(unix)]
    async fn assert_claude_grant_cannot_control(server: &Server, token: &str, params: &Value) {
        let client=reqwest::Client::new();let flat=json!({"v":1,"callId":"attempt-main","name":"gmgn_inspect_world","arguments":{}});
        assert_eq!(client.post(format!("{}/rpc",server.base)).bearer_auth(&server.token).json(&flat).send().await.unwrap().status(),StatusCode::BAD_REQUEST);
        for method in ["agent_claude_read","agent_claude_cancel","agent_tool_begin","snapshot"] {
            assert_eq!(client.post(format!("{}/rpc",server.base)).bearer_auth(token).json(&json!({"id":"forbidden-control","method":method,"params":params})).send().await.unwrap().status(),StatusCode::BAD_REQUEST);
        }
        assert_eq!(client.get(format!("{}/health",server.base)).bearer_auth(token).send().await.unwrap().status(),StatusCode::UNAUTHORIZED);
    }
    #[cfg(unix)]
    #[tokio::test]
    #[ignore = "requires explicitly built GMGN_TEST_MCP_ADAPTER; no real Claude or credentials"]
    async fn claude_native_mcp_http_read_requires_authorization_and_bound_receipt() {
        let server=server().await;let params=claude_native_fixture(&server).await;
        let started:Value=post(&server,"/rpc","agent_claude_start",params.clone()).send().await.unwrap().json().await.unwrap();assert_eq!(started["result"]["started"],true);
        let read=claude_phase(&server,&params,"authorize").await;let token=claude_fixture_token(&server);assert_claude_grant_cannot_control(&server,&token,&params).await;
        let count=server.http.service.db.call(|store|store.connection.query_row("SELECT count(*) FROM agent_tool_calls",[],|r|r.get::<_,i64>(0)).map_err(|_|"storage_unavailable")).await.unwrap();assert_eq!(count,0,"even read must wait for host authorization");
        for field in ["worldID","residentScope","hostSessionID","runID","eventID"] {let mut stale=params.clone();stale[field]=json!("stale");let rejected:Value=post(&server,"/rpc","agent_claude_read",stale).send().await.unwrap().json().await.unwrap();assert_eq!(rejected["error"]["code"],"agent_claude_stale_session");}
        let mut approval=read["pendingTools"][0].clone();approval["decision"]=json!("approved");approval["operationID"]=json!("trusted-http-read-operation");
        let approved:Value=post(&server,"/rpc","agent_claude_authorize",approval).send().await.unwrap().json().await.unwrap();assert!(approved.get("error").is_none());
        let read=claude_phase(&server,&params,"execute").await;let mut receipt=read["pendingTools"][0].clone();receipt["status"]=json!("completed");receipt["output"]=json!({"observed":true});receipt["images"]=json!([{"mediaType":"image/png","base64":"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6WQAAAAASUVORK5CYII="}]);
        let mut stale=receipt.clone();stale["round"]=json!("old-round");let rejected:Value=post(&server,"/rpc","agent_claude_tool_receipt",stale).send().await.unwrap().json().await.unwrap();assert_eq!(rejected["error"]["code"],"agent_claude_receipt_conflict");
        let completed:Value=post(&server,"/rpc","agent_claude_tool_receipt",receipt).send().await.unwrap().json().await.unwrap();assert!(completed.get("error").is_none());
        let done=claude_phase(&server,&params,"completed").await;assert_eq!(done["text"],"done");assert!(done.get("sessionID").is_none());
        let record=server.http.service.db.call(|store|store.connection.query_row("SELECT world,scope,run,session,effect,state FROM agent_tool_calls WHERE operation='trusted-http-read-operation'",[],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,String>(3)?,r.get::<_,String>(4)?,r.get::<_,String>(5)?))).map_err(|_|"storage_unavailable")).await.unwrap();assert_eq!(record,("w".into(),"s".into(),"run".into(),"h".into(),"read".into(),"finished".into()));
        assert_eq!(reqwest::Client::new().post(format!("{}/rpc",server.base)).bearer_auth(token).json(&json!({"v":1,"callId":"late","name":"gmgn_inspect_world","arguments":{}})).send().await.unwrap().status(),StatusCode::UNAUTHORIZED);
    }
    #[cfg(unix)]
    #[tokio::test]
    #[ignore = "requires explicitly built GMGN_TEST_MCP_ADAPTER; no real Claude or credentials"]
    async fn claude_native_mcp_http_cancel_revokes_grant_before_any_read_dispatch() {
        let server=server().await;let params=claude_native_fixture(&server).await;
        let started:Value=post(&server,"/rpc","agent_claude_start",params.clone()).send().await.unwrap().json().await.unwrap();assert_eq!(started["result"]["started"],true);claude_phase(&server,&params,"authorize").await;let token=claude_fixture_token(&server);
        let cancelled:Value=post(&server,"/rpc","agent_claude_cancel",params.clone()).send().await.unwrap().json().await.unwrap();assert_eq!(cancelled["result"]["cancelRequested"],true);claude_phase(&server,&params,"cancelled").await;
        assert_eq!(reqwest::Client::new().post(format!("{}/rpc",server.base)).bearer_auth(token).json(&json!({"v":1,"callId":"late","name":"gmgn_inspect_world","arguments":{}})).send().await.unwrap().status(),StatusCode::UNAUTHORIZED);
        let count=server.http.service.db.call(|store|store.connection.query_row("SELECT count(*) FROM agent_tool_calls",[],|r|r.get::<_,i64>(0)).map_err(|_|"storage_unavailable")).await.unwrap();assert_eq!(count,0);
    }

    #[tokio::test]
    async fn dsh_flat_grant_is_scoped_revocable_and_not_main_auth() {
        let server = server().await;
        let params = crate::agent_dsh::tests::fixture(
            server.http.service.db.clone(), server.root.clone(), false,
        ).await;
        let started: Value = post(&server, "/rpc", "agent_dsh_start", params.clone())
            .send().await.unwrap().json().await.unwrap();
        assert_eq!(started["result"]["started"], true);
        dsh_phase(&server, &params, "running").await;
        let token = params["grantToken"].as_str().unwrap().to_owned();
        let flat = json!({"v":1,"callId":"http-call","name":"gmgn_move","arguments":{"target":"chair"}});
        let client = reqwest::Client::new();
        assert_eq!(client.post(format!("{}/rpc", server.base)).bearer_auth("unknown")
            .json(&flat).send().await.unwrap().status(), StatusCode::UNAUTHORIZED);
        assert_eq!(client.post(format!("{}/rpc", server.base)).bearer_auth(&server.token)
            .json(&flat).send().await.unwrap().status(), StatusCode::BAD_REQUEST);
        assert_eq!(client.post(format!("{}/rpc", server.base)).bearer_auth(&token)
            .json(&json!({"id":"escape","method":"snapshot","params":{}}))
            .send().await.unwrap().status(), StatusCode::BAD_REQUEST);
        let url = format!("{}/rpc", server.base);
        let call_token = token.clone();
        let call_flat = flat.clone();
        let pending = tokio::spawn(async move {
            reqwest::Client::new().post(url).bearer_auth(call_token).json(&call_flat)
                .send().await.unwrap().json::<Value>().await.unwrap()
        });
        let read = dsh_phase(&server, &params, "authorize").await;
        let mut approval = read["pendingTools"][0].clone();
        approval["decision"] = json!("approved");
        approval["operationID"] = json!("http-operation");
        let approved: Value = post(&server, "/rpc", "agent_dsh_authorize", approval)
            .send().await.unwrap().json().await.unwrap();
        assert!(approved.get("error").is_none());
        let read = dsh_phase(&server, &params, "execute").await;
        let mut receipt = read["pendingTools"][0].clone();
        receipt["status"] = json!("completed");
        receipt["output"] = json!({"moved":true});
        let completed: Value = post(&server, "/rpc", "agent_dsh_tool_receipt", receipt)
            .send().await.unwrap().json().await.unwrap();
        assert!(completed.get("error").is_none());
        assert_eq!(pending.await.unwrap()["data"]["moved"], true);
        std::fs::write(server.root.join("finish"), b"ready").unwrap();
        dsh_phase(&server, &params, "completed").await;
        assert_eq!(client.post(format!("{}/rpc", server.base)).bearer_auth(&token)
            .json(&flat).send().await.unwrap().status(), StatusCode::UNAUTHORIZED);
    }
    async fn data(response: &mut reqwest::Response, buffer: &mut Vec<u8>) -> Value {
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                if let Some(end) = buffer.windows(2).position(|v| v == b"\n\n") {
                    let event: Vec<_> = buffer.drain(..end + 2).collect();
                    if event.starts_with(b"data: ") {
                        return serde_json::from_slice(&event[6..event.len() - 2]).unwrap();
                    }
                    continue;
                }
                buffer.extend_from_slice(&response.chunk().await.unwrap().expect("SSE data"));
            }
        })
        .await
        .expect("SSE timeout")
    }
    #[tokio::test]
    async fn http_auth_origin_routes_and_request_bounds() {
        let s = server().await;
        let client = reqwest::Client::new();
        let health = client
            .get(format!("{}/health", s.base))
            .bearer_auth(&s.token)
            .send()
            .await
            .unwrap();
        assert_eq!(health.status(), StatusCode::OK);
        assert_eq!(
            health.json::<Value>().await.unwrap(),
            json!({"version":2,"transport":"http"})
        );
        let unauthorized = client.post(format!("{}/rpc",s.base)).json(&json!({"id":"x","method":"configure","params":{"endpoint":"https://example.invalid","token":"never-persist"}})).send().await.unwrap();
        assert_eq!(unauthorized.status(), StatusCode::UNAUTHORIZED);
        let media = client
            .get(format!("{}/media/{}/video", s.base, "a".repeat(64)))
            .header(header::RANGE, "bytes=0-31")
            .send()
            .await
            .unwrap();
        assert_eq!(media.status(), StatusCode::UNAUTHORIZED);
        let unissued_cap = client
            .get(format!(
                "{}/media-live/{}/{}",
                s.base,
                uuid::Uuid::new_v4(),
                uuid::Uuid::new_v4()
            ))
            .send()
            .await
            .unwrap();
        assert_eq!(unissued_cap.status(), StatusCode::BAD_GATEWAY);
        assert_eq!(
            unissued_cap.json::<Value>().await.unwrap()["error"]["code"],
            "media_cache_missing"
        );
        assert_eq!(
            unauthorized.json::<Value>().await.unwrap()["error"]["code"],
            "http_unauthorized"
        );
        let origin = post(&s, "/rpc", "snapshot", json!({}))
            .header(header::ORIGIN, "https://example.invalid")
            .send()
            .await
            .unwrap();
        assert_eq!(origin.status(), StatusCode::FORBIDDEN);
        let route = post(&s, "/rpc", "subscribe", json!({"after":0}))
            .send()
            .await
            .unwrap();
        assert_eq!(route.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            route.json::<Value>().await.unwrap()["error"]["code"],
            "http_events_route_required"
        );
        // Headers-only oversize request tests the explicit 413 without racing a
        // client's concurrent upload against the server's deliberate rejection.
        let body = client
            .post(format!("{}/rpc", s.base))
            .bearer_auth(&s.token)
            .header(header::CONTENT_TYPE, "application/json")
            .header(header::CONTENT_LENGTH, (FRAME_LIMIT + 1).to_string())
            .body(Bytes::new())
            .send()
            .await
            .unwrap();
        assert_eq!(body.status(), StatusCode::PAYLOAD_TOO_LARGE);
        let invalid = client
            .post(format!("{}/rpc", s.base))
            .bearer_auth(&s.token)
            .json(&json!({"id":1,"method":"snapshot"}))
            .send()
            .await
            .unwrap();
        assert_eq!(invalid.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            invalid.json::<Value>().await.unwrap()["error"]["code"],
            "invalid_request_id"
        );
    }
    #[tokio::test]
    async fn sse_ack_is_distinct_and_committed_replay_has_no_gap() {
        let s = server().await;
        let task_id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let stored_id = task_id.clone();
        s.http
            .service
            .db
            .call(move |store| {
                store
                    .connection
                    .execute("INSERT INTO jobs(id,data) VALUES(?1,'{}')", [stored_id])
                    .map_err(|_| "storage_unavailable")?;
                Ok(())
            })
            .await
            .unwrap();
        let before = uuid::Uuid::new_v4().to_string();
        let after = uuid::Uuid::new_v4().to_string();
        let publish = |id: &str| json!({"id":id,"taskId":task_id,"worldID":"world-a","residentScope":"resident-a","kind":"task.stateChanged","payload":{"n":id}});
        let published = post(&s, "/rpc", "publish_message", publish(&before))
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap();
        assert!(published.get("result").is_some(), "{published}");
        let mut response = post(
            &s,
            "/events",
            "subscribe_messages",
            json!({"consumer":"ui","worldID":"world-a","residentScope":"resident-a"}),
        )
        .send()
        .await
        .unwrap();
        assert_eq!(
            response.headers()[header::CONTENT_TYPE],
            "text/event-stream"
        );
        let mut buffer = Vec::new();
        let ack = data(&mut response, &mut buffer).await;
        assert_eq!(ack["result"]["subscribed"], true);
        assert!(ack.get("message").is_none());
        let replay = data(&mut response, &mut buffer).await;
        assert_eq!(replay["message"]["id"], before);
        let published = post(&s, "/rpc", "publish_message", publish(&after))
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap();
        assert!(published.get("result").is_some(), "{published}");
        let live = data(&mut response, &mut buffer).await;
        assert_eq!(live["message"]["id"], after);
        assert!(live.get("id").is_none());
        drop(response);
    }
    #[tokio::test]
    async fn voice_http_catalog_and_stream_events_never_echo_credentials() {
        let s = server().await;
        let capabilities = post(&s, "/rpc", "voice_capabilities", json!({}))
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap();
        assert_eq!(
            capabilities["result"]["providers"][2]["asrStreaming"],
            false
        );
        let list = post(&s, "/rpc", "voice_list", json!({"provider":"bailian"}))
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap();
        assert_eq!(list["result"]["voices"].as_array().unwrap().len(), 4);
        let missing = post(&s, "/events", "voice_asr_start", json!({}))
            .send()
            .await
            .unwrap();
        assert_eq!(missing.status(), StatusCode::BAD_REQUEST);
        assert_eq!(
            missing.json::<Value>().await.unwrap()["error"]["code"],
            "invalid_client_id"
        );
        let client = uuid::Uuid::new_v4().to_string();
        // Invalid provider voice ID fails before network IO in the real core.
        let mut response = post(&s,"/events","voice_tts_start",json!({"sessionID":"speech","provider":"elevenlabs","apiKey":"secret-never-echoed","voiceID":"invalid voice","text":"hello"})).header("x-gmgn-client-id",&client).send().await.unwrap();
        let mut buffer = Vec::new();
        let ack = data(&mut response, &mut buffer).await;
        assert_eq!(ack["result"]["started"], true);
        let event = data(&mut response, &mut buffer).await;
        assert!(event.get("id").is_none());
        assert_eq!(event["voice_event"]["type"], "error");
        assert_eq!(event["voice_event"]["sessionID"], "speech");
        assert!(!event.to_string().contains("secret-never-echoed"));
        drop(response);
        for _ in 0..100 {
            if s.http.voices.lock().unwrap().is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(s.http.voices.lock().unwrap().is_empty());
        let stale = post(&s, "/rpc", "voice_cancel", json!({"sessionID":"speech"}))
            .header("x-gmgn-client-id", client)
            .send()
            .await
            .unwrap()
            .json::<Value>()
            .await
            .unwrap();
        assert_eq!(stale["error"]["code"], "voice_session_not_found");
    }
    #[tokio::test]
    async fn asr_commands_share_client_session_and_stream_drop_aborts_provider() {
        let s = server().await;
        let client = uuid::Uuid::new_v4().to_string();
        let generation = uuid::Uuid::new_v4();
        let (connection, canceled) = voice::tests::active_asr("asr-current");
        s.http.voices.lock().unwrap().insert(
            client.clone(),
            VoiceEntry {
                generation,
                connection: Arc::new(AsyncMutex::new(connection)),
            },
        );
        tokio::task::yield_now().await;
        let owner = tokio::spawn(std::future::pending::<()>());
        let guard = StreamGuard {
            task: owner.abort_handle(),
            voice: Some((s.http.voices.clone(), client.clone(), generation)),
            _permit: s.http.streams.clone().try_acquire_owned().unwrap(),
        };
        for (method, params) in [
            (
                "voice_audio_append",
                json!({"sessionID":"asr-current","audioBase64":"AAA="}),
            ),
            ("voice_asr_commit", json!({"sessionID":"asr-current"})),
        ] {
            let ack = post(&s, "/rpc", method, params)
                .header("x-gmgn-client-id", &client)
                .send()
                .await
                .unwrap()
                .json::<Value>()
                .await
                .unwrap();
            assert_eq!(ack["result"]["accepted"], true, "{ack}");
        }
        let wrong = post(
            &s,
            "/rpc",
            "voice_audio_append",
            json!({"sessionID":"asr-current","audioBase64":"AAA="}),
        )
        .header("x-gmgn-client-id", uuid::Uuid::new_v4().to_string())
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
        assert_eq!(wrong["error"]["code"], "voice_session_not_found");
        drop(guard);
        assert!(s.http.voices.lock().unwrap().is_empty());
        assert!(
            tokio::time::timeout(Duration::from_secs(2), canceled)
                .await
                .unwrap()
                .is_err(),
            "provider task should be aborted by stream owner drop"
        );
        let stale = post(
            &s,
            "/rpc",
            "voice_asr_commit",
            json!({"sessionID":"asr-current"}),
        )
        .header("x-gmgn-client-id", client)
        .send()
        .await
        .unwrap()
        .json::<Value>()
        .await
        .unwrap();
        assert_eq!(stale["error"]["code"], "voice_session_not_found");
    }
    #[tokio::test]
    async fn concurrent_http_replies_keep_their_own_request_ids() {
        let s = server().await;
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let db = s.http.service.db.clone();
        let blocker = tokio::spawn(async move {
            db.call(move |_| {
                let _ = entered_tx.send(());
                release_rx.recv().unwrap();
                Ok(())
            })
            .await
        });
        entered_rx.await.unwrap();
        let mut calls = tokio::task::JoinSet::new();
        let client = reqwest::Client::new();
        for index in 0..64 {
            let builder = client
                .post(format!("{}/rpc", s.base))
                .bearer_auth(&s.token)
                .json(&json!({"id":index.to_string(),"method":"snapshot","params":{}}));
            calls.spawn(async move {
                (
                    index,
                    builder.send().await.unwrap().json::<Value>().await.unwrap(),
                )
            });
        }
        for _ in 0..32 {
            tokio::task::yield_now().await;
        }
        release_tx.send(()).unwrap();
        blocker.await.unwrap().unwrap();
        while let Some(call) = calls.join_next().await {
            let (index, reply) = call.unwrap();
            assert_eq!(reply["id"], index.to_string());
            assert!(reply.get("result").is_some());
        }
    }
    #[tokio::test]
    async fn disconnected_http_client_cancels_an_inflight_reply_future() {
        use tokio::io::AsyncWriteExt;
        let s = server().await;
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let db = s.http.service.db.clone();
        let blocker = tokio::spawn(async move {
            db.call(move |_| {
                let _ = entered_tx.send(());
                release_rx.recv().unwrap();
                Ok(())
            })
            .await
        });
        entered_rx.await.unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut client = tokio::net::TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (socket, _) = listener.accept().await.unwrap();
        let http = s.http.clone();
        let serving = tokio::spawn(async move {
            http1::Builder::new()
                .serve_connection(
                    TokioIo::new(socket),
                    service_fn(move |request| {
                        let http = http.clone();
                        async move { http.handle(request).await }
                    }),
                )
                .await
        });
        let body = br#"{"id":"disconnected","method":"snapshot","params":{}}"#;
        let headers = format!("POST /rpc HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {}\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n",s.token,body.len());
        client.write_all(headers.as_bytes()).await.unwrap();
        client.write_all(body).await.unwrap();
        for _ in 0..32 {
            tokio::task::yield_now().await;
        }
        drop(client);
        let completion = tokio::time::timeout(Duration::from_secs(2), serving).await;
        // Always release the writer before asserting, even when cancellation
        // regresses, so a failing test cannot strand taskd-storage indefinitely.
        release_tx.send(()).unwrap();
        blocker.await.unwrap().unwrap();
        assert!(
            completion.is_ok(),
            "HTTP disconnect must stop the pending reply before the storage barrier opens"
        );
    }
}
