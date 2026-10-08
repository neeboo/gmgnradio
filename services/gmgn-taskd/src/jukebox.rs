//! Durable compound control; native measurements are receipts, never authorization flags.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS jukebox_compounds(id TEXT PRIMARY KEY,world_id TEXT NOT NULL,scope_id TEXT NOT NULL,session TEXT NOT NULL,request_id TEXT NOT NULL,input TEXT NOT NULL,payload TEXT NOT NULL,UNIQUE(world_id,scope_id,request_id));CREATE TABLE IF NOT EXISTS jukebox_actions(action_id TEXT PRIMARY KEY,compound_id TEXT NOT NULL,payload TEXT NOT NULL);").map_err(|_|"storage_unavailable")
}
fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
        .ok_or("jukebox_invalid_input")
}
fn canonical(v: &Value) -> Result<String> {
    crate::canonical_json::to_string(v).map_err(|_| "jukebox_invalid_input")
}
fn load(c: &Connection, id: &str) -> Result<Value> {
    let raw: String = c
        .query_row(
            "SELECT payload FROM jukebox_compounds WHERE id=?1",
            [id],
            |r| r.get(0),
        )
        .map_err(|_| "jukebox_invalid_input")?;
    serde_json::from_str(&raw).map_err(|_| "jukebox_invalid_state")
}
fn save(c: &Connection, s: &Value) -> Result<()> {
    c.execute(
        "UPDATE jukebox_compounds SET payload=?1 WHERE id=?2",
        params![canonical(s)?, s["compoundID"].as_str()],
    )
    .map_err(|_| "storage_unavailable")?;
    if s["action"].is_object() {
        c.execute("INSERT INTO jukebox_actions VALUES(?1,?2,?3) ON CONFLICT(action_id) DO UPDATE SET payload=excluded.payload",params![s["action"]["actionID"].as_str(),s["compoundID"].as_str(),canonical(&s["action"])?]).map_err(|_|"storage_unavailable")?;
    }
    Ok(())
}
fn action(s: &mut Value, kind: &str, args: Value) {
    s["state"] = json!(kind);
    s["action"] = json!({"actionID":uuid::Uuid::new_v4().to_string(),"kind":kind,"status":"pending","args":args});
}
fn run(c: &Connection, world: &str) -> Result<Value> {
    let raw: Option<String> = c
        .query_row(
            "SELECT payload FROM world_activity_runs WHERE world_id=?1",
            [world],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let state: Value = raw
        .map(|s| serde_json::from_str(&s).map_err(|_| "jukebox_invalid_state"))
        .transpose()?
        .unwrap_or(Value::Null);
    Ok(state["run"].clone())
}
fn owned(s: &Value, r: &Value) -> bool {
    r.is_object()
        && r["requestID"] == s["ownedRun"]["runRequestID"]
        && r["generation"] == s["ownedRun"]["generation"]
        && r["hostSessionID"] == s["ownedRun"]["hostSessionID"]
        && music(r)
        && r["status"] == "running"
}
fn music(r: &Value) -> bool {
    r["definition"]["id"] == "music.listen" || r["usageBinding"]["templateID"] == "music.listen"
}
fn fail(c: &Connection, s: &mut Value, code: &str) -> Result<()> {
    s["errorCode"] = json!(code);
    let r = run(c, text(s, "worldID")?)?;
    if owned(s, &r) {
        action(
            s,
            "compensate_stop",
            json!({"runRequestID":r["requestID"],"generation":r["generation"],"phaseGeneration":r["phaseGeneration"],"phase":r["phase"]}),
        );
    } else {
        s["state"] = json!("failed");
        s["action"] = Value::Null;
    }
    Ok(())
}
fn point(v: &Value) -> Result<[f64; 3]> {
    let mut out = [0.; 3];
    for (i, k) in ["x", "y", "z"].iter().enumerate() {
        out[i] = v[*k]
            .as_f64()
            .filter(|x| x.is_finite())
            .ok_or("jukebox_invalid_facts")?;
    }
    Ok(out)
}
fn close(a: &Value, b: &Value, t: f64) -> Result<bool> {
    let a = point(a)?;
    let b = point(b)?;
    Ok(a.into_iter()
        .zip(b)
        .map(|(a, b)| (a - b).powi(2))
        .sum::<f64>()
        <= t * t)
}
fn fence(s: &Value, p: &Value) -> Result<()> {
    for k in ["worldID", "scopeID", "hostSessionID"] {
        if text(p, k)? != text(s, k)? {
            return Err("jukebox_identity_mismatch");
        }
    }
    Ok(())
}
fn check_prepare(c: &Connection, s: &Value, f: &Value) -> Result<()> {
    let snap = crate::world::snapshot(
        c,
        &crate::world::SnapshotRequest {
            world_id: text(s, "worldID")?.into(),
            include_state: Some(true),
        },
    )?;
    if f["worldRevision"] != snap["record"]["state"]["revision"]
        || f["worldRevision"].as_u64().is_none()
    {
        return Err("jukebox_stale_world");
    }
    let id = text(f, "objectID")?;
    if snap["record"]["state"]["objectStates"][id]["isEnabled"] != true {
        return Err("jukebox_invalid_facts");
    }
    if f["motionRequired"] == true {
        text(f, "requiredMotionID")?;
    } else if f["motionRequired"] != false
        || !f["avatarFormat"].is_null()
        || !f["requiredMotionID"].is_null()
    {
        return Err("jukebox_invalid_facts");
    }
    point(&f["interactionTarget"])?;
    if !f["contactTarget"].is_null() {
        point(&f["contactTarget"])?;
    }
    Ok(())
}
fn check_start(c: &Connection, s: &Value, f: &Value) -> Result<Value> {
    let r = run(c, text(s, "worldID")?)?;
    if r["requestID"] != f["runRequestID"]
        || r["generation"] != f["generation"]
        || f["generation"].as_u64().is_none()
        || r["hostSessionID"].as_str().is_none()
        || !music(&r)
        || r["status"] != "running"
    {
        return Err("jukebox_stale_run");
    }
    if !close(&r["target"], &s["prepared"]["interactionTarget"], 0.02)? {
        return Err("jukebox_invalid_facts");
    }
    let phases = r["definition"]["phases"]
        .as_array()
        .ok_or("jukebox_invalid_facts")?;
    let motion = phases.iter().any(|p| {
        p["phase"] == "loop"
            && p["motionIDs"].as_array().is_some_and(|ids| {
                ids.contains(&s["prepared"]["motionBinding"]["authoredMotionID"])
            })
    });
    let object = phases.iter().any(|p| {
        p["propIDs"]
            .as_array()
            .is_some_and(|ids| ids.contains(&s["prepared"]["objectID"]))
    }) || r["usageBinding"]["objectID"] == s["prepared"]["objectID"];
    let binding = &s["prepared"]["motionBinding"];
    let authored = &binding["authoredMotionID"];
    let rendered = &binding["renderedMotionID"];
    let mapped = authored == rendered
        || (authored == "listen.music"
            && rendered == "builtin.motion.iluvslapbass-vrm"
            && binding["avatarFormat"] == "vrm")
        || (authored == "listen.music"
            && rendered == "builtin.motion.iluvslapbass"
            && binding["avatarFormat"] == "pmx");
    if (s["prepared"]["motionRequired"] == true
        && (!motion || !mapped || rendered != &s["prepared"]["requiredMotionID"]))
        || !object
    {
        return Err("jukebox_invalid_facts");
    }
    Ok(r)
}
fn render(c: &Connection, s: &mut Value, f: &Value) -> Result<bool> {
    let r = run(c, text(s, "worldID")?)?;
    if !owned(s, &r) {
        return Err("jukebox_stale_run");
    }
    for (a, b) in [
        ("runRequestID", "requestID"),
        ("generation", "generation"),
        ("phaseGeneration", "phaseGeneration"),
        ("phase", "phase"),
    ] {
        if f[a] != r[b] {
            return Err("jukebox_stale_render");
        }
    }
    if s["prepared"]["contactTarget"].is_null() {
        s["contactConfirmed"] = json!(true);
    } else if f["contactReady"] == true
        && close(&f["contactPosition"], &s["prepared"]["contactTarget"], 0.1)?
    {
        s["contactConfirmed"] = json!(true);
    }
    if r["phase"] != "loop"
        || s["contactConfirmed"] != true
        || (s["prepared"]["motionRequired"] == true
            && (f["motionReady"] != true
                || f["motionPlaying"] != true
                || f["motionID"] != s["prepared"]["requiredMotionID"]))
    {
        return Ok(false);
    }
    let tolerance = r["arrivalTolerance"]
        .as_f64()
        .filter(|x| x.is_finite() && *x > 0. && *x <= 1.)
        .ok_or("jukebox_invalid_facts")?;
    let snapshot = crate::world::snapshot(
        c,
        &crate::world::SnapshotRequest {
            world_id: text(s, "worldID")?.to_owned(),
            include_state: Some(true),
        },
    )?;
    let actual = &snapshot["record"]["state"]["agentTransform"]["position"];
    Ok(close(&f["position"], actual, 0.05)? && close(actual, &r["target"], tolerance)?)
}
pub fn recover(c: &Connection) -> Result<()> {
    let mut q = c
        .prepare("SELECT id FROM jukebox_compounds")
        .map_err(|_| "storage_unavailable")?;
    let ids = q
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|_| "storage_unavailable")?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| "storage_unavailable")?;
    drop(q);
    for id in ids {
        let mut s = load(c, &id)?;
        if s["action"]["status"] == "claimed" {
            s["action"]["status"] = json!("unknown");
            save(c, &s)?;
        }
    }
    Ok(())
}
pub fn request(c: &Connection, method: &str, p: &Value, now: u64) -> Result<Value> {
    let mut s = if method == "jukebox_begin" {
        let world = text(p, "worldID")?;
        let scope = text(p, "scopeID")?;
        let host = text(p, "hostSessionID")?;
        let req = text(p, "requestID")?;
        let kind = text(&p["operation"], "kind")?;
        let args = p["operation"]["args"]
            .as_object()
            .ok_or("jukebox_invalid_input")?;
        if !matches!(
            kind,
            "play_program_track"
                | "next_track"
                | "previous_track"
                | "resume_music"
                | "activate_prepared_program"
        ) || (kind != "play_program_track" && !args.is_empty())
            || args
                .keys()
                .any(|k| !matches!(k.as_str(), "trackID" | "slotIndex"))
            || args
                .get("trackID")
                .is_some_and(|v| v.as_str().is_none_or(|v| v.is_empty() || v.len() > 512))
            || args.get("slotIndex").is_some_and(|v| v.as_u64().is_none())
        {
            return Err("jukebox_invalid_input");
        }
        let input = canonical(p)?;
        let old:Option<(String,String)>=c.query_row("SELECT id,input FROM jukebox_compounds WHERE world_id=?1 AND scope_id=?2 AND request_id=?3",params![world,scope,req],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
        if let Some((id, stored)) = old {
            if stored != input {
                return Err("jukebox_identity_mismatch");
            }
            return load(c, &id);
        }
        let mut query = c
            .prepare("SELECT payload FROM jukebox_compounds WHERE world_id=?1")
            .map_err(|_| "storage_unavailable")?;
        for raw in query
            .query_map([world], |r| r.get::<_, String>(0))
            .map_err(|_| "storage_unavailable")?
        {
            let v: Value = serde_json::from_str(&raw.map_err(|_| "storage_unavailable")?)
                .map_err(|_| "jukebox_invalid_state")?;
            if !matches!(v["state"].as_str(), Some("completed" | "failed")) {
                return Err("jukebox_busy");
            }
        }
        drop(query);
        let id = uuid::Uuid::new_v4().to_string();
        let mut v = json!({"compoundID":id,"worldID":world,"scopeID":scope,"hostSessionID":host,"requestID":req,"operation":p["operation"],"startedAtMs":now,"deadlineMs":now.saturating_add(45000),"waitMS":0,"errorCode":null,"ownedRun":null,"prepared":null});
        action(&mut v, "prepare", p["operation"]["args"].clone());
        c.execute(
            "INSERT INTO jukebox_compounds VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![id, world, scope, host, req, input, canonical(&v)?],
        )
        .map_err(|_| "storage_unavailable")?;
        save(c, &v)?;
        return Ok(v);
    } else {
        let s = load(c, text(p, "compoundID")?)?;
        fence(&s, p)?;
        s
    };
    let current = run(c, text(&s, "worldID")?)?;
    s["runFence"] = if owned(&s, &current) {
        json!({"runRequestID":current["requestID"],"generation":current["generation"],"phaseGeneration":current["phaseGeneration"],"phase":current["phase"]})
    } else {
        Value::Null
    };
    if method == "jukebox_read" {
        if p["cancelRequested"] == true
            && !matches!(s["state"].as_str(), Some("completed" | "failed"))
        {
            s["cancelRequested"] = json!(true);
            if matches!(s["action"]["status"].as_str(), Some("claimed" | "unknown")) {
                s["errorCode"] = json!("jukebox_cancel_requested");
                save(c, &s)?;
                return Ok(s);
            }
            fail(c, &mut s, "jukebox_cancelled")?;
            save(c, &s)?;
            return Ok(s);
        }
        if s["state"] == "wait_render" {
            if now >= s["deadlineMs"].as_u64().ok_or("jukebox_invalid_state")? {
                fail(c, &mut s, "jukebox_timeout")?;
            } else {
                let r = run(c, text(&s, "worldID")?)?;
                if !owned(&s, &r) {
                    fail(c, &mut s, "jukebox_stale_run")?;
                } else if p["renderFacts"].is_object() && render(c, &mut s, &p["renderFacts"])? {
                    let args = json!({"runRequestID":r["requestID"],"generation":r["generation"],"phaseGeneration":r["phaseGeneration"],"phase":r["phase"],"playbackID":s["compoundID"]});
                    action(&mut s, "play", args);
                } else {
                    s["waitMS"] = json!(100);
                }
            }
        }
        save(c, &s)?;
        return Ok(s);
    }
    if p["actionID"] != s["action"]["actionID"] {
        if method == "jukebox_receipt" {
            let raw: Option<String> = c
                .query_row(
                    "SELECT payload FROM jukebox_actions WHERE action_id=?1 AND compound_id=?2",
                    params![text(p, "actionID")?, text(&s, "compoundID")?],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|_| "storage_unavailable")?;
            if let Some(raw) = raw {
                let historic: Value =
                    serde_json::from_str(&raw).map_err(|_| "jukebox_invalid_state")?;
                if historic["receipt"] == canonical(p)? {
                    return Ok(s);
                }
            }
        }
        return Err("jukebox_stale_action");
    }
    match method {
        "jukebox_claim" => {
            if s["action"]["status"] != "pending" {
                return Err("jukebox_claim_unknown");
            }
            if s["state"] == "play" || s["state"] == "compensate_stop" {
                let r = run(c, text(&s, "worldID")?)?;
                let a = &s["action"]["args"];
                if !owned(&s, &r)
                    || r["phaseGeneration"] != a["phaseGeneration"]
                    || r["phase"] != a["phase"]
                {
                    s["state"] = json!("failed");
                    s["action"] = Value::Null;
                    s["errorCode"] = json!("jukebox_stale_run");
                    save(c, &s)?;
                    return Ok(s);
                }
            }
            s["action"]["status"] = json!("claimed");
        }
        "jukebox_receipt" => {
            let canonical_receipt = canonical(p)?;
            if s["action"]["receipt"] == canonical_receipt {
                return Ok(s);
            }
            if s["action"]["status"] != "claimed" && s["action"]["status"] != "unknown" {
                return Err("jukebox_stale_action");
            }
            if p["outcome"] == "unknown" {
                s["action"]["status"] = json!("unknown");
                s["errorCode"] = json!("jukebox_execution_unknown");
                save(c, &s)?;
                return Ok(s);
            }
            if p["outcome"] != "completed" && p["outcome"] != "failed" {
                return Err("jukebox_invalid_input");
            }
            s["action"]["receipt"] = json!(canonical_receipt);
            s["action"]["status"] = json!("confirmed");
            save(c, &s)?;
            if p["outcome"] == "failed" {
                if s["state"] == "compensate_stop" {
                    let r = run(c, text(&s, "worldID")?)?;
                    if owned(&s, &r) {
                        s["action"]["status"] = json!("unknown");
                        s["errorCode"] = json!("jukebox_execution_unknown");
                    } else {
                        s["state"] = json!("failed");
                        s["action"] = Value::Null;
                    }
                } else {
                    fail(c, &mut s, "jukebox_execution_failed")?;
                }
            } else {
                match s["state"].as_str() {
                    Some("prepare") => {
                        check_prepare(c, &s, &p["facts"])?;
                        s["prepared"] = p["facts"].clone();
                        let args = json!({"activityID":"music.listen","objectID":s["prepared"]["objectID"],"interactionTarget":s["prepared"]["interactionTarget"]});
                        action(&mut s, "start", args);
                    }
                    Some("start") => {
                        let r = check_start(c, &s, &p["facts"])?;
                        s["ownedRun"] = json!({"runRequestID":r["requestID"],"generation":r["generation"],"hostSessionID":r["hostSessionID"]});
                        s["state"] = json!("wait_render");
                        s["deadlineMs"] = json!(now.saturating_add(45000));
                        s["waitMS"] = json!(100);
                        s["action"] = Value::Null;
                        if s["cancelRequested"] == true {
                            fail(c, &mut s, "jukebox_cancelled")?;
                        }
                    }
                    Some("play") => {
                        let r = run(c, text(&s, "worldID")?)?;
                        let f = &p["facts"];
                        let valid = f["hasSnapshot"] == true
                            && f["isPlaying"].is_boolean()
                            && text(f, "trackID").is_ok()
                            && matches!(
                                f["playbackState"].as_str(),
                                Some("idle" | "ready" | "playing" | "paused" | "finished")
                            )
                            && f.get("programID").is_none_or(|v| {
                                v.is_null()
                                    || v.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 512)
                            })
                            && f.get("slotIndex")
                                .is_none_or(|v| v.is_null() || v.as_u64().is_some());
                        let target = &s["operation"]["args"];
                        let wrong_target = s["operation"]["kind"] == "play_program_track"
                            && ((target.get("trackID").is_some()
                                && target["trackID"] != f["trackID"])
                                || (target.get("slotIndex").is_some()
                                    && target["slotIndex"] != f["slotIndex"]));
                        if s["cancelRequested"] == true {
                            fail(c, &mut s, "jukebox_cancelled")?;
                        } else if !owned(&s, &r) {
                            fail(c, &mut s, "jukebox_stale_run")?;
                        } else if !valid
                            || (f["isPlaying"] == true && f["playbackState"] != "playing")
                        {
                            s["action"]["status"] = json!("unknown");
                            s["errorCode"] = json!("jukebox_execution_unknown");
                        } else if f["isPlaying"] != true || wrong_target {
                            fail(c, &mut s, "jukebox_playback_not_observed")?;
                        } else {
                            s["state"] = json!("completed");
                            s["action"] = Value::Null;
                        }
                    }
                    Some("compensate_stop") => {
                        let r = run(c, text(&s, "worldID")?)?;
                        if owned(&s, &r) {
                            return Err("jukebox_stop_not_observed");
                        }
                        s["state"] = json!("failed");
                        s["action"] = Value::Null;
                    }
                    _ => return Err("jukebox_invalid_state"),
                }
            }
        }
        _ => return Err("jukebox_invalid_input"),
    }
    let current = run(c, text(&s, "worldID")?)?;
    s["runFence"] = if owned(&s, &current) {
        json!({"runRequestID":current["requestID"],"generation":current["generation"],"phaseGeneration":current["phaseGeneration"],"phase":current["phase"]})
    } else {
        Value::Null
    };
    save(c, &s)?;
    Ok(s)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> (Connection, Value) {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        crate::world_activity::schema(&c).unwrap();
        crate::world::schema(&c).unwrap();
        let state = json!({"worldID":"world","revision":1,"agentTransform":{"position":{"x":1,"y":0,"z":1}}});
        let raw = canonical(&state).unwrap();
        c.execute(
            "INSERT INTO world_records VALUES('world','worlds','state',1,0,'fixture',0,?1,?2)",
            params![crate::model::digest(raw.as_bytes()), raw],
        )
        .unwrap();
        let p = json!({"worldID":"world","scopeID":"resident-world","hostSessionID":"host","requestID":"req","operation":{"kind":"resume_music","args":{}}});
        (c, p)
    }
    fn request_for(s: &Value) -> Value {
        json!({"worldID":"world","scopeID":"resident-world","hostSessionID":"host","compoundID":s["compoundID"],"actionID":s["action"]["actionID"]})
    }
    #[test]
    fn begin_identity_busy_and_recovery_no_replay() {
        let (c, p) = fixture();
        let s = request(&c, "jukebox_begin", &p, 10).unwrap();
        assert_eq!(request(&c, "jukebox_begin", &p, 20).unwrap(), s);
        let mut other = p.clone();
        other["requestID"] = json!("other");
        assert_eq!(
            request(&c, "jukebox_begin", &other, 20).unwrap_err(),
            "jukebox_busy"
        );
        let q = request_for(&s);
        request(&c, "jukebox_claim", &q, 20).unwrap();
        recover(&c).unwrap();
        assert_eq!(
            request(&c, "jukebox_claim", &q, 30).unwrap_err(),
            "jukebox_claim_unknown"
        );
        other = p.clone();
        other["operation"]["kind"] = json!("next_track");
        assert_eq!(
            request(&c, "jukebox_begin", &other, 30).unwrap_err(),
            "jukebox_identity_mismatch"
        );
    }
    fn waiting(c: &Connection, p: &Value) -> Value {
        let mut s = request(c, "jukebox_begin", p, 0).unwrap();
        s["state"] = json!("wait_render");
        s["action"] = Value::Null;
        s["ownedRun"] =
            json!({"runRequestID":"run","generation":3,"hostSessionID":"activity-host"});
        s["prepared"] = json!({"interactionTarget":{"x":1,"y":0,"z":1},"contactTarget":{"x":1,"y":1,"z":1},"motionRequired":true,"requiredMotionID":"builtin.motion.iluvslapbass-vrm"});
        save(c, &s).unwrap();
        let r = json!({"requestID":"run","generation":3,"hostSessionID":"activity-host","definition":{"id":"music.listen"},"status":"running","phase":"enter","phaseGeneration":2,"target":{"x":1,"y":0,"z":1},"arrivalTolerance":0.02});
        c.execute(
            "INSERT INTO world_activity_runs VALUES('world',?1)",
            [canonical(&json!({"run":r})).unwrap()],
        )
        .unwrap();
        s
    }
    #[test]
    fn real_run_contact_enter_then_loop_and_phase_fenced_claim() {
        let (c, p) = fixture();
        let s = waiting(&c, &p);
        let mut q = request_for(&s);
        q["renderFacts"] = json!({"runRequestID":"run","generation":3,"phaseGeneration":2,"phase":"enter","position":{"x":1,"y":0,"z":1},"contactPosition":{"x":1,"y":1,"z":1},"contactReady":true,"motionReady":true,"motionPlaying":true,"motionID":"builtin.motion.iluvslapbass-vrm"});
        let waiting = request(&c, "jukebox_read", &q, 10).unwrap();
        assert_eq!(waiting["state"], "wait_render");
        assert_eq!(waiting["contactConfirmed"], true);
        let mut r = run(&c, "world").unwrap();
        r["phase"] = json!("loop");
        r["phaseGeneration"] = json!(3);
        c.execute(
            "UPDATE world_activity_runs SET payload=?1",
            [canonical(&json!({"run":r})).unwrap()],
        )
        .unwrap();
        q["renderFacts"]["phase"] = json!("loop");
        q["renderFacts"]["phaseGeneration"] = json!(3);
        q["renderFacts"]["contactReady"] = json!(false);
        let play = request(&c, "jukebox_read", &q, 20).unwrap();
        assert_eq!(play["state"], "play");
        assert_eq!(play["action"]["status"], "pending");
        let claim = request_for(&play);
        r["requestID"] = json!("replacement");
        c.execute(
            "UPDATE world_activity_runs SET payload=?1",
            [canonical(&json!({"run":r})).unwrap()],
        )
        .unwrap();
        assert_eq!(
            request(&c, "jukebox_claim", &claim, 30).unwrap()["state"],
            "failed"
        );
    }
    #[test]
    fn timeout_compensation_only_owns_current_run() {
        let (c, p) = fixture();
        let s = waiting(&c, &p);
        let timed = request(&c, "jukebox_read", &request_for(&s), 45000).unwrap();
        assert_eq!(timed["state"], "compensate_stop");
        let mut r = run(&c, "world").unwrap();
        r["requestID"] = json!("other");
        c.execute(
            "UPDATE world_activity_runs SET payload=?1",
            [canonical(&json!({"run":r})).unwrap()],
        )
        .unwrap();
        let result = request(&c, "jukebox_claim", &request_for(&timed), 45001).unwrap();
        assert_eq!(result["state"], "failed");
        assert!(result["action"].is_null());
    }
    #[test]
    fn failed_stop_keeps_owned_running_slot_quarantined() {
        let (c, p) = fixture();
        let s = waiting(&c, &p);
        let timed = request(&c, "jukebox_read", &request_for(&s), 45000).unwrap();
        let mut q = request_for(&timed);
        request(&c, "jukebox_claim", &q, 45001).unwrap();
        q["outcome"] = json!("failed");
        let failed = request(&c, "jukebox_receipt", &q, 45002).unwrap();
        assert_eq!(failed["state"], "compensate_stop");
        assert_eq!(failed["action"]["status"], "unknown");
        let mut next = p.clone();
        next["requestID"] = json!("next");
        assert_eq!(
            request(&c, "jukebox_begin", &next, 45003).unwrap_err(),
            "jukebox_busy"
        );
        assert_eq!(
            request(&c, "jukebox_claim", &request_for(&failed), 45003).unwrap_err(),
            "jukebox_claim_unknown"
        );
    }
    #[test]
    fn renderer_legacy_contact_and_pose_boundaries() {
        let (c, p) = fixture();
        let mut s = waiting(&c, &p);
        let mut r = run(&c, "world").unwrap();
        r["phase"] = json!("loop");
        r["phaseGeneration"] = json!(3);
        c.execute(
            "UPDATE world_activity_runs SET payload=?1",
            [canonical(&json!({"run":r})).unwrap()],
        )
        .unwrap();
        let mut f = json!({"runRequestID":"run","generation":3,"phaseGeneration":3,"phase":"loop","position":{"x":1.04,"y":0,"z":1},"contactPosition":{"x":1.08,"y":1,"z":1},"contactReady":true,"motionReady":true,"motionPlaying":true,"motionID":"builtin.motion.iluvslapbass-vrm"});
        assert!(render(&c, &mut s, &f).unwrap());
        s["contactConfirmed"] = json!(false);
        f["contactPosition"]["x"] = json!(1.11);
        assert!(!render(&c, &mut s, &f).unwrap());
        f["contactPosition"]["x"] = json!(1.08);
        f["position"]["x"] = json!(1.06);
        assert!(!render(&c, &mut s, &f).unwrap());
    }
    #[test]
    fn actual_player_snapshot_required_for_completion() {
        for (facts, state, status) in [
            (Value::Null, "play", "unknown"),
            (json!({"hasSnapshot":false}), "play", "unknown"),
            (
                json!({"hasSnapshot":true,"isPlaying":false,"playbackState":"paused","trackID":"track"}),
                "compensate_stop",
                "pending",
            ),
            (
                json!({"hasSnapshot":true,"isPlaying":true,"playbackState":"playing","trackID":"wrong"}),
                "compensate_stop",
                "pending",
            ),
            (
                json!({"hasSnapshot":true,"isPlaying":true,"playbackState":"playing","trackID":"track"}),
                "completed",
                "",
            ),
        ] {
            let (c, p) = fixture();
            let mut s = waiting(&c, &p);
            s["operation"] = json!({"kind":"play_program_track","args":{"trackID":"track"}});
            action(&mut s, "play", json!({}));
            s["action"]["status"] = json!("claimed");
            save(&c, &s).unwrap();
            let mut q = request_for(&s);
            q["outcome"] = json!("completed");
            q["facts"] = facts;
            let result = request(&c, "jukebox_receipt", &q, 10).unwrap();
            assert_eq!(result["state"], state);
            if !status.is_empty() {
                assert_eq!(result["action"]["status"], status);
            }
        }
    }
    #[test]
    fn pmx_music_alias_is_exact_and_format_bound() {
        let (c, p) = fixture();
        let mut s = waiting(&c, &p);
        s["prepared"]["objectID"] = json!("jukebox");
        s["prepared"]["requiredMotionID"] = json!("builtin.motion.iluvslapbass");
        s["prepared"]["motionBinding"] = json!({"authoredMotionID":"listen.music","renderedMotionID":"builtin.motion.iluvslapbass","avatarFormat":"pmx"});
        let mut r = run(&c, "world").unwrap();
        r["definition"]["phases"] =
            json!([{"phase":"loop","motionIDs":["listen.music"],"propIDs":["jukebox"]}]);
        c.execute(
            "UPDATE world_activity_runs SET payload=?1",
            [canonical(&json!({"run":r})).unwrap()],
        )
        .unwrap();
        let facts = json!({"runRequestID":"run","generation":3});
        assert!(check_start(&c, &s, &facts).is_ok());
        s["prepared"]["motionBinding"]["avatarFormat"] = json!("vrm");
        assert_eq!(
            check_start(&c, &s, &facts).unwrap_err(),
            "jukebox_invalid_facts"
        );
        s["prepared"]["motionBinding"]["avatarFormat"] = json!("pmx");
        s["prepared"]["motionBinding"]["renderedMotionID"] = json!("arbitrary.motion");
        assert_eq!(
            check_start(&c, &s, &facts).unwrap_err(),
            "jukebox_invalid_facts"
        );
    }
}
