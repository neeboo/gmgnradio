//! Qwen realtime TTS: incremental text input and bounded PCM output.
//! https://help.aliyun.com/en/model-studio/qwen-tts-realtime-client-events
//! https://help.aliyun.com/en/model-studio/qwen-tts-realtime-server-events
use crate::BailianConfig;
use base64::{engine::general_purpose::STANDARD, Engine};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::{sync::mpsc, task::JoinHandle};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{client::IntoClientRequest, protocol::WebSocketConfig, Message},
};
use uuid::Uuid;

pub const MODEL: &str = "qwen3-tts-flash-realtime";
const ENDPOINT: &str =
    "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-tts-flash-realtime";
const MAX_MESSAGE: usize = 262_144;
const MAX_TEXT: usize = 16_384;
const QUEUE: usize = 8;

#[derive(Debug, PartialEq, Eq)]
pub enum TtsStreamError {
    Transport,
    Protocol,
    Provider,
    Timeout,
    Closed,
    InvalidText,
}
impl std::fmt::Display for TtsStreamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "realtime synthesis {:?}", self)
    }
}
impl std::error::Error for TtsStreamError {}

/// PCM16 little-endian mono, 24 kHz. Every packet is tagged to its utterance.
#[derive(Debug, PartialEq, Eq)]
pub enum TtsStreamEvent {
    Audio {
        generation: Uuid,
        pcm: Vec<u8>,
        sample_rate: u32,
    },
    Finished {
        generation: Uuid,
    },
}
enum Command {
    Append(String),
    Finish,
}

