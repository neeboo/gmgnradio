//! Push-to-talk streaming transport. One session recognizes one committed turn.
//! No voice conversation, automatic VAD, tool calls, or transparent reconnect.
use crate::{asr, providers::elevenlabs_asr};
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::{sync::mpsc, task::JoinHandle};
use tokio_tungstenite::{
    connect_async_with_config,
    tungstenite::{client::IntoClientRequest, protocol::WebSocketConfig, Message},
};
use uuid::Uuid;

#[derive(Clone, Copy, Debug)]
pub enum AsrProvider {
    Bailian,
    ElevenLabs,
}
/// No Debug or Serialize implementation: the key is kept private.
pub struct AsrConfig {
    provider: AsrProvider,
    api_key: String,
}
impl AsrConfig {
    pub fn new(provider: AsrProvider, key: impl Into<String>) -> Result<Self, AsrStreamError> {
        let api_key = key.into().trim().to_owned();
        if api_key.is_empty() {
            return Err(AsrStreamError::MissingKey);
        }
        Ok(Self { provider, api_key })
    }
}
#[derive(Debug, PartialEq, Eq)]
pub enum AsrStreamError {
    MissingKey,
    InvalidPcm,
    EmptyInput,
    Closed,
    Transport,
    Protocol,
    Provider,
    Timeout,
}
impl std::fmt::Display for AsrStreamError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "speech recognition {:?}", self)
    }
}
impl std::error::Error for AsrStreamError {}
#[derive(Debug, PartialEq, Eq)]
pub enum AsrStreamEvent {
    Partial { generation: Uuid, text: String },
    Final { generation: Uuid, text: String },
}
enum Command {
    Pcm(Vec<u8>),
    Commit,
}
pub struct AsrStream {
    generation: Uuid,
    commands: mpsc::Sender<Command>,
    events: mpsc::Receiver<Result<AsrStreamEvent, AsrStreamError>>,
    task: JoinHandle<()>,
    has_audio: bool,
    committed: bool,
    cancelled: bool,
}
impl AsrStream {
    pub async fn connect(config: AsrConfig) -> Result<Self, AsrStreamError> {
        let endpoint = match config.provider {
            AsrProvider::Bailian => asr::ENDPOINT,
            AsrProvider::ElevenLabs => elevenlabs_asr::ENDPOINT,
        };
        Self::connect_endpoint(config, endpoint).await
    }
    async fn connect_endpoint(config: AsrConfig, endpoint: &str) -> Result<Self, AsrStreamError> {
        let mut request = endpoint
            .into_client_request()
            .map_err(|_| AsrStreamError::Protocol)?;
        let (header, value) = match config.provider {
            AsrProvider::Bailian => ("Authorization", format!("Bearer {}", config.api_key)),
            AsrProvider::ElevenLabs => ("xi-api-key", config.api_key),
        };
        request
            .headers_mut()
            .insert(header, value.parse().map_err(|_| AsrStreamError::Protocol)?);
        let ws_config = WebSocketConfig::default()
            .max_message_size(Some(262_144))
            .max_frame_size(Some(262_144));
        let (mut socket, _) = tokio::time::timeout(
            Duration::from_secs(30),
            connect_async_with_config(request, Some(ws_config), false),
        )
        .await
        .map_err(|_| AsrStreamError::Timeout)?
        .map_err(|_| AsrStreamError::Transport)?;
        match config.provider {
            AsrProvider::Bailian => {
                wait_handshake(&mut socket, "type", "session.created").await?;
                socket
                    .send(Message::Text(
                        asr::session_update(&Uuid::new_v4().to_string())
                            .to_string()
                            .into(),
                    ))
                    .await
                    .map_err(|_| AsrStreamError::Transport)?;
                let event = wait_handshake(&mut socket, "type", "session.updated").await?;
                // Qwen manual-mode acknowledgements omit the disabled/null
                // field. A non-null VAD configuration still violates PTT.
                if !event["session"].is_object()
                    || event["session"].get("turn_detection").is_some_and(|value| !value.is_null()) {
                    return Err(AsrStreamError::Protocol);
                }
            }
            AsrProvider::ElevenLabs => {
                wait_handshake(&mut socket, "message_type", "session_started").await?;
            }
        }
        let generation = Uuid::new_v4();
        let (commands, mut command_rx) = mpsc::channel(8);
        let (event_tx, events) = mpsc::channel(8);
        let task = tokio::spawn(async move {
            let result = async {
                let mut committed = false;
                let mut decoder = asr::Decoder::default();
                loop {
                    tokio::select! {
                        command = command_rx.recv(), if !committed => {
                            let value = match (config.provider, command) {
                                (AsrProvider::Bailian, Some(Command::Pcm(pcm))) => asr::append_audio(&Uuid::new_v4().to_string(), &pcm).map_err(|_| AsrStreamError::InvalidPcm)?,
                                (AsrProvider::ElevenLabs, Some(Command::Pcm(pcm))) => elevenlabs_asr::audio_chunk(&pcm).map_err(|_| AsrStreamError::InvalidPcm)?,
                                (AsrProvider::Bailian, Some(Command::Commit)) => { committed = true; asr::commit_input(&Uuid::new_v4().to_string()) },
                                (AsrProvider::ElevenLabs, Some(Command::Commit)) => { committed = true; elevenlabs_asr::commit() },
                                (_, None) => return Ok(()),
                            };
                            socket.send(Message::Text(value.to_string().into())).await.map_err(|_| AsrStreamError::Transport)?;
                        }
                        incoming = tokio::time::timeout(Duration::from_secs(90), socket.next()) => {
                            let message = incoming.map_err(|_| AsrStreamError::Timeout)?.ok_or(AsrStreamError::Closed)?.map_err(|_| AsrStreamError::Transport)?;
                            let bytes = match message {
                                Message::Text(text) => text,
                                Message::Ping(bytes) => { socket.send(Message::Pong(bytes)).await.map_err(|_| AsrStreamError::Transport)?; continue; },
                                Message::Pong(_) => continue,
                                _ => return Err(AsrStreamError::Closed),
                            };
                            let event = match config.provider {
                                AsrProvider::Bailian => match decoder.decode(bytes.as_bytes()).map_err(|_| AsrStreamError::Protocol)? {
                                    Some(asr::TranscriptEvent::Partial(text)) => Some(AsrStreamEvent::Partial {generation, text}),
                                    Some(asr::TranscriptEvent::Final {text, ..}) => Some(AsrStreamEvent::Final {generation, text}),
                                    Some(asr::TranscriptEvent::Failure {..}) => return Err(AsrStreamError::Provider),
                                    _ => None,
                                },
                                AsrProvider::ElevenLabs => match elevenlabs_asr::decode(bytes.as_bytes()).map_err(|_| AsrStreamError::Protocol)? {
                                    Some(elevenlabs_asr::Event::Partial(text)) => Some(AsrStreamEvent::Partial {generation, text}),
                                    Some(elevenlabs_asr::Event::Final(text)) => Some(AsrStreamEvent::Final {generation, text}),
                                    Some(elevenlabs_asr::Event::Failure) => return Err(AsrStreamError::Provider),
                                    _ => None,
                                },
                            };
                            if let Some(event) = event {
                                let final_event = matches!(&event, AsrStreamEvent::Final {..});
                                if final_event && !committed { return Err(AsrStreamError::Protocol); }
                                if event_tx.send(Ok(event)).await.is_err() { return Ok(()); }
                                if final_event {
                                    if matches!(config.provider, AsrProvider::Bailian) {
                                        let finish = json!({"type":"session.finish","event_id":Uuid::new_v4().to_string()});
                                        let _ = socket.send(Message::Text(finish.to_string().into())).await;
                                    }
                                    let _ = socket.close(None).await;
                                    return Ok(());
                                }
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
            has_audio: false,
            committed: false,
            cancelled: false,
        })
    }
    pub fn generation(&self) -> Uuid {
        self.generation
    }
    /// Host provides PCM16 little-endian mono 16 kHz, at most ~1 s per chunk.
    pub async fn append_pcm(&mut self, pcm: Vec<u8>) -> Result<(), AsrStreamError> {
        if self.committed || self.cancelled {
            return Err(AsrStreamError::Closed);
        }
        if pcm.is_empty() || !pcm.len().is_multiple_of(2) || pcm.len() > 32_768 {
            return Err(AsrStreamError::InvalidPcm);
        }
        self.commands
            .send(Command::Pcm(pcm))
            .await
            .map_err(|_| AsrStreamError::Closed)?;
        self.has_audio = true;
        Ok(())
    }
    /// Called only when push-to-talk is released; final transcript follows.
    pub async fn commit(&mut self) -> Result<(), AsrStreamError> {
        if self.committed || self.cancelled {
            return Err(AsrStreamError::Closed);
        }
        if !self.has_audio {
            return Err(AsrStreamError::EmptyInput);
        }
        self.commands
            .send(Command::Commit)
            .await
            .map_err(|_| AsrStreamError::Closed)?;
        self.committed = true;
        Ok(())
    }
    pub async fn next_event(&mut self) -> Option<Result<AsrStreamEvent, AsrStreamError>> {
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
impl Drop for AsrStream {
    fn drop(&mut self) {
        self.task.abort();
    }
}
async fn wait_handshake<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    key: &str,
    expected: &str,
) -> Result<Value, AsrStreamError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    loop {
        let message = tokio::time::timeout(Duration::from_secs(30), socket.next())
            .await
            .map_err(|_| AsrStreamError::Timeout)?
            .ok_or(AsrStreamError::Closed)?
            .map_err(|_| AsrStreamError::Transport)?;
        match message {
            Message::Text(text) => {
                let value: Value =
                    serde_json::from_str(&text).map_err(|_| AsrStreamError::Protocol)?;
                if value[key] != expected {
                    return Err(AsrStreamError::Protocol);
                }
                return Ok(value);
            }
            Message::Ping(bytes) => socket
                .send(Message::Pong(bytes))
                .await
                .map_err(|_| AsrStreamError::Transport)?,
            _ => return Err(AsrStreamError::Protocol),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::{TcpListener, TcpStream};
    type Socket = tokio_tungstenite::WebSocketStream<TcpStream>;
    async fn send(socket: &mut Socket, value: Value) {
        socket
            .send(Message::Text(value.to_string().into()))
            .await
            .unwrap();
    }
    async fn receive(socket: &mut Socket) -> Value {
        serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap()).unwrap()
    }
    async fn setup(provider: AsrProvider) -> (AsrStream, Socket) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(tcp).await.unwrap();
            match provider {
                AsrProvider::Bailian => {
                    send(&mut socket, json!({"type":"session.created"})).await;
                    let update = receive(&mut socket).await;
                    assert!(update["session"]["turn_detection"].is_null());
                    assert_eq!(update["session"]["sample_rate"], 16000);
                    send(
                        &mut socket,
                        json!({"type":"session.updated","session":{"turn_detection":null}}),
                    )
                    .await;
                }
                AsrProvider::ElevenLabs => {
                    send(&mut socket, json!({"message_type":"session_started"})).await
                }
            }
            socket
        });
        let stream =
            AsrStream::connect_endpoint(AsrConfig::new(provider, "test-key").unwrap(), &endpoint)
                .await
                .unwrap();
        (stream, server.await.unwrap())
    }
    #[tokio::test]
    async fn bailian_manual_ack_omits_null_turn_detection() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (tcp, _) = listener.accept().await.unwrap();
            let mut socket = tokio_tungstenite::accept_async(tcp).await.unwrap();
            send(&mut socket, json!({"type":"session.created"})).await;
            let update = receive(&mut socket).await;
            assert!(update["session"]["turn_detection"].is_null());
            send(&mut socket, json!({"type":"session.updated","session":{"model":"qwen3-asr-flash-realtime","input_audio_format":"pcm"}})).await;
            socket
        });
        let stream = AsrStream::connect_endpoint(AsrConfig::new(AsrProvider::Bailian, "test-key").unwrap(), &endpoint).await;
        assert!(stream.is_ok(), "Manual-mode acknowledgement may omit null turn_detection");
        let mut stream = stream.unwrap(); stream.cancel();
        server.await.unwrap();
    }
    #[tokio::test]
    async fn bailian_manual_ack_rejects_vad_and_missing_session() {
        for ack in [json!({"type":"session.updated","session":{"turn_detection":{"type":"server_vad"}}}), json!({"type":"session.updated"})] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = format!("ws://{}", listener.local_addr().unwrap());
            let server = tokio::spawn(async move {
                let (tcp, _) = listener.accept().await.unwrap();
                let mut socket = tokio_tungstenite::accept_async(tcp).await.unwrap();
                send(&mut socket, json!({"type":"session.created"})).await;
                receive(&mut socket).await;
                send(&mut socket, ack).await;
            });
            let result = AsrStream::connect_endpoint(AsrConfig::new(AsrProvider::Bailian,"test-key").unwrap(), &endpoint).await;
            assert!(matches!(result, Err(AsrStreamError::Protocol)));
            server.await.unwrap();
        }
    }
    #[tokio::test]
    async fn bailian_streams_pcm_and_commits_before_final() {
        let (mut stream, mut socket) = setup(AsrProvider::Bailian).await;
        assert_eq!(stream.commit().await, Err(AsrStreamError::EmptyInput));
        stream.append_pcm(vec![0, 1]).await.unwrap();
        assert_eq!(
            receive(&mut socket).await["type"],
            "input_audio_buffer.append"
        );
        send(&mut socket, json!({"type":"conversation.item.input_audio_transcription.text","text":"你","stash":"好"})).await;
        assert_eq!(
            stream.next_event().await.unwrap().unwrap(),
            AsrStreamEvent::Partial {
                generation: stream.generation(),
                text: "你好".into()
            }
        );
        stream.commit().await.unwrap();
        assert_eq!(
            receive(&mut socket).await["type"],
            "input_audio_buffer.commit"
        );
        send(&mut socket, json!({"type":"conversation.item.input_audio_transcription.completed","transcript":"你好","item_id":"i1"})).await;
        assert_eq!(
            stream.next_event().await.unwrap().unwrap(),
            AsrStreamEvent::Final {
                generation: stream.generation(),
                text: "你好".into()
            }
        );
        assert!(stream.next_event().await.is_none());
        assert_eq!(
            stream.append_pcm(vec![0, 1]).await,
            Err(AsrStreamError::Closed)
        );
    }
    #[tokio::test]
    async fn elevenlabs_streams_manual_commit_with_final_event() {
        let (mut stream, mut socket) = setup(AsrProvider::ElevenLabs).await;
        stream.append_pcm(vec![0, 1]).await.unwrap();
        let chunk = receive(&mut socket).await;
        assert_eq!(chunk["message_type"], "input_audio_chunk");
        assert_eq!(chunk["commit"], false);
        send(
            &mut socket,
            json!({"message_type":"partial_transcript","text":"hello"}),
        )
        .await;
        assert!(matches!(
            stream.next_event().await.unwrap().unwrap(),
            AsrStreamEvent::Partial { .. }
        ));
        stream.commit().await.unwrap();
        let commit = receive(&mut socket).await;
        assert_eq!(commit["commit"], true);
        assert_eq!(commit["audio_base_64"], "");
        send(
            &mut socket,
            json!({"message_type":"committed_transcript","text":"hello world"}),
        )
        .await;
        assert_eq!(
            stream.next_event().await.unwrap().unwrap(),
            AsrStreamEvent::Final {
                generation: stream.generation(),
                text: "hello world".into()
            }
        );
        assert!(stream.next_event().await.is_none());
    }
    #[tokio::test]
    async fn cancel_drops_queued_old_generation_and_new_session_is_distinct() {
        let (mut old, mut socket) = setup(AsrProvider::ElevenLabs).await;
        old.append_pcm(vec![0, 1]).await.unwrap();
        receive(&mut socket).await;
        for _ in 0..32 {
            send(
                &mut socket,
                json!({"message_type":"partial_transcript","text":"old"}),
            )
            .await;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(old.events.len(), 8);
        let old_generation = old.generation();
        old.cancel();
        assert!(old.next_event().await.is_none());
        let (mut new, mut new_socket) = setup(AsrProvider::ElevenLabs).await;
        assert_ne!(new.generation(), old_generation);
        new.append_pcm(vec![0, 1]).await.unwrap();
        receive(&mut new_socket).await;
        send(
            &mut new_socket,
            json!({"message_type":"partial_transcript","text":"new"}),
        )
        .await;
        assert_eq!(
            new.next_event().await.unwrap().unwrap(),
            AsrStreamEvent::Partial {
                generation: new.generation(),
                text: "new".into()
            }
        );
        new.cancel();
    }
    #[tokio::test]
    async fn unsolicited_final_and_provider_messages_cannot_leak() {
        let (mut stream, mut socket) = setup(AsrProvider::ElevenLabs).await;
        send(
            &mut socket,
            json!({"message_type":"committed_transcript","text":"unsolicited"}),
        )
        .await;
        assert_eq!(
            stream.next_event().await.unwrap(),
            Err(AsrStreamError::Protocol)
        );
        let (mut stream, mut socket) = setup(AsrProvider::Bailian).await;
        send(
            &mut socket,
            json!({"type":"error","error":{"code":"secret-key","message":"signed-url"}}),
        )
        .await;
        let error = stream.next_event().await.unwrap().unwrap_err();
        assert_eq!(error, AsrStreamError::Provider);
        assert!(!error.to_string().contains("secret"));
    }
}
