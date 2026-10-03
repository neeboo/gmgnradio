//! Resident transcription wire protocol. This module performs no device I/O,
//! generates no agent replies, and cannot dispatch world tools.
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::collections::HashSet;

pub const MODEL: &str = "qwen3-asr-flash-realtime";
pub const ENDPOINT: &str =
    "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3-asr-flash-realtime";
pub const SAMPLE_RATE: u32 = 16_000;

pub fn session_update(event_id: &str) -> Value {
    json!({"event_id":event_id,"type":"session.update","session":{
        "input_audio_format":"pcm","sample_rate":SAMPLE_RATE,
        "turn_detection":null
    }})
}

/// Input is mono, signed PCM16 little-endian, already resampled by the host.
pub fn append_audio(event_id: &str, pcm: &[u8]) -> Result<Value, &'static str> {
    if pcm.is_empty() || !pcm.len().is_multiple_of(2) {
        return Err("invalid_pcm16");
    }
    Ok(json!({"event_id":event_id,"type":"input_audio_buffer.append",
        "audio":STANDARD.encode(pcm)}))
}

pub fn clear_input(event_id: &str) -> Value {
    json!({"event_id":event_id,"type":"input_audio_buffer.clear"})
}

/// Release of the push-to-talk button commits the audio already uploaded.
pub fn commit_input(event_id: &str) -> Value {
    json!({"event_id":event_id,"type":"input_audio_buffer.commit"})
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TranscriptEvent {
    SpeechStarted,
    SpeechStopped,
    Partial(String),
    Final { text: String, item_id: Option<String> },
    /// Only a provider code is retained; remote messages may contain secrets.
    Failure { code: String },
}

/// One decoder per connection generation. Reconnect calls reset; stale socket
/// events must be rejected by the transport before entering this decoder.
#[derive(Default)]
pub struct Decoder {
    completed_items: HashSet<String>,
}

impl Decoder {
    pub fn reset(&mut self) {
        self.completed_items.clear();
    }

    pub fn decode(&mut self, bytes: &[u8]) -> Result<Option<TranscriptEvent>, &'static str> {
        let value: Value = serde_json::from_slice(bytes).map_err(|_| "invalid_asr_message")?;
        let kind = value["type"].as_str().ok_or("invalid_asr_message")?;
        let event = match kind {
            "input_audio_buffer.speech_started" => TranscriptEvent::SpeechStarted,
            "input_audio_buffer.speech_stopped" => TranscriptEvent::SpeechStopped,
            "conversation.item.input_audio_transcription.delta"
            | "conversation.item.input_audio_transcription.text" => TranscriptEvent::Partial(
                format!("{}{}", value["text"].as_str().unwrap_or(""),
                    value["stash"].as_str().unwrap_or(""))),
            "conversation.item.input_audio_transcription.completed" => {
                let text = value["transcript"].as_str().ok_or("invalid_asr_message")?;
                let item_id = value["item_id"].as_str().map(str::to_owned);
                if let Some(id) = &item_id {
                    if !self.completed_items.insert(id.clone()) { return Ok(None); }
                }
                TranscriptEvent::Final { text: text.to_owned(), item_id }
            }
            "conversation.item.input_audio_transcription.failed" | "error" => {
                TranscriptEvent::Failure { code: value["error"]["code"].as_str()
                    .unwrap_or("asr_provider_error").to_owned() }
            }
            // Includes response.*, audio and tool events: ASR never responds.
            _ => return Ok(None),
        };
        Ok(Some(event))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcription_configuration_is_not_a_conversation() {
        let update = session_update("e1");
        assert_eq!(update["session"]["sample_rate"], 16000);
        assert!(update["session"]["turn_detection"].is_null());
        for key in ["tools", "instructions", "modalities", "voice"] {
            assert!(update["session"].get(key).is_none());
        }
    }

    #[test]
    fn pcm_and_clear_match_wire() {
        assert_eq!(append_audio("e2", &[0, 1]).unwrap()["audio"], "AAE=");
        assert!(append_audio("e2", &[0]).is_err());
        assert!(append_audio("e2", &[]).is_err());
        assert_eq!(clear_input("e3")["type"], "input_audio_buffer.clear");
        assert_eq!(commit_input("e4")["type"], "input_audio_buffer.commit");
    }

    #[test]
    fn partial_final_deduplication_and_reconnect() {
        let mut d = Decoder::default();
        assert_eq!(d.decode(br#"{"type":"conversation.item.input_audio_transcription.text","text":"hello","stash":" world"}"#).unwrap(),
            Some(TranscriptEvent::Partial("hello world".into())));
        let final_event = br#"{"type":"conversation.item.input_audio_transcription.completed","transcript":"hello","item_id":"a"}"#;
        assert!(matches!(d.decode(final_event).unwrap(), Some(TranscriptEvent::Final {..})));
        assert_eq!(d.decode(final_event).unwrap(), None);
        d.reset();
        assert!(d.decode(final_event).unwrap().is_some());
    }

    #[test]
    fn assistant_audio_and_tools_cannot_escape_asr() {
        let mut d = Decoder::default();
        for kind in ["response.audio.delta", "response.text.delta", "response.function_call_arguments.done"] {
            assert_eq!(d.decode(&serde_json::to_vec(&json!({"type":kind,"delta":"abc"})).unwrap()).unwrap(), None);
        }
        assert!(d.decode(b"{}").is_err());
        assert!(d.decode(b"not json").is_err());
    }
}
