//! Scoped resident plans/fact drafts. No world execution or model-written state blob.
use crate::{model::Result, resident};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::BTreeMap;
pub fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS resident_intent_authority(world TEXT NOT NULL,scope TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(world,scope)); CREATE TABLE IF NOT EXISTS resident_intent_drafts(sequence INTEGER PRIMARY KEY AUTOINCREMENT,world TEXT NOT NULL,scope TEXT NOT NULL,events TEXT NOT NULL,pending TEXT NOT NULL,request TEXT NOT NULL,value TEXT NOT NULL,UNIQUE(world,scope)); CREATE TABLE IF NOT EXISTS resident_intent_commands(world TEXT NOT NULL,scope TEXT NOT NULL,request TEXT NOT NULL,input TEXT NOT NULL,output TEXT NOT NULL,PRIMARY KEY(world,scope,request)); INSERT OR IGNORE INTO resident_intent_authority(world,scope,revision) SELECT world_id,resident_scope,revision FROM resident_states WHERE domain='resident' AND key='plan';").map_err(|_|"storage_unavailable")
}
fn scope(p: &Value) -> Result<resident::Scope> {
    let s: resident::Scope =
        serde_json::from_value(p["scope"].clone()).map_err(|_| "resident_intent_invalid_scope")?;
    if [&s.world_id, &s.resident_scope]
        .iter()
        .any(|s| s.is_empty() || s.len() > 200)
    {
        return Err("resident_intent_invalid_scope");
    }
    Ok(s)
}
fn canonical(v: &Value) -> Result<String> {
    crate::canonical_json::to_string(v).map_err(|_| "resident_intent_invalid_input")
}
fn text<'a>(p: &'a Value, key: &str) -> Result<&'a str> {
    p[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("resident_intent_invalid_input")
}
fn events(v: &Value, cap: usize) -> Result<Vec<Value>> {
    let raw = v.as_array().ok_or("resident_intent_invalid_events")?;
    if raw.len() > 200 {
        return Err("resident_intent_invalid_events");
    }
    let mut result = Vec::new();
    for event in raw.iter().rev().take(cap) {
        let o = event.as_object().ok_or("resident_intent_invalid_events")?;
        if o.len() != 3
            || !o
                .keys()
                .all(|k| ["id", "kind", "summary"].contains(&k.as_str()))
            || text(event, "id").is_err()
            || text(event, "kind").is_err()
            || event["summary"].as_str().is_none_or(|s| s.len() > 65536)
        {
            return Err("resident_intent_invalid_events");
        }
        if !result.iter().any(|v: &Value| v["id"] == event["id"]) {
            result.push(event.clone());
        }
    }
    result.reverse();
    Ok(result)
}
fn union(preferred: &[Value], retained: &[Value]) -> Vec<Value> {
    let mut result = preferred.to_vec();
    for event in retained {
        if let Some(i) = result.iter().position(|v| v["id"] == event["id"]) {
            result[i] = event.clone()
        } else {
            result.push(event.clone())
        }
    }
    if result.len() > 200 {
        result.drain(..result.len() - 200);
    }
    result
}
fn by_id(v: &[Value]) -> BTreeMap<String, Value> {
    v.iter()
        .map(|e| (e["id"].as_str().unwrap().into(), e.clone()))
        .collect()
}
fn refresh_draft(db: &Connection, s: &resident::Scope, plan: &Value) -> Result<()> {
    let current: Option<(String, String)> = db
        .query_row(
            "SELECT value,events FROM resident_intent_drafts WHERE world=?1 AND scope=?2",
            params![s.world_id, s.resident_scope],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((old, recent)) = current {
        let mut new = plan.clone();
        new["groundedEvents"] =
            serde_json::from_str(&recent).map_err(|_| "resident_intent_invalid_state")?;
        let new = canonical(&new)?;
        if new != old {
            db.execute(
                "UPDATE resident_intent_drafts SET value=?3,request=?4 WHERE world=?1 AND scope=?2",
                params![
                    s.world_id,
                    s.resident_scope,
                    new,
                    uuid::Uuid::new_v4().to_string()
                ],
            )
            .map_err(|_| "storage_unavailable")?;
        }
    }
    Ok(())
}
fn plan(db: &Connection, s: &resident::Scope) -> Result<Value> {
    Ok(resident::read_state(db, s, "resident", "plan")
        .map_err(|e| e.code)?
        .map(|r| r.value)
        .unwrap_or_else(|| json!({"intent":null,"intentPausedByUser":false,"groundedEvents":[]})))
}
fn revision(db: &Connection, s: &resident::Scope) -> Result<i64> {
    db.execute(
        "INSERT OR IGNORE INTO resident_intent_authority(world,scope)VALUES(?1,?2)",
        params![s.world_id, s.resident_scope],
    )
    .map_err(|_| "storage_unavailable")?;
    db.query_row(
        "SELECT revision FROM resident_intent_authority WHERE world=?1 AND scope=?2",
        params![s.world_id, s.resident_scope],
        |r| r.get(0),
    )
    .map_err(|_| "storage_unavailable")
}
fn commit(
    tx: &rusqlite::Transaction<'_>,
    s: &resident::Scope,
    value: Value,
    request: String,
    facts: Vec<resident::Item>,
) -> Result<Value> {
    let result = resident::commit(
        tx,
        &resident::CommitRequest {
            scope: s.clone(),
            domain: "resident".into(),
            key: "plan".into(),
            expected_revision: revision(tx, s)?,
            request_id: request,
            value,
            events: facts,
            messages: vec![],
        },
    )
    .map_err(|e| e.code)?;
    tx.execute(
        "UPDATE resident_intent_authority SET revision=?3 WHERE world=?1 AND scope=?2",
        params![s.world_id, s.resident_scope, result.revision],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(json!({"revision":result.revision,"replayed":result.replayed}))
}
fn resolved(p: &Value, key: &str, old: &Value) -> Result<Value> {
    match p.get(key) {
        None => Ok(old[key].clone()),
        Some(Value::String(s)) => {
            let t = s.trim();
            Ok(if t.is_empty() {
                Value::Null
            } else {
                json!(t.chars().take(500).collect::<String>())
            })
        }
        _ => Err("resident_intent_invalid_input"),
    }
}
pub fn request(db: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    if canonical(p)?.len() > 256 * 1024 {
        return Err("resident_intent_input_limit");
    }
    let s = scope(p)?;
    let allowed: &[&str] = match method {
        "resident_intent_restore" | "resident_intent_drain" => &["scope"],
        "resident_intent_enqueue" => &["scope", "groundedEvents"],
        "resident_intent_pause" => &["scope", "action", "requestID"],
        "resident_intent_update" => &[
            "scope",
            "runID",
            "hostSessionID",
            "requestID",
            "nowMillis",
            "resumePausedIntent",
            "update",
        ],
        _ => return Err("unsupported_method"),
    };
    if p.as_object()
        .is_none_or(|o| o.keys().any(|k| !allowed.contains(&k.as_str())))
    {
        return Err("resident_intent_invalid_input");
    }
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    let command = matches!(method, "resident_intent_update" | "resident_intent_pause");
    let command_input = if command {
        Some(canonical(&json!({"method":method,"params":p}))?)
    } else {
        None
    };
    if let Some(input) = &command_input {
        let recorded:Option<(String,String)>=tx.query_row("SELECT input,output FROM resident_intent_commands WHERE world=?1 AND scope=?2 AND request=?3",params![s.world_id,s.resident_scope,text(p,"requestID")?],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
        if let Some((old, output)) = recorded {
            if &old != input {
                return Err("request_id_conflict");
            }
            return serde_json::from_str(&output).map_err(|_| "resident_intent_invalid_state");
        }
    }
    let output = match method {
        "resident_intent_restore" => {
            let record = resident::read_state(&tx, &s, "resident", "plan").map_err(|e| e.code)?;
            revision(&tx, &s)?;
            tx.execute(
                "UPDATE resident_intent_authority SET revision=?3 WHERE world=?1 AND scope=?2",
                params![
                    s.world_id,
                    s.resident_scope,
                    record.as_ref().map(|r| r.revision).unwrap_or(0)
                ],
            )
            .map_err(|_| "storage_unavailable")?;
            if let Some(record) = &record {
                refresh_draft(&tx, &s, &record.value)?;
            }
            json!({"record":record})
        }
        "resident_intent_update" => {
            let run = text(p, "runID")?;
            let host = text(p, "hostSessionID")?;
            let claimed:Option<(String,String)>=tx.query_row("SELECT state,payload FROM agent_loop_events WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4",params![s.world_id,s.resident_scope,run,host],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
            let (state, payload) = claimed.ok_or("resident_intent_inactive_run")?;
            if state != "claimed" {
                return Err("resident_intent_inactive_run");
            }
            let payload: Value =
                serde_json::from_str(&payload).map_err(|_| "resident_intent_invalid_state")?;
            let human=payload["kind"]=="human"||tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND ((state='claimed' AND mode='human') OR (state='delivered' AND mode='steering')))",params![s.world_id,s.resident_scope,run,host],|r|r.get::<_,bool>(0)).map_err(|_|"storage_unavailable")?;
            let mut value = plan(&tx, &s)?;
            let resume = match p.get("resumePausedIntent") {
                None => false,
                Some(v) => v.as_bool().ok_or("resident_intent_invalid_input")?,
            };
            if resume && !human {
                return Err("resident_intent_missing_human_guidance");
            }
            if value["intentPausedByUser"] == true && !resume {
                return Err("resident_intent_paused");
            }
            let update = p["update"]
                .as_object()
                .ok_or("resident_intent_invalid_input")?;
            if !update.keys().all(|k| {
                [
                    "summary",
                    "status",
                    "wakeAfterSeconds",
                    "goal",
                    "currentStep",
                    "nextSteps",
                    "advanceWhen",
                    "adjustReason",
                    "source",
                ]
                .contains(&k.as_str())
            }) {
                return Err("resident_intent_invalid_input");
            }
            let u = &p["update"];
            let summary = u["summary"]
                .as_str()
                .ok_or("resident_intent_invalid_summary")?
                .trim();
            if summary.is_empty() || summary.chars().count() > 2000 {
                return Err("resident_intent_invalid_summary");
            }
            let status = u["status"]
                .as_str()
                .filter(|s| ["active", "waiting_user", "waiting_event", "completed"].contains(s))
                .ok_or("resident_intent_invalid_input")?;
            let delay = if u["wakeAfterSeconds"].is_null() {
                None
            } else {
                Some(
                    u["wakeAfterSeconds"]
                        .as_f64()
                        .filter(|v| {
                            v.is_finite()
                                && (1. ..=86400.).contains(v)
                                && ["active", "waiting_event"].contains(&status)
                        })
                        .ok_or("resident_intent_invalid_wake")?,
                )
            };
            let old = value["intent"].clone();
            let mut intent = json!({"summary":summary,"status":status});
            // Clock comes from authenticated host observation, never model args.
            if let Some(delay) = delay {
                let now = p["nowMillis"]
                    .as_i64()
                    .filter(|v| *v >= 0)
                    .ok_or("resident_intent_invalid_clock")?;
                intent["wakeAt"] = json!(iso_time(
                    now.checked_add((delay * 1000.) as i64)
                        .ok_or("resident_intent_invalid_clock")?
                )?);
            }
            for key in ["goal", "currentStep", "advanceWhen", "adjustReason"] {
                let v = resolved(u, key, &old)?;
                if !v.is_null() {
                    intent[key] = v;
                }
            }
            let steps = if let Some(raw) = u.get("nextSteps") {
                let raw = raw.as_array().ok_or("resident_intent_invalid_input")?;
                let mut steps = Vec::new();
                for raw in raw {
                    let s = raw.as_str().ok_or("resident_intent_invalid_input")?.trim();
                    if !s.is_empty() && steps.len() < 8 {
                        steps.push(json!(s.chars().take(500).collect::<String>()));
                    }
                }
                json!(steps)
            } else {
                old["nextSteps"].clone()
            };
            if !steps.is_null() {
                intent["nextSteps"] = steps;
            }
            if !old["lastOutcome"].is_null() {
                intent["lastOutcome"] = old["lastOutcome"].clone();
            }
            let source = u
                .get("source")
                .or_else(|| old.get("source"))
                .cloned()
                .unwrap_or_else(|| json!(if human { "userDelegated" } else { "autonomous" }));
            if !["userDelegated", "autonomous"].contains(&source.as_str().unwrap_or("")) {
                return Err("resident_intent_invalid_input");
            }
            intent["source"] = source;
            value["intent"] = intent;
            if resume {
                value["intentPausedByUser"] = json!(false)
            }
            let receipt = commit(&tx, &s, value.clone(), text(p, "requestID")?.into(), vec![])?;
            refresh_draft(&tx, &s, &value)?;
            json!({"record":{"revision":receipt["revision"],"value":value},"replayed":receipt["replayed"]})
        }
        "resident_intent_pause" => {
            let action = text(p, "action")?;
            if !["userStop", "resumeUser", "system"].contains(&action) {
                return Err("resident_intent_invalid_input");
            }
            let mut value = plan(&tx, &s)?;
            if action != "system" {
                value["intentPausedByUser"] = json!(action == "userStop");
            }
            let receipt = commit(&tx, &s, value.clone(), text(p, "requestID")?.into(), vec![])?;
            refresh_draft(&tx, &s, &value)?;
            json!({"record":{"revision":receipt["revision"],"value":value}})
        }
        "resident_intent_enqueue" => {
            let recent = events(&p["groundedEvents"], 24)?;
            let mut value = plan(&tx, &s)?;
            value["groundedEvents"] = json!(recent);
            let value = canonical(&value)?;
            let old:Option<(String,String,String,String)>=tx.query_row("SELECT events,pending,request,value FROM resident_intent_drafts WHERE world=?1 AND scope=?2",params![s.world_id,s.resident_scope],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(|_|"storage_unavailable")?;
            let retained = old
                .as_ref()
                .map(|o| {
                    serde_json::from_str::<Vec<Value>>(&o.1)
                        .map_err(|_| "resident_intent_invalid_state")
                })
                .transpose()?
                .unwrap_or_default();
            let pending = union(&recent, &retained);
            let request = if let Some((old_events, _, request, old_value)) = old {
                let old_events: Vec<Value> = serde_json::from_str(&old_events)
                    .map_err(|_| "resident_intent_invalid_state")?;
                if by_id(&old_events) == by_id(&recent)
                    && by_id(&retained) == by_id(&pending)
                    && old_value == value
                {
                    request
                } else {
                    uuid::Uuid::new_v4().to_string()
                }
            } else {
                uuid::Uuid::new_v4().to_string()
            };
            revision(&tx, &s)?;
            tx.execute("INSERT INTO resident_intent_drafts(world,scope,events,pending,request,value)VALUES(?1,?2,?3,?4,?5,?6)ON CONFLICT(world,scope)DO UPDATE SET events=excluded.events,pending=excluded.pending,request=excluded.request,value=excluded.value",params![s.world_id,s.resident_scope,canonical(&json!(recent))?,canonical(&json!(pending))?,request,value]).map_err(|_|"storage_unavailable")?;
            json!({"queued":true})
        }
        "resident_intent_drain" => {
            let next:Option<(String,String,String,String,String)>=tx.query_row("SELECT world,scope,value,pending,request FROM resident_intent_drafts ORDER BY sequence LIMIT 1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?))).optional().map_err(|_|"storage_unavailable")?;
            if let Some((world, scope, value, pending, id)) = next {
                let target = resident::Scope {
                    world_id: world,
                    resident_scope: scope,
                };
                let value =
                    serde_json::from_str(&value).map_err(|_| "resident_intent_invalid_state")?;
                let pending: Vec<Value> =
                    serde_json::from_str(&pending).map_err(|_| "resident_intent_invalid_state")?;
                let mut facts = Vec::new();
                for event in pending {
                    let durable:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM resident_events WHERE world_id=?1 AND resident_scope=?2 AND id=?3)",params![target.world_id,target.resident_scope,event["id"].as_str()],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                    if !durable {
                        facts.push(resident::Item {
                            id: event["id"].as_str().unwrap().into(),
                            kind: event["kind"].as_str().unwrap().into(),
                            payload: json!({"summary":event["summary"]}),
                        });
                    }
                }
                tx.execute_batch("SAVEPOINT resident_intent_drain_attempt")
                    .map_err(|_| "storage_unavailable")?;
                let current =
                    resident::read_state(&tx, &target, "resident", "plan").map_err(|e| e.code)?;
                // A lost successful drain reply followed by an identical save
                // must replay the durable value without advancing revision.
                // This is not a CAS bypass: the authority revision must still
                // equal the real current record and every fact must be durable.
                let unchanged =
                    current.as_ref().is_some_and(|r| r.value == value) && facts.is_empty();
                let outcome =
                    if unchanged && current.as_ref().unwrap().revision == revision(&tx, &target)? {
                        Ok(json!({"revision":current.as_ref().unwrap().revision,"replayed":true}))
                    } else {
                        commit(&tx, &target, value, id, facts)
                    };
                match outcome {
                    Ok(receipt) => {
                        tx.execute_batch("RELEASE resident_intent_drain_attempt")
                            .map_err(|_| "storage_unavailable")?;
                        tx.execute(
                            "DELETE FROM resident_intent_drafts WHERE world=?1 AND scope=?2",
                            params![target.world_id, target.resident_scope],
                        )
                        .map_err(|_| "storage_unavailable")?;
                        json!({"drained":true,"scope":target,"receipt":receipt})
                    }
                    Err(code) => {
                        tx.execute_batch("ROLLBACK TO resident_intent_drain_attempt; RELEASE resident_intent_drain_attempt").map_err(|_|"storage_unavailable")?;
                        if code == "request_id_conflict" {
                            tx.execute("UPDATE resident_intent_drafts SET request=?3 WHERE world=?1 AND scope=?2",params![target.world_id,target.resident_scope,uuid::Uuid::new_v4().to_string()]).map_err(|_|"storage_unavailable")?;
                        }
                        json!({"drained":false,"errorCode":code})
                    }
                }
            } else {
                json!({"drained":false,"empty":true})
            }
        }
        _ => return Err("unsupported_method"),
    };
    if let Some(input) = command_input {
        tx.execute("INSERT INTO resident_intent_commands(world,scope,request,input,output)VALUES(?1,?2,?3,?4,?5)",params![s.world_id,s.resident_scope,text(p,"requestID")?,input,canonical(&output)?]).map_err(|_|"storage_unavailable")?;
    }
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(output)
}
// Gregorian UTC conversion; no process/global timezone or new dependency.
fn iso_time(ms: i64) -> Result<String> {
    if !(0..=253402300799000).contains(&ms) {
        return Err("resident_intent_invalid_clock");
    }
    let seconds = ms / 1000;
    let z = seconds / 86400 + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let mut year = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = mp + if mp < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    let within = seconds % 86400;
    Ok(format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        within / 3600,
        within / 60 % 60,
        within % 60
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn lost_successful_drain_reply_identical_save_does_not_advance_revision() {
        let mut db = db();
        let observation = json!({"groundedEvents":[fact("durable")]});
        call(&mut db, "resident_intent_enqueue", "a", observation.clone()).unwrap();
        let first = call(&mut db, "resident_intent_drain", "a", json!({})).unwrap();
        call(&mut db, "resident_intent_enqueue", "a", observation).unwrap();
        let retried = call(&mut db, "resident_intent_drain", "a", json!({})).unwrap();
        assert_eq!(first["receipt"]["revision"], retried["receipt"]["revision"]);
        assert_eq!(retried["receipt"]["replayed"], true);
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM resident_events", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
    }
    fn db() -> Connection {
        let db = Connection::open_in_memory().unwrap();
        resident::schema(&db).unwrap();
        crate::agent_scheduler::schema(&db).unwrap();
        schema(&db).unwrap();
        db
    }
    fn call(
        db: &mut Connection,
        method: &str,
        resident_scope: &str,
        extra: Value,
    ) -> Result<Value> {
        let mut p = json!({"scope":{"worldID":"world","residentScope":resident_scope}});
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone()
        }
        request(db, method, &p)
    }
    fn scheduler(db: &mut Connection, method: &str, extra: Value) -> Value {
        let mut p = json!({"worldID":"world","residentScope":"resident"});
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone()
        }
        crate::agent_scheduler::request(db, method, &p).unwrap()
    }
    fn claim(db: &mut Connection, human: bool) {
        scheduler(
            db,
            "agent_loop_configure",
            json!({"hostSessionID":"host","hourlyLimit":6,"minimumWakeIntervalSeconds":1,"backgroundEnabled":true}),
        );
        let mut p = json!({"eventID":"event","intentID":"intent","kind":if human{"human"}else{"background"},"intentState":"active","command":{}});
        if human {
            p["messageIDs"] = json!(["human-message"]);
            p["inputRefs"] = json!({"human-message":"actual-input"});
        }
        scheduler(db, "agent_loop_enqueue", p);
        assert_eq!(
            scheduler(
                db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"hostSessionID":"host","runID":"run"})
            )["claimed"],
            true
        );
    }
    fn update() -> Value {
        json!({"runID":"run","hostSessionID":"host","requestID":"mutation","nowMillis":1000,"resumePausedIntent":false,"update":{"summary":"执行安排","status":"active","goal":"  目标  ","nextSteps":[" a "," ","b"],"wakeAfterSeconds":60}})
    }
    fn fact(id: &str) -> Value {
        json!({"id":id,"kind":"world.observed","summary":format!("actual {id}")})
    }
    #[test]
    fn actual_claim_permission_pause_and_stale_run_boundaries() {
        let mut db = db();
        claim(&mut db, false);
        call(
            &mut db,
            "resident_intent_pause",
            "resident",
            json!({"requestID":"stop","action":"userStop"}),
        )
        .unwrap();
        let mut p = update();
        p["resumePausedIntent"] = json!(true);
        assert_eq!(
            call(&mut db, "resident_intent_update", "resident", p.clone()).unwrap_err(),
            "resident_intent_missing_human_guidance"
        );
        p["resumePausedIntent"] = json!(false);
        assert_eq!(
            call(&mut db, "resident_intent_update", "resident", p).unwrap_err(),
            "resident_intent_paused"
        );
        let mut foreign = update();
        foreign["hostSessionID"] = json!("foreign");
        assert_eq!(
            call(&mut db, "resident_intent_update", "resident", foreign).unwrap_err(),
            "resident_intent_inactive_run"
        );
        scheduler(
            &mut db,
            "agent_loop_cancel",
            json!({"eventID":"event","runID":"run","hostSessionID":"host"}),
        );
        assert_eq!(
            call(&mut db, "resident_intent_update", "resident", update()).unwrap_err(),
            "resident_intent_inactive_run"
        );
    }
    #[test]
    fn human_update_canonical_fields_idempotency_and_partial_clear() {
        let mut db = db();
        claim(&mut db, true);
        call(
            &mut db,
            "resident_intent_pause",
            "resident",
            json!({"requestID":"stop","action":"userStop"}),
        )
        .unwrap();
        let mut p = update();
        p["resumePausedIntent"] = json!(true);
        let first = call(&mut db, "resident_intent_update", "resident", p.clone()).unwrap();
        assert_eq!(first["record"]["value"]["intentPausedByUser"], false);
        let intent = &first["record"]["value"]["intent"];
        assert_eq!(intent["goal"], "目标");
        assert_eq!(intent["nextSteps"], json!(["a", "b"]));
        assert_eq!(intent["source"], "userDelegated");
        assert_eq!(intent["wakeAt"], "1970-01-01T00:01:01Z");
        assert_eq!(
            call(&mut db, "resident_intent_update", "resident", p.clone()).unwrap(),
            first
        );
        p["update"]["summary"] = json!("changed");
        assert_eq!(
            call(&mut db, "resident_intent_update", "resident", p).unwrap_err(),
            "request_id_conflict"
        );
        let cleared=call(&mut db,"resident_intent_update","resident",json!({"runID":"run","hostSessionID":"host","requestID":"next","nowMillis":1000,"update":{"summary":"新安排","status":"waiting_user","goal":""}})).unwrap();
        assert!(cleared["record"]["value"]["intent"]["goal"].is_null());
        assert_eq!(
            cleared["record"]["value"]["intent"]["nextSteps"],
            json!(["a", "b"])
        );
    }
    #[test]
    fn pending_union_recent_window_fifo_durable_event_ids_scope_isolation() {
        let mut db = db();
        let first = (0..24)
            .map(|i| fact(&format!("old-{i}")))
            .collect::<Vec<_>>();
        let second = (0..24)
            .map(|i| fact(&format!("new-{i}")))
            .collect::<Vec<_>>();
        call(
            &mut db,
            "resident_intent_enqueue",
            "a",
            json!({"groundedEvents":first}),
        )
        .unwrap();
        call(
            &mut db,
            "resident_intent_enqueue",
            "b",
            json!({"groundedEvents":[fact("old-0")]}),
        )
        .unwrap();
        call(
            &mut db,
            "resident_intent_enqueue",
            "a",
            json!({"groundedEvents":second}),
        )
        .unwrap();
        let first = call(&mut db, "resident_intent_drain", "a", json!({})).unwrap();
        assert_eq!(first["scope"]["residentScope"], "a");
        let count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM resident_events WHERE resident_scope='a'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 48);
        assert_eq!(
            call(&mut db, "resident_intent_restore", "a", json!({})).unwrap()["record"]["value"]
                ["groundedEvents"]
                .as_array()
                .unwrap()
                .len(),
            24
        );
        assert_eq!(
            call(&mut db, "resident_intent_drain", "a", json!({})).unwrap()["scope"]
                ["residentScope"],
            "b"
        );
        let mut changed = fact("new-0");
        changed["summary"] = json!("new observation text");
        call(
            &mut db,
            "resident_intent_enqueue",
            "a",
            json!({"groundedEvents":[changed]}),
        )
        .unwrap();
        assert_eq!(
            call(&mut db, "resident_intent_drain", "a", json!({})).unwrap()["drained"],
            true
        );
        let count: i64 = db
            .query_row(
                "SELECT COUNT(*) FROM resident_events WHERE resident_scope='a'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 48);
    }
    #[test]
    fn cas_conflict_stops_preserves_pending_until_explicit_restore() {
        let mut db = db();
        call(
            &mut db,
            "resident_intent_enqueue",
            "a",
            json!({"groundedEvents":[fact("pending")]}),
        )
        .unwrap();
        let scope = resident::Scope {
            world_id: "world".into(),
            resident_scope: "a".into(),
        };
        let tx = db.transaction().unwrap();
        resident::commit(
            &tx,
            &resident::CommitRequest {
                scope,
                domain: "resident".into(),
                key: "plan".into(),
                expected_revision: 0,
                request_id: "independent-writer".into(),
                value: json!({"intent":null,"intentPausedByUser":true,"groundedEvents":[]}),
                events: vec![],
                messages: vec![],
            },
        )
        .unwrap();
        tx.commit().unwrap();
        let failed = call(&mut db, "resident_intent_drain", "a", json!({})).unwrap();
        assert_eq!(failed["errorCode"], "revision_conflict");
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM resident_intent_drafts", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        call(&mut db, "resident_intent_restore", "a", json!({})).unwrap();
        call(
            &mut db,
            "resident_intent_enqueue",
            "a",
            json!({"groundedEvents":[fact("pending")]}),
        )
        .unwrap();
        assert_eq!(
            call(&mut db, "resident_intent_drain", "a", json!({})).unwrap()["drained"],
            true
        );
        assert_eq!(
            call(&mut db, "resident_intent_restore", "a", json!({})).unwrap()["record"]["value"]
                ["intentPausedByUser"],
            true
        );
    }
}
