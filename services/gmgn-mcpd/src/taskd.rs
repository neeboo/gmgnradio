//! The one channel into authority: a private authenticated loopback endpoint,
//! over HTTP. No storage access belongs in this process.
//!
//! There is deliberately no other backend here. The MCP process never opens the
//! taskd private root, never links SQLite, and never takes `taskd.lock` — see
//! `tests/no_direct_authority.rs`, which fails if any of those reappear. That is
//! what makes "kill the MCP server" a non-event for the authority.

use gmgn_protocol::{is_reply_to, reply_error_code, Endpoint};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Shared ceiling the daemon enforces on both directions.
/// A client that reads a longer frame than the authority would ever write is
/// reading something that is not the authority.
pub use gmgn_protocol::FRAME_LIMIT;

/// A failure that came back from the authority, or the inability to reach it.
///
/// `Code` keeps the authority's error code **verbatim**. The MCP face is a
/// translator, not a classifier: renaming `invalid_size_intent` to something
/// friendlier here would create a second vocabulary for the same fact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TaskdError {
    /// Could not connect / write / read. The authority was not consulted.
    Unavailable(String),
    /// The authority answered `{"error":{"code":...}}`.
    Code(String),
    /// The authority answered something this client cannot interpret.
    Protocol(String),
}

impl TaskdError {
    pub fn code(&self) -> &str {
        match self {
            TaskdError::Code(code) => code,
            TaskdError::Unavailable(_) => "authority_unavailable",
            TaskdError::Protocol(_) => "authority_protocol_error",
        }
    }

    pub fn detail(&self) -> String {
        match self {
            TaskdError::Code(code) => code.clone(),
            TaskdError::Unavailable(detail) => detail.clone(),
            TaskdError::Protocol(detail) => detail.clone(),
        }
    }
}

#[derive(Clone)]
pub struct Client {
    endpoint_file: PathBuf,
}

impl Client {
    pub fn new(endpoint_file: impl Into<PathBuf>) -> Self {
        Self {
            endpoint_file: endpoint_file.into(),
        }
    }

    pub fn endpoint_file(&self) -> &Path {
        &self.endpoint_file
    }

    pub async fn call(&self, method: &str, params: Value) -> Result<Value, TaskdError> {
        self.call_with_id(method, params, 1).await
    }

    /// `id` is a **string** of 1–200 bytes on this wire, not a number.
    ///
    /// The daemon enforces exactly that (`daemon.rs`: a request whose
    /// `id.as_str()` is absent or outside 1..=200 is answered with
    /// `invalid_request_id` and a `null` id), so a numeric id is not a
    /// stylistic difference — it is a request the authority refuses. The live
    /// end-to-end run against a real daemon is what caught this; the fake peer
    /// in `tests/mcp_stdio.rs` now enforces the same rule so it cannot come back.
    pub async fn call_with_id(
        &self,
        method: &str,
        params: Value,
        id: u64,
    ) -> Result<Value, TaskdError> {
        let wire_id = id.to_string();
        let bytes = std::fs::read(&self.endpoint_file)
            .map_err(|error| TaskdError::Unavailable(format!("read endpoint: {error}")))?;
        let endpoint: Endpoint = serde_json::from_slice(&bytes)
            .map_err(|_| TaskdError::Protocol("invalid endpoint".to_owned()))?;
        let address = endpoint
            .validate()
            .map_err(|_| TaskdError::Protocol("invalid loopback endpoint".to_owned()))?;
        let request = json!({"id": wire_id, "method": method, "params": params});
        let bytes = serde_json::to_vec(&request)
            .map_err(|error| TaskdError::Protocol(format!("encode request: {error}")))?;
        if bytes.len() > FRAME_LIMIT {
            return Err(TaskdError::Protocol("request too large".to_owned()));
        }
        // No proxy or redirect may forward the bearer token outside this
        // validated daemon-owned loopback address. Dropping this future cancels
        // the outstanding request; the timeout covers headers and body.
        let client = reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(|error| TaskdError::Unavailable(format!("HTTP client: {error}")))?;
        let mut response = client
            .post(format!("http://{address}/rpc"))
            .bearer_auth(&endpoint.token)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(bytes)
            .send()
            .await
            .map_err(|error| TaskdError::Unavailable(format!("HTTP request: {error}")))?;
        let status = response.status();
        if response
            .content_length()
            .is_some_and(|length| length > FRAME_LIMIT as u64)
        {
            return Err(TaskdError::Protocol("reply too large".to_owned()));
        }
        let mut body = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|error| TaskdError::Unavailable(format!("HTTP body: {error}")))?
        {
            if body.len() + chunk.len() > FRAME_LIMIT {
                return Err(TaskdError::Protocol("reply too large".to_owned()));
            }
            body.extend_from_slice(&chunk);
        }
        let value: Value = serde_json::from_slice(&body)
            .map_err(|error| TaskdError::Protocol(format!("decode reply: {error}")))?;
        if let Some(code) = reply_error_code(&value) {
            return Err(TaskdError::Code(code.to_owned()));
        }
        if !status.is_success() {
            return Err(TaskdError::Protocol(format!("HTTP status {status}")));
        }
        if !is_reply_to(&value, &wire_id) {
            return Err(TaskdError::Protocol("reply id mismatch".to_owned()));
        }
        Ok(value)
    }
}
