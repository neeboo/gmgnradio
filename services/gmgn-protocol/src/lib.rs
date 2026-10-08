//! Taskd HTTP JSON/SSE envelopes shared across host platforms.
pub mod resident_grant;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{fmt, net::SocketAddr};

/// Private connection descriptor. Credentials must never appear in diagnostics.
#[derive(Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Endpoint {
    pub version: u32,
    pub address: String,
    pub token: String,
}

impl Endpoint {
    pub fn validate(&self) -> Result<SocketAddr, &'static str> {
        if self.version != 2 {
            return Err("invalid_endpoint");
        }
        self.validate_previous_descriptor()
    }
    /// Descriptor validation only, for safely replacing a v1 descriptor during
    /// startup. This never authorizes a legacy TCP business connection.
    pub fn validate_previous_descriptor(&self) -> Result<SocketAddr, &'static str> {
        let address: SocketAddr = self.address.parse().map_err(|_| "invalid_endpoint")?;
        if !matches!(self.version, 1 | 2)
            || address.ip() != std::net::Ipv4Addr::LOCALHOST
            || address.port() == 0
        {
            return Err("invalid_endpoint");
        }
        let token = uuid::Uuid::parse_str(&self.token).map_err(|_| "invalid_endpoint")?;
        if token.get_version_num() != 4 {
            return Err("invalid_endpoint");
        }
        Ok(address)
    }
}

impl fmt::Debug for Endpoint {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Endpoint")
            .field("version", &self.version)
            .field("address", &self.address)
            .field("token", &"[redacted]")
            .finish()
    }
}

/// Maximum HTTP request/JSON response payload (SSE framing excluded).
pub const FRAME_LIMIT: usize = 12 * 1024 * 1024;

/// Keep the ID as JSON until validation so malformed IDs preserve the daemon's
/// `invalid_request_id` response rather than becoming `invalid_request`.
#[derive(Debug, Serialize, Deserialize)]
pub struct Request {
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

pub fn valid_request_id(id: &Value) -> bool {
    id.as_str().is_some_and(|id| (1..=200).contains(&id.len()))
}

pub fn failure(id: Value, code: &str) -> Value {
    json!({"id": id, "error": {"code": code, "message": code}})
}

/// Replies retain their original JSON shape. Events and resident messages share
/// this wire, but must never satisfy a pending request, even when they have IDs.
pub fn is_reply_to(value: &Value, id: &str) -> bool {
    value.get("event").is_none()
        && value.get("message").is_none()
        && value.get("worldFact").is_none()
        && value.get("voice_event").is_none()
        && value.get("id").and_then(Value::as_str) == Some(id)
}

pub fn reply_error_code(value: &Value) -> Option<&str> {
    value.get("error")?.get("code")?.as_str()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_is_loopback_only_and_redacts_credentials() {
        let mut endpoint = Endpoint {
            version: 2,
            address: "127.0.0.1:2345".into(),
            token: "2e988296-09be-4ef4-996d-a4777be03580".into(),
        };
        assert!(endpoint.validate().is_ok());
        assert!(!format!("{endpoint:?}").contains(&endpoint.token));
        for address in [
            "0.0.0.0:2345",
            "192.168.1.1:2345",
            "127.0.0.1:0",
            "localhost:2345",
        ] {
            endpoint.address = address.into();
            assert!(endpoint.validate().is_err());
        }
    }

    #[test]
    fn id_validation_keeps_byte_limit_and_invalid_id_classification() {
        for id in [json!(null), json!(1), json!(""), json!("x".repeat(201))] {
            assert!(!valid_request_id(&id));
            let request: Request =
                serde_json::from_value(json!({"id": id, "method": "snapshot"})).unwrap();
            assert!(!valid_request_id(&request.id));
            assert_eq!(request.params, Value::Null);
        }
        assert!(valid_request_id(&json!("x".repeat(200))));
        assert!(valid_request_id(&json!("界".repeat(66))));
        assert!(!valid_request_id(&json!("界".repeat(67))));
    }
    #[test]
    fn legacy_descriptor_is_only_accepted_for_startup_replacement() {
        let mut endpoint = Endpoint {
            version: 1,
            address: "127.0.0.1:2345".into(),
            token: "2e988296-09be-4ef4-996d-a4777be03580".into(),
        };
        assert!(endpoint.validate_previous_descriptor().is_ok());
        assert!(endpoint.validate().is_err());
        endpoint.version = 2;
        assert!(endpoint.validate().is_ok());
        endpoint.version = 3;
        assert!(endpoint.validate_previous_descriptor().is_err());
    }

    #[test]
    fn errors_and_pushed_events_keep_existing_wire_behavior() {
        let reply = failure(json!("1"), "invalid_size_intent");
        assert_eq!(
            reply,
            json!({"id":"1","error":{"code":"invalid_size_intent","message":"invalid_size_intent"}})
        );
        assert!(is_reply_to(&reply, "1"));
        assert_eq!(reply_error_code(&reply), Some("invalid_size_intent"));
        assert!(!is_reply_to(&json!({"id":"1","event":null}), "1"));
        assert!(!is_reply_to(&json!({"id":"1","message":{}}), "1"));
        assert!(!is_reply_to(&json!({"id":1}), "1"));
        assert!(!is_reply_to(&reply, "2"));
    }
}
