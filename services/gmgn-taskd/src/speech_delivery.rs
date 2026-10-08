//! Durable speech delivery authority. Provider EOF is never a device receipt.
use crate::{
    model::{digest, Result},
    store::Database,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::Notify;

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Identity {
    #[serde(rename = "scopeID")]
    pub scope_id: String,
    #[serde(rename = "hostSessionID")]
    pub host_session_id: String,
    #[serde(rename = "utteranceID")]
    pub utterance_id: String,
    pub generation: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub provenance: Option<Value>,
}
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS speech_delivery_lanes(scope TEXT PRIMARY KEY,payload TEXT NOT NULL);")
        .map_err(|_| "storage_unavailable")
}
fn load(c: &Connection, scope: &str) -> Result<Value> {
    let s = c
        .query_row(
            "SELECT payload FROM speech_delivery_lanes WHERE scope=?1",
            [scope],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    s.map(|s| serde_json::from_str(&s).map_err(|_| "speech_delivery_invalid_state"))
        .unwrap_or_else(|| Ok(json!({"revision":0,"generation":0,"hostSessionID":"","states":[]})))
}
fn save(c: &Connection, scope: &str, s: &Value) -> Result<()> {
    c.execute("INSERT INTO speech_delivery_lanes VALUES(?1,?2) ON CONFLICT(scope) DO UPDATE SET payload=excluded.payload",params![scope,crate::canonical_json::to_string(s).map_err(|_|"speech_delivery_invalid_state")?]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn bump(s: &mut Value, key: &str) -> Result<u64> {
    let n = s[key]
        .as_u64()
        .ok_or("speech_delivery_invalid_state")?
        .checked_add(1)
        .filter(|n| *n <= i64::MAX as u64)
        .ok_or("speech_delivery_invalid_state")?;
    s[key] = json!(n);
    Ok(n)
}
fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("speech_delivery_invalid_input")
}
fn provenance(p: &Value) -> Result<Option<Value>> {
    let Some(value) = p.get("provenance").filter(|v| !v.is_null()) else {
        return Ok(None);
    };
    let fields = value.as_object().ok_or("speech_delivery_invalid_input")?;
    for (key, value) in fields {
        if !matches!(key.as_str(), "worldID" | "residentScope" | "runID")
            || value.as_str().is_none_or(|s| s.is_empty() || s.len() > 256)
        {
            return Err("speech_delivery_invalid_input");
        }
    }
    Ok(Some(value.clone()))
}
fn live(d: &Value) -> bool {
    matches!(
        d["status"].as_str(),
        Some("starting" | "playing" | "draining" | "stopping")
    )
}
fn view(s: &Value) -> Value {
    let states = s["states"].as_array().unwrap();
    let ticket = if states.iter().any(live) {
        Value::Null
    } else {
        states.iter().find(|d|d["status"]=="queued").map(|d|json!({"identity":d["identity"],"textSHA256":d["textSHA256"],"textBytes":d["textBytes"]})).unwrap_or(Value::Null)
    };
    let stops: Vec<Value> = states
        .iter()
        .filter(|d| d["status"] == "stopping")
        .map(|d| json!({"identity":d["identity"],"stopRequestID":d["stopRequestID"]}))
        .collect();
    json!({"revision":s["revision"],"states":states,"ticket":ticket,"stopCommands":stops})
}
pub fn recover(c: &mut Connection) -> Result<()> {
    let rows = {
        let mut q = c
            .prepare("SELECT scope,payload FROM speech_delivery_lanes")
            .map_err(|_| "storage_unavailable")?;
        let rows = q
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))
            .map_err(|_| "storage_unavailable")?;
        rows.collect::<std::result::Result<Vec<_>, _>>()
            .map_err(|_| "storage_unavailable")?
    };
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    for (scope, raw) in rows {
        let mut s: Value =
            serde_json::from_str(&raw).map_err(|_| "speech_delivery_invalid_state")?;
        let mut changed = false;
        for d in s["states"]
            .as_array_mut()
            .ok_or("speech_delivery_invalid_state")?
        {
            if live(d) || d["status"] == "queued" {
                d["status"] = json!("unknown");
                d["packets"] = json!([]);
                changed = true;
            }
        }
        if changed {
            bump(&mut s, "revision")?;
            save(&tx, &scope, &s)?;
        }
    }
    tx.commit().map_err(|_| "storage_unavailable")
}

