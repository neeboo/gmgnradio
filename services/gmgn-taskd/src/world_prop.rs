//! Typed prop authority. Native supplies measured geometry and loader facts,
//! never a candidate document or an `allowed` decision.
use crate::{
    model::{digest, Result},
    placement::{self, BoxVolume, Column, EvaluateRequest, Footprint, Grid, Layer, Obstacle},
    support_grid, world,
};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};
type V = [f32; 3];
type Triangle = [V; 3];
const GRIP: &str = "gmgn.prop-grip.v1";
const REACH: f32 = 0.6;
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Command {
    op: String,
    #[serde(rename = "objectID", default)]
    object_id: Option<String>,
    #[serde(default)]
    position: Option<V>,
    #[serde(default)]
    yaw: Option<f32>,
    #[serde(rename = "surfaceID", default)]
    surface_id: Option<String>,
    #[serde(default)]
    slot: Option<String>,
    #[serde(default)]
    offset: Option<V>,
    #[serde(default)]
    rotation: Option<[f32; 4]>,
    #[serde(default)]
    reason: Option<String>,
    #[serde(default)]
    target_longest_edge: Option<f32>,
    #[serde(rename = "templateID", default)]
    template_id: Option<String>,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RegistrationMeasurement {
    blob_ref: String,
    #[serde(deserialize_with = "crate::placement::geometry_wire::deserialize_triangles")]
    triangles: Vec<Triangle>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MeshFact {
    #[serde(rename = "assetID")]
    asset_id: String,
    blob_ref: String,
    #[serde(deserialize_with = "crate::placement::geometry_wire::deserialize_triangles")]
    triangles: Vec<Triangle>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AvatarFact {
    #[serde(rename = "assetID")]
    asset_id: String,
    selection_revision: u64,
    format: String,
    slots: Vec<String>,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Binding {
    #[serde(rename = "objectID")]
    object_id: String,
    metadata_key: String,
    #[serde(rename = "metadataSHA256")]
    metadata_sha256: String,
}
#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct NativeFacts {
    environment_blob_ref: String,
    environment: support_grid::DeriveRequest,
    avatar: AvatarFact,
    objects: BTreeMap<String, MeshFact>,
    #[serde(default)]
    activity_bindings: BTreeMap<String, Binding>,
    #[serde(default)]
    anchor_positions: BTreeMap<String, V>,
}
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS world_prop_native(world TEXT NOT NULL,scope TEXT NOT NULL,host TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(world,scope,host));
CREATE TABLE IF NOT EXISTS world_prop_intents(id TEXT PRIMARY KEY,world TEXT NOT NULL,scope TEXT NOT NULL,host TEXT NOT NULL,capability TEXT NOT NULL,revision INTEGER NOT NULL,layout INTEGER NOT NULL,expires INTEGER NOT NULL,command TEXT NOT NULL,used INTEGER NOT NULL DEFAULT 0);
CREATE TABLE IF NOT EXISTS world_prop_commands(world TEXT NOT NULL,request TEXT NOT NULL,input TEXT NOT NULL,output TEXT NOT NULL,PRIMARY KEY(world,request));").map_err(|_|"storage_unavailable")
}
pub fn recover(c: &Connection) -> Result<()> {
    c.execute_batch("DELETE FROM world_prop_native;DELETE FROM world_prop_intents;")
        .map_err(|_| "storage_unavailable")
}
fn now() -> Result<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|v| v.as_millis() as u64)
        .map_err(|_| "world_prop_clock_unavailable")
}
fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("world_prop_invalid_input")
}
fn encode(v: &impl Serialize) -> Result<String> {
    crate::canonical_json::to_string(
        &serde_json::to_value(v).map_err(|_| "world_prop_invalid_input")?,
    )
    .map_err(|_| "world_prop_invalid_input")
}
fn vector(v: &Value) -> Result<V> {
    let a = [v["x"].as_f64(), v["y"].as_f64(), v["z"].as_f64()];
    let mut r = [0.; 3];
    for (i, n) in a.into_iter().enumerate() {
        r[i] = n
            .filter(|n| n.is_finite() && n.abs() <= 100000.)
            .ok_or("world_prop_invalid_state")? as f32;
    }
    Ok(r)
}
fn xyz(v: V) -> Value {
    json!({"x":v[0],"y":v[1],"z":v[2]})
}
fn generated(item: &Value) -> Result<Value> {
    serde_json::from_str(
        item["metadata"][world::GENERATED_PROP_KEY]
            .as_str()
            .ok_or("world_prop_basic_object")?,
    )
    .map_err(|_| "world_prop_invalid_state")
}
fn size(prop: &Value) -> Result<V> {
    let value =
        if prop["sizeLocked"] == true || prop.get("sizeIntent").is_some_and(|v| !v.is_null()) {
            &prop["size"]
        } else {
            prop.pointer("/authoritativeSize/dimensions")
                .unwrap_or(&prop["size"])
        };
    let v = vector(value)?;
    if v.iter().any(|n| *n <= 0. || *n > 100.) {
        return Err("world_prop_invalid_state");
    }
    Ok(v)
}
fn asset_digest(asset: &str) -> Result<String> {
    let hash = asset
        .rsplit(':')
        .next()
        .unwrap_or(asset)
        .to_ascii_lowercase();
    if hash.len() != 64 || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("world_prop_asset_unverified");
    }
    Ok(hash)
}
fn present(c: &Connection, root: &Path, hash: &str) -> Result<()> {
    let r = world::blob_get(
        c,
        root,
        &world::BlobGetRequest {
            sha256: hash.into(),
        },
    )?;
    if r["blob"]["localState"] != "present" {
        return Err("world_prop_asset_unverified");
    }
    Ok(())
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
fn validate_facts(
    c: &Connection,
    root: &Path,
    _p: &Value,
    state: &Value,
    f: &NativeFacts,
) -> Result<()> {
    present(c, root, &asset_digest(&f.environment_blob_ref)?)?;
    if f.avatar.asset_id.is_empty()
        || f.avatar.asset_id.len() > 256
        || !["pmx", "vrm", "orb"].contains(&f.avatar.format.as_str())
        || f.avatar
            .slots
            .iter()
            .any(|s| !["rightHand", "back", "waist"].contains(&s.as_str()))
        || f.avatar.format == "orb" && !f.avatar.slots.is_empty()
    {
        return Err("world_prop_invalid_native_facts");
    }
    let mut total = f.environment.triangles.len();
    for (id, m) in &f.objects {
        let prop = generated(&state["objectStates"][id])?;
        if prop["objectID"] != *id
            || prop["assetID"] != m.asset_id
            || asset_digest(&m.asset_id)? != asset_digest(&m.blob_ref)?
            || m.triangles.is_empty()
        {
            return Err("world_prop_invalid_native_facts");
        }
        present(c, root, &asset_digest(&m.blob_ref)?)?;
        total += m.triangles.len();
    }
    if total > 300000 || f.environment.triangles.is_empty() {
        return Err("world_prop_invalid_native_facts");
    }
    for t in f
        .environment
        .triangles
        .iter()
        .chain(f.objects.values().flat_map(|m| m.triangles.iter()))
    {
        if t.iter()
            .flatten()
            .any(|n| !n.is_finite() || n.abs() > 100000.)
        {
            return Err("world_prop_invalid_native_facts");
        }
    }
    if f.anchor_positions.len() > 4096
        || f.anchor_positions
            .values()
            .flatten()
            .any(|n| !n.is_finite())
    {
        return Err("world_prop_invalid_native_facts");
    }
    // Bindings are rechecked against the live catalog during the command.
    for b in f.activity_bindings.values() {
        if ![
            "gmgn.prop-seat.v1",
            "gmgn.prop-function-points.v1",
            "gmgn.prop-capability.v1",
        ]
        .contains(&b.metadata_key.as_str())
            || state["objectStates"][&b.object_id]["metadata"][&b.metadata_key]
                .as_str()
                .is_none_or(|v| digest(v.as_bytes()) != b.metadata_sha256)
        {
            return Err("world_prop_invalid_native_facts");
        }
    }
    Ok(())
}
fn observation(
    c: &Connection,
    p: &Value,
    state: &Value,
    root: &Path,
) -> Result<(NativeFacts, Grid)> {
    let raw: Option<String> = c
        .query_row(
            "SELECT payload FROM world_prop_native WHERE world=?1 AND scope=?2 AND host=?3",
            params![
                text(p, "worldID")?,
                text(p, "residentScope")?,
                text(p, "hostSessionID")?
            ],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let v: Value = serde_json::from_str(&raw.ok_or("world_prop_native_not_ready")?)
        .map_err(|_| "world_prop_invalid_state")?;
    if p["geometryID"] != v["geometryID"]
        || v["layoutRevision"] != state["layoutRevision"]
        || now()?.saturating_sub(
            v["observedAtMS"]
                .as_u64()
                .ok_or("world_prop_invalid_state")?,
        ) > 6000
    {
        return Err("world_prop_stale_native_facts");
    }
    let f: NativeFacts = serde_json::from_value(v["facts"].clone())
        .map_err(|_| "world_prop_invalid_native_facts")?;
    validate_facts(c, root, p, state, &f)?;
    let grid: Grid =
        serde_json::from_value(v["grid"].clone()).map_err(|_| "world_prop_invalid_state")?;
    Ok((f, grid))
}

/// Public dispatch runs inside the caller's existing SQLite transaction.
/// Builtin-device authority shares exactly the same native observation gate.
/// No caller-selected obstacle exclusions or candidate placement enter here.
pub(crate) fn device_environment(
    tx: &Transaction<'_>,
    root: &Path,
    p: &Value,
    state: &Value,
) -> Result<(support_grid::DeriveRequest, Grid, Vec<Obstacle>)> {
    let (facts, grid) = observation(tx, p, state, root)?;
    let obstacles = obstacles(state, &facts, "")?;
    Ok((facts.environment, grid, obstacles))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LifecycleReturnEvent {
    kind: String,
    #[serde(rename = "objectID")]
    object_id: String,
    #[serde(rename = "previousAvatarAssetID")]
    previous_avatar_asset_id: String,
    #[serde(rename = "heldBindingSHA256")]
    held_binding_sha256: String,
    #[serde(rename = "avatarAssetID", default)]
    avatar_asset_id: Option<String>,
    #[serde(default)]
    selection_revision: Option<u64>,
    #[serde(rename = "selectedWorldID", default)]
    selected_world_id: Option<String>,
}
fn system_return(tx: &Transaction<'_>, root: &Path, p: &Value) -> Result<Value> {
    let input = encode(p)?;
    if p["readBinding"] == true {
        let snap = snapshot(tx, p)?;
        let h = &snap["record"]["state"]["heldProp"];
        if !h.is_object() {
            return Ok(json!({"held":false,"snapshot":snap}));
        }
        return Ok(
            json!({"held":true,"heldBindingSHA256":digest(encode(h)?.as_bytes()),"snapshot":snap}),
        );
    }
    let request_id = text(p, "requestID")?;
    let old: Option<(String, String)> = tx
        .query_row(
            "SELECT input,output FROM world_prop_commands WHERE world=?1 AND request=?2",
            params![text(p, "worldID")?, request_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((prior, output)) = old {
        return if prior == input {
            serde_json::from_str(&output).map_err(|_| "world_prop_invalid_state")
        } else {
            Err("world_prop_request_conflict")
        };
    }
    if p.get("command").is_some() || p.get("candidate").is_some() || p.get("authority").is_some() {
        return Err("world_prop_invalid_input");
    }
    let snap = snapshot(tx, p)?;
    let state = &snap["record"]["state"];
    if p["expectedRevision"] != snap["record"]["recordRevision"]
        || p["expectedLayoutRevision"] != state["layoutRevision"]
    {
        return Err("revision_conflict");
    }
    let event: LifecycleReturnEvent =
        serde_json::from_value(p["event"].clone()).map_err(|_| "world_prop_invalid_input")?;
    let h = held(state, &event.object_id)?;
    if h["avatarAssetID"] != event.previous_avatar_asset_id
        || digest(encode(h)?.as_bytes()) != event.held_binding_sha256
    {
        return Err("world_prop_system_binding_changed");
    }
    let original = h["returnState"].clone();
    let prop = generated(&state["objectStates"][&event.object_id])?;
    if generated(&original)? != prop {
        return Err("world_prop_invalid_state");
    }
    let mut rebound = None;
    match event.kind.as_str() {
        "avatar_changed" | "avatar_changed_rebind" => {
            if event.selected_world_id.is_some() {
                return Err("world_prop_invalid_input");
            }
            let (facts, grid) = observation(tx, p, state, root)?;
            if event.avatar_asset_id.as_deref() != Some(facts.avatar.asset_id.as_str())
                || event.selection_revision != Some(facts.avatar.selection_revision)
                || facts.avatar.asset_id == event.previous_avatar_asset_id
            {
                return Err("world_prop_system_event_stale");
            }
            if event.kind == "avatar_changed_rebind" {
                let command: Command = serde_json::from_value(
                    json!({"op":"hold","objectID":event.object_id,"slot":h["hand"]}),
                )
                .map_err(|_| "world_prop_invalid_state")?;
                validate_command(&command)?;
                let (mut next, receipt) = reduce(state, &command, Some(&(facts, grid)))?;
                // Rebinding changes the live grip, never the durable original
                // return reservation that was created when this object was held.
                next["heldProp"]["returnState"] = original.clone();
                rebound = Some((next, receipt));
            } else if original["isEnabled"] == true {
                validate_loaded(state, &event.object_id, &prop, &facts)?;
                let (position, _) = evaluate_pose(
                    state,
                    &event.object_id,
                    &prop,
                    vector(&original["transform"]["position"])?,
                    yaw(&original)?,
                    &facts,
                    &grid,
                    None,
                )?;
                if (position[1] - vector(&original["transform"]["position"])?[1]).abs() > 0.005 {
                    return Err("world_prop_placement_blocked");
                }
            }
        }
        "world_detached" => {
            if event.avatar_asset_id.is_some()
                || event.selection_revision.is_some()
                || event.selected_world_id.as_deref() == Some(text(p, "worldID")?)
            {
                return Err("world_prop_system_event_stale");
            }
            // This is restoration of the existing durable return reservation,
            // not a new placement. The detached renderer supplies no fake mesh.
        }
        "user_stop" | "resident_pause" | "application_exit" => {
            if event.avatar_asset_id.is_some()
                || event.selection_revision.is_some()
                || event.selected_world_id.is_some()
            {
                return Err("world_prop_invalid_input");
            }
        }
        _ => return Err("world_prop_invalid_input"),
    }
    let (mut next, receipt) = rebound.unwrap_or_else(|| {
        let mut next = state.clone();
        next["objectStates"][&event.object_id] = original;
        next["heldProp"] = Value::Null;
        next["layoutUndo"] = Value::Null;
        (
            next,
            json!({"op":"returnHeld","objectID":event.object_id,"event":event.kind}),
        )
    });
    next["revision"] = json!(state["revision"]
        .as_u64()
        .ok_or("world_prop_invalid_state")?
        .checked_add(1)
        .ok_or("world_prop_invalid_state")?);
    next["layoutRevision"] = json!(state["layoutRevision"]
        .as_u64()
        .ok_or("world_prop_invalid_state")?
        .checked_add(1)
        .ok_or("world_prop_invalid_state")?);
    let commit = world::commit_prop(
        tx,
        &world::CommitRequest {
            world_id: text(p, "worldID")?.into(),
            request_id: format!("prop:{request_id}"),
            expected_revision: snap["record"]["recordRevision"]
                .as_i64()
                .ok_or("world_prop_invalid_state")?,
            producer: Some("world-prop-lifecycle".into()),
            intent: Some(
                json!({"kind":"prop.lifecycle.returnHeld","event":event.kind,"objectID":event.object_id,"heldBindingSHA256":event.held_binding_sha256}),
            ),
            ops: vec![world::Op {
                op: "replaceState".into(),
                state: Some(next),
                ..Default::default()
            }],
        },
    )?;
    let out = json!({"receipt":receipt,"commit":commit,"snapshot":snapshot(tx,p)?});
    tx.execute(
        "INSERT INTO world_prop_commands VALUES(?1,?2,?3,?4)",
        params![text(p, "worldID")?, request_id, input, encode(&out)?],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(out)
}
pub fn request(tx: &Transaction<'_>, root: &Path, method: &str, p: Value) -> Result<Value> {
    text(&p, "worldID")?;
    text(&p, "residentScope")?;
    text(&p, "hostSessionID")?;
    if method == "world_prop_system_avatar_return" {
        return system_return(tx, root, &p);
    }
    if method == "world_prop_receipt" {
        let saved: Option<(String, String)> = tx
            .query_row(
                "SELECT input,output FROM world_prop_commands WHERE world=?1 AND request=?2",
                params![text(&p, "worldID")?, text(&p, "requestID")?],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        let Some((input, output)) = saved else {
            return Ok(json!({"found":false}));
        };
        let input: Value = serde_json::from_str(&input).map_err(|_| "world_prop_invalid_state")?;
        let context = if input["params"].is_object() {
            &input["params"]
        } else {
            &input
        };
        if context["residentScope"] != p["residentScope"]
            || context["hostSessionID"] != p["hostSessionID"]
        {
            return Err("world_prop_unauthorized");
        }
        let output: Value =
            serde_json::from_str(&output).map_err(|_| "world_prop_invalid_state")?;
        return Ok(json!({"found":true,"output":output}));
    }
    let snap = snapshot(tx, &p)?;
    let state = snap["record"]["state"].clone();
    if !state.is_object() {
        return Err("world_prop_invalid_state");
    }
    if method == "world_prop_read" {
        return inventory(&state);
    }
    if matches!(
        method,
        "world_prop_register" | "world_prop_rebase" | "world_prop_output_preview"
    ) {
        return register_or_rebase(tx, root, method, &p, &snap);
    }
    if method == "world_prop_surfaces" {
        let (_, grid) = observation(tx, &p, &state, root)?;
        let mut surfaces: BTreeMap<i32, Vec<&crate::placement::Layer>> = BTreeMap::new();
        for layer in &grid.layers {
            surfaces.entry(layer.layer).or_default().push(layer);
        }
        let surfaces: Vec<Value> = surfaces.into_iter().map(|(id, layers)| {
            let minimum_x = layers.iter().map(|l| l.column.x).min().unwrap();
            let maximum_x = layers.iter().map(|l| l.column.x).max().unwrap();
            let minimum_z = layers.iter().map(|l| l.column.z).min().unwrap();
            let maximum_z = layers.iter().map(|l| l.column.z).max().unwrap();
            json!({"surfaceID":format!("grid.layer.{id}"),"layerID":id,"height":layers[0].support_height,"count":layers.len(),"bounds":{"minimum":[minimum_x as f32*grid.spacing,minimum_z as f32*grid.spacing],"maximum":[(maximum_x+1) as f32*grid.spacing,(maximum_z+1) as f32*grid.spacing]}})
        }).collect();
        return Ok(json!({"layoutRevision":state["layoutRevision"],"surfaces":surfaces}));
    }
    if method == "world_prop_observe" {
        if p["expectedRevision"] != snap["record"]["recordRevision"]
            || p["layoutRevision"] != state["layoutRevision"]
        {
            return Err("revision_conflict");
        }
        let mut f: NativeFacts = serde_json::from_value(p["facts"].clone())
            .map_err(|_| "world_prop_invalid_native_facts")?;
        let prior: Option<String> = tx
            .query_row(
                "SELECT payload FROM world_prop_native WHERE world=?1 AND scope=?2 AND host=?3",
                params![
                    text(&p, "worldID")?,
                    text(&p, "residentScope")?,
                    text(&p, "hostSessionID")?
                ],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        if let Some(prior) = prior {
            let prior: Value =
                serde_json::from_str(&prior).map_err(|_| "world_prop_invalid_state")?;
            if prior["facts"]["avatar"]["selectionRevision"]
                .as_u64()
                .is_some_and(|n| n > f.avatar.selection_revision)
            {
                return Err("world_prop_stale_native_facts");
            }
        }
        validate_facts(tx, root, &p, &state, &f)?;
        f.environment.seed = vector(&state["agentTransform"]["position"])?;
        let grid = support_grid::derive(f.environment.clone())
            .map_err(|_| "world_prop_invalid_native_facts")?
            .grid;
        let geometry_id = uuid::Uuid::new_v4().to_string();
        let encoded = encode(&f)?;
        let hash = digest(encoded.as_bytes());
        let v = json!({"geometryID":geometry_id,"meshSHA256":hash,"observedAtMS":now()?,"layoutRevision":state["layoutRevision"],"facts":f,"grid":grid});
        tx.execute("INSERT INTO world_prop_native VALUES(?1,?2,?3,?4) ON CONFLICT(world,scope,host) DO UPDATE SET payload=excluded.payload",params![text(&p,"worldID")?,text(&p,"residentScope")?,text(&p,"hostSessionID")?,encode(&v)?]).map_err(|_|"storage_unavailable")?;
        return Ok(
            json!({"geometryID":geometry_id,"meshSHA256":hash,"layoutRevision":state["layoutRevision"]}),
        );
    }
    if method == "world_prop_ui_intent" {
        if p["expectedRevision"] != snap["record"]["recordRevision"]
            || p["expectedLayoutRevision"] != state["layoutRevision"]
        {
            return Err("revision_conflict");
        }
        let command: Command =
            serde_json::from_value(p["command"].clone()).map_err(|_| "world_prop_invalid_input")?;
        validate_command(&command)?;
        let id = uuid::Uuid::new_v4().to_string();
        let capability = uuid::Uuid::new_v4().to_string();
        let expires = now()? + 10000;
        tx.execute(
            "INSERT INTO world_prop_intents VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,0)",
            params![
                id,
                text(&p, "worldID")?,
                text(&p, "residentScope")?,
                text(&p, "hostSessionID")?,
                capability,
                snap["record"]["recordRevision"]
                    .as_i64()
                    .ok_or("world_prop_invalid_state")?,
                state["layoutRevision"]
                    .as_i64()
                    .ok_or("world_prop_invalid_state")?,
                expires,
                encode(&command)?
            ],
        )
        .map_err(|_| "storage_unavailable")?;
        return Ok(json!({"intentID":id,"capability":capability,"expiresAtMS":expires}));
    }
    if !["world_prop_preview", "world_prop_command"].contains(&method) {
        return Err("unknown_method");
    }
    let request_id = if method == "world_prop_command" {
        Some(text(&p, "requestID")?)
    } else {
        None
    };
    let canonical = encode(&p)?;
    if let Some(id) = request_id {
        let old: Option<(String, String)> = tx
            .query_row(
                "SELECT input,output FROM world_prop_commands WHERE world=?1 AND request=?2",
                params![text(&p, "worldID")?, id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        if let Some((input, output)) = old {
            if input != canonical {
                return Err("world_prop_request_conflict");
            }
            let mut v: Value =
                serde_json::from_str(&output).map_err(|_| "world_prop_invalid_state")?;
            v["replayed"] = json!(true);
            return Ok(v);
        }
    }
    if p["expectedRevision"] != snap["record"]["recordRevision"]
        || p["expectedLayoutRevision"] != state["layoutRevision"]
    {
        return Err("revision_conflict");
    }
    let command = if method == "world_prop_preview" {
        serde_json::from_value(p["command"].clone()).map_err(|_| "world_prop_invalid_input")?
    } else {
        authorize(tx, &p, &snap)?
    };
    validate_command(&command)?;
    let mut working = state.clone();
    let mut revision = snap["record"]["recordRevision"]
        .as_i64()
        .ok_or("world_prop_invalid_state")?;
    let needs_geometry = matches!(
        command.op.as_str(),
        "place"
            | "hold"
            | "adjustGrip"
            | "returnHeld"
            | "dropHeld"
            | "undo"
            | "resize"
            | "enableCapability"
    );
    let geometry = if needs_geometry {
        Some(observation(tx, &p, &state, root)?)
    } else {
        None
    };
    let binding_facts = if geometry.is_none() {
        let raw: Option<String> = tx
            .query_row(
                "SELECT payload FROM world_prop_native WHERE world=?1 AND scope=?2 AND host=?3",
                params![
                    text(&p, "worldID")?,
                    text(&p, "residentScope")?,
                    text(&p, "hostSessionID")?
                ],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        raw.and_then(|raw| serde_json::from_str::<Value>(&raw).ok())
            .filter(|v| {
                v["layoutRevision"] == state["layoutRevision"]
                    && v["observedAtMS"]
                        .as_u64()
                        .is_some_and(|n| now().is_ok_and(|t| t.saturating_sub(n) <= 6000))
            })
            .and_then(|v| serde_json::from_value::<NativeFacts>(v["facts"].clone()).ok())
    } else {
        None
    };
    let stop = if method == "world_prop_command" {
        stop_bound_activity(
            tx,
            &p,
            &command,
            &working,
            geometry.as_ref().map(|g| &g.0).or(binding_facts.as_ref()),
            revision,
        )?
    } else {
        None
    };
    if let Some(v) = &stop {
        working = v["snapshot"]["record"]["state"].clone();
        revision = v["snapshot"]["record"]["recordRevision"]
            .as_i64()
            .ok_or("world_prop_invalid_state")?;
    }
    if method == "world_prop_preview" {
        if command.op != "place" {
            return Err("world_prop_invalid_input");
        }
        let (f, g) = geometry.as_ref().ok_or("world_prop_native_not_ready")?;
        let id = command
            .object_id
            .as_deref()
            .ok_or("world_prop_invalid_input")?;
        let prop = generated(&working["objectStates"][id])?;
        validate_loaded(&working, id, &prop, f)?;
        let size = size(&prop)?;
        let position = command.position.ok_or("world_prop_invalid_input")?;
        let yaw = command.yaw.ok_or("world_prop_invalid_input")?;
        let anchor = Column {
            x: ((position[0] - g.spacing * 0.5) / g.spacing).round() as i32,
            z: ((position[2] - g.spacing * 0.5) / g.spacing).round() as i32,
        };
        let mut footprint = Footprint {
            size: [size[0], size[2]],
            yaw,
            center_offset: [0.; 2],
        };
        let base = footprint.center(anchor, g.spacing);
        footprint.center_offset = [position[0] - base[0], position[2] - base[1]];
        let result = reduce(&working, &command, geometry.as_ref());
        let (allowed, reason, receipt) = match result {
            Ok((_, receipt)) => (true, Value::Null, receipt),
            Err(e)
                if [
                    "world_prop_placement_blocked",
                    "world_prop_resident_blocked",
                    "world_prop_route_blocked",
                    "world_prop_object_held",
                ]
                .contains(&e) =>
            {
                (false, json!(e), Value::Null)
            }
            Err(e) => return Err(e),
        };
        let columns:Vec<Value>=footprint.columns(anchor,g.spacing).into_iter().map(|column| {
            let height=g.layers.iter().filter(|l|l.column==column && command.surface_id.as_deref().is_none_or(|s|s==format!("grid.layer.{}",l.layer)||s=="floor"&&l.layer==0)).min_by(|a,b|(a.support_height-position[1]).abs().total_cmp(&(b.support_height-position[1]).abs())).map(|l|l.support_height);
            json!({"column":column,"height":height.unwrap_or(position[1]),"hasSupport":height.is_some(),"canPlace":allowed&&height.is_some()})
        }).collect();
        return Ok(
            json!({"canPlace":allowed,"reason":reason,"receipt":receipt,"expectedRevision":revision,"spacing":g.spacing,"columns":columns}),
        );
    }
    let (next, receipt) = reduce(&working, &command, geometry.as_ref())?;
    let commit = if next == working {
        Value::Null
    } else {
        world::commit_prop(
            tx,
            &world::CommitRequest {
                world_id: text(&p, "worldID")?.into(),
                request_id: format!("prop:{}", request_id.unwrap()),
                expected_revision: revision,
                producer: Some("world-prop".into()),
                intent: Some(
                    json!({"kind":"prop.command","op":command.op,"objectID":command.object_id}),
                ),
                ops: vec![world::Op {
                    op: "replaceState".into(),
                    state: Some(next),
                    ..Default::default()
                }],
            },
        )?
    };
    let out =
        json!({"receipt":receipt,"commit":commit,"snapshot":snapshot(tx,&p)?,"activityStop":stop});
    tx.execute(
        "INSERT INTO world_prop_commands VALUES(?1,?2,?3,?4)",
        params![
            text(&p, "worldID")?,
            request_id.unwrap(),
            canonical,
            encode(&out)?
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(out)
}

fn register_or_rebase(
    tx: &Transaction<'_>,
    root: &Path,
    method: &str,
    p: &Value,
    snap: &Value,
) -> Result<Value> {
    let preview = method == "world_prop_output_preview";
    let request_id = text(p, "requestID")?;
    let input = encode(&json!({"method":method,"params":p}))?;
    let saved: Option<(String, String)> = tx
        .query_row(
            "SELECT input,output FROM world_prop_commands WHERE world=?1 AND request=?2",
            params![text(p, "worldID")?, request_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((old, result)) = saved.filter(|_| !preview) {
        if old != input {
            return Err("world_prop_request_conflict");
        }
        let mut result: Value =
            serde_json::from_str(&result).map_err(|_| "world_prop_invalid_state")?;
        result["replayed"] = json!(true);
        return Ok(result);
    }
    let state = &snap["record"]["state"];
    if p["expectedRevision"] != snap["record"]["recordRevision"]
        || p["expectedLayoutRevision"] != state["layoutRevision"]
    {
        return Err("revision_conflict");
    }
    let wish_id =
        uuid::Uuid::parse_str(text(p, "wishID")?).map_err(|_| "world_prop_invalid_input")?;
    let mut query = tx
        .prepare("SELECT payload FROM wish_control_documents WHERE session=?1")
        .map_err(|_| "storage_unavailable")?;
    let rows = query
        .query_map([text(p, "hostSessionID")?], |r| r.get::<_, String>(0))
        .map_err(|_| "storage_unavailable")?;
    let mut found = None;
    for row in rows {
        let archive: Value = serde_json::from_str(&row.map_err(|_| "storage_unavailable")?)
            .map_err(|_| "world_prop_invalid_state")?;
        for wish in archive["jobs"].as_array().into_iter().flatten() {
            if wish["id"]
                .as_str()
                .and_then(|s| uuid::Uuid::parse_str(s).ok())
                == Some(wish_id)
                && wish["worldID"] == p["worldID"]
                && wish["residentScope"] == p["residentScope"]
                && wish["stage"] == if preview { "ready" } else { "claimed" }
            {
                if found.replace(wish.clone()).is_some() {
                    return Err("world_prop_invalid_state");
                }
            }
        }
    }
    let wish = found.ok_or("world_prop_unauthorized")?;
    let id = text(&wish, "objectID")?;
    if state["propTombstones"].get(id).is_some() {
        return Err("world_prop_object_deleted");
    }
    let raw: String = tx
        .query_row(
            "SELECT data FROM jobs WHERE lower(id)=lower(?1)",
            [text(&wish, "jobID")?],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?
        .ok_or("world_prop_asset_unverified")?;
    let stored: crate::model::Stored =
        serde_json::from_str(&raw).map_err(|_| "world_prop_asset_unverified")?;
    let core = stored.job;
    if core.cancel_requested
        || !core.context.as_ref().is_some_and(|c| {
            c.world_id == text(p, "worldID").unwrap_or("")
                && c.resident_scope == text(p, "residentScope").unwrap_or("")
        })
        || core
            .receipt
            .as_ref()
            .is_none_or(|r| r["state"] != "completed")
    {
        return Err("world_prop_asset_unverified");
    }
    let model_path = root.join(format!("{}.glb", core.id));
    if core.local_model_path.as_deref() != model_path.to_str()
        || wish["modelPath"].as_str() != model_path.to_str()
    {
        return Err("world_prop_asset_unverified");
    }
    let bytes = crate::files::read(&model_path, crate::model::MODEL_LIMIT)
        .map_err(|_| "world_prop_asset_unverified")?;
    crate::model::validate_glb(
        &bytes,
        core.receipt.as_ref().ok_or("world_prop_asset_unverified")?,
    )
    .map_err(|_| "world_prop_asset_unverified")?;
    let measured: RegistrationMeasurement = serde_json::from_value(p["measurement"].clone())
        .map_err(|_| "world_prop_invalid_native_facts")?;
    let hash = digest(&bytes);
    if hash != measured.blob_ref
        || measured.triangles.is_empty()
        || measured.triangles.len() > 300000
        || measured
            .triangles
            .iter()
            .flatten()
            .flatten()
            .any(|v| !v.is_finite() || v.abs() > 100000.)
    {
        return Err("world_prop_invalid_native_facts");
    }
    present(tx, root, &hash)?;
    let mut prop = crate::world_prop_measurement::derive(
        &measured.triangles,
        &wish,
        &core.receipt.as_ref().unwrap()["result"],
    )?;
    if let Some(collision) = prop.get("collision") {
        let path = root.join(format!("{}.collider.glb", core.id));
        if core.local_collision_path.as_deref() != path.to_str() {
            return Err("world_prop_asset_unverified");
        }
        let bytes = crate::files::read(&path, crate::model::MODEL_LIMIT)
            .map_err(|_| "world_prop_asset_unverified")?;
        crate::model::validate_collider_glb(&bytes, core.receipt.as_ref().unwrap())
            .map_err(|_| "world_prop_asset_unverified")?;
        if collision["sha256"].as_str() != Some(digest(&bytes).as_str()) {
            return Err("world_prop_asset_unverified");
        }
        present(
            tx,
            root,
            collision["sha256"]
                .as_str()
                .ok_or("world_prop_asset_unverified")?,
        )?;
    }
    prop["objectID"] = json!(id);
    prop["sourceWishID"] = json!(wish_id.to_string().to_uppercase());
    prop["assetID"] = json!(format!("sha256:{hash}"));
    prop["displayName"] = wish["name"].clone();
    if preview {
        return Ok(json!({"prop":prop,"snapshot":snap}));
    }
    let mut next = state.clone();
    let mut unchanged = false;
    if let Some(existing) = state["objectStates"].get(id) {
        let old = generated(existing)?;
        if old["assetID"] != prop["assetID"]
            || old["sourceWishID"]
                .as_str()
                .and_then(|s| uuid::Uuid::parse_str(s).ok())
                != Some(wish_id)
        {
            return Err("world_prop_invalid_state");
        }
        if method == "world_prop_register" {
            prop = old;
            unchanged = true;
        } else {
            // Preserve the archive's identity spelling and user label; only
            // geometric derived fields are candidates for remeasurement.
            for key in ["objectID", "sourceWishID", "assetID", "displayName"] {
                prop[key] = old[key].clone();
            }
            let decision = crate::world_prop_measurement::rebase(
                &old,
                &prop,
                &measured.triangles,
                wish["heightMeters"]
                    .as_f64()
                    .ok_or("world_prop_invalid_state")? as f32,
                "rust-prop",
            )?;
            if decision["verdict"] == "unchanged" {
                prop = old;
                unchanged = true;
            } else {
                prop = decision["prop"].clone();
                next["objectStates"][id]["metadata"][world::GENERATED_PROP_KEY] =
                    json!(encode(&prop)?);
                let factor = size(&prop)?[1]
                    / prop["sourceHeight"]
                        .as_f64()
                        .ok_or("world_prop_invalid_state")? as f32;
                next["objectStates"][id]["transform"]["scale"] =
                    json!({"x":factor,"y":factor,"z":factor});
                if next["heldProp"]["objectID"] == id {
                    next["heldProp"]["returnState"]["metadata"][world::GENERATED_PROP_KEY] =
                        json!(encode(&prop)?);
                    next["heldProp"]["returnState"]["transform"]["scale"] =
                        json!({"x":factor,"y":factor,"z":factor});
                }
                if next["layoutUndo"]["objectID"] == id {
                    next["layoutUndo"] = Value::Null;
                }
            }
        }
    } else {
        if method == "world_prop_rebase" {
            return Err("world_prop_object_not_found");
        }
        if state["objectStates"]
            .as_object()
            .ok_or("world_prop_invalid_state")?
            .values()
            .any(|v| {
                generated(v).ok().is_some_and(|g| {
                    g["sourceWishID"]
                        .as_str()
                        .and_then(|s| uuid::Uuid::parse_str(s).ok())
                        == Some(wish_id)
                })
            })
        {
            return Err("world_prop_invalid_state");
        }
        let factor = size(&prop)?[1]
            / prop["sourceHeight"]
                .as_f64()
                .ok_or("world_prop_invalid_state")? as f32;
        next["objectStates"][id] = json!({"isEnabled":false,"transform":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":factor,"y":factor,"z":factor}},"metadata":{world::GENERATED_PROP_KEY:encode(&prop)?}});
        next["layoutUndo"] = Value::Null;
    }
    if install_reviewed_seat_metadata(&mut next, Some(id))? {
        unchanged = false;
    }
    let receipt = json!({"op":if method=="world_prop_register" {"register"}else{"rebase"},"objectID":id,"unchanged":unchanged});
    let mut commit_revision = snap["record"]["recordRevision"]
        .as_i64()
        .ok_or("world_prop_invalid_state")?;
    let mut activity_stop = Value::Null;
    if !unchanged && method == "world_prop_rebase" {
        let native = if p["geometryID"].is_string() {
            Some(observation(tx, p, state, root)?.0)
        } else {
            None
        };
        let command: Command = serde_json::from_value(json!({"op":"rebase","objectID":id}))
            .map_err(|_| "world_prop_invalid_input")?;
        if let Some(stopped) =
            stop_bound_activity(tx, p, &command, state, native.as_ref(), commit_revision)?
        {
            let stopped_state = &stopped["snapshot"]["record"]["state"];
            for (key, value) in stopped_state
                .as_object()
                .ok_or("world_prop_invalid_state")?
            {
                if ![
                    "objectStates",
                    "layoutRevision",
                    "layoutUndo",
                    "layoutReceipts",
                    "propTombstones",
                    "heldProp",
                ]
                .contains(&key.as_str())
                {
                    next[key] = value.clone();
                }
            }
            for (object, item) in stopped_state["objectStates"]
                .as_object()
                .ok_or("world_prop_invalid_state")?
            {
                if let Some(usage) = item["metadata"].get("gmgn.prop-usage.v1") {
                    next["objectStates"][object]["metadata"]["gmgn.prop-usage.v1"] = usage.clone();
                } else if let Some(metadata) =
                    next["objectStates"][object]["metadata"].as_object_mut()
                {
                    metadata.remove("gmgn.prop-usage.v1");
                }
            }
            commit_revision = stopped["snapshot"]["record"]["recordRevision"]
                .as_i64()
                .ok_or("world_prop_invalid_state")?;
            activity_stop = stopped;
        }
    }
    let commit = if unchanged {
        Value::Null
    } else {
        next["layoutRevision"] = json!(state["layoutRevision"]
            .as_u64()
            .ok_or("world_prop_invalid_state")?
            .checked_add(1)
            .ok_or("world_prop_invalid_state")?);
        next["revision"] = json!(next["revision"]
            .as_u64()
            .ok_or("world_prop_invalid_state")?
            .checked_add(1)
            .ok_or("world_prop_invalid_state")?);
        let op = if method == "world_prop_register" {
            "register"
        } else {
            "rebase"
        };
        next["layoutReceipts"][format!("rust-prop:{request_id}")] = json!({op:{"_0":prop}});
        world::commit_prop(
            tx,
            &world::CommitRequest {
                world_id: text(p, "worldID")?.into(),
                request_id: format!("prop:{request_id}"),
                expected_revision: commit_revision,
                producer: Some("world-prop".into()),
                intent: Some(receipt.clone()),
                ops: vec![world::Op {
                    op: "replaceState".into(),
                    state: Some(next),
                    ..Default::default()
                }],
            },
        )?
    };
    let out = json!({"prop":prop,"receipt":receipt,"commit":commit,"snapshot":snapshot(tx,p)?,"activityStop":activity_stop});
    tx.execute(
        "INSERT INTO world_prop_commands VALUES(?1,?2,?3,?4)",
        params![text(p, "worldID")?, request_id, input, encode(&out)?],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(out)
}

/// Canonical immutable measured facts, never coordinates supplied by a host.
/// Explicit metadata has priority, including malformed metadata: leave it
/// intact so the normal activity validator reports its error.
pub(crate) fn install_reviewed_seat_metadata(
    state: &mut Value,
    object_id: Option<&str>,
) -> Result<bool> {
    let mut changed = false;
    let objects = state["objectStates"]
        .as_object_mut()
        .ok_or("world_prop_invalid_state")?;
    for (id, item) in objects {
        if object_id.is_some_and(|wanted| wanted != id) {
            continue;
        }
        if item["metadata"].get("gmgn.prop-seat.v1").is_some()
            || item["metadata"].get(world::GENERATED_PROP_KEY).is_none()
        {
            continue;
        }
        let prop = generated(item)?;
        if prop["objectID"] != *id {
            return Err("world_prop_invalid_state");
        }
        let asset = prop["assetID"].as_str().ok_or("world_prop_invalid_state")?;
        asset_digest(asset)?;
        if let Some(seat) = crate::world_activity_approach::reviewed_seat_calibration(asset) {
            item["metadata"]["gmgn.prop-seat.v1"] = json!(encode(&seat)?);
            changed = true;
        }
    }
    let refresh_held = object_id.is_none_or(|wanted| state["heldProp"]["objectID"] == wanted);
    if let Some(return_state) = state["heldProp"]
        .get_mut("returnState")
        .filter(|_| refresh_held)
    {
        if return_state["metadata"].get("gmgn.prop-seat.v1").is_none()
            && return_state["metadata"]
                .get(world::GENERATED_PROP_KEY)
                .is_some()
        {
            let prop = generated(return_state)?;
            if let Some(seat) = crate::world_activity_approach::reviewed_seat_calibration(
                prop["assetID"].as_str().ok_or("world_prop_invalid_state")?,
            ) {
                return_state["metadata"]["gmgn.prop-seat.v1"] = json!(encode(&seat)?);
                changed = true;
            }
        }
    }
    Ok(changed)
}

fn validate_command(c: &Command) -> Result<()> {
    if ![
        "place",
        "withdraw",
        "hold",
        "adjustGrip",
        "returnHeld",
        "dropHeld",
        "delete",
        "undo",
        "resize",
        "enableCapability",
    ]
    .contains(&c.op.as_str())
        || c.op != "undo"
            && c.object_id
                .as_ref()
                .is_none_or(|s| s.is_empty() || s.len() > 256)
        || c.position
            .iter()
            .flatten()
            .chain(c.offset.iter().flatten())
            .any(|v| !v.is_finite() || v.abs() > 100000.)
        || c.yaw.is_some_and(|v| !v.is_finite())
        || c.target_longest_edge
            .is_some_and(|v| !v.is_finite() || !(0.02..=3.).contains(&v))
        || c.reason.as_ref().is_some_and(|s| s.chars().count() > 200)
    {
        return Err("world_prop_invalid_input");
    }
    Ok(())
}
fn tool_command(name: &str, a: &Value) -> Result<Command> {
    let op = match name {
        "apply_prop_placement" => "place",
        "withdraw_prop" => "withdraw",
        "hold_prop" => "hold",
        "adjust_held_prop_grip" => "adjustGrip",
        "return_held_prop" => "returnHeld",
        "drop_held_prop" => "dropHeld",
        "delete_prop" => "delete",
        "undo_prop_placement" => "undo",
        "resize_prop" => "resize",
        "enable_prop_capability" => "enableCapability",
        _ => return Err("world_prop_unauthorized"),
    };
    let n = |k: &str| {
        a[k].as_f64()
            .filter(|v| v.is_finite())
            .map(|v| v as f32)
            .ok_or("world_prop_invalid_input")
    };
    Ok(Command {
        op: op.into(),
        object_id: a["object_id"].as_str().map(str::to_owned),
        position: if op == "place" {
            Some([n("x")?, n("y")?, n("z")?])
        } else {
            None
        },
        yaw: if op == "place" { Some(n("yaw")?) } else { None },
        surface_id: a["surface_id"].as_str().map(str::to_owned),
        slot: a["slot"].as_str().map(str::to_owned),
        offset: if op == "adjustGrip" {
            Some([n("offset_x")?, n("offset_y")?, n("offset_z")?])
        } else {
            None
        },
        rotation: if op == "adjustGrip" {
            let y = n("rotation_yaw")? / 2.;
            Some([0., y.sin(), 0., y.cos()])
        } else {
            None
        },
        reason: a["reason"].as_str().map(str::to_owned),
        target_longest_edge: a["target_longest_edge"].as_f64().map(|v| v as f32),
        template_id: a["capability"].as_str().map(str::to_owned),
    })
}
fn authorize(tx: &Transaction<'_>, p: &Value, snap: &Value) -> Result<Command> {
    let a = &p["authority"];
    if a["kind"] == "ui" {
        let raw:Option<(String,String,i64,i64,u64,String,i64)>=tx.query_row("SELECT capability,host,revision,layout,expires,command,used FROM world_prop_intents WHERE id=?1 AND world=?2 AND scope=?3",params![text(a,"intentID")?,text(p,"worldID")?,text(p,"residentScope")?],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).optional().map_err(|_|"storage_unavailable")?;
        let (cap, host, rev, layout, expires, command, used) =
            raw.ok_or("world_prop_unauthorized")?;
        if cap != text(a, "capability")?
            || host != text(p, "hostSessionID")?
            || used != 0
            || now()? >= expires
            || snap["record"]["recordRevision"] != rev
            || snap["record"]["state"]["layoutRevision"] != layout
        {
            return Err("world_prop_unauthorized");
        }
        tx.execute(
            "UPDATE world_prop_intents SET used=1 WHERE id=?1",
            [text(a, "intentID")?],
        )
        .map_err(|_| "storage_unavailable")?;
        return serde_json::from_str(&command).map_err(|_| "world_prop_invalid_state");
    }
    if a["kind"] != "agent" {
        return Err("world_prop_unauthorized");
    }
    let row:Option<(String,String,String,String)>=tx.query_row("SELECT tool,input,effect,state FROM agent_tool_calls WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND call=?5 AND operation=?6",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"hostSessionID")?,text(a,"runID")?,text(a,"callID")?,text(a,"operationID")?],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(|_|"storage_unavailable")?;
    let (name, input, effect, status) = row.ok_or("world_prop_unauthorized")?;
    if effect != "write" || status != "inflight" {
        return Err("world_prop_unauthorized");
    }
    let claimed:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_events WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND state='claimed')",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"hostSessionID")?,text(a,"runID")?],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
    if !claimed {
        return Err("world_prop_unauthorized");
    }
    let args: Value = serde_json::from_str(&input).map_err(|_| "world_prop_invalid_state")?;
    if args["layout_revision"] != snap["record"]["state"]["layoutRevision"] {
        return Err("revision_conflict");
    }
    let command = tool_command(&name, &args)?;
    let human:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND session=?3 AND run=?4 AND state IN ('claimed','steer_claimed') AND mode='human')",params![text(p,"worldID")?,text(p,"residentScope")?,text(p,"hostSessionID")?,text(a,"runID")?],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
    if !human {
        delegation(tx, p, &command)?;
    }
    Ok(command)
}
fn delegation(c: &Connection, p: &Value, command: &Command) -> Result<()> {
    if command.op != "place" {
        return Err("world_prop_unauthorized");
    }
    let mut q = c
        .prepare("SELECT payload FROM wish_control_documents WHERE session=?1")
        .map_err(|_| "storage_unavailable")?;
    let rows = q
        .query_map([text(p, "hostSessionID")?], |r| r.get::<_, String>(0))
        .map_err(|_| "storage_unavailable")?;
    for raw in rows {
        let v: Value = serde_json::from_str(&raw.map_err(|_| "storage_unavailable")?)
            .map_err(|_| "world_prop_invalid_state")?;
        for d in v["delegations"].as_array().into_iter().flatten() {
            if d["worldID"] == p["worldID"]
                && d["residentScope"] == p["residentScope"]
                && d["objectID"].as_str() == command.object_id.as_deref()
                && d["state"] == "pending"
                && v["jobs"].as_array().is_some_and(|jobs| {
                    jobs.iter().any(|j| {
                        j["worldID"] == p["worldID"]
                            && j["residentScope"] == p["residentScope"]
                            && j["objectID"] == d["objectID"]
                            && j["stage"] == "claimed"
                            && j["autoContinuationPaused"] != true
                            && j["cancelRequested"] != true
                    })
                })
                && d["allowedSurfaceIDs"].as_array().is_some_and(|a| {
                    a.iter()
                        .any(|s| s.as_str() == command.surface_id.as_deref())
                })
            {
                let target = &d["explicitTarget"];
                if target.is_null()
                    || target["surfaceID"].as_str() == command.surface_id.as_deref()
                        && vector(&target["position"])?
                            == command.position.ok_or("world_prop_invalid_input")?
                        && target["yaw"].as_f64() == command.yaw.map(|v| v as f64)
                {
                    return Ok(());
                }
            }
        }
    }
    Err("world_prop_unauthorized")
}

fn stop_bound_activity(
    tx: &Transaction<'_>,
    p: &Value,
    command: &Command,
    state: &Value,
    facts: Option<&NativeFacts>,
    revision: i64,
) -> Result<Option<Value>> {
    let activity =
        crate::world_activity::request(tx, "world_activity_read", json!({"worldID":p["worldID"]}))?
            ["activity"]
            .clone();
    let run = &activity["run"];
    if !run.is_object() {
        return Ok(None);
    }
    let object = command
        .object_id
        .as_deref()
        .or_else(|| state["layoutUndo"]["objectID"].as_str())
        .ok_or("world_prop_invalid_input")?;
    let binding = run.get("usageBinding").filter(|b| b["objectID"] == object);
    let native = facts
        .and_then(|f| {
            f.activity_bindings
                .get(run["definition"]["id"].as_str().unwrap_or(""))
        })
        .filter(|b| {
            b.object_id == object
                && state["objectStates"][object]["metadata"][&b.metadata_key]
                    .as_str()
                    .is_some_and(|s| digest(s.as_bytes()) == b.metadata_sha256)
        });
    if binding.is_none() && native.is_none() {
        // A non-object activity is left alone. Missing object association must
        // never be turned into permission to stop an arbitrary run.
        if matches!(command.op.as_str(), "hold" | "adjustGrip") {
            return Err("world_prop_activity_conflict");
        }
        if [
            "gmgn.prop-seat.v1",
            "gmgn.prop-function-points.v1",
            "gmgn.prop-capability.v1",
        ]
        .iter()
        .any(|k| state["objectStates"][object]["metadata"].get(k).is_some())
        {
            return Err("world_prop_activity_not_ready");
        }
        return Ok(None);
    }
    if !activity["definitions"]
        .as_array()
        .is_some_and(|d| d.iter().any(|d| d["id"] == run["definition"]["id"]))
        || run["status"] == "unknown"
    {
        return Err("world_prop_activity_not_ready");
    }
    if matches!(command.op.as_str(), "hold" | "adjustGrip") {
        return Err("world_prop_activity_conflict");
    }
    let input = json!({"worldID":p["worldID"],"hostSessionID":p["hostSessionID"],"requestID":format!("prop-stop:{}",text(p,"requestID")?),"expectedRevision":revision,"checkpoint":state,"runRequestID":run["requestID"],"generation":run["generation"],"phaseGeneration":run["phaseGeneration"],"phase":run["phase"]});
    crate::world_activity::request(tx, "world_activity_stop", input).map(Some)
}
fn yaw(item: &Value) -> Result<f32> {
    let q = &item["transform"]["rotation"];
    let y = q["y"].as_f64().ok_or("world_prop_invalid_state")? as f32;
    let w = q["w"].as_f64().ok_or("world_prop_invalid_state")? as f32;
    Ok((2. * w * y).atan2(1. - 2. * y * y))
}
fn rotate(p: V, q: [f32; 4]) -> V {
    let u = [q[0], q[1], q[2]];
    let dot = u[0] * p[0] + u[1] * p[1] + u[2] * p[2];
    let norm = u.iter().map(|v| v * v).sum::<f32>();
    let cross = [
        u[1] * p[2] - u[2] * p[1],
        u[2] * p[0] - u[0] * p[2],
        u[0] * p[1] - u[1] * p[0],
    ];
    std::array::from_fn(|i| 2. * dot * u[i] + (q[3] * q[3] - norm) * p[i] + 2. * q[3] * cross[i])
}
fn quaternion(v: &Value) -> Result<[f32; 4]> {
    let mut q = [0.; 4];
    for (i, k) in ["x", "y", "z", "w"].iter().enumerate() {
        q[i] = v[k]
            .as_f64()
            .filter(|n| n.is_finite())
            .ok_or("world_prop_invalid_state")? as f32;
    }
    if (q.iter().map(|v| v * v).sum::<f32>() - 1.).abs() > 0.01 {
        return Err("world_prop_invalid_state");
    }
    Ok(q)
}
fn transformed_mesh(item: &Value, mesh: &MeshFact) -> Result<Vec<Triangle>> {
    let prop = generated(item)?;
    let dimensions = size(&prop)?;
    let orientation = prop
        .pointer("/orientation/rotation")
        .map(quaternion)
        .transpose()?
        .unwrap_or([0., 0., 0., 1.]);
    let oriented: Vec<Triangle> = mesh
        .triangles
        .iter()
        .map(|t| t.map(|p| rotate(p, orientation)))
        .collect();
    let mut lo = [f32::INFINITY; 3];
    let mut hi = [f32::NEG_INFINITY; 3];
    for p in oriented.iter().flatten() {
        for i in 0..3 {
            lo[i] = lo[i].min(p[i]);
            hi[i] = hi[i].max(p[i]);
        }
    }
    if hi[1] - lo[1] <= 0. {
        return Err("world_prop_invalid_native_facts");
    }
    let scale = dimensions[1] / (hi[1] - lo[1]);
    let origin = [(lo[0] + hi[0]) / 2., lo[1], (lo[2] + hi[2]) / 2.];
    let position = vector(&item["transform"]["position"])?;
    let rotation = quaternion(&item["transform"]["rotation"])?;
    Ok(oriented
        .into_iter()
        .map(|t| {
            t.map(|p| {
                let p = rotate(
                    std::array::from_fn(|i| (p[i] - origin[i]) * scale),
                    rotation,
                );
                std::array::from_fn(|i| p[i] + position[i])
            })
        })
        .collect())
}
fn obstacles(state: &Value, f: &NativeFacts, exclude: &str) -> Result<Vec<Obstacle>> {
    let mut out = f.environment.blocking_volumes.clone();
    for (id, item) in state["objectStates"]
        .as_object()
        .ok_or("world_prop_invalid_state")?
    {
        if id == exclude || item["isEnabled"] != true {
            continue;
        }
        if item["metadata"].get(world::GENERATED_PROP_KEY).is_none() {
            continue;
        }
        let mesh = f.objects.get(id).ok_or("world_prop_native_not_ready")?;
        out.push(Obstacle::Mesh {
            id: id.clone(),
            triangles: transformed_mesh(item, mesh)?,
            is_closed: mesh_closed(&mesh.triangles),
        });
    }
    if let Some(held) = state.get("heldProp").filter(|h| h.is_object()) {
        let id = text(held, "objectID")?;
        if id != exclude && held["returnState"]["isEnabled"] == true {
            let mesh = f.objects.get(id).ok_or("world_prop_native_not_ready")?;
            out.push(Obstacle::Mesh {
                id: id.into(),
                triangles: transformed_mesh(&held["returnState"], mesh)?,
                is_closed: mesh_closed(&mesh.triangles),
            });
        }
    }
    Ok(out)
}
fn mesh_closed(triangles: &[Triangle]) -> bool {
    let key = |p: V| p.map(|n| if n == 0. { 0 } else { n.to_bits() });
    let mut edges = BTreeMap::new();
    for t in triangles {
        for (a, b) in [(t[0], t[1]), (t[1], t[2]), (t[2], t[0])] {
            let (a, b) = (key(a), key(b));
            if a == b {
                return false;
            }
            let edge = if a < b { (a, b) } else { (b, a) };
            *edges.entry(edge).or_insert(0usize) += 1;
        }
    }
    !edges.is_empty() && edges.values().all(|count| *count == 2)
}
fn obstacle_bounds(o: &Obstacle) -> (V, V) {
    match o {
        Obstacle::Box { volume: v, .. } => {
            let hx = v.yaw.cos().abs() * v.half_extents[0] + v.yaw.sin().abs() * v.half_extents[2];
            let hz = v.yaw.sin().abs() * v.half_extents[0] + v.yaw.cos().abs() * v.half_extents[2];
            let h = [hx, v.half_extents[1], hz];
            (
                std::array::from_fn(|i| v.center[i] - h[i]),
                std::array::from_fn(|i| v.center[i] + h[i]),
            )
        }
        Obstacle::Mesh { triangles, .. } => {
            let mut lo = [f32::INFINITY; 3];
            let mut hi = [f32::NEG_INFINITY; 3];
            for p in triangles.iter().flatten() {
                for i in 0..3 {
                    lo[i] = lo[i].min(p[i]);
                    hi[i] = hi[i].max(p[i]);
                }
            }
            (lo, hi)
        }
    }
}
fn evaluate_pose(
    state: &Value,
    id: &str,
    prop: &Value,
    position: V,
    yaw: f32,
    f: &NativeFacts,
    grid: &Grid,
    requested_surface: Option<&str>,
) -> Result<(V, String)> {
    let s = size(prop)?;
    let mut footprint = Footprint {
        size: [s[0], s[2]],
        yaw,
        center_offset: [0.; 2],
    };
    let spacing = grid.spacing;
    let column = Column {
        x: ((position[0] - spacing * 0.5) / spacing).round() as i32,
        z: ((position[2] - spacing * 0.5) / spacing).round() as i32,
    };
    let base = footprint.center(column, spacing);
    footprint.center_offset = [position[0] - base[0], position[2] - base[1]];
    let mut layers: Vec<Layer> = grid
        .layers
        .iter()
        .filter(|l| {
            l.column == column
                && requested_surface.is_none_or(|s| {
                    s == format!("grid.layer.{}", l.layer) || s == "floor" && l.layer == 0
                })
        })
        .cloned()
        .collect();
    layers.sort_by(|a, b| {
        (a.support_height - position[1])
            .abs()
            .total_cmp(&(b.support_height - position[1]).abs())
    });
    let placed = obstacles(state, f, id)?;
    for mut anchor in layers {
        let columns = footprint.columns(anchor.column, spacing);
        let mut plane = anchor.support_height;
        for c in columns {
            if let Some(y) = grid
                .layers
                .iter()
                .filter(|l| l.column == c && l.layer == anchor.layer)
                .map(|l| l.support_height)
                .max_by(f32::total_cmp)
            {
                plane = plane.max(y);
            }
        }
        anchor.support_height = plane;
        let result = placement::evaluate(EvaluateRequest {
            grid: grid.clone(),
            anchor: anchor.clone(),
            footprint,
            height: s[1],
            triangles: f.environment.triangles.clone(),
            blocking_volumes: vec![],
            placed_obstacles: placed.clone(),
            resting_tolerance: 0.02,
            support_height_deviation: 0.02,
        });
        if result.can_place {
            let bottom = [position[0], plane, position[2]];
            let mut candidate = state.clone();
            set_placement(
                &mut candidate["objectStates"][id],
                bottom,
                yaw,
                &format!("grid.layer.{}", anchor.layer),
                prop,
            )?;
            route_clearance(&candidate, id, f, grid)?;
            return Ok((bottom, format!("grid.layer.{}", anchor.layer)));
        }
    }
    Err("world_prop_placement_blocked")
}
fn route_clearance(state: &Value, exclude: &str, f: &NativeFacts, grid: &Grid) -> Result<()> {
    let resident = vector(&state["agentTransform"]["position"])?;
    let placed = obstacles(state, f, "")?;
    let bounded: Vec<_> = placed.iter().map(|o| (o, obstacle_bounds(o))).collect();
    let can_stand = |p: V| {
        bounded.iter().all(|(o, (lo, hi))| {
            if p[0] + 0.25 < lo[0]
                || p[0] - 0.25 > hi[0]
                || p[2] + 0.25 < lo[2]
                || p[2] - 0.25 > hi[2]
                || p[1] + 1.8 < lo[1]
                || p[1] > hi[1]
            {
                return true;
            }
            placement::capsule_can_occupy(&[], std::slice::from_ref(*o), p, 0.25, 1.8)
        })
    };
    if !can_stand(resident) {
        return Err("world_prop_resident_blocked");
    }
    let mut open = BTreeMap::<(i32, i32), Vec<&Layer>>::new();
    for l in &grid.layers {
        let p = [
            l.column.x as f32 * grid.spacing,
            l.support_height,
            l.column.z as f32 * grid.spacing,
        ];
        if can_stand(p) {
            open.entry((l.column.x, l.column.z)).or_default().push(l);
        }
    }
    let nearest = |p: V| -> Option<(i32, i32, i32)> {
        open.values()
            .flatten()
            .filter(|l| (l.support_height - p[1]).abs() <= 0.3)
            .filter(|l| {
                (l.column.x as f32 * grid.spacing - p[0]).powi(2)
                    + (l.column.z as f32 * grid.spacing - p[2]).powi(2)
                    <= 0.4f32.powi(2)
            })
            .min_by(|a, b| {
                let d = |l: &&Layer| {
                    (l.column.x as f32 * grid.spacing - p[0]).powi(2)
                        + (l.column.z as f32 * grid.spacing - p[2]).powi(2)
                };
                d(a).total_cmp(&d(b))
            })
            .map(|l| (l.column.x, l.column.z, l.layer))
    };
    let start = nearest(resident).ok_or("world_prop_route_blocked")?;
    let heights: BTreeMap<_, _> = grid
        .layers
        .iter()
        .map(|l| ((l.column.x, l.column.z, l.layer), l.support_height))
        .collect();
    let mut seen = BTreeSet::from([start]);
    let mut queue = VecDeque::from([start]);
    while let Some((x, z, layer)) = queue.pop_front() {
        let h = *heights
            .get(&(x, z, layer))
            .ok_or("world_prop_invalid_state")?;
        for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            if let Some(nodes) = open.get(&(x + dx, z + dz)) {
                for next in nodes {
                    if (next.support_height - h).abs() > 0.3 {
                        continue;
                    }
                    let key = (next.column.x, next.column.z, next.layer);
                    if seen.insert(key) {
                        queue.push_back(key);
                    }
                }
            }
        }
    }
    let mut targets: Vec<V> = f.anchor_positions.values().copied().collect();
    // Native anchorPositions contains authored room anchors only. Prop-local
    // declarations are transformed here from the candidate, not its old pose.
    for item in state["objectStates"]
        .as_object()
        .ok_or("world_prop_invalid_state")?
        .values()
        .filter(|item| item["isEnabled"] == true)
    {
        if item["metadata"].get(world::GENERATED_PROP_KEY).is_none() {
            continue;
        }
        let prop = generated(item)?;
        let base = vector(&item["transform"]["position"])?;
        let y = yaw(item)?;
        let world_point = |local: V| {
            [
                base[0] + y.cos() * local[0] + y.sin() * local[2],
                base[1] + local[1],
                base[2] - y.sin() * local[0] + y.cos() * local[2],
            ]
        };
        if let Some(raw) = item["metadata"]["gmgn.prop-function-points.v1"].as_str() {
            let declaration: Value =
                serde_json::from_str(raw).map_err(|_| "world_prop_invalid_state")?;
            let points = declaration["functionPoints"]
                .as_array()
                .filter(|p| p.len() <= 16)
                .ok_or("world_prop_invalid_state")?;
            for point in points {
                if point.get("kind").is_none() || point["kind"] == "standingSpot" {
                    targets.push(world_point(vector(&point["position"])?));
                }
            }
        }
        if let Some(raw) = item["metadata"]["gmgn.prop-seat.v1"].as_str() {
            let seat: Value = serde_json::from_str(raw).map_err(|_| "world_prop_invalid_state")?;
            if seat["assetID"] != prop["assetID"] {
                return Err("world_prop_invalid_state");
            }
            let source = vector(&seat["sourceSize"])?;
            let s = size(&prop)?;
            if source.iter().any(|v| *v <= 0.) {
                return Err("world_prop_invalid_state");
            }
            let point = vector(&seat["approachPoint"])?;
            targets.push(world_point(std::array::from_fn(|i| {
                point[i] * s[i] / source[i]
            })));
        }
    }
    for p in &targets {
        let goal = nearest(*p).ok_or("world_prop_route_blocked")?;
        if !seen.contains(&goal) {
            return Err("world_prop_route_blocked");
        }
    }
    let _ = exclude;
    Ok(())
}
fn set_placement(
    item: &mut Value,
    position: V,
    yaw: f32,
    surface: &str,
    prop: &Value,
) -> Result<()> {
    let scale = size(prop)?[1]
        / prop["sourceHeight"]
            .as_f64()
            .filter(|v| *v > 0. && v.is_finite())
            .ok_or("world_prop_invalid_state")? as f32;
    item["isEnabled"] = json!(true);
    item["transform"] = json!({"position":xyz(position),"rotation":{"x":0,"y":(yaw/2.).sin(),"z":0,"w":(yaw/2.).cos()},"scale":xyz([scale;3])});
    item["metadata"][world::SUPPORT_SURFACE_KEY] = json!(surface);
    Ok(())
}
fn held<'a>(state: &'a Value, id: &str) -> Result<&'a Value> {
    state
        .get("heldProp")
        .filter(|h| h["objectID"] == id)
        .ok_or("world_prop_not_held")
}
fn validate_loaded<'a>(
    state: &Value,
    id: &str,
    prop: &Value,
    f: &'a NativeFacts,
) -> Result<&'a MeshFact> {
    let mesh = f
        .objects
        .get(id)
        .filter(|m| prop["assetID"] == m.asset_id)
        .ok_or("world_prop_native_not_ready")?;
    let _ = state;
    Ok(mesh)
}
fn reduce(
    state: &Value,
    command: &Command,
    geometry: Option<&(NativeFacts, Grid)>,
) -> Result<(Value, Value)> {
    let id = command
        .object_id
        .as_deref()
        .or_else(|| state["layoutUndo"]["objectID"].as_str())
        .ok_or("world_prop_invalid_input")?;
    let before = state["objectStates"][id].clone();
    if !before.is_object() {
        return Err("world_prop_object_not_found");
    }
    let prop = generated(&before)?;
    if prop["objectID"] != id {
        return Err("world_prop_invalid_state");
    }
    let mut next = state.clone();
    let mut receipt = json!({"op":command.op,"objectID":id});
    let geometry = || geometry.ok_or("world_prop_native_not_ready");
    match command.op.as_str() {
        "resize" => {
            if state["heldProp"]["objectID"] == id {
                return Err("world_prop_object_held");
            }
            let resized = crate::world_prop_measurement::manual_resize(
                &prop,
                command
                    .target_longest_edge
                    .ok_or("world_prop_invalid_input")?,
            )?;
            let (f, g) = geometry()?;
            validate_loaded(state, id, &prop, f)?;
            next["objectStates"][id]["metadata"][world::GENERATED_PROP_KEY] =
                json!(encode(&resized)?);
            let factor = size(&resized)?[1]
                / resized["sourceHeight"]
                    .as_f64()
                    .ok_or("world_prop_invalid_state")? as f32;
            if !factor.is_finite() || factor <= 0. {
                return Err("world_prop_invalid_state");
            }
            next["objectStates"][id]["transform"]["scale"] =
                json!({"x":factor,"y":factor,"z":factor});
            next["layoutUndo"] = Value::Null;
            if before["isEnabled"] == true {
                evaluate_pose(
                    &next,
                    id,
                    &resized,
                    vector(&before["transform"]["position"])?,
                    yaw(&before)?,
                    f,
                    g,
                    None,
                )?;
            }
        }
        "enableCapability" => {
            if state["heldProp"]["objectID"] == id {
                return Err("world_prop_object_held");
            }
            let capability = crate::world_prop_capability::proposal(
                &prop,
                command
                    .template_id
                    .as_deref()
                    .ok_or("world_prop_invalid_input")?,
            )?;
            if let Some(raw) =
                before["metadata"][crate::world_prop_capability::METADATA_KEY].as_str()
            {
                if serde_json::from_str::<Value>(raw).map_err(|_| "world_prop_invalid_state")?
                    != capability
                {
                    return Err("prop_capability_unsupported_template");
                }
                return Ok((
                    state.clone(),
                    json!({"op":"enableCapability","objectID":id,"unchanged":true}),
                ));
            }
            next["objectStates"][id]["metadata"][crate::world_prop_capability::METADATA_KEY] =
                json!(encode(&capability)?);
            next["layoutUndo"] = Value::Null;
            let (f, g) = geometry()?;
            route_clearance(&next, id, f, g)?;
        }
        "place" => {
            if state["heldProp"]["objectID"] == id {
                return Err("world_prop_object_held");
            }
            let (f, g) = geometry()?;
            validate_loaded(state, id, &prop, f)?;
            let (pos, surface) = evaluate_pose(
                state,
                id,
                &prop,
                command.position.ok_or("world_prop_invalid_input")?,
                command.yaw.ok_or("world_prop_invalid_input")?,
                f,
                g,
                command.surface_id.as_deref(),
            )?;
            next["layoutUndo"] =
                json!({"objectID":id,"previous":before,"previousHeldProp":state["heldProp"]});
            set_placement(
                &mut next["objectStates"][id],
                pos,
                command.yaw.unwrap(),
                &surface,
                &prop,
            )?;
            receipt["placement"] =
                json!({"position":xyz(pos),"yaw":command.yaw,"surfaceID":surface});
        }
        "withdraw" => {
            if state["heldProp"]["objectID"] == id {
                return Err("world_prop_object_held");
            }
            next["layoutUndo"] =
                json!({"objectID":id,"previous":before,"previousHeldProp":state["heldProp"]});
            next["objectStates"][id]["isEnabled"] = json!(false);
        }
        "hold" => {
            let (f, _) = geometry()?;
            let mesh = validate_loaded(state, id, &prop, f)?;
            let slot = command.slot.as_deref().unwrap_or("rightHand");
            if !f.avatar.slots.iter().any(|s| s == slot) {
                return Err("world_prop_slot_unavailable");
            }
            if size(&prop)?.into_iter().fold(0., f32::max) > 1.6 {
                return Err("world_prop_too_large");
            }
            if state["activeActivity"].is_object() {
                return Err("world_prop_activity_conflict");
            }
            if state["heldProp"].is_object() && state["heldProp"]["objectID"] != id {
                return Err("world_prop_object_held");
            }
            if before["isEnabled"] == true {
                let pos = vector(&before["transform"]["position"])?;
                let agent = vector(&state["agentTransform"]["position"])?;
                let y = yaw(&before)?;
                let (dx, dz) = (agent[0] - pos[0], agent[2] - pos[2]);
                let x = (dx * y.cos() - dz * y.sin()).abs();
                let z = (dx * y.sin() + dz * y.cos()).abs();
                let s = size(&prop)?;
                if ((x - s[0] / 2.).max(0.).powi(2) + (z - s[2] / 2.).max(0.).powi(2)).sqrt()
                    > REACH + 0.00001
                {
                    return Err("prop_out_of_reach");
                }
            }
            let existing = before["metadata"][GRIP]
                .as_str()
                .and_then(|s| serde_json::from_str::<Value>(s).ok());
            let calibration = if let Some(v) = existing.filter(|v| {
                v["avatarAssetID"] == f.avatar.asset_id
                    && v["hand"] == slot
                    && crate::world_prop_grip::validate(v).is_ok()
            }) {
                v
            } else {
                crate::world_prop_grip::calibration(
                    &prop,
                    &f.avatar.asset_id,
                    slot,
                    &mesh.triangles,
                )?
            };
            next["objectStates"][id]["metadata"][GRIP] = json!(encode(&calibration)?);
            let return_state = if state["heldProp"]["objectID"] == id {
                let mut r = state["heldProp"]["returnState"].clone();
                r["metadata"][GRIP] = json!(encode(&calibration)?);
                r
            } else {
                next["objectStates"][id].clone()
            };
            next["objectStates"][id]["isEnabled"] = json!(false);
            next["heldProp"] = json!({"objectID":id,"avatarAssetID":f.avatar.asset_id,"hand":slot,"returnState":return_state});
            next["layoutUndo"] = Value::Null;
        }
        "adjustGrip" => {
            let (f, _) = geometry()?;
            let h = held(state, id)?;
            if h["avatarAssetID"] != f.avatar.asset_id {
                return Err("world_prop_avatar_changed");
            }
            validate_loaded(state, id, &prop, f)?;
            let existing: Value = serde_json::from_str(
                before["metadata"][GRIP]
                    .as_str()
                    .ok_or("world_prop_invalid_state")?,
            )
            .map_err(|_| "world_prop_invalid_state")?;
            let updated = crate::world_prop_grip::adjust(
                &existing,
                command.offset.ok_or("world_prop_invalid_input")?,
                command.rotation.ok_or("world_prop_invalid_input")?,
            )?;
            next["objectStates"][id]["metadata"][GRIP] = json!(encode(&updated)?);
            next["heldProp"]["returnState"]["metadata"][GRIP] = json!(encode(&updated)?);
            next["layoutUndo"] = Value::Null;
        }
        "returnHeld" => {
            let h = held(state, id)?;
            let (f, g) = geometry()?;
            if h["avatarAssetID"] != f.avatar.asset_id {
                return Err("world_prop_avatar_changed");
            }
            let original = h["returnState"].clone();
            if generated(&original)? != prop {
                return Err("world_prop_invalid_state");
            }
            if original["isEnabled"] == true {
                validate_loaded(state, id, &prop, f)?;
                let (pos, _) = evaluate_pose(
                    state,
                    id,
                    &prop,
                    vector(&original["transform"]["position"])?,
                    yaw(&original)?,
                    f,
                    g,
                    None,
                )?;
                if (pos[1] - vector(&original["transform"]["position"])?[1]).abs() > 0.005 {
                    return Err("world_prop_placement_blocked");
                }
            }
            next["objectStates"][id] = original;
            next["heldProp"] = Value::Null;
            next["layoutUndo"] = Value::Null;
        }
        "dropHeld" => {
            let h = held(state, id)?;
            let (f, g) = geometry()?;
            if h["avatarAssetID"] != f.avatar.asset_id {
                return Err("world_prop_avatar_changed");
            }
            validate_loaded(state, id, &prop, f)?;
            let agent = vector(&state["agentTransform"]["position"])?;
            let y = yaw(&h["returnState"])?;
            let mut positions: Vec<_> = g
                .layers
                .iter()
                .filter(|l| {
                    ((l.column.x as f32 * g.spacing - agent[0]).powi(2)
                        + (l.column.z as f32 * g.spacing - agent[2]).powi(2))
                    .sqrt()
                        <= REACH
                        && (l.support_height - agent[1]).abs() <= 0.25
                })
                .collect();
            positions.sort_by(|a, b| {
                let d = |l: &&Layer| {
                    (l.column.x as f32 * g.spacing - agent[0]).powi(2)
                        + (l.column.z as f32 * g.spacing - agent[2]).powi(2)
                };
                d(a).total_cmp(&d(b))
                    .then((a.column.x, a.column.z, a.layer).cmp(&(b.column.x, b.column.z, b.layer)))
            });
            let mut selected = None;
            for l in positions {
                let p = [
                    l.column.x as f32 * g.spacing,
                    l.support_height,
                    l.column.z as f32 * g.spacing,
                ];
                if let Ok(v) = evaluate_pose(state, id, &prop, p, y, f, g, None) {
                    selected = Some(v);
                    break;
                }
            }
            let (pos, surface) = selected.ok_or("world_prop_no_nearby_drop")?;
            set_placement(&mut next["objectStates"][id], pos, y, &surface, &prop)?;
            next["heldProp"] = Value::Null;
            next["layoutUndo"] = Value::Null;
            receipt["placement"] = json!({"position":xyz(pos),"yaw":y,"surfaceID":surface});
        }
        "delete" => {
            let settlement = if state["heldProp"]["objectID"] == id {
                let h = held(state, id)?;
                next["heldProp"] = Value::Null;
                json!({"returnedFromSlot":{"slot":h["hand"],"position":h["returnState"]["transform"]["position"]}})
            } else if before["isEnabled"] == true {
                json!({"withdrawn":{"surfaceID":before["metadata"][world::SUPPORT_SURFACE_KEY].as_str().unwrap_or(""),"position":before["transform"]["position"]}})
            } else {
                json!({"inventory":{}})
            };
            let mut refs = BTreeSet::new();
            if let Ok(v) = asset_digest(prop["assetID"].as_str().unwrap_or("")) {
                refs.insert(v);
            }
            if let Some(v) = prop
                .pointer("/collision/sha256")
                .and_then(Value::as_str)
                .and_then(|v| asset_digest(v).ok())
            {
                refs.insert(v);
            }
            if !next["propTombstones"].is_object() {
                next["propTombstones"] = json!({});
            }
            next["propTombstones"][id] = json!({"objectID":id,"displayName":prop["displayName"],"releasedBlobRefs":refs,"settlement":settlement,"reason":command.reason,"deletedAt":state["worldTime"].as_f64().ok_or("world_prop_invalid_state")?/1000.-978307200.,"previous":prop});
            next["objectStates"].as_object_mut().unwrap().remove(id);
            next["layoutUndo"] = Value::Null;
            receipt["settlement"] = settlement;
        }
        "undo" => {
            let previous = state["layoutUndo"]["previous"].clone();
            if generated(&previous)? != prop {
                return Err("world_prop_invalid_state");
            }
            let (f, g) = geometry()?;
            if previous["isEnabled"] == true {
                validate_loaded(state, id, &prop, f)?;
                evaluate_pose(
                    state,
                    id,
                    &prop,
                    vector(&previous["transform"]["position"])?,
                    yaw(&previous)?,
                    f,
                    g,
                    None,
                )?;
            }
            next["objectStates"][id] = previous;
            next["heldProp"] = state["layoutUndo"]["previousHeldProp"].clone();
            next["layoutUndo"] = Value::Null;
        }
        _ => return Err("world_prop_invalid_input"),
    }
    next["layoutRevision"] = json!(state["layoutRevision"]
        .as_u64()
        .ok_or("world_prop_invalid_state")?
        .checked_add(1)
        .ok_or("world_prop_invalid_state")?);
    next["revision"] = json!(state["revision"]
        .as_u64()
        .ok_or("world_prop_invalid_state")?
        .checked_add(1)
        .ok_or("world_prop_invalid_state")?);
    // Typed receipts retain the old Codable enum vocabulary. Usage remains the
    // activity authority's exact bytes; this reducer never manufactures it.
    let legacy = match command.op.as_str() {
        "place" => json!({"objectID":id,"placement":receipt["placement"]}),
        "withdraw" => json!({"objectID":id}),
        "hold" | "adjustGrip" => {
            let calibration: Value = serde_json::from_str(
                next["objectStates"][id]["metadata"][GRIP]
                    .as_str()
                    .ok_or("world_prop_invalid_state")?,
            )
            .map_err(|_| "world_prop_invalid_state")?;
            json!({"objectID":id,"avatarAssetID":next["heldProp"]["avatarAssetID"],"calibration":calibration})
        }
        "returnHeld" => json!({"objectID":id,"avatarAssetID":state["heldProp"]["avatarAssetID"]}),
        "dropHeld" => {
            json!({"objectID":id,"avatarAssetID":state["heldProp"]["avatarAssetID"],"placement":receipt["placement"]})
        }
        "delete" => json!({"objectID":id,"reason":command.reason}),
        "undo" => json!({}),
        "resize" => json!({"objectID":id,"size":generated(&next["objectStates"][id])?["size"]}),
        "enableCapability" => json!({"objectID":id,"templateID":command.template_id}),
        _ => return Err("world_prop_invalid_input"),
    };
    if !next["layoutReceipts"].is_object() {
        next["layoutReceipts"] = json!({});
    }
    next["layoutReceipts"][format!("rust-prop:{}", uuid::Uuid::new_v4())] =
        json!({command.op.clone():legacy});
    Ok((next, receipt))
}
fn inventory(state: &Value) -> Result<Value> {
    let mut objects = Vec::new();
    for (id, item) in state["objectStates"]
        .as_object()
        .ok_or("world_prop_invalid_state")?
    {
        let Ok(prop) = generated(item) else {
            continue;
        };
        let status = if state["heldProp"]["objectID"] == *id {
            "held"
        } else if item["isEnabled"] == true {
            "placed"
        } else {
            "inventory"
        };
        // Availability is only the state-machine operation vocabulary. Geometry,
        // current avatar and caller authority are rechecked by every command.
        let actions = match status {
            "held" => vec!["adjustGrip", "returnHeld", "dropHeld", "delete"],
            "placed" => vec!["place", "withdraw", "hold", "delete"],
            _ if state["heldProp"].is_null() => vec!["place", "hold", "delete"],
            _ => vec!["place", "delete"],
        };
        objects.push(json!({"objectID":id,"prop":prop,"status":status,"allowedActions":actions,"requiresCommandValidation":true,"held":state["heldProp"]["objectID"]==*id}));
    }
    objects.sort_by(|a, b| a["objectID"].as_str().cmp(&b["objectID"].as_str()));
    Ok(
        json!({"layoutRevision":state["layoutRevision"],"objects":objects,"canUndo":state["layoutUndo"].is_object()}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    struct PrivateRoot(std::path::PathBuf);
    impl PrivateRoot {
        fn new() -> Self {
            let path = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("gmgn-world-prop-test-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
        fn path(&self) -> &Path {
            &self.0
        }
    }
    impl Drop for PrivateRoot {
        fn drop(&mut self) {
            // This exact root was uniquely created by this fixture.
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    const WORLD: &str = "84503420-3010-4944-8fde-2f383cd08ebe";
    fn command(op: &str) -> Command {
        Command {
            op: op.into(),
            object_id: Some("prop".into()),
            position: Some([1.137, 0., 1.091]),
            yaw: Some(0.),
            surface_id: Some("floor".into()),
            slot: None,
            offset: None,
            rotation: None,
            reason: None,
            target_longest_edge: None,
            template_id: None,
        }
    }
    fn state() -> Value {
        let prop = json!({"objectID":"prop","sourceWishID":"EBFC07BE-6AF3-4E25-AF6C-9E795C6E28C6","assetID":format!("sha256:{}","a".repeat(64)),"displayName":"private cube","sourceHeight":0.3,"size":{"x":0.3,"y":0.3,"z":0.3}});
        json!({"worldID":WORLD,"revision":0,"layoutRevision":0,"worldTime":1760000000000i64,"agentTransform":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"activeActivity":null,"heldProp":null,"layoutReceipts":{},"objectStates":{"prop":{"isEnabled":false,"transform":{"position":{"x":1,"y":0,"z":1},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"metadata":{world::GENERATED_PROP_KEY:encode(&prop).unwrap(),"note":"preserved","gmgn.prop-usage.v1":"{\"status\":\"stopped\"}"}},"basic":{"isEnabled":true,"transform":{"position":{"x":4,"y":0,"z":4},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"metadata":{}}}})
    }
    fn geometry() -> (NativeFacts, Grid) {
        let t = vec![
            [[-3., 0., -3.], [3., 0., -3.], [3., 0., 3.]],
            [[-3., 0., -3.], [3., 0., 3.], [-3., 0., 3.]],
        ];
        let mesh = vec![
            [[-0.15, 0., -0.15], [0.15, 0., -0.15], [0.15, 0.3, 0.15]],
            [[-0.15, 0., -0.15], [0.15, 0.3, 0.15], [-0.15, 0.3, 0.15]],
        ];
        let grid = Grid {
            spacing: 0.25,
            minimum: Column { x: -12, z: -12 },
            maximum: Column { x: 12, z: 12 },
            layers: (-12..=12)
                .flat_map(|x| {
                    (-12..=12).map(move |z| Layer {
                        column: Column { x, z },
                        layer: 0,
                        support_height: 0.,
                    })
                })
                .collect(),
        };
        let f = NativeFacts {
            environment_blob_ref: "a".repeat(64),
            environment: support_grid::DeriveRequest {
                triangles: t,
                blocking_volumes: vec![],
                bounds: support_grid::Bounds {
                    minimum_x: -3.,
                    maximum_x: 3.,
                    minimum_z: -3.,
                    maximum_z: 3.,
                },
                seed: [0.; 3],
                parameters: Default::default(),
            },
            avatar: AvatarFact {
                asset_id: "private-avatar".into(),
                selection_revision: 1,
                format: "pmx".into(),
                slots: vec!["rightHand".into(), "back".into(), "waist".into()],
            },
            objects: BTreeMap::from([(
                "prop".into(),
                MeshFact {
                    asset_id: format!("sha256:{}", "a".repeat(64)),
                    blob_ref: "a".repeat(64),
                    triangles: mesh,
                },
            )]),
            activity_bindings: BTreeMap::new(),
            anchor_positions: BTreeMap::from([("end".into(), [2., 0., 2.])]),
        };
        (f, grid)
    }
    #[test]
    fn place_exact_center_then_withdraw_undo_and_preserve_usage() {
        let s = state();
        let g = geometry();
        let (n, r) = reduce(&s, &command("place"), Some(&g)).unwrap();
        assert_eq!(
            vector(&n["objectStates"]["prop"]["transform"]["position"]).unwrap(),
            [1.137, 0., 1.091]
        );
        assert_eq!(
            n["objectStates"]["prop"]["metadata"]["gmgn.prop-usage.v1"],
            s["objectStates"]["prop"]["metadata"]["gmgn.prop-usage.v1"]
        );
        assert!(r["placement"].is_object());
        let (w, _) = reduce(&n, &command("withdraw"), None).unwrap();
        assert_eq!(w["objectStates"]["prop"]["isEnabled"], false);
        let (u, _) = reduce(&w, &command("undo"), Some(&g)).unwrap();
        assert_eq!(u["objectStates"]["prop"], n["objectStates"]["prop"]);
    }
    #[test]
    fn held_lifecycle_returns_original_or_drops_nearby_and_adjusts_explicitly() {
        let s = state();
        let g = geometry();
        let (h, _) = reduce(&s, &command("hold"), Some(&g)).unwrap();
        assert_eq!(h["heldProp"]["objectID"], "prop");
        let original = h["heldProp"]["returnState"].clone();
        let (r, _) = reduce(&h, &command("returnHeld"), Some(&g)).unwrap();
        assert_eq!(r["objectStates"]["prop"], original);
        assert!(r["heldProp"].is_null());
        let mut adjust = command("adjustGrip");
        adjust.offset = Some([0.01, 0.02, -0.03]);
        adjust.rotation = Some([0., 0., 0., 1.]);
        let (a, _) = reduce(&h, &adjust, Some(&g)).unwrap();
        let grip: Value = serde_json::from_str(
            a["objectStates"]["prop"]["metadata"][GRIP]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(vector(&grip["localOffset"]).unwrap(), [0.01, 0.02, -0.03]);
        let (d, receipt) = reduce(&a, &command("dropHeld"), Some(&g)).unwrap();
        assert!(d["heldProp"].is_null());
        let pos = vector(&receipt["placement"]["position"]).unwrap();
        assert!(pos[0].hypot(pos[2]) <= REACH + 0.00001);
    }
    #[test]
    fn far_pickup_and_basic_delete_are_rejected_but_broken_prop_deletes() {
        let mut s = state();
        s["objectStates"]["prop"]["isEnabled"] = json!(true);
        let g = geometry();
        assert_eq!(
            reduce(&s, &command("hold"), Some(&g)).unwrap_err(),
            "prop_out_of_reach"
        );
        let mut basic = command("delete");
        basic.object_id = Some("basic".into());
        assert_eq!(
            reduce(&s, &basic, None).unwrap_err(),
            "world_prop_basic_object"
        );
        let (d, r) = reduce(&s, &command("delete"), None).unwrap();
        assert!(d["objectStates"].get("prop").is_none());
        assert_eq!(
            d["propTombstones"]["prop"]["previous"],
            generated(&s["objectStates"]["prop"]).unwrap()
        );
        assert!(r["settlement"].is_object());
    }
    #[test]
    fn obstacles_block_placement_and_agent_overlap() {
        let s = state();
        let mut g = geometry();
        g.0.environment.blocking_volumes.push(Obstacle::Box {
            id: "wall".into(),
            volume: BoxVolume {
                center: [1.137, 0.5, 1.091],
                half_extents: [0.2, 0.5, 0.2],
                yaw: 0.,
            },
        });
        assert_eq!(
            reduce(&s, &command("place"), Some(&g)).unwrap_err(),
            "world_prop_placement_blocked"
        );
        let mut near = command("place");
        near.position = Some([0., 0., 0.]);
        assert!(reduce(&s, &near, Some(&geometry())).is_err());
    }
    fn db() -> Connection {
        let mut c = Connection::open_in_memory().unwrap();
        crate::store::migrate(&mut c).unwrap();
        let tx = c.transaction().unwrap();
        let s = state();
        let raw = encode(&s).unwrap();
        world::import(
            &tx,
            &world::ImportRequest {
                world_id: WORLD.into(),
                request_id: "private-import".into(),
                producer: Some("test".into()),
                package_id: "private".into(),
                package_version: "1".into(),
                state_sha256: digest(raw.as_bytes()),
                state_json: raw,
            },
        )
        .unwrap();
        tx.commit().unwrap();
        c
    }
    fn params(rev: i64, request: &str) -> Value {
        json!({"worldID":WORLD,"residentScope":"private-resident","hostSessionID":"private-host","requestID":request,"expectedRevision":rev,"expectedLayoutRevision":0})
    }
    #[test]
    fn reviewed_seat_metadata_is_exact_asset_only_and_never_overwrites_explicit() {
        let mut s = state();
        assert!(!install_reviewed_seat_metadata(&mut s, None).unwrap());
        let mut prop = generated(&s["objectStates"]["prop"]).unwrap();
        prop["assetID"] =
            json!("sha256:0eb955793605cbfe0680616f98991369f85fd46c317d1b51a877949b3fb36303");
        s["objectStates"]["prop"]["metadata"][world::GENERATED_PROP_KEY] =
            json!(encode(&prop).unwrap());
        let original_pose = s["objectStates"]["prop"]["transform"].clone();
        assert!(install_reviewed_seat_metadata(&mut s, Some("prop")).unwrap());
        assert_eq!(s["objectStates"]["prop"]["transform"], original_pose);
        let seat: Value = serde_json::from_str(
            s["objectStates"]["prop"]["metadata"]["gmgn.prop-seat.v1"]
                .as_str()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(
            seat,
            crate::world_activity_approach::reviewed_seat_calibration(
                prop["assetID"].as_str().unwrap()
            )
            .unwrap()
        );
        assert!(!install_reviewed_seat_metadata(&mut s, None).unwrap());
        s["objectStates"]["prop"]["metadata"]["gmgn.prop-seat.v1"] = json!("explicit-invalid");
        assert!(!install_reviewed_seat_metadata(&mut s, None).unwrap());
        assert_eq!(
            s["objectStates"]["prop"]["metadata"]["gmgn.prop-seat.v1"],
            "explicit-invalid"
        );
    }
    #[test]
    fn typed_lifecycle_return_restores_reserved_state_and_exact_receipt() {
        for kind in [
            "world_detached",
            "user_stop",
            "resident_pause",
            "application_exit",
        ] {
            let mut c = db();
            let tx = c.transaction().unwrap();
            let (held_state, _) = reduce(&state(), &command("hold"), Some(&geometry())).unwrap();
            let original = held_state["heldProp"]["returnState"].clone();
            world::commit_prop(
                &tx,
                &world::CommitRequest {
                    world_id: WORLD.into(),
                    request_id: "private-hold".into(),
                    expected_revision: 1,
                    producer: Some("test".into()),
                    intent: None,
                    ops: vec![world::Op {
                        op: "replaceState".into(),
                        state: Some(held_state),
                        ..Default::default()
                    }],
                },
            )
            .unwrap();
            let mut p = params(2, "private-system-return");
            p["readBinding"] = json!(true);
            let binding = system_return(&tx, Path::new("/private/tmp"), &p).unwrap();
            p.as_object_mut().unwrap().remove("readBinding");
            p["expectedLayoutRevision"] =
                binding["snapshot"]["record"]["state"]["layoutRevision"].clone();
            p["event"] = json!({"kind":kind,"objectID":"prop","previousAvatarAssetID":"private-avatar","heldBindingSHA256":binding["heldBindingSHA256"]});
            if kind == "world_detached" {
                p["event"]["selectedWorldID"] = json!("actual-other-world")
            }
            let mut wrong = p.clone();
            wrong["event"]["heldBindingSHA256"] = json!("wrong");
            assert_eq!(
                system_return(&tx, Path::new("/private/tmp"), &wrong).unwrap_err(),
                "world_prop_system_binding_changed"
            );
            let mut arbitrary = p.clone();
            arbitrary["event"]["kind"] = json!("model_requested_return");
            assert_eq!(
                system_return(&tx, Path::new("/private/tmp"), &arbitrary).unwrap_err(),
                "world_prop_invalid_input"
            );
            let reply = system_return(&tx, Path::new("/private/tmp"), &p).unwrap();
            assert!(reply["snapshot"]["record"]["state"]["heldProp"].is_null());
            assert_eq!(
                reply["snapshot"]["record"]["state"]["objectStates"]["prop"],
                original
            );
            assert_eq!(
                system_return(&tx, Path::new("/private/tmp"), &p).unwrap(),
                reply
            );
            let mut other_host = p;
            other_host["hostSessionID"] = json!("other-host");
            assert_eq!(
                system_return(&tx, Path::new("/private/tmp"), &other_host).unwrap_err(),
                "world_prop_request_conflict"
            );
        }
    }
    #[test]
    fn avatar_rebind_uses_observed_selection_and_preserves_reserved_return() {
        let mut c = db();
        let root = PrivateRoot::new();
        let mut bytes = b"glTF".to_vec();
        bytes.extend(2u32.to_le_bytes());
        bytes.extend(24u32.to_le_bytes());
        bytes.extend(4u32.to_le_bytes());
        bytes.extend(0x4e4f534au32.to_le_bytes());
        bytes.extend(b"{}  ");
        let hash = digest(&bytes);
        let file = root.path().join("rebind.glb");
        std::fs::write(&file, &bytes).unwrap();
        world::blob_put(
            &c,
            root.path(),
            &world::BlobPutRequest {
                sha256: hash.clone(),
                mime: "model/gltf-binary".into(),
                local_path: file.to_string_lossy().into(),
                remote_key: None,
            },
        )
        .unwrap();
        let tx = c.transaction().unwrap();
        let mut s = state();
        let mut prop = generated(&s["objectStates"]["prop"]).unwrap();
        prop["assetID"] = json!(format!("sha256:{hash}"));
        s["objectStates"]["prop"]["metadata"][world::GENERATED_PROP_KEY] =
            json!(encode(&prop).unwrap());
        let (mut facts, grid) = geometry();
        facts.environment_blob_ref = hash.clone();
        facts.objects.get_mut("prop").unwrap().asset_id = format!("sha256:{hash}");
        facts.objects.get_mut("prop").unwrap().blob_ref = hash;
        let (held_state, _) = reduce(&s, &command("hold"), Some(&(facts.clone(), grid))).unwrap();
        let reserved = held_state["heldProp"]["returnState"].clone();
        world::commit_prop(
            &tx,
            &world::CommitRequest {
                world_id: WORLD.into(),
                request_id: "rebind-held".into(),
                expected_revision: 1,
                producer: None,
                intent: None,
                ops: vec![world::Op {
                    op: "replaceState".into(),
                    state: Some(held_state),
                    ..Default::default()
                }],
            },
        )
        .unwrap();
        let mut p = params(2, "rebind");
        p["readBinding"] = json!(true);
        let binding = system_return(&tx, root.path(), &p).unwrap();
        p.as_object_mut().unwrap().remove("readBinding");
        p["expectedLayoutRevision"] =
            binding["snapshot"]["record"]["state"]["layoutRevision"].clone();
        facts.avatar.asset_id = "actual-new-avatar".into();
        facts.avatar.selection_revision = 2;
        let mut observe = p.clone();
        observe["layoutRevision"] = p["expectedLayoutRevision"].clone();
        observe["facts"] = serde_json::to_value(&facts).unwrap();
        let observation = request(&tx, root.path(), "world_prop_observe", observe).unwrap();
        p["geometryID"] = observation["geometryID"].clone();
        p["event"] = json!({"kind":"avatar_changed_rebind","objectID":"prop","previousAvatarAssetID":"private-avatar","heldBindingSHA256":binding["heldBindingSHA256"],"avatarAssetID":"actual-new-avatar","selectionRevision":2});
        let mut wrong = p.clone();
        wrong["event"]["heldBindingSHA256"] = json!("wrong");
        assert_eq!(
            system_return(&tx, root.path(), &wrong).unwrap_err(),
            "world_prop_system_binding_changed"
        );
        wrong = p.clone();
        wrong["event"]["selectionRevision"] = json!(3);
        assert_eq!(
            system_return(&tx, root.path(), &wrong).unwrap_err(),
            "world_prop_system_event_stale"
        );
        let receipt = system_return(&tx, root.path(), &p).unwrap();
        let held = &receipt["snapshot"]["record"]["state"]["heldProp"];
        assert_eq!(held["avatarAssetID"], "actual-new-avatar");
        assert_eq!(held["returnState"], reserved);
        assert_eq!(system_return(&tx, root.path(), &p).unwrap(), receipt);
    }
    #[test]
    fn generic_commit_cannot_bypass_registered_prop_authority() {
        let mut c = db();
        let tx = c.transaction().unwrap();
        // Only presence activates ownership; no geometry or authorization is
        // fabricated to execute a command in this projection-guard test.
        tx.execute(
            "INSERT INTO world_prop_native VALUES(?1,'private-resident','private-host','{}')",
            [WORLD],
        )
        .unwrap();
        let mut changed = state();
        // The baseline object is inventory/disabled. Mutate its actual bytes,
        // rather than asserting that an unchanged snapshot should be denied.
        changed["objectStates"]["prop"]["isEnabled"] = json!(true);
        let req = world::CommitRequest {
            world_id: WORLD.into(),
            request_id: "bypass".into(),
            expected_revision: 1,
            producer: Some("world-prop".into()),
            intent: None,
            ops: vec![world::Op {
                op: "replaceState".into(),
                state: Some(changed),
                ..Default::default()
            }],
        };
        assert_eq!(world::commit(&tx, &req), Err("world_prop_owned_projection"));
        assert_eq!(
            world::commit_activity(&tx, &req),
            Err("world_prop_owned_projection")
        );
        assert!(world::commit_prop(&tx, &req).is_ok());
    }
    #[test]
    fn ui_capability_exact_version_one_use_and_retry_are_durable() {
        let mut c = db();
        let root = PrivateRoot::new();
        let tx = c.transaction().unwrap();
        let mut p = params(1, "ui");
        p["command"] = serde_json::to_value(command("delete")).unwrap();
        let cap = request(&tx, root.path(), "world_prop_ui_intent", p.clone()).unwrap();
        p["authority"] =
            json!({"kind":"ui","intentID":cap["intentID"],"capability":cap["capability"]});
        let first = request(&tx, root.path(), "world_prop_command", p.clone()).unwrap();
        assert!(first["snapshot"]["record"]["state"]["objectStates"]
            .get("prop")
            .is_none());
        assert_eq!(
            request(&tx, root.path(), "world_prop_command", p.clone()).unwrap()["replayed"],
            true
        );
        p["requestID"] = json!("reuse");
        p["expectedRevision"] = first["snapshot"]["record"]["recordRevision"].clone();
        p["expectedLayoutRevision"] = json!(1);
        assert_eq!(
            request(&tx, root.path(), "world_prop_command", p),
            Err("world_prop_unauthorized")
        );
        tx.commit().unwrap();
    }
    #[test]
    fn caller_candidate_or_boolean_never_grants_permission() {
        let mut c = db();
        let root = PrivateRoot::new();
        let tx = c.transaction().unwrap();
        let mut p = params(1, "bad");
        p["command"] = serde_json::to_value(command("delete")).unwrap();
        p["allowsMutation"] = json!(true);
        p["candidate"] = state();
        assert_eq!(
            request(&tx, root.path(), "world_prop_command", p),
            Err("world_prop_unauthorized")
        );
        let snap = world::snapshot(
            &tx,
            &world::SnapshotRequest {
                world_id: WORLD.into(),
                include_state: Some(true),
            },
        )
        .unwrap();
        assert_eq!(snap["record"]["recordRevision"], 1);
    }
    #[test]
    fn ledger_dispatch_is_bound_to_actual_tool_input_not_caller_command() {
        let mut c = db();
        let root = PrivateRoot::new();
        let tx = c.transaction().unwrap();
        tx.execute("INSERT INTO agent_loop_events VALUES(?1,'private-resident','event','{}','claimed','run','private-host',0,NULL)",[WORLD]).unwrap();
        tx.execute("INSERT INTO agent_loop_human_messages VALUES(?1,'private-resident','human','private-input','claimed','event','run','private-host',NULL,'human')",[WORLD]).unwrap();
        let input = encode(&json!({"object_id":"prop","layout_revision":0})).unwrap();
        tx.execute("INSERT INTO agent_tool_calls VALUES(?1,'private-resident','run','private-host','call','operation','delete_prop',?2,'write','inflight',NULL)",params![WORLD,input]).unwrap();
        let mut p = params(1, "actual-ledger");
        p["authority"] =
            json!({"kind":"agent","runID":"run","callID":"call","operationID":"operation"});
        p["command"] = json!({"op":"delete","objectID":"basic"});
        let result = request(&tx, root.path(), "world_prop_command", p.clone()).unwrap();
        assert_eq!(result["receipt"]["objectID"], "prop");
        assert!(result["snapshot"]["record"]["state"]["objectStates"]
            .get("basic")
            .is_some());
        p["requestID"] = json!("bad-context");
        p["authority"]["operationID"] = json!("other");
        p["expectedRevision"] = result["snapshot"]["record"]["recordRevision"].clone();
        p["expectedLayoutRevision"] = json!(1);
        assert_eq!(
            request(&tx, root.path(), "world_prop_command", p),
            Err("world_prop_unauthorized")
        );
    }
    #[test]
    fn register_uses_claimed_job_artifact_and_receipt_preserves_manual_size() {
        let mut c = db();
        let root = PrivateRoot::new();
        let mut bytes = b"glTF".to_vec();
        bytes.extend(2u32.to_le_bytes());
        bytes.extend(24u32.to_le_bytes());
        bytes.extend(4u32.to_le_bytes());
        bytes.extend(0x4e4f534au32.to_le_bytes());
        bytes.extend(b"{}  ");
        let hash = digest(&bytes);
        let path = root.path().join("private-core.glb");
        std::fs::write(&path, &bytes).unwrap();
        world::blob_put(
            &c,
            root.path(),
            &world::BlobPutRequest {
                sha256: hash.clone(),
                mime: "model/gltf-binary".into(),
                local_path: path.to_string_lossy().into(),
                remote_key: None,
            },
        )
        .unwrap();
        let wish_id = "765edee9-6b39-43b1-a96c-a575c7fb15bf";
        let wish = json!({"id":wish_id,"jobID":"private-core","objectID":"registered","worldID":WORLD,"residentScope":"private-resident","stage":"claimed","modelPath":path.to_string_lossy(),"name":"real artifact","heightMeters":0.3});
        let core = json!({"job":{"id":"private-core","name":"real artifact","endpoint":"https://example.invalid","imagePath":"unused","imageSHA256":"0".repeat(64),"heightMeters":0.3,"source":{"author":"fixture","license":"CC0"},"idempotencyKey":"private-core","receipt":{"state":"completed","result":{"inspection":{"bytes":bytes.len(),"sha256":hash}}},"localModelPath":path.to_string_lossy(),"context":{"worldID":WORLD,"residentScope":"private-resident"}},"attempted":true});
        c.execute(
            "INSERT INTO jobs(id,data) VALUES('private-core',?1)",
            [encode(&core).unwrap()],
        )
        .unwrap();
        c.execute(
            "INSERT INTO wish_control_documents VALUES('private-owner','private-host',0,?1,NULL)",
            [encode(&json!({"jobs":[wish]})).unwrap()],
        )
        .unwrap();
        let tx = c.transaction().unwrap();
        let mut p = params(1, "register");
        p["wishID"] = json!(wish_id);
        p["measurement"] =
            json!({"blobRef":hash,"triangles":geometry().0.objects["prop"].triangles});
        assert_eq!(
            request(&tx, root.path(), "world_prop_output_preview", p.clone()),
            Err("world_prop_unauthorized")
        );
        let mut ready = wish.clone();
        ready["stage"] = json!("ready");
        tx.execute(
            "UPDATE wish_control_documents SET payload=?1 WHERE session='private-host'",
            [encode(&json!({"jobs":[ready]})).unwrap()],
        )
        .unwrap();
        let before = snapshot(&tx, &p).unwrap();
        let command_count: i64 = tx
            .query_row("SELECT count(*) FROM world_prop_commands", [], |r| r.get(0))
            .unwrap();
        let preview = request(&tx, root.path(), "world_prop_output_preview", p.clone()).unwrap();
        assert_eq!(preview["prop"]["assetID"], format!("sha256:{hash}"));
        assert_eq!(preview["snapshot"], before);
        assert!(preview.get("commit").is_none());
        assert!(preview.get("receipt").is_none());
        assert_eq!(snapshot(&tx, &p).unwrap(), before);
        assert_eq!(
            tx.query_row::<i64, _, _>("SELECT count(*) FROM world_prop_commands", [], |r| r.get(0))
                .unwrap(),
            command_count
        );
        let mut unknown = p.clone();
        unknown["wishID"] = json!(uuid::Uuid::new_v4().to_string());
        assert_eq!(
            request(&tx, root.path(), "world_prop_output_preview", unknown),
            Err("world_prop_unauthorized")
        );
        tx.execute(
            "UPDATE wish_control_documents SET payload=?1 WHERE session='private-host'",
            [encode(&json!({"jobs":[wish]})).unwrap()],
        )
        .unwrap();
        let out = request(&tx, root.path(), "world_prop_register", p.clone()).unwrap();
        assert_eq!(out["prop"]["assetID"], format!("sha256:{hash}"));
        assert_eq!(
            out["snapshot"]["record"]["state"]["objectStates"]["registered"]["isEnabled"],
            false
        );
        assert_eq!(
            request(&tx, root.path(), "world_prop_register", p.clone()).unwrap()["replayed"],
            true
        );
        let query = params(0, "register");
        assert_eq!(
            request(&tx, root.path(), "world_prop_receipt", query).unwrap()["found"],
            true
        );
        let mut wrong = p.clone();
        wrong["requestID"] = json!("wrong");
        wrong["expectedRevision"] = out["snapshot"]["record"]["recordRevision"].clone();
        wrong["expectedLayoutRevision"] = json!(1);
        wrong["measurement"]["blobRef"] = json!("0".repeat(64));
        assert_eq!(
            request(&tx, root.path(), "world_prop_register", wrong),
            Err("world_prop_invalid_native_facts")
        );
        let mut s = out["snapshot"]["record"]["state"].clone();
        let resized = crate::world_prop_measurement::manual_resize(&out["prop"], 0.6).unwrap();
        s["objectStates"]["registered"]["metadata"][world::GENERATED_PROP_KEY] =
            json!(encode(&resized).unwrap());
        world::commit_prop(
            &tx,
            &world::CommitRequest {
                world_id: WORLD.into(),
                request_id: "manual-fixture".into(),
                expected_revision: 2,
                producer: None,
                intent: None,
                ops: vec![world::Op {
                    op: "replaceState".into(),
                    state: Some(s),
                    ..Default::default()
                }],
            },
        )
        .unwrap();
        p["requestID"] = json!("register-again");
        p["expectedRevision"] = json!(3);
        p["expectedLayoutRevision"] = json!(1);
        let again = request(&tx, root.path(), "world_prop_register", p).unwrap();
        assert_eq!(again["prop"], resized);
        assert!(again["commit"].is_null());
    }
    #[test]
    fn native_geometry_requires_matching_real_blob_and_current_versions() {
        let mut c = db();
        let root = PrivateRoot::new();
        let mut bytes = b"glTF".to_vec();
        bytes.extend(2u32.to_le_bytes());
        bytes.extend(24u32.to_le_bytes());
        bytes.extend(4u32.to_le_bytes());
        bytes.extend(0x4e4f534au32.to_le_bytes());
        bytes.extend(b"{}  ");
        let hash = digest(&bytes);
        let file = root.path().join("private.glb");
        std::fs::write(&file, &bytes).unwrap();
        world::blob_put(
            &c,
            root.path(),
            &world::BlobPutRequest {
                sha256: hash.clone(),
                mime: "model/gltf-binary".into(),
                local_path: file.to_string_lossy().into(),
                remote_key: None,
            },
        )
        .unwrap();
        let tx = c.transaction().unwrap();
        let mut s = state();
        let mut prop = generated(&s["objectStates"]["prop"]).unwrap();
        prop["assetID"] = json!(format!("sha256:{hash}"));
        s["objectStates"]["prop"]["metadata"][world::GENERATED_PROP_KEY] =
            json!(encode(&prop).unwrap());
        world::commit(
            &tx,
            &world::CommitRequest {
                world_id: WORLD.into(),
                request_id: "native-asset".into(),
                expected_revision: 1,
                producer: None,
                intent: None,
                ops: vec![world::Op {
                    op: "replaceState".into(),
                    state: Some(s),
                    ..Default::default()
                }],
            },
        )
        .unwrap();
        let mut facts = geometry().0;
        facts.environment_blob_ref = hash.clone();
        let mesh = facts.objects.get_mut("prop").unwrap();
        mesh.asset_id = format!("sha256:{hash}");
        mesh.blob_ref = hash;
        let mut p = params(2, "observe");
        p["layoutRevision"] = json!(0);
        p["facts"] = serde_json::to_value(facts).unwrap();
        let observed = request(&tx, root.path(), "world_prop_observe", p.clone()).unwrap();
        assert_eq!(observed["meshSHA256"].as_str().unwrap().len(), 64);
        let mut preview = params(2, "preview");
        preview["geometryID"] = observed["geometryID"].clone();
        preview["command"] = serde_json::to_value(command("place")).unwrap();
        assert_eq!(
            request(&tx, root.path(), "world_prop_preview", preview.clone()).unwrap()["canPlace"],
            true
        );
        preview["geometryID"] = json!("unregistered");
        assert_eq!(
            request(&tx, root.path(), "world_prop_preview", preview),
            Err("world_prop_stale_native_facts")
        );
        p["facts"]["objects"]["prop"]["assetID"] = json!("wrong-asset");
        assert_eq!(
            request(&tx, root.path(), "world_prop_observe", p),
            Err("world_prop_invalid_native_facts")
        );
        std::fs::write(&file, b"corrupt").unwrap();
        let mut read = params(2, "badblob");
        read["geometryID"] = observed["geometryID"].clone();
        read["command"] = serde_json::to_value(command("place")).unwrap();
        assert_eq!(
            request(&tx, root.path(), "world_prop_preview", read),
            Err("world_prop_asset_unverified")
        );
    }
}
