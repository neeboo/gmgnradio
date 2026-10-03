//! Independent provider protocols. No conversation agent, LiveKit or device I/O.
use crate::SpeechError;
use base64::{engine::general_purpose::STANDARD, Engine};
use reqwest::{Client, RequestBuilder};
use serde_json::{json, Value};
use std::time::Duration;
use tokio::{sync::mpsc, task::JoinHandle};
use uuid::Uuid;

const MAX_TEXT: usize = 16_384;
const MAX_AUDIO: usize = 32 * 1024 * 1024;
const PACKET_BYTES: usize = 16_384;

/// Secrets intentionally have no Debug/Serialize implementation.
pub struct ElevenLabsConfig {
    api_key: String,
    pub voice_id: String,
    pub model_id: String,
}
impl ElevenLabsConfig {
    pub fn new(
        api_key: impl Into<String>,
        voice_id: impl Into<String>,
    ) -> Result<Self, SpeechError> {
        let api_key = key(api_key.into())?;
        let voice_id = voice_id.into();
        if voice_id.is_empty()
            || !voice_id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
        {
            return Err(SpeechError::InvalidResponse);
        }
        Ok(Self {
            api_key,
            voice_id,
            model_id: crate::model_catalog::ELEVEN_TTS.into(),
        })
    }
}
pub struct FishAudioConfig {
    api_key: String,
    pub reference_id: String,
    pub model: String,
}
impl FishAudioConfig {
    pub fn new(
        api_key: impl Into<String>,
        reference_id: impl Into<String>,
    ) -> Result<Self, SpeechError> {
        let reference_id = reference_id.into();
        if reference_id.is_empty() {
            return Err(SpeechError::InvalidResponse);
        }
        Ok(Self {
            api_key: key(api_key.into())?,
            reference_id,
            model: crate::model_catalog::FISH_TTS.into(),
        })
    }
}
fn key(value: String) -> Result<String, SpeechError> {
    let value = value.trim().to_owned();
    if value.is_empty() {
        return Err(SpeechError::MissingKey);
    }
    Ok(value)
}
fn client() -> Result<Client, SpeechError> {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(15))
        .timeout(Duration::from_secs(120))
        .build()
        .map_err(|_| SpeechError::Transport)
}
fn validate_text(text: &str) -> Result<(), SpeechError> {
    if text.trim().is_empty() {
        return Err(SpeechError::EmptyText);
    }
    if text.len() > MAX_TEXT {
        return Err(SpeechError::InvalidResponse);
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
pub enum AudioEvent {
    /// Signed PCM16 little-endian mono. Packets may end mid-sample; the host
    /// must preserve its trailing byte until the next packet arrives.
    Chunk {
        generation: Uuid,
        bytes: Vec<u8>,
        sample_rate: u32,
    },
    Finished {
        generation: Uuid,
    },
}
/// Eight bounded packets. Drop/cancel aborts HTTP and discards queued output.
pub struct HttpAudioStream {
    generation: Uuid,
    events: mpsc::Receiver<Result<AudioEvent, SpeechError>>,
    task: JoinHandle<()>,
    cancelled: bool,
}
impl HttpAudioStream {
    pub fn generation(&self) -> Uuid {
        self.generation
    }
    pub async fn next(&mut self) -> Option<Result<AudioEvent, SpeechError>> {
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
    async fn start(request: RequestBuilder, sample_rate: u32) -> Result<Self, SpeechError> {
        let mut response = request.send().await.map_err(|_| SpeechError::Transport)?;
        if !response.status().is_success() {
            return Err(SpeechError::Http(response.status().as_u16()));
        }
        if response
            .content_length()
            .is_some_and(|n| n > MAX_AUDIO as u64)
        {
            return Err(SpeechError::InvalidResponse);
        }
        let generation = Uuid::new_v4();
        let (sender, events) = mpsc::channel(8);
        let task = tokio::spawn(async move {
            let result = async {
                let mut received = 0usize;
                while let Some(chunk) =
                    response.chunk().await.map_err(|_| SpeechError::Transport)?
                {
                    received = received
                        .checked_add(chunk.len())
                        .ok_or(SpeechError::InvalidResponse)?;
                    if received > MAX_AUDIO {
                        return Err(SpeechError::InvalidResponse);
                    }
                    for bytes in chunk.chunks(PACKET_BYTES) {
                        if sender
                            .send(Ok(AudioEvent::Chunk {
                                generation,
                                bytes: bytes.to_vec(),
                                sample_rate,
                            }))
                            .await
                            .is_err()
                        {
                            return Ok(());
                        }
                    }
                }
                if received == 0 || !received.is_multiple_of(2) {
                    return Err(SpeechError::InvalidResponse);
                }
                let _ = sender.send(Ok(AudioEvent::Finished { generation })).await;
                Ok(())
            }
            .await;
            if let Err(error) = result {
                let _ = sender.send(Err(error)).await;
            }
        });
        Ok(Self {
            generation,
            events,
            task,
            cancelled: false,
        })
    }
}
impl Drop for HttpAudioStream {
    fn drop(&mut self) {
        self.task.abort();
    }
}

pub async fn elevenlabs_tts(
    config: &ElevenLabsConfig,
    text: &str,
) -> Result<HttpAudioStream, SpeechError> {
    validate_text(text)?;
    if !crate::model_catalog::supports("elevenlabs", false, &config.model_id) {
        return Err(SpeechError::InvalidResponse);
    }
    let endpoint = format!(
        "https://api.elevenlabs.io/v1/text-to-speech/{}/stream",
        config.voice_id
    );
    let request = client()?
        .post(endpoint)
        .query(&[("output_format", "pcm_24000")])
        .header("xi-api-key", &config.api_key)
        .json(&json!({"text":text,"model_id":config.model_id}));
    HttpAudioStream::start(request, 24000).await
}
pub async fn fish_audio_tts(
    config: &FishAudioConfig,
    text: &str,
) -> Result<HttpAudioStream, SpeechError> {
    validate_text(text)?;
    if !crate::model_catalog::supports("fish", false, &config.model) {
        return Err(SpeechError::InvalidResponse);
    }
    let request = client()?.post("https://api.fish.audio/v1/tts")
        .bearer_auth(&config.api_key).header("model", &config.model)
        .json(&json!({"text":text,"reference_id":config.reference_id,"format":"pcm","sample_rate":24000,"latency":"low"}));
    HttpAudioStream::start(request, 24000).await
}

/// Scribe wire protocol for push-to-talk. Realtime here describes transport,
/// never an always-on voice conversation. Commit only when the user releases.
pub mod elevenlabs_asr {
    use super::*;
    pub const ENDPOINT: &str = "wss://api.elevenlabs.io/v1/speech-to-text/realtime?model_id=scribe_v2_realtime&audio_format=pcm_16000&commit_strategy=manual";
    pub fn audio_chunk(pcm: &[u8]) -> Result<Value, SpeechError> {
        if pcm.is_empty() || !pcm.len().is_multiple_of(2) || pcm.len() > 32_768 {
            return Err(SpeechError::InvalidResponse);
        }
        Ok(
            json!({"message_type":"input_audio_chunk","audio_base_64":STANDARD.encode(pcm),"sample_rate":16000,"commit":false}),
        )
    }
    pub fn commit() -> Value {
        json!({"message_type":"input_audio_chunk","audio_base_64":"","sample_rate":16000,"commit":true})
    }
    #[derive(Debug, PartialEq, Eq)]
    pub enum Event {
        Started,
        Partial(String),
        Final(String),
        Failure,
    }
    pub fn decode(bytes: &[u8]) -> Result<Option<Event>, SpeechError> {
        if bytes.len() > 262_144 {
            return Err(SpeechError::InvalidResponse);
        }
        let value: Value =
            serde_json::from_slice(bytes).map_err(|_| SpeechError::InvalidResponse)?;
        let kind = value["message_type"]
            .as_str()
            .ok_or(SpeechError::InvalidResponse)?;
        Ok(match kind {
            "session_started" => Some(Event::Started),
            "partial_transcript" => Some(Event::Partial(
                value["text"]
                    .as_str()
                    .ok_or(SpeechError::InvalidResponse)?
                    .into(),
            )),
            "committed_transcript" | "committed_transcript_with_timestamps" => Some(Event::Final(
                value["text"]
                    .as_str()
                    .ok_or(SpeechError::InvalidResponse)?
                    .into(),
            )),
            "error"
            | "auth_error"
            | "quota_exceeded"
            | "rate_limited"
            | "input_error"
            | "commit_throttled"
            | "transcriber_error"
            | "invalid_request"
            | "unaccepted_terms"
            | "queue_overflow"
            | "resource_exhausted"
            | "session_time_limit_exceeded"
            | "chunk_size_exceeded"
            | "insufficient_audio_activity" => Some(Event::Failure),
            _ => None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    #[test]
    fn scribe_errors_fail_immediately_without_remote_message() {
        for kind in [
            "auth_error",
            "quota_exceeded",
            "transcriber_error",
            "input_error",
            "invalid_request",
            "error",
            "commit_throttled",
            "unaccepted_terms",
            "rate_limited",
            "queue_overflow",
            "resource_exhausted",
            "session_time_limit_exceeded",
            "chunk_size_exceeded",
            "insufficient_audio_activity",
        ] {
            let payload = json!({"message_type":kind,"error":"remote-secret"}).to_string();
            assert_eq!(
                elevenlabs_asr::decode(payload.as_bytes()).unwrap(),
                Some(elevenlabs_asr::Event::Failure)
            );
        }
        assert_eq!(
            elevenlabs_asr::decode(br#"{"message_type":"warning","warning":"remote-secret"}"#)
                .unwrap(),
            None
        );
    }
    #[test]
    fn push_to_talk_manual_commit() {
        assert!(elevenlabs_asr::ENDPOINT.contains("commit_strategy=manual"));
        assert_eq!(
            elevenlabs_asr::audio_chunk(&[0, 1]).unwrap()["commit"],
            false
        );
        assert_eq!(elevenlabs_asr::commit()["commit"], true);
        assert!(elevenlabs_asr::audio_chunk(&[1]).is_err());
        assert_eq!(
            elevenlabs_asr::decode(br#"{"message_type":"partial_transcript","text":"hi"}"#)
                .unwrap(),
            Some(elevenlabs_asr::Event::Partial("hi".into()))
        );
        assert_eq!(
            elevenlabs_asr::decode(br#"{"message_type":"committed_transcript","text":"hi"}"#)
                .unwrap(),
            Some(elevenlabs_asr::Event::Final("hi".into()))
        );
    }
    #[tokio::test]
    async fn first_packet_precedes_response_completion_and_cancel_clears_queue() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (finish, wait) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            let _ = socket.read(&mut request).await.unwrap();
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab\r\n")
                .await
                .unwrap();
            let _ = wait.await;
            let _ = socket.write_all(b"2\r\ncd\r\n0\r\n\r\n").await;
        });
        let mut stream =
            HttpAudioStream::start(client().unwrap().post(format!("http://{address}")), 24000)
                .await
                .unwrap();
        let event = tokio::time::timeout(Duration::from_secs(2), stream.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        assert_eq!(
            event,
            AudioEvent::Chunk {
                generation: stream.generation(),
                bytes: b"ab".to_vec(),
                sample_rate: 24000
            }
        );
        assert!(!server.is_finished());
        stream.cancel();
        assert!(stream.next().await.is_none());
        let _ = finish.send(());
        server.await.unwrap();
    }
    #[tokio::test]
    async fn redirects_are_not_followed_with_provider_credentials() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            let _ = socket.read(&mut request).await.unwrap();
            socket.write_all(format!("HTTP/1.1 302 Found\r\nLocation: http://{address}/leak\r\nContent-Length: 0\r\n\r\n").as_bytes()).await.unwrap();
            assert!(
                tokio::time::timeout(Duration::from_millis(150), listener.accept())
                    .await
                    .is_err()
            );
        });
        let result = HttpAudioStream::start(
            client()
                .unwrap()
                .post(format!("http://{address}"))
                .header("xi-api-key", "test-not-secret"),
            24000,
        )
        .await;
        assert!(matches!(result, Err(SpeechError::Http(302))));
        server.await.unwrap();
    }
    #[tokio::test]
    async fn tts_models_default_to_catalog_and_reject_unknown_before_network() {
        let mut fish = FishAudioConfig::new("test-key", "voice").unwrap();
        assert_eq!(fish.model, crate::model_catalog::FISH_TTS);
        fish.model = "unknown-paid-fallback".into();
        assert!(matches!(fish_audio_tts(&fish, "hello").await, Err(SpeechError::InvalidResponse)));
        let mut eleven = ElevenLabsConfig::new("test-key", "voice").unwrap();
        assert_eq!(eleven.model_id, crate::model_catalog::ELEVEN_TTS);
        eleven.model_id = "unknown".into();
        assert!(matches!(elevenlabs_tts(&eleven, "hello").await, Err(SpeechError::InvalidResponse)));
    }
}
