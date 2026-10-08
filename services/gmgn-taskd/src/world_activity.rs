//! Navigation decisions. Native collision queries are evidence, not a second router.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS world_activity_runs(world_id TEXT PRIMARY KEY,payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS world_activity_commands(world_id TEXT NOT NULL,request_id TEXT NOT NULL,input TEXT NOT NULL,output TEXT NOT NULL,PRIMARY KEY(world_id,request_id));")
        .map_err(|_|"storage_unavailable")
}
fn token<'a>(input: &'a Value, key: &str) -> Result<&'a str> {
    input[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 200)
        .ok_or("world_activity_invalid_input")
}
fn now_ms() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|v| v.as_millis() as u64)
        .map_err(|_| "world_activity_clock_unavailable")
}
fn elapsed_value(milliseconds: u64) -> Value {
    if milliseconds % 1000 == 0 {
        json!(milliseconds / 1000)
    } else {
        json!(milliseconds as f64 / 1000.0)
    }
}
fn load_run(c: &Connection, world: &str) -> Result<Value> {
    let raw: Option<String> = c
        .query_row(
            "SELECT payload FROM world_activity_runs WHERE world_id=?1",
            [world],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    raw.map(|s|serde_json::from_str(&s).map_err(|_|"world_activity_invalid_state"))
        .unwrap_or_else(||Ok(json!({"worldID":world,"generation":0,"hostSessionID":"","definitions":[],"run":null,"suspended":[],"cooldowns":{}})))
}
fn save_run(c: &Connection, world: &str, state: &Value) -> Result<()> {
    c.execute("INSERT INTO world_activity_runs(world_id,payload) VALUES(?1,?2) ON CONFLICT(world_id) DO UPDATE SET payload=excluded.payload",
        params![world,crate::canonical_json::to_string(state).map_err(|_|"world_activity_invalid_state")?]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn set_phase(run: &mut Value, phase: &str, now: u64) -> Result<()> {
    run["phase"] = json!(phase);
    run["phaseGeneration"] = json!(run["phaseGeneration"]
        .as_u64()
        .unwrap_or(0)
        .checked_add(1)
        .ok_or("world_activity_revision_overflow")?);
    let duration = run["definition"]["phases"]
        .as_array()
        .and_then(|p| p.iter().find(|p| p["phase"] == phase))
        .and_then(|p| p["durationSeconds"].as_f64());
    run["deadlineMs"] = duration
        .filter(|d| d.is_finite() && *d >= 0.0)
        .map(|d| json!(now.saturating_add((d * 1000.0) as u64)))
        .unwrap_or(Value::Null);
    let has_motion = run["definition"]["phases"]
        .as_array()
        .and_then(|p| p.iter().find(|p| p["phase"] == phase))
        .and_then(|p| p["motionIDs"].as_array())
        .is_some_and(|m| !m.is_empty());
    run["deadlineEligible"] = json!(
        !run["deadlineMs"].is_null() && !(run["waitsForRenderedCompletion"] == true && has_motion)
    );
    run["alignmentYaw"] = if phase == "enter" {
        run["targetYaw"].clone()
    } else {
        Value::Null
    };
    Ok(())
}
fn resume_or_idle(state: &mut Value, now: u64, outcome: &str) -> Result<()> {
    let completed = state["run"].take();
    state["lastTerminal"] = json!({"requestID":completed["requestID"],"activityID":completed["definition"]["id"],"generation":completed["generation"],"outcome":outcome,"atMs":now});
    if let Some(id) = completed["definition"]["id"].as_str() {
        let seconds = completed["definition"]["cooldownSeconds"]
            .as_f64()
            .unwrap_or(0.0)
            .max(0.0);
        state["cooldowns"][id] = json!(now.saturating_add((seconds * 1000.0) as u64));
    }
    let prior = state["suspended"].as_array_mut().and_then(Vec::pop);
    if let Some(mut prior) = prior {
        let generation = state["generation"]
            .as_u64()
            .unwrap_or(0)
            .checked_add(1)
            .ok_or("world_activity_revision_overflow")?;
        state["generation"] = json!(generation);
        prior["generation"] = json!(generation);
        prior["status"] = json!("running");
        let phase = prior["phase"].as_str().unwrap_or("enter").to_owned();
        set_phase(&mut prior, &phase, now)?;
        state["run"] = prior;
    } else {
        state["run"] = Value::Null;
    }
    Ok(())
}

// A catalog binding is a native observed capability, never a model supplied
// usage command. Revalidate it against the actual checkpoint before writing.
fn project_usage(checkpoint: &mut Value, state: &Value, run: &Value, status: &str) -> Result<()> {
    let Some(id) = run["definition"]["id"].as_str() else {
        return Ok(());
    };
    let Some(binding) = run
        .get("usageBinding")
        .filter(|v| v.is_object())
        .or_else(|| state["usageBindings"].get(id))
    else {
        return Ok(());
    };
    let object_id = token(binding, "objectID")?;
    let template = token(binding, "templateID")?;
    let item = &checkpoint["objectStates"][object_id];
    let decode = |key: &str| -> Result<Value> {
        serde_json::from_str(
            item["metadata"][key]
                .as_str()
                .ok_or("world_activity_invalid_state")?,
        )
        .map_err(|_| "world_activity_invalid_state")
    };
    let generated = decode("gmgn.generated-prop.v1")?;
    let capability = decode("gmgn.prop-capability.v1")?;
    if generated["objectID"] != object_id
        || capability["objectID"] != object_id
        || capability["templateID"] != template
    {
        return Err("world_activity_invalid_state");
    }
    // Embedded metadata has always used Foundation's default Date encoding,
    // unlike the outer RPC document which uses milliseconds since Unix epoch.
    let date = checkpoint["worldTime"]
        .as_f64()
        .ok_or("world_activity_invalid_state")?
        / 1000.0
        - 978307200.0;
    let usage = json!({"templateID":template,"status":status,"activityRequestID":run["requestID"],"updatedAt":date});
    checkpoint["objectStates"][object_id]["metadata"]["gmgn.prop-usage.v1"] = json!(
        crate::canonical_json::to_string(&usage).map_err(|_| "world_activity_invalid_state")?
    );
    Ok(())
}

/// All activity mutations and their world projection share the Store's single
/// transaction. A renderer receipt is fenced by host, run, generation and phase.
/// Read-only plan selection. Collision answers carry the exact requested
/// geometry; native never supplies a selected path or facing direction.
fn approach_binding(catalog: &Value, state: &Value, id: &str) -> Result<Option<Value>> {
    if let Some(binding) = catalog["usageBindings"].get(id) {
        return Ok(Some(
            json!({"kind":"capability","objectID":token(binding,"objectID")?}),
        ));
    }
    let mut found = None;
    for (object, item) in state["objectStates"]
        .as_object()
        .ok_or("world_activity_invalid_state")?
    {
        if item["isEnabled"] != true {
            continue;
        }
        if id == format!("prop.seat.{object}")
            && item["metadata"]
                .get(crate::world::GENERATED_PROP_KEY)
                .is_some()
        {
            if found
                .replace(json!({"kind":"seat","objectID":object}))
                .is_some()
            {
                return Err("world_activity_plan_binding_conflict");
            }
        }
        if let Some(raw) = item["metadata"]["gmgn.prop-function-points.v1"].as_str() {
            let declaration: Value =
                serde_json::from_str(raw).map_err(|_| "world_activity_invalid_state")?;
            if declaration["objectID"] != *object {
                return Err("world_activity_invalid_state");
            }
            for point in declaration["functionPoints"]
                .as_array()
                .ok_or("world_activity_invalid_state")?
            {
                if point["activityID"] == id
                    && (point["kind"].is_null() || point["kind"] == "standingSpot")
                {
                    let binding = json!({"kind":"functionPoint","objectID":object,"role":token(point,"role")?});
                    if found.replace(binding).is_some() {
                        return Err("world_activity_plan_binding_conflict");
                    }
                }
            }
        }
    }
    Ok(found)
}
// WorldVector3 on the native wire is IEEE Float. Compare its exact typed value,
// not the incidental JSON decimal spelling after f32 -> Value promotion.
fn native_physics_point(value: &Value) -> Result<[f32; 3]> {
    let coordinates = point(value)?.map(|coordinate| coordinate as f32);
    if coordinates.iter().any(|coordinate| !coordinate.is_finite()) {
        return Err("world_activity_invalid_physics");
    }
    Ok(coordinates)
}
pub fn prepare(db: &Connection, input: &Value) -> Result<Value> {
    let world = token(input, "worldID")?;
    let host = token(input, "hostSessionID")?;
    let catalog = load_run(db, world)?;
    if catalog["hostSessionID"] != host {
        return Err("world_activity_stale_session");
    }
    let snapshot = crate::world::snapshot(
        db,
        &crate::world::SnapshotRequest {
            world_id: world.into(),
            include_state: Some(true),
        },
    )?;
    let current = &snapshot["record"]["state"];
    if input["expectedRevision"] != snapshot["record"]["recordRevision"]
        || input["expectedLayoutRevision"] != current["layoutRevision"]
    {
        return Err("revision_conflict");
    }
    let checkpoint = &input["checkpoint"];
    if checkpoint["worldID"] != world || checkpoint["activeActivity"] != current["activeActivity"] {
        return Err("world_activity_owned_projection");
    }
    let start = &checkpoint["agentTransform"]["position"];
    point(start)?;
    let id = token(input, "definitionID")?;
    let definition = catalog["definitions"]
        .as_array()
        .and_then(|d| d.iter().find(|d| d["id"] == id))
        .ok_or("world_activity_unknown_definition")?;
    let kind = token(&definition["activity"], "type")?;
    let approaching = !matches!(kind, "idle" | "turn");
    let mut target_yaw = if kind == "turn" {
        definition["activity"]["targetYaw"].clone()
    } else {
        Value::Null
    };
    let mut entry = String::new();
    let mut final_target = Value::Null;
    if approaching {
        if let Some(binding) = approach_binding(&catalog, current, id)? {
            let binding_kind = token(&binding, "kind")?;
            let mut p = json!({"worldID":world,"hostSessionID":host,"objectID":token(&binding,"objectID")?,"expectedLayoutRevision":current["layoutRevision"],"waypoints":catalog["waypoints"],"kind":binding_kind,"role":binding["role"],"activityID":id,"capsuleRadius":input["capsuleRadius"]});
            let (plan_method, resolve_method) = if binding_kind == "capability" {
                (
                    "world_prop_capability_plan",
                    "world_prop_capability_resolve",
                )
            } else {
                (
                    "world_activity_approach_plan",
                    "world_activity_approach_resolve",
                )
            };
            let call = |method, p| {
                if binding_kind == "capability" {
                    crate::world_prop_capability::request(db, method, p)
                } else {
                    crate::world_activity_approach::request(db, method, p)
                }
            };
            let plan = call(plan_method, p.clone())?;
            if input["approachPhysics"].is_null() {
                return Ok(
                    json!({"stage":"approach","geometryID":plan["geometryID"],"probes":plan["probes"]}),
                );
            }
            p["geometryID"] = input["approachPhysics"]["geometryID"].clone();
            p["physics"] = input["approachPhysics"]["physics"].clone();
            let resolved = call(resolve_method, p)?;
            let target = &resolved["target"];
            if target.is_null() {
                return Err("world_activity_plan_unreachable");
            }
            entry = token(target, "waypointID")?.into();
            final_target = target["approachPoint"].clone();
            target_yaw = target["targetYaw"].clone();
        } else {
            let anchor = catalog["authoredActivities"]
                .as_array()
                .and_then(|a| a.iter().find(|a| a["id"] == id))
                .ok_or("world_activity_plan_binding_missing")?;
            entry = token(anchor, "entryWaypointID")?.into();
            let q = &anchor["transform"]["rotation"];
            let x = q["x"]
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("world_activity_invalid_position")?;
            let y = q["y"]
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("world_activity_invalid_position")?;
            let w = q["w"]
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("world_activity_invalid_position")?;
            let z = q["z"]
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("world_activity_invalid_position")?;
            target_yaw = json!((2. * (w * y + x * z)).atan2(1. - 2. * (y * y + z * z)));
        }
    }
    let mut path = json!({"destinationID":if entry.is_empty(){id}else{entry.as_str()},"waypointIDs":[],"points":[],"totalLength":0,"arrivalTolerance":0.02});
    if approaching {
        let mut route_input = json!({"start":start,"destinationID":entry,"waypoints":catalog["waypoints"],"routes":catalog["routes"],"facts":{}});
        let proofs = input
            .get("traversal")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if proofs.len() > 4096 {
            return Err("world_activity_invalid_physics");
        }
        let mut used = BTreeSet::new();
        for _ in 0..4097 {
            let decision = route(&route_input)?;
            if let Some(probes) = decision.get("probes").and_then(Value::as_array) {
                let mut missing = Vec::new();
                for probe in probes {
                    let key = token(probe, "key")?;
                    let matches: Vec<_> = proofs.iter().filter(|p| p["key"] == key).collect();
                    if matches.is_empty() {
                        missing.push(probe.clone());
                        continue;
                    }
                    if matches.len() != 1
                        || native_physics_point(&matches[0]["from"])?
                            != native_physics_point(&probe["from"])?
                        || native_physics_point(&matches[0]["to"])?
                            != native_physics_point(&probe["to"])?
                        || !matches[0]["canTraverse"].is_boolean()
                    {
                        return Err("world_activity_invalid_physics");
                    }
                    route_input["facts"][key] = matches[0]["canTraverse"].clone();
                    used.insert(key.to_owned());
                }
                if !missing.is_empty() {
                    return Ok(json!({"stage":"route","probes":missing}));
                }
            } else {
                path = decision
                    .get("route")
                    .cloned()
                    .ok_or("world_activity_plan_unreachable")?;
                break;
            }
        }
        if !final_target.is_null() {
            let from = path["points"]
                .as_array()
                .and_then(|p| p.last())
                .unwrap_or(start);
            let key = json!(["activity-final", id]).to_string();
            let required = probe(&key, from, &final_target);
            let final_proofs: Vec<_> = proofs.iter().filter(|p| p["key"] == key).collect();
            if final_proofs.is_empty() {
                return Ok(json!({"stage":"route","probes":[required]}));
            }
            if final_proofs.len() != 1
                || native_physics_point(&final_proofs[0]["from"])? != native_physics_point(from)?
                || native_physics_point(&final_proofs[0]["to"])?
                    != native_physics_point(&final_target)?
                || !final_proofs[0]["canTraverse"].is_boolean()
            {
                return Err("world_activity_invalid_physics");
            }
            if final_proofs[0]["canTraverse"] != true {
                return Err("world_activity_plan_unreachable");
            }
            used.insert(key);
            let mut extension = json!({"baseRoute":path,"start":start,"destinationID":entry,"destinationKind":"generated","finalTarget":final_target,"facts":{}});
            let proposed = route(&extension)?;
            if let Some(probes) = proposed["probes"].as_array() {
                for probe in probes {
                    let key = token(probe, "key")?;
                    let proof = proofs.iter().find(|p| p["key"] == key);
                    let Some(proof) = proof else {
                        return Ok(json!({"stage":"route","probes":probes}));
                    };
                    if native_physics_point(&proof["from"])?
                        != native_physics_point(&probe["from"])?
                        || native_physics_point(&proof["to"])?
                            != native_physics_point(&probe["to"])?
                        || !proof["canTraverse"].is_boolean()
                    {
                        return Err("world_activity_invalid_physics");
                    }
                    extension["facts"][key] = proof["canTraverse"].clone();
                    used.insert(key.to_owned());
                }
                path = route(&extension)?["route"].clone();
            } else {
                path = proposed["route"].clone();
            }
        }
        if used.len() != proofs.len() {
            return Err("world_activity_invalid_physics");
        }
    }
    let timestamp = input["preparedAtMS"].as_u64().unwrap_or(now_ms()?);
    if timestamp > now_ms()? || now_ms()?.saturating_sub(timestamp) > 10000 {
        return Err("world_activity_plan_expired");
    }
    let binding = json!({"worldID":world,"hostSessionID":host,"expectedRevision":input["expectedRevision"],"state":current,"catalog":catalog,"definitionID":id,"start":start,"path":path,"targetYaw":target_yaw,"preparedAtMS":timestamp,"approachPhysics":input["approachPhysics"],"traversal":input["traversal"]});
    let canonical =
        crate::canonical_json::to_string(&binding).map_err(|_| "world_activity_invalid_input")?;
    let hash = crate::model::digest(canonical.as_bytes());
    Ok(
        json!({"stage":"ready","planSHA256":hash,"preparedAtMS":timestamp,"entryWaypointID":entry,"path":path,"targetYaw":target_yaw,"definition":definition}),
    )
}
pub fn request(tx: &Transaction<'_>, method: &str, input: Value) -> Result<Value> {
    if method == "world_activity_prepare" {
        return prepare(tx, &input);
    }
    // Existing exact receipts are checked below before preparation on replay.
    let world = token(&input, "worldID")?;
    let mut state = load_run(tx, world)?;
    if method == "world_activity_read" {
        return Ok(json!({"activity":state}));
    }
    let host = token(&input, "hostSessionID")?;
    let request_id = token(&input, "requestID")?;
    let canonical = crate::canonical_json::to_string(&json!({"method":method,"input":input}))
        .map_err(|_| "world_activity_invalid_input")?;
    let recorded: Option<(String, String)> = tx
        .query_row(
            "SELECT input,output FROM world_activity_commands WHERE world_id=?1 AND request_id=?2",
            params![world, request_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((old, output)) = recorded {
        if old != canonical {
            return Err("world_activity_request_conflict");
        }
        let mut output: Value =
            serde_json::from_str(&output).map_err(|_| "world_activity_invalid_state")?;
        output["activity"] = state;
        output["replayed"] = json!(true);
        output["snapshot"] = crate::world::snapshot(
            tx,
            &crate::world::SnapshotRequest {
                world_id: world.to_owned(),
                include_state: Some(true),
            },
        )?;
        return Ok(output);
    }
    let now = now_ms()?;
    let mut events = Vec::<Value>::new();
    if method == "world_activity_bind_catalog" {
        let catalog = crate::activity::request(
            "activity_catalog_build",
            json!({"authoredDefinitions":input["definitions"],"dynamicDefinitions":[]}),
        )?;
        if state["hostSessionID"] != host && state["run"].is_object() {
            // Restart is unknown until explicit native verification; do not
            // manufacture an arrival or rendered completion from a snapshot.
            state["run"]["status"] = json!("unknown");
            state["suspended"] = json!([]);
        }
        state["hostSessionID"] = json!(host);
        state["definitions"] = catalog["definitions"].clone();
        state["waypoints"] = input.get("waypoints").cloned().unwrap_or_else(|| json!([]));
        for key in ["routes", "authoredActivities"] {
            let raw = input
                .get(key)
                .cloned()
                .unwrap_or_else(|| state.get(key).cloned().unwrap_or_else(|| json!([])));
            if raw.as_array().is_none_or(|a| a.len() > 4096) {
                return Err("world_activity_invalid_input");
            }
            state[key] = raw;
        }
        let bindings = input
            .get("usageBindings")
            .cloned()
            .unwrap_or_else(|| json!({}));
        for (id, binding) in bindings.as_object().ok_or("world_activity_invalid_input")? {
            if !state["definitions"]
                .as_array()
                .is_some_and(|defs| defs.iter().any(|d| d["id"] == *id))
            {
                return Err("world_activity_unknown_definition");
            }
            token(binding, "objectID")?;
            token(binding, "templateID")?;
        }
        state["usageBindings"] = bindings;
    } else {
        if state["hostSessionID"] != host {
            return Err("world_activity_stale_session");
        }
        let expected = input["expectedRevision"]
            .as_i64()
            .filter(|v| *v >= 0)
            .ok_or("invalid_revision")?;
        let snapshot = crate::world::snapshot(
            tx,
            &crate::world::SnapshotRequest {
                world_id: world.to_owned(),
                include_state: Some(true),
            },
        )?;
        if snapshot["record"]["recordRevision"] != expected {
            return Err("revision_conflict");
        }
        let mut checkpoint = input["checkpoint"].clone();
        if checkpoint["worldID"] != world
            || checkpoint["activeActivity"] != snapshot["record"]["state"]["activeActivity"]
        {
            return Err("world_activity_owned_projection");
        }
        point(&checkpoint["agentTransform"]["position"])?;
        let prior_run = state["run"].clone();
        match method {
            "world_activity_start" | "world_activity_move" => {
                let movement = method == "world_activity_move";
                let prepared = if !movement {
                    if input.get("path").is_some() || input.get("targetYaw").is_some() {
                        return Err("world_activity_host_plan_rejected");
                    }
                    let p = prepare(tx, &input)?;
                    if p["stage"] != "ready" {
                        return Err("world_activity_plan_not_ready");
                    }
                    if input["planSHA256"] != p["planSHA256"] {
                        return Err("world_activity_plan_changed");
                    }
                    Some(p)
                } else {
                    None
                };
                let selected_path = prepared
                    .as_ref()
                    .map(|p| &p["path"])
                    .unwrap_or(&input["path"]);
                if !movement && checkpoint.get("heldProp").is_some_and(|v| !v.is_null()) {
                    return Err("held_prop_conflict");
                }
                let id = if movement {
                    "world.movement"
                } else {
                    token(&input, "definitionID")?
                };
                let definition = if movement {
                    let destination = token(&input["path"], "destinationID")?;
                    let phases=["approach","enter","loop","exit","interrupt","failed"].map(|phase|json!({"phase":phase,"requiredAnchorIDs":[],"propIDs":[],"motionIDs":if phase=="approach" {json!(["gmgn.motion.bones.walk-loop-pmx","gmgn.motion.bones.walk-loop-vrm"])}else{json!([])}}));
                    json!({"id":id,"activity":{"type":"walk","destinationID":destination},"interruptible":true,"cooldownSeconds":0,
                        "phases":phases})
                } else {
                    state["definitions"]
                        .as_array()
                        .and_then(|defs| defs.iter().find(|d| d["id"] == id))
                        .cloned()
                        .ok_or("world_activity_unknown_definition")?
                };
                if state["cooldowns"][id].as_u64().unwrap_or(0) > now {
                    return Err("world_activity_cooldown_active");
                }
                let priority = input["priority"]
                    .as_u64()
                    .filter(|v| *v <= 5)
                    .ok_or("world_activity_invalid_priority")?;
                if state["run"].is_object() && state["run"]["status"] == "running" {
                    if !movement && state["run"]["definition"]["interruptible"] != true {
                        return Err("world_activity_not_interruptible");
                    }
                    let current_priority = state["run"]["priority"]
                        .as_u64()
                        .ok_or("world_activity_invalid_state")?;
                    if movement || priority == 0 && current_priority == 0 {
                        state["suspended"] = json!([]);
                    } else if priority < current_priority {
                        let prior = state["run"].clone();
                        state["suspended"]
                            .as_array_mut()
                            .ok_or("world_activity_invalid_state")?
                            .push(prior);
                    } else {
                        return Err("world_activity_lower_priority");
                    }
                } else {
                    state["suspended"] = json!([]);
                }
                let generation = state["generation"]
                    .as_u64()
                    .unwrap_or(0)
                    .checked_add(1)
                    .ok_or("world_activity_revision_overflow")?;
                let kind = definition["activity"]["type"]
                    .as_str()
                    .ok_or("world_activity_invalid_definition")?;
                let approach = !matches!(kind, "idle" | "turn");
                let target_yaw = if kind == "turn" {
                    definition["activity"]["targetYaw"].clone()
                } else {
                    prepared
                        .as_ref()
                        .map(|p| p["targetYaw"].clone())
                        .unwrap_or_else(|| input["targetYaw"].clone())
                };
                if !target_yaw.is_null() && target_yaw.as_f64().is_none_or(|v| !v.is_finite()) {
                    return Err("world_activity_invalid_position");
                }
                let points = selected_path["points"]
                    .as_array()
                    .ok_or("world_activity_invalid_path")?;
                for p in points {
                    point(p)?;
                }
                if points.len() > 4096 {
                    return Err("world_activity_invalid_path");
                }
                let target = points
                    .last()
                    .cloned()
                    .unwrap_or_else(|| checkpoint["agentTransform"]["position"].clone());
                state["generation"] = json!(generation);
                let run_request = if movement {
                    input["movementRequestID"]
                        .as_str()
                        .filter(|s| !s.is_empty() && s.len() <= 256)
                        .ok_or("world_activity_invalid_input")?
                } else {
                    request_id
                };
                let mut run = json!({"requestID":run_request,"hostSessionID":host,"generation":generation,"phaseGeneration":0,
                    "definition":definition,"priority":priority,"status":"running","path":selected_path,"target":target,
                    "arrivalTolerance":if movement {input["path"]["arrivalTolerance"].clone()}else{json!(0.02)},"targetYaw":target_yaw,"startedAt":checkpoint["worldTime"],"startedAtMs":now,"waitsForRenderedCompletion":input["waitsForRenderedCompletion"],"patrolVisits":{},"activity":definition["activity"],"kind":if movement {"movement"}else{"activity"},"replansRemaining":1,"coordinateTarget":input["coordinateTarget"]});
                set_phase(&mut run, if approach { "approach" } else { "enter" }, now)?;
                if let Some(binding) = state["usageBindings"].get(id) {
                    run["usageBinding"] = binding.clone();
                }
                state["run"] = run;
            }
            "world_activity_receipt"
            | "world_activity_stop"
            | "world_activity_continue"
            | "world_activity_replan" => {
                let run = &state["run"];
                let unknown_stop = method == "world_activity_stop"
                    && input["reconcileUnknown"] == true
                    && (run.is_null() || run["status"] == "unknown")
                    && input["generation"] == state["generation"];
                if !unknown_stop
                    && (!run.is_object()
                        || !(run["status"] == "running"
                            || run["status"] == "replanRequired"
                                && (method == "world_activity_replan"
                                    || method == "world_activity_stop"
                                    || input["kind"] == "failed"))
                        || run["hostSessionID"] != host
                        || run["requestID"] != input["runRequestID"]
                        || run["generation"] != input["generation"]
                        || run["phaseGeneration"] != input["phaseGeneration"]
                        || run["phase"] != input["phase"])
                {
                    return Err("world_activity_stale_receipt");
                }
                if method == "world_activity_replan" {
                    if run["kind"] != "movement"
                        || input["path"]["destinationID"] != run["path"]["destinationID"]
                    {
                        return Err("world_activity_invalid_path");
                    }
                    let points = input["path"]["points"]
                        .as_array()
                        .filter(|p| p.len() <= 4096)
                        .ok_or("world_activity_invalid_path")?;
                    for p in points {
                        point(p)?;
                    }
                    let target = points
                        .last()
                        .cloned()
                        .unwrap_or_else(|| checkpoint["agentTransform"]["position"].clone());
                    state["run"]["path"] = input["path"].clone();
                    state["run"]["target"] = target;
                    state["run"]["arrivalTolerance"] = input["path"]["arrivalTolerance"].clone();
                    state["run"]["status"] = json!("running");
                    set_phase(&mut state["run"], "approach", now)?;
                } else if method == "world_activity_continue" {
                    let candidates = run["patrolCandidates"]
                        .as_array()
                        .ok_or("world_activity_invalid_receipt")?;
                    let target_id = token(&input, "targetID")?;
                    if input["path"]["destinationID"] != target_id {
                        return Err("world_activity_invalid_path");
                    }
                    let rejected = input["rejectedTargets"]
                        .as_array()
                        .ok_or("world_activity_invalid_receipt")?;
                    if candidates.iter().take(rejected.len()).ne(rejected.iter())
                        || candidates.get(rejected.len()) != Some(&json!(target_id))
                    {
                        return Err("world_activity_invalid_receipt");
                    }
                    let points = input["path"]["points"]
                        .as_array()
                        .filter(|p| p.len() <= 4096)
                        .ok_or("world_activity_invalid_path")?;
                    for p in points {
                        point(p)?;
                    }
                    let target = points
                        .last()
                        .cloned()
                        .unwrap_or_else(|| checkpoint["agentTransform"]["position"].clone());
                    state["run"]["path"] = input["path"].clone();
                    state["run"]["target"] = target;
                    state["run"]["targetYaw"] = Value::Null;
                    state["run"]["patrolCandidates"] = Value::Null;
                    state["run"]["activity"] = json!({"type":"walk","destinationID":target_id});
                    set_phase(&mut state["run"], "approach", now)?;
                } else if method == "world_activity_stop" {
                    state["suspended"] = json!([]);
                    resume_or_idle(&mut state, now, "stopped")?;
                } else {
                    let phase = run["phase"]
                        .as_str()
                        .ok_or("world_activity_invalid_state")?
                        .to_owned();
                    match input["kind"]
                        .as_str()
                        .ok_or("world_activity_invalid_receipt")?
                    {
                        "arrived" => {
                            if phase != "approach" {
                                return Err("world_activity_stale_receipt");
                            }
                            if distance(
                                point(&checkpoint["agentTransform"]["position"])?,
                                point(&run["target"])?,
                            ) > run["arrivalTolerance"].as_f64().unwrap_or(0.02)
                            {
                                return Err("world_activity_not_arrived");
                            }
                            if run["kind"] == "movement" {
                                resume_or_idle(&mut state, now, "completed")?;
                            } else if run["definition"]["id"] == "home.walk" {
                                let reached = run["path"]["destinationID"]
                                    .as_str()
                                    .ok_or("world_activity_invalid_state")?
                                    .to_owned();
                                let visits = run["patrolVisits"][&reached]
                                    .as_u64()
                                    .unwrap_or(0)
                                    .saturating_add(1);
                                state["run"]["patrolVisits"][&reached] = json!(visits);
                                let pose = point(&checkpoint["agentTransform"]["position"])?;
                                let mut candidates: Vec<(String, u64, f64)> = Vec::new();
                                for waypoint in state["waypoints"]
                                    .as_array()
                                    .ok_or("world_activity_invalid_state")?
                                {
                                    if waypoint["enabled"] != true {
                                        continue;
                                    }
                                    let id = token(waypoint, "id")?;
                                    let xyz = point(&waypoint["position"])?;
                                    let length = ((pose[0] - xyz[0]).powi(2)
                                        + (pose[2] - xyz[2]).powi(2))
                                    .sqrt();
                                    if id != reached && (1.0..=6.0).contains(&length) {
                                        candidates.push((
                                            id.to_owned(),
                                            state["run"]["patrolVisits"][id].as_u64().unwrap_or(0),
                                            (length - 3.0).abs(),
                                        ));
                                    }
                                }
                                candidates.sort_by(|a, b| {
                                    a.1.cmp(&b.1).then(a.2.total_cmp(&b.2)).then(a.0.cmp(&b.0))
                                });
                                state["run"]["patrolCandidates"] = json!(candidates
                                    .into_iter()
                                    .take(8)
                                    .map(|v| v.0)
                                    .collect::<Vec<_>>());
                                set_phase(&mut state["run"], "approach", now)?;
                            } else {
                                set_phase(&mut state["run"], "enter", now)?;
                            }
                        }
                        "failed" => {
                            resume_or_idle(&mut state, now, "failed")?;
                        }
                        "blocked" => {
                            if run["kind"] == "movement"
                                && run["replansRemaining"].as_u64().unwrap_or(0) > 0
                            {
                                state["run"]["replansRemaining"] = json!(0);
                                set_phase(&mut state["run"], "approach", now)?;
                                state["run"]["status"] = json!("replanRequired");
                            } else {
                                resume_or_idle(&mut state, now, "failed")?;
                            }
                        }
                        "clipCompleted" | "deadline" => {
                            if !matches!(phase.as_str(), "enter" | "loop" | "exit") {
                                return Err("world_activity_invalid_receipt");
                            }
                            let contract = run["definition"]["phases"]
                                .as_array()
                                .and_then(|ps| ps.iter().find(|p| p["phase"] == phase))
                                .ok_or("world_activity_invalid_state")?;
                            if phase == "loop"
                                && contract.get("durationSeconds").is_none_or(Value::is_null)
                            {
                                return Err("world_activity_infinite_loop");
                            }
                            if input["kind"] == "deadline" {
                                if run["deadlineMs"]
                                    .as_u64()
                                    .is_none_or(|deadline| now < deadline)
                                {
                                    return Err("world_activity_deadline_not_due");
                                }
                                if run["waitsForRenderedCompletion"] == true
                                    && contract["motionIDs"]
                                        .as_array()
                                        .is_some_and(|m| !m.is_empty())
                                {
                                    return Err("world_activity_renderer_receipt_required");
                                }
                            }
                            match phase.as_str() {
                                "enter" => set_phase(&mut state["run"], "loop", now)?,
                                "loop" => set_phase(&mut state["run"], "exit", now)?,
                                _ => resume_or_idle(&mut state, now, "completed")?,
                            }
                        }
                        _ => return Err("world_activity_invalid_receipt"),
                    }
                }
            }
            _ => return Err("unknown_method"),
        }
        let next_run = state["run"].clone();
        let changed_run = next_run["requestID"] != prior_run["requestID"]
            || next_run["generation"] != prior_run["generation"];
        let terminal = prior_run.is_object()
            && state["lastTerminal"].is_object()
            && state["lastTerminal"]["requestID"] == prior_run["requestID"]
            && state["lastTerminal"]["generation"] == prior_run["generation"];
        let mut kinds = Vec::<Value>::new();
        if prior_run.is_object()
            && (prior_run["status"] == "running"
                || prior_run["status"] == "replanRequired"
                || matches!(
                    method,
                    "world_activity_stop" | "world_activity_start" | "world_activity_move"
                ))
            && (next_run["requestID"] != prior_run["requestID"] || !next_run.is_object())
        {
            let outcome = if terminal {
                state["lastTerminal"]["outcome"]
                    .as_str()
                    .unwrap_or("stopped")
            } else {
                "stopped"
            };
            project_usage(&mut checkpoint, &state, &prior_run, outcome)?;
            if prior_run["kind"] == "movement" {
                let payload = json!({"requestID":prior_run["requestID"],"destinationID":prior_run["path"]["destinationID"]});
                if outcome == "completed" {
                    kinds.push(json!({"movementCompleted":payload}));
                } else if outcome == "failed" {
                    let mut payload = payload;
                    payload["reason"] = json!("executionFailed");
                    kinds.push(json!({"movementFailed":payload}));
                }
            } else {
                let id = prior_run["definition"]["id"].clone();
                kinds.push(match outcome {
                    "completed" => json!({"activityCompleted":{"activityID":id}}),
                    "failed" => {
                        json!({"activityFailed":{"activityID":id,"reason":"executionFailed"}})
                    }
                    _ if state["suspended"].as_array().is_some_and(|runs| {
                        runs.iter()
                            .any(|run| run["requestID"] == prior_run["requestID"])
                    }) =>
                    {
                        json!({"activityInterrupted":{"activityID":id,"reason":"higherPriority"}})
                    }
                    _ => json!({"activityCancelled":{"activityID":id}}),
                });
            }
        }
        if next_run.is_object()
            && next_run["status"] == "running"
            && (changed_run || prior_run["status"] != "running")
        {
            project_usage(&mut checkpoint, &state, &next_run, "running")?;
            if next_run["kind"] != "movement" {
                let id = next_run["definition"]["id"].clone();
                kinds.push(if terminal {
                    json!({"activityResumed":{"activityID":id}})
                } else {
                    json!({"activityStarted":{"activityID":id}})
                });
            }
        }
        checkpoint["activeActivity"] = if state["run"].is_object()
            && state["run"]["kind"] != "movement"
        {
            let elapsed_ms =
                now.saturating_sub(state["run"]["startedAtMs"].as_u64().unwrap_or(now));
            // Swift emits whole-valued Double times as integer JSON numbers.
            let elapsed = elapsed_value(elapsed_ms);
            json!({"activityID":state["run"]["definition"]["id"],"status":"running","startedAt":state["run"]["startedAt"],"elapsedActiveTime":elapsed})
        } else {
            Value::Null
        };
        checkpoint["revision"] = json!(checkpoint["revision"]
            .as_u64()
            .ok_or("invalid_revision")?
            .checked_add(1)
            .ok_or("world_activity_revision_overflow")?);
        crate::world::commit_activity(
            tx,
            &crate::world::CommitRequest {
                world_id: world.to_owned(),
                request_id: request_id.to_owned(),
                expected_revision: expected,
                producer: Some("world.activity".to_owned()),
                intent: Some(json!({"method":method})),
                ops: vec![crate::world::Op {
                    op: "replaceState".to_owned(),
                    state: Some(checkpoint.clone()),
                    ..Default::default()
                }],
            },
        )?;
        for (index, kind) in kinds.into_iter().enumerate() {
            let id = format!("activity:{request_id}:{index}");
            let payload = json!({"kind":kind,"worldTime":checkpoint["worldTime"],"revision":checkpoint["revision"]});
            tx.execute("INSERT INTO world_facts(world_id,id,kind,subject_domain,subject_key,revision,payload,producer,at_ms) VALUES(?1,?2,'activity.transition','worlds','state',?3,?4,'world.activity',?5)",
                params![world,id,expected+1,crate::canonical_json::to_string(&payload).map_err(|_|"world_activity_invalid_state")?,now]).map_err(|_|"storage_unavailable")?;
            let sequence: i64 = tx
                .query_row(
                    "SELECT seq FROM world_facts WHERE world_id=?1 AND id=?2",
                    params![world, id],
                    |r| r.get(0),
                )
                .map_err(|_| "storage_unavailable")?;
            events.push(json!({"sequence":sequence,"revision":checkpoint["revision"],"worldTime":checkpoint["worldTime"],"kind":kind}));
        }
    }
    save_run(tx, world, &state)?;
    let output = json!({"activity":state,"events":events,"snapshot":crate::world::snapshot(tx,&crate::world::SnapshotRequest{world_id:world.to_owned(),include_state:Some(true)})?});
    tx.execute(
        "INSERT INTO world_activity_commands(world_id,request_id,input,output) VALUES(?1,?2,?3,?4)",
        params![
            world,
            request_id,
            canonical,
            crate::canonical_json::to_string(&output)
                .map_err(|_| "world_activity_invalid_state")?
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(output)
}

#[derive(Clone)]
struct Node {
    id: String,
    point: Value,
    xyz: [f64; 3],
    radius: f64,
}
fn point(v: &Value) -> Result<[f64; 3]> {
    let mut p = [0.0; 3];
    for (i, key) in ["x", "y", "z"].iter().enumerate() {
        p[i] = v[key]
            .as_f64()
            .filter(|n| n.is_finite())
            .ok_or("world_activity_invalid_position")?;
    }
    Ok(p)
}
fn distance(a: [f64; 3], b: [f64; 3]) -> f64 {
    a.iter()
        .zip(b)
        .map(|(a, b)| (a - b) * (a - b))
        .sum::<f64>()
        .sqrt()
}
fn probe(key: &str, from: &Value, to: &Value) -> Value {
    json!({"key":key,"from":from,"to":to})
}

/// Repeated calls share an immutable graph and measured segment facts. Each
/// response asks only for collision evidence on the selected candidate route.
pub fn route(input: &Value) -> Result<Value> {
    if input.get("baseRoute").is_some() {
        let mut route = input["baseRoute"].clone();
        let destination = token(input, "destinationID")?;
        let mut points = route["points"]
            .as_array()
            .cloned()
            .ok_or("world_activity_invalid_path")?;
        let mut ids = route["waypointIDs"]
            .as_array()
            .cloned()
            .ok_or("world_activity_invalid_path")?;
        let mut length = route["totalLength"]
            .as_f64()
            .filter(|v| v.is_finite() && *v >= 0.0)
            .ok_or("world_activity_invalid_path")?;
        let tolerance = route["arrivalTolerance"]
            .as_f64()
            .filter(|v| v.is_finite() && *v >= 0.0)
            .ok_or("world_activity_invalid_path")?;
        if !input["finalTarget"].is_null() {
            let target = point(&input["finalTarget"])?;
            let prior = point(points.last().unwrap_or(&input["start"]))?;
            length += distance(prior, target);
            points.push(input["finalTarget"].clone());
            ids.push(json!(destination));
        }
        route["destinationID"] = json!(destination);
        route["points"] = json!(points);
        route["waypointIDs"] = json!(ids);
        route["totalLength"] = json!(length);
        route["arrivalTolerance"] = json!(match input["destinationKind"].as_str() {
            Some("generated") => 0.05,
            Some("device") => tolerance.min(0.05),
            _ => return Err("world_activity_invalid_destination"),
        });
        return Ok(json!({"route":route}));
    }
    if input.get("coordinateTarget").is_some() {
        return coordinate_route(input);
    }
    waypoint_route(input)
}
fn coordinate_route(input: &Value) -> Result<Value> {
    let target = point(&input["coordinateTarget"])?;
    let ground = input["coordinateGroundHeight"]
        .as_f64()
        .filter(|v| v.is_finite())
        .ok_or("world_coordinate_missing_ground")?;
    if (target[1] - ground).abs() > 0.05 {
        return Err("world_coordinate_off_ground");
    }
    if input["coordinateOccupable"] != true {
        return Err("world_coordinate_occupied");
    }
    if input["startOccupable"] != true {
        return Err("world_coordinate_blocked");
    }
    let start = point(&input["start"])?;
    let target_point = json!({"x":target[0],"y":ground,"z":target[2]});
    let target_xyz = [target[0], ground, target[2]];
    let facts = input["facts"]
        .as_object()
        .ok_or("world_activity_invalid_facts")?;
    let direct_key = json!(["coordinateDirect"]).to_string();
    match facts.get(&direct_key).and_then(Value::as_bool) {
        None => return Ok(json!({"probes":[probe(&direct_key,&input["start"],&target_point)]})),
        Some(true) => {
            return Ok(
                json!({"route":{"destinationID":token(input,"destinationID")?,"waypointIDs":[],"points":[target_point],"totalLength":distance(start,target_xyz),"arrivalTolerance":0.02}}),
            )
        }
        Some(false) => {}
    }
    let mut best: Option<Value> = None;
    for waypoint in input["waypoints"]
        .as_array()
        .ok_or("world_activity_invalid_graph")?
    {
        if waypoint["enabled"] != true {
            continue;
        }
        let id = token(waypoint, "id")?;
        let mut candidate_input = input.clone();
        candidate_input["destinationID"] = json!(id);
        let candidate = match waypoint_route(&candidate_input) {
            Ok(candidate) => candidate,
            Err("world_activity_unreachable" | "world_activity_unknown_destination") => continue,
            Err(error) => return Err(error),
        };
        if candidate.get("probes").is_some() {
            return Ok(candidate);
        }
        let last = candidate["route"]["points"]
            .as_array()
            .and_then(|p| p.last())
            .unwrap_or(&input["start"]);
        let final_key = json!(["coordinateFinal", id]).to_string();
        match facts.get(&final_key).and_then(Value::as_bool) {
            None => return Ok(json!({"probes":[probe(&final_key,last,&target_point)]})),
            Some(false) => continue,
            Some(true) => {}
        }
        let length = candidate["route"]["totalLength"]
            .as_f64()
            .ok_or("world_activity_invalid_state")?
            + distance(point(last)?, target_xyz);
        if best
            .as_ref()
            .is_none_or(|b| length < b["totalLength"].as_f64().unwrap_or(f64::INFINITY))
        {
            let mut route = candidate["route"].clone();
            route["destinationID"] = input["destinationID"].clone();
            route["points"]
                .as_array_mut()
                .ok_or("world_activity_invalid_state")?
                .push(target_point.clone());
            route["totalLength"] = json!(length);
            route["arrivalTolerance"] = json!(0.02);
            best = Some(route);
        }
    }
    best.map(|route| json!({"route":route}))
        .ok_or("world_coordinate_blocked")
}
fn waypoint_route(input: &Value) -> Result<Value> {
    let start = point(&input["start"])?;
    let destination = input["destinationID"]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("world_activity_invalid_destination")?;
    let mut nodes = Vec::<Node>::new();
    let mut ids = BTreeMap::new();
    for v in input["waypoints"]
        .as_array()
        .ok_or("world_activity_invalid_graph")?
    {
        let id = v["id"].as_str().ok_or("world_activity_invalid_graph")?;
        // Existing authored graph semantics: first declaration wins, including disabled.
        if ids.contains_key(id) {
            continue;
        }
        ids.insert(id.to_owned(), None);
        if v["enabled"].as_bool() != Some(true) {
            continue;
        }
        let xyz = point(&v["position"])?;
        let radius = v["arrivalRadius"]
            .as_f64()
            .filter(|x| x.is_finite())
            .ok_or("world_activity_invalid_graph")?
            .max(0.0);
        ids.insert(id.to_owned(), Some(nodes.len()));
        nodes.push(Node {
            id: id.to_owned(),
            point: v["position"].clone(),
            xyz,
            radius,
        });
    }
    if nodes.len() > 4096 {
        return Err("world_activity_graph_too_large");
    }
    let dest = ids
        .get(destination)
        .copied()
        .flatten()
        .ok_or("world_activity_unknown_destination")?;
    let facts = input["facts"]
        .as_object()
        .ok_or("world_activity_invalid_facts")?;
    if distance(start, nodes[dest].xyz) <= nodes[dest].radius {
        return Ok(
            json!({"route":{"destinationID":destination,"waypointIDs":[],"points":[],"totalLength":0,"arrivalTolerance":nodes[dest].radius}}),
        );
    }
    let mut edges = BTreeSet::new();
    for route in input["routes"]
        .as_array()
        .ok_or("world_activity_invalid_graph")?
    {
        if route["enabled"].as_bool() != Some(true) {
            continue;
        }
        let chain = route["waypointIDs"]
            .as_array()
            .ok_or("world_activity_invalid_graph")?;
        for pair in chain.windows(2) {
            let a = pair[0]
                .as_str()
                .and_then(|id| ids.get(id))
                .copied()
                .flatten();
            let b = pair[1]
                .as_str()
                .and_then(|id| ids.get(id))
                .copied()
                .flatten();
            if let (Some(a), Some(b)) = (a, b) {
                edges.insert((a, b));
                if route["bidirectional"].as_bool() == Some(true) {
                    edges.insert((b, a));
                }
            }
        }
    }
    let key = |a: usize, b: usize| json!(["edge", nodes[a].id, nodes[b].id]).to_string();
    let available =
        |a: usize, b: usize| facts.get(&key(a, b)).and_then(Value::as_bool) != Some(false);
    let mut reachable = BTreeSet::from([dest]);
    loop {
        let before = reachable.len();
        for &(a, b) in &edges {
            if reachable.contains(&b) && available(a, b) {
                reachable.insert(a);
            }
        }
        if before == reachable.len() {
            break;
        }
    }
    let mut entries: Vec<usize> = reachable.into_iter().filter(|i| *i != dest).collect();
    entries.sort_by(|a, b| {
        distance(start, nodes[*a].xyz)
            .total_cmp(&distance(start, nodes[*b].xyz))
            .then(nodes[*a].id.cmp(&nodes[*b].id))
    });
    for entry in entries {
        let entry_key = json!(["entry", nodes[entry].id]).to_string();
        match facts.get(&entry_key).and_then(Value::as_bool) {
            Some(false) => continue,
            None => {
                return Ok(
                    json!({"probes":[probe(&entry_key,&input["start"],&nodes[entry].point)]}),
                )
            }
            Some(true) => {}
        }
        let mut lengths = vec![f64::INFINITY; nodes.len()];
        let mut previous = vec![None; nodes.len()];
        let mut visited = BTreeSet::new();
        lengths[entry] = 0.0;
        loop {
            let current = (0..nodes.len())
                .filter(|i| !visited.contains(i) && lengths[*i].is_finite())
                .min_by(|a, b| {
                    lengths[*a]
                        .total_cmp(&lengths[*b])
                        .then(nodes[*a].id.cmp(&nodes[*b].id))
                });
            let Some(current) = current else {
                break;
            };
            if current == dest {
                break;
            }
            visited.insert(current);
            let mut neighbors: Vec<usize> = edges
                .iter()
                .filter(|(a, b)| *a == current && available(*a, *b))
                .map(|(_, b)| *b)
                .collect();
            neighbors.sort_by(|a, b| nodes[*a].id.cmp(&nodes[*b].id));
            for next in neighbors {
                let candidate = lengths[current] + distance(nodes[current].xyz, nodes[next].xyz);
                if candidate < lengths[next] {
                    lengths[next] = candidate;
                    previous[next] = Some(current);
                }
            }
        }
        if !lengths[dest].is_finite() {
            continue;
        }
        let mut path = vec![dest];
        while *path.last().unwrap() != entry {
            path.push(previous[*path.last().unwrap()].ok_or("world_activity_unreachable")?);
        }
        path.reverse();
        let probes: Vec<Value> = path
            .windows(2)
            .filter_map(|pair| {
                let k = key(pair[0], pair[1]);
                if facts.get(&k).and_then(Value::as_bool).is_none() {
                    Some(probe(&k, &nodes[pair[0]].point, &nodes[pair[1]].point))
                } else {
                    None
                }
            })
            .collect();
        if !probes.is_empty() {
            return Ok(json!({"probes":probes}));
        }
        let start_distance = distance(start, nodes[entry].xyz);
        let total = lengths[dest]
            + if start_distance <= nodes[entry].radius {
                0.0
            } else {
                start_distance
            };
        if start_distance <= nodes[entry].radius {
            path.remove(0);
        }
        return Ok(
            json!({"route":{"destinationID":destination,"waypointIDs":path.iter().map(|i|&nodes[*i].id).collect::<Vec<_>>(),"points":path.iter().map(|i|&nodes[*i].point).collect::<Vec<_>>(),"totalLength":total,"arrivalTolerance":nodes[dest].radius}}),
        );
    }
    Err("world_activity_unreachable")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn elapsed_numbers_match_native_swift_json_shape() {
        assert_eq!(elapsed_value(0).to_string(), "0");
        assert_eq!(elapsed_value(1000).to_string(), "1");
        assert_eq!(elapsed_value(125).to_string(), "0.125");
    }
    #[test]
    fn native_proof_coordinate_is_exact_float_not_json_decimal_spelling() {
        assert_eq!(
            native_physics_point(&json!({"x":1e100,"y":0,"z":0})).unwrap_err(),
            "world_activity_invalid_physics"
        );
        assert_eq!(
            native_physics_point(&json!({"x":0.2,"y":0,"z":0})).unwrap(),
            native_physics_point(&json!({"x":0.2_f32,"y":0,"z":0})).unwrap()
        );
        assert_ne!(
            native_physics_point(&json!({"x":0.2,"y":0,"z":0})).unwrap(),
            native_physics_point(&json!({"x":0.21,"y":0,"z":0})).unwrap()
        );
    }
    #[test]
    fn prepared_authored_facing_preserves_full_native_quaternion() {
        let mut c = setup_activity();
        let catalog = load_run(&c, "fixture").unwrap();
        let mut anchors = catalog["authoredActivities"].clone();
        anchors[0]["transform"]["rotation"] = json!({"x":0.5,"y":0.5,"z":0.5,"w":0.5});
        execute(&mut c,"world_activity_bind_catalog",json!({"worldID":"fixture","hostSessionID":"host","requestID":"tilted-author",
            "definitions":catalog["definitions"],"waypoints":catalog["waypoints"],"routes":catalog["routes"],"authoredActivities":anchors})).unwrap();
        let p = start(&c, "tilted-start");
        let ready = prepare(&c, &p).unwrap();
        assert!((ready["targetYaw"].as_f64().unwrap() - std::f64::consts::FRAC_PI_2).abs() < 1e-6);
    }
    #[test]
    fn usage_projection_preserves_native_metadata_and_revalidates_capability() {
        let mut checkpoint = json!({"worldTime":978307201125_i64,"objectStates":{"prop":{"metadata":{
            "gmgn.generated-prop.v1":"{\"objectID\":\"prop\"}",
            "gmgn.prop-capability.v1":"{\"objectID\":\"prop\",\"templateID\":\"coffee.brew\"}",
            "user-note":"unchanged"}},"other":{"metadata":{"user-note":"other"}}}});
        let before_other = checkpoint["objectStates"]["other"].clone();
        let run = json!({"requestID":"actual-run","definition":{"id":"coffee.brew@prop"},
            "usageBinding":{"objectID":"prop","templateID":"coffee.brew"}});
        for status in ["running", "completed", "stopped", "failed"] {
            project_usage(&mut checkpoint, &json!({}), &run, status).unwrap();
            let usage: Value = serde_json::from_str(
                checkpoint["objectStates"]["prop"]["metadata"]["gmgn.prop-usage.v1"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap();
            assert_eq!(usage["status"], status);
            assert_eq!(usage["activityRequestID"], "actual-run");
            assert_eq!(usage["updatedAt"].as_f64(), Some(1.125));
            assert_eq!(checkpoint["objectStates"]["other"], before_other);
            assert_eq!(
                checkpoint["objectStates"]["prop"]["metadata"]["user-note"],
                "unchanged"
            );
        }
        checkpoint["objectStates"]["prop"]["metadata"]["gmgn.prop-capability.v1"] =
            json!("{\"objectID\":\"prop\",\"templateID\":\"changed\"}");
        assert_eq!(
            project_usage(&mut checkpoint, &json!({}), &run, "completed").unwrap_err(),
            "world_activity_invalid_state"
        );
    }
    fn execute(c: &mut Connection, method: &str, input: Value) -> Result<Value> {
        let tx = c.transaction().unwrap();
        let result = request(&tx, method, input)?;
        tx.commit().unwrap();
        Ok(result)
    }
    fn setup_activity() -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        crate::world::schema(&c).unwrap();
        schema(&c).unwrap();
        schema(&c).unwrap();
        let tx = c.transaction().unwrap();
        crate::world::commit(&tx,&crate::world::CommitRequest{world_id:"fixture".into(),request_id:"seed".into(),expected_revision:0,producer:None,intent:None,
            ops:vec![crate::world::Op{op:"replaceState".into(),state:Some(json!({"worldID":"fixture","revision":0,"layoutRevision":0,"worldTime":1000,"objectStates":{},"agentTransform":{"position":{"x":0,"y":0,"z":0}}})),..Default::default()}]}).unwrap();
        tx.commit().unwrap();
        let definition = crate::activity::request(
            "activity_seat_definition",
            json!({"activityID":"seat","objectID":"sofa"}),
        )
        .unwrap()["definition"]
            .clone();
        execute(&mut c,"world_activity_bind_catalog",json!({"worldID":"fixture","requestID":"bind","hostSessionID":"host","definitions":[definition],"waypoints":[{"id":"origin","position":{"x":0,"y":0,"z":0},"arrivalRadius":0.1,"enabled":true},{"id":"a","position":{"x":1,"y":0,"z":0},"arrivalRadius":0.1,"enabled":true}],"routes":[{"id":"fixture","enabled":true,"bidirectional":true,"waypointIDs":["origin","a"]}],"authoredActivities":[{"id":"seat","entryWaypointID":"a","transform":{"rotation":{"x":0,"y":0,"z":0,"w":1}}}]})).unwrap();
        c
    }
    fn start(c: &Connection, id: &str) -> Value {
        let snapshot = crate::world::snapshot(
            c,
            &crate::world::SnapshotRequest {
                world_id: "fixture".into(),
                include_state: Some(true),
            },
        )
        .unwrap();
        let catalog = load_run(c, "fixture").unwrap();
        let mut p = json!({"worldID":"fixture","requestID":id,"hostSessionID":catalog["hostSessionID"],"expectedRevision":snapshot["record"]["recordRevision"],"expectedLayoutRevision":snapshot["record"]["state"]["layoutRevision"],"checkpoint":snapshot["record"]["state"],"definitionID":catalog["definitions"][0]["id"],"priority":0,"waitsForRenderedCompletion":true,"traversal":[],"capsuleRadius":0.2});
        for _ in 0..50 {
            let plan = prepare(c, &p).unwrap();
            if plan["stage"] == "ready" {
                p["planSHA256"] = plan["planSHA256"].clone();
                p["preparedAtMS"] = plan["preparedAtMS"].clone();
                return p;
            }
            if plan["stage"] == "approach" {
                p["approachPhysics"] = json!({"geometryID":plan["geometryID"],"physics":plan["probes"].as_array().unwrap().iter().map(|probe|json!({"key":probe["key"],"position":probe["position"],"grounded":probe["position"],"canTraverse":true})).collect::<Vec<_>>()});
                continue;
            }
            for probe in plan["probes"].as_array().unwrap() {
                let mut proof = probe.clone();
                proof["canTraverse"] = json!(true);
                p["traversal"].as_array_mut().unwrap().push(proof);
            }
        }
        panic!("private native proof loop exceeded bound")
    }
    fn receipt(c: &Connection, run: &Value, id: &str, kind: &str) -> Value {
        let snapshot = crate::world::snapshot(
            c,
            &crate::world::SnapshotRequest {
                world_id: "fixture".into(),
                include_state: Some(true),
            },
        )
        .unwrap();
        json!({"worldID":"fixture","requestID":id,"hostSessionID":"host","expectedRevision":snapshot["record"]["recordRevision"],"checkpoint":snapshot["record"]["state"],
            "runRequestID":run["requestID"],"generation":run["generation"],"phaseGeneration":run["phaseGeneration"],"phase":run["phase"],"kind":kind})
    }
    #[test]
    fn preparation_is_read_only_and_start_rejects_host_plan_and_changed_digest() {
        let mut c = setup_activity();
        let before = load_run(&c, "fixture").unwrap();
        let count: i64 = c
            .query_row("SELECT count(*) FROM world_activity_commands", [], |r| {
                r.get(0)
            })
            .unwrap();
        let p = start(&c, "prepared");
        assert_eq!(load_run(&c, "fixture").unwrap(), before);
        assert_eq!(
            c.query_row::<i64, _, _>("SELECT count(*) FROM world_activity_commands", [], |r| r
                .get(0))
                .unwrap(),
            count
        );
        for field in ["path", "targetYaw"] {
            let mut forged = p.clone();
            forged[field] = json!(0);
            assert_eq!(
                execute(&mut c, "world_activity_start", forged).unwrap_err(),
                "world_activity_host_plan_rejected"
            );
        }
        let mut forged = p.clone();
        forged["planSHA256"] = json!("0".repeat(64));
        assert_eq!(
            execute(&mut c, "world_activity_start", forged).unwrap_err(),
            "world_activity_plan_changed"
        );
        assert_eq!(load_run(&c, "fixture").unwrap(), before);
    }
    #[test]
    fn preparation_rejects_stale_pose_layout_expiry_and_wrong_route_proof() {
        let mut c = setup_activity();
        let p = start(&c, "proof");
        let mut changed = p.clone();
        changed["checkpoint"]["agentTransform"]["position"]["x"] = json!(8);
        assert!(execute(&mut c, "world_activity_start", changed).is_err());
        let mut changed = p.clone();
        changed["expectedLayoutRevision"] = json!(999);
        assert!(prepare(&c, &changed).is_err());
        let mut changed = p.clone();
        changed["preparedAtMS"] = json!(1);
        assert_eq!(
            prepare(&c, &changed).unwrap_err(),
            "world_activity_plan_expired"
        );
        assert!(!p["traversal"].as_array().unwrap().is_empty());
        let mut changed = p.clone();
        changed["traversal"][0]["to"]["x"] = json!(42);
        assert_eq!(
            prepare(&c, &changed).unwrap_err(),
            "world_activity_invalid_physics"
        );
        let mut changed = p.clone();
        let extra = changed["traversal"][0].clone();
        changed["traversal"].as_array_mut().unwrap().push(extra);
        assert_eq!(
            prepare(&c, &changed).unwrap_err(),
            "world_activity_invalid_physics"
        );
        let mut changed = p.clone();
        changed["traversal"][0]["key"] = json!("not-requested");
        assert_eq!(prepare(&c, &changed).unwrap()["stage"], "route");
    }
    #[test]
    fn bound_usage_and_lifecycle_fact_commit_together_without_restore_replay() {
        let mut c = setup_activity();
        let initial = start(&c, "unused");
        let mut checkpoint = initial["checkpoint"].clone();
        checkpoint["objectStates"]["prop"] = json!({"isEnabled":true,"transform":{
            "position":{"x":1,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},
            "metadata":{"gmgn.generated-prop.v1":"{\"objectID\":\"prop\",\"size\":{\"x\":1,\"y\":1,\"z\":1}}",
            "gmgn.prop-capability.v1":"{\"objectID\":\"prop\",\"templateID\":\"coffee.brew\"}","note":"keep"}});
        let tx = c.transaction().unwrap();
        crate::world::commit(
            &tx,
            &crate::world::CommitRequest {
                world_id: "fixture".into(),
                request_id: "usage-seed".into(),
                expected_revision: initial["expectedRevision"].as_i64().unwrap(),
                producer: None,
                intent: None,
                ops: vec![crate::world::Op {
                    op: "replaceState".into(),
                    state: Some(checkpoint),
                    ..Default::default()
                }],
            },
        )
        .unwrap();
        tx.commit().unwrap();
        let catalog = load_run(&c, "fixture").unwrap();
        let definitions = json!([crate::world_prop_capability::definition(
            &json!({"objectID":"prop","size":{"x":1,"y":1,"z":1}}),
            "coffee.brew"
        )
        .unwrap()]);
        execute(&mut c,"world_activity_bind_catalog",json!({"worldID":"fixture","hostSessionID":"host","requestID":"usage-bind","definitions":definitions,
            "waypoints":catalog["waypoints"],"routes":catalog["routes"],"authoredActivities":catalog["authoredActivities"],
            "usageBindings":{"coffee.brew@prop":{"objectID":"prop","templateID":"coffee.brew"}}})).unwrap();
        let command = start(&c, "usage-start");
        let started = execute(&mut c, "world_activity_start", command.clone()).unwrap();
        let usage = |result: &Value| -> Value {
            serde_json::from_str(
                result["snapshot"]["record"]["state"]["objectStates"]["prop"]["metadata"]
                    ["gmgn.prop-usage.v1"]
                    .as_str()
                    .unwrap(),
            )
            .unwrap()
        };
        assert_eq!(usage(&started)["status"], "running");
        let events = started["events"].clone();
        let replayed = execute(&mut c, "world_activity_start", command).unwrap();
        assert_eq!(replayed["events"], events);
        let restarted=execute(&mut c,"world_activity_bind_catalog",json!({"worldID":"fixture","hostSessionID":"new-host","requestID":"usage-restart","definitions":definitions,
            "waypoints":catalog["waypoints"],"routes":catalog["routes"],"authoredActivities":catalog["authoredActivities"],
            "usageBindings":{"coffee.brew@prop":{"objectID":"prop","templateID":"coffee.brew"}}})).unwrap();
        assert_eq!(restarted["events"], json!([]));
        assert_eq!(usage(&restarted)["status"], "running");
        let mut stop = receipt(&c, &restarted["activity"]["run"], "usage-stop", "stopped");
        stop["hostSessionID"] = json!("new-host");
        stop["reconcileUnknown"] = json!(true);
        let stopped = execute(&mut c, "world_activity_stop", stop).unwrap();
        assert_eq!(usage(&stopped)["status"], "stopped");
        assert_eq!(
            stopped["events"][0]["kind"],
            json!({"activityCancelled":{"activityID":"coffee.brew@prop"}})
        );
        assert_eq!(
            stopped["snapshot"]["record"]["state"]["objectStates"]["prop"]["metadata"]["note"],
            "keep"
        );
        assert_eq!(
            c.query_row(
                "SELECT COUNT(*) FROM world_facts WHERE kind='activity.transition'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
    }
    #[test]
    fn phase_world_transaction_and_strict_receipts() {
        let mut c = setup_activity();
        let command = start(&c, "start");
        let result = execute(&mut c, "world_activity_start", command.clone()).unwrap();
        assert_eq!(
            result["events"][0]["kind"],
            json!({"activityStarted":{"activityID":"seat"}})
        );
        let fact_sequence = result["events"][0]["sequence"].as_i64().unwrap();
        assert_eq!(
            c.query_row(
                "SELECT seq FROM world_facts WHERE kind='activity.transition'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            fact_sequence
        );
        let run = &result["activity"]["run"];
        assert_eq!(run["phase"], "approach");
        assert_eq!(
            result["snapshot"]["record"]["state"]["activeActivity"]["activityID"],
            "seat"
        );
        assert_eq!(
            execute(&mut c, "world_activity_start", command).unwrap()["replayed"],
            true
        );
        assert_eq!(
            c.query_row(
                "SELECT COUNT(*) FROM world_facts WHERE kind='activity.transition'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            1
        );
        let mut premature = receipt(&c, run, "premature", "arrived");
        assert_eq!(
            execute(&mut c, "world_activity_receipt", premature.clone()).unwrap_err(),
            "world_activity_not_arrived"
        );
        premature["requestID"] = json!("arrived");
        premature["checkpoint"]["agentTransform"]["position"]["x"] = json!(1);
        let entered = execute(&mut c, "world_activity_receipt", premature).unwrap();
        assert_eq!(entered["activity"]["run"]["phase"], "enter");
        let stale = receipt(&c, run, "old", "failed");
        assert_eq!(
            execute(&mut c, "world_activity_receipt", stale).unwrap_err(),
            "world_activity_stale_receipt"
        );
        let clip = receipt(&c, &entered["activity"]["run"], "clip", "clipCompleted");
        let looping = execute(&mut c, "world_activity_receipt", clip).unwrap();
        assert_eq!(looping["activity"]["run"]["phase"], "loop");
        let complete = receipt(&c, &looping["activity"]["run"], "infinite", "clipCompleted");
        assert_eq!(
            execute(&mut c, "world_activity_receipt", complete).unwrap_err(),
            "world_activity_infinite_loop"
        );
        let stop = receipt(&c, &looping["activity"]["run"], "stop", "stopped");
        let stopped = execute(&mut c, "world_activity_stop", stop).unwrap();
        assert!(stopped["activity"]["run"].is_null());
        assert!(stopped["snapshot"]["record"]["state"]["activeActivity"].is_null());
    }
    #[test]
    fn recovery_is_unknown_and_catalog_is_not_model_definition() {
        let mut c = setup_activity();
        let command = start(&c, "start");
        execute(&mut c, "world_activity_start", command).unwrap();
        let definition = crate::activity::request(
            "activity_seat_definition",
            json!({"activityID":"seat","objectID":"sofa"}),
        )
        .unwrap()["definition"]
            .clone();
        let catalog = load_run(&c, "fixture").unwrap();
        let restarted=execute(&mut c,"world_activity_bind_catalog",json!({"worldID":"fixture","requestID":"restart","hostSessionID":"new-host","definitions":[definition],"waypoints":catalog["waypoints"],"routes":catalog["routes"],"authoredActivities":catalog["authoredActivities"]})).unwrap();
        assert_eq!(restarted["activity"]["run"]["status"], "unknown");
        let stale = receipt(&c, &restarted["activity"]["run"], "stale", "arrived");
        assert_eq!(
            execute(&mut c, "world_activity_receipt", stale).unwrap_err(),
            "world_activity_stale_session"
        );
        let mut command = start(&c, "unregistered");
        command["hostSessionID"] = json!("new-host");
        command["definitionID"] = json!("arbitrary-action");
        assert_eq!(
            execute(&mut c, "world_activity_start", command).unwrap_err(),
            "world_activity_unknown_definition"
        );
    }
    #[test]
    fn coordinate_and_live_object_targets_are_rust_rules() {
        let mut coordinate = input();
        coordinate["coordinateTarget"] = json!({"x":3,"y":0.04,"z":0});
        coordinate["coordinateGroundHeight"] = json!(0);
        coordinate["coordinateOccupable"] = json!(true);
        coordinate["startOccupable"] = json!(true);
        let key = json!(["coordinateDirect"]).to_string();
        assert_eq!(route(&coordinate).unwrap()["probes"][0]["key"], key);
        coordinate["facts"][&key] = json!(true);
        let result = route(&coordinate).unwrap();
        assert_eq!(result["route"]["arrivalTolerance"], 0.02);
        assert_eq!(result["route"]["points"][0]["y"].as_f64(), Some(0.0));
        coordinate["coordinateTarget"]["y"] = json!(0.06);
        assert_eq!(
            route(&coordinate).unwrap_err(),
            "world_coordinate_off_ground"
        );
        let finalized=route(&json!({"baseRoute":{"destinationID":"b","waypointIDs":["b"],"points":[{"x":2,"y":0,"z":0}],"totalLength":2,"arrivalTolerance":0.1},
            "destinationID":"live-object","destinationKind":"generated","start":{"x":0,"y":0,"z":0},"finalTarget":{"x":3,"y":0,"z":0}})).unwrap();
        assert_eq!(finalized["route"]["destinationID"], "live-object");
        assert_eq!(
            finalized["route"]["waypointIDs"],
            json!(["b", "live-object"])
        );
        assert_eq!(finalized["route"]["arrivalTolerance"], 0.05);
        assert_eq!(finalized["route"]["totalLength"], 3.0);
    }
    #[test]
    fn movement_owns_arrival_and_single_replan_without_activity_projection() {
        let mut c = setup_activity();
        let mut command = start(&c, "move-command");
        command["path"] = prepare(&c, &command).unwrap()["path"].clone();
        command["movementRequestID"] = json!("native-move-id");
        let moving = execute(&mut c, "world_activity_move", command).unwrap();
        let run = &moving["activity"]["run"];
        assert_eq!(run["requestID"], "native-move-id");
        assert!(moving["snapshot"]["record"]["state"]["activeActivity"].is_null());
        let blocked = receipt(&c, run, "blocked", "blocked");
        let retry = execute(&mut c, "world_activity_receipt", blocked).unwrap();
        assert_eq!(retry["activity"]["run"]["status"], "replanRequired");
        let mut replan = receipt(&c, &retry["activity"]["run"], "replan", "ignored");
        replan["path"] = retry["activity"]["run"]["path"].clone();
        let retry = execute(&mut c, "world_activity_replan", replan).unwrap();
        assert_eq!(retry["activity"]["run"]["requestID"], "native-move-id");
        let blocked = receipt(&c, &retry["activity"]["run"], "blocked-again", "blocked");
        let failed = execute(&mut c, "world_activity_receipt", blocked).unwrap();
        assert!(failed["activity"]["run"].is_null());
        assert_eq!(failed["activity"]["lastTerminal"]["outcome"], "failed");
        let mut command = start(&c, "next-move");
        command["path"] = prepare(&c, &command).unwrap()["path"].clone();
        command["movementRequestID"] = json!("next-id");
        let moving = execute(&mut c, "world_activity_move", command).unwrap();
        let mut arrived = receipt(&c, &moving["activity"]["run"], "arrived", "arrived");
        arrived["checkpoint"]["agentTransform"]["position"]["x"] = json!(0.95);
        let completed = execute(&mut c, "world_activity_receipt", arrived).unwrap();
        assert!(completed["activity"]["run"].is_null());
        assert_eq!(
            completed["activity"]["lastTerminal"]["outcome"],
            "completed"
        );
    }
    #[test]
    fn patrol_candidates_and_stable_request_are_rust_owned() {
        let mut c = setup_activity();
        let phases: [Value; 6] = ["approach", "enter", "loop", "exit", "interrupt", "failed"]
            .map(|phase| json!({"phase":phase,"requiredAnchorIDs":[],"propIDs":[],"motionIDs":[]}));
        let definition = json!({"id":"home.walk","activity":{"type":"walk","destinationID":"a"},"interruptible":true,"cooldownSeconds":0,"phases":phases});
        execute(&mut c,"world_activity_bind_catalog",json!({"worldID":"fixture","requestID":"patrol-bind","hostSessionID":"host","definitions":[definition],"waypoints":[
            {"id":"a","enabled":true,"position":{"x":1,"y":0,"z":0},"arrivalRadius":0.1}, {"id":"b","enabled":true,"position":{"x":3,"y":0,"z":0},"arrivalRadius":0.1}, {"id":"c","enabled":true,"position":{"x":4,"y":0,"z":0},"arrivalRadius":0.1}],"routes":[{"id":"patrol","enabled":true,"bidirectional":true,"waypointIDs":["a","b","c"]}],"authoredActivities":[{"id":"home.walk","entryWaypointID":"a","transform":{"rotation":{"x":0,"y":0,"z":0,"w":1}}}]})).unwrap();
        let mut command = start(&c, "patrol");
        command["definitionID"] = json!("home.walk");
        let result = execute(&mut c, "world_activity_start", command).unwrap();
        let mut arrived = receipt(&c, &result["activity"]["run"], "leg1", "arrived");
        arrived["checkpoint"]["agentTransform"]["position"]["x"] = json!(1);
        let result = execute(&mut c, "world_activity_receipt", arrived).unwrap();
        assert_eq!(
            result["activity"]["run"]["patrolCandidates"],
            json!(["c", "b"])
        );
        let mut next = receipt(&c, &result["activity"]["run"], "leg2", "ignored");
        next["targetID"] = json!("c");
        next["rejectedTargets"] = json!([]);
        next["path"] = json!({"destinationID":"c","waypointIDs":["c"],"points":[{"x":4,"y":0,"z":0}],"totalLength":3,"arrivalTolerance":0.1});
        let result = execute(&mut c, "world_activity_continue", next).unwrap();
        assert_eq!(result["activity"]["run"]["requestID"], "patrol");
        assert_eq!(result["activity"]["run"]["activity"]["destinationID"], "c");
    }
    fn input() -> Value {
        json!({"start":{"x":0,"y":0,"z":0},"destinationID":"b","waypoints":[{"id":"a","position":{"x":0,"y":0,"z":0},"arrivalRadius":0.1,"enabled":true},{"id":"b","position":{"x":2,"y":0,"z":0},"arrivalRadius":0.1,"enabled":true}],"routes":[{"enabled":true,"bidirectional":true,"waypointIDs":["a","b"]}],"facts":{}})
    }
    #[test]
    fn evidence_precedes_route() {
        let mut v = input();
        let entry = json!(["entry", "a"]).to_string();
        let edge = json!(["edge", "a", "b"]).to_string();
        assert_eq!(route(&v).unwrap()["probes"][0]["key"], entry);
        v["facts"][&entry] = json!(true);
        assert_eq!(route(&v).unwrap()["probes"][0]["key"], edge);
        v["facts"][&edge] = json!(true);
        let result = route(&v).unwrap();
        assert_eq!(result["route"]["waypointIDs"], json!(["b"]));
        assert_eq!(result["route"]["totalLength"], 2.0);
        v["facts"][&edge] = json!(false);
        assert_eq!(route(&v).unwrap_err(), "world_activity_unreachable");
    }
    #[test]
    fn arrival_is_authored_and_nonnegative() {
        let mut v = input();
        v["start"]["x"] = json!(1.95);
        assert_eq!(route(&v).unwrap()["route"]["points"], json!([]));
        v["waypoints"][1]["arrivalRadius"] = json!(-1);
        assert!(route(&v).unwrap().get("probes").is_some());
    }
}
