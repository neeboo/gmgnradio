//! Supported streaming models and defaults, shared by protocols and capability discovery.
use serde_json::{json, Value};

pub const BAILIAN_TTS: &str = "qwen3-tts-flash-realtime";
pub const BAILIAN_ASR: &str = "qwen3-asr-flash-realtime";
pub const ELEVEN_TTS: &str = "eleven_flash_v2_5";
pub const ELEVEN_ASR: &str = "scribe_v2_realtime";
pub const FISH_TTS: &str = "s2.1-pro-free";

pub fn models(provider: &str, asr: bool) -> &'static [(&'static str, &'static str)] {
    match (provider, asr) {
        ("bailian", false) => &[(BAILIAN_TTS, "Qwen3 TTS Flash Realtime"),
            ("qwen3-tts-vc-realtime-2026-01-15", "Qwen3 VC Realtime · 已有克隆音色 · 2026-01-15"),
            ("qwen3-tts-vc-realtime-2025-11-27", "Qwen3 VC Realtime · 已有克隆音色 · 2025-11-27")],
        ("bailian", true) => &[(BAILIAN_ASR, "Qwen3 ASR Flash Realtime")],
        ("elevenlabs", false) => &[
            (ELEVEN_TTS, "Flash v2.5"),
            ("eleven_turbo_v2_5", "Turbo v2.5"),
            ("eleven_multilingual_v2", "Multilingual v2"),
        ],
        ("elevenlabs", true) => &[(ELEVEN_ASR, "Scribe v2 Realtime")],
        ("fish", false) => &[
            (FISH_TTS, "S2.1 Pro · 免费开发者档"),
            ("s2.1-pro", "S2.1 Pro · 付费"),
            ("s2-pro", "S2 Pro · 付费"),
        ],
        _ => &[],
    }
}
pub fn default_model(provider: &str, asr: bool) -> Option<&'static str> {
    models(provider, asr).first().map(|(id, _)| *id)
}
pub fn supports(provider: &str, asr: bool, model: &str) -> bool {
    models(provider, asr).iter().any(|(id, _)| *id == model)
}
pub fn bailian_voice_supported(model: &str, voice: &str) -> bool {
    let builtin = matches!(voice, "Cherry" | "Serena" | "Ethan" | "Chelsie");
    if model == BAILIAN_TTS { return builtin; }
    supports("bailian", false, model) && !builtin && !voice.is_empty() && voice.len() <= 200
        && voice.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}
pub fn describe(provider: &str, asr: bool) -> Value {
    Value::Array(
        models(provider, asr)
            .iter()
            .map(|(id, name)| json!({"id":id,"name":name}))
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_and_supported_models_have_one_source() {
        for provider in ["bailian", "elevenlabs", "fish"] {
            let default = default_model(provider, false).unwrap();
            assert!(supports(provider, false, default));
            assert_eq!(describe(provider, false)[0]["id"], default);
            assert!(!supports(provider, false, "unknown-paid-fallback"));
        }
        assert_eq!(default_model("fish", false), Some("s2.1-pro-free"));
        assert!(supports("fish", false, "s2-pro"));
        assert!(models("fish", true).is_empty());
    }
    #[test]
    fn existing_custom_voice_requires_supported_clone_target() {
        let model = "qwen3-tts-vc-realtime-2026-01-15";
        assert!(bailian_voice_supported(model, "qwen-tts-vc-existing123"));
        assert!(!bailian_voice_supported(BAILIAN_TTS, "qwen-tts-vc-existing123"));
        assert!(!bailian_voice_supported(model, "Cherry"));
        assert!(!bailian_voice_supported(model, ""));
        assert!(!bailian_voice_supported(model, "bad/path"));
        assert!(!bailian_voice_supported("qwen3-tts-vc-realtime", "existing"));
        let config = crate::BailianConfig::with_model_voice("test-key", model, "existing").unwrap();
        assert_eq!(config.realtime_model, model);
        assert_eq!(config.realtime_voice(), "existing");
    }
    #[tokio::test]
    async fn legacy_http_rejects_custom_voice_without_network_or_builtin_fallback() {
        let config = crate::BailianConfig::with_model_voice("test-key", "qwen3-tts-vc-realtime-2026-01-15", "existing").unwrap();
        let client = crate::BailianTts::new(config).unwrap();
        assert_eq!(client.synthesize_chunk("hello").await, Err(crate::SpeechError::InvalidResponse));
        let config = crate::BailianConfig::with_model_voice("test-key", BAILIAN_TTS, "Serena").unwrap();
        assert_eq!(config.voice, crate::BailianVoice::Serena);
    }
}
