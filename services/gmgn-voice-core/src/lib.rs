//! Portable speech synthesis protocol. No audio device or application runtime.
pub mod asr;
pub mod asr_stream;
pub mod providers;
pub mod model_catalog;
pub mod voice_catalog;
pub mod tts_stream;
use reqwest::{Client, Response};
use serde_json::{json, Value};
use std::{fmt, time::Duration};
use url::Url;

const ENDPOINT: &str =
    "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation";
const RESPONSE_LIMIT: usize = 1_048_576;
const AUDIO_LIMIT: usize = 16 * RESPONSE_LIMIT;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum BailianVoice {
    Cherry,
    Serena,
    Ethan,
    Chelsie,
}
impl BailianVoice {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Cherry => "Cherry",
            Self::Serena => "Serena",
            Self::Ethan => "Ethan",
            Self::Chelsie => "Chelsie",
        }
    }
}

/// Deliberately does not implement Debug or Serialize: credentials stay private.
pub struct BailianConfig {
    api_key: String,
    pub voice: BailianVoice,
    realtime_model: String,
    realtime_voice: Option<String>,
}
impl BailianConfig {
    pub fn new(api_key: impl Into<String>, voice: BailianVoice) -> Result<Self, SpeechError> {
        let api_key = api_key.into().trim().to_owned();
        if api_key.is_empty() {
            return Err(SpeechError::MissingKey);
        }
        Ok(Self { api_key, voice, realtime_model: model_catalog::BAILIAN_TTS.into(), realtime_voice: None })
    }
    /// Consume an existing cloned voice only; creation/upload is outside this core.
    pub fn with_model_voice(api_key: impl Into<String>, model: &str, voice_id: &str) -> Result<Self, SpeechError> {
        if !model_catalog::bailian_voice_supported(model, voice_id) {
            return Err(SpeechError::InvalidResponse);
        }
        let voice = match voice_id {
            "Serena" => BailianVoice::Serena,
            "Ethan" => BailianVoice::Ethan,
            "Chelsie" => BailianVoice::Chelsie,
            _ => BailianVoice::Cherry,
        };
        let mut config = Self::new(api_key, voice)?;
        config.realtime_model = model.to_owned();
        config.realtime_voice = Some(voice_id.to_owned());
        Ok(config)
    }
    pub(crate) fn realtime_voice(&self) -> &str {
        self.realtime_voice.as_deref().unwrap_or(self.voice.as_str())
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum SpeechError {
    MissingKey,
    EmptyText,
    InvalidResponse,
    Http(u16),
    Transport,
}
impl fmt::Display for SpeechError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingKey => f.write_str("speech credential is missing"),
            Self::EmptyText => f.write_str("speech text is empty"),
            Self::InvalidResponse => {
                f.write_str("speech response is invalid or exceeds its size limit")
            }
            Self::Http(code) => write!(f, "speech HTTP request failed ({code})"),
            Self::Transport => f.write_str("speech transport failed"),
        }
    }
}
impl std::error::Error for SpeechError {}

/// Scalar-based segmentation matches Swift's UnicodeScalarView, not bytes.
pub fn text_chunks(text: &str) -> Vec<String> {
    let scalars: Vec<char> = text.chars().collect();
    let mut chunks = Vec::new();
    let mut start = 0;
    while start < scalars.len() {
        let mut end = (start + 600).min(scalars.len());
        if end < scalars.len() {
            if let Some(boundary) = (start..end)
                .rev()
                .find(|&i| "。！？.!?；;\n".contains(scalars[i]))
            {
                end = boundary + 1;
            }
        }
        chunks.push(scalars[start..end].iter().collect());
        start = end;
    }
    chunks
}

fn request_body(text: &str, voice: BailianVoice) -> Value {
    json!({"model":"qwen3-tts-flash", "input":{"text":text,"voice":voice.as_str(),"language_type":"Auto"}})
}

/// Signed URLs are kept internal; upgrade HTTP to TLS without altering queries.
fn audio_url(data: &[u8]) -> Result<Url, SpeechError> {
    if data.len() > RESPONSE_LIMIT {
        return Err(SpeechError::InvalidResponse);
    }
    let value: Value = serde_json::from_slice(data).map_err(|_| SpeechError::InvalidResponse)?;
    let address = value
        .pointer("/output/audio/url")
        .and_then(Value::as_str)
        .ok_or(SpeechError::InvalidResponse)?;
    let mut url = Url::parse(address).map_err(|_| SpeechError::InvalidResponse)?;
    // Explicit default ports are rejected too; Url normalizes them away.
    let authority = address
        .split_once("://")
        .map(|(_, tail)| tail.split(['/', '?', '#']).next().unwrap_or(""))
        .unwrap_or("");
    if !matches!(url.scheme(), "https" | "http")
        || !url
            .host_str()
            .is_some_and(|host| host.ends_with(".aliyuncs.com"))
        || !url.username().is_empty()
        || url.password().is_some()
        || authority.contains(':')
        || authority.contains('@')
    {
        return Err(SpeechError::InvalidResponse);
    }
    url.set_scheme("https")
        .map_err(|_| SpeechError::InvalidResponse)?;
    Ok(url)
}

