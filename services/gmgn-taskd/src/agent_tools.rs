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
        let name = text(t, "name")?;
        if !names.insert(name) || !matches!(text(t, "effect")?, "read" | "write") {
            return Err("agent_tool_invalid_authority");
        }
        if t["inputSchema"]["type"] != "object" || !supported_schema(&t["inputSchema"], 0) {
            let (path, detail) = schema_defect(&t["inputSchema"], 0, "$.inputSchema")
                .err()
                .unwrap_or_else(|| {
                    (
                        "$.inputSchema.type".to_owned(),
                        "inputSchema must be a supported object schema".to_owned(),
                    )
                });
            let violation = SchemaViolation::new(name, path, detail);
            eprintln!("gmgn-taskd: {}", violation.diagnostic());
            return Err(violation.code);
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
/// A tool schema the authority refuses, with the contract code, the offending
/// tool and the exact JSON path of the first unsupported node. The wire only
/// carries the code (`agent_tool_invalid_authority`); the structured locator is
/// logged so a business rejection is never collapsed into an anonymous
/// transport failure — the whole point of the 2026-10-08 `error 3` diagnosis.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SchemaViolation {
    pub code: &'static str,
    pub tool: String,
    pub path: String,
    pub detail: String,
}
impl SchemaViolation {
    fn new(tool: &str, path: String, detail: String) -> Self {
        Self {
            code: "agent_tool_invalid_authority",
            tool: tool.to_owned(),
            path,
            detail,
        }
    }
    /// Canonical one-line locator. Deliberately not the payload itself: a
    /// refused schema may still contain caller data, only the blame is logged.
    fn diagnostic(&self) -> String {
        json!({
            "event": "rejected",
            "code": self.code,
            "tool": self.tool,
            "path": self.path,
            "detail": self.detail,
        })
        .to_string()
    }
}
/// First unsupported node of a tool schema as `(json path, reason)`.
///
/// A `type` may be a single known type name **or** a standard JSON Schema union
/// array (`["object","null"]`, the shape `submit_wish_generation` really sends).
/// Every alternative must be a known, non-repeated type name: a bare `123`, an
/// unknown name, an empty array or a duplicate is still refused, so this is not
/// "accept anything".
fn schema_defect(s: &Value, depth: usize, path: &str) -> std::result::Result<(), (String, String)> {
    let Some(m) = s.as_object() else {
        return Err((path.to_owned(), "schema node is not an object".to_owned()));
    };
    let valid_type = |v: &Value| matches!(v.as_str(), Some("object" | "array" | "string" | "boolean" | "integer" | "number" | "null"));
    let valid_types = valid_type(&s["type"]) || s["type"].as_array().is_some_and(|types| {
        !types.is_empty() && types.len() <= 7 && types.iter().all(valid_type)
            && types.iter().enumerate().all(|(index, ty)| !types[..index].contains(ty))
    });
    if depth > 16 || !valid_types {
        return Err((
            format!("{path}.type"),
            format!(
                "type must be one known JSON Schema type or a duplicate-free non-empty union of at most 7 of them, found {}",
                s["type"]
            ),
        ));
    }
    if let Some(key) = m.keys().find(|k| {
        !matches!(
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
        return Err((
            format!("{path}.{key}"),
            format!("unsupported schema keyword {key}"),
        ));
    }
    if s.get("additionalProperties")
        .is_some_and(|v| v != &Value::Bool(false))
    {
        return Err((
            format!("{path}.additionalProperties"),
            "additionalProperties must be false when present".to_owned(),
        ));
    }
    if let Some(p) = s.get("properties") {
        let Some(p) = p.as_object() else {
            return Err((
                format!("{path}.properties"),
                "properties must be an object".to_owned(),
            ));
        };
        for (key, subschema) in p {
            schema_defect(subschema, depth + 1, &format!("{path}.properties.{key}"))?;
        }
    }
    if let Some(i) = s.get("items") {
        schema_defect(i, depth + 1, &format!("{path}.items"))?;
    }
    for key in ["minimum", "maximum"] {
        if s.get(key).is_some_and(|v| v.as_f64().is_none()) {
            return Err((
                format!("{path}.{key}"),
                "bound must be a JSON number".to_owned(),
            ));
        }
    }
    for key in ["minLength", "maxLength", "minItems", "maxItems"] {
        if s.get(key).is_some_and(|v| v.as_u64().is_none()) {
            return Err((
                format!("{path}.{key}"),
                "bound must be a non-negative integer".to_owned(),
            ));
        }
    }
    if s.get("enum")
        .is_some_and(|v| v.as_array().is_none_or(|a| a.is_empty()))
    {
        return Err((
            format!("{path}.enum"),
            "enum must be a non-empty array".to_owned(),
        ));
    }
    if s.get("required").is_some_and(|v| {
        v.as_array()
            .is_none_or(|a| a.iter().any(|v| v.as_str().is_none()))
    }) {
        return Err((
            format!("{path}.required"),
            "required must be an array of strings".to_owned(),
        ));
    }
    Ok(())
}
fn supported_schema(s: &Value, depth: usize) -> bool {
    schema_defect(s, depth, "$.inputSchema").is_ok()
}
/// First argument path that fails the registered tool schema, as
/// `(json path, reason)`. This is the only value judge: `matches_schema` is a
/// thin boolean view of it, so registration-time and call-time validation can
/// never drift apart.
fn match_defect(
    v: &Value,
    s: &Value,
    depth: usize,
    path: &str,
) -> std::result::Result<(), (String, String)> {
    if depth > 16 {
        return Err((path.to_owned(), "argument nesting is too deep".to_owned()));
    }
    if let Some(types) = s["type"].as_array() {
        // Keep every constraint on each alternative; only the selected type changes.
        if types.is_empty() || types.len() > 7 {
            return Err((
                path.to_owned(),
                "declared union has an unsupported number of alternatives".to_owned(),
            ));
        }
        for ty in types {
            let mut alternative = s.clone();
            alternative["type"] = ty.clone();
            if match_defect(v, &alternative, depth, path).is_ok() {
                return Ok(());
            }
        }
        return Err((
            path.to_owned(),
            format!("value does not satisfy any alternative of union {}", s["type"]),
        ));
    }
    if let Some(en) = s["enum"].as_array() {
        if !en.contains(v) {
            return Err((
                path.to_owned(),
                format!("value is not one of the {} declared enum values", en.len()),
            ));
        }
    }
    if let Some(n) = v.as_f64() {
        if s["minimum"].as_f64().is_some_and(|min| n < min) {
            return Err((
                path.to_owned(),
                format!("value {n} is below minimum {}", s["minimum"]),
            ));
        }
        if s["maximum"].as_f64().is_some_and(|max| n > max) {
            return Err((
                path.to_owned(),
                format!("value {n} is above maximum {}", s["maximum"]),
            ));
        }
    }
    if let Some(v) = v.as_str() {
        let n = v.chars().count() as u64;
        if s["minLength"].as_u64().is_some_and(|min| n < min) {
            return Err((
                path.to_owned(),
                format!("string length {n} is below minLength {}", s["minLength"]),
            ));
        }
        if s["maxLength"].as_u64().is_some_and(|max| n > max) {
            return Err((
                path.to_owned(),
                format!("string length {n} is above maxLength {}", s["maxLength"]),
            ));
        }
    }
    if let Some(v) = v.as_array() {
        let n = v.len() as u64;
        if s["minItems"].as_u64().is_some_and(|min| n < min) {
            return Err((
                path.to_owned(),
                format!("array has {n} items, below minItems {}", s["minItems"]),
            ));
        }
        if s["maxItems"].as_u64().is_some_and(|max| n > max) {
            return Err((
                path.to_owned(),
                format!("array has {n} items, above maxItems {}", s["maxItems"]),
            ));
        }
    }
    match s["type"].as_str() {
        Some("object") => {
            let Some(m) = v.as_object() else {
                return Err((path.to_owned(), "value is not an object".to_owned()));
            };
            if let Some(required) = s["required"].as_array() {
                for key in required.iter().filter_map(|k| k.as_str()) {
                    if !m.contains_key(key) {
                        return Err((
                            format!("{path}.{key}"),
                            "required property is missing".to_owned(),
                        ));
                    }
                }
            }
            let props = s["properties"].as_object();
            for (key, value) in m {
                match props.and_then(|p| p.get(key)) {
                    Some(subschema) => {
                        match_defect(value, subschema, depth + 1, &format!("{path}.{key}"))?
                    }
                    None => {
                        return Err((
                            format!("{path}.{key}"),
                            "property is not declared by the tool schema".to_owned(),
                        ))
                    }
                }
            }
        }
        Some("array") => {
            let Some(a) = v.as_array() else {
                return Err((path.to_owned(), "value is not an array".to_owned()));
            };
            if a.len() > 128 {
                return Err((
                    path.to_owned(),
                    "array exceeds the 128 item limit".to_owned(),
                ));
            }
            for (index, item) in a.iter().enumerate() {
                match_defect(item, &s["items"], depth + 1, &format!("{path}[{index}]"))?;
            }
        }
        Some("string") if !v.is_string() => {
            return Err((path.to_owned(), "value is not a string".to_owned()))
        }
        Some("boolean") if !v.is_boolean() => {
            return Err((path.to_owned(), "value is not a boolean".to_owned()))
        }
        Some("integer") if v.as_i64().is_none() && v.as_u64().is_none() => {
            return Err((path.to_owned(), "value is not an integer".to_owned()))
        }
        Some("number") if !v.is_number() => {
            return Err((path.to_owned(), "value is not a number".to_owned()))
        }
        Some("null") if !v.is_null() => {
            return Err((path.to_owned(), "value is not null".to_owned()))
        }
        Some(_) => {}
        None => return Err((path.to_owned(), "schema node has no type".to_owned())),
    }
    Ok(())
}
/// Boolean view kept for the call-time contract tests; production dispatch uses
/// `match_defect` directly so it can report the failing argument path.
#[cfg(test)]
fn matches_schema(v: &Value, s: &Value, depth: usize) -> bool {
    match_defect(v, s, depth, "$").is_ok()
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
            if let Err((path, detail)) =
                match_defect(&p["arguments"], &tool["inputSchema"], 0, "$")
            {
                // Keep the locator: a refused call must name the tool and the
                // exact argument path, not just the generic code.
                eprintln!(
                    "gmgn-taskd: {}",
                    json!({
                        "event": "rejected",
                        "code": "agent_tool_invalid_arguments",
                        "tool": name,
                        "path": path,
                        "detail": detail,
                    })
                );
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

    /// The real 52 tools the Unity host sends to taskd, reconstructed from the
    /// shipping Swift sources on 2026-10-08 (see the group comments below).
    ///
    /// Provenance (each group is the actual schema producer, descriptions elided —
    /// they never reach `schema_defect`; every structural key is verbatim):
    ///   · 10 world tools — `Agent/WorldAgentToolContract.swift` `providerTools(for:)`
    ///     ∩ `ResidentWorldToolSession.allowedToolNames`.
    ///   · 17 music tools — `Agent/DJAgentToolDispatcher.swift`
    ///     `DJAgentCapabilityManifest.providerTools(for:)` for
    ///     `ResidentMusicToolBridge.playbackNames ∪ planningNames ∪ spatialNames`.
    ///   · 7 wish-machine tools — `Agent/ResidentWishMachineTools.swift` (the only
    ///     union-bearing tool: `submit_wish_generation`).
    ///   · 2 wish-reference tools — `Agent/ResidentWishReferenceTools.swift`.
    ///   · 12 prop tools — `Agent/ResidentPropToolBridge.swift`, filtered by
    ///     `UnityHost/UnityWorldSessionComposition.swift`.
    ///   · 3 screen tools — `Screen/ResidentScreenTools.swift`.
    ///   · 1 inbox tool — `UnityHost/UnityInboxAgentTools.swift`.
    ///
    /// Manifest-derived `enum` payloads (activity ids, weather, scene presets, lyrics
    /// modes) vary per world; the validator only cares that they are non-empty.
    const REAL_TOOL_CATALOG: &str = r#"[{"name":"inspect_world","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"list_places","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"list_available_activities","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"plan_route","effect":"read","inputSchema":{"type":"object","properties":{"place_id":{"type":"string","description":"list_places 或 inspect_world 返回的地点 ID"}},"required":["place_id"],"additionalProperties":false}},{"name":"move_to","effect":"write","inputSchema":{"type":"object","properties":{"place_id":{"type":"string","description":"list_places 或 inspect_world 返回的地点 ID"}},"required":["place_id"],"additionalProperties":false}},{"name":"start_activity","effect":"write","inputSchema":{"type":"object","properties":{"activity_id":{"type":"string","enum":["coffee.brew@prop"],"description":"世界清单或已绑定物件能力中的活动 ID"}},"required":["activity_id"],"additionalProperties":false}},{"name":"stop_activity","effect":"write","inputSchema":{"type":"object","properties":{"reason":{"type":"string","description":"停止活动的可选原因"}},"required":[],"additionalProperties":false}},{"name":"look_at","effect":"write","inputSchema":{"type":"object","properties":{"place_id":{"type":"string","description":"世界清单中的地点 ID"}},"required":["place_id"],"additionalProperties":false}},{"name":"list_available_motions","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"play_motion","effect":"write","inputSchema":{"type":"object","properties":{"motion_id":{"type":"string","description":"list_available_motions 返回的精确动作 ID"}},"required":["motion_id"],"additionalProperties":false}},{"name":"read_radio_state","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"read_current_track","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"search_music","effect":"read","inputSchema":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"],"additionalProperties":false}},{"name":"list_music_playlists","effect":"read","inputSchema":{"type":"object","properties":{"query":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":[],"additionalProperties":false}},{"name":"read_music_playlist","effect":"read","inputSchema":{"type":"object","properties":{"playlist_id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}},"required":["playlist_id"],"additionalProperties":false}},{"name":"prepare_music_track","effect":"write","inputSchema":{"type":"object","properties":{"playlist_id":{"type":"string"},"track_id":{"type":"string"}},"required":["playlist_id","track_id"],"additionalProperties":false}},{"name":"play_program_track","effect":"write","inputSchema":{"type":"object","properties":{"track_id":{"type":"string"},"slot_index":{"type":"integer"}},"required":[],"additionalProperties":false}},{"name":"next_track","effect":"write","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"previous_track","effect":"write","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"pause_music","effect":"write","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"resume_music","effect":"write","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"set_lyrics_mode","effect":"write","inputSchema":{"type":"object","properties":{"mode":{"type":"string","enum":["auto"],"description":"歌词视觉模式"}},"required":["mode"],"additionalProperties":false}},{"name":"replan_program","effect":"write","inputSchema":{"type":"object","properties":{"immediate_instruction":{"type":"string"}},"required":[],"additionalProperties":false}},{"name":"activate_prepared_program","effect":"write","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"insert_track","effect":"write","inputSchema":{"type":"object","properties":{"immediate_instruction":{"type":"string"}},"required":["immediate_instruction"],"additionalProperties":false}},{"name":"set_spatial_environment","effect":"write","inputSchema":{"type":"object","properties":{"scene":{"type":"string","enum":["cabin"]},"weather":{"type":"string","enum":["clear"]}},"required":[],"additionalProperties":false}},{"name":"move_spatial_camera","effect":"write","inputSchema":{"type":"object","properties":{"direction":{"type":"string","enum":["reset"]},"distance":{"type":"number"}},"required":["direction"],"additionalProperties":false}},{"name":"submit_wish_generation","effect":"write","inputSchema":{"type":"object","properties":{"attachment_id":{"type":"string","description":"本轮参考图编号：用户附件或用 register_wish_reference_image 登记的网页参考图；可用 read_wish_generation 空参数查询"},"name":{"type":"string","description":"物件名称"},"size_intent":{"type":["object","null"],"description":"尺寸意图，**两种形状二选一**：给完整三维时用 mode=dimensions + millimeters；只说得出一根轴时才用 axis + meters。许愿机的参数与尺寸规则只有一处定义：填任何参数之前先调用 read_wish_machine_contract（空参数）读取，不要凭记忆填。","properties":{"axis":{"type":"string","description":"哪根轴（**只给一根轴**时用）。合法取值与例子见 read_wish_machine_contract"},"meters":{"type":"number","description":"米数（**只给一根轴**时用）。允许范围见 read_wish_machine_contract"},"mode":{"type":"string","enum":["dimensions"],"description":"三轴形状的标签：用户说了完整长宽高就必须给 dimensions，并同时给 millimeters。与 axis/meters **只能给一种**。"},"millimeters":{"type":["object","null"],"description":"三轴尺寸（毫米）：x = 宽、y = 高（上下，本仓 up 固定在 ±Y）、z = 深。用户说「1443 x 862 x 302 mm」就**照实**填这三个整数（不要换算成米、不要只挑最长边、不要改顺序）。","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"}},"required":["x","y","z"],"additionalProperties":false},"source":{"type":"string","description":"这个数字是谁说的。合法取值见 read_wish_machine_contract"}},"required":[],"additionalProperties":false},"height_meters":{"type":"number","description":"legacy_height_field：旧字段，等价于 height 轴；与 size_intent 只能给一个。"},"pending_id":{"type":"string","description":"续上一次**未完成**的委托时原样回填"},"destination":{"type":["object","null"],"description":"仅当用户明确要求把成品摆到指定支撑面时提供；surface_ids 取自 list_placement_surfaces，position 为用户明确指定的绝对位置与朝向（可选）","properties":{"surface_ids":{"type":"array","items":{"type":"string"},"minItems":1,"maxItems":8},"position":{"type":["object","null"],"properties":{"surface_id":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"yaw":{"type":"number"}},"required":["surface_id","x","y","z","yaw"],"additionalProperties":false}},"required":["surface_ids"],"additionalProperties":false}},"required":["attachment_id","name"],"additionalProperties":false}},{"name":"read_wish_generation","effect":"read","inputSchema":{"type":"object","properties":{"wish_id":{"type":"string","description":"许愿任务编号"}},"required":[],"additionalProperties":false}},{"name":"read_wish_machine_contract","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"retry_wish_generation","effect":"write","inputSchema":{"type":"object","properties":{"wish_id":{"type":"string","description":"许愿任务编号"}},"required":["wish_id"],"additionalProperties":false}},{"name":"cancel_wish_generation","effect":"write","inputSchema":{"type":"object","properties":{"wish_id":{"type":"string","description":"许愿任务编号"}},"required":["wish_id"],"additionalProperties":false}},{"name":"claim_wish_output","effect":"write","inputSchema":{"type":"object","properties":{"wish_id":{"type":"string","description":"许愿任务编号"}},"required":["wish_id"],"additionalProperties":false}},{"name":"resume_wish_continuation","effect":"write","inputSchema":{"type":"object","properties":{"wish_id":{"type":"string","description":"许愿任务编号"},"confirm_resume":{"type":"boolean","enum":[true],"description":"仅本轮用户明确要求恢复此原许愿任务的自动领取及原目的地摆放时设为 true"}},"required":["confirm_resume","wish_id"],"additionalProperties":false}},{"name":"search_wish_reference_images","effect":"read","inputSchema":{"type":"object","properties":{"query":{"type":"string","description":"要搜索的英文物件名关键词，例如 red wooden chair"}},"required":["query"],"additionalProperties":false}},{"name":"register_wish_reference_image","effect":"write","inputSchema":{"type":"object","properties":{"image_url":{"type":"string","description":"搜索结果里的公开图片直链（https）"},"display_name":{"type":"string","description":"给这张参考图起的简短名字"}},"required":["image_url","display_name"],"additionalProperties":false}},{"name":"read_owned_props","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"list_placement_surfaces","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"preview_prop_placement","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"surface_id":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"yaw":{"type":"number"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id","surface_id","x","y","yaw","z"],"additionalProperties":false}},{"name":"apply_prop_placement","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"surface_id":{"type":"string"},"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},"yaw":{"type":"number"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id","surface_id","x","y","yaw","z"],"additionalProperties":false}},{"name":"withdraw_prop","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id"],"additionalProperties":false}},{"name":"undo_prop_placement","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id"],"additionalProperties":false}},{"name":"return_held_prop","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id"],"additionalProperties":false}},{"name":"drop_held_prop","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id"],"additionalProperties":false}},{"name":"hold_prop","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"slot":{"type":"string","enum":["rightHand","back","waist"],"description":"挂点（**可省**，不写就是 rightHand）"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id"],"additionalProperties":false}},{"name":"adjust_held_prop_grip","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"},"offset_x":{"type":"number"},"offset_y":{"type":"number"},"offset_z":{"type":"number"},"rotation_yaw":{"type":"number"}},"required":["layout_revision","object_id","offset_x","offset_y","offset_z","rotation_yaw"],"additionalProperties":false}},{"name":"enable_prop_capability","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"capability":{"type":"string","description":"受支持的使用能力模板，当前仅支持 coffee.brew"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["capability","layout_revision","object_id"],"additionalProperties":false}},{"name":"delete_prop","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"read_owned_props 返回的已拥有物件编号"},"reason":{"type":"string","description":"（可省）删除的理由，最多 200 字"},"layout_revision":{"type":"integer","description":"布局版本（**必填**）：把 read_owned_props 回执里的 layout_revision 原样填进来"}},"required":["layout_revision","object_id","reason"],"additionalProperties":false}},{"name":"play_screen","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"哪一台电视。空间里只有一台时可以省略。"},"url":{"type":"string"}},"required":["url"],"additionalProperties":false}},{"name":"stop_screen","effect":"write","inputSchema":{"type":"object","properties":{"object_id":{"type":"string","description":"哪一台电视。"}},"required":[],"additionalProperties":false}},{"name":"read_screen","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}},{"name":"read_system_inbox","effect":"read","inputSchema":{"type":"object","properties":{},"required":[],"additionalProperties":false}}]"#;

    fn fresh_db() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        crate::agent_scheduler::schema(&db).unwrap();
        schema(&db).unwrap();
        db.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state,run,session) VALUES('w','s','e','{}','claimed','r','h')",[]).unwrap();
        db
    }
    fn authority(tools: Value) -> Value {
        json!({"worldID":"w","residentScope":"s","runID":"r","hostSessionID":"h","tools":tools})
    }
    fn catalog() -> Value {
        serde_json::from_str(REAL_TOOL_CATALOG).unwrap()
    }
    fn authority_count(db: &Connection) -> i64 {
        db.query_row("SELECT COUNT(*) FROM agent_tool_authority", [], |r| r.get(0)).unwrap()
    }
    #[test]
    fn real_production_catalog_registers() {
        let tools = catalog();
        let entries = tools.as_array().unwrap();
        assert_eq!(entries.len(), 52, "生产 52 项工具");
        for tool in entries {
            assert!(
                supported_schema(&tool["inputSchema"], 0),
                "real tool schema refused: {}",
                tool["name"]
            );
        }
        let submit = entries
            .iter()
            .find(|t| t["name"] == "submit_wish_generation")
            .unwrap();
        for path in [
            &submit["inputSchema"]["properties"]["size_intent"]["type"],
            &submit["inputSchema"]["properties"]["size_intent"]["properties"]["millimeters"]["type"],
            &submit["inputSchema"]["properties"]["destination"]["type"],
            &submit["inputSchema"]["properties"]["destination"]["properties"]["position"]["type"],
        ] {
            assert_eq!(path, &json!(["object", "null"]));
        }
        let mut db = fresh_db();
        register_authorization(&mut db, &authority(tools)).unwrap();
        assert_eq!(authority_count(&db), 1);
        // The registered group is replayable with the identical catalog.
        register_authorization(&mut db, &authority(catalog())).unwrap();
    }
    #[test]
    fn malformed_type_is_refused_with_tool_and_field_path() {
        let mut tools = catalog();
        let submit = tools
            .as_array_mut()
            .unwrap()
            .iter_mut()
            .find(|t| t["name"] == "submit_wish_generation")
            .unwrap();
        submit["inputSchema"]["properties"]["destination"]["type"] = json!(["object", "bogus"]);
        let mut db = fresh_db();
        assert_eq!(
            register_authorization(&mut db, &authority(tools)).unwrap_err(),
            "agent_tool_invalid_authority"
        );
        assert_eq!(authority_count(&db), 0, "a refused tool group must not persist");
        let bad = json!({"type":"object","properties":{"destination":{"type":["object","bogus"]}}});
        let (path, detail) = schema_defect(&bad, 0, "$.inputSchema").unwrap_err();
        assert_eq!(path, "$.inputSchema.properties.destination.type");
        assert!(detail.contains("union"), "{detail}");
        let violation = SchemaViolation::new("submit_wish_generation", path, detail);
        assert_eq!(violation.code, "agent_tool_invalid_authority");
        assert_eq!(violation.tool, "submit_wish_generation");
        let diagnostic = violation.diagnostic();
        assert!(diagnostic.contains("\"tool\":\"submit_wish_generation\""), "{diagnostic}");
        assert!(diagnostic.contains("$.inputSchema.properties.destination.type"), "{diagnostic}");
        assert!(diagnostic.contains("agent_tool_invalid_authority"), "{diagnostic}");
    }
    #[test]
    fn union_types_are_accepted_and_malformed_types_still_fail_closed() {
        for ty in [
            json!(["object", "null"]),
            json!(["string", "null"]),
            json!(["integer", "null"]),
            json!(["array", "null"]),
            json!(["boolean", "null"]),
            json!(["number", "null"]),
            json!(["string"]),
        ] {
            assert!(
                schema_defect(&json!({"type": ty}), 0, "$").is_ok(),
                "legal union must be accepted: {ty}"
            );
        }
        for bad in [
            json!({"type": 123}),
            json!({"type": "bogus"}),
            json!({"type": ["object", "bogus"]}),
            json!({"type": []}),
            json!({"type": ["object", "object"]}),
            json!({"type": ["object", 123]}),
            json!({"type": ["object", ["null"]]}),
            json!({"type": ["object", "null", "string", "array", "boolean", "integer", "number", "object"]}),
            json!({"type": "object", "properties": {"x": {"type": ["object", "bogus"]}}}),
            json!({"type": "object", "properties": {"x": {"type": 7}}}),
            json!({"type": "object", "properties": {"x": {"type": "object", "pattern": ".*"}}}),
            json!({"type": "object", "additionalProperties": true}),
            json!({"type": "object", "required": [1]}),
            json!({"type": "object", "enum": []}),
            json!({"type": "object", "minLength": "x"}),
            json!({"type": "object", "minimum": "x"}),
            json!({}),
        ] {
            assert!(
                schema_defect(&bad, 0, "$").is_err(),
                "malformed schema must be refused: {bad}"
            );
        }
        // Registration fails closed on the same shapes.
        let mut db = fresh_db();
        let mut tools = catalog();
        tools[0]["inputSchema"]["type"] = json!(123);
        assert_eq!(
            register_authorization(&mut db, &authority(tools)).unwrap_err(),
            "agent_tool_invalid_authority"
        );
        assert_eq!(authority_count(&db), 0);
    }
    #[test]
    fn union_value_validation_checks_every_alternative_and_constraint() {
        let size_intent = json!({
            "type": ["object", "null"],
            "properties": {"axis": {"type": "string"}, "meters": {"type": "number"}},
            "required": [],
            "additionalProperties": false
        });
        assert!(matches_schema(&Value::Null, &size_intent, 0));
        assert!(matches_schema(&json!({"axis":"height","meters":1.2}), &size_intent, 0));
        assert!(!matches_schema(&json!(5), &size_intent, 0));
        assert!(!matches_schema(&json!({"axis":"height","extra":1}), &size_intent, 0), "union must keep additionalProperties");
        assert!(!matches_schema(&json!({"axis":1}), &size_intent, 0), "union must keep member types");
        let nullable_string = json!({"type": ["string", "null"]});
        assert!(matches_schema(&json!("x"), &nullable_string, 0));
        assert!(matches_schema(&Value::Null, &nullable_string, 0));
        assert!(!matches_schema(&json!(1), &nullable_string, 0));
        let (path, _) = match_defect(&json!(5), &size_intent, 0, "$").unwrap_err();
        assert_eq!(path, "$");
        // The real submit schema accepts both declared shapes and refuses others.
        let tools = catalog();
        let submit = &tools
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["name"] == "submit_wish_generation")
            .unwrap()["inputSchema"];
        assert!(matches_schema(&json!({"attachment_id":"a","name":"n","destination":null}), submit, 0));
        assert!(matches_schema(
            &json!({"attachment_id":"a","name":"n","size_intent":{"mode":"dimensions","millimeters":{"x":1,"y":2,"z":3}}}),
            submit,
            0
        ));
        assert!(!matches_schema(&json!({"attachment_id":"a","name":"n","size_intent":5}), submit, 0));
        assert!(matches_schema(
            &json!({"attachment_id":"a","name":"n","destination":{"surface_ids":["s"],"position":null}}),
            submit,
            0
        ), "position null is legal when surface_ids is present");
        assert!(!matches_schema(
            &json!({"attachment_id":"a","name":"n","destination":{"position":null}}),
            submit,
            0
        ), "surface_ids is required inside destination");
        assert!(!matches_schema(
            &json!({"attachment_id":"a","name":"n","destination":{"surface_ids":["s"],"position":{"surface_id":"s","x":1,"y":2,"z":3}}}),
            submit,
            0
        ), "position requires yaw as well");
    }
    #[test]
    fn refused_arguments_report_the_tool_field_path() {
        let (mut db, mut p) = setup();
        p["arguments"] = json!({"target": 5});
        assert_eq!(
            request(&mut db, "agent_tool_begin", &p).unwrap_err(),
            "agent_tool_invalid_arguments"
        );
        let schema = json!({"type":"object","properties":{"target":{"type":"string"}},"required":["target"]});
        let (path, detail) = match_defect(&json!({"target":5}), &schema, 0, "$").unwrap_err();
        assert_eq!(path, "$.target");
        assert!(detail.contains("string"), "{detail}");
        assert_eq!(match_defect(&json!({}), &schema, 0, "$").unwrap_err().0, "$.target");
    }

}
