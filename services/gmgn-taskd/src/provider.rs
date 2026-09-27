use crate::{
    files,
    model::{self, Job, Result, MODEL_LIMIT, PNG_LIMIT},
};
use base64::Engine;
use reqwest::{Client, Method};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

pub fn client() -> Result<Client> {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .timeout(Duration::from_secs(60))
        .connect_timeout(Duration::from_secs(15))
        .retry(reqwest::retry::never())
        .build()
        .map_err(|_| "http_unavailable")
}
async fn load(
    client: &Client,
    method: Method,
    url: String,
    token: &str,
    body: Option<Value>,
    key: Option<&str>,
    limit: usize,
) -> Result<Vec<u8>> {
    let mut req = client.request(method, &url).bearer_auth(token);
    if let Some(body) = body {
        req = req.json(&body);
    }
    if let Some(key) = key {
        req = req.header("Idempotency-Key", key);
    }
    let mut response = req.send().await.map_err(|_| "network_unavailable")?;
    if !response.status().is_success() {
        return Err(match response.status().as_u16() {
            401 | 403 => "authentication_required",
            300..=399 => "redirect_rejected",
            400 | 409 | 422 => "request_rejected",
            _ => "remote_unavailable",
        });
    }
    if response.url().as_str() != url || response.content_length().is_some_and(|n| n > limit as u64)
    {
        return Err("response_too_large_or_unsafe");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "network_unavailable")? {
        if bytes.len() + chunk.len() > limit {
            return Err("response_too_large_or_unsafe");
        }
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}
pub async fn request(
    client: &Client,
    job: &Job,
    token: &str,
    submit: bool,
    cancel: bool,
) -> Result<Value> {
    let (method, url, body, key) = if submit {
        let path = job.image_path.clone();
        let bytes = tokio::task::spawn_blocking(move || files::read(Path::new(&path), PNG_LIMIT))
            .await
            .map_err(|_| "storage_unavailable")??;
        model::validate_png(&bytes)?;
        if model::digest(&bytes) != job.image_sha256 {
            return Err("image_integrity_failed");
        }
        (
            Method::POST,
            format!("{}/v1/jobs", job.endpoint),
            Some(
                json!({"image_base64":base64::engine::general_purpose::STANDARD.encode(bytes),"name":job.name,"source":job.source,"height_meters":job.height_meters}),
            ),
            Some(job.idempotency_key.as_str()),
        )
    } else {
        let id = model::remote_id(job.receipt.as_ref().ok_or("missing_receipt")?)?;
        if cancel {
            (
                Method::POST,
                format!("{}/v1/jobs/{}/cancel", job.endpoint, id),
                Some(json!({})),
                None,
            )
        } else {
            (
                Method::GET,
                format!("{}/v1/jobs/{}", job.endpoint, id),
                None,
                None,
            )
        }
    };
    let bytes = load(client, method, url, token, body, key, 1024 * 1024).await?;
    if bytes.windows(token.len()).any(|w| w == token.as_bytes()) {
        return Err("invalid_response");
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| "invalid_response")?;
    if contains_secret(&value, token) {
        return Err("invalid_response");
    }
    model::receipt(&value, job)?;
    Ok(value)
}
pub fn contains_secret(value: &Value, token: &str) -> bool {
    match value {
        Value::String(s) => s.contains(token),
        Value::Array(a) => a.iter().any(|v| contains_secret(v, token)),
        Value::Object(m) => m
            .iter()
            .any(|(k, v)| k.contains(token) || contains_secret(v, token)),
        _ => false,
    }
}
pub async fn download(client: &Client, job: &Job, token: &str) -> Result<Vec<u8>> {
    let receipt = job.receipt.as_ref().ok_or("missing_receipt")?;
    let id = model::remote_id(receipt)?;
    let expected_path = format!("/v1/jobs/{}/model.glb", id);
    let expected = format!("{}{}", job.endpoint, expected_path);
    let actual = receipt["result"]["model_url"]
        .as_str()
        .ok_or("unsafe_download")?;
    if actual != expected_path && actual != expected {
        return Err("unsafe_download");
    }
    let bytes = load(
        client,
        Method::GET,
        expected,
        token,
        None,
        None,
        MODEL_LIMIT,
    )
    .await?;
    model::validate_glb(&bytes, receipt)?;
    Ok(bytes)
}
