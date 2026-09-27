use base64::Engine;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

pub type Result<T> = std::result::Result<T, &'static str>;
pub const PNG_LIMIT: usize = 8 * 1024 * 1024;
pub const MODEL_LIMIT: usize = 32 * 1024 * 1024;
pub const FRAME_LIMIT: usize = 12 * 1024 * 1024;

#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct Source {
    pub author: String,
    pub license: String,
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
pub struct Context {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(rename = "residentScope")]
    pub resident_scope: String,
}

#[derive(Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub name: String,
    pub endpoint: String,
    pub image_path: String,
    #[serde(rename = "imageSHA256")]
    pub image_sha256: String,
    pub height_meters: f64,
    pub source: Source,
    pub idempotency_key: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub receipt: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_model_path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_error: Option<String>,
    #[serde(default = "interrupted")]
    pub backend_stage: String,
    #[serde(default)]
    pub cancel_requested: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<Context>,
}
fn interrupted() -> String {
    "interrupted".into()
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Stored {
    pub job: Job,
    pub attempted: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Submit {
    pub id: String,
    pub endpoint: String,
    pub name: String,
    pub png_base64: String,
    pub source: Source,
    pub height_meters: f64,
    #[serde(default)]
    pub context: Option<Context>,
}

pub fn identity(s: &str) -> Result<String> {
    uuid::Uuid::parse_str(s)
        .map(|u| u.hyphenated().to_string().to_uppercase())
        .map_err(|_| "invalid_id")
}
pub fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}
pub fn endpoint(s: &str) -> Result<String> {
    let u = Url::parse(s).map_err(|_| "invalid_endpoint")?;
    let authority_and_path = s
        .split_once("://")
        .map(|(_, rest)| rest)
        .ok_or("invalid_endpoint")?;
    let raw_path = authority_and_path
        .find('/')
        .map(|at| &authority_and_path[at..]);
    if raw_path.is_some_and(|p| p != "/")
        || authority_and_path.contains('@')
        || s.chars().any(char::is_control)
    {
        return Err("invalid_endpoint");
    }
    let host = u.host_str().unwrap_or("").trim_matches(['[', ']']);
    let local = host == "localhost"
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback());
    if !(u.scheme() == "https" || (u.scheme() == "http" && local))
        || u.host().is_none()
        || !u.username().is_empty()
        || u.password().is_some()
        || u.path() != "/"
        || u.query().is_some()
        || u.fragment().is_some()
        || s.contains('\\')
        || s.trim() != s
    {
        return Err("invalid_endpoint");
    }
    Ok(u.origin().ascii_serialization())
}

pub fn validate_png(bytes: &[u8]) -> Result<()> {
    if bytes.len() > PNG_LIMIT || bytes.len() < 24 || &bytes[..8] != b"\x89PNG\r\n\x1a\n" {
        return Err("invalid_png");
    }
    for off in [16, 20] {
        let size = u32::from_be_bytes(bytes[off..off + 4].try_into().unwrap());
        if !(1..=2048).contains(&size) {
            return Err("invalid_png");
        }
    }
    let mut decoder = png::Decoder::new(std::io::Cursor::new(bytes));
    decoder.set_limits(png::Limits {
        bytes: 40 * 1024 * 1024,
    });
    let mut reader = decoder.read_info().map_err(|_| "invalid_png")?;
    let size = reader.output_buffer_size();
    if size > 40 * 1024 * 1024 {
        return Err("invalid_png");
    }
    reader
        .next_frame(&mut vec![0; size])
        .map_err(|_| "invalid_png")?;
    reader.finish().map_err(|_| "invalid_png")?;
    Ok(())
}

