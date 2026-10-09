//! Durable dispatch authority. A claimed command is never automatically replayed.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

fn canonical_stored_input(raw: &str) -> Result<String> {
    let value: Value = serde_json::from_str(raw).map_err(|_| "storage_unavailable")?;
    crate::canonical_json::to_string(&value).map_err(|_| "storage_unavailable")
}

// Older rows may have preserved object insertion order. The textual unique
// index alone cannot enforce semantic ownership across those legacy encodings.
fn check_input_owner(
    db: &Connection,
    world: &str,
    scope: &str,
    input: &str,
    message: &str,
) -> Result<()> {
    let mut query = db
        .prepare(
            "SELECT message,input_ref FROM agent_loop_human_messages WHERE world=?1 AND scope=?2",
        )
        .map_err(|_| "storage_unavailable")?;
    let rows = query
        .query_map(params![world, scope], |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
        })
        .map_err(|_| "storage_unavailable")?;
    for row in rows {
        let (owner, stored) = row.map_err(|_| "storage_unavailable")?;
        if owner != message && canonical_stored_input(&stored)? == input {
            return Err("agent_loop_input_conflict");
        }
    }
    Ok(())
}

pub fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS agent_loop_config(world TEXT NOT NULL, scope TEXT NOT NULL, config TEXT NOT NULL, PRIMARY KEY(world,scope));
      CREATE TABLE IF NOT EXISTS agent_loop_events(world TEXT NOT NULL, scope TEXT NOT NULL, event TEXT NOT NULL, payload TEXT NOT NULL, state TEXT NOT NULL, run TEXT, session TEXT, claimed_at INTEGER, receipt TEXT, PRIMARY KEY(world,scope,event));
      CREATE INDEX IF NOT EXISTS agent_loop_budget ON agent_loop_events(world,scope,claimed_at);
      CREATE UNIQUE INDEX IF NOT EXISTS agent_loop_run ON agent_loop_events(world,scope,run) WHERE run IS NOT NULL;
      CREATE TABLE IF NOT EXISTS agent_loop_human_messages(world TEXT NOT NULL,scope TEXT NOT NULL,message TEXT NOT NULL,input_ref TEXT NOT NULL,state TEXT NOT NULL,event TEXT NOT NULL,run TEXT,session TEXT,receipt TEXT,mode TEXT NOT NULL DEFAULT 'human',PRIMARY KEY(world,scope,message));
      CREATE UNIQUE INDEX IF NOT EXISTS agent_loop_input_ref ON agent_loop_human_messages(world,scope,input_ref);")
        .map_err(|_| "storage_unavailable")
}

pub fn recover(db: &Connection) -> Result<()> {
    db.execute(
        "UPDATE agent_loop_events SET state='unknown' WHERE state IN ('claimed','cancel_requested')",
        [],
    )
    .map_err(|_| "storage_unavailable")?;
    db.execute(
        "UPDATE agent_loop_human_messages SET state='unknown' WHERE state IN ('claimed','steer_claimed')",
        [],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(())
}

fn text<'a>(p: &'a Value, key: &str) -> Result<&'a str> {
    p.get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && v.len() <= 256)
        .ok_or("agent_loop_invalid_request")
}
fn clock(p: &Value) -> Result<i64> {
    p.get("nowMillis")
        .and_then(Value::as_i64)
        .filter(|v| *v >= 0)
        .ok_or("agent_loop_invalid_clock")
}
fn unstarted_receipt(receipt: &Value) -> bool {
    receipt["kind"] == "resident_model_turn"
        && receipt["executionNotStarted"] == true
        && receipt["invocationStarted"] == false
}
fn flag(p: &Value, key: &str, default: bool) -> bool {
    p.get(key).and_then(Value::as_bool).unwrap_or(default)
}

