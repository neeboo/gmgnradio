//! Reply selection is durable; rendering a chat event is never a speech receipt.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS chat_speech_lanes(scope TEXT PRIMARY KEY,host TEXT NOT NULL,request TEXT NOT NULL,state TEXT NOT NULL,source TEXT,utterance TEXT);CREATE TABLE IF NOT EXISTS chat_speech_requests(scope TEXT NOT NULL,host TEXT NOT NULL,request TEXT NOT NULL,source TEXT,PRIMARY KEY(scope,host,request));CREATE UNIQUE INDEX IF NOT EXISTS chat_speech_source_once ON chat_speech_requests(scope,source) WHERE source IS NOT NULL;").map_err(|_| "storage_unavailable")
}
fn field<'a>(p: &'a Value, key: &str) -> Result<&'a str> {
    p[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("chat_speech_invalid_input")
}
fn completed_reply(c: &Connection, source: &Value) -> Result<String> {
    validate_source(source)?;
    match field(source, "kind")? {
        "chat" => {
            let row: Option<(String,String,Option<String>)> = c.query_row("SELECT host_session,state,reply FROM chat_requests WHERE backend=?1 AND scope=?2 AND request=?3",params![field(source,"backend")?,field(source,"scopeID")?,field(source,"requestID")?],|r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional().map_err(|_| "storage_unavailable")?;
            let (host, state, reply) = row.ok_or("chat_speech_source_missing")?;
            if host != field(source, "hostSessionID")? || state != "completed" {
                return Err("chat_speech_source_not_completed");
            }
            reply.ok_or("chat_speech_source_not_completed")
        }
        "world" => {
            let row: Option<(String,Option<String>,Option<String>,Option<String>)> = c.query_row("SELECT state,run,session,receipt FROM agent_loop_events WHERE world=?1 AND scope=?2 AND event=?3",params![field(source,"worldID")?,field(source,"residentScope")?,field(source,"eventID")?],|r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(|_| "storage_unavailable")?;
            let (state, run, host, receipt) = row.ok_or("chat_speech_source_missing")?;
            if state != "completed"
                || run.as_deref() != Some(field(source, "runID")?)
                || host.as_deref() != Some(field(source, "hostSessionID")?)
            {
                return Err("chat_speech_source_not_completed");
            }
            let receipt: Value =
                serde_json::from_str(&receipt.ok_or("chat_speech_source_not_completed")?)
                    .map_err(|_| "storage_unavailable")?;
            receipt["reply"]
                .as_str()
                .map(str::to_owned)
                .ok_or("chat_speech_source_not_completed")
        }
        _ => Err("chat_speech_invalid_input"),
    }
}
fn validate_source(source: &Value) -> Result<()> {
    let keys = match field(source, "kind")? {
        "chat" => &["kind", "backend", "scopeID", "hostSessionID", "requestID"][..],
        "world" => &[
            "kind",
            "worldID",
            "residentScope",
            "hostSessionID",
            "runID",
            "eventID",
        ][..],
        _ => return Err("chat_speech_invalid_input"),
    };
    let map = source.as_object().ok_or("chat_speech_invalid_input")?;
    if map.len() != keys.len() || !map.keys().all(|k| keys.contains(&k.as_str())) {
        return Err("chat_speech_invalid_input");
    }
    for key in keys {
        field(source, key)?;
    }
    Ok(())
}
pub fn request(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    if !matches!(method, "chat_speech_event" | "chat_speech_read") {
        return Err("unknown_method");
    }
    let scope = field(p, "scopeID")?;
    let host = field(p, "hostSessionID")?;
    let settings = crate::product_settings::request(c, "product_settings_read", &json!({}))?;
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let old: Option<(String, String, String, Option<String>, Option<String>)> = tx
        .query_row(
            "SELECT host,request,state,source,utterance FROM chat_speech_lanes WHERE scope=?1",
            [scope],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if method == "chat_speech_read" {
        return Ok(
            json!({"requestID":old.as_ref().filter(|v| v.0==host).map(|v|&v.1),"state":old.as_ref().filter(|v| v.0==host).map(|v|&v.2)}),
        );
    }
    let request = field(p, "requestID")?;
    let kind = field(p, "kind")?;
    let delivery_scope = json!({"scopeID":scope,"hostSessionID":host});
    let mut dispatch = Value::Null;
    let delivery;
    if kind == "accepted" {
        if tx
            .query_row(
                "SELECT 1 FROM chat_speech_requests WHERE scope=?1 AND host=?2 AND request=?3",
                params![scope, host, request],
                |r| r.get::<_, i64>(0),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?
            .is_some()
        {
            return Ok(json!({"duplicate":true,"dispatch":null}));
        }
        crate::speech_delivery::transition_in(&tx, "speech_delivery_claim", &delivery_scope)?;
        delivery =
            crate::speech_delivery::transition_in(&tx, "speech_delivery_cancel", &delivery_scope)?;
        tx.execute("INSERT INTO chat_speech_lanes VALUES(?1,?2,?3,'accepted',NULL,NULL) ON CONFLICT(scope) DO UPDATE SET host=excluded.host,request=excluded.request,state='accepted',source=NULL,utterance=NULL",params![scope,host,request]).map_err(|_| "storage_unavailable")?;
        tx.execute(
            "INSERT INTO chat_speech_requests VALUES(?1,?2,?3,NULL)",
            params![scope, host, request],
        )
        .map_err(|_| "storage_unavailable")?;
    } else {
        let (old_host, old_request, state, old_source, _) =
            old.ok_or("chat_speech_stale_request")?;
        if old_host != host || old_request != request {
            return Err("chat_speech_stale_request");
        }
        if kind == "reply" {
            validate_source(&p["source"])?;
            let source = crate::canonical_json::to_string(&p["source"])
                .map_err(|_| "chat_speech_invalid_input")?;
            if state == "selected" || state == "suppressed" {
                if old_source.as_deref() != Some(&source) {
                    return Err("chat_speech_source_conflict");
                }
                return Ok(json!({"duplicate":true,"dispatch":null}));
            }
            if state != "accepted" {
                return Err("chat_speech_stale_request");
            }
            if tx
                .query_row(
                    "SELECT 1 FROM chat_speech_requests WHERE scope=?1 AND source=?2",
                    params![scope, source],
                    |r| r.get::<_, i64>(0),
                )
                .optional()
                .map_err(|_| "storage_unavailable")?
                .is_some()
            {
                return Err("chat_speech_source_already_selected");
            }
            let reply = completed_reply(&tx, &p["source"])?;
            let enabled = settings["values"]["autoSpeak"] == true
                && p["testMuted"] != true
                && !reply.trim().is_empty();
            let utterance = format!(
                "chat-{}",
                crate::model::digest(
                    crate::canonical_json::to_vec(&json!([scope, host, request, &p["source"]]))
                        .map_err(|_| "chat_speech_invalid_input")?
                        .as_slice()
                )
            );
            if enabled {
                delivery = crate::speech_delivery::transition_in(
                    &tx,
                    "speech_delivery_enqueue",
                    &json!({"scopeID":scope,"hostSessionID":host,"utteranceID":utterance,"text":reply,"mode":"fifo"}),
                )?;
                dispatch = json!({"utteranceID":utterance,"text":reply,"delivery":delivery});
            } else {
                delivery = Value::Null;
            }
            tx.execute(
                "UPDATE chat_speech_lanes SET state=?2,source=?3,utterance=?4 WHERE scope=?1",
                params![
                    scope,
                    if enabled { "selected" } else { "suppressed" },
                    source,
                    utterance
                ],
            )
            .map_err(|_| "storage_unavailable")?;
            tx.execute("UPDATE chat_speech_requests SET source=?4 WHERE scope=?1 AND host=?2 AND request=?3",params![scope,host,request,source]).map_err(|_| "storage_unavailable")?;
        } else if matches!(kind, "cancelled" | "failure" | "closed") {
            delivery = crate::speech_delivery::transition_in(
                &tx,
                "speech_delivery_cancel",
                &delivery_scope,
            )?;
            tx.execute(
                "UPDATE chat_speech_lanes SET state='cancelled' WHERE scope=?1",
                [scope],
            )
            .map_err(|_| "storage_unavailable")?;
        } else {
            return Err("chat_speech_invalid_input");
        }
    }
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(json!({"duplicate":false,"dispatch":dispatch,"delivery":delivery}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        crate::speech_delivery::schema(&c).unwrap();
        crate::product_settings::schema(&c).unwrap();
        crate::agent_chat::schema(&c).unwrap();
        c.execute_batch("CREATE TABLE agent_loop_events(world TEXT,scope TEXT,event TEXT,state TEXT,run TEXT,session TEXT,receipt TEXT);").unwrap();
        c.execute("INSERT INTO chat_requests(backend,scope,request,host_session,digest,state,reply) VALUES('codex','actual-chat','model-request','model-host','digest','completed','actual reply')",[]).unwrap();
        c
    }
    fn event(kind: &str) -> Value {
        json!({"scopeID":"unity.reply","hostSessionID":"speech-host","requestID":"ui-request","kind":kind,"source":{"kind":"chat","backend":"codex","scopeID":"actual-chat","hostSessionID":"model-host","requestID":"model-request"}})
    }
    #[test]
    fn completed_source_issues_once_and_stale_cancel_cannot_stop_new_reply() {
        let mut c = db();
        request(&mut c, "chat_speech_event", &event("accepted")).unwrap();
        let mut reply = event("reply");
        reply["text"] = json!("untrusted UI text");
        let first = request(&mut c, "chat_speech_event", &reply).unwrap();
        assert_eq!(first["dispatch"]["text"], "actual reply");
        assert!(first["dispatch"]["delivery"]["ticket"].is_object());
        assert_eq!(
            request(&mut c, "chat_speech_event", &reply).unwrap()["dispatch"],
            Value::Null
        );
        // Reopen an actual private SQLite file, then run production speech recovery.
        let path =
            std::env::temp_dir().join(format!("gmgn-chat-speech-{}.sqlite", uuid::Uuid::new_v4()));
        c.execute("VACUUM INTO ?1", [path.to_str().unwrap()])
            .unwrap();
        drop(c);
        let mut c = Connection::open(&path).unwrap();
        crate::speech_delivery::recover(&mut c).unwrap();
        assert_eq!(
            request(&mut c, "chat_speech_event", &reply).unwrap()["dispatch"],
            Value::Null
        );
        let mut next = event("accepted");
        next["requestID"] = json!("new-request");
        request(&mut c, "chat_speech_event", &next).unwrap();
        assert_eq!(
            request(&mut c, "chat_speech_event", &event("accepted")).unwrap()["duplicate"],
            true
        );
        let mut replay = next.clone();
        replay["kind"] = json!("reply");
        assert_eq!(
            request(&mut c, "chat_speech_event", &replay).unwrap_err(),
            "chat_speech_source_already_selected"
        );
        assert_eq!(
            request(&mut c, "chat_speech_event", &event("cancelled")).unwrap_err(),
            "chat_speech_stale_request"
        );
        assert_eq!(
            request(&mut c, "chat_speech_read", &next).unwrap()["state"],
            "accepted"
        );
        drop(c);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn identity_unknown_cancel_and_settings_suppression_are_authoritative() {
        let mut c = db();
        request(&mut c, "chat_speech_event", &event("accepted")).unwrap();
        let mut wrong = event("reply");
        wrong["source"]["hostSessionID"] = json!("other");
        assert_eq!(
            request(&mut c, "chat_speech_event", &wrong).unwrap_err(),
            "chat_speech_source_not_completed"
        );
        c.execute("UPDATE chat_requests SET state='unknown'", [])
            .unwrap();
        assert_eq!(
            request(&mut c, "chat_speech_event", &event("reply")).unwrap_err(),
            "chat_speech_source_not_completed"
        );
        c.execute("UPDATE chat_requests SET state='completed'", [])
            .unwrap();
        crate::product_settings::request(
            &mut c,
            "product_settings_apply",
            &json!({"requestID":"mute","expectedRevision":0,"changes":{"autoSpeak":false}}),
        )
        .unwrap();
        assert!(
            request(&mut c, "chat_speech_event", &event("reply")).unwrap()["dispatch"].is_null()
        );
        assert_eq!(
            c.query_row("SELECT state FROM chat_speech_lanes", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "suppressed"
        );
        assert_eq!(
            c.query_row("SELECT COUNT(*) FROM speech_delivery_lanes", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    #[test]
    fn new_native_host_after_recovery_cannot_replay_completed_source() {
        let mut c = db();
        request(&mut c, "chat_speech_event", &event("accepted")).unwrap();
        request(&mut c, "chat_speech_event", &event("reply")).unwrap();
        let mut next = event("accepted");
        next["hostSessionID"] = json!("restarted-host");
        next["requestID"] = json!("new-ui");
        assert_eq!(
            request(&mut c, "chat_speech_event", &next).unwrap_err(),
            "speech_delivery_stale_session"
        );
        crate::speech_delivery::recover(&mut c).unwrap();
        request(&mut c, "chat_speech_event", &next).unwrap();
        next["kind"] = json!("reply");
        assert_eq!(
            request(&mut c, "chat_speech_event", &next).unwrap_err(),
            "chat_speech_source_already_selected"
        );
        let states: Value = serde_json::from_str(
            &c.query_row("SELECT payload FROM speech_delivery_lanes", [], |r| {
                r.get::<_, String>(0)
            })
            .unwrap(),
        )
        .unwrap();
        assert_eq!(states["states"], json!([]));
        assert_eq!(states["hostSessionID"], "restarted-host");
    }
    #[test]
    fn world_requires_full_completed_identity_and_original_reply() {
        let mut c = db();
        c.execute("INSERT INTO agent_loop_events VALUES('world','resident','event','completed','run','host',?1)",[json!({"reply":"world reply"}).to_string()]).unwrap();
        request(&mut c, "chat_speech_event", &event("accepted")).unwrap();
        let mut p = event("reply");
        p["source"] = json!({"kind":"world","worldID":"world","residentScope":"resident","eventID":"event","runID":"run","hostSessionID":"host"});
        for field in [
            "worldID",
            "residentScope",
            "eventID",
            "runID",
            "hostSessionID",
        ] {
            let mut wrong = p.clone();
            wrong["source"][field] = json!("other");
            assert!(request(&mut c, "chat_speech_event", &wrong).is_err());
        }
        assert_eq!(
            request(&mut c, "chat_speech_event", &p).unwrap()["dispatch"]["text"],
            "world reply"
        );
    }
    #[test]
    fn cancellation_requires_native_stop_receipt_and_test_mute_never_changes_preference() {
        let mut c = db();
        request(&mut c, "chat_speech_event", &event("accepted")).unwrap();
        let selected = request(&mut c, "chat_speech_event", &event("reply")).unwrap();
        let identity = selected["dispatch"]["delivery"]["ticket"]["identity"].clone();
        crate::speech_delivery::transition_in(
            &c,
            "bind",
            &json!({"identity":identity,"text":"actual reply"}),
        )
        .unwrap();
        let cancelled = request(&mut c, "chat_speech_event", &event("cancelled")).unwrap();
        let stop = &cancelled["delivery"]["stopCommands"][0];
        assert!(stop.is_object());
        assert_eq!(cancelled["delivery"]["states"][0]["status"], "stopping");
        assert_eq!(
            request(&mut c, "chat_speech_event", &event("reply")).unwrap_err(),
            "chat_speech_stale_request"
        );
        let stopped = crate::speech_delivery::transition_in(&c,"speech_delivery_receipt",&json!({"identity":stop["identity"],"kind":"stopped","stopRequestID":stop["stopRequestID"]})).unwrap();
        assert_eq!(stopped["states"][0]["status"], "stopped");
        let mut next = event("accepted");
        next["requestID"] = json!("muted-request");
        request(&mut c, "chat_speech_event", &next).unwrap();
        next["kind"] = json!("reply");
        next["testMuted"] = json!(true);
        c.execute("INSERT INTO chat_requests(backend,scope,request,host_session,digest,state,reply) VALUES('codex','actual-chat','muted-model','model-host','digest','completed','actual reply')",[]).unwrap();
        next["source"]["requestID"] = json!("muted-model");
        assert!(request(&mut c, "chat_speech_event", &next).unwrap()["dispatch"].is_null());
        assert_eq!(
            crate::product_settings::request(&mut c, "product_settings_read", &json!({})).unwrap()
                ["values"]["autoSpeak"],
            true
        );
    }
}