impl Submit {
    pub fn validate(&mut self) -> Result<Vec<u8>> {
        self.id = identity(&self.id)?;
        self.endpoint = endpoint(&self.endpoint)?;
        if self.context.as_ref().is_some_and(|c| {
            [&c.world_id, &c.resident_scope]
                .iter()
                .any(|s| s.trim().is_empty() || s.len() > 200)
        }) {
            return Err("invalid_context");
        }
        if !(1..=100).contains(&self.name.chars().count())
            || self.name.chars().any(|c| "/\\\0".contains(c))
            || [&self.source.author, &self.source.license]
                .iter()
                .any(|s| s.trim().is_empty() || s.chars().count() > 200)
            || !self.height_meters.is_finite()
            || !(0.01..=3.0).contains(&self.height_meters)
            || self.png_base64.len() > PNG_LIMIT.div_ceil(3) * 4
        {
            return Err("invalid_input");
        }
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&self.png_base64)
            .map_err(|_| "invalid_png")?;
        validate_png(&bytes)?;
        Ok(bytes)
    }
}

pub fn remote_id(value: &Value) -> Result<&str> {
    let id = value["id"].as_str().ok_or("invalid_response")?;
    if id.len() != 32
        || !id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    {
        return Err("invalid_response");
    }
    Ok(id)
}

pub fn receipt(value: &Value, job: &Job) -> Result<()> {
    let id = remote_id(value)?;
    if let Some(previous) = &job.receipt {
        if remote_id(previous)? != id {
            return Err("remote_id_mismatch");
        }
    }
    let state = value["state"].as_str().ok_or("invalid_response")?;
    if ![
        "queued",
        "preflight",
        "waiting_resources",
        "submitting",
        "remote_pending",
        "running",
        "cancel_requested",
        "completed",
        "failed",
        "cancelled",
        "interrupted",
    ]
    .contains(&state)
        || value["name"].as_str() != Some(&job.name)
        || value["source"] != serde_json::to_value(&job.source).map_err(|_| "invalid_response")?
        || value["height_meters"].as_f64() != Some(job.height_meters)
        || value["compute_may_continue"].as_bool().is_none()
        || value["created_at"].as_f64().is_none()
        || value["updated_at"].as_f64().is_none()
        || (!value["reason"].is_null() && !value["reason"].is_string())
    {
        return Err("invalid_response");
    }
    if state == "completed" || !value["result"].is_null() {
        let r = &value["result"];
        for key in ["model_url", "interaction_status", "workflow_profile"] {
            if !r[key].is_string() {
                return Err("invalid_response");
            }
        }
        if r["suggested_height_meters"].as_f64().is_none()
            || !r["scale_requires_confirmation"].is_boolean()
            || r["source"] != value["source"]
        {
            return Err("invalid_response");
        }
        for key in ["affordance_candidates", "interaction_bindings"] {
            if !r[key]
                .as_array()
                .is_some_and(|a| a.iter().all(Value::is_string))
            {
                return Err("invalid_response");
            }
        }
        let i = &r["inspection"];
        for key in [
            "bytes",
            "triangles",
            "primitives",
            "materials",
            "accessors",
            "scene_transform_count",
        ] {
            if i[key].as_u64().is_none_or(|n| n > i64::MAX as u64) {
                return Err("invalid_response");
            }
        }
        if !i["sha256"]
            .as_str()
            .is_some_and(|s| s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit()))
            || !i["scale_calibrated"].is_boolean()
            || !i["accessor_bounds"].is_object()
        {
            return Err("invalid_response");
        }
        validate_bounds(&i["bounds"])?;
        for bounds in i["accessor_bounds"]
            .as_object()
            .ok_or("invalid_response")?
            .values()
        {
            validate_bounds(bounds)?;
        }
        if !i["meters_per_model_unit"].is_null() && i["meters_per_model_unit"].as_f64().is_none() {
            return Err("invalid_response");
        }
    }
    Ok(())
}

fn validate_bounds(value: &Value) -> Result<()> {
    for key in ["min", "max"] {
        if !value[key]
            .as_array()
            .is_some_and(|a| a.len() == 3 && a.iter().all(|v| v.as_f64().is_some()))
        {
            return Err("invalid_response");
        }
    }
    if !value["dimensions"].is_null()
        && !value["dimensions"]
            .as_array()
            .is_some_and(|a| a.len() == 3 && a.iter().all(|v| v.as_f64().is_some()))
    {
        return Err("invalid_response");
    }
    for key in ["units", "space"] {
        if !value[key].is_null() && !value[key].is_string() {
            return Err("invalid_response");
        }
    }
    Ok(())
}

