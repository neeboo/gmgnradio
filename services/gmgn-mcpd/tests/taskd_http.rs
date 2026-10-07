#[path = "../src/taskd.rs"]
mod taskd;

use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpListener;

async fn call_peer(reply: String) -> Result<serde_json::Value, taskd::TaskdError> {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let path = std::env::temp_dir().join(format!(
        "gmgn-http-client-{}-{}.json",
        std::process::id(),
        listener.local_addr().unwrap().port()
    ));
    std::fs::write(
        &path,
        serde_json::to_vec(&json!({
            "version": 2, "address": listener.local_addr().unwrap().to_string(),
            "token": "6ef3b6dc-a90b-4df0-8b79-e79b94c30cd1"
        }))
        .unwrap(),
    )
    .unwrap();
    let peer = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader.read_line(&mut line).await.unwrap();
        assert_eq!(line.trim(), "POST /rpc HTTP/1.1");
        let mut length = 0;
        loop {
            line.clear();
            reader.read_line(&mut line).await.unwrap();
            if line == "\r\n" {
                break;
            }
            if let Some((name, value)) = line.trim().split_once(':') {
                if name.eq_ignore_ascii_case("content-length") {
                    length = value.trim().parse().unwrap();
                }
            }
        }
        let mut request = vec![0; length];
        reader.read_exact(&mut request).await.unwrap();
        reader.get_mut().write_all(reply.as_bytes()).await.unwrap();
    });
    let client = taskd::Client::new(&path);
    assert_eq!(client.endpoint_file(), path);
    let result = client.call("snapshot", json!({})).await;
    peer.await.unwrap();
    std::fs::remove_file(path).unwrap();
    result
}

fn response(status: &str, body: &str) -> String {
    format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

#[tokio::test]
async fn http_error_preserves_authority_code() {
    let error = call_peer(response(
        "401 Unauthorized",
        r#"{"id":null,"error":{"code":"unauthorized"}}"#,
    ))
    .await
    .unwrap_err();
    assert_eq!(error.code(), "unauthorized");
    assert_eq!(error.detail(), "unauthorized");
}

#[tokio::test]
async fn unrelated_reply_and_ndjson_are_rejected() {
    assert!(matches!(
        call_peer(response("200 OK", r#"{"id":"2","result":{}}"#)).await,
        Err(taskd::TaskdError::Protocol(_))
    ));
    assert!(matches!(
        call_peer(response(
            "200 OK",
            "{\"id\":\"1\",\"result\":{}}\n{\"id\":\"1\",\"result\":{}}\n"
        ))
        .await,
        Err(taskd::TaskdError::Protocol(_))
    ));
}

#[tokio::test]
async fn redirect_is_not_followed_and_oversize_is_rejected() {
    assert!(matches!(call_peer(
        "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/leak\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into()).await,
        Err(taskd::TaskdError::Protocol(_))));
    assert!(matches!(
        call_peer(format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            taskd::FRAME_LIMIT + 1
        ))
        .await,
        Err(taskd::TaskdError::Protocol(_))
    ));
}