/// All transitions execute in the existing database worker, atomically.
fn transition(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let result = transition_in(&tx, method, p)?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(result)
}
pub(crate) fn transition_in(tx: &Connection, method: &str, p: &Value) -> Result<Value> {
    let identity = p.get("identity");
    let lane = identity.unwrap_or(p);
    let scope = text(lane, "scopeID")?;
    let host = text(lane, "hostSessionID")?;
    let mut s = load(&tx, scope)?;
    if s["hostSessionID"] != "" && s["hostSessionID"] != host {
        if !matches!(method, "speech_delivery_enqueue" | "speech_delivery_claim")
            || s["states"]
                .as_array()
                .unwrap()
                .iter()
                .any(|d| live(d) || d["status"] == "queued")
        {
            return Err("speech_delivery_stale_session");
        }
        // Only a fresh enqueue may claim a lane whose former owner has no live output.
        s["hostSessionID"] = json!(host);
        s["states"] = json!([]);
    }
    if method == "speech_delivery_read" {
        return Ok(view(&s));
    }
    s["hostSessionID"] = json!(host);
    let mut changed = true;
    if method == "speech_delivery_enqueue" {
        let utterance = text(p, "utteranceID")?;
        let provenance = provenance(p)?;
        let input = p["text"]
            .as_str()
            .filter(|s| !s.trim().is_empty() && s.len() <= 16384)
            .ok_or("speech_delivery_invalid_input")?;
        let hash = digest(input.as_bytes());
        if let Some(d) = s["states"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["identity"]["utteranceID"] == utterance)
        {
            if d["textSHA256"] != hash || d["identity"].get("provenance") != provenance.as_ref() {
                return Err("speech_delivery_receipt_conflict");
            }
            return Ok(view(&s));
        }
        let mode = p["mode"].as_str().ok_or("speech_delivery_invalid_input")?;
        if !["fifo", "replace"].contains(&mode) {
            return Err("speech_delivery_invalid_input");
        }
        if mode == "replace" {
            stop_all(&mut s, true)?;
        }
        if s["states"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|d| d["status"] == "queued")
            .count()
            >= 8
        {
            return Err("speech_delivery_queue_full");
        }
        let generation = bump(&mut s, "generation")?;
        let id = Identity {
            scope_id: scope.into(),
            host_session_id: host.into(),
            utterance_id: utterance.into(),
            generation,
            provenance,
        };
        s["states"].as_array_mut().unwrap().push(json!({"identity":id,"status":"queued","textSHA256":hash,"textBytes":input.len(),"packets":[],"nextSequence":0,"totalFrames":0,"playedFrames":0,"deviceStarted":false,"eof":false}));
        // Keep bounded terminal history; active entries are never evicted.
        while s["states"].as_array().unwrap().len() > 32 {
            let a = s["states"].as_array_mut().unwrap();
            let i = a
                .iter()
                .position(|d| !live(d) && d["status"] != "queued")
                .ok_or("speech_delivery_queue_full")?;
            a.remove(i);
        }
    } else if method == "speech_delivery_claim" {
        // Internal owner claim never turns unknown delivery into success.
    } else if method == "speech_delivery_cancel" {
        stop_all(&mut s, true)?;
    } else if method == "speech_delivery_receipt" && p["kind"] == "failed" {
        if !s["states"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["identity"] == p["identity"] && live(d))
        {
            return Err("speech_delivery_stale_session");
        }
        stop_all(&mut s, false)?;
    } else {
        let id: Identity =
            serde_json::from_value(identity.cloned().ok_or("speech_delivery_invalid_input")?)
                .map_err(|_| "speech_delivery_invalid_input")?;
        let head = s["states"]
            .as_array()
            .unwrap()
            .iter()
            .find(|d| d["status"] == "queued")
            .map(|d| d["identity"].clone());
        let any_active = s["states"].as_array().unwrap().iter().any(live);
        let d = s["states"]
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|d| d["identity"]["utteranceID"] == id.utterance_id)
            .ok_or("speech_delivery_stale_session")?;
        if d["identity"]
            != serde_json::to_value(&id).map_err(|_| "speech_delivery_invalid_input")?
        {
            return Err("speech_delivery_stale_session");
        }
        let status = d["status"].as_str().unwrap_or("").to_owned();
        match method {
            "bind" => {
                if status != "queued" || any_active || head.as_ref() != Some(&d["identity"]) {
                    return Err("speech_delivery_start_rejected");
                }
                if digest(
                    p["text"]
                        .as_str()
                        .ok_or("speech_delivery_invalid_input")?
                        .as_bytes(),
                ) != d["textSHA256"]
                {
                    return Err("speech_delivery_receipt_conflict");
                }
                d["status"] = json!("starting");
            }
            "packet" => {
                if !matches!(status.as_str(), "starting" | "playing") {
                    return Err("speech_delivery_stale_session");
                }
                let frames = p["frameCount"]
                    .as_u64()
                    .filter(|n| *n > 0 && *n <= 4096)
                    .ok_or("speech_delivery_invalid_input")?;
                let pending =
                    d["totalFrames"].as_u64().unwrap() - d["playedFrames"].as_u64().unwrap();
                if pending + frames > 12000 {
                    return Err("speech_delivery_window_full");
                }
                let seq = d["nextSequence"].as_u64().unwrap();
                let packets = d["packets"].as_array_mut().unwrap();
                if packets.len() >= 128 {
                    let i = packets
                        .iter()
                        .position(|x| x["played"] == true)
                        .ok_or("speech_delivery_window_full")?;
                    packets.remove(i);
                }
                packets.push(
                    json!({"sequence":seq,"frameCount":frames,"scheduled":false,"played":false}),
                );
                d["nextSequence"] =
                    json!(seq.checked_add(1).ok_or("speech_delivery_invalid_state")?);
                d["totalFrames"] = json!(d["totalFrames"]
                    .as_u64()
                    .unwrap()
                    .checked_add(frames)
                    .ok_or("speech_delivery_invalid_state")?);
            }
            "eof" => {
                if !matches!(status.as_str(), "starting" | "playing") {
                    return Err("speech_delivery_stale_session");
                }
                if d["totalFrames"] == 0 {
                    return Err("speech_delivery_empty_output");
                }
                d["eof"] = json!(true);
                d["status"] = json!("draining");
            }
            "speech_delivery_receipt" => {
                match p["kind"].as_str().ok_or("speech_delivery_invalid_input")? {
                    "stopped" => {
                        if status == "stopped" && d["stopRequestID"] == p["stopRequestID"] {
                            changed = false;
                        } else if status != "stopping" || d["stopRequestID"] != p["stopRequestID"] {
                            return Err("speech_delivery_stale_session");
                        } else {
                            d["status"] = json!("stopped");
                            d["packets"] = json!([]);
                        }
                    }
                    "device_started" => {
                        if !matches!(
                            status.as_str(),
                            "starting" | "playing" | "draining" | "delivered"
                        ) {
                            return Err("speech_delivery_stale_session");
                        }
                        changed = d["deviceStarted"] != true;
                        d["deviceStarted"] = json!(true);
                        if status == "starting" {
                            d["status"] = json!("playing");
                        }
                    }
                    kind @ ("scheduled" | "played") => {
                        if !matches!(
                            status.as_str(),
                            "starting" | "playing" | "draining" | "delivered"
                        ) {
                            return Err("speech_delivery_stale_session");
                        }
                        let seq = p["sequence"]
                            .as_u64()
                            .ok_or("speech_delivery_invalid_input")?;
                        let packet = d["packets"]
                            .as_array_mut()
                            .unwrap()
                            .iter_mut()
                            .find(|x| x["sequence"] == seq)
                            .ok_or("speech_delivery_receipt_conflict")?;
                        if packet["frameCount"] != p["frameCount"]
                            || kind == "played" && packet["scheduled"] != true
                        {
                            return Err("speech_delivery_receipt_conflict");
                        }
                        changed = packet[kind] != true;
                        packet[kind] = json!(true);
                        if changed && kind == "played" {
                            d["playedFrames"] = json!(
                                d["playedFrames"].as_u64().unwrap()
                                    + p["frameCount"].as_u64().unwrap()
                            );
                        }
                    }
                    _ => return Err("speech_delivery_invalid_input"),
                }
            }
            _ => return Err("unknown_method"),
        }
        if d["eof"] == true && d["deviceStarted"] == true && d["totalFrames"] == d["playedFrames"] {
            d["status"] = json!("delivered");
        }
    }
    if changed {
        bump(&mut s, "revision")?;
        save(&tx, scope, &s)?;
    }
    let result = view(&s);
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        c
    }
    fn enqueue(c: &mut Connection, u: &str, mode: &str) -> Value {
        transition(c,"speech_delivery_enqueue",&json!({"scopeID":"chat","hostSessionID":"host","utteranceID":u,"text":"hello","mode":mode})).unwrap()
    }
    fn packet(c: &mut Connection, id: &Value, n: u64) -> Value {
        transition(c, "packet", &json!({"identity":id,"frameCount":n})).unwrap()
    }
    fn receipt(c: &mut Connection, id: &Value, k: &str, seq: u64, n: u64) -> Result<Value> {
        transition(
            c,
            "speech_delivery_receipt",
            &json!({"identity":id,"kind":k,"sequence":seq,"frameCount":n}),
        )
    }
    fn bind(c: &mut Connection, id: &Value) {
        transition(c, "bind", &json!({"identity":id,"text":"hello"})).unwrap();
    }
    #[test]
    fn eof_is_not_delivery_and_receipts_are_exact_and_idempotent() {
        let mut c = db();
        let id = enqueue(&mut c, "one", "fifo")["ticket"]["identity"].clone();
        bind(&mut c, &id);
        packet(&mut c, &id, 64);
        let eof = transition(&mut c, "eof", &json!({"identity":id})).unwrap();
        assert_eq!(eof["states"][0]["status"], "draining");
        assert!(receipt(&mut c, &id, "played", 0, 64).is_err());
        assert!(receipt(&mut c, &id, "scheduled", 0, 63).is_err());
        receipt(&mut c, &id, "device_started", 0, 0).unwrap();
        receipt(&mut c, &id, "scheduled", 0, 64).unwrap();
        let done = receipt(&mut c, &id, "played", 0, 64).unwrap();
        assert_eq!(done["states"][0]["status"], "delivered");
        assert_eq!(
            receipt(&mut c, &id, "played", 0, 64).unwrap()["revision"],
            done["revision"]
        );
    }
    #[test]
    fn replacement_waits_for_real_stop_and_rejects_old_generation() {
        let mut c = db();
        let old = enqueue(&mut c, "one", "fifo")["ticket"]["identity"].clone();
        bind(&mut c, &old);
        packet(&mut c, &old, 64);
        let replaced = enqueue(&mut c, "two", "replace");
        assert!(replaced["ticket"].is_null());
        assert!(receipt(&mut c, &old, "scheduled", 0, 64).is_err());
        let command = &replaced["stopCommands"][0];
        assert!(transition(
            &mut c,
            "speech_delivery_receipt",
            &json!({"identity":command["identity"],"kind":"stopped","stopRequestID":"wrong"})
        )
        .is_err());
        let next=transition(&mut c,"speech_delivery_receipt",&json!({"identity":command["identity"],"kind":"stopped","stopRequestID":command["stopRequestID"]})).unwrap();
        assert_eq!(next["ticket"]["identity"]["utteranceID"], "two");
    }
    #[test]
    fn fifo_start_and_pcm_window_are_rust_owned() {
        let mut c = db();
        let one = enqueue(&mut c, "one", "fifo");
        let id = one["ticket"]["identity"].clone();
        let two = enqueue(&mut c, "two", "fifo");
        let other = two["states"][1]["identity"].clone();
        assert!(transition(&mut c, "bind", &json!({"identity":other,"text":"hello"})).is_err());
        bind(&mut c, &id);
        packet(&mut c, &id, 4096);
        packet(&mut c, &id, 4096);
        assert_eq!(
            transition(&mut c, "packet", &json!({"identity":id,"frameCount":4096})),
            Err("speech_delivery_window_full")
        );
        receipt(&mut c, &id, "scheduled", 0, 4096).unwrap();
        receipt(&mut c, &id, "played", 0, 4096).unwrap();
        packet(&mut c, &id, 4096);
    }
    #[test]
    fn crash_becomes_unknown_without_replay() {
        let mut c = db();
        let id = enqueue(&mut c, "one", "fifo")["ticket"]["identity"].clone();
        bind(&mut c, &id);
        enqueue(&mut c, "two", "fifo");
        recover(&mut c).unwrap();
        let v = transition(
            &mut c,
            "speech_delivery_read",
            &json!({"scopeID":"chat","hostSessionID":"host"}),
        )
        .unwrap();
        assert!(v["ticket"].is_null());
        assert!(v["states"]
            .as_array()
            .unwrap()
            .iter()
            .all(|d| d["status"] == "unknown"));
        assert!(receipt(&mut c, &id, "device_started", 0, 0).is_err());
        assert!(transition(&mut c, "bind", &json!({"identity":id,"text":"hello"})).is_err());
    }
    #[test]
    fn failure_requires_device_stop_before_next() {
        let mut c = db();
        let id = enqueue(&mut c, "one", "fifo")["ticket"]["identity"].clone();
        bind(&mut c, &id);
        let failed = receipt(&mut c, &id, "failed", 0, 0).unwrap();
        assert_eq!(failed["stopCommands"].as_array().unwrap().len(), 1);
        assert!(enqueue(&mut c, "two", "fifo")["ticket"].is_null());
    }
    #[test]
    fn database_never_contains_text_or_audio() {
        let mut c = db();
        enqueue(&mut c, "one", "fifo");
        let raw: String = c
            .query_row("SELECT payload FROM speech_delivery_lanes", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert!(!raw.contains("hello"));
        assert!(!raw.contains("audioBase64"));
    }
    #[test]
    fn null_provenance_is_omitted_and_identity_round_trips() {
        let mut c = db();
        let v = transition(&mut c,"speech_delivery_enqueue",&json!({"scopeID":"chat","hostSessionID":"host","utteranceID":"one","text":"hello","mode":"fifo","provenance":null})).unwrap();
        let raw = v["ticket"]["identity"].clone();
        assert!(raw.get("provenance").is_none());
        assert!(raw.get("worldID").is_none());
        let id: Identity = serde_json::from_value(raw.clone()).unwrap();
        assert_eq!(serde_json::to_value(id).unwrap(), raw);
        bind(&mut c, &raw);
    }
    #[test]
    fn provenance_accepts_only_bounded_optional_identity_metadata() {
        let base = json!({"scopeID":"chat","hostSessionID":"host","utteranceID":"one","text":"hello","mode":"fifo"});
        for bad in [
            json!({"apiKey":"secret"}),
            json!({"worldID":{"text":"raw"}}),
            json!({"runID":"x".repeat(257)}),
            json!({"residentScope":""}),
            json!(["world"]),
        ] {
            let mut c = db();
            let mut p = base.clone();
            p["provenance"] = bad;
            assert_eq!(
                transition(&mut c, "speech_delivery_enqueue", &p),
                Err("speech_delivery_invalid_input")
            );
            assert_eq!(
                c.query_row("SELECT COUNT(*) FROM speech_delivery_lanes", [], |r| r
                    .get::<_, i64>(0))
                    .unwrap(),
                0
            );
        }
        let mut c = db();
        let mut p = base;
        p["provenance"] = json!({"worldID":"actual-world","runID":"actual-run"});
        let v = transition(&mut c, "speech_delivery_enqueue", &p).unwrap();
        assert_eq!(v["ticket"]["identity"]["provenance"], p["provenance"]);
        p["provenance"]["runID"] = json!("another-run");
        assert_eq!(
            transition(&mut c, "speech_delivery_enqueue", &p),
            Err("speech_delivery_receipt_conflict")
        );
    }
}
fn stop_all(s: &mut Value, cancel_queued: bool) -> Result<()> {
    let generation = bump(s, "generation")?;
    for d in s["states"].as_array_mut().unwrap() {
        if cancel_queued && d["status"] == "queued" {
            d["status"] = json!("cancelled");
        } else if live(d) && d["status"] != "stopping" {
            d["identity"]["generation"] = json!(generation);
            d["status"] = json!("stopping");
            d["stopRequestID"] = json!(uuid::Uuid::new_v4().to_string());
        }
    }
    Ok(())
}
pub struct SpeechDeliveryService {
    db: Database,
    changed: Arc<Notify>,
}
impl SpeechDeliveryService {
    pub fn new(db: Database) -> Self {
        Self {
            db,
            changed: Arc::new(Notify::new()),
        }
    }
    pub async fn request(&self, method: &str, p: Value) -> Result<Value> {
        if method == "speech_delivery_wait" {
            let timeout = p["timeoutMS"].as_u64().unwrap_or(30000).min(30000);
            let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(timeout);
            loop {
                let notified = self.changed.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                let v = self.request_once("speech_delivery_read", p.clone()).await?;
                if v["revision"] != p["afterRevision"] {
                    return Ok(v);
                }
                if tokio::time::timeout_at(deadline, notified).await.is_err() {
                    return Ok(v);
                }
            }
        }
        self.request_once(method, p).await
    }
    async fn request_once(&self, method: &str, p: Value) -> Result<Value> {
        let m = method.to_owned();
        let v = self
            .db
            .call(move |s| {
                if matches!(m.as_str(), "chat_speech_event" | "chat_speech_read") {
                    crate::chat_speech::request(&mut s.connection, &m, &p)
                } else {
                    transition(&mut s.connection, &m, &p)
                }
            })
            .await?;
        if method != "speech_delivery_read" {
            self.changed.notify_waiters();
        }
        Ok(v)
    }
    pub async fn bind(&self, id: &Identity, text: &str) -> Result<()> {
        self.request_once("bind", json!({"identity":id,"text":text}))
            .await
            .map(|_| ())
    }
    pub async fn packet(&self, id: &Identity, frames: u64) -> Result<u64> {
        loop {
            let notified = self.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            match self
                .request_once("packet", json!({"identity":id,"frameCount":frames}))
                .await
            {
                Ok(v) => {
                    return v["states"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|d| d["identity"]["utteranceID"] == id.utterance_id)
                        .and_then(|d| d["nextSequence"].as_u64())
                        .map(|n| n - 1)
                        .ok_or("speech_delivery_invalid_state")
                }
                Err("speech_delivery_window_full") => notified.await,
                Err(e) => return Err(e),
            }
        }
    }
    pub async fn eof(&self, id: &Identity) -> Result<()> {
        self.request_once("eof", json!({"identity":id}))
            .await
            .map(|_| ())
    }
    pub async fn delivered(&self, id: &Identity) -> Result<()> {
        loop {
            let notified = self.changed.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            let v = self
                .request_once(
                    "speech_delivery_read",
                    json!({"scopeID":id.scope_id,"hostSessionID":id.host_session_id}),
                )
                .await?;
            let d = v["states"]
                .as_array()
                .unwrap()
                .iter()
                .find(|d| d["identity"]["utteranceID"] == id.utterance_id)
                .ok_or("speech_delivery_stale_session")?;
            if d["identity"]
                != serde_json::to_value(id).map_err(|_| "speech_delivery_invalid_input")?
            {
                return Err("speech_delivery_stale_session");
            }
            match d["status"].as_str() {
                Some("delivered") => return Ok(()),
                Some("starting" | "playing" | "draining") => notified.await,
                _ => return Err("speech_delivery_stale_session"),
            }
        }
    }
}
