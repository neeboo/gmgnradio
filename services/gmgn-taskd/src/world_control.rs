//! Typed world controls. Hosts provide raw intent, not completed goal/state documents.
use crate::{model::Result, world};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS world_control_catalog(world_id TEXT PRIMARY KEY,cameras TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS world_control_hosts(world TEXT,scope TEXT,host TEXT,capability TEXT NOT NULL,PRIMARY KEY(world,scope,host));
CREATE TABLE IF NOT EXISTS world_control_intents(id TEXT PRIMARY KEY,world TEXT NOT NULL,scope TEXT NOT NULL,host TEXT NOT NULL,capability TEXT NOT NULL,revision INTEGER NOT NULL,command TEXT NOT NULL,expires INTEGER NOT NULL,used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS world_control_commands(world TEXT,scope TEXT,request TEXT,input TEXT NOT NULL,output TEXT NOT NULL,PRIMARY KEY(world,scope,request));")
        .map_err(|_| "storage_unavailable")
}
pub fn recover(db: &Connection) -> Result<()> {
    db.execute_batch("DELETE FROM world_control_hosts; DELETE FROM world_control_intents;")
        .map_err(|_| "storage_unavailable")
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("world_control_invalid_input")
}
fn encoded(v: &Value) -> Result<String> {
    crate::canonical_json::to_string(v).map_err(|_| "world_control_invalid_input")
}
fn now() -> Result<i64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "world_control_clock_unavailable")?
        .as_millis()
        .try_into()
        .map_err(|_| "world_control_clock_unavailable")
}
fn snapshot(db: &Connection, world_id: &str) -> Result<Value> {
    world::snapshot(
        db,
        &world::SnapshotRequest {
            world_id: world_id.into(),
            include_state: Some(true),
        },
    )
}
fn revision(p: &Value, s: &Value) -> Result<i64> {
    let expected = p["expectedRevision"]
        .as_i64()
        .filter(|v| *v >= 0)
        .ok_or("world_control_invalid_input")?;
    if s["record"]["recordRevision"] != expected {
        return Err("revision_conflict");
    }
    Ok(expected)
}
fn command(tool: &str, args: &Value) -> Result<Value> {
    match tool {
        "set_world_weather" => Ok(json!({"op":"weather","weather":args["weather"]})),
        "move_live_camera" => Ok(json!({"op":"camera","cameraID":args["camera_id"]})),
        "complete_world_goal" => {
            Ok(json!({"op":"goal","goalID":args["goal_id"],"summary":args["summary"]}))
        }
        _ => Err("world_control_unauthorized"),
    }
}
fn validate_command(raw: &Value) -> Result<()> {
    let object = raw.as_object().ok_or("world_control_invalid_input")?;
    let allowed: &[&str] = match text(raw, "op")? {
        "weather" => &["op", "weather"],
        "camera" => &["op", "cameraID"],
        "goal" => &["op", "goalID", "summary"],
        _ => return Err("world_control_invalid_input"),
    };
    if object.keys().any(|k| !allowed.contains(&k.as_str())) {
        return Err("world_control_invalid_input");
    }
    Ok(())
}
fn authorized_command(tx: &Transaction<'_>, p: &Value, expected: i64) -> Result<Value> {
    let world = text(p, "worldID")?;
    let scope = text(p, "residentScope")?;
    let host = text(p, "hostSessionID")?;
    let authority = &p["authority"];
    if authority["kind"] == "ui" {
        let row: Option<(String,String,String,String,i64,String,i64,bool)> = tx.query_row("SELECT world,scope,host,capability,revision,command,expires,used FROM world_control_intents WHERE id=?1",[text(authority,"intentID")?],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?))).optional().map_err(|_|"storage_unavailable")?;
        let (w, s, h, cap, r, raw, expires, used) = row.ok_or("world_control_unauthorized")?;
        if w != world
            || s != scope
            || h != host
            || cap != text(authority, "capability")?
            || r != expected
            || used
            || now()? >= expires
        {
            return Err("world_control_unauthorized");
        }
        tx.execute(
            "UPDATE world_control_intents SET used=1 WHERE id=?1",
            [text(authority, "intentID")?],
        )
        .map_err(|_| "storage_unavailable")?;
        let command: Value =
            serde_json::from_str(&raw).map_err(|_| "world_control_invalid_state")?;
        if p["command"] != command {
            return Err("world_control_unauthorized");
        }
        return Ok(command);
    }
    if authority["kind"] != "agent" {
        return Err("world_control_unauthorized");
    }
    let run = text(authority, "runID")?;
    let row:Option<(String,String,String,String)>=tx.query_row("SELECT tool,input,effect,state FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND call=?5 AND operation=?6",params![world,scope,run,host,text(authority,"callID")?,text(authority,"operationID")?],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(|_|"storage_unavailable")?;
    let (tool, args, effect, state) = row.ok_or("world_control_unauthorized")?;
    let claimed:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_events WHERE world=?1 AND scope=?2 AND run=?3 AND session=?4 AND state='claimed')",params![world,scope,run,host],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
    if !claimed || effect != "write" || state != "inflight" {
        return Err("world_control_unauthorized");
    }
    let args: Value = serde_json::from_str(&args).map_err(|_| "world_control_invalid_state")?;
    let resolved = command(&tool, &args)?;
    if p["command"] != resolved {
        return Err("world_control_unauthorized");
    }
    Ok(resolved)
}
pub fn request(db: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let input = encoded(p)?;
    if input.len() > 65536 {
        return Err("world_control_input_limit");
    }
    let world = text(p, "worldID")?;
    let scope = text(p, "residentScope")?;
    let host = text(p, "hostSessionID")?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    let output = if method == "world_control_bind_catalog" {
        let cameras = p["cameras"]
            .as_array()
            .filter(|v| v.len() <= 64)
            .ok_or("world_control_invalid_input")?;
        let mut ids = std::collections::HashSet::new();
        for camera in cameras {
            if !ids.insert(text(camera, "id")?) || !camera["transform"].is_object() {
                return Err("world_control_invalid_input");
            }
            for field in ["fieldOfViewDegrees", "nearPlane", "farPlane"] {
                if camera[field]
                    .as_f64()
                    .filter(|v| v.is_finite() && *v > 0.)
                    .is_none()
                {
                    return Err("world_control_invalid_input");
                }
            }
        }
        tx.execute("INSERT INTO world_control_catalog VALUES(?1,?2) ON CONFLICT(world_id) DO UPDATE SET cameras=excluded.cameras",params![world,encoded(&p["cameras"])?]).map_err(|_|"storage_unavailable")?;
        let old:Option<String>=tx.query_row("SELECT capability FROM world_control_hosts WHERE world=?1 AND scope=?2 AND host=?3",params![world,scope,host],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
        let capability = old.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        tx.execute(
            "INSERT OR IGNORE INTO world_control_hosts VALUES(?1,?2,?3,?4)",
            params![world, scope, host, capability],
        )
        .map_err(|_| "storage_unavailable")?;
        json!({"worldID":world,"residentScope":scope,"hostSessionID":host,"capability":capability})
    } else if method == "world_control_ui_intent" {
        let accepted:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM world_control_hosts WHERE world=?1 AND scope=?2 AND host=?3 AND capability=?4)",params![world,scope,host,text(p,"bindingCapability")?],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
        if !accepted {
            return Err("world_control_unauthorized");
        }
        let snap = snapshot(&tx, world)?;
        let expected = revision(p, &snap)?;
        validate_command(&p["command"])?;
        let id = uuid::Uuid::new_v4().to_string();
        let capability = uuid::Uuid::new_v4().to_string();
        tx.execute("INSERT INTO world_control_intents(id,world,scope,host,capability,revision,command,expires) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",params![id,world,scope,host,capability,expected,encoded(&p["command"])?,now()?+30000]).map_err(|_|"storage_unavailable")?;
        json!({"intentID":id,"capability":capability})
    } else if method == "world_control_command" {
        let request = text(p, "requestID")?;
        let old:Option<(String,String)>=tx.query_row("SELECT input,output FROM world_control_commands WHERE world=?1 AND scope=?2 AND request=?3",params![world,scope,request],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
        if let Some((old, result)) = old {
            if old != input {
                return Err("request_id_conflict");
            }
            serde_json::from_str(&result).map_err(|_| "world_control_invalid_state")?
        } else {
            let snap = snapshot(&tx, world)?;
            let expected = revision(p, &snap)?;
            let raw = authorized_command(&tx, p, expected)?;
            validate_command(&raw)?;
            let mut state = snap["record"]["state"].clone();
            let time = state["worldTime"].clone();
            time.as_f64()
                .filter(|v| v.is_finite())
                .ok_or("world_control_invalid_state")?;
            let kind = match text(&raw, "op")? {
                "weather" => {
                    let weather = text(&raw, "weather")?;
                    if !["clear", "cloudy", "rain", "snow"].contains(&weather) {
                        return Err("world_control_invalid_weather");
                    }
                    state["weather"] = json!(weather);
                    json!({"weatherChanged":{"weather":weather}})
                }
                "camera" => {
                    let id = text(&raw, "cameraID")?;
                    let catalog: String = tx
                        .query_row(
                            "SELECT cameras FROM world_control_catalog WHERE world_id=?1",
                            [world],
                            |r| r.get(0),
                        )
                        .optional()
                        .map_err(|_| "storage_unavailable")?
                        .ok_or("world_control_catalog_missing")?;
                    let cameras: Value = serde_json::from_str(&catalog)
                        .map_err(|_| "world_control_invalid_state")?;
                    let mut camera = cameras
                        .as_array()
                        .and_then(|rows| rows.iter().find(|row| row["id"] == id))
                        .cloned()
                        .ok_or("world_control_unknown_camera")?;
                    camera
                        .as_object_mut()
                        .ok_or("world_control_invalid_state")?
                        .remove("id");
                    camera["anchorID"] = json!(id);
                    state["liveCamera"] = camera.clone();
                    json!({"liveCameraChanged":{"camera":camera}})
                }
                "goal" => {
                    let id = raw["goalID"]
                        .as_str()
                        .ok_or("world_control_invalid_goal")?
                        .trim();
                    if id.is_empty() || id.len() > 256 {
                        return Err("world_control_invalid_goal");
                    }
                    let goals = state["completedGoals"]
                        .as_object_mut()
                        .ok_or("world_control_invalid_state")?;
                    if goals.contains_key(id) {
                        return Err("world_control_goal_already_completed");
                    }
                    let summary = if raw["summary"].is_null() {
                        None
                    } else {
                        let s = raw["summary"]
                            .as_str()
                            .ok_or("world_control_invalid_input")?
                            .trim();
                        if s.len() > 8192 {
                            return Err("world_control_input_limit");
                        }
                        if s.is_empty() {
                            None
                        } else {
                            Some(s)
                        }
                    };
                    let mut goal = json!({"goalID":id,"completedAt":time});
                    if let Some(summary) = summary {
                        goal["summary"] = json!(summary);
                    }
                    goals.insert(id.into(), goal);
                    json!({"goalCompleted":{"goalID":id}})
                }
                _ => return Err("world_control_invalid_input"),
            };
            let simulation_revision = state["revision"]
                .as_u64()
                .ok_or("world_control_invalid_state")?
                .checked_add(1)
                .ok_or("world_control_invalid_state")?;
            state["revision"] = json!(simulation_revision);
            world::commit_control(
                &tx,
                &world::CommitRequest {
                    world_id: world.into(),
                    request_id: format!("control:{scope}:{request}"),
                    expected_revision: expected,
                    producer: Some("world.control".into()),
                    intent: Some(raw),
                    ops: vec![world::Op {
                        op: "replaceState".into(),
                        state: Some(state),
                        ..Default::default()
                    }],
                },
            )?;
            let id = format!("control:{scope}:{request}");
            let fact = json!({"kind":kind,"worldTime":time,"revision":simulation_revision});
            tx.execute("INSERT INTO world_facts(world_id,id,kind,subject_domain,subject_key,revision,payload,producer,at_ms) VALUES(?1,?2,'control.transition','worlds','state',?3,?4,'world.control',?5)",params![world,id,expected+1,encoded(&fact)?,now()?]).map_err(|_|"storage_unavailable")?;
            let seq: i64 = tx
                .query_row(
                    "SELECT seq FROM world_facts WHERE world_id=?1 AND id=?2",
                    params![world, id],
                    |r| r.get(0),
                )
                .map_err(|_| "storage_unavailable")?;
            let result = json!({"worldID":world,"residentScope":scope,"hostSessionID":host,"requestID":request,"snapshot":snapshot(&tx,world)?,"events":[{"sequence":seq,"revision":simulation_revision,"worldTime":time,"kind":kind}]});
            tx.execute(
                "INSERT INTO world_control_commands VALUES(?1,?2,?3,?4,?5)",
                params![world, scope, request, input, encoded(&result)?],
            )
            .map_err(|_| "storage_unavailable")?;
            result
        }
    } else {
        return Err("method_not_found");
    };
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn identity() -> Value {
        json!({"worldID":"fixture","residentScope":"s","hostSessionID":"h"})
    }
    fn call(db: &mut Connection, method: &str, extra: Value) -> Result<Value> {
        let mut p = identity();
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone();
        }
        request(db, method, &p)
    }
    fn setup() -> (Connection, String) {
        let mut db = Connection::open_in_memory().unwrap();
        world::schema(&db).unwrap();
        schema(&db).unwrap();
        crate::agent_scheduler::schema(&db).unwrap();
        crate::agent_tools::schema(&db).unwrap();
        let tx = db.transaction().unwrap();
        world::commit(&tx,&world::CommitRequest{world_id:"fixture".into(),request_id:"seed".into(),expected_revision:0,producer:None,intent:None,ops:vec![world::Op{op:"replaceState".into(),state:Some(json!({"worldID":"fixture","revision":0,"worldTime":978307201125_i64,"weather":"clear","completedGoals":{},"objectStates":{},"agentTransform":{"position":{"x":0,"y":0,"z":0}}})),..Default::default()}]}).unwrap();
        tx.commit().unwrap();
        let cameras = json!([{"id":"wide","transform":{"position":{"x":1,"y":2,"z":3},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"fieldOfViewDegrees":55,"nearPlane":0.1,"farPlane":100}]);
        let bound = call(
            &mut db,
            "world_control_bind_catalog",
            json!({"cameras":cameras}),
        )
        .unwrap();
        (db, bound["capability"].as_str().unwrap().into())
    }
    fn ui(db: &mut Connection, capability: &str, raw: Value, request: &str) -> Result<Value> {
        let revision = snapshot(db, "fixture")?["record"]["recordRevision"].clone();
        let grant = call(
            db,
            "world_control_ui_intent",
            json!({"bindingCapability":capability,"expectedRevision":revision,"command":raw}),
        )?;
        call(
            db,
            "world_control_command",
            json!({"requestID":request,"expectedRevision":revision,"command":raw,"authority":{"kind":"ui","intentID":grant["intentID"],"capability":grant["capability"]}}),
        )
    }
    #[test]
    fn ui_controls_goals_use_authority_clock_and_fixed_catalog() {
        let (mut db, cap) = setup();
        let weather = ui(
            &mut db,
            &cap,
            json!({"op":"weather","weather":"rain"}),
            "weather",
        )
        .unwrap();
        assert_eq!(weather["snapshot"]["record"]["state"]["weather"], "rain");
        assert_eq!(
            weather["events"][0]["kind"],
            json!({"weatherChanged":{"weather":"rain"}})
        );
        let camera = ui(
            &mut db,
            &cap,
            json!({"op":"camera","cameraID":"wide"}),
            "camera",
        )
        .unwrap();
        assert_eq!(
            camera["snapshot"]["record"]["state"]["liveCamera"]["anchorID"],
            "wide"
        );
        assert_eq!(
            camera["snapshot"]["record"]["state"]["liveCamera"]["fieldOfViewDegrees"],
            55
        );
        assert_eq!(
            ui(
                &mut db,
                &cap,
                json!({"op":"camera","cameraID":"missing"}),
                "missing"
            ),
            Err("world_control_unknown_camera")
        );
        assert_eq!(
            ui(
                &mut db,
                &cap,
                json!({"op":"weather","weather":"fake"}),
                "invalid"
            ),
            Err("world_control_invalid_weather")
        );
        let goal = ui(
            &mut db,
            &cap,
            json!({"op":"goal","goalID":"  goal  ","summary":"  actual completion  "}),
            "goal",
        )
        .unwrap();
        let row = &goal["snapshot"]["record"]["state"]["completedGoals"]["goal"];
        assert_eq!(row["completedAt"], 978307201125_i64);
        assert_eq!(row["summary"], "actual completion");
        assert_eq!(
            goal["events"][0]["kind"],
            json!({"goalCompleted":{"goalID":"goal"}})
        );
        assert_eq!(
            ui(&mut db, &cap, json!({"op":"goal","goalID":"goal"}), "again"),
            Err("world_control_goal_already_completed")
        );
        assert_eq!(
            ui(&mut db, &cap, json!({"op":"goal","goalID":"  "}), "empty"),
            Err("world_control_invalid_goal")
        );
    }
    #[test]
    fn exact_ui_capability_revision_single_use_and_durable_replay() {
        let (mut db, cap) = setup();
        let raw = json!({"op":"goal","goalID":"a","summary":null});
        assert_eq!(
            call(
                &mut db,
                "world_control_ui_intent",
                json!({"bindingCapability":"wrong","expectedRevision":1,"command":raw})
            ),
            Err("world_control_unauthorized")
        );
        let grant = call(
            &mut db,
            "world_control_ui_intent",
            json!({"bindingCapability":cap,"expectedRevision":1,"command":raw}),
        )
        .unwrap();
        let p = json!({"requestID":"a","expectedRevision":1,"command":raw,"authority":{"kind":"ui","intentID":grant["intentID"],"capability":grant["capability"]}});
        let result = call(&mut db, "world_control_command", p.clone()).unwrap();
        let facts: i64 = db
            .query_row("SELECT COUNT(*) FROM world_facts", [], |r| r.get(0))
            .unwrap();
        assert_eq!(
            call(&mut db, "world_control_command", p.clone()).unwrap(),
            result
        );
        assert_eq!(
            db.query_row("SELECT COUNT(*) FROM world_facts", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            facts
        );
        let mut changed = p.clone();
        changed["requestID"] = json!("other");
        changed["expectedRevision"] = json!(2);
        assert_eq!(
            call(&mut db, "world_control_command", changed),
            Err("world_control_unauthorized")
        );
        let mut changed = p;
        changed["command"]["goalID"] = json!("b");
        assert_eq!(
            call(&mut db, "world_control_command", changed),
            Err("request_id_conflict")
        );
        recover(&db).unwrap();
        assert_eq!(
            ui(
                &mut db,
                &cap,
                json!({"op":"weather","weather":"clear"}),
                "stale"
            ),
            Err("world_control_unauthorized")
        );
    }
    #[test]
    fn actual_scheduler_and_ledger_authority_no_model_state_or_cancelled_claim() {
        let (mut db, _) = setup();
        let mut config = identity();
        config["hourlyLimit"] = json!(1);
        config["minimumWakeIntervalSeconds"] = json!(1);
        config["backgroundEnabled"] = json!(true);
        crate::agent_scheduler::request(&mut db, "agent_loop_configure", &config).unwrap();
        let mut event = identity();
        event["eventID"] = json!("e");
        event["intentID"] = json!("i");
        event["kind"] = json!("background");
        event["intentState"] = json!("active");
        event["command"] = json!({});
        crate::agent_scheduler::request(&mut db, "agent_loop_enqueue", &event).unwrap();
        let mut claim = identity();
        claim["runID"] = json!("r");
        claim["nowMillis"] = json!(1000);
        assert_eq!(
            crate::agent_scheduler::request(&mut db, "agent_loop_claim", &claim).unwrap()
                ["claimed"],
            true
        );
        let mut tool = identity();
        tool["runID"] = json!("r");
        tool["callID"] = json!("c");
        tool["operationID"] = json!("o");
        tool["toolName"] = json!("complete_world_goal");
        tool["arguments"] = json!({"goal_id":"proven","summary":"ledger input"});
        let mut registration = tool.clone();
        registration["tools"] = json!([{"name":"complete_world_goal","effect":"write","inputSchema":{"type":"object","properties":{"goal_id":{"type":"string"},"summary":{"type":"string"}},"required":["goal_id"],"additionalProperties":false}}]);
        crate::agent_tools::register_authorization(&mut db, &registration).unwrap();
        crate::agent_tools::authorize_operation(&mut db, &tool).unwrap();
        crate::agent_tools::request(&mut db, "agent_tool_begin", &tool).unwrap();
        let p = json!({"requestID":"agent","expectedRevision":1,"command":{"op":"goal","goalID":"proven","summary":"ledger input"},"authority":{"kind":"agent","runID":"r","callID":"c","operationID":"o"}});
        let mut forged = p.clone();
        forged["command"]["goalID"] = json!("forged");
        assert_eq!(
            call(&mut db, "world_control_command", forged),
            Err("world_control_unauthorized")
        );
        assert!(call(&mut db, "world_control_command", p).is_ok());
        let mut cancel = identity();
        cancel["eventID"] = json!("e");
        crate::agent_scheduler::request(&mut db, "agent_loop_cancel", &cancel).unwrap();
        let pending = json!({"requestID":"cancelled","expectedRevision":2,"command":{"op":"goal","goalID":"proven","summary":"ledger input"},"authority":{"kind":"agent","runID":"r","callID":"c","operationID":"o"}});
        assert_eq!(
            call(&mut db, "world_control_command", pending),
            Err("world_control_unauthorized")
        );
    }
    #[test]
    fn ordinary_prop_and_activity_commits_cannot_forge_owned_fields() {
        let (mut db, _) = setup();
        for field in ["weather", "liveCamera", "completedGoals"] {
            for owner in 0..3 {
                let tx = db.transaction().unwrap();
                let mut state = snapshot(&tx, "fixture").unwrap()["record"]["state"].clone();
                state[field] = json!({"forged":true});
                let req = world::CommitRequest {
                    world_id: "fixture".into(),
                    request_id: format!("forged-{field}-{owner}"),
                    expected_revision: 1,
                    producer: Some("world.control".into()),
                    intent: None,
                    ops: vec![world::Op {
                        op: "replaceState".into(),
                        state: Some(state),
                        ..Default::default()
                    }],
                };
                let result = match owner {
                    0 => world::commit(&tx, &req),
                    1 => world::commit_prop(&tx, &req),
                    _ => world::commit_activity(&tx, &req),
                };
                assert_eq!(result, Err("world_control_owned_projection"));
            }
            let tx = db.transaction().unwrap();
            let req = world::CommitRequest {
                world_id: "fixture".into(),
                request_id: format!("facts-{field}"),
                expected_revision: 1,
                producer: None,
                intent: None,
                ops: vec![world::Op {
                    op: "setWorldFacts".into(),
                    facts: Some(json!({(field):{"forged":true}})),
                    ..Default::default()
                }],
            };
            assert_eq!(
                world::commit(&tx, &req),
                Err("world_control_owned_projection")
            );
        }
    }
}
