//! Real loopback HTTP/SSE through aimux provider and the pinned Rutis driver.
use gmgn_agent_runtime::{
    provider::{build_provider, ProviderConfig},
    *,
};
use rutis::BoxFuture;
use serde_json::{json, Value};
use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    sync::mpsc,
};

struct Fixture {
    base: String,
    requests: mpsc::Receiver<Value>,
    task: tokio::task::JoinHandle<()>,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn fixture(responses: Vec<Option<String>>) -> Fixture {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/v1", listener.local_addr().unwrap());
    let (tx, requests) = mpsc::channel(8);
    let task = tokio::spawn(async move {
        for response in responses {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let (header_end, length) = loop {
                let mut chunk = [0u8; 4096];
                let n = stream.read(&mut chunk).await.unwrap();
                assert!(n > 0 && bytes.len() + n <= 128 * 1024);
                bytes.extend_from_slice(&chunk[..n]);
                if let Some(i) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                    let headers = std::str::from_utf8(&bytes[..i]).unwrap();
                    assert!(headers.starts_with("POST /v1/chat/completions HTTP/1.1"));
                    assert!(headers
                        .to_ascii_lowercase()
                        .contains("authorization: bearer fake-local-key"));
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            line.to_ascii_lowercase()
                                .strip_prefix("content-length:")
                                .map(|s| s.trim().parse::<usize>().unwrap())
                        })
                        .unwrap();
                    break (i + 4, length);
                }
            };
            while bytes.len() < header_end + length {
                let mut chunk = [0u8; 4096];
                let n = stream.read(&mut chunk).await.unwrap();
                assert!(n > 0 && bytes.len() + n <= 128 * 1024);
                bytes.extend_from_slice(&chunk[..n]);
            }
            tx.send(serde_json::from_slice(&bytes[header_end..header_end + length]).unwrap())
                .await
                .unwrap();
            match response {
                Some(body) => {
                    let headers = format!("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                    stream.write_all(headers.as_bytes()).await.unwrap();
                    stream.write_all(body.as_bytes()).await.unwrap();
                    stream.shutdown().await.unwrap();
                }
                None => {
                    std::future::pending::<()>().await;
                }
            }
        }
    });
    Fixture {
        base,
        requests,
        task,
    }
}
fn chunk(delta: Value, finish: Value) -> String {
    format!(
        "data: {}\n\n",
        json!({"id":"local","object":"chat.completion.chunk","created":0,"model":"test-model","choices":[{"index":0,"delta":delta,"finish_reason":finish}]})
    )
}
fn tool_response(finish: bool) -> String {
    let mut s = chunk(
        json!({"role":"assistant","tool_calls":[{"index":0,"id":"call-1","type":"function","function":{"name":"gmgn_move","arguments":"{\"x\":1}"}}]}),
        Value::Null,
    );
    if finish {
        s += &chunk(json!({}), json!("tool_calls"));
        s += "data: [DONE]\n\n";
    }
    s
}
fn text_response() -> String {
    chunk(json!({"role":"assistant","content":"arrived"}), Value::Null)
        + &chunk(json!({}), json!("stop"))
        + "data: [DONE]\n\n"
}
fn identity() -> TurnIdentity {
    TurnIdentity {
        world_id: "world".into(),
        scope_id: "scope".into(),
        session_id: "session".into(),
        run_id: "http-run".into(),
    }
}
struct Executor(Arc<AtomicUsize>);
impl HostToolExecutor for Executor {
    fn execute(&self, c: HostToolContext) -> BoxFuture<'static, Result<HostToolReceipt, String>> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move {
            assert_eq!(c.execution.call.input, json!({"x":1}));
            Ok(HostToolReceipt {
                identity: c.identity,
                call_id: c.execution.call.tool_call_id,
                status: HostToolStatus::Completed,
                output: json!({"arrived":true}),
                images: vec![],
            })
        })
    }
}
async fn runtime(base: String, calls: Arc<AtomicUsize>, timeout: Duration) -> RutisRuntime {
    let mut c = ProviderConfig::new(
        "openai".into(),
        base,
        "test-model".into(),
        "fake-local-key".into(),
    );
    c.request_timeout = timeout;
    RutisRuntime::new_host(
        build_provider(c).unwrap(),
        vec![HostToolSchema {
            name: "gmgn_move".into(),
            description: "move".into(),
            parameters: json!({"type":"object","properties":{"x":{"type":"integer"}}}),
        }],
        Arc::new(Executor(calls)),
        RuntimeConfig {
            allowed_tools: ["gmgn_move".into()].into_iter().collect(),
            ..Default::default()
        },
    )
    .await
    .unwrap()
}
#[tokio::test]
async fn real_http_sse_tool_receipt_and_followup_text() {
    let mut f = fixture(vec![Some(tool_response(true)), Some(text_response())]).await;
    let calls = Arc::new(AtomicUsize::new(0));
    let r = runtime(f.base.clone(), calls.clone(), Duration::from_secs(3)).await;
    assert_eq!(
        r.followup_with_identity("move", identity()).await.unwrap(),
        "arrived"
    );
    assert_eq!(calls.load(Ordering::SeqCst), 1);
    let first = f.requests.recv().await.unwrap();
    let second = f.requests.recv().await.unwrap();
    assert_eq!(first["stream"], true);
    assert_eq!(first["tools"][0]["function"]["name"], "gmgn_move");
    assert!(second["messages"]
        .as_array()
        .unwrap()
        .iter()
        .any(|m| m["role"] == "tool"
            && m["tool_call_id"] == "call-1"
            && m["content"].as_str().unwrap().contains("arrived")));
    r.shutdown().await.unwrap();
}
#[tokio::test]
async fn incomplete_and_malformed_sse_do_not_execute_tools_or_succeed() {
    for body in [tool_response(false), "data: {wrong json}\n\n".into()] {
        let f = fixture(vec![Some(body)]).await;
        let calls = Arc::new(AtomicUsize::new(0));
        let r = runtime(f.base.clone(), calls.clone(), Duration::from_secs(3)).await;
        assert!(r.followup_with_identity("move", identity()).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 0);
        r.shutdown().await.unwrap();
    }
}
#[tokio::test]
async fn request_timeout_and_cancel_are_real_http_bounded() {
    let f = fixture(vec![None]).await;
    let r = runtime(
        f.base.clone(),
        Arc::new(AtomicUsize::new(0)),
        Duration::from_millis(80),
    )
    .await;
    let result = tokio::time::timeout(
        Duration::from_secs(1),
        r.followup_with_identity("move", identity()),
    )
    .await
    .unwrap();
    assert!(result.is_err());
    r.shutdown().await.unwrap();

    let mut f = fixture(vec![None]).await;
    let r = Arc::new(
        runtime(
            f.base.clone(),
            Arc::new(AtomicUsize::new(0)),
            Duration::from_secs(30),
        )
        .await,
    );
    let turn = r.clone();
    let join = tokio::spawn(async move { turn.followup_with_identity("move", identity()).await });
    tokio::time::timeout(Duration::from_secs(1), f.requests.recv())
        .await
        .unwrap()
        .unwrap();
    r.cancel();
    assert!(tokio::time::timeout(Duration::from_secs(1), join)
        .await
        .unwrap()
        .unwrap()
        .is_err());
    r.shutdown().await.unwrap();
}

