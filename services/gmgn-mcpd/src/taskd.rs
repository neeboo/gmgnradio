//! The one channel `gmgn-mcpd` has into the authority: the `gmgn-taskd` unix
//! socket, newline-delimited JSON, exactly as the daemon already speaks it.
//!
//! There is deliberately no other backend here. The MCP process never opens the
//! taskd private root, never links SQLite, and never takes `taskd.lock` — see
//! `tests/no_direct_authority.rs`, which fails if any of those reappear. That is
//! what makes "kill the MCP server" a non-event for the authority.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

/// Same ceiling the daemon enforces on both directions
/// (`services/gmgn-taskd/src/model.rs`: `FRAME_LIMIT = 12 * 1024 * 1024`).
/// A client that reads a longer frame than the authority would ever write is
/// reading something that is not the authority.
pub const FRAME_LIMIT: usize = 12 * 1024 * 1024;

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
    socket: PathBuf,
}

impl Client {
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
        }
    }

    pub fn socket(&self) -> &Path {
        &self.socket
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
        let stream = UnixStream::connect(&self.socket).await.map_err(|error| {
            TaskdError::Unavailable(format!("connect {}: {error}", self.socket.display()))
        })?;
        let (read_half, mut write_half) = stream.into_split();
        let request = json!({"id": wire_id, "method": method, "params": params});
        let mut bytes = serde_json::to_vec(&request)
            .map_err(|error| TaskdError::Protocol(format!("encode request: {error}")))?;
        bytes.push(b'\n');
        write_half
            .write_all(&bytes)
            .await
            .map_err(|error| TaskdError::Unavailable(format!("write: {error}")))?;
        write_half
            .flush()
            .await
            .map_err(|error| TaskdError::Unavailable(format!("flush: {error}")))?;

        let mut reader = BufReader::new(read_half);
        loop {
            let frame = read_frame(&mut reader).await?;
            let Some(frame) = frame else {
                return Err(TaskdError::Protocol(
                    "authority closed before replying".to_owned(),
                ));
            };
            let value: Value = serde_json::from_slice(&frame)
                .map_err(|error| TaskdError::Protocol(format!("decode reply: {error}")))?;
            // Events and business messages are pushed on the same connection for
            // subscribers. This client never subscribes, but a reply that is not
            // addressed to this request must never be mistaken for one.
            if value.get("event").is_some() || value.get("message").is_some() {
                continue;
            }
            if value.get("id").and_then(Value::as_str) != Some(wire_id.as_str()) {
                continue;
            }
            if let Some(code) = value
                .get("error")
                .and_then(|error| error.get("code"))
                .and_then(Value::as_str)
            {
                return Err(TaskdError::Code(code.to_owned()));
            }
            return Ok(value);
        }
    }
}

async fn read_frame(
    reader: &mut BufReader<tokio::net::unix::OwnedReadHalf>,
) -> Result<Option<Vec<u8>>, TaskdError> {
    let mut frame = Vec::new();
    loop {
        let buffer = reader
            .fill_buf()
            .await
            .map_err(|error| TaskdError::Unavailable(format!("read: {error}")))?;
        if buffer.is_empty() {
            return if frame.is_empty() {
                Ok(None)
            } else {
                Err(TaskdError::Protocol("incomplete frame".to_owned()))
            };
        }
        let count = buffer
            .iter()
            .position(|byte| *byte == b'\n')
            .map(|at| at + 1)
            .unwrap_or(buffer.len());
        if frame.len() + count > FRAME_LIMIT {
            return Err(TaskdError::Protocol("frame too large".to_owned()));
        }
        let done = buffer[count - 1] == b'\n';
        frame.extend_from_slice(&buffer[..count]);
        let consumed = count;
        reader.consume(consumed);
        if done {
            frame.pop();
            if frame.last() == Some(&b'\r') {
                frame.pop();
            }
            return Ok(Some(frame));
        }
    }
}