async fn bounded_body(mut response: Response, limit: usize) -> Result<Vec<u8>, SpeechError> {
    if !response.status().is_success() {
        return Err(SpeechError::Http(response.status().as_u16()));
    }
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        return Err(SpeechError::InvalidResponse);
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| SpeechError::Transport)? {
        if chunk.len() > limit.saturating_sub(body.len()) {
            return Err(SpeechError::InvalidResponse);
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

pub struct BailianTts {
    client: Client,
    config: BailianConfig,
}
impl BailianTts {
    pub fn new(config: BailianConfig) -> Result<Self, SpeechError> {
        let client = Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| SpeechError::Transport)?;
        Ok(Self { client, config })
    }
    /// Synthesize a single chunk. Drop this future to cancel its network work.
    /// Returning bytes does not imply playback or delivered-speech completion.
    pub async fn synthesize_chunk(&self, text: &str) -> Result<Vec<u8>, SpeechError> {
        if self.config.realtime_model != model_catalog::BAILIAN_TTS
            || self.config.realtime_voice() != self.config.voice.as_str()
        {
            return Err(SpeechError::InvalidResponse);
        }
        if text.trim().is_empty() {
            return Err(SpeechError::EmptyText);
        }
        let response = self
            .client
            .post(ENDPOINT)
            .bearer_auth(&self.config.api_key)
            .timeout(Duration::from_secs(90))
            .json(&request_body(text, self.config.voice))
            .send()
            .await
            .map_err(|_| SpeechError::Transport)?;
        let address = audio_url(&bounded_body(response, RESPONSE_LIMIT).await?)?;
        // No default credential header: download receives no API authorization.
        let audio = self
            .client
            .get(address)
            .timeout(Duration::from_secs(60))
            .send()
            .await
            .map_err(|_| SpeechError::Transport)?;
        let bytes = bounded_body(audio, AUDIO_LIMIT).await?;
        if bytes.is_empty() {
            return Err(SpeechError::InvalidResponse);
        }
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    #[test]
    fn scalar_segmentation_and_boundary() {
        let text = format!("{}。{}", "🙂".repeat(400), "界".repeat(400));
        let chunks = text_chunks(&text);
        assert_eq!(chunks[0].chars().count(), 401);
        assert_eq!(chunks.concat(), text);
        assert_eq!(
            text_chunks(&"界".repeat(601))
                .iter()
                .map(|s| s.chars().count())
                .collect::<Vec<_>>(),
            vec![600, 1]
        );
        assert!(text_chunks("").is_empty());
    }
    #[test]
    fn exact_request_and_credentials() {
        assert!(matches!(
            BailianConfig::new(" \n", BailianVoice::Cherry),
            Err(SpeechError::MissingKey)
        ));
        assert_eq!(
            request_body("你好", BailianVoice::Serena),
            json!({"model":"qwen3-tts-flash","input":{"text":"你好","voice":"Serena","language_type":"Auto"}})
        );
    }
    #[test]
    fn signed_url_validation() {
        let parse = |s: &str| {
            audio_url(&serde_json::to_vec(&json!({"output":{"audio":{"url":s}}})).unwrap())
        };
        assert_eq!(
            parse("http://bucket.oss.aliyuncs.com/a?signature=a%2Bb")
                .unwrap()
                .as_str(),
            "https://bucket.oss.aliyuncs.com/a?signature=a%2Bb"
        );
        for address in [
            "https://aliyuncs.com/a",
            "https://evilaliyuncs.com/a",
            "https://a.aliyuncs.com.evil/a",
            "https://u@a.aliyuncs.com/a",
            "https://a.aliyuncs.com:443/a",
            "file://a.aliyuncs.com/a",
        ] {
            assert_eq!(parse(address), Err(SpeechError::InvalidResponse));
        }
        assert_eq!(
            audio_url(&vec![b' '; RESPONSE_LIMIT + 1]),
            Err(SpeechError::InvalidResponse)
        );
    }
    async fn serve(response: &'static [u8]) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = [0; 4096];
            let count = socket.read(&mut request).await.unwrap();
            assert!(count > 0);
            socket.write_all(response).await.unwrap();
        });
        format!("http://{address}")
    }
    #[tokio::test]
    async fn production_body_limit_and_http_errors() {
        let client = Client::new();
        let url =
            serve(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntest").await;
        assert_eq!(
            bounded_body(client.get(url).send().await.unwrap(), 3).await,
            Err(SpeechError::InvalidResponse)
        );
        let url = serve(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n4\r\ntest\r\n0\r\n\r\n").await;
        assert_eq!(
            bounded_body(client.get(url).send().await.unwrap(), 3).await,
            Err(SpeechError::InvalidResponse)
        );
        let url = serve(
            b"HTTP/1.1 403 Forbidden\r\nContent-Length: 6\r\nConnection: close\r\n\r\nsecret",
        )
        .await;
        assert_eq!(
            bounded_body(client.get(url).send().await.unwrap(), 3).await,
            Err(SpeechError::Http(403))
        );
        assert!(!SpeechError::Transport.to_string().contains("http"));
    }

    #[tokio::test]
    async fn production_client_blocks_redirect_and_never_defaults_credentials() {
        let core =
            BailianTts::new(BailianConfig::new("test-secret", BailianVoice::Cherry).unwrap())
                .unwrap();
        let url = serve(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").await;
        assert_eq!(
            bounded_body(core.client.get(url).send().await.unwrap(), 10).await,
            Err(SpeechError::Http(302))
        );
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut bytes = [0; 4096];
            let count = socket.read(&mut bytes).await.unwrap();
            let request = String::from_utf8_lossy(&bytes[..count]).to_ascii_lowercase();
            assert!(!request.contains("authorization:"));
            assert!(!request.contains("test-secret"));
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")
                .await
                .unwrap();
        });
        assert_eq!(
            bounded_body(
                core.client
                    .get(format!("http://{address}"))
                    .send()
                    .await
                    .unwrap(),
                10
            )
            .await
            .unwrap(),
            b"ok"
        );
        server.await.unwrap();
    }
}
