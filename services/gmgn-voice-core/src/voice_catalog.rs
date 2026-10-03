//! Bounded voice catalogs. Provider credentials and remote error bodies stay private.
use crate::SpeechError;
use reqwest::{Client, RequestBuilder};
use serde_json::{json, Value};
use std::{collections::HashSet, time::Duration};

const MAX_BODY: usize = 1_048_576;
const MAX_VOICES: usize = 100;

/// Returns only stable voice identifiers and display names; never preview URLs.
pub async fn list(provider: &str, api_key: &str) -> Result<Value, SpeechError> {
    if provider == "bailian" {
        return Ok(json!({"provider":provider,"voices":[
            {"id":"Cherry","name":"Cherry · 自然亲切女声"},
            {"id":"Serena","name":"Serena · 温柔女声"},
            {"id":"Ethan","name":"Ethan · 普通话男声"},
            {"id":"Chelsie","name":"Chelsie · 活泼女声"}]}));
    }
    if api_key.trim().is_empty() || api_key.len() > 8192 {
        return Err(SpeechError::MissingKey);
    }
    let client = Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|_| SpeechError::Transport)?;
    let request = match provider {
        "elevenlabs" => client
            .get("https://api.elevenlabs.io/v2/voices")
            .query(&[("page_size", "100")])
            .header("xi-api-key", api_key),
        "fish" => client
            .get("https://api.fish.audio/model")
            .query(&[("page_size", "100"), ("page_number", "1")])
            .bearer_auth(api_key),
        _ => return Err(SpeechError::InvalidResponse),
    };
    let value = fetch(request).await?;
    parse(provider, &value)
}

async fn fetch(request: RequestBuilder) -> Result<Value, SpeechError> {
    let mut response = request.send().await.map_err(|_| SpeechError::Transport)?;
    if !response.status().is_success() {
        return Err(SpeechError::Http(response.status().as_u16()));
    }
    if response
        .content_length()
        .is_some_and(|n| n > MAX_BODY as u64)
    {
        return Err(SpeechError::InvalidResponse);
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| SpeechError::Transport)? {
        if bytes.len().saturating_add(chunk.len()) > MAX_BODY {
            return Err(SpeechError::InvalidResponse);
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| SpeechError::InvalidResponse)
}

fn parse(provider: &str, value: &Value) -> Result<Value, SpeechError> {
    let (items_key, id_key, name_key) = match provider {
        "elevenlabs" => ("voices", "voice_id", "name"),
        "fish" => ("items", "_id", "title"),
        _ => return Err(SpeechError::InvalidResponse),
    };
    let items = value[items_key]
        .as_array()
        .ok_or(SpeechError::InvalidResponse)?;
    let mut seen = HashSet::new();
    let mut voices = Vec::new();
    for item in items.iter().take(MAX_VOICES) {
        let Some(id) = item[id_key].as_str().filter(|s| {
            !s.is_empty()
                && s.len() <= 200
                && s.bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }) else {
            continue;
        };
        let Some(name) = item[name_key]
            .as_str()
            .filter(|s| !s.trim().is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
        else {
            continue;
        };
        if seen.insert(id) {
            voices.push(json!({"id":id,"name":name}));
        }
    }
    Ok(json!({"provider":provider,"voices":voices}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn bailian_catalog_is_available_without_credentials() {
        let catalog = list("bailian", "").await.unwrap();
        assert_eq!(catalog["voices"].as_array().unwrap().len(), 4);
        assert_eq!(catalog["voices"][0]["id"], "Cherry");
    }
    #[test]
    fn catalogs_normalize_and_discard_untrusted_fields() {
        for (provider, value) in [
            (
                "elevenlabs",
                json!({"voices":[{"voice_id":"one","name":"One","preview_url":"secret"},{"voice_id":"one","name":"Duplicate"},{"voice_id":"bad/path","name":"Bad"}]}),
            ),
            (
                "fish",
                json!({"items":[{"_id":"one","title":"One","description":"secret"},{"_id":"one","title":"Duplicate"},{"_id":"two","title":"bad\nname"}]}),
            ),
        ] {
            let result = parse(provider, &value).unwrap();
            assert_eq!(result["voices"], json!([{"id":"one","name":"One"}]));
            assert!(!result.to_string().contains("secret"));
        }
        assert_eq!(parse("fish", &json!({})), Err(SpeechError::InvalidResponse));
    }
    #[test]
    fn catalog_count_is_bounded() {
        let items: Vec<Value> = (0..150)
            .map(|i| json!({"_id":i.to_string(),"title":"Voice"}))
            .collect();
        assert_eq!(
            parse("fish", &json!({"items":items})).unwrap()["voices"]
                .as_array()
                .unwrap()
                .len(),
            100
        );
    }
}
