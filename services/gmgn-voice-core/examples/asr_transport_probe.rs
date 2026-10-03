//! Opt-in diagnostic: credentials from inherited environment, never logged.
use futures_util::{SinkExt, StreamExt};
use gmgn_voice_core::asr_stream::{AsrConfig, AsrProvider, AsrStream, AsrStreamEvent};
use gmgn_voice_core::providers::elevenlabs_asr;
use std::time::Duration;
use tokio_tungstenite::{
    connect_async,
    tungstenite::{client::IntoClientRequest, Message},
};

fn safe_type(value: &serde_json::Value) -> &'static str {
    match value["message_type"].as_str() {
        Some("session_started") => "session_started",
        Some("partial_transcript") => "partial_transcript",
        Some("committed_transcript") => "committed_transcript",
        Some("input_error") => "input_error",
        Some("invalid_request") => "invalid_request",
        Some("chunk_size_exceeded") => "chunk_size_exceeded",
        Some("insufficient_audio_activity") => "insufficient_audio_activity",
        Some("auth_error") => "auth_error",
        Some("quota_exceeded") => "quota_exceeded",
        Some("transcriber_error") => "transcriber_error",
        Some("error") => "error",
        Some("warning") => "warning",
        _ => "other_event",
    }
}
#[tokio::main]
async fn main() {
    let Ok(key) = std::env::var("ELEVENLABS_API_KEY") else {
        eprintln!("missing_environment_key");
        return;
    };
    if std::env::args().any(|arg| arg == "--production") {
        let config = AsrConfig::new(AsrProvider::ElevenLabs, key).unwrap();
        let mut stream = match AsrStream::connect(config).await {
            Ok(stream) => stream,
            Err(error) => {
                println!("{error}");
                return;
            }
        };
        println!("transport_ready");
        for _ in 0..20 {
            if let Err(error) = stream.append_pcm(vec![0; 3200]).await {
                println!("{error}");
                return;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        if let Err(error) = stream.commit().await {
            println!("{error}");
            return;
        }
        println!("transport_committed");
        let result = tokio::time::timeout(Duration::from_secs(15), async {
            while let Some(event) = stream.next_event().await {
                match event {
                    Ok(AsrStreamEvent::Partial { .. }) => println!("partial_transcript"),
                    Ok(AsrStreamEvent::Final { .. }) => println!("committed_transcript"),
                    Err(error) => println!("{error}"),
                }
            }
        })
        .await;
        if result.is_err() {
            println!("probe_timeout");
        }
        stream.cancel();
        return;
    }
    let mut request = elevenlabs_asr::ENDPOINT.into_client_request().unwrap();
    let Ok(header) = key.parse() else {
        eprintln!("invalid_header");
        return;
    };
    request.headers_mut().insert("xi-api-key", header);
    let Ok(Ok((mut socket, _))) =
        tokio::time::timeout(Duration::from_secs(30), connect_async(request)).await
    else {
        eprintln!("connect_failed");
        return;
    };
    for step in 0..3 {
        let Ok(Some(Ok(Message::Text(text)))) =
            tokio::time::timeout(Duration::from_secs(5), socket.next()).await
        else {
            println!("no_text_event");
            break;
        };
        let Ok(value) = serde_json::from_str::<serde_json::Value>(&text) else {
            println!("invalid_json");
            break;
        };
        println!("{}", safe_type(&value));
        if step == 0 {
            let payload = elevenlabs_asr::audio_chunk(&vec![0; 3050]).unwrap();
            if socket
                .send(Message::Text(payload.to_string().into()))
                .await
                .is_err()
            {
                println!("send_failed");
                break;
            }
        }
    }
    let _ = socket.close(None).await;
}