pub fn validate_glb(bytes: &[u8], receipt: &Value) -> Result<()> {
    if bytes.len() > MODEL_LIMIT {
        return Err("model_too_large");
    }
    if bytes.len() < 20
        || &bytes[..4] != b"glTF"
        || u32::from_le_bytes(bytes[4..8].try_into().unwrap()) != 2
        || u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize != bytes.len()
    {
        return Err("invalid_glb");
    }
    let inspection = &receipt["result"]["inspection"];
    if inspection["bytes"].as_u64() != Some(bytes.len() as u64)
        || inspection["sha256"].as_str() != Some(digest(bytes).as_str())
    {
        return Err("model_integrity_failed");
    }
    Ok(())
}
pub fn stage(job: &Job) -> &'static str {
    match job.receipt.as_ref().and_then(|r| r["state"].as_str()) {
        Some("cancelled") => "cancelled",
        Some("failed") => "failed",
        Some("interrupted") => "interrupted",
        Some("completed") if job.cancel_requested => "cancel_requested",
        Some("completed") => "downloading",
        _ if job.cancel_requested => "cancel_requested",
        Some(_) => "running",
        None => "queued",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fixture() -> (Job, Value) {
        let job = Job {
            id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            name: "test".into(),
            endpoint: "https://example.invalid".into(),
            image_path: "/tmp/test.png".into(),
            image_sha256: "0".repeat(64),
            height_meters: 0.5,
            source: Source {
                author: "test".into(),
                license: "CC0".into(),
            },
            idempotency_key: "unused".into(),
            receipt: None,
            local_model_path: None,
            last_error: None,
            backend_stage: "running".into(),
            cancel_requested: false,
            context: None,
        };
        let value = json!({"id":"a".repeat(32),"state":"running","reason":null,"name":job.name,"source":job.source,"height_meters":0.5,"compute_may_continue":false,"created_at":1.0,"updated_at":1.0});
        (job, value)
    }
    #[test]
    fn running_receipt_must_not_contain_a_malformed_optional_result() {
        let (job, mut value) = fixture();
        value["result"] = json!("invalid result");
        assert!(receipt(&value, &job).is_err());
    }
    #[test]
    fn endpoints_reject_paths_even_if_url_normalization_removes_them() {
        for endpoint in [
            "https://example.com/a/..",
            "https://example.com/.",
            "https://@example.com",
            "https://exam\nple.com",
        ] {
            assert!(super::endpoint(endpoint).is_err(), "accepted {endpoint:?}");
        }
        assert_eq!(
            super::endpoint("https://EXAMPLE.com/").unwrap(),
            "https://example.com"
        );
    }
    #[test]
    fn receipt_inspection_fields_remain_decodable_by_the_client() {
        let (job, mut value) = fixture();
        value["state"] = json!("completed");
        value["result"] = json!({"model_url":"/v1/jobs/model.glb","interaction_status":"unbound","workflow_profile":"test","source":job.source,"suggested_height_meters":0.5,"scale_requires_confirmation":true,"affordance_candidates":[],"interaction_bindings":[],"inspection":{"sha256":"a".repeat(64),"bytes":24,"triangles":0,"primitives":0,"materials":0,"accessors":0,"scene_transform_count":0,"scale_calibrated":false,"accessor_bounds":{},"bounds":{"min":[0,0,0],"max":[1,1,1]}}});
        assert!(receipt(&value, &job).is_ok());
        for (pointer, invalid) in [
            (
                "/result/inspection/accessor_bounds/0",
                json!("invalid bounds"),
            ),
            (
                "/result/inspection/meters_per_model_unit",
                json!("invalid units"),
            ),
            ("/result/inspection/triangles", json!(u64::MAX)),
        ] {
            let mut broken = value.clone();
            let (parent, key) = pointer.rsplit_once('/').unwrap();
            broken.pointer_mut(parent).unwrap()[key] = invalid;
            assert!(receipt(&broken, &job).is_err(), "accepted {pointer}");
        }
    }
}
