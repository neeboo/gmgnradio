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
    pub(crate) fn new(service: Service, token: String) -> Self {
        Self {
            service,
            token: token.into(),
            voices: Arc::new(Mutex::new(HashMap::new())),
            streams: Arc::new(Semaphore::new(64)),
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
            None => Arc::new(AsyncMutex::new(voice::Connection::default())),
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
                connection: Arc::new(AsyncMutex::new(voice::Connection::default())),
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
        if !authorized {
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
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-http-{}", uuid::Uuid::new_v4()));
        crate::files::directory(&root).unwrap();
        let service = Service::new(Database::open(root.clone(), None).unwrap()).unwrap();
        let token = uuid::Uuid::new_v4().to_string();
        let http = HttpService::new(service, token.clone());
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
