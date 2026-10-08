//! Durable tool dispatch ledger. Registration and reconciliation are host-only APIs.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

pub fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS agent_tool_authority(world TEXT,scope TEXT,run TEXT,session TEXT,tools TEXT NOT NULL,PRIMARY KEY(world,scope,run));
    CREATE TABLE IF NOT EXISTS agent_tool_calls(world TEXT,scope TEXT,run TEXT,session TEXT,call TEXT,operation TEXT,tool TEXT,input TEXT,effect TEXT,state TEXT,receipt TEXT,PRIMARY KEY(world,scope,run,call));
    CREATE INDEX IF NOT EXISTS agent_tool_operation ON agent_tool_calls(world,scope,operation);
    CREATE TABLE IF NOT EXISTS agent_tool_operation_authority(world TEXT,scope TEXT,run TEXT,session TEXT,operation TEXT,tool TEXT,input TEXT,PRIMARY KEY(world,scope,run,operation));") .map_err(|_| "storage_unavailable")
}
pub fn recover(db: &Connection) -> Result<()> {
    db.execute(
        "UPDATE agent_tool_calls SET state='unknown' WHERE state='inflight'",
        [],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(())
}
/// Internal transport cancellation/disconnect marker; never implies absence of effect.
pub fn mark_unknown(db: &Connection, p: &Value) -> Result<()> {
    db.execute("UPDATE agent_tool_calls SET state='unknown' WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND call=?5 AND state='inflight'",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"runID")?,text(p,"hostSessionID")?,text(p,"callID")?]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn text<'a>(p: &'a Value, key: &str) -> Result<&'a str> {
    p[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("agent_tool_invalid_request")
}
fn safe(v: &Value) -> bool {
    match v {
        Value::Object(m) => m.iter().all(|(k, v)| {
            let k = k.to_ascii_lowercase().replace(['_', '-'], "");
            ![
                "apikey",
                "authorization",
                "token",
                "privatetoken",
                "password",
                "secret",
                "accesskey",
                "credential",
            ]
            .iter()
            .any(|s| k.contains(s))
                && safe(v)
        }),
        Value::Array(a) => a.iter().all(safe),
        _ => true,
    }
}
fn bounded(v: &Value) -> Result<String> {
    let encoded = crate::canonical_json::to_string(v).map_err(|_| "agent_tool_invalid_payload")?;
    if encoded.len() > 16384 || !safe(v) {
        return Err("agent_tool_invalid_payload");
    }
    Ok(encoded)
}
fn claimed(db: &Connection, p: &Value) -> Result<()> {
    let state:Option<String>=db.query_row("SELECT state FROM agent_loop_events WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"runID")?,text(p,"hostSessionID")?],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
    if state.as_deref() != Some("claimed") {
        return Err("agent_tool_run_not_claimed");
    }
    Ok(())
}
/// Invoke only from a trusted host/runtime configuration channel, never model tools.
pub fn register_authorization(db: &mut Connection, p: &Value) -> Result<Value> {
    let tools = p["tools"]
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 128)
        .ok_or("agent_tool_invalid_authority")?;
    let mut names = std::collections::HashSet::new();
    for t in tools {
        if !names.insert(text(t, "name")?)
            || !matches!(text(t, "effect")?, "read" | "write")
            || t["inputSchema"]["type"] != "object"
            || !supported_schema(&t["inputSchema"], 0)
        {
            return Err("agent_tool_invalid_authority");
        }
    }
    let encoded = bounded(&p["tools"])?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    claimed(&tx, p)?;
    let old: Option<(String, String)> = tx
        .query_row(
            "SELECT session,tools FROM agent_tool_authority WHERE world=?1 AND scope=?2 AND run=?3",
            params![
                text(p, "worldID")?,
                text(p, "residentScope")?,
                text(p, "runID")?
            ],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((session, old)) = old {
        if session != text(p, "hostSessionID")? || old != encoded {
            return Err("agent_tool_authority_conflict");
        }
    } else {
        tx.execute(
            "INSERT INTO agent_tool_authority VALUES(?1,?2,?3,?4,?5)",
            params![
                text(p, "worldID")?,
                text(p, "residentScope")?,
                text(p, "runID")?,
                text(p, "hostSessionID")?,
                encoded
            ],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(json!({"registered":true}))
}
/// Trusted business gateway derives operationID from stable business/task identity.
/// Never expose this to the model: accepting arbitrary model IDs defeats deduplication.
pub fn authorize_operation(db: &mut Connection, p: &Value) -> Result<Value> {
    let input = bounded(&p["arguments"])?;
    let world = text(p, "worldID")?;
    let scope = text(p, "residentScope")?;
    let run = text(p, "runID")?;
    let session = text(p, "hostSessionID")?;
    let op = text(p, "operationID")?;
    let tool = text(p, "toolName")?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    claimed(&tx, p)?;
    let old:Option<(String,String,String)>=tx.query_row("SELECT session,tool,input FROM agent_tool_operation_authority WHERE world=?1 AND scope=?2 AND run=?3 AND operation=?4",params![world,scope,run,op],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional().map_err(|_|"storage_unavailable")?;
    if let Some((s, t, i)) = old {
        if s != session || t != tool || i != input {
            return Err("agent_tool_operation_conflict");
        }
    } else {
        tx.execute(
            "INSERT INTO agent_tool_operation_authority VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![world, scope, run, session, op, tool, input],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(json!({"authorized":true}))
}
fn supported_schema(s: &Value, depth: usize) -> bool {
    let Some(m) = s.as_object() else {
        return false;
    };
    if depth > 16
        || !matches!(
            s["type"].as_str(),
            Some("object" | "array" | "string" | "boolean" | "integer" | "number" | "null")
        )
    {
        return false;
    }
    if !m.keys().all(|k| {
        matches!(
            k.as_str(),
            "type"
                | "description"
                | "title"
                | "properties"
                | "required"
                | "additionalProperties"
                | "enum"
                | "items"
                | "minimum"
                | "maximum"
                | "minLength"
                | "maxLength"
                | "minItems"
                | "maxItems"
        )
    }) {
        return false;
    }
    if s.get("additionalProperties")
        .is_some_and(|v| v != &Value::Bool(false))
    {
        return false;
    }
    if let Some(p) = s.get("properties") {
        let Some(p) = p.as_object() else {
            return false;
        };
        if !p.values().all(|s| supported_schema(s, depth + 1)) {
            return false;
        }
    }
    if let Some(i) = s.get("items") {
        if !supported_schema(i, depth + 1) {
            return false;
        }
    }
    for key in ["minimum", "maximum"] {
        if s.get(key).is_some_and(|v| v.as_f64().is_none()) {
            return false;
        }
    }
    for key in ["minLength", "maxLength", "minItems", "maxItems"] {
        if s.get(key).is_some_and(|v| v.as_u64().is_none()) {
            return false;
        }
    }
    if s.get("enum")
        .is_some_and(|v| v.as_array().is_none_or(|a| a.is_empty()))
    {
        return false;
    }
    if s.get("required").is_some_and(|v| {
        v.as_array()
            .is_none_or(|a| a.iter().any(|v| v.as_str().is_none()))
    }) {
        return false;
    }
    true
}
fn matches_schema(v: &Value, s: &Value, depth: usize) -> bool {
    if depth > 16 {
        return false;
    }
    if let Some(en) = s["enum"].as_array() {
        if !en.contains(v) {
            return false;
        }
    }
    if let Some(n) = v.as_f64() {
        if s["minimum"].as_f64().is_some_and(|min| n < min)
            || s["maximum"].as_f64().is_some_and(|max| n > max)
        {
            return false;
        }
    }
    if let Some(v) = v.as_str() {
        let n = v.chars().count() as u64;
        if s["minLength"].as_u64().is_some_and(|min| n < min)
            || s["maxLength"].as_u64().is_some_and(|max| n > max)
        {
            return false;
        }
    }
    if let Some(v) = v.as_array() {
        let n = v.len() as u64;
        if s["minItems"].as_u64().is_some_and(|min| n < min)
            || s["maxItems"].as_u64().is_some_and(|max| n > max)
        {
            return false;
        }
    }
    match s["type"].as_str() {
        Some("object") => v.as_object().is_some_and(|m| {
            let props = s["properties"].as_object();
            s["required"].as_array().is_none_or(|a| {
                a.iter()
                    .all(|k| k.as_str().is_some_and(|k| m.contains_key(k)))
            }) && m.iter().all(|(k, v)| {
                props
                    .and_then(|p| p.get(k))
                    .is_some_and(|s| matches_schema(v, s, depth + 1))
            })
        }),
        Some("array") => v.as_array().is_some_and(|a| {
            a.len() <= 128 && a.iter().all(|v| matches_schema(v, &s["items"], depth + 1))
        }),
        Some("string") => v.is_string(),
        Some("boolean") => v.is_boolean(),
        Some("integer") => v.as_i64().is_some() || v.as_u64().is_some(),
        Some("number") => v.is_number(),
        Some("null") => v.is_null(),
        _ => false,
    }
}
pub fn request(db: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let world = text(p, "worldID")?;
    let scope = text(p, "residentScope")?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    let result = match method {
        "agent_tool_begin" => {
            claimed(&tx, p)?;
            let run = text(p, "runID")?;
            let session = text(p, "hostSessionID")?;
            let call = text(p, "callID")?;
            let op = text(p, "operationID")?;
            let name = text(p, "toolName")?;
            let input = bounded(&p["arguments"])?;
            let auth:Option<String>=tx.query_row("SELECT tools FROM agent_tool_authority WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4",params![world,scope,run,session],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
            let tools: Value = serde_json::from_str(&auth.ok_or("agent_tool_not_authorized")?)
                .map_err(|_| "storage_unavailable")?;
            let tool = tools
                .as_array()
                .and_then(|a| a.iter().find(|t| t["name"] == name))
                .ok_or("agent_tool_not_authorized")?;
            if !matches_schema(&p["arguments"], &tool["inputSchema"], 0) {
                return Err("agent_tool_invalid_arguments");
            }
            let effect = text(tool, "effect")?;
            if effect == "write" {
                let authorized:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_tool_operation_authority WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND operation=?5 AND tool=?6 AND input=?7)",params![world,scope,run,session,op,name,input],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                if !authorized {
                    return Err("agent_tool_operation_not_authorized");
                }
            }
            let old:Option<(String,String,String,String,String,Option<String>)>=tx.query_row("SELECT session,operation,tool,input,state,receipt FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND call=?4",params![world,scope,run,call],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional().map_err(|_|"storage_unavailable")?;
            if let Some((s, o, t, i, state, receipt)) = old {
                if s != session || o != op || t != name || i != input {
                    return Err("agent_tool_call_conflict");
                }
                json!({"dispatch":false,"state":state,"receipt":receipt.and_then(|r|serde_json::from_str::<Value>(&r).ok())})
            } else {
                let count:i64=tx.query_row("SELECT COUNT(*) FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3",params![world,scope,run],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                if count >= 128 {
                    return Err("agent_tool_budget_exhausted");
                }
                let blocked:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND operation=?3 AND state!='not_applied' AND (effect='write' OR ?4='write' OR state='unknown'))",params![world,scope,op,effect],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                if blocked {
                    return Err("agent_tool_operation_blocked");
                }
                tx.execute("INSERT INTO agent_tool_calls VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,'inflight',NULL)",params![world,scope,run,session,call,op,name,input,effect]).map_err(|_|"storage_unavailable")?;
                json!({"dispatch":true,"state":"inflight"})
            }
        }
        "agent_tool_finish" => {
            let receipt = bounded(&p["receipt"])?;
            let run = text(p, "runID")?;
            let session = text(p, "hostSessionID")?;
            let call = text(p, "callID")?;
            let old:Option<(String,Option<String>)>=tx.query_row("SELECT state,receipt FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND call=?5",params![world,scope,run,session,call],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
            let (state, old) = old.ok_or("agent_tool_call_not_found")?;
            if state == "finished" {
                if old.as_deref() != Some(&receipt) {
                    return Err("agent_tool_receipt_conflict");
                }
            } else if state == "inflight" {
                tx.execute("UPDATE agent_tool_calls SET state='finished',receipt=?6 WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND call=?5",params![world,scope,run,session,call,receipt]).map_err(|_|"storage_unavailable")?;
            } else {
                return Err("agent_tool_requires_reconciliation");
            }
            json!({"finished":true})
        }
        "agent_tool_inspect" => {
            let op = text(p, "operationID")?;
            let mut q=tx.prepare("SELECT run,session,call,state,receipt FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND operation=?3 ORDER BY rowid").map_err(|_|"storage_unavailable")?;
            let rows = q
                .query_map(params![world, scope, op], |r| {
                    Ok((
                        r.get::<_, String>(0)?,
                        r.get::<_, String>(1)?,
                        r.get::<_, String>(2)?,
                        r.get::<_, String>(3)?,
                        r.get::<_, Option<String>>(4)?,
                    ))
                })
                .map_err(|_| "storage_unavailable")?;
            let mut entries = Vec::new();
            for row in rows {
                let (run, session, call, state, receipt) =
                    row.map_err(|_| "storage_unavailable")?;
                entries.push(json!({"runID":run,"hostSessionID":session,"callID":call,"state":state,"receipt":receipt.and_then(|r|serde_json::from_str::<Value>(&r).ok())}));
            }
            json!({"calls":entries})
        }
        _ => return Err("unknown_method"),
    };
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(result)
}
/// Trusted host must actually verify whether the side effect happened before calling.
pub fn reconcile(db: &mut Connection, p: &Value) -> Result<Value> {
    let world = text(p, "worldID")?;
    let scope = text(p, "residentScope")?;
    let run = text(p, "runID")?;
    let session = text(p, "hostSessionID")?;
    let call = text(p, "callID")?;
    let outcome = text(p, "outcome")?;
    if !matches!(outcome, "applied" | "not_applied") {
        return Err("agent_tool_invalid_request");
    }
    let receipt = bounded(&p["verificationReceipt"])?;
    if !p["verificationReceipt"].is_object()
        || p["verificationReceipt"]
            .as_object()
            .is_some_and(|o| o.is_empty())
    {
        return Err("agent_tool_invalid_payload");
    }
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    let count=tx.execute("UPDATE agent_tool_calls SET state=?6,receipt=?7 WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND call=?5 AND state='unknown'",params![world,scope,run,session,call,if outcome=="applied" {"finished"} else {"not_applied"},receipt]).map_err(|_|"storage_unavailable")?;
    if count != 1 {
        return Err("agent_tool_not_unknown");
    }
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(json!({"reconciled":true,"outcome":outcome}))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> (Connection, Value) {
        let mut db = Connection::open_in_memory().unwrap();
        crate::agent_scheduler::schema(&db).unwrap();
        schema(&db).unwrap();
        db.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','e','{}','claimed','r','h')",[]).unwrap();
        let p = json!({"worldID":"w","residentScope":"s","runID":"r","hostSessionID":"h","callID":"c","operationID":"o","toolName":"move","arguments":{"target":"chair"}});
        let mut a = p.clone();
        a["tools"] = json!([{"name":"move","effect":"write","inputSchema":{"type":"object","properties":{"target":{"type":"string"}},"required":["target"]}}]);
        register_authorization(&mut db, &a).unwrap();
        authorize_operation(&mut db, &p).unwrap();
        (db, p)
    }
    #[test]
    fn reordered_authority_arguments_and_receipt_are_idempotent() {
        let mut db = Connection::open_in_memory().unwrap();
        crate::agent_scheduler::schema(&db).unwrap();
        schema(&db).unwrap();
        db.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','e','{}','claimed','r','h')",[]).unwrap();
        let mut p = json!({"worldID":"w","residentScope":"s","runID":"r","hostSessionID":"h","callID":"c","operationID":"o","toolName":"move"});
        let tools:Value=serde_json::from_str(r#"[{"name":"move","effect":"write","inputSchema":{"type":"object","properties":{"target":{"type":"string"},"speed":{"type":"integer"}},"required":["target","speed"]}}]"#).unwrap();
        let reordered:Value=serde_json::from_str(r#"[{"inputSchema":{"required":["target","speed"],"properties":{"speed":{"type":"integer"},"target":{"type":"string"}},"type":"object"},"effect":"write","name":"move"}]"#).unwrap();
        p["tools"] = tools;
        register_authorization(&mut db, &p).unwrap();
        p["tools"] = reordered;
        register_authorization(&mut db, &p).unwrap();
        p["arguments"] = serde_json::from_str(r#"{"target":"chair","speed":2}"#).unwrap();
        authorize_operation(&mut db, &p).unwrap();
        p["arguments"] = serde_json::from_str(r#"{"speed":2,"target":"chair"}"#).unwrap();
        authorize_operation(&mut db, &p).unwrap();
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap()["dispatch"],
            true
        );
        p["arguments"] = serde_json::from_str(r#"{"target":"chair","speed":2}"#).unwrap();
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap()["dispatch"],
            false
        );
        p["receipt"] = serde_json::from_str(r#"{"ok":true,"position":{"x":1,"z":2}}"#).unwrap();
        request(&mut db, "agent_tool_finish", &p).unwrap();
        p["receipt"] = serde_json::from_str(r#"{"position":{"z":2,"x":1},"ok":true}"#).unwrap();
        request(&mut db, "agent_tool_finish", &p).unwrap();
        p["receipt"]["position"]["x"] = json!(9);
        assert_eq!(
            request(&mut db, "agent_tool_finish", &p).unwrap_err(),
            "agent_tool_receipt_conflict"
        );
    }
    #[test]
    fn model_cannot_choose_fresh_operation_identity() {
        let (mut db, mut p) = setup();
        p["operationID"] = json!("model-generated-other-id");
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_operation_not_authorized"
        );
        assert_eq!(
            request(&mut db, "agent_tool_register", &p).unwrap_err(),
            "unknown_method"
        );
        assert!(!matches_schema(
            &json!(12),
            &json!({"type":"integer","maximum":10}),
            0
        ));
        assert!(!supported_schema(
            &json!({"type":"string","pattern":".*"}),
            0
        ));
    }
    #[test]
    fn durable_dispatch_and_receipt_idempotency() {
        let (mut db, mut p) = setup();
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap()["dispatch"],
            true
        );
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap()["dispatch"],
            false
        );
        p["receipt"] = json!({"ok":true});
        request(&mut db, "agent_tool_finish", &p).unwrap();
        request(&mut db, "agent_tool_finish", &p).unwrap();
        p["receipt"] = json!({"ok":false});
        assert_eq!(
            request(&mut db, "agent_tool_finish", &p).unwrap_err(),
            "agent_tool_receipt_conflict"
        );
        p["callID"] = json!("c2");
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_operation_blocked"
        );
    }
    #[test]
    fn recovery_requires_actual_verification() {
        let (mut db, mut p) = setup();
        request(&mut db, "agent_tool_begin", &p).unwrap();
        recover(&db).unwrap();
        p["receipt"] = json!({"ok":true});
        assert_eq!(
            request(&mut db, "agent_tool_finish", &p).unwrap_err(),
            "agent_tool_requires_reconciliation"
        );
        p["callID"] = json!("c2");
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_operation_blocked"
        );
        p["callID"] = json!("c");
        p["outcome"] = json!("not_applied");
        p["verificationReceipt"] = json!({"observed":"unchanged"});
        reconcile(&mut db, &p).unwrap();
        p["callID"] = json!("c2");
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap()["dispatch"],
            true
        );
    }
    #[test]
    fn cancellation_session_scope_and_schema_fail_closed() {
        let (mut db, mut p) = setup();
        p["hostSessionID"] = json!("wrong");
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_run_not_claimed"
        );
        p["hostSessionID"] = json!("h");
        p["residentScope"] = json!("other");
        assert!(request(&mut db, "agent_tool_begin", &p).is_err());
        p["residentScope"] = json!("s");
        p["arguments"] = json!({"target":"chair","extra":1});
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_invalid_arguments"
        );
        p["arguments"] = json!({"target":"chair","api_key":"private"});
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_invalid_payload"
        );
        db.execute("UPDATE agent_loop_events SET state='cancel_requested'", [])
            .unwrap();
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_run_not_claimed"
        );
    }
}
