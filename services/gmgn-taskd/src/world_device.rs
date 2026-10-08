//! Built-in catalog device placement is a typed Rust authority. Native supplies
//! its loaded geometry and pointer pose, never a replacement document/verdict.
use crate::{
    model::{digest, Result},
    placement::{self, BoxVolume, Column, EvaluateRequest, Footprint, Grid, Layer, Obstacle},
    support_grid, world,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

const DEVICE: &str = "gmgn.builtin-device.v1";
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Pointer {
    op: String,
    #[serde(rename = "templateID")]
    template_id: String,
    position: [f32; 3],
    yaw: f32,
}
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS world_device_catalog(world TEXT NOT NULL,id TEXT NOT NULL,declaration TEXT NOT NULL,PRIMARY KEY(world,id));
CREATE TABLE IF NOT EXISTS world_device_intents(id TEXT PRIMARY KEY,world TEXT NOT NULL,scope TEXT NOT NULL,host TEXT NOT NULL,capability TEXT NOT NULL,revision INTEGER NOT NULL,layout INTEGER NOT NULL,expires INTEGER NOT NULL,command TEXT NOT NULL,used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS world_device_commands(world TEXT NOT NULL,request TEXT NOT NULL,input TEXT NOT NULL,output TEXT NOT NULL,PRIMARY KEY(world,request));")
        .map_err(|_|"storage_unavailable")
}
pub fn recover(c: &Connection) -> Result<()> {
    c.execute("DELETE FROM world_device_intents", [])
        .map_err(|_| "storage_unavailable")?;
    Ok(())
}
fn now() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|n| n.as_millis() as u64)
        .map_err(|_| "world_device_clock_unavailable")
}
fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("world_device_invalid_input")
}
fn encode(v: &Value) -> Result<String> {
    crate::canonical_json::to_string(v).map_err(|_| "world_device_invalid_input")
}
fn snapshot(c: &Connection, p: &Value) -> Result<Value> {
    world::snapshot(
        c,
        &world::SnapshotRequest {
            world_id: text(p, "worldID")?.into(),
            include_state: Some(true),
        },
    )
}
fn identity(p: &Value) -> Result<()> {
    text(p, "worldID")?;
    text(p, "residentScope")?;
    text(p, "hostSessionID")?;
    Ok(())
}
fn version(p: &Value, s: &Value) -> Result<(i64, u64)> {
    let revision = p["expectedRevision"]
        .as_i64()
        .filter(|n| *n >= 0)
        .ok_or("world_device_invalid_input")?;
    let layout = p["expectedLayoutRevision"]
        .as_u64()
        .ok_or("world_device_invalid_input")?;
    if s["record"]["recordRevision"] != revision || s["record"]["state"]["layoutRevision"] != layout
    {
        return Err("revision_conflict");
    }
    Ok((revision, layout))
}
fn dimensions(t: &Value) -> Result<[f32; 3]> {
    let a = t["size"]
        .as_array()
        .filter(|a| a.len() == 3)
        .ok_or("world_device_invalid_catalog")?;
    let mut size = [0.; 3];
    for i in 0..3 {
        size[i] = a[i]
            .as_f64()
            .filter(|n| n.is_finite() && *n > 0. && *n <= 100.)
            .ok_or("world_device_invalid_catalog")? as f32;
    }
    Ok(size)
}
fn validate_template(t: &Value) -> Result<()> {
    text(t, "id")?;
    if !matches!(
        (text(t, "id")?, t["renderer"].as_str()),
        ("prop.jukebox", Some("builtin.jukebox"))
            | ("wish_machine.device", Some("builtin.wish_machine"))
    ) {
        return Err("world_device_invalid_catalog");
    }
    dimensions(t)?;
    function_points(t)?;
    if let Some(bindings) = t.get("placeBindings") {
        let bindings = bindings
            .as_array()
            .filter(|b| b.len() <= 16)
            .ok_or("world_device_invalid_catalog")?;
        let mut places = std::collections::BTreeSet::new();
        for binding in bindings {
            let place = text(binding, "placeID")?;
            let role = text(binding, "role")?;
            let expected = match text(t, "id")? {
                "prop.jukebox" => ("wp.jukebox", "interact"),
                "wish_machine.device" => ("wish_machine.pickup", "pickup"),
                _ => return Err("world_device_invalid_catalog"),
            };
            if (place, role) != expected
                || !places.insert(place)
                || !t["functionPoints"].as_array().is_some_and(|p| {
                    p.iter().any(|p| {
                        p["role"] == role && (p["kind"].is_null() || p["kind"] == "standingSpot")
                    })
                })
            {
                return Err("world_device_invalid_catalog");
            }
        }
    }
    if let Some(source) = t.get("collisionSourceID") {
        let valid = matches!(
            (text(t, "id")?, t["renderer"].as_str(), source.as_str()),
            (
                "prop.jukebox",
                Some("builtin.jukebox"),
                Some("collision.jukebox")
            ) | (
                "wish_machine.device",
                Some("builtin.wish_machine"),
                Some("wish_machine.collision")
            )
        );
        if !valid {
            return Err("world_device_invalid_catalog");
        }
    }
    Ok(())
}
fn function_points(t: &Value) -> Result<Option<String>> {
    let Some(points) = t.get("functionPoints") else {
        return Ok(None);
    };
    let points = points
        .as_array()
        .filter(|p| p.len() <= 16)
        .ok_or("world_device_invalid_catalog")?;
    if points.is_empty() {
        return Ok(None);
    }
    let mut roles = std::collections::BTreeSet::new();
    for point in points {
        let role = text(point, "role")?;
        if point.get("activityID").is_some_and(|v| {
            !v.is_null() && v.as_str().is_none_or(|s| s.is_empty() || s.len() > 256)
        }) {
            return Err("world_device_invalid_catalog");
        }
        if !roles.insert(role)
            || !matches!(
                point.get("kind").and_then(Value::as_str),
                None | Some("standingSpot" | "interaction" | "emitter")
            )
        {
            return Err("world_device_invalid_catalog");
        }
        let position = &point["position"];
        for (i, key) in ["x", "y", "z"].iter().enumerate() {
            let component = if position.is_array() {
                &position[i]
            } else {
                &position[*key]
            };
            if !component
                .as_f64()
                .is_some_and(|v| v.is_finite() && v.abs() <= 100.)
            {
                return Err("world_device_invalid_catalog");
            }
        }
        if point
            .get("yaw")
            .is_some_and(|v| !v.as_f64().is_some_and(f64::is_finite))
        {
            return Err("world_device_invalid_catalog");
        }
    }
    Ok(Some(encode(
        &json!({"objectID":text(t,"id")?,"functionPoints":points}),
    )?))
}
fn template(c: &Connection, p: &Value, id: &str) -> Result<Value> {
    let raw: Option<String> = c
        .query_row(
            "SELECT declaration FROM world_device_catalog WHERE world=?1 AND id=?2",
            params![text(p, "worldID")?, id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    serde_json::from_str(&raw.ok_or("world_device_template_unavailable")?)
        .map_err(|_| "world_device_invalid_catalog")
}
fn pointer(v: &Value) -> Result<Pointer> {
    let p: Pointer = serde_json::from_value(v.clone()).map_err(|_| "world_device_invalid_input")?;
    if p.op != "place"
        || p.template_id.is_empty()
        || p.template_id.len() > 256
        || !p.yaw.is_finite()
        || p.position
            .iter()
            .any(|n| !n.is_finite() || n.abs() > 100000.)
    {
        return Err("world_device_invalid_input");
    }
    Ok(p)
}
fn can_place(state: &Value, t: &Value) -> Result<()> {
    let id = text(t, "id")?;
    if state["heldProp"]["objectID"] == id {
        return Err("world_device_basic_object");
    }
    if let Some(existing) = state["objectStates"].get(id) {
        if existing["metadata"]
            .get(world::GENERATED_PROP_KEY)
            .is_some()
        {
            return Err("world_device_basic_object");
        }
        if existing["isEnabled"] == true {
            let stored: Value = serde_json::from_str(
                existing["metadata"][DEVICE]
                    .as_str()
                    .ok_or("world_device_basic_object")?,
            )
            .map_err(|_| "world_device_basic_object")?;
            if stored["id"] != t["id"]
                || stored["renderer"] != t["renderer"]
                || t.get("collisionSourceID").is_none()
            {
                return Err("world_device_basic_object");
            }
        }
        if existing["metadata"]
            .as_object()
            .is_some_and(|m| m.keys().any(|k| k != DEVICE))
        {
            return Err("world_device_basic_object");
        }
    }
    Ok(())
}
fn obstacle_id(o: &Obstacle) -> &str {
    match o {
        Obstacle::Box { id, .. } | Obstacle::Mesh { id, .. } => id,
    }
}
fn retain_unreplaced(obstacles: &mut Vec<Obstacle>, sources: &std::collections::BTreeSet<String>) {
    obstacles.retain(|o| !sources.contains(obstacle_id(o)));
}
// Only Rust-validated catalog source IDs may replace a manifest obstacle. The
// request carries no exclusions. Durable poses rebuild all other enabled devices.
fn device_geometry(
    tx: &Transaction<'_>,
    root: &Path,
    p: &Value,
    state: &Value,
    target: &str,
) -> Result<(support_grid::DeriveRequest, Grid, Vec<Obstacle>)> {
    let (mut environment, _, mut obstacles) =
        crate::world_prop::device_environment(tx, root, p, state)?;
    let mut statement = tx
        .prepare("SELECT declaration FROM world_device_catalog WHERE world=?1")
        .map_err(|_| "storage_unavailable")?;
    let rows = statement
        .query_map([text(p, "worldID")?], |r| r.get::<_, String>(0))
        .map_err(|_| "storage_unavailable")?;
    let mut replaced = std::collections::BTreeSet::new();
    let mut actual = Vec::new();
    for row in rows {
        let template: Value = serde_json::from_str(&row.map_err(|_| "storage_unavailable")?)
            .map_err(|_| "world_device_invalid_catalog")?;
        validate_template(&template)?;
        let Some(source) = template["collisionSourceID"].as_str() else {
            continue;
        };
        let id = text(&template, "id")?;
        let existing = state["objectStates"].get(id);
        if id == target || existing.is_some() {
            replaced.insert(source.to_owned());
        }
        if id == target {
            continue;
        }
        let Some(item) = existing.filter(|v| v["isEnabled"] == true) else {
            continue;
        };
        let t = &item["transform"];
        let size = dimensions(&template)?;
        let number = |v: &Value| {
            v.as_f64()
                .filter(|n| n.is_finite())
                .map(|n| n as f32)
                .ok_or("world_device_invalid_state")
        };
        let rotation = &t["rotation"];
        let q = [
            number(&rotation["x"])?,
            number(&rotation["y"])?,
            number(&rotation["z"])?,
            number(&rotation["w"])?,
        ];
        if q[0].abs() > 0.0001
            || q[2].abs() > 0.0001
            || ((q[1] * q[1] + q[3] * q[3]) - 1.).abs() > 0.001
        {
            return Err("world_device_invalid_state");
        }
        actual.push(Obstacle::Box {
            id: id.into(),
            volume: BoxVolume {
                center: [
                    number(&t["position"]["x"])?,
                    number(&t["position"]["y"])? + size[1] / 2.,
                    number(&t["position"]["z"])?,
                ],
                half_extents: size.map(|v| v / 2.),
                yaw: 2. * q[1].atan2(q[3]),
            },
        });
    }
    retain_unreplaced(&mut environment.blocking_volumes, &replaced);
    retain_unreplaced(&mut obstacles, &replaced);
    environment.blocking_volumes.extend(actual.clone());
    obstacles.extend(actual);
    let grid = support_grid::derive(environment.clone())
        .map_err(|_| "world_device_invalid_native_facts")?
        .grid;
    Ok((environment, grid, obstacles))
}
fn preview_pose(
    size: [f32; 3],
    p: &Pointer,
    env: &support_grid::DeriveRequest,
    grid: &Grid,
    placed: &[Obstacle],
) -> Result<Value> {
    let spacing = grid.spacing;
    if !spacing.is_finite() || spacing <= 0. {
        return Err("world_device_invalid_native_facts");
    }
    let column = Column {
        x: ((p.position[0] - spacing * 0.5) / spacing).round() as i32,
        z: ((p.position[2] - spacing * 0.5) / spacing).round() as i32,
    };
    let mut footprint = Footprint {
        size: [size[0], size[2]],
        yaw: p.yaw,
        center_offset: [0.; 2],
    };
    let base = footprint.center(column, spacing);
    footprint.center_offset = [p.position[0] - base[0], p.position[2] - base[1]];
    let mut layers: Vec<Layer> = grid
        .layers
        .iter()
        .filter(|l| l.column == column)
        .cloned()
        .collect();
    layers.sort_by(|a, b| {
        (a.support_height - p.position[1])
            .abs()
            .total_cmp(&(b.support_height - p.position[1]).abs())
    });
    let mut last = None;
    for anchor in layers {
        let support_height = anchor.support_height;
        let verdict = placement::evaluate(EvaluateRequest {
            grid: grid.clone(),
            anchor,
            footprint,
            height: size[1],
            triangles: env.triangles.clone(),
            blocking_volumes: env.blocking_volumes.clone(),
            placed_obstacles: placed.to_vec(),
            resting_tolerance: 0.02,
            support_height_deviation: 0.02,
        });
        let columns:Vec<Value>=verdict.columns.iter().map(|c|json!({"column":c,"height":support_height,"hasSupport":grid.layers.iter().any(|l|l.column==*c),"canPlace":verdict.can_place})).collect();
        let mut reply = json!({"canPlace":verdict.can_place,"reason":verdict.reason,"volume":verdict.volume,"columns":columns,"spacing":spacing});
        if verdict.can_place {
            let volume = verdict
                .volume
                .as_ref()
                .ok_or("world_device_invalid_native_facts")?;
            reply["placement"] = json!({"position":{"x":volume.center[0],"y":volume.center[1]-size[1]/2.,"z":volume.center[2]},"yaw":p.yaw});
            return Ok(reply);
        }
        last = Some(reply);
    }
    Ok(last.unwrap_or_else(
        || json!({"canPlace":false,"reason":{"code":"noSupport"},"columns":[],"spacing":spacing}),
    ))
}
fn typed_commit(
    tx: &Transaction<'_>,
    p: &Value,
    revision: i64,
    state: Value,
    kind: &str,
    id: &str,
    request_id: &str,
) -> Result<Value> {
    world::commit_prop(
        tx,
        &world::CommitRequest {
            world_id: text(p, "worldID")?.into(),
            request_id: format!("device:{request_id}"),
            expected_revision: revision,
            producer: Some("world-device".into()),
            intent: Some(json!({"kind":kind,"objectID":id})),
            ops: vec![world::Op {
                op: "replaceState".into(),
                state: Some(state),
                ..Default::default()
            }],
        },
    )
}
pub fn request(tx: &Transaction<'_>, root: &Path, method: &str, p: Value) -> Result<Value> {
    identity(&p)?;
    // An exact durable retry remains readable after its successful revision change.
    if method == "world_device_command" {
        let old: Option<(String, String)> = tx
            .query_row(
                "SELECT input,output FROM world_device_commands WHERE world=?1 AND request=?2",
                params![text(&p, "worldID")?, text(&p, "requestID")?],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        if let Some((prior, output)) = old {
            return if prior == encode(&p)? {
                serde_json::from_str(&output).map_err(|_| "world_device_invalid_state")
            } else {
                Err("request_id_conflict")
            };
        }
        if p.get("command").is_some() || p.get("candidate").is_some() || p.get("allowed").is_some()
        {
            return Err("world_device_invalid_command");
        }
    }
    let snap = snapshot(tx, &p)?;
    let state = &snap["record"]["state"];
    if method == "world_device_catalog_install" {
        let templates = p["templates"]
            .as_array()
            .filter(|a| !a.is_empty() && a.len() <= 16)
            .ok_or("world_device_invalid_catalog")?;
        let mut ids = std::collections::BTreeSet::new();
        let mut next = state.clone();
        for t in templates {
            validate_template(t)?;
            let id = text(t, "id")?;
            if !ids.insert(id) {
                return Err("world_device_invalid_catalog");
            }
            tx.execute("INSERT INTO world_device_catalog VALUES(?1,?2,?3) ON CONFLICT(world,id) DO UPDATE SET declaration=excluded.declaration",params![text(&p,"worldID")?,id,encode(t)?]).map_err(|_|"storage_unavailable")?;
            if let Some(raw) = function_points(t)? {
                if let Some(item) = next["objectStates"].get_mut(id) {
                    if item["metadata"].get(world::GENERATED_PROP_KEY).is_none() {
                        item["metadata"]["gmgn.prop-function-points.v1"] = json!(raw);
                    }
                }
            }
        }
        crate::world_prop::install_reviewed_seat_metadata(&mut next, None)?;
        if next == *state {
            return Ok(json!({"installed":ids.len(),"didCommit":false,"snapshot":snap}));
        }
        next["revision"] = json!(state["revision"]
            .as_u64()
            .ok_or("world_device_invalid_state")?
            .checked_add(1)
            .ok_or("world_device_invalid_state")?);
        next["layoutRevision"] = json!(state["layoutRevision"]
            .as_u64()
            .ok_or("world_device_invalid_state")?
            .checked_add(1)
            .ok_or("world_device_invalid_state")?);
        let revision = snap["record"]["recordRevision"]
            .as_i64()
            .ok_or("world_device_invalid_state")?;
        let request = format!("catalog-functions:{}", uuid::Uuid::new_v4());
        let commit = typed_commit(
            tx,
            &p,
            revision,
            next,
            "register-authored-device-functions",
            "catalog",
            &request,
        )?;
        return Ok(
            json!({"installed":ids.len(),"didCommit":true,"commit":commit,"snapshot":snapshot(tx,&p)?}),
        );
    }
    let (revision, layout) = version(&p, &snap)?;
    if method == "world_device_refresh" {
        let id = text(&p, "templateID")?;
        let t = template(tx, &p, id)?;
        if t["renderer"] != "builtin.jukebox" {
            return Err("world_device_template_unavailable");
        }
        let object = &state["objectStates"][id];
        if object["isEnabled"] != true
            || object["metadata"][DEVICE].as_str().is_none()
            || object["metadata"].get(world::GENERATED_PROP_KEY).is_some()
        {
            return Err("world_device_template_unavailable");
        }
        let declaration = encode(&t)?;
        if object["metadata"][DEVICE] == declaration {
            return Ok(json!({"didCommit":false,"snapshot":snap}));
        }
        let mut next = state.clone();
        next["objectStates"][id]["metadata"][DEVICE] = json!(declaration);
        next["revision"] = json!(state["revision"]
            .as_u64()
            .ok_or("world_device_invalid_state")?
            .checked_add(1)
            .ok_or("world_device_invalid_state")?);
        let commit = typed_commit(
            tx,
            &p,
            revision,
            next,
            "refresh-builtin-device-functions",
            id,
            text(&p, "requestID")?,
        )?;
        return Ok(json!({"didCommit":true,"commit":commit,"snapshot":snapshot(tx,&p)?}));
    }
    if method == "world_device_ui_intent" {
        let command = pointer(&p["command"])?;
        let t = template(tx, &p, &command.template_id)?;
        can_place(state, &t)?;
        let id = uuid::Uuid::new_v4().to_string();
        let cap = uuid::Uuid::new_v4().to_string();
        let expires = now()? + 10000;
        let bound = json!({"pointer":p["command"],"templateSHA256":digest(encode(&t)?.as_bytes())});
        tx.execute(
            "INSERT INTO world_device_intents VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,0)",
            params![
                id,
                text(&p, "worldID")?,
                text(&p, "residentScope")?,
                text(&p, "hostSessionID")?,
                cap,
                revision,
                layout,
                expires,
                encode(&bound)?
            ],
        )
        .map_err(|_| "storage_unavailable")?;
        return Ok(json!({"intentID":id,"capability":cap,"expiresAtMS":expires}));
    }
    let request_id = if method == "world_device_command" {
        Some(text(&p, "requestID")?)
    } else {
        None
    };
    let input = encode(&p)?;
    let command = if method == "world_device_preview" {
        p["command"].clone()
    } else if method == "world_device_command" {
        let auth = &p["authority"];
        if auth["kind"] != "ui" {
            return Err("world_device_unauthorized");
        }
        let old:Option<(String,String,String,String,i64,u64,u64,String,bool)>=tx.query_row("SELECT world,scope,host,capability,revision,layout,expires,command,used FROM world_device_intents WHERE id=?1",[text(auth,"intentID")?],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?))).optional().map_err(|_|"storage_unavailable")?;
        let (w, s, h, cap, r, l, expires, c, used) = old.ok_or("world_device_unauthorized")?;
        if used
            || w != text(&p, "worldID")?
            || s != text(&p, "residentScope")?
            || h != text(&p, "hostSessionID")?
            || cap != text(auth, "capability")?
            || r != revision
            || l != layout
            || now()? > expires
        {
            return Err("world_device_unauthorized");
        }
        tx.execute(
            "UPDATE world_device_intents SET used=1 WHERE id=?1",
            [text(auth, "intentID")?],
        )
        .map_err(|_| "storage_unavailable")?;
        let bound: Value = serde_json::from_str(&c).map_err(|_| "world_device_invalid_state")?;
        let pointer = pointer(&bound["pointer"])?;
        let t = template(tx, &p, &pointer.template_id)?;
        if bound["templateSHA256"] != digest(encode(&t)?.as_bytes()) {
            return Err("world_device_catalog_changed");
        }
        bound["pointer"].clone()
    } else {
        return Err("method_not_found");
    };
    let pointer = pointer(&command)?;
    let t = template(tx, &p, &pointer.template_id)?;
    can_place(state, &t)?;
    let size = dimensions(&t)?;
    let (environment, grid, obstacles) =
        device_geometry(tx, root, &p, state, &pointer.template_id)?;
    let verdict = preview_pose(size, &pointer, &environment, &grid, &obstacles)?;
    if method == "world_device_preview" {
        return Ok(verdict);
    }
    if verdict["canPlace"] != true {
        return Err("world_device_cannot_place");
    }
    let center = &verdict["volume"]["center"];
    let yaw = pointer.yaw;
    let mut object = json!({"isEnabled":true,"transform":{"position":{"x":center[0],"y":center[1].as_f64().ok_or("world_device_invalid_native_facts")?-size[1] as f64/2.,"z":center[2]},"rotation":{"x":0,"y":(yaw/2.).sin(),"z":0,"w":(yaw/2.).cos()},"scale":{"x":1,"y":1,"z":1}},"metadata":{}});
    object["metadata"][DEVICE] = json!(encode(&t)?);
    if let Some(raw) = function_points(&t)? {
        object["metadata"]["gmgn.prop-function-points.v1"] = json!(raw);
    }
    let mut next = state.clone();
    next["objectStates"][&pointer.template_id] = object;
    next["revision"] = json!(state["revision"]
        .as_u64()
        .ok_or("world_device_invalid_state")?
        .checked_add(1)
        .ok_or("world_device_invalid_state")?);
    next["layoutRevision"] = json!(layout.checked_add(1).ok_or("world_device_invalid_state")?);
    let commit = typed_commit(
        tx,
        &p,
        revision,
        next,
        "place-builtin-device",
        &pointer.template_id,
        request_id.unwrap(),
    )?;
    let out = json!({"objectID":pointer.template_id,"commit":commit,"snapshot":snapshot(tx,&p)?,"placement":verdict});
    tx.execute(
        "INSERT INTO world_device_commands VALUES(?1,?2,?3,?4)",
        params![
            text(&p, "worldID")?,
            request_id.unwrap(),
            input,
            encode(&out)?
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn source_provenance_cannot_exclude_wall_or_other_device() {
        let mut t = json!({"id":"prop.jukebox","renderer":"builtin.jukebox","size":[1,2,3],"collisionSourceID":"collision.jukebox"});
        assert!(validate_template(&t).is_ok());
        t["collisionSourceID"] = json!("floor");
        assert!(validate_template(&t).is_err());
        t["collisionSourceID"] = json!("wish_machine.collision");
        assert!(validate_template(&t).is_err());
        t["collisionSourceID"] = json!("collision.jukebox");
        t["id"] = json!("model-call-id");
        assert!(validate_template(&t).is_err());
    }
    #[test]
    fn self_exclusion_uses_exact_source_id_not_identical_position() {
        let at_same_position = |id: &str| Obstacle::Box {
            id: id.into(),
            volume: BoxVolume {
                center: [0., 1., 0.],
                half_extents: [1., 1., 1.],
                yaw: 0.,
            },
        };
        let mut obstacles = vec![
            at_same_position("collision.jukebox"),
            at_same_position("wall"),
            at_same_position("wish_machine.collision"),
        ];
        retain_unreplaced(
            &mut obstacles,
            &std::collections::BTreeSet::from(["collision.jukebox".into()]),
        );
        assert_eq!(
            obstacles.iter().map(obstacle_id).collect::<Vec<_>>(),
            vec!["wall", "wish_machine.collision"]
        );
    }
    #[test]
    fn enabled_bundled_device_can_move_but_cannot_replace_unrelated_basic_object() {
        let t = json!({"id":"prop.jukebox","renderer":"builtin.jukebox","size":[1,2,3],"collisionSourceID":"collision.jukebox"});
        let mut state = json!({"objectStates":{"prop.jukebox":{"isEnabled":true,"metadata":{}}}});
        state["objectStates"]["prop.jukebox"]["metadata"][DEVICE] = json!(encode(&t).unwrap());
        assert!(can_place(&state, &t).is_ok());
        state["objectStates"]["prop.jukebox"]["metadata"][DEVICE] = json!("{}");
        assert!(can_place(&state, &t).is_err());
    }
    #[test]
    fn durable_receipt_retry_survives_changed_world_revision_and_fences_identity() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let p = json!({"worldID":"w","residentScope":"s","hostSessionID":"h","requestID":"r",
            "expectedRevision":7,"expectedLayoutRevision":3,"geometryID":"g",
            "authority":{"kind":"ui","intentID":"i","capability":"c"}});
        let output = json!({"objectID":"device","commit":{"revision":8}});
        c.execute(
            "INSERT INTO world_device_commands VALUES(?1,?2,?3,?4)",
            params!["w", "r", encode(&p).unwrap(), encode(&output).unwrap()],
        )
        .unwrap();
        let tx = c.transaction().unwrap();
        // No world snapshot table exists: receipt replay must precede current-state lookup.
        assert_eq!(
            request(
                &tx,
                Path::new("/private/tmp"),
                "world_device_command",
                p.clone()
            )
            .unwrap(),
            output
        );
        let mut changed = p.clone();
        changed["hostSessionID"] = json!("other-host");
        assert_eq!(
            request(
                &tx,
                Path::new("/private/tmp"),
                "world_device_command",
                changed
            )
            .unwrap_err(),
            "request_id_conflict"
        );
        let mut changed = p;
        changed["authority"]["capability"] = json!("other-cap");
        assert_eq!(
            request(
                &tx,
                Path::new("/private/tmp"),
                "world_device_command",
                changed
            )
            .unwrap_err(),
            "request_id_conflict"
        );
    }
    #[test]
    fn catalog_registers_only_existing_basic_raw_functions_without_pose_change() {
        let mut c = Connection::open_in_memory().unwrap();
        crate::store::migrate(&mut c).unwrap();
        let tx = c.transaction().unwrap();
        let transform = json!({"position":{"x":4,"y":0.3,"z":-2},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}});
        let state = json!({"worldID":"private","revision":0,"layoutRevision":0,"worldTime":1760000000000i64,"agentTransform":transform,"activeActivity":null,"heldProp":null,"objectStates":{"prop.jukebox":{"isEnabled":true,"transform":transform,"metadata":{"unrelated":"preserved"}}}});
        let raw = encode(&state).unwrap();
        world::import(
            &tx,
            &world::ImportRequest {
                world_id: "private".into(),
                request_id: "import".into(),
                producer: None,
                package_id: "private".into(),
                package_version: "1".into(),
                state_sha256: digest(raw.as_bytes()),
                state_json: raw,
            },
        )
        .unwrap();
        let points = json!([{"role":"interact","activityID":"music.listen","kind":"standingSpot","position":[-0.7,0.0068,0],"yaw":-1.57}]);
        let p = json!({"worldID":"private","residentScope":"s","hostSessionID":"h","templates":[{"id":"prop.jukebox","renderer":"builtin.jukebox","size":[1,2,3],"functionPoints":points},{"id":"wish_machine.device","renderer":"builtin.wish_machine","size":[1,2,3],"functionPoints":[]}]});
        let first = request(
            &tx,
            Path::new("/private/tmp"),
            "world_device_catalog_install",
            p.clone(),
        )
        .unwrap();
        let next = &first["snapshot"]["record"]["state"];
        assert_eq!(next["objectStates"]["prop.jukebox"]["transform"], transform);
        assert_eq!(
            next["objectStates"]["prop.jukebox"]["metadata"]["unrelated"],
            "preserved"
        );
        assert!(next["objectStates"].get("wish_machine.device").is_none());
        let declared: Value = serde_json::from_str(
            next["objectStates"]["prop.jukebox"]["metadata"]["gmgn.prop-function-points.v1"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            declared,
            json!({"objectID":"prop.jukebox","functionPoints":points})
        );
        assert_eq!(next["layoutRevision"], 1);
        let again = request(
            &tx,
            Path::new("/private/tmp"),
            "world_device_catalog_install",
            p.clone(),
        )
        .unwrap();
        assert_eq!(again["didCommit"], false);
        assert_eq!(again["snapshot"], first["snapshot"]);
        let mut invalid = p;
        invalid["templates"][0]["id"] = json!("wall");
        assert_eq!(
            request(
                &tx,
                Path::new("/private/tmp"),
                "world_device_catalog_install",
                invalid
            )
            .unwrap_err(),
            "world_device_invalid_catalog"
        );
    }
    #[test]
    fn catalog_dimensions_and_renderer_are_authoritative() {
        let wish: Value = serde_json::from_str(include_str!(
            "../../../apps/macos/Resources/Worlds/marble-living-cabin/wish-machine.json"
        ))
        .unwrap();
        assert!(validate_template(&wish).is_ok());
        let declaration: Value =
            serde_json::from_str(&function_points(&wish).unwrap().unwrap()).unwrap();
        assert_eq!(declaration["functionPoints"], wish["functionPoints"]);
        assert!(validate_template(
            &json!({"id":"prop.jukebox","renderer":"builtin.jukebox","size":[1,2,3]})
        )
        .is_ok());
        assert!(validate_template(
            &json!({"id":"base","renderer":"model-anything","size":[1,2,3]})
        )
        .is_err());
        assert!(validate_template(
            &json!({"id":"base","renderer":"builtin.jukebox","size":[0,2,3]})
        )
        .is_err());
    }
    #[test]
    fn basic_objects_cannot_be_overwritten_or_deleted() {
        let t = json!({"id":"base","renderer":"builtin.jukebox","size":[1,2,3]});
        let mut basic = json!({"objectStates":{"base":{"isEnabled":true,"metadata":{}}}});
        basic["objectStates"]["base"]["metadata"][DEVICE] = json!("declared");
        assert!(can_place(&basic, &t).is_err());
        let mut generated = json!({"objectStates":{"base":{"isEnabled":false,"metadata":{}}}});
        generated["objectStates"]["base"]["metadata"][world::GENERATED_PROP_KEY] = json!("owned");
        assert!(can_place(&generated, &t).is_err());
        assert!(
            pointer(&json!({"op":"delete","templateID":"base","position":[0,0,0],"yaw":0}))
                .is_err()
        );
    }
}