/// One connection owns one utterance generation. No transparent reconnect.
/// Cancellation clears queued output and aborts the socket task immediately.
pub struct TtsStream {
    generation: Uuid,
    commands: mpsc::Sender<Command>,
    events: mpsc::Receiver<Result<TtsStreamEvent, TtsStreamError>>,
    task: JoinHandle<()>,
    input_finished: bool,
    cancelled: bool,
}
impl TtsStream {
    pub async fn connect(config: BailianConfig) -> Result<Self, TtsStreamError> {
        Self::connect_endpoint(config, ENDPOINT).await
    }
    async fn connect_endpoint(
        config: BailianConfig,
        endpoint: &str,
    ) -> Result<Self, TtsStreamError> {
        let mut request = endpoint
            .into_client_request()
            .map_err(|_| TtsStreamError::Protocol)?;
        let header = format!("Bearer {}", config.api_key)
            .parse()
            .map_err(|_| TtsStreamError::Protocol)?;
        request.headers_mut().insert("Authorization", header);
        let ws_config = WebSocketConfig::default()
            .max_message_size(Some(MAX_MESSAGE))
            .max_frame_size(Some(MAX_MESSAGE));
        let (mut socket, _) = tokio::time::timeout(
            Duration::from_secs(30),
            connect_async_with_config(request, Some(ws_config), false),
        )
        .await
        .map_err(|_| TtsStreamError::Timeout)?
        .map_err(|_| TtsStreamError::Transport)?;
        wait_event(&mut socket, "session.created").await?;
        socket.send(Message::Text(json!({"event_id":Uuid::new_v4().to_string(),"type":"session.update","session":{"voice":config.voice.as_str(),"mode":"server_commit","language_type":"Auto","response_format":"pcm","sample_rate":24000}}).to_string().into())).await.map_err(|_| TtsStreamError::Transport)?;
        let updated = wait_event(&mut socket, "session.updated").await?;
        if updated["session"]["response_format"] != "pcm"
            || updated["session"]["sample_rate"] != 24000
        {
            return Err(TtsStreamError::Protocol);
        }
        let generation = Uuid::new_v4();
        let (commands, mut command_rx) = mpsc::channel(QUEUE);
        let (event_tx, events) = mpsc::channel(QUEUE);
        let task = tokio::spawn(async move {
            let result = async {
                let mut finishing = false;
                let mut active_response: Option<String> = None;
                loop {
                    tokio::select! {
                        command = command_rx.recv(), if !finishing => {
                            let value = match command {
                                Some(Command::Append(text)) => json!({"event_id":Uuid::new_v4().to_string(),"type":"input_text_buffer.append","text":text}),
                                Some(Command::Finish) => { finishing = true; json!({"event_id":Uuid::new_v4().to_string(),"type":"session.finish"}) },
                                None => return Ok(()),
                            };
                            socket.send(Message::Text(value.to_string().into())).await.map_err(|_| TtsStreamError::Transport)?;
                        }
                        incoming = tokio::time::timeout(Duration::from_secs(90), socket.next()) => {
                            let message = incoming.map_err(|_| TtsStreamError::Timeout)?.ok_or(TtsStreamError::Closed)?.map_err(|_| TtsStreamError::Transport)?;
                            let value = match message {
                                Message::Text(text) => serde_json::from_str::<Value>(&text).map_err(|_| TtsStreamError::Protocol)?,
                                Message::Ping(bytes) => { socket.send(Message::Pong(bytes)).await.map_err(|_| TtsStreamError::Transport)?; continue; },
                                Message::Pong(_) => continue,
                                Message::Close(_) => return Err(TtsStreamError::Closed),
                                _ => return Err(TtsStreamError::Protocol),
                            };
                            match value["type"].as_str().ok_or(TtsStreamError::Protocol)? {
                                "error" => return Err(TtsStreamError::Provider),
                                "response.created" => {
                                    if active_response.is_some() { return Err(TtsStreamError::Protocol); }
                                    active_response = Some(value["response"]["id"].as_str().ok_or(TtsStreamError::Protocol)?.to_owned());
                                },
                                "response.audio.delta" => {
                                    if active_response.as_deref() != value["response_id"].as_str() || active_response.is_none() { return Err(TtsStreamError::Protocol); }
                                    let encoded = value["delta"].as_str().ok_or(TtsStreamError::Protocol)?;
                                    let pcm = STANDARD.decode(encoded).map_err(|_| TtsStreamError::Protocol)?;
                                    if pcm.is_empty() || !pcm.len().is_multiple_of(2) { return Err(TtsStreamError::Protocol); }
                                    // Await capacity before reading another WS message: bounded backpressure.
                                    if event_tx.send(Ok(TtsStreamEvent::Audio { generation, pcm, sample_rate:24000 })).await.is_err() { return Ok(()); }
                                },
                                "response.done" => {
                                    if active_response.as_deref() != value["response"]["id"].as_str() || active_response.is_none() { return Err(TtsStreamError::Protocol); }
                                    if value["response"]["status"] != "completed" { return Err(TtsStreamError::Provider); }
                                    active_response = None;
                                },
                                "session.finished" => {
                                    if !finishing || active_response.is_some() { return Err(TtsStreamError::Protocol); }
                                    let _ = event_tx.send(Ok(TtsStreamEvent::Finished { generation })).await;
                                    let _ = socket.close(None).await;
                                    return Ok(());
                                },
                                "response.audio.done" | "response.output_item.added" | "response.content_part.added" | "response.content_part.done" | "response.output_item.done" | "input_text_buffer.committed" => {},
                                _ => return Err(TtsStreamError::Protocol),
                            }
                        }
                    }
                }
            }.await;
            if let Err(error) = result {
                let _ = event_tx.send(Err(error)).await;
            }
        });
        Ok(Self {
            generation,
            commands,
            events,
            task,
            input_finished: false,
            cancelled: false,
        })
    }
    pub fn generation(&self) -> Uuid {
        self.generation
    }
    pub async fn append_text(&mut self, text: impl Into<String>) -> Result<(), TtsStreamError> {
        let text = text.into();
        if text.is_empty() || text.len() > MAX_TEXT {
            return Err(TtsStreamError::InvalidText);
        }
        if self.input_finished || self.cancelled {
            return Err(TtsStreamError::Closed);
        }
        self.commands
            .send(Command::Append(text))
            .await
            .map_err(|_| TtsStreamError::Closed)
    }
    pub async fn finish_input(&mut self) -> Result<(), TtsStreamError> {
        if self.input_finished || self.cancelled {
            return Err(TtsStreamError::Closed);
        }
        self.commands
            .send(Command::Finish)
            .await
            .map_err(|_| TtsStreamError::Closed)?;
        self.input_finished = true;
        Ok(())
    }
    pub async fn next_event(&mut self) -> Option<Result<TtsStreamEvent, TtsStreamError>> {
        if self.cancelled {
            return None;
        }
        self.events.recv().await
    }
    pub fn cancel(&mut self) {
        self.cancelled = true;
        self.task.abort();
        self.events.close();
        while self.events.try_recv().is_ok() {}
    }
}
impl Drop for TtsStream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn wait_event<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    expected: &str,
) -> Result<Value, TtsStreamError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    loop {
        let message = tokio::time::timeout(Duration::from_secs(30), socket.next())
            .await
            .map_err(|_| TtsStreamError::Timeout)?
            .ok_or(TtsStreamError::Closed)?
            .map_err(|_| TtsStreamError::Transport)?;
        match message {
            Message::Text(text) => {
                let event: Value =
                    serde_json::from_str(&text).map_err(|_| TtsStreamError::Protocol)?;
                if event["type"] == "error" {
                    return Err(TtsStreamError::Provider);
                }
                if event["type"] != expected {
                    return Err(TtsStreamError::Protocol);
                }
                return Ok(event);
            }
            Message::Ping(bytes) => socket
                .send(Message::Pong(bytes))
                .await
                .map_err(|_| TtsStreamError::Transport)?,
            _ => return Err(TtsStreamError::Protocol),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::BailianVoice;
    use tokio::{net::TcpListener, sync::oneshot};
    async fn send<S>(socket: &mut tokio_tungstenite::WebSocketStream<S>, value: Value)
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        socket
            .send(Message::Text(value.to_string().into()))
            .await
            .unwrap();
    }
    async fn receive<S>(socket: &mut tokio_tungstenite::WebSocketStream<S>) -> Value
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
    {
        let message = socket.next().await.unwrap().unwrap();
        serde_json::from_str(message.to_text().unwrap()).unwrap()
    }
    async fn server_start() -> (String, TcpListener) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        (format!("ws://{}", listener.local_addr().unwrap()), listener)
    }
    async fn handshake(
        listener: TcpListener,
    ) -> tokio_tungstenite::WebSocketStream<tokio::net::TcpStream> {
        let (tcp, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(tcp).await.unwrap();
        send(&mut socket, json!({"type":"session.created"})).await;
        let update = receive(&mut socket).await;
        assert_eq!(update["type"], "session.update");
        assert_eq!(update["session"]["response_format"], "pcm");
        assert_eq!(update["session"]["sample_rate"], 24000);
        assert_eq!(update["session"]["mode"], "server_commit");
        send(&mut socket, json!({"type":"session.updated","session":{"response_format":"pcm","sample_rate":24000}})).await;
        socket
    }
    fn config() -> BailianConfig {
        BailianConfig::new("local-test-key", BailianVoice::Cherry).unwrap()
    }
    #[tokio::test]
    async fn first_pcm_arrives_before_done_and_finish_is_not_audio_done() {
        let (endpoint, listener) = server_start().await;
        let (continue_tx, continue_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let mut socket = handshake(listener).await;
            assert_eq!(
                receive(&mut socket).await["type"],
                "input_text_buffer.append"
            );
            send(
                &mut socket,
                json!({"type":"response.created","response":{"id":"r1"}}),
            )
            .await;
            send(&mut socket, json!({"type":"response.audio.delta","response_id":"r1","delta":STANDARD.encode([1,2,3,4])})).await;
            continue_rx.await.unwrap(); // Cannot send done until consumer has received PCM.
            assert_eq!(receive(&mut socket).await["type"], "session.finish");
            send(
                &mut socket,
                json!({"type":"response.audio.done","response_id":"r1"}),
            )
            .await;
            send(
                &mut socket,
                json!({"type":"response.done","response":{"id":"r1","status":"completed"}}),
            )
            .await;
            send(&mut socket, json!({"type":"session.finished"})).await;
        });
        let mut stream = TtsStream::connect_endpoint(config(), &endpoint)
            .await
            .unwrap();
        stream.append_text("你好").await.unwrap();
        let first = tokio::time::timeout(Duration::from_secs(1), stream.next_event())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(
            first,
            TtsStreamEvent::Audio {
                generation: stream.generation(),
                pcm: vec![1, 2, 3, 4],
                sample_rate: 24000
            }
        );
        continue_tx.send(()).unwrap();
        stream.finish_input().await.unwrap();
        assert_eq!(
            stream.next_event().await.unwrap().unwrap(),
            TtsStreamEvent::Finished {
                generation: stream.generation()
            }
        );
        assert!(stream.next_event().await.is_none());
        server.await.unwrap();
    }
    #[tokio::test]
    async fn bounded_output_backpressure_and_cancel_discards_old_audio() {
        let (endpoint, listener) = server_start().await;
        let (sent_tx, sent_rx) = oneshot::channel();
        let server = tokio::spawn(async move {
            let mut socket = handshake(listener).await;
            receive(&mut socket).await;
            send(
                &mut socket,
                json!({"type":"response.created","response":{"id":"r1"}}),
            )
            .await;
            for _ in 0..32 {
                send(
                    &mut socket,
                    json!({"type":"response.audio.delta","response_id":"r1","delta":"AQI="}),
                )
                .await;
            }
            sent_tx.send(()).unwrap();
            let _ = socket.next().await;
        });
        let mut stream = TtsStream::connect_endpoint(config(), &endpoint)
            .await
            .unwrap();
        stream.append_text("你好").await.unwrap();
        sent_rx.await.unwrap();
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(stream.events.len(), QUEUE);
        assert!(!stream.task.is_finished());
        stream.cancel();
        assert!(stream.next_event().await.is_none());
        assert_eq!(
            stream.append_text("新句子").await,
            Err(TtsStreamError::Closed)
        );
        server.await.unwrap();
    }
    #[tokio::test]
    async fn provider_error_is_typed_and_does_not_expose_payload() {
        let (endpoint, listener) = server_start().await;
        let server = tokio::spawn(async move {
            let mut socket = handshake(listener).await;
            receive(&mut socket).await;
            send(
                &mut socket,
                json!({"type":"error","error":{"message":"signed-url-and-secret"}}),
            )
            .await;
        });
        let mut stream = TtsStream::connect_endpoint(config(), &endpoint)
            .await
            .unwrap();
        stream.append_text("你好").await.unwrap();
        let error = stream.next_event().await.unwrap().unwrap_err();
        assert_eq!(error, TtsStreamError::Provider);
        assert!(!error.to_string().contains("secret"));
        server.await.unwrap();
    }
    #[tokio::test]
    async fn mismatched_response_cannot_deliver_audio() {
        let (endpoint, listener) = server_start().await;
        let server = tokio::spawn(async move {
            let mut socket = handshake(listener).await;
            receive(&mut socket).await;
            send(
                &mut socket,
                json!({"type":"response.created","response":{"id":"r1"}}),
            )
            .await;
            send(
                &mut socket,
                json!({"type":"response.audio.delta","response_id":"old","delta":"AQI="}),
            )
            .await;
        });
        let mut stream = TtsStream::connect_endpoint(config(), &endpoint)
            .await
            .unwrap();
        stream.append_text("你好").await.unwrap();
        assert_eq!(
            stream.next_event().await.unwrap(),
            Err(TtsStreamError::Protocol)
        );
        server.await.unwrap();
    }
}
