//! Queue/navigation authority. Device output is a host receipt, never an inferred success.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};

pub fn program_schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS music_program_playback(queue_id TEXT PRIMARY KEY,payload TEXT NOT NULL);")
        .map_err(|_|"storage_unavailable")
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ProgramInput {
    #[serde(rename = "queueID")]
    queue_id: String,
    #[serde(rename = "hostSessionID")]
    host_session_id: String,
    op: String,
    #[serde(default)]
    generation: u64,
    #[serde(rename = "programID")]
    program_id: Option<String>,
    program_revision: Option<u64>,
    starting_index: Option<i64>,
    locked_capacity: Option<usize>,
    #[serde(rename = "trackID")]
    track_id: Option<String>,
    resource_handle: Option<String>,
    accepted: Option<bool>,
    #[serde(rename = "ticketID")]
    ticket_id: Option<String>,
}
fn program_slots(c: &Connection, id: Option<&str>, revision: Option<u64>) -> Result<Vec<Value>> {
    let id = id.ok_or("music_playback_invalid_input")?;
    let revision = revision.ok_or("music_playback_invalid_input")?;
    let matches = |plan: &Value| {
        plan["brief"]["id"].as_str() == Some(id) && plan["revision"].as_u64() == Some(revision)
    };
    let decode = |raw: String| {
        serde_json::from_str::<Value>(&raw).map_err(|_| "music_playback_invalid_state")
    };
    // Published state may retain an older revision after a same-ID draft replaces
    // the archive row and the latest prepared-owned revision.
    let raw: Option<String> = c
        .query_row(
            "SELECT payload FROM music_dj_state WHERE singleton=1",
            [],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some(raw) = raw {
        let state = decode(raw)?;
        for key in ["plan", "pendingPlan"] {
            if matches(&state[key]) {
                return state[key]["slots"]
                    .as_array()
                    .cloned()
                    .ok_or("music_playback_invalid_state");
            }
        }
    }
    let raw: Option<String> = c
        .query_row(
            "SELECT payload FROM music_programs WHERE id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some(raw) = raw {
        let saved = decode(raw)?;
        if matches(&saved["plan"]) {
            return saved["plan"]["slots"]
                .as_array()
                .cloned()
                .ok_or("music_playback_invalid_state");
        }
    }
    let plan = crate::music_program::owned(c, id)?;
    if !matches(&plan) {
        return Err("music_playback_program_revision_mismatch");
    }
    plan["slots"]
        .as_array()
        .cloned()
        .ok_or("music_playback_invalid_state")
}
fn prepared_values(state: &Value) -> Vec<Value> {
    let mut values = Vec::new();
    if !state["current"].is_null() {
        values.push(state["current"].clone());
    }
    for key in ["locked", "history"] {
        values.extend(state[key].as_array().unwrap().iter().cloned());
    }
    values
}
fn selected_state(state: &mut Value, slots: Vec<Value>, index: usize, selected: Value) {
    let cache = prepared_values(state);
    let remaining = &slots[index + 1..];
    let capacity = state["lockedCapacity"].as_u64().unwrap() as usize;
    let locked: Vec<_> = remaining
        .iter()
        .filter_map(|slot| {
            cache
                .iter()
                .rev()
                .find(|v| v["slot"]["track"]["id"] == slot["track"]["id"])
                .cloned()
        })
        .take(capacity)
        .collect();
    let reserve: Vec<_> = remaining
        .iter()
        .filter(|slot| {
            !locked
                .iter()
                .any(|v| v["slot"]["track"]["id"] == slot["track"]["id"])
        })
        .cloned()
        .collect();
    state["current"] = selected;
    state["locked"] = json!(locked);
    state["reserve"] = json!(reserve);
    state["history"] = json!([]);
    state["failedTrackIDs"] = json!([]);
}
fn program_next(state: &mut Value) {
    if !state["pending"].is_null() {
        return;
    }
    let needed = state["current"].is_null()
        || state["locked"].as_array().unwrap().len()
            < state["lockedCapacity"].as_u64().unwrap() as usize;
    if needed && !state["reserve"].as_array().unwrap().is_empty() {
        let slot = state["reserve"].as_array_mut().unwrap().remove(0);
        state["pending"] = json!({"ticketID":uuid::Uuid::new_v4().to_string(),"generation":state["generation"],"slot":slot,"kind":"fill"});
    }
}

/// Typed raw events for native preflight. Only owned program IDs select slots;
/// receipts carry opaque in-process handles, never arbitrary resource paths.
pub fn program_request(c: &mut Connection, params: Value) -> Result<Value> {
    let input: ProgramInput =
        serde_json::from_value(params).map_err(|_| "music_playback_invalid_input")?;
    if input.queue_id.is_empty()
        || input.queue_id.len() > 200
        || input.host_session_id.is_empty()
        || input.host_session_id.len() > 200
    {
        return Err("music_playback_invalid_input");
    }
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let raw: Option<String> = tx
        .query_row(
            "SELECT payload FROM music_program_playback WHERE queue_id=?1",
            [&input.queue_id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let mut state = if let Some(raw) = raw {
        serde_json::from_str::<Value>(&raw).map_err(|_| "music_playback_invalid_state")?
    } else {
        json!({"generation":0,"hostSessionID":input.host_session_id,"lockedCapacity":2,"current":null,"locked":[],"reserve":[],"failedTrackIDs":[],"history":[],"pending":null})
    };
    if state["hostSessionID"] != input.host_session_id
        || state["generation"].as_u64() != Some(input.generation)
    {
        return Err("music_playback_stale_session");
    }
    let op = input.op.as_str();
    let mut selected = Value::Null;
    if op != "read" && op != "prepare_receipt" && !state["pending"].is_null() {
        return Err("music_playback_selection_pending");
    }
    match op {
        "read" => {}
        "load" => {
            let slots = program_slots(&tx, input.program_id.as_deref(), input.program_revision)?;
            let index = input
                .starting_index
                .unwrap_or(0)
                .max(0)
                .min(slots.len().saturating_sub(1) as i64) as usize;
            let generation = input
                .generation
                .checked_add(1)
                .ok_or("music_playback_revision_overflow")?;
            state = json!({"generation":generation,"hostSessionID":input.host_session_id,"lockedCapacity":input.locked_capacity.unwrap_or(2),"current":null,"locked":[],"reserve":slots[index..],"failedTrackIDs":[],"history":[],"pending":null});
            program_next(&mut state);
        }
        "select" => {
            let slots = program_slots(&tx, input.program_id.as_deref(), input.program_revision)?;
            if slots.is_empty() {
                return Err("music_playback_empty");
            }
            let index = input
                .starting_index
                .unwrap_or(0)
                .max(0)
                .min(slots.len() as i64 - 1) as usize;
            let cache = prepared_values(&state);
            if let Some(selected) = cache
                .iter()
                .rev()
                .find(|v| v["slot"]["track"]["id"] == slots[index]["track"]["id"])
            {
                selected_state(&mut state, slots, index, selected.clone());
            } else {
                state["pending"] = json!({"ticketID":uuid::Uuid::new_v4().to_string(),"generation":state["generation"],"slot":slots[index],"kind":"select","slots":slots,"index":index});
            }
        }
        "replace_upcoming" => {
            let slots = program_slots(&tx, input.program_id.as_deref(), input.program_revision)?;
            let index = input
                .starting_index
                .unwrap_or(0)
                .max(0)
                .min(slots.len() as i64) as usize;
            state["locked"] = json!([]);
            state["reserve"] = json!(slots[index..]);
            state["failedTrackIDs"] = json!([]);
            program_next(&mut state);
        }
        "advance" | "current_failed" => {
            let current = state["current"].clone();
            if !current.is_null() {
                if op == "advance" {
                    state["history"].as_array_mut().unwrap().push(current);
                } else {
                    state["failedTrackIDs"]
                        .as_array_mut()
                        .unwrap()
                        .push(current["slot"]["track"]["id"].clone());
                }
            }
            let locked = state["locked"].as_array_mut().unwrap();
            let next = if locked.is_empty() {
                Value::Null
            } else {
                locked.remove(0)
            };
            state["current"] = next;
            program_next(&mut state);
        }
        "previous" => {
            if let Some(previous) = state["history"].as_array_mut().unwrap().pop() {
                selected = previous.clone();
                let current = state["current"].clone();
                if !current.is_null() {
                    state["locked"].as_array_mut().unwrap().insert(0, current);
                }
                state["current"] = previous;
            }
        }
        "prepare_receipt" => {
            let ticket = state["pending"].clone();
            if ticket.is_null()
                || ticket["ticketID"].as_str() != input.ticket_id.as_deref()
                || ticket["slot"]["track"]["id"].as_str() != input.track_id.as_deref()
            {
                return Err("music_playback_stale_selection");
            }
            let accepted = input.accepted.ok_or("music_playback_invalid_input")?;
            if accepted {
                let handle = input
                    .resource_handle
                    .as_deref()
                    .filter(|s| uuid::Uuid::parse_str(s).is_ok())
                    .ok_or("music_playback_invalid_input")?;
                let prepared = json!({"slot":ticket["slot"],"resourceHandle":handle});
                if ticket["kind"] == "select" {
                    selected_state(
                        &mut state,
                        ticket["slots"].as_array().unwrap().clone(),
                        ticket["index"].as_u64().unwrap() as usize,
                        prepared,
                    );
                } else if state["current"].is_null() {
                    state["current"] = prepared;
                } else {
                    state["locked"].as_array_mut().unwrap().push(prepared);
                }
            } else if ticket["kind"] == "fill" {
                state["failedTrackIDs"]
                    .as_array_mut()
                    .unwrap()
                    .push(ticket["slot"]["track"]["id"].clone());
            }
            state["pending"] = Value::Null;
            if ticket["kind"] == "fill" {
                program_next(&mut state);
            }
        }
        _ => return Err("music_playback_invalid_input"),
    }
    let output = json!({"state":state,"ticket":state["pending"],"selected":selected});
    tx.execute("INSERT INTO music_program_playback VALUES(?1,?2) ON CONFLICT(queue_id) DO UPDATE SET payload=excluded.payload",params![input.queue_id,crate::canonical_json::to_string(&state).map_err(|_|"music_playback_invalid_state")?]).map_err(|_|"storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(output)
}

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS music_playback_sessions(player_id TEXT PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS music_playback_commands(player_id TEXT NOT NULL, method TEXT NOT NULL, request_id TEXT NOT NULL,
            input TEXT NOT NULL, output TEXT NOT NULL, PRIMARY KEY(player_id,method,request_id));")
        .map_err(|_| "storage_unavailable")
}
fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 4096)
        .ok_or("music_playback_invalid_input")
}
fn load(c: &Connection, player: &str) -> Result<Value> {
    let raw: Option<String> = c
        .query_row(
            "SELECT payload FROM music_playback_sessions WHERE player_id=?1",
            [player],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    match raw {
        Some(raw) => serde_json::from_str(&raw).map_err(|_| "music_playback_invalid_state"),
        None => Ok(
            json!({"playerID":player,"generation":0,"sessionID":"","hostSessionID":"",
            "mode":"local","queue":[],"index":0,"status":"empty","pending":null}),
        ),
    }
}
fn save(c: &Connection, player: &str, state: &Value) -> Result<()> {
    c.execute("INSERT INTO music_playback_sessions(player_id,payload) VALUES(?1,?2) ON CONFLICT(player_id) DO UPDATE SET payload=excluded.payload",
        params![player,crate::canonical_json::to_string(state).map_err(|_|"music_playback_invalid_input")?]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn current<'a>(state: &'a Value, input: &Value) -> Result<&'a str> {
    if string(input, "sessionID")? != state["sessionID"]
        || string(input, "hostSessionID")? != state["hostSessionID"]
    {
        return Err("music_playback_stale_session");
    }
    state["queue"]
        .as_array()
        .and_then(|q| q.get(state["index"].as_u64()? as usize))
        .and_then(|v| v["id"].as_str())
        .ok_or("music_playback_empty")
}
fn queue(v: &Value) -> Result<&Vec<Value>> {
    let items = v
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 10_000)
        .ok_or("music_playback_invalid_queue")?;
    if v.to_string().len() > 8 * 1024 * 1024 {
        return Err("music_playback_invalid_queue");
    }
    for item in items {
        string(item, "id")?;
        if item.get("payload").is_none() {
            return Err("music_playback_invalid_queue");
        }
    }
    Ok(items)
}
fn begin(
    state: &mut Value,
    input: &Value,
    items: Value,
    index: usize,
    mode: &str,
) -> Result<Value> {
    let host = string(input, "hostSessionID")?;
    let request = string(input, "requestID")?;
    let items_array = queue(&items)?;
    let track = items_array
        .get(index)
        .ok_or("music_playback_track_not_found")?["id"]
        .clone();
    if let Some(pending) = state.get("pending").filter(|v| v.is_object()) {
        if pending["requestID"] == request && pending["hostSessionID"] == host {
            if pending["queue"] != items || pending["index"] != index || pending["mode"] != mode {
                return Err("music_playback_request_conflict");
            }
            return Ok(json!({"state":state,"ticket":pending}));
        }
    }
    let generation = state["generation"]
        .as_u64()
        .and_then(|g| g.checked_add(1))
        .filter(|g| *g <= i64::MAX as u64)
        .ok_or("music_playback_revision_overflow")?;
    let ticket = json!({"generation":generation,"requestID":request,"hostSessionID":host,
        "queue":items,"index":index,"mode":mode,"trackID":track});
    state["generation"] = json!(generation);
    state["pending"] = ticket.clone();
    Ok(json!({"state":state,"ticket":ticket}))
}

pub fn request(c: &mut Connection, method: &str, input: Value) -> Result<Value> {
    let player = string(&input, "playerID")?;
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let mut state = load(&tx, player)?;
    let idempotent = [
        "music_playback_begin",
        "music_playback_navigate",
        "music_playback_commit",
    ]
    .contains(&method);
    let fingerprint =
        crate::canonical_json::to_string(&input).map_err(|_| "music_playback_invalid_input")?;
    if idempotent {
        let request_id = string(&input, "requestID")?;
        let saved: Option<(String,String)> = tx.query_row(
            "SELECT input,output FROM music_playback_commands WHERE player_id=?1 AND method=?2 AND request_id=?3",
            params![player,method,request_id], |r| Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
        if let Some((old_input, output)) = saved {
            if old_input != fingerprint {
                return Err("music_playback_request_conflict");
            }
            let mut reply: Value =
                serde_json::from_str(&output).map_err(|_| "music_playback_invalid_state")?;
            // A retry may return its original ticket, but never rolls the host projection backwards.
            reply["state"] = state;
            reply["replayed"] = json!(true);
            tx.commit().map_err(|_| "storage_unavailable")?;
            return Ok(reply);
        }
    }
    let output = match method {
        "music_playback_read" => json!({"state":state}),
        "music_playback_begin" => {
            let mode = string(&input, "mode")?;
            if mode != "local" && mode != "library" {
                return Err("music_playback_invalid_input");
            }
            let index = input["index"]
                .as_u64()
                .ok_or("music_playback_invalid_input")? as usize;
            begin(&mut state, &input, input["queue"].clone(), index, mode)?
        }
        "music_playback_navigate" => {
            current(&state, &input)?;
            let items = queue(&state["queue"])?;
            let index = if let Some(delta) = input.get("delta") {
                let delta = delta
                    .as_i64()
                    .filter(|d| *d == 1 || *d == -1)
                    .ok_or("music_playback_invalid_input")?;
                let index = state["index"]
                    .as_i64()
                    .ok_or("music_playback_invalid_state")?
                    + delta;
                if index < 0 {
                    return Err("music_playback_track_not_found");
                }
                index as usize
            } else if let Some(slot) = input.get("slotIndex").filter(|v| !v.is_null()) {
                let index = slot.as_u64().ok_or("music_playback_invalid_input")? as usize;
                let item = items.get(index).ok_or("music_playback_track_not_found")?;
                if let Some(track) = input.get("trackID").filter(|v| !v.is_null()) {
                    if item["id"] != *track {
                        return Err("music_playback_track_not_found");
                    }
                }
                index
            } else {
                let track = string(&input, "trackID")?;
                let matches: Vec<_> = items
                    .iter()
                    .enumerate()
                    .filter(|(_, v)| v["id"] == track)
                    .map(|(i, _)| i)
                    .collect();
                if matches.len() != 1 {
                    return Err("music_playback_ambiguous_track");
                }
                matches[0]
            };
            let items = state["queue"].clone();
            let mode = state["mode"]
                .as_str()
                .ok_or("music_playback_invalid_state")?
                .to_owned();
            begin(&mut state, &input, items, index, &mode)?
        }
        "music_playback_commit" => {
            let pending = state["pending"].clone();
            if !pending.is_object()
                || input["generation"] != pending["generation"]
                || input["requestID"] != pending["requestID"]
                || input["hostSessionID"] != pending["hostSessionID"]
                || input["trackID"] != pending["trackID"]
            {
                return Err("music_playback_stale_selection");
            }
            let accepted = input["accepted"]
                .as_bool()
                .ok_or("music_playback_invalid_input")?;
            if accepted {
                for key in ["queue", "index", "mode", "hostSessionID"] {
                    state[key] = pending[key].clone();
                }
                state["sessionID"] = pending["requestID"].clone();
                state["status"] = json!("loaded");
            }
            state["pending"] = Value::Null;
            json!({"state":state,"accepted":accepted})
        }
        "music_playback_receipt" => {
            let track = current(&state, &input)?;
            if string(&input, "trackID")? != track {
                return Err("music_playback_stale_track");
            }
            let status = string(&input, "status")?;
            if !["playing", "paused", "stopped", "completed", "failed"].contains(&status) {
                return Err("music_playback_invalid_input");
            }
            state["status"] = json!(status);
            json!({"state":state,"accepted":true})
        }
        "music_playback_replace_upcoming" => {
            let track = current(&state, &input)?.to_owned();
            let items = queue(&input["queue"])?;
            let index = state["index"]
                .as_u64()
                .ok_or("music_playback_invalid_state")? as usize;
            let selected = items.get(index).ok_or("music_playback_track_not_found")?;
            if selected["id"] != track || selected != &state["queue"][index] {
                return Err("music_playback_stale_track");
            }
            if state["pending"].is_object() {
                return Err("music_playback_selection_pending");
            }
            state["queue"] = input["queue"].clone();
            json!({"state":state})
        }
        "music_playback_clear" => {
            current(&state, &input)?;
            state["queue"] = json!([]);
            state["index"] = json!(0);
            state["pending"] = Value::Null;
            state["status"] = json!("empty");
            state["sessionID"] = json!("");
            json!({"state":state})
        }
        _ => return Err("unknown_method"),
    };
    if method != "music_playback_read" {
        save(&tx, player, &state)?;
    }
    if idempotent {
        tx.execute("INSERT INTO music_playback_commands(player_id,method,request_id,input,output) VALUES(?1,?2,?3,?4,?5)",
            params![player,method,string(&input,"requestID")?,fingerprint,
                crate::canonical_json::to_string(&output).map_err(|_|"music_playback_invalid_input")?])
            .map_err(|_|"storage_unavailable")?;
    }
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn program_db(ids: &[&str]) -> Connection {
        let c = Connection::open_in_memory().unwrap();
        program_schema(&c).unwrap();
        c.execute_batch(
            "CREATE TABLE music_dj_owned(id TEXT PRIMARY KEY,payload TEXT NOT NULL);
            CREATE TABLE music_dj_state(singleton INTEGER PRIMARY KEY,payload TEXT NOT NULL);
            CREATE TABLE music_programs(id TEXT PRIMARY KEY,payload TEXT NOT NULL);",
        )
        .unwrap();
        let slots: Vec<_> = ids.iter().map(|id| json!({"track":{"id":id}})).collect();
        c.execute(
            "INSERT INTO music_dj_owned VALUES('p',?1)",
            [json!({"brief":{"id":"p"},"revision":1,"slots":slots}).to_string()],
        )
        .unwrap();
        c
    }
    fn event(c: &mut Connection, generation: u64, op: &str, mut p: Value) -> Value {
        p["queueID"] = json!("queue");
        p["hostSessionID"] = json!("host");
        p["generation"] = json!(generation);
        p["op"] = json!(op);
        if ["load", "select", "replace_upcoming"].contains(&op)
            && p.get("programRevision").is_none()
        {
            p["programRevision"] = json!(1);
        }
        program_request(c, p).unwrap()
    }
    fn drain(c: &mut Connection, mut reply: Value, fail: &[&str]) -> Value {
        while !reply["ticket"].is_null() {
            let t = reply["ticket"].clone();
            let id = t["slot"]["track"]["id"].as_str().unwrap();
            reply = event(
                c,
                reply["state"]["generation"].as_u64().unwrap(),
                "prepare_receipt",
                json!({"ticketID":t["ticketID"],"trackID":id,"accepted":!fail.contains(&id),"resourceHandle":uuid::Uuid::new_v4().to_string()}),
            );
        }
        reply
    }
    fn prepared_ids(v: &Value, key: &str) -> Vec<String> {
        v["state"][key]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v["slot"]["track"]["id"].as_str().unwrap().to_owned())
            .collect()
    }
    #[test]
    fn program_preflight_skip_advance_failure_and_previous_preserve_window() {
        let mut c = program_db(&["1", "2", "3", "4", "5", "6"]);
        let r = event(
            &mut c,
            0,
            "load",
            json!({"programID":"p","lockedCapacity":2}),
        );
        let r = drain(&mut c, r, &["2"]);
        assert_eq!(r["state"]["current"]["slot"]["track"]["id"], "1");
        assert_eq!(prepared_ids(&r, "locked"), vec!["3", "4"]);
        assert_eq!(r["state"]["failedTrackIDs"], json!(["2"]));
        let r = event(&mut c, 1, "advance", json!({}));
        let r = drain(&mut c, r, &["5"]);
        assert_eq!(r["state"]["current"]["slot"]["track"]["id"], "3");
        assert_eq!(prepared_ids(&r, "locked"), vec!["4", "6"]);
        assert_eq!(r["state"]["failedTrackIDs"], json!(["2", "5"]));
        let r = event(&mut c, 1, "previous", json!({}));
        assert_eq!(r["selected"]["slot"]["track"]["id"], "1");
        assert_eq!(prepared_ids(&r, "locked"), vec!["3", "4", "6"]);
        let r = event(&mut c, 1, "previous", json!({}));
        assert!(r["selected"].is_null());
        assert_eq!(r["state"]["current"]["slot"]["track"]["id"], "1");
        let r = event(&mut c, 1, "current_failed", json!({}));
        assert_eq!(r["state"]["current"]["slot"]["track"]["id"], "3");
        assert_eq!(r["state"]["failedTrackIDs"], json!(["2", "5", "1"]));
    }
    #[test]
    fn program_select_reuses_cache_and_failed_selected_preflight_preserves_queue() {
        let mut c = program_db(&["1", "2", "3", "4"]);
        let r = event(&mut c, 0, "load", json!({"programID":"p"}));
        let r = drain(&mut c, r, &[]);
        let before = r["state"].clone();
        let r = event(
            &mut c,
            1,
            "select",
            json!({"programID":"p","startingIndex":3}),
        );
        let r = drain(&mut c, r, &["4"]);
        assert_eq!(r["state"]["current"], before["current"]);
        assert_eq!(r["state"]["locked"], before["locked"]);
        assert_eq!(r["state"]["reserve"], before["reserve"]);
        assert_eq!(r["state"]["failedTrackIDs"], json!([]));
        let r = event(
            &mut c,
            1,
            "select",
            json!({"programID":"p","startingIndex":1}),
        );
        assert!(r["ticket"].is_null());
        assert_eq!(r["state"]["current"], before["locked"][0]);
        assert_eq!(prepared_ids(&r, "locked"), vec!["3"]);
        assert_eq!(r["state"]["reserve"][0]["track"]["id"], "4");
    }
    #[test]
    fn program_rejects_candidate_slots_and_late_receipts() {
        let mut c = program_db(&["1"]);
        assert_eq!(
            program_request(
                &mut c,
                json!({"queueID":"q","hostSessionID":"h","op":"load","slots":[]})
            ),
            Err("music_playback_invalid_input")
        );
        let r = event(&mut c, 0, "load", json!({"programID":"p"}));
        let t = r["ticket"].clone();
        let _ = drain(&mut c, r, &[]);
        let r = event(&mut c, 1, "load", json!({"programID":"p"}));
        assert_eq!(r["state"]["generation"], 2);
        assert_eq!(
            program_request(
                &mut c,
                json!({"queueID":"queue","hostSessionID":"host","generation":1,"op":"prepare_receipt","ticketID":t["ticketID"],"trackID":"1","accepted":false})
            ),
            Err("music_playback_stale_session")
        );
    }
    #[test]
    fn program_revision_load_preserves_published_old_plan_after_same_id_draft() {
        let mut c = program_db(&["old"]);
        let old: String = c
            .query_row("SELECT payload FROM music_dj_owned WHERE id='p'", [], |r| {
                r.get(0)
            })
            .unwrap();
        let old: Value = serde_json::from_str(&old).unwrap();
        let draft = json!({"brief":{"id":"p"},"revision":2,"slots":[{"track":{"id":"new"}}]});
        c.execute(
            "INSERT INTO music_dj_state VALUES(1,?1)",
            [json!({"plan":old,"pendingPlan":draft}).to_string()],
        )
        .unwrap();
        c.execute(
            "INSERT INTO music_programs VALUES('p',?1)",
            [json!({"plan":draft}).to_string()],
        )
        .unwrap();
        c.execute(
            "UPDATE music_dj_owned SET payload=?1 WHERE id='p'",
            [draft.to_string()],
        )
        .unwrap();
        let r = event(
            &mut c,
            0,
            "load",
            json!({"programID":"p","programRevision":1}),
        );
        assert_eq!(r["ticket"]["slot"]["track"]["id"], "old");
        let _ = drain(&mut c, r, &[]);
        let r = event(
            &mut c,
            1,
            "load",
            json!({"programID":"p","programRevision":2}),
        );
        assert_eq!(r["ticket"]["slot"]["track"]["id"], "new");
        assert_eq!(
            program_slots(&c, Some("p"), Some(3)),
            Err("music_playback_program_revision_mismatch")
        );
        assert_eq!(
            program_slots(&c, Some("p"), None),
            Err("music_playback_invalid_input")
        );
    }
    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        c
    }
    fn call(c: &mut Connection, method: &str, mut params: Value) -> Result<Value> {
        params["playerID"] = json!("fixture");
        params["hostSessionID"] = json!("host");
        request(c, method, params)
    }
    fn selection(c: &mut Connection, id: &str) -> Value {
        call(
            c,
            "music_playback_begin",
            json!({"requestID":id,"mode":"library","index":0,
        "queue":[{"id":"a","payload":{"title":"A"}},{"id":"b","payload":{"title":"B"}}]}),
        )
        .unwrap()["ticket"]
            .clone()
    }
    fn commit(c: &mut Connection, mut ticket: Value) -> Value {
        ticket["accepted"] = json!(true);
        call(c, "music_playback_commit", ticket).unwrap()["state"].clone()
    }
    #[test]
    fn pending_does_not_replace_current_and_old_receipts_never_advance_new_queue() {
        let mut c = db();
        let first = selection(&mut c, "first");
        commit(&mut c, first);
        let second = selection(&mut c, "second");
        assert_eq!(
            call(&mut c, "music_playback_read", json!({})).unwrap()["state"]["sessionID"],
            "first"
        );
        commit(&mut c, second);
        assert_eq!(
            call(
                &mut c,
                "music_playback_receipt",
                json!({"sessionID":"first","trackID":"a","status":"completed"})
            ),
            Err("music_playback_stale_session")
        );
        let done = call(
            &mut c,
            "music_playback_receipt",
            json!({"sessionID":"second","trackID":"a","status":"completed"}),
        )
        .unwrap();
        assert_eq!(done["state"]["index"], 0);
    }
    #[test]
    fn navigation_is_rust_owned_and_failed_preparation_preserves_current() {
        let mut c = db();
        let ticket = selection(&mut c, "first");
        commit(&mut c, ticket);
        let mut next = call(
            &mut c,
            "music_playback_navigate",
            json!({"sessionID":"first","requestID":"next","delta":1}),
        )
        .unwrap()["ticket"]
            .clone();
        assert_eq!(next["index"], 1);
        next["accepted"] = json!(false);
        assert_eq!(
            call(&mut c, "music_playback_commit", next).unwrap()["state"]["index"],
            0
        );
        assert_eq!(
            call(
                &mut c,
                "music_playback_navigate",
                json!({"sessionID":"first","requestID":"prev","delta":-1})
            ),
            Err("music_playback_track_not_found")
        );
    }
    #[test]
    fn old_selection_cannot_commit_and_wrong_track_receipt_is_rejected() {
        let mut c = db();
        let old = selection(&mut c, "old");
        let newer = selection(&mut c, "new");
        let mut stale = old;
        stale["accepted"] = json!(true);
        assert_eq!(
            call(&mut c, "music_playback_commit", stale),
            Err("music_playback_stale_selection")
        );
        commit(&mut c, newer);
        assert_eq!(
            call(
                &mut c,
                "music_playback_receipt",
                json!({"sessionID":"new","trackID":"other","status":"failed"})
            ),
            Err("music_playback_stale_track")
        );
    }
    #[test]
    fn committed_begin_replay_is_durable_and_changed_payload_is_rejected() {
        let mut c = db();
        let ticket = selection(&mut c, "stable");
        commit(&mut c, ticket.clone());
        let replay = selection(&mut c, "stable");
        assert_eq!(replay, ticket);
        let mut changed = json!({"requestID":"stable","mode":"local","index":0,"queue":[{"id":"a","payload":{}}]});
        changed["playerID"] = json!("fixture");
        changed["hostSessionID"] = json!("host");
        assert_eq!(
            request(&mut c, "music_playback_begin", changed),
            Err("music_playback_request_conflict")
        );
        schema(&c).unwrap();
    }
}