const PNG: &[u8] = &[
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 4, 0,
    0, 0, 181, 28, 12, 2, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 252, 255, 31, 0, 3, 3, 2, 0,
    239, 163, 233, 100, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
];
fn image() -> ImageInput {
    ImageInput {
        bytes: PNG.to_vec(),
        media_type: "image/png".into(),
    }
}
struct ImageExecutor;
impl HostToolExecutor for ImageExecutor {
    fn execute(&self, c: HostToolContext) -> BoxFuture<'static, Result<HostToolReceipt, String>> {
        Box::pin(async move {
            Ok(HostToolReceipt {
                identity: c.identity,
                call_id: c.execution.call.tool_call_id,
                status: HostToolStatus::Completed,
                output: json!({"observed":true}),
                images: vec![image()],
            })
        })
    }
}
#[tokio::test]
async fn initial_and_tool_images_are_real_http_image_parts_in_same_run() {
    let mut f = fixture(vec![Some(tool_response(true)), Some(text_response())]).await;
    let mut c = ProviderConfig::new(
        "openai".into(),
        f.base.clone(),
        "test-vision".into(),
        "fake-local-key".into(),
    );
    c.image_input = true;
    let r = RutisRuntime::new_host(
        build_provider(c).unwrap(),
        vec![HostToolSchema {
            name: "gmgn_move".into(),
            description: "move".into(),
            parameters: json!({"type":"object"}),
        }],
        Arc::new(ImageExecutor),
        RuntimeConfig {
            supports_images: true,
            allowed_tools: ["gmgn_move".into()].into_iter().collect(),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    assert_eq!(
        r.followup_input_with_identity(
            UserInput {
                text: "observe".into(),
                images: vec![image()]
            },
            identity()
        )
        .await
        .unwrap(),
        "arrived"
    );
    let first = f.requests.recv().await.unwrap();
    let second = f.requests.recv().await.unwrap();
    let expected = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j6WQAAAAASUVORK5CYII=";
    for (body, count) in [(first, 1), (second, 2)] {
        let images: Vec<_> = body["messages"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|m| m["content"].as_array())
            .flat_map(|parts| parts.iter())
            .filter(|p| p["type"] == "image_url")
            .collect();
        assert_eq!(images.len(), count);
        assert!(images.iter().all(|p| p["image_url"]["url"] == expected));
    }
    assert_eq!(
        r.session()
            .messages()
            .iter()
            .filter(|m| m.role == aimux_core::message::Role::Tool)
            .count(),
        1
    );
    r.shutdown().await.unwrap();
}
#[tokio::test]
async fn unsupported_and_mismatched_images_fail_before_http() {
    let mut f = fixture(vec![Some(text_response())]).await;
    let r = runtime(
        f.base.clone(),
        Arc::new(AtomicUsize::new(0)),
        Duration::from_secs(3),
    )
    .await;
    assert!(r
        .followup_input_with_identity(
            UserInput {
                text: "look".into(),
                images: vec![image()]
            },
            identity()
        )
        .await
        .is_err());
    assert!(f.requests.try_recv().is_err());
    r.shutdown().await.unwrap();
    let mut c = ProviderConfig::new(
        "openai".into(),
        f.base.clone(),
        "test-vision".into(),
        "fake-local-key".into(),
    );
    c.image_input = true;
    let r = RutisRuntime::new_host(
        build_provider(c).unwrap(),
        vec![],
        Arc::new(ImageExecutor),
        RuntimeConfig {
            supports_images: true,
            ..Default::default()
        },
    )
    .await
    .unwrap();
    let mut wrong = image();
    wrong.media_type = "image/jpeg".into();
    assert!(r
        .followup_input_with_identity(
            UserInput {
                text: "look".into(),
                images: vec![wrong]
            },
            identity()
        )
        .await
        .is_err());
    assert!(f.requests.try_recv().is_err());
    r.shutdown().await.unwrap();
}