pub fn request(db: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let world = text(p, "worldID")?;
    let scope = text(p, "residentScope")?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    let config: Option<String> = tx
        .query_row(
            "SELECT config FROM agent_loop_config WHERE world=?1 AND scope=?2",
            params![world, scope],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let result = match method {
        "agent_loop_configure" => {
            text(p, "hostSessionID")?;
            for key in [
                "backgroundEnabled",
                "userStopped",
                "editing",
                "humanTurn",
                "available",
            ] {
                if p.get(key).is_some_and(|v| !v.is_boolean()) {
                    return Err("agent_loop_invalid_request");
                }
            }
            let limit = p
                .get("hourlyLimit")
                .and_then(Value::as_u64)
                .filter(|n| *n <= 6)
                .ok_or("agent_loop_invalid_limit")?;
            let interval = p
                .get("minimumWakeIntervalSeconds")
                .and_then(Value::as_u64)
                .filter(|n| *n >= 1 && *n <= 86400)
                .ok_or("agent_loop_invalid_interval")?;
            let mut c = p.clone();
            c["hourlyLimit"] = json!(limit);
            c["minimumWakeIntervalSeconds"] = json!(interval);
            tx.execute("UPDATE agent_loop_events SET state='unknown' WHERE world=?1 AND scope=?2 AND state IN ('claimed','cancel_requested') AND session!=?3",params![world,scope,text(p,"hostSessionID")?]).map_err(|_|"storage_unavailable")?;
            tx.execute("UPDATE agent_loop_human_messages SET state='unknown' WHERE world=?1 AND scope=?2 AND state IN ('claimed','steer_claimed') AND session!=?3",params![world,scope,text(p,"hostSessionID")?]).map_err(|_|"storage_unavailable")?;
            tx.execute("INSERT INTO agent_loop_config VALUES(?1,?2,?3) ON CONFLICT(world,scope) DO UPDATE SET config=excluded.config",params![world,scope,c.to_string()]).map_err(|_| "storage_unavailable")?;
            json!({"configured":true})
        }
        "agent_loop_enqueue" => {
            let event = text(p, "eventID")?;
            let mut effective_event = event.to_owned();
            text(p, "intentID")?;
            let kind = text(p, "kind")?;
            for key in [
                "hasPendingEvent",
                "idleReviewDue",
                "restUntilTrigger",
                "advanceConditionPending",
            ] {
                if p.get(key).is_some_and(|v| !v.is_boolean()) {
                    return Err("agent_loop_invalid_request");
                }
            }
            if p.get("wakeAtMillis")
                .is_some_and(|v| v.as_i64().filter(|n| *n >= 0).is_none())
            {
                return Err("agent_loop_invalid_clock");
            }
            if !matches!(kind, "background" | "continuation" | "human")
                || !matches!(
                    text(p, "intentState")?,
                    "active" | "waiting_event" | "waiting_user" | "completed"
                )
                || p.get("command").is_none()
            {
                return Err("agent_loop_invalid_request");
            }
            if let Some(deadline) = p.get("opportunityDeadlineMillis") {
                if deadline.as_i64().filter(|n| *n >= 0).is_none() {
                    return Err("agent_loop_invalid_clock");
                }
            }
            let old: Option<String> = tx.query_row("SELECT payload FROM agent_loop_events WHERE world=?1 AND scope=?2 AND event=?3",params![world,scope,event],|r|r.get(0)).optional().map_err(|_| "storage_unavailable")?;
            if let Some(old) = old {
                if serde_json::from_str::<Value>(&old).map_err(|_| "storage_unavailable")? != *p {
                    return Err("agent_loop_event_conflict");
                }
                if kind != "human" {
                    let terminal: (String, Option<String>) = tx.query_row("SELECT state,receipt FROM agent_loop_events WHERE world=?1 AND scope=?2 AND event=?3",params![world,scope,event],|r|Ok((r.get(0)?,r.get(1)?))).map_err(|_|"storage_unavailable")?;
                    let receipt = terminal
                        .1
                        .as_deref()
                        .map(serde_json::from_str::<Value>)
                        .transpose()
                        .map_err(|_| "storage_unavailable")?;
                    if terminal.0 == "cancelled"
                        && receipt
                            .as_ref()
                            .is_some_and(|r| r["_schedulerReservationReleased"] == true)
                    {
                        let c: Value = serde_json::from_str(
                            config.as_deref().ok_or("agent_loop_not_configured")?,
                        )
                        .map_err(|_| "storage_unavailable")?;
                        // A confirmed never-started reservation is retryable
                        // even when permissions return to the configuration
                        // present before native invocation was withdrawn.
                        {
                            let encoded = crate::canonical_json::to_string(
                                &json!({"event":event,"configuration":c}),
                            )
                            .map_err(|_| "storage_unavailable")?;
                            effective_event =
                                format!("retry.{:x}", Sha256::digest(encoded.as_bytes()));
                            let mut retry = p.clone();
                            retry["eventID"] = json!(effective_event);
                            retry["retryOf"] = json!(event);
                            tx.execute("INSERT OR IGNORE INTO agent_loop_events(world,scope,event,payload,state) VALUES(?1,?2,?3,?4,'pending')",params![world,scope,effective_event,retry.to_string()]).map_err(|_|"storage_unavailable")?;
                        }
                    }
                }
            } else {
                if kind == "human" {
                    let messages = p
                        .get("messageIDs")
                        .and_then(Value::as_array)
                        .filter(|v| !v.is_empty())
                        .ok_or("agent_loop_invalid_request")?;
                    let refs = p
                        .get("inputRefs")
                        .and_then(Value::as_object)
                        .ok_or("agent_loop_invalid_request")?;
                    let mut seen = std::collections::HashSet::new();
                    for message in messages {
                        let id = message
                            .as_str()
                            .filter(|id| !id.is_empty() && id.len() <= 256)
                            .ok_or("agent_loop_invalid_request")?;
                        if !seen.insert(id) {
                            return Err("agent_loop_invalid_request");
                        }
                        let input_ref = crate::canonical_json::to_string(
                            refs.get(id).ok_or("agent_loop_invalid_request")?,
                        )
                        .map_err(|_| "agent_loop_invalid_request")?;
                        check_input_owner(&tx, world, scope, &input_ref, id)?;
                        let old:Option<(String,String)>=tx.query_row("SELECT state,input_ref FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND message=?3",params![world,scope,id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
                        if let Some((state, old_ref)) = old {
                            if canonical_stored_input(&old_ref)? != input_ref
                                || !matches!(state.as_str(), "queued" | "not_delivered")
                            {
                                return Err("agent_loop_message_conflict");
                            }
                            // A queued message cannot belong to two pending batches.
                            let old_event:String=tx.query_row("SELECT event FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND message=?3",params![world,scope,id],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                            if state == "queued" && old_event != event {
                                return Err("agent_loop_message_conflict");
                            }
                            tx.execute("UPDATE agent_loop_human_messages SET state='queued',event=?4,run=NULL,session=NULL,receipt=NULL,mode='human' WHERE world=?1 AND scope=?2 AND message=?3",params![world,scope,id,event]).map_err(|_|"storage_unavailable")?;
                        } else {
                            tx.execute("INSERT INTO agent_loop_human_messages(world,scope,message,input_ref,state,event) VALUES(?1,?2,?3,?4,'queued',?5)",params![world,scope,id,input_ref,event]).map_err(|_|"storage_unavailable")?;
                        }
                    }
                }
                tx.execute("INSERT INTO agent_loop_events(world,scope,event,payload,state) VALUES(?1,?2,?3,?4,'pending')",params![world,scope,event,p.to_string()]).map_err(|_|"storage_unavailable")?;
            }
            json!({"enqueued":true,"eventID":effective_event})
        }
        "agent_loop_claim" => {
            let now = clock(p)?;
            let run = text(p, "runID")?;
            let session = text(p, "hostSessionID")?;
            let c: Value = serde_json::from_str(&config.ok_or("agent_loop_not_configured")?)
                .map_err(|_| "storage_unavailable")?;
            if c.get("hostSessionID").and_then(Value::as_str) != Some(session) {
                return Err("agent_loop_stale_session");
            }
            let blocked = flag(&c, "editing", false) || !flag(&c, "available", true);
            let (count,last): (i64,Option<i64>) = tx.query_row("SELECT COALESCE(SUM(CASE WHEN claimed_at>?3 THEN 1 ELSE 0 END),0),MAX(claimed_at) FROM agent_loop_events WHERE world=?1 AND scope=?2 AND json_extract(payload,'$.kind') IN ('background','continuation') AND NOT (state='cancelled' AND COALESCE(json_extract(receipt,'$._schedulerReservationReleased'),0)=1)",params![world,scope,now.saturating_sub(3600000)],|r|Ok((r.get(0)?,r.get(1)?))).map_err(|_|"storage_unavailable")?;
            let used: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_events WHERE world=?1 AND scope=?2 AND run=?3)",params![world,scope,run],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
            if used {
                return Err("agent_loop_run_conflict");
            }
            // A turn is **executing** only while one of its events is genuinely in
            // flight. An `unknown` event is the durable record of a turn whose
            // invocation already returned — or whose owning host session is gone —
            // and whose side effects are still unconfirmed: every writer of
            // `unknown` (`recover` at daemon start, `agent_loop_configure` for a
            // foreign session, and the run tails in `agent_runtime` / `agent_cli` /
            // `agent_claude` / `agent_dsh`) runs *after* the invocation returned.
            // Counting it here (the rule until 2026-10-09) let the daemon poison
            // its own scope: `recover()` rewrote one orphaned turn from the
            // previous build into `unknown`, and from then on every
            // `agent_loop_claim` for that world+scope answered `claimed:false` for
            // the life of the database — a human message stayed `queued` and its
            // event stayed `pending` forever, so chat looked dead however many
            // times the user pressed send. The DSH tool gate was corrected the same
            // way (`agent_dsh_stale_unconfirmed_tools`); the row is still kept —
            // never rewritten to a terminal state without the host's own
            // verification — it just stops gating unrelated turns.
            let executing: bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_events WHERE world=?1 AND scope=?2 AND state IN ('claimed','cancel_requested'))",params![world,scope],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
            let stale: i64=tx.query_row("SELECT count(*) FROM agent_loop_events WHERE world=?1 AND scope=?2 AND state='unknown'",params![world,scope],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
            let limit = c["hourlyLimit"].as_i64().unwrap_or(0);
            let interval = c["minimumWakeIntervalSeconds"].as_i64().unwrap_or(1) * 1000;
            if blocked || executing {
                json!({"claimed":false})
            } else {
                let rows: Vec<(String, String)> = {
                    let mut q = tx.prepare("SELECT event,payload FROM agent_loop_events WHERE world=?1 AND scope=?2 AND state='pending' ORDER BY CASE json_extract(payload,'$.kind') WHEN 'human' THEN 0 ELSE 1 END,rowid").map_err(|_|"storage_unavailable")?;
                    let rows = q
                        .query_map(params![world, scope], |r| Ok((r.get(0)?, r.get(1)?)))
                        .map_err(|_| "storage_unavailable")?;
                    rows.collect::<std::result::Result<_, _>>()
                        .map_err(|_| "storage_unavailable")?
                };
                let mut output = json!({"claimed":false});
                for (event, payload) in rows {
                    let e: Value =
                        serde_json::from_str(&payload).map_err(|_| "storage_unavailable")?;
                    if p.get("eventID")
                        .and_then(Value::as_str)
                        .is_some_and(|expected| expected != event)
                    {
                        if e["kind"] == "human" {
                            break;
                        }
                        continue;
                    }
                    let human = e["kind"] == "human";
                    if !human
                        && (flag(&c, "userStopped", false)
                            || flag(&c, "humanTurn", false)
                            || count >= limit
                            || last.is_some_and(|last| now.saturating_sub(last) < interval))
                    {
                        continue;
                    }
                    if !human
                        && e.get("opportunityDeadlineMillis")
                            .and_then(Value::as_i64)
                            .is_some_and(|deadline| now >= deadline)
                    {
                        tx.execute("UPDATE agent_loop_events SET state='cancelled' WHERE world=?1 AND scope=?2 AND event=?3",params![world,scope,event]).map_err(|_|"storage_unavailable")?;
                        continue;
                    }
                    let continuation = e["kind"] == "continuation";
                    let triggered = flag(&e, "hasPendingEvent", false);
                    let due = e
                        .get("wakeAtMillis")
                        .and_then(Value::as_i64)
                        .is_some_and(|wake| now >= wake);
                    if !human
                        && ((e["intentState"] == "waiting_user" && !continuation)
                            || (e["intentState"] == "waiting_event" && !triggered && !due)
                            || (e["intentState"] == "completed"
                                && !triggered
                                && !due
                                && !flag(&e, "idleReviewDue", false))
                            || (!triggered && flag(&e, "restUntilTrigger", false))
                            || (e["intentState"] == "active"
                                && !triggered
                                && e.get("wakeAtMillis")
                                    .and_then(Value::as_i64)
                                    .is_some_and(|wake| now < wake))
                            || (e["intentState"] == "active"
                                && !triggered
                                && flag(&e, "advanceConditionPending", false)
                                && e.get("wakeAtMillis").is_none())
                            || (e["kind"] == "background" && !flag(&c, "backgroundEnabled", false)))
                    {
                        continue;
                    }
                    if stale > 0 {
                        // Named, readable and never silent — emitted at most once
                        // per granted turn, because that is exactly the moment the
                        // unconfirmed record stops gating: the effect of those
                        // turns is still unconfirmed, we just no longer pretend a
                        // new turn could learn it.
                        eprintln!(
                            "gmgn-taskd: {}",
                            json!({
                                "event": "recovered",
                                "code": "agent_loop_stale_unconfirmed_turns",
                                "worldID": world,
                                "residentScope": scope,
                                "count": stale,
                            })
                        );
                    }
                    tx.execute("UPDATE agent_loop_events SET state='claimed',run=?4,session=?5,claimed_at=?6 WHERE world=?1 AND scope=?2 AND event=?3",params![world,scope,event,run,session,now]).map_err(|_|"storage_unavailable")?;
                    if human {
                        tx.execute("UPDATE agent_loop_human_messages SET state='claimed',run=?4,session=?5 WHERE world=?1 AND scope=?2 AND event=?3 AND state='queued'",params![world,scope,event,run,session]).map_err(|_|"storage_unavailable")?;
                    }
                    output = json!({"claimed":true,"eventID":event,"runID":run,"hostSessionID":session,"command":e["command"]});
                    break;
                }
                output
            }
        }
        "agent_loop_steer_admit" | "agent_loop_steer_finish" => {
            let event = text(p, "eventID")?;
            let run = text(p, "runID")?;
            let session = text(p, "hostSessionID")?;
            let message = text(p, "messageID")?;
            let c: Value = serde_json::from_str(&config.ok_or("agent_loop_not_configured")?)
                .map_err(|_| "storage_unavailable")?;
            if c["hostSessionID"].as_str() != Some(session) {
                return Err("agent_loop_stale_session");
            }
            let parent:Option<(String,Option<String>,Option<String>)>=tx.query_row("SELECT state,run,session FROM agent_loop_events WHERE world=?1 AND scope=?2 AND event=?3",params![world,scope,event],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional().map_err(|_|"storage_unavailable")?;
            let (parent_state, parent_run, parent_session) =
                parent.ok_or("agent_loop_event_missing")?;
            if parent_run.as_deref() != Some(run) || parent_session.as_deref() != Some(session) {
                return Err("agent_loop_receipt_mismatch");
            }
            let old:Option<(String,String,String,Option<String>,Option<String>,Option<String>)>=tx.query_row("SELECT state,input_ref,event,run,session,receipt FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND message=?3",params![world,scope,message],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).optional().map_err(|_|"storage_unavailable")?;
            if method == "agent_loop_steer_admit" {
                if parent_state != "claimed"
                    || flag(&c, "editing", false)
                    || !flag(&c, "available", true)
                {
                    return Err("agent_loop_parent_inactive");
                }
                let input_ref = crate::canonical_json::to_string(
                    p.get("inputRef").ok_or("agent_loop_invalid_request")?,
                )
                .map_err(|_| "agent_loop_invalid_request")?;
                check_input_owner(&tx, world, scope, &input_ref, message)?;
                if let Some((state, old_ref, old_event, old_run, old_session, _)) = old {
                    if canonical_stored_input(&old_ref)? != input_ref
                        || old_event != event
                        || old_run.as_deref() != Some(run)
                        || old_session.as_deref() != Some(session)
                    {
                        return Err("agent_loop_message_conflict");
                    }
                    json!({"admitted":false,"delivery":state})
                } else {
                    tx.execute("INSERT INTO agent_loop_human_messages(world,scope,message,input_ref,state,event,run,session,mode) VALUES(?1,?2,?3,?4,'steer_claimed',?5,?6,?7,'steering')",params![world,scope,message,input_ref,event,run,session]).map_err(|_|"storage_unavailable")?;
                    json!({"admitted":true,"delivery":"steer_claimed"})
                }
            } else {
                let delivery = text(p, "delivery")?;
                if !matches!(delivery, "delivered" | "not_delivered" | "unknown") {
                    return Err("agent_loop_invalid_receipt");
                }
                let receipt = p
                    .get("receipt")
                    .ok_or("agent_loop_invalid_receipt")?
                    .to_string();
                let (state, _, old_event, old_run, old_session, old_receipt) =
                    old.ok_or("agent_loop_message_missing")?;
                if old_event != event
                    || old_run.as_deref() != Some(run)
                    || old_session.as_deref() != Some(session)
                {
                    return Err("agent_loop_receipt_mismatch");
                }
                if state == delivery && old_receipt.as_deref() == Some(&receipt) {
                    json!({"accepted":true,"duplicate":true})
                } else if state != "steer_claimed" || parent_state == "unknown" {
                    return Err("agent_loop_receipt_conflict");
                } else {
                    tx.execute("UPDATE agent_loop_human_messages SET state=?4,receipt=?5 WHERE world=?1 AND scope=?2 AND message=?3",params![world,scope,message,delivery,receipt]).map_err(|_|"storage_unavailable")?;
                    json!({"accepted":true,"duplicate":false})
                }
            }
        }
        "agent_loop_complete" | "agent_loop_confirm_cancel" | "agent_loop_reconcile" => {
            let event = text(p, "eventID")?;
            let run = text(p, "runID")?;
            let session = text(p, "hostSessionID")?;
            let reconcile = method == "agent_loop_reconcile";
            if reconcile && p.get("receipt").is_some_and(unstarted_receipt) {
                // An execution recovered as unknown cannot be declared never
                // started merely to release its reserved budget.
                return Err("agent_loop_invalid_receipt");
            }
            let status = if method == "agent_loop_confirm_cancel" {
                "cancelled"
            } else if reconcile {
                text(p, "outcome")?
            } else {
                text(p, "status")?
            };
            if !matches!(status, "completed" | "failed" | "cancelled")
                || (method == "agent_loop_complete" && status == "cancelled")
            {
                return Err("agent_loop_invalid_receipt");
            }
            let supplied_receipt = p.get("receipt").ok_or("agent_loop_invalid_receipt")?;
            if supplied_receipt
                .get("_schedulerReservationReleased")
                .is_some()
                || supplied_receipt.get("_schedulerConfiguration").is_some()
            {
                return Err("agent_loop_invalid_receipt");
            }
            let c: Value = serde_json::from_str(&config.ok_or("agent_loop_not_configured")?)
                .map_err(|_| "storage_unavailable")?;
            if c["hostSessionID"].as_str() != Some(session) {
                return Err("agent_loop_stale_session");
            }
            let row: Option<(String,Option<String>,Option<String>,Option<String>)>=tx.query_row("SELECT state,run,session,receipt FROM agent_loop_events WHERE world=?1 AND scope=?2 AND event=?3",params![world,scope,event],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(|_|"storage_unavailable")?;
            let (state, old_run, old_session, old_receipt) =
                row.ok_or("agent_loop_event_missing")?;
            let original_session = if reconcile {
                text(p, "originalHostSessionID")?
            } else {
                session
            };
            if old_run.as_deref() != Some(run) || old_session.as_deref() != Some(original_session) {
                return Err("agent_loop_receipt_mismatch");
            }
            let old_supplied = old_receipt
                .as_deref()
                .map(serde_json::from_str::<Value>)
                .transpose()
                .map_err(|_| "storage_unavailable")?
                .map(|mut old| {
                    if let Some(object) = old.as_object_mut() {
                        object.remove("_schedulerReservationReleased");
                        object.remove("_schedulerConfiguration");
                    }
                    old
                });
            if state == status && old_supplied.as_ref() == Some(supplied_receipt) {
                json!({"accepted":true,"duplicate":true})
            } else if (reconcile && state != "unknown")
                || (!reconcile && !matches!(state.as_str(), "claimed" | "cancel_requested"))
            {
                return Err("agent_loop_receipt_conflict");
            } else {
                let mut persisted_receipt = supplied_receipt.clone();
                if !reconcile && status == "cancelled" && unstarted_receipt(supplied_receipt) {
                    persisted_receipt["_schedulerReservationReleased"] = json!(true);
                    persisted_receipt["_schedulerConfiguration"] = c;
                }
                let receipt = crate::canonical_json::to_string(&persisted_receipt)
                    .map_err(|_| "agent_loop_invalid_receipt")?;
                tx.execute("UPDATE agent_loop_events SET state=?4,receipt=?5 WHERE world=?1 AND scope=?2 AND event=?3",params![world,scope,event,status,receipt]).map_err(|_|"storage_unavailable")?;
                tx.execute("UPDATE agent_loop_human_messages SET state=?4 WHERE world=?1 AND scope=?2 AND event=?3 AND mode='human' AND state IN ('claimed','unknown')",params![world,scope,event,status]).map_err(|_|"storage_unavailable")?;
                json!({"accepted":true,"duplicate":false})
            }
        }
        "agent_loop_cancel" => {
            let event = text(p, "eventID")?;
            let state: Option<String> = tx
                .query_row(
                    "SELECT state FROM agent_loop_events WHERE world=?1 AND scope=?2 AND event=?3",
                    params![world, scope, event],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|_| "storage_unavailable")?;
            let state = state.ok_or("agent_loop_event_missing")?;
            let next = match state.as_str() {
                "pending" => "cancelled",
                "claimed" => "cancel_requested",
                other => other,
            };
            tx.execute(
                "UPDATE agent_loop_events SET state=?4 WHERE world=?1 AND scope=?2 AND event=?3",
                params![world, scope, event, next],
            )
            .map_err(|_| "storage_unavailable")?;
            if next == "cancelled" {
                tx.execute("UPDATE agent_loop_human_messages SET state='cancelled' WHERE world=?1 AND scope=?2 AND event=?3 AND state='queued'",params![world,scope,event]).map_err(|_|"storage_unavailable")?;
            }
            json!({"cancelled":next=="cancelled","cancelRequested":next=="cancel_requested","requiresVerification":next=="unknown","state":next})
        }
        "agent_loop_read" => {
            let mut q=tx.prepare("SELECT event,state,run,session,claimed_at,payload,receipt FROM agent_loop_events WHERE world=?1 AND scope=?2 ORDER BY rowid").map_err(|_|"storage_unavailable")?;
            let rows=q.query_map(params![world,scope],|r|Ok(json!({"eventID":r.get::<_,String>(0)?,"state":r.get::<_,String>(1)?,"runID":r.get::<_,Option<String>>(2)?,"hostSessionID":r.get::<_,Option<String>>(3)?,"claimedAtMillis":r.get::<_,Option<i64>>(4)?,"payload":r.get::<_,String>(5)?,"receipt":r.get::<_,Option<String>>(6)?}))).map_err(|_|"storage_unavailable")?;
            let mut events = rows
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| "storage_unavailable")?;
            for event in &mut events {
                event["payload"] =
                    serde_json::from_str(event["payload"].as_str().ok_or("storage_unavailable")?)
                        .map_err(|_| "storage_unavailable")?;
                if let Some(receipt) = event["receipt"].as_str() {
                    event["receipt"] =
                        serde_json::from_str(receipt).map_err(|_| "storage_unavailable")?;
                }
            }
            let mut q=tx.prepare("SELECT message,state,event,run,session,input_ref FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 ORDER BY rowid").map_err(|_|"storage_unavailable")?;
            let messages=q.query_map(params![world,scope],|r|Ok(json!({"messageID":r.get::<_,String>(0)?,"state":r.get::<_,String>(1)?,"eventID":r.get::<_,String>(2)?,"runID":r.get::<_,Option<String>>(3)?,"hostSessionID":r.get::<_,Option<String>>(4)?,"inputRef":r.get::<_,String>(5)?}))).map_err(|_|"storage_unavailable")?.collect::<std::result::Result<Vec<_>,_>>().map_err(|_|"storage_unavailable")?;
            json!({"config":config.and_then(|c|serde_json::from_str::<Value>(&c).ok()),"events":events,"humanMessages":messages})
        }
        _ => return Err("unknown_method"),
    };
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_canonical_input_is_string_and_retains_array_order() {
        let text: String = canonical_stored_input(r#"{"b":[2,1],"a":0}"#).unwrap();
        assert_eq!(text, r#"{"a":0,"b":[2,1]}"#);
        assert_eq!(
            canonical_stored_input("invalid"),
            Err("storage_unavailable")
        );
    }
    fn call(db: &mut Connection, m: &str, extra: Value) -> Result<Value> {
        let mut p = json!({"worldID":"w","residentScope":"s"});
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone();
        }
        request(db, m, &p)
    }
    fn setup() -> Connection {
        let mut db = Connection::open_in_memory().unwrap();
        schema(&db).unwrap();
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":6,"minimumWakeIntervalSeconds":1,"backgroundEnabled":true})).unwrap();
        db
    }
    fn enqueue(db: &mut Connection, id: &str, kind: &str) {
        call(db,"agent_loop_enqueue",json!({"eventID":id,"intentID":"i","kind":kind,"intentState":"active","command":{"do":"sit"}})).unwrap();
    }
    fn human(db: &mut Connection, event: &str, message: &str, input_ref: &str) -> Result<Value> {
        let mut refs = json!({});
        refs[message] = json!(input_ref);
        call(
            db,
            "agent_loop_enqueue",
            json!({"eventID":event,"intentID":"human-batch","kind":"human","intentState":"waiting_user","messageIDs":[message],"inputRefs":refs,"command":{"type":"resident_human_turn"}}),
        )
    }
    #[test]
    fn human_priority_budget_stop_wait_and_fifo() {
        let mut db = setup();
        enqueue(&mut db, "background", "background");
        human(&mut db, "first", "m1", "input1").unwrap();
        human(&mut db, "second", "m2", "input2").unwrap();
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":0,"minimumWakeIntervalSeconds":86400,"backgroundEnabled":false,"userStopped":true,"humanTurn":true})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r","hostSessionID":"h","eventID":"second"})
            )
            .unwrap()["claimed"],
            false
        );
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r","hostSessionID":"h","eventID":"first"})
            )
            .unwrap()["eventID"],
            "first"
        );
        call(&mut db,"agent_loop_complete",json!({"eventID":"first","runID":"r","hostSessionID":"h","status":"completed","receipt":{}})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r2","hostSessionID":"h","eventID":"second"})
            )
            .unwrap()["eventID"],
            "second"
        );
        let snapshot = call(&mut db, "agent_loop_read", json!({})).unwrap();
        assert_eq!(snapshot["humanMessages"][0]["state"], "completed");
        assert_eq!(snapshot["events"][0]["state"], "pending");
    }
    #[test]
    fn human_available_editing_and_cancel_still_gate() {
        let mut db = setup();
        human(&mut db, "h", "m", "input").unwrap();
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":0,"minimumWakeIntervalSeconds":1,"editing":true})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
        call(&mut db, "agent_loop_cancel", json!({"eventID":"h"})).unwrap();
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["humanMessages"][0]["state"],
            "cancelled"
        );
        assert!(human(&mut db, "replay", "m", "input").is_err());
        call(
            &mut db,
            "agent_loop_configure",
            json!({"hostSessionID":"h","hourlyLimit":0,"minimumWakeIntervalSeconds":1}),
        )
        .unwrap();
        human(&mut db, "new", "m2", "input2").unwrap();
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        recover(&db).unwrap();
        human(&mut db, "later", "m3", "input3").unwrap();
        // `recover()` names the orphaned turn `unknown` — that is an honest record,
        // not a lease. Until 2026-10-09 this last assertion read `false`, i.e. the
        // suite pinned the very rule that locked the resident out of chat: one
        // orphaned turn from the previous build made every later claim answer
        // `claimed:false` for the life of the database. The three gates above
        // (`available` / `editing` / `cancel`) still gate; `unknown` does not.
        let recovered = call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":5000,"runID":"new","hostSessionID":"h"}),
        )
        .unwrap();
        assert_eq!(recovered["claimed"], true);
        assert_eq!(recovered["eventID"], "later");
    }
    #[test]
    fn steering_admission_is_durable_unknown_input_cannot_replay() {
        let mut db = setup();
        enqueue(&mut db, "e", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        let admission = json!({"eventID":"e","runID":"r","hostSessionID":"h","messageID":"m","inputRef":"same-business-input"});
        assert_eq!(
            call(&mut db, "agent_loop_steer_admit", admission.clone()).unwrap()["admitted"],
            true
        );
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["humanMessages"][0]["state"],
            "steer_claimed"
        );
        assert_eq!(
            call(&mut db, "agent_loop_steer_admit", admission.clone()).unwrap()["admitted"],
            false
        );
        let receipt = json!({"eventID":"e","runID":"r","hostSessionID":"h","messageID":"m","delivery":"unknown","receipt":{"ack":false}});
        call(&mut db, "agent_loop_steer_finish", receipt.clone()).unwrap();
        assert_eq!(
            call(&mut db, "agent_loop_steer_finish", receipt).unwrap()["duplicate"],
            true
        );
        let mut alias = admission;
        alias["messageID"] = json!("different-id");
        assert_eq!(
            call(&mut db, "agent_loop_steer_admit", alias),
            Err("agent_loop_input_conflict")
        );
        assert!(human(&mut db, "replay", "m", "same-business-input").is_err());
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["events"][0]["payload"]["kind"],
            "background"
        );
    }
    #[test]
    fn steering_not_delivered_can_join_ordered_human_batch() {
        let mut db = setup();
        enqueue(&mut db, "e", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        call(
            &mut db,
            "agent_loop_steer_admit",
            json!({"eventID":"e","runID":"r","hostSessionID":"h","messageID":"m","inputRef":"i"}),
        )
        .unwrap();
        call(&mut db,"agent_loop_steer_finish",json!({"eventID":"e","runID":"r","hostSessionID":"h","messageID":"m","delivery":"not_delivered","receipt":{}})).unwrap();
        human(&mut db, "queued", "m", "i").unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r2","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
        call(&mut db,"agent_loop_complete",json!({"eventID":"e","runID":"r","hostSessionID":"h","status":"completed","receipt":{}})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r2","hostSessionID":"h"})
            )
            .unwrap()["eventID"],
            "queued"
        );
    }
    #[test]
    fn unordered_legacy_steering_input_rejoins_human_fifo_without_identity_bypass() {
        let mut db = setup();
        enqueue(&mut db, "parent", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        let input: Value = serde_json::from_str(
            r#"{"submissionID":"m","inputSHA256":"sha","imageReferences":["first","second"]}"#,
        )
        .unwrap();
        call(&mut db, "agent_loop_steer_admit", json!({"eventID":"parent","runID":"r","hostSessionID":"h","messageID":"m","inputRef":input})).unwrap();
        // Actual legacy encoding, not an already canonical fixture.
        let legacy =
            r#"{"submissionID":"m","inputSHA256":"sha","imageReferences":["first","second"]}"#;
        db.execute(
            "UPDATE agent_loop_human_messages SET input_ref=?1 WHERE message='m'",
            params![legacy],
        )
        .unwrap();
        let reordered: Value = serde_json::from_str(
            r#"{"imageReferences":["first","second"],"inputSHA256":"sha","submissionID":"m"}"#,
        )
        .unwrap();
        let replay = call(&mut db, "agent_loop_steer_admit", json!({"eventID":"parent","runID":"r","hostSessionID":"h","messageID":"m","inputRef":reordered})).unwrap();
        assert_eq!(replay["admitted"], false);
        assert_eq!(
            call(
                &mut db,
                "agent_loop_steer_admit",
                json!({"eventID":"parent","runID":"r","hostSessionID":"h","messageID":"other","inputRef":reordered})
            ),
            Err("agent_loop_input_conflict")
        );
        call(&mut db, "agent_loop_steer_finish", json!({"eventID":"parent","runID":"r","hostSessionID":"h","messageID":"m","delivery":"not_delivered","receipt":{}})).unwrap();
        let batch = |input: Value| json!({"eventID":"queued","intentID":"human-batch","kind":"human","intentState":"waiting_user","messageIDs":["m"],"inputRefs":{"m":input},"command":{"type":"resident_human_turn"}});
        let mut changed = reordered.clone();
        changed["inputSHA256"] = json!("changed");
        assert_eq!(
            call(&mut db, "agent_loop_enqueue", batch(changed)),
            Err("agent_loop_message_conflict")
        );
        let mut changed = reordered.clone();
        changed["imageReferences"] = json!(["second", "first"]);
        assert_eq!(
            call(&mut db, "agent_loop_enqueue", batch(changed)),
            Err("agent_loop_message_conflict")
        );
        assert_eq!(
            call(
                &mut db,
                "agent_loop_enqueue",
                json!({"eventID":"duplicate","intentID":"human-batch","kind":"human","intentState":"waiting_user","messageIDs":["other"],"inputRefs":{"other":reordered},"command":{"type":"resident_human_turn"}})
            ),
            Err("agent_loop_input_conflict")
        );
        call(&mut db, "agent_loop_enqueue", batch(reordered)).unwrap();
        call(&mut db, "agent_loop_complete", json!({"eventID":"parent","runID":"r","hostSessionID":"h","status":"completed","receipt":{}})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r2","hostSessionID":"h"})
            )
            .unwrap()["eventID"],
            "queued"
        );
    }

    #[test]
    fn confirmed_unstarted_reservation_releases_budget_and_rust_retries_after_config_change() {
        let mut db = setup();
        let configure = |limit| json!({"hostSessionID":"h","hourlyLimit":limit,"minimumWakeIntervalSeconds":1,"backgroundEnabled":true});
        call(&mut db, "agent_loop_configure", configure(1)).unwrap();
        let opportunity = json!({"eventID":"e","intentID":"i","kind":"background","intentState":"active","command":{"do":"sit"}});
        call(&mut db, "agent_loop_enqueue", opportunity.clone()).unwrap();
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        let terminal = json!({"eventID":"e","runID":"r","hostSessionID":"h","receipt":{"kind":"resident_model_turn","executionNotStarted":true,"invocationStarted":false}});
        call(&mut db, "agent_loop_confirm_cancel", terminal.clone()).unwrap();
        assert_eq!(
            call(&mut db, "agent_loop_confirm_cancel", terminal).unwrap()["duplicate"],
            true
        );
        // Match the real host ordering: native budget drops before invocation,
        // but its cancellation is confirmed while Rust still has limit=1.
        call(&mut db, "agent_loop_configure", configure(0)).unwrap();
        let zero = call(&mut db, "agent_loop_enqueue", opportunity.clone()).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"eventID":zero["eventID"],"nowMillis":1000,"runID":"r0","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
        call(&mut db, "agent_loop_configure", configure(1)).unwrap();
        let retry = call(&mut db, "agent_loop_enqueue", opportunity.clone()).unwrap();
        assert_ne!(retry["eventID"], "e");
        assert_ne!(retry["eventID"], zero["eventID"]);
        call(
            &mut db,
            "agent_loop_cancel",
            json!({"eventID":zero["eventID"]}),
        )
        .unwrap();
        assert_eq!(
            {
                let before: i64 = db
                    .query_row("SELECT COUNT(*) FROM agent_loop_events", [], |r| r.get(0))
                    .unwrap();
                let replay = call(&mut db, "agent_loop_enqueue", opportunity).unwrap();
                let after: i64 = db
                    .query_row("SELECT COUNT(*) FROM agent_loop_events", [], |r| r.get(0))
                    .unwrap();
                assert_eq!(before, after);
                replay["eventID"].clone()
            },
            retry["eventID"]
        );
        assert_eq!(call(&mut db,"agent_loop_claim",json!({"eventID":retry["eventID"],"nowMillis":1000,"runID":"r2","hostSessionID":"h"})).unwrap()["claimed"],true);
        let preserved: (String, String, i64) = db
            .query_row(
                "SELECT state,run,claimed_at FROM agent_loop_events WHERE event='e'",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(preserved, ("cancelled".into(), "r".into(), 1000));
    }

    #[test]
    fn started_cancelled_reservation_still_charges_hourly_budget() {
        let mut db = setup();
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":1,"minimumWakeIntervalSeconds":1,"backgroundEnabled":true})).unwrap();
        enqueue(&mut db, "e", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        call(&mut db,"agent_loop_confirm_cancel",json!({"eventID":"e","runID":"r","hostSessionID":"h","receipt":{"kind":"resident_model_turn","executionNotStarted":false,"invocationStarted":true}})).unwrap();
        enqueue(&mut db, "later", "background");
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":3000,"runID":"r2","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
    }

    #[test]
    fn unknown_reservation_cannot_be_released_with_unstarted_claim() {
        let mut db = setup();
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":1,"minimumWakeIntervalSeconds":1,"backgroundEnabled":true})).unwrap();
        enqueue(&mut db, "e", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        recover(&db).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_reconcile",
                json!({"eventID":"e","runID":"r","hostSessionID":"h","originalHostSessionID":"h","outcome":"cancelled","receipt":{"kind":"resident_model_turn","executionNotStarted":true,"invocationStarted":false}})
            ),
            Err("agent_loop_invalid_receipt")
        );
        call(&mut db,"agent_loop_reconcile",json!({"eventID":"e","runID":"r","hostSessionID":"h","originalHostSessionID":"h","outcome":"cancelled","receipt":{"verified":true}})).unwrap();
        enqueue(&mut db, "later", "background");
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":3000,"runID":"r2","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
    }

    #[test]
    fn durable_claim_and_idempotent_receipt() {
        let mut db = setup();
        enqueue(&mut db, "e", "background");
        assert!(call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"})
        )
        .unwrap()["claimed"]
            .as_bool()
            .unwrap());
        let receipt = json!({"eventID":"e","runID":"r","hostSessionID":"h","status":"completed","receipt":{"ok":true}});
        assert_eq!(
            call(&mut db, "agent_loop_complete", receipt.clone()).unwrap()["duplicate"],
            false
        );
        assert_eq!(
            call(&mut db, "agent_loop_complete", receipt).unwrap()["duplicate"],
            true
        );
        assert!(call(&mut db,"agent_loop_complete",json!({"eventID":"e","runID":"r","hostSessionID":"h","status":"completed","receipt":{"ok":false}})).is_err());
    }
    #[test]
    fn crash_never_replays() {
        let mut db = setup();
        enqueue(&mut db, "e", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        recover(&db).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":3000,"runID":"r2","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["events"][0]["state"],
            "unknown"
        );
    }
    #[test]
    fn continuation_respects_stop_and_budget() {
        let mut db = setup();
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":1,"minimumWakeIntervalSeconds":1,"backgroundEnabled":false})).unwrap();
        enqueue(&mut db, "a", "background");
        enqueue(&mut db, "b", "continuation");
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"})
            )
            .unwrap()["eventID"],
            "b"
        );
        enqueue(&mut db, "c", "continuation");
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":3000,"runID":"r2","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":6,"minimumWakeIntervalSeconds":1,"userStopped":true})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":4000000,"runID":"r3","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
    }
    #[test]
    fn stale_session_rejected() {
        let mut db = setup();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":1000,"runID":"r","hostSessionID":"old"})
            ),
            Err("agent_loop_stale_session")
        );
    }
    #[test]
    fn waiting_user_continuation_and_expired_opportunity() {
        let mut db = setup();
        call(&mut db,"agent_loop_enqueue",json!({"eventID":"old","intentID":"i","kind":"background","intentState":"waiting_event","wakeAtMillis":100,"opportunityDeadlineMillis":200,"command":{}})).unwrap();
        call(&mut db,"agent_loop_enqueue",json!({"eventID":"reply","intentID":"i","kind":"continuation","intentState":"waiting_user","command":{}})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":300,"runID":"r","hostSessionID":"h"})
            )
            .unwrap()["eventID"],
            "reply"
        );
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["events"][0]["state"],
            "cancelled"
        );
    }
    #[test]
    fn concurrent_run_and_changed_host_do_not_replay() {
        let mut db = setup();
        enqueue(&mut db, "a", "background");
        enqueue(&mut db, "b", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":3000,"runID":"other","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"new","hourlyLimit":6,"minimumWakeIntervalSeconds":1,"backgroundEnabled":true})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_complete",
                json!({"eventID":"a","runID":"r","hostSessionID":"h","status":"completed","receipt":{}})
            ),
            Err("agent_loop_stale_session")
        );
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["events"][0]["state"],
            "unknown"
        );
        // 旧回合的 `unknown` 不是租约（见 `agent_loop_claim`）：换了宿主之后可以继续，
        // 但领到的是**下一个**待办事件，绝不是那个未确认的 `a` —— 这才是本用例要的
        // "do not replay"。直到 2026-10-09 这里写的是 `claimed: false`，即把
        // "永不复用旧回合"错写成了"整个 world+scope 永久停摆"。
        let after_host_change = call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":3000,"runID":"fresh","hostSessionID":"new"}),
        )
        .unwrap();
        assert_eq!(after_host_change["claimed"], true);
        assert_eq!(after_host_change["eventID"], "b");
        let verified = json!({"eventID":"a","runID":"r","hostSessionID":"new","originalHostSessionID":"h","outcome":"completed","receipt":{"verified":true}});
        assert_eq!(
            call(&mut db, "agent_loop_reconcile", verified.clone()).unwrap()["duplicate"],
            false
        );
        assert_eq!(
            call(&mut db, "agent_loop_reconcile", verified).unwrap()["duplicate"],
            true
        );
        // 对账之后 `a` 是终态，永远不会再被当成待办领走；也没有别的待办留下。
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["events"][0]["state"],
            "completed"
        );
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":6000,"runID":"after-reconcile","hostSessionID":"new"})
            )
            .unwrap()["claimed"],
            false
        );
    }
    #[test]
    fn cancel_requires_actual_ack_and_accepts_late_completion() {
        let mut db = setup();
        enqueue(&mut db, "a", "background");
        enqueue(&mut db, "b", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        assert_eq!(
            call(&mut db, "agent_loop_cancel", json!({"eventID":"a"})).unwrap()["state"],
            "cancel_requested"
        );
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":3000,"runID":"next","hostSessionID":"h"})
            )
            .unwrap()["claimed"],
            false
        );
        assert!(call(
            &mut db,
            "agent_loop_confirm_cancel",
            json!({"eventID":"a","runID":"wrong","hostSessionID":"h","receipt":{}})
        )
        .is_err());
        call(&mut db,"agent_loop_complete",json!({"eventID":"a","runID":"r","hostSessionID":"h","status":"completed","receipt":{"actual":true}})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":3000,"runID":"next","hostSessionID":"h"})
            )
            .unwrap()["eventID"],
            "b"
        );
        call(&mut db, "agent_loop_cancel", json!({"eventID":"b"})).unwrap();
        let ack =
            json!({"eventID":"b","runID":"next","hostSessionID":"h","receipt":{"stopped":true}});
        assert_eq!(
            call(&mut db, "agent_loop_confirm_cancel", ack.clone()).unwrap()["duplicate"],
            false
        );
        assert_eq!(
            call(&mut db, "agent_loop_confirm_cancel", ack).unwrap()["duplicate"],
            true
        );
    }
    #[test]
    fn unknown_cancel_does_not_settle_the_record() {
        let mut db = setup();
        enqueue(&mut db, "a", "background");
        enqueue(&mut db, "b", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        recover(&db).unwrap();
        let cancel = call(&mut db, "agent_loop_cancel", json!({"eventID":"a"})).unwrap();
        assert_eq!(cancel["cancelled"], false);
        assert_eq!(cancel["requiresVerification"], true);
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["events"][0]["state"],
            "unknown"
        );
        // Cancelling an unconfirmed execution must not settle it: the record stays
        // `unknown` for the host's own reconciliation, and `agent_loop_confirm_cancel`
        // cannot launder it (asserted below). It must not, however, hold the whole
        // scope hostage — `unknown` is not a lease, so the next turn is claimable.
        // Until 2026-10-09 the assertion here read `false`, which is the permanent
        // lock the real device hit.
        let next = call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":5000,"runID":"next","hostSessionID":"h"}),
        )
        .unwrap();
        assert_eq!(next["claimed"], true);
        assert_eq!(next["eventID"], "b");
        assert!(call(
            &mut db,
            "agent_loop_confirm_cancel",
            json!({"eventID":"a","runID":"r","hostSessionID":"h","receipt":{}})
        )
        .is_err());
    }
    /// 真机 2026-10-09 18:58 的形状，逐字复现：build 229 的 daemon 启动时
    /// `recover()` 把上一版遗留的 `claimed` 回合命名成 `unknown`（诚实记录：我们
    /// 没学到效果），接着用户发一条消息。`unknown` 不是租约 —— 调度器必须还能把
    /// 这条人类消息领起来。否则人类消息行永远停在 `queued`、事件永远停在
    /// `pending`，而界面上既没有回复也没有报错（宿主在 `guard let ticket else
    /// { return }` 处静默），于是「装了 229 之后聊天还是发不出去」。
    #[test]
    fn a_recovered_unconfirmed_turn_does_not_starve_the_next_human_message() {
        let mut db = setup();
        human(&mut db, "first", "m1", "input1").unwrap();
        let claimed = call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r1","hostSessionID":"h","eventID":"first"}),
        )
        .unwrap();
        assert_eq!(claimed["claimed"], true);
        // 宿主没有结算这一轮：build 228 的应用在中途退出，daemon 重启时把它命名。
        recover(&db).unwrap();
        assert_eq!(
            call(&mut db, "agent_loop_read", json!({})).unwrap()["events"][0]["state"],
            "unknown"
        );
        human(&mut db, "second", "m2", "input2").unwrap();
        let next = call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":5000,"runID":"r2","hostSessionID":"h","eventID":"second"}),
        )
        .unwrap();
        assert_eq!(next["claimed"], true);
        assert_eq!(next["eventID"], "second");
        let read = call(&mut db, "agent_loop_read", json!({})).unwrap();
        let message = read["humanMessages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|m| m["messageID"] == "m2")
            .unwrap();
        assert_eq!(message["state"], "claimed");
        // 诚实记录仍在：旧回合没有被猜成 completed/failed，也没有被改写。
        assert_eq!(
            read["events"]
                .as_array()
                .unwrap()
                .iter()
                .find(|e| e["eventID"] == "first")
                .unwrap()["state"],
            "unknown"
        );
    }
    #[test]
    fn separate_connections_cancel_and_claim_never_overlap() {
        let path = std::env::temp_dir().join(format!(
            "gmgn-scheduler-{}-{}.sqlite3",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let mut db = Connection::open(&path).unwrap();
        schema(&db).unwrap();
        call(&mut db,"agent_loop_configure",json!({"hostSessionID":"h","hourlyLimit":6,"minimumWakeIntervalSeconds":1,"backgroundEnabled":true})).unwrap();
        enqueue(&mut db, "a", "background");
        enqueue(&mut db, "b", "background");
        call(
            &mut db,
            "agent_loop_claim",
            json!({"nowMillis":1000,"runID":"r","hostSessionID":"h"}),
        )
        .unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let mut handles = vec![];
        for cancel in [true, false] {
            let path = path.clone();
            let barrier = barrier.clone();
            handles.push(std::thread::spawn(move || {
                let mut db = Connection::open(path).unwrap();
                db.busy_timeout(std::time::Duration::from_secs(5)).unwrap();
                barrier.wait();
                if cancel {
                    call(&mut db, "agent_loop_cancel", json!({"eventID":"a"})).unwrap()
                } else {
                    call(
                        &mut db,
                        "agent_loop_claim",
                        json!({"nowMillis":5000,"runID":"next","hostSessionID":"h"}),
                    )
                    .unwrap()
                }
            }));
        }
        let cancel = handles.remove(0).join().unwrap();
        let claim = handles.remove(0).join().unwrap();
        assert_eq!(cancel["cancelled"], false);
        assert_eq!(claim["claimed"], false);
        call(&mut db,"agent_loop_complete",json!({"eventID":"a","runID":"r","hostSessionID":"h","status":"completed","receipt":{"actual":true}})).unwrap();
        assert_eq!(
            call(
                &mut db,
                "agent_loop_claim",
                json!({"nowMillis":5000,"runID":"next","hostSessionID":"h"})
            )
            .unwrap()["eventID"],
            "b"
        );
        drop(db);
        std::fs::remove_file(path).unwrap();
    }
}
