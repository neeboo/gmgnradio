//! Marble lifecycle authority. Native transports raw HTTP and measures packages;
//! it cannot choose completion, polling, identities, or paid retries.
use crate::{
    canonical_json, files,
    model::{self, Result},
    world,
};
use base64::Engine;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde_json::{json, Value};
use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_BODY: usize = 1024 * 1024;
const POLL_INTERVAL: u64 = 3000;
const POLL_BUDGET: u64 = 120;
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS marble_control_libraries(owner TEXT PRIMARY KEY,payload TEXT NOT NULL,legacy_hash TEXT);
        CREATE TABLE IF NOT EXISTS marble_control_tasks(owner TEXT NOT NULL,task TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(owner,task));
        CREATE TABLE IF NOT EXISTS marble_control_actions(owner TEXT NOT NULL,task TEXT NOT NULL,action TEXT NOT NULL,input TEXT NOT NULL,receipt TEXT,PRIMARY KEY(owner,task,action));
        CREATE TABLE IF NOT EXISTS marble_control_commands(owner TEXT NOT NULL,request TEXT NOT NULL,input TEXT NOT NULL,output TEXT NOT NULL,PRIMARY KEY(owner,request));
        CREATE TABLE IF NOT EXISTS marble_control_presets(owner TEXT NOT NULL,preset TEXT NOT NULL,binding TEXT NOT NULL,PRIMARY KEY(owner,preset));").map_err(|_| "storage_unavailable")
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("marble_control_invalid_input")
}
fn encoded(v: &Value) -> Result<String> {
    let s = canonical_json::to_string(v).map_err(|_| "marble_control_invalid_input")?;
    if s.len() > 4 * MAX_BODY {
        return Err("marble_control_capacity");
    }
    Ok(s)
}
fn decoded(s: String) -> Result<Value> {
    serde_json::from_str(&s).map_err(|_| "marble_control_corrupt")
}
fn now() -> Result<u64> {
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "marble_control_clock_unavailable")?
        .as_millis();
    u64::try_from(n)
        .ok()
        .filter(|n| *n <= i64::MAX as u64)
        .ok_or("marble_control_clock_unavailable")
}
fn library(c: &Connection, owner: &str) -> Result<Value> {
    c.query_row("SELECT payload FROM marble_control_libraries WHERE owner=?1", [owner], |r| r.get::<_,String>(0))
        .optional().map_err(|_| "storage_unavailable")?.map(decoded).unwrap_or_else(||Ok(json!({"revision":0,"worlds":public_worlds(),"selectedWorldID":null,"currentTaskID":null,"selectionImported":false})))
}
fn task(c: &Connection, owner: &str, id: &str) -> Result<Value> {
    decoded(
        c.query_row(
            "SELECT payload FROM marble_control_tasks WHERE owner=?1 AND task=?2",
            params![owner, id],
            |r| r.get(0),
        )
        .map_err(|_| "marble_control_unknown_task")?,
    )
}
fn select_catalog(lib: &mut Value) -> Result<()> {
    let worlds = lib["worlds"].as_array().ok_or("marble_control_corrupt")?;
    let saved = lib["selectedWorldID"]
        .as_str()
        .filter(|id| worlds.iter().any(|w| w["id"] == *id))
        .map(str::to_owned);
    let selected = saved
        .or(catalog_preset(lib, "dj_house")?)
        .or_else(|| {
            worlds
                .iter()
                .find(|w| w["id"] == "56934fab-6a88-4136-bdf8-a46fef39b2f0")
                .and_then(|w| w["id"].as_str().map(str::to_owned))
        })
        .or_else(|| {
            worlds
                .first()
                .and_then(|w| w["id"].as_str().map(str::to_owned))
        });
    lib["selectedWorldID"] = json!(selected);
    Ok(())
}
fn output(c: &Connection, owner: &str, lib: &Value) -> Result<Value> {
    let t = lib["currentTaskID"]
        .as_str()
        .map(|id| task(c, owner, id))
        .transpose()?
        .unwrap_or(Value::Null);
    let mut presets = serde_json::Map::new();
    let mut packages = serde_json::Map::new();
    for id in ["dj_house", "cosy_wood_house"] {
        let binding: Option<String> = c
            .query_row(
                "SELECT binding FROM marble_control_presets WHERE owner=?1 AND preset=?2",
                params![owner, id],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        let binding = binding.map(decoded).transpose()?;
        if let Some(binding) = &binding {
            packages.insert(id.into(), binding.clone());
        }
        let selected = binding
            .and_then(|v| v["worldID"].as_str().map(str::to_owned))
            .or(catalog_preset(lib, id)?);
        if let Some(selected) = selected {
            presets.insert(id.into(), json!(selected));
        }
    }
    Ok(
        json!({"revision":lib["revision"],"worlds":lib["worlds"],"selectedWorldID":lib["selectedWorldID"],"task":t,"presetWorldIDs":presets,"presetPackages":packages}),
    )
}
fn save(c: &Connection, owner: &str, lib: &mut Value, t: Option<&Value>) -> Result<()> {
    lib["revision"] = json!(lib["revision"]
        .as_u64()
        .ok_or("marble_control_corrupt")?
        .checked_add(1)
        .filter(|n| *n <= i64::MAX as u64)
        .ok_or("marble_control_capacity")?);
    if let Some(t) = t {
        c.execute("INSERT INTO marble_control_tasks VALUES(?1,?2,?3) ON CONFLICT(owner,task) DO UPDATE SET payload=excluded.payload",params![owner,text(t,"taskID")?,encoded(t)?]).map_err(|_|"storage_unavailable")?;
    }
    c.execute("INSERT INTO marble_control_libraries(owner,payload) VALUES(?1,?2) ON CONFLICT(owner) DO UPDATE SET payload=excluded.payload",params![owner,encoded(lib)?]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn expected(p: &Value, lib: &Value) -> Result<()> {
    if p["expectedRevision"] != lib["revision"] {
        return Err("marble_control_revision_conflict");
    }
    Ok(())
}
fn preset(id: &str) -> Result<Value> {
    let (name, model, prompt, tags, image) = match id {
        "dj_house" => ("gmgn DJ House", "marble-1.0-draft", "A premium nighttime electronic music recording studio and intimate DJ listening room. Matte black acoustic walls, brushed dark metal, restrained cyan and violet neon accents, a central professional mixing console, studio monitors, synthesizers and turntables. Keep a clear walkable floor, realistic interior scale, cinematic high contrast and warm practical lights. No people, no text, no logos, no floating interface.",json!(["gmgn-radio","dj-house","image-v3","recording-studio"]),Some("b14767e2-448c-4f61-9c17-b051f3cea509")),
        "cosy_wood_house" => ("gmgn Cosy Wood House", "marble-1.1-plus", "A complete explorable cosy wood cabin interior made for listening to records at night. The camera begins at human eye level in a warm timber living room with a built-in fireplace, a physical record player and vinyl shelves, soft sofa, wool rugs, reading lamps and large rain-covered windows looking into a dark pine forest. Keep realistic room scale, connected walking space, rich warm materials and restrained cinematic lighting. No text, no people, no floating interface, no isolated product render.",json!(["gmgn-radio","cosy-wood-house"]),None),
        _ => return Err("marble_control_unknown_preset")
    };
    let mut p = json!({"type":"text","text_prompt":prompt,"disable_recaption":true});
    if let Some(id) = image {
        p["type"] = json!("image");
        p["image_prompt"] = json!({"source":"media_asset","media_asset_id":id});
        p["is_pano"] = json!(false);
    }
    Ok(json!({"world_prompt":p,"display_name":name,"model":model,"tags":tags}))
}
fn url(v: &Value) -> Result<Value> {
    if v.is_null() {
        return Ok(Value::Null);
    }
    let raw = v.as_str().ok_or("marble_control_invalid_response")?;
    let u = reqwest::Url::parse(raw).map_err(|_| "marble_control_invalid_response")?;
    if !["https", "http"].contains(&u.scheme())
        || !u.username().is_empty()
        || u.password().is_some()
        || raw.len() > 4096
    {
        return Err("marble_control_invalid_response");
    }
    // HTTP is only available for explicitly injected loopback fixture transports.
    if u.scheme() == "http" && u.host_str() != Some("127.0.0.1") {
        return Err("marble_control_invalid_response");
    }
    Ok(json!(raw))
}
fn normalized_world(v: &Value) -> Result<Value> {
    let id = v["world_id"]
        .as_str()
        .or_else(|| v["id"].as_str())
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("marble_control_invalid_response")?;
    let name = v["display_name"].as_str().unwrap_or(id);
    if name.len() > 4096 {
        return Err("marble_control_invalid_response");
    }
    let mut splats = vec![];
    for q in ["500k", "150k", "100k", "full_res"] {
        let u = &v["assets"]["splats"]["spz_urls"][q];
        if !u.is_null() {
            splats.push(json!({"quality":q,"url":url(u)?}));
        }
    }
    let semantics = &v["assets"]["splats"]["semantics_metadata"];
    let scale = semantics["metric_scale_factor"].as_f64().unwrap_or(1.);
    let offset = semantics["ground_plane_offset"].as_f64().unwrap_or(0.);
    if !scale.is_finite() || scale <= 0. || !offset.is_finite() {
        return Err("marble_control_invalid_response");
    }
    Ok(
        json!({"id":id,"name":name,"model":v["model"],"thumbnailURL":url(&v["assets"]["thumbnail_url"])? ,"colliderURL":url(&v["assets"]["mesh"]["collider_mesh_url"])? ,"colliderCoordinates":"glTF","semantics":{"metricScale":scale,"groundPlaneOffset":offset},"splatFallbacks":splats}),
    )
}
fn public_worlds() -> Value {
    let rows = [
        (
            "elegant-library",
            "壁炉图书馆",
            "elegant_library_with_fireplace",
        ),
        (
            "modern-house",
            "现代住宅",
            "modern_house_with_lush_landscaping",
        ),
        (
            "rustic-kitchen",
            "自然光乡村厨房",
            "rustic_kitchen_with_natural_light",
        ),
        ("cobblestone-lane", "欧洲石板巷", "cobblestone_lane"),
        (
            "warm-kitchen",
            "暖色传统厨房",
            "warm_traditional_kitchen_interior",
        ),
    ];
    json!(rows.into_iter().map(|(id,name,slug)| {let root=format!("https://wlt-ai-cdn.art/example_exports/{slug}");json!({"id":format!("world-labs-example-{id}"),"name":name,"model":"world-labs-official-example","thumbnailURL":null,"colliderURL":format!("{root}/{slug}_collider.glb"),"colliderCoordinates":"worldLabsOpenCV","semantics":{"metricScale":1,"groundPlaneOffset":0},"splatFallbacks":[{"quality":"500k","url":format!("{root}/{slug}_500k.spz")},{"quality":"full_res","url":format!("{root}/{slug}_2m.spz")}]})}).collect::<Vec<_>>())
}
#[cfg(target_os = "macos")]
fn name_equal(a: &str, b: &str) -> Result<bool> {
    use std::ffi::{c_char, c_void};
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            a: *const c_void,
            b: *const u8,
            n: isize,
            e: u32,
            x: u8,
        ) -> *const c_void;
        fn CFRelease(v: *const c_void);
    }
    #[link(name = "Foundation", kind = "framework")]
    unsafe extern "C" {}
    #[link(name = "objc")]
    unsafe extern "C" {
        fn sel_registerName(s: *const c_char) -> *const c_void;
        fn objc_msgSend();
    }
    unsafe {
        let left = CFStringCreateWithBytes(
            std::ptr::null(),
            a.as_ptr(),
            a.len() as isize,
            0x08000100,
            0,
        );
        let right = CFStringCreateWithBytes(
            std::ptr::null(),
            b.as_ptr(),
            b.len() as isize,
            0x08000100,
            0,
        );
        if left.is_null() || right.is_null() {
            if !left.is_null() {
                CFRelease(left);
            }
            if !right.is_null() {
                CFRelease(right);
            }
            return Err("marble_control_comparison_unavailable");
        }
        let send: unsafe extern "C" fn(
            *const c_void,
            *const c_void,
            *const c_void,
            usize,
        ) -> isize = std::mem::transmute(objc_msgSend as *const ());
        let equal = send(
            left,
            sel_registerName(c"compare:options:".as_ptr()),
            right,
            129,
        ) == 0;
        CFRelease(left);
        CFRelease(right);
        Ok(equal)
    }
}
#[cfg(not(target_os = "macos"))]
fn name_equal(_: &str, _: &str) -> Result<bool> {
    Err("marble_control_comparison_unavailable")
}
fn catalog_preset(lib: &Value, id: &str) -> Result<Option<String>> {
    let desired = preset(id)?["display_name"].as_str().unwrap().to_owned();
    for w in lib["worlds"].as_array().ok_or("marble_control_corrupt")? {
        if name_equal(text(w, "name")?, &desired)? {
            return Ok(Some(text(w, "id")?.into()));
        }
    }
    Ok(None)
}
fn action(
    c: &Connection,
    owner: &str,
    t: &mut Value,
    kind: &str,
    method: Option<&str>,
    path: Option<String>,
    body: Value,
    due: u64,
) -> Result<()> {
    let id = uuid::Uuid::new_v4().to_string();
    let a = json!({"actionID":id,"taskID":t["taskID"],"hostSessionID":t["hostSessionID"],"generation":t["generation"],"kind":kind,"method":method,"path":path,"body":body,"world":t["world"],"dueAtMS":due,"status":"queued"});
    c.execute(
        "INSERT INTO marble_control_actions VALUES(?1,?2,?3,?4,NULL)",
        params![owner, text(t, "taskID")?, id, encoded(&a)?],
    )
    .map_err(|_| "storage_unavailable")?;
    t["actionID"] = json!(id);
    Ok(())
}
fn current_action(c: &Connection, owner: &str, t: &Value) -> Result<Value> {
    decoded(
        c.query_row(
            "SELECT input FROM marble_control_actions WHERE owner=?1 AND task=?2 AND action=?3",
            params![owner, text(t, "taskID")?, text(t, "actionID")?],
            |r| r.get(0),
        )
        .map_err(|_| "marble_control_unknown_action")?,
    )
}
fn path_id(id: &str) -> Result<String> {
    if id.len() > 256
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err("marble_control_invalid_response");
    }
    Ok(id.into())
}
fn polling(c: &Connection, owner: &str, t: &mut Value, due: u64) -> Result<()> {
    let id = path_id(text(t, "operationID")?)?;
    action(
        c,
        owner,
        t,
        "operation",
        Some("GET"),
        Some(format!("/marble/v1/operations/{id}")),
        Value::Null,
        due,
    )
}
fn operation(c: &Connection, owner: &str, t: &mut Value, v: &Value, at: u64) -> Result<()> {
    let id = text(v, "operation_id").map_err(|_| "marble_control_invalid_response")?;
    path_id(id)?;
    if let Some(prior) = t["operationID"].as_str() {
        if prior != id {
            return Err("marble_control_identity_mismatch");
        }
    }
    t["operationID"] = json!(id);
    let done = v["done"]
        .as_bool()
        .ok_or("marble_control_invalid_response")?;
    if let Some(progress) = v["metadata"]["progress"]["percentage"].as_f64() {
        if !progress.is_finite() {
            return Err("marble_control_invalid_response");
        }
        t["progress"] = json!(progress.round() as i64);
    }
    if let Some(message) = v["error"]["message"].as_str() {
        t["status"] = json!("failed");
        t["phase"] = json!("failed");
        t["errorCode"] = json!("marble_control_generation_failed");
        t["errorMessage"] = json!(message.chars().take(300).collect::<String>());
        return Ok(());
    }
    if t["cancelRequested"] == true {
        t["status"] = json!("cancelled_remote");
        t["phase"] = json!("cancelled_remote_operation_may_continue");
        return Ok(());
    }
    t["status"] = json!("pending");
    if done {
        let world_id = path_id(
            text(&v["response"], "world_id").map_err(|_| "marble_control_identity_missing")?,
        )?;
        t["worldID"] = json!(world_id);
        action(
            c,
            owner,
            t,
            "world",
            Some("GET"),
            Some(format!("/marble/v1/worlds/{world_id}")),
            Value::Null,
            at,
        )?;
    } else {
        t["phase"] = json!("generating");
        polling(c, owner, t, at.saturating_add(POLL_INTERVAL))?;
    }
    Ok(())
}
fn http_body(fact: &Value) -> Result<Value> {
    if fact["transportErrorCode"].is_string() {
        return Err("marble_control_transport_failed");
    }
    let status = fact["statusCode"]
        .as_u64()
        .filter(|n| *n >= 100 && *n <= 599)
        .ok_or("marble_control_invalid_response")?;
    if !(200..300).contains(&status) {
        return Err("marble_control_provider_rejected");
    }
    let raw = fact["bodyBase64"]
        .as_str()
        .filter(|s| s.len() <= MAX_BODY * 4 / 3 + 8)
        .ok_or("marble_control_invalid_response")?;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(raw)
        .map_err(|_| "marble_control_invalid_response")?;
    if bytes.len() > MAX_BODY {
        return Err("marble_control_capacity");
    }
    serde_json::from_slice(&bytes).map_err(|_| "marble_control_invalid_response")
}
fn package(tx: &Transaction<'_>, root: &Path, t: &Value, fact: &Value, at: u64) -> Result<Value> {
    let id = text(t, "worldID")?;
    let package_root = root
        .parent()
        .ok_or("marble_control_invalid_package")?
        .join("WorldPackages")
        .join(model::digest(id.as_bytes()));
    let manifest_bytes = files::read(&package_root.join("world.json"), MAX_BODY)?;
    if fact["manifestSHA256"].as_str() != Some(model::digest(&manifest_bytes).as_str()) {
        return Err("marble_control_invalid_package");
    }
    let manifest: Value =
        serde_json::from_slice(&manifest_bytes).map_err(|_| "marble_control_invalid_package")?;
    if manifest["worldID"] != t["worldID"]
        || manifest["packageID"] != json!(format!("marble-{}", model::digest(id.as_bytes())))
    {
        return Err("marble_control_identity_mismatch");
    }
    let resources = manifest["resources"]
        .as_array()
        .filter(|r| r.len() == 3)
        .ok_or("marble_control_invalid_package")?;
    for r in resources {
        let path = text(r, "path")?;
        if !["scene.spz", "collider.glb", "marble-runtime.json"].contains(&path) {
            return Err("marble_control_invalid_package");
        }
        let limit = if path.ends_with("spz") {
            512 * MAX_BODY
        } else if path.ends_with("glb") {
            256 * MAX_BODY
        } else {
            MAX_BODY
        };
        let bytes = files::read(&package_root.join(path), limit)?;
        if r["sha256"].as_str() != Some(model::digest(&bytes).as_str()) {
            return Err("marble_control_invalid_package");
        }
    }
    let digest = model::digest(&manifest_bytes);
    // An existing authoritative world may have evolved. Never overwrite it with a new seed.
    let current = world::materialize(tx, id)?;
    let initial = json!({"worldID":id,"revision":0,"layoutRevision":0,"worldTime":at,"lastObservedWallTime":at,"weather":"clear","agentTransform":manifest["spawn"],"objectStates":{},"completedGoals":{},"layoutReceipts":{}});
    let lineage = if let Some(existing) = current {
        let _ = existing;
        let marker: Option<(String, String)> = tx
            .query_row(
                "SELECT package_id,package_version FROM world_imports WHERE world_id=?1",
                [id],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        if marker.as_ref().is_none_or(|(id, version)| {
            Some(id.as_str()) != manifest["packageID"].as_str()
                || Some(version.as_str()) != manifest["packageVersion"].as_str()
        }) {
            return Err("marble_control_package_conflict");
        }
        let mut q = tx
            .prepare("SELECT binding FROM marble_control_presets WHERE owner=?1")
            .map_err(|_| "storage_unavailable")?;
        let bindings = q
            .query_map([text(t, "owner")?], |r| r.get::<_, String>(0))
            .map_err(|_| "storage_unavailable")?;
        let mut matching = false;
        for raw in bindings {
            let b = decoded(raw.map_err(|_| "storage_unavailable")?)?;
            if b["worldID"] == t["worldID"] && b["manifestSHA256"] == digest {
                matching = true;
            }
        }
        if !matching {
            // Import-only worlds have no preset: their original durable task receipt is lineage too.
            let mut q = tx
                .prepare("SELECT payload FROM marble_control_tasks WHERE owner=?1")
                .map_err(|_| "storage_unavailable")?;
            let rows = q
                .query_map([text(t, "owner")?], |r| r.get::<_, String>(0))
                .map_err(|_| "storage_unavailable")?;
            for raw in rows {
                let prior = decoded(raw.map_err(|_| "storage_unavailable")?)?;
                if prior["package"]["worldID"] == t["worldID"]
                    && prior["package"]["manifestSHA256"] == digest
                {
                    matching = true;
                }
            }
        }
        if !matching {
            let legacy_path = root
                .parent()
                .ok_or("marble_control_invalid_package")?
                .join("WorldRegistrations")
                .join(format!("{}.json", model::digest(id.as_bytes())));
            let bytes = files::read(&legacy_path, 4 * MAX_BODY)
                .map_err(|_| "marble_control_package_conflict")?;
            let prior: Value =
                serde_json::from_slice(&bytes).map_err(|_| "marble_control_package_conflict")?;
            if prior["manifestSHA256"] != digest
                || prior["packageID"] != manifest["packageID"]
                || prior["packageVersion"] != manifest["packageVersion"]
            {
                return Err("marble_control_package_conflict");
            }
        }
        json!({"existing":true})
    } else {
        let raw = encoded(&initial)?;
        world::import(
            tx,
            &world::ImportRequest {
                world_id: id.into(),
                request_id: format!("marble-register-{}", text(t, "taskID")?),
                producer: Some("marble-control".into()),
                package_id: text(&manifest, "packageID")?.into(),
                package_version: text(&manifest, "packageVersion")?.into(),
                state_sha256: model::digest(raw.as_bytes()),
                state_json: raw,
            },
        )?
    };
    if world::materialize(tx, id)?.is_none() {
        return Err("marble_control_registration_failed");
    }
    Ok(
        json!({"worldID":id,"manifestSHA256":digest,"packageID":manifest["packageID"],"packageVersion":manifest["packageVersion"],"registration":lineage}),
    )
}

/// Recovery never dispatches an HTTP or file action. Original in-flight actions
/// retain their identity so a late, exact receipt can still resolve uncertainty.
pub fn recover(c: &Connection) -> Result<()> {
    let mut q = c
        .prepare("SELECT owner,task,payload FROM marble_control_tasks")
        .map_err(|_| "storage_unavailable")?;
    let rows = q
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })
        .map_err(|_| "storage_unavailable")?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| "storage_unavailable")?;
    for (owner, id, raw) in rows {
        let mut t = decoded(raw)?;
        if ["pending", "inflight"].contains(&t["status"].as_str().unwrap_or("")) {
            let a = current_action(c, &owner, &t)?;
            t["status"] = json!(if a["status"] == "inflight" {
                "unknown"
            } else {
                "resume_available"
            });
            t["phase"] = json!("resume_available");
            c.execute(
                "UPDATE marble_control_tasks SET payload=?3 WHERE owner=?1 AND task=?2",
                params![owner, id, encoded(&t)?],
            )
            .map_err(|_| "storage_unavailable")?;
        }
    }
    Ok(())
}
pub fn request(c: &mut Connection, root: &Path, method: &str, p: Value) -> Result<Value> {
    import_legacy(c, root, text(&p, "owner")?, text(&p, "hostSessionID")?)?;
    transition(c, root, method, p, now()?)
}

/// Only the two known preset files and one known pending file may be read.
/// Never mutate them or overwrite an already-authoritative library.
pub fn import_legacy(c: &mut Connection, root: &Path, owner: &str, host: &str) -> Result<()> {
    let prior: Option<(String, Option<String>)> = c
        .query_row(
            "SELECT payload,legacy_hash FROM marble_control_libraries WHERE owner=?1",
            [owner],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if prior.as_ref().is_some_and(|(_, hash)| hash.is_some()) {
        return Ok(());
    }
    if prior.as_ref().is_some_and(|(raw, _)| {
        decoded(raw.clone())
            .ok()
            .is_some_and(|v| v["revision"].as_u64().unwrap_or(0) > 0)
    }) {
        c.execute("UPDATE marble_control_libraries SET legacy_hash='already-authoritative' WHERE owner=?1",[owner]).map_err(|_|"storage_unavailable")?;
        return Ok(());
    }
    let base = root
        .parent()
        .ok_or("marble_control_invalid_package")?
        .join("MarbleOperations");
    let read = |path: &Path| -> Result<Option<Vec<u8>>> {
        match std::fs::symlink_metadata(path) {
            Ok(_) => files::read(path, MAX_BODY).map(Some),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(_) => Err("marble_control_legacy_invalid"),
        }
    };
    let pending = read(&base.join("pending.json"))?;
    let mut old_presets = vec![];
    let mut digest_input = vec![];
    if let Some(bytes) = &pending {
        digest_input.extend_from_slice(bytes);
    }
    for id in ["dj_house", "cosy_wood_house"] {
        if let Some(bytes) = read(&base.join("Presets").join(format!("{id}.json")))? {
            digest_input.extend_from_slice(id.as_bytes());
            digest_input.extend_from_slice(&bytes);
            old_presets.push((id, bytes));
        }
    }
    let at = now()?;
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let mut lib = library(&tx, owner)?;
    for (id, bytes) in old_presets {
        let prior: Value =
            serde_json::from_slice(&bytes).map_err(|_| "marble_control_legacy_invalid")?;
        let world_id = text(&prior, "worldID")?;
        if world::materialize(&tx, world_id)?.is_none() {
            return Err("marble_control_legacy_unconfirmed");
        }
        let proof =
            json!({"owner":owner,"taskID":format!("legacy-{id}"),"presetID":id,"worldID":world_id});
        let binding = package(&tx, root, &proof, &prior, at)?;
        tx.execute(
            "INSERT INTO marble_control_presets VALUES(?1,?2,?3)",
            params![owner, id, encoded(&binding)?],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    if let Some(bytes) = pending {
        let prior: Value =
            serde_json::from_slice(&bytes).map_err(|_| "marble_control_legacy_invalid")?;
        let operation_id = path_id(text(&prior, "operationID")?)?;
        preset(text(&prior, "presetID")?)?;
        let id = format!("legacy-{}", model::digest(&bytes));
        let mut t = json!({"owner":owner,"taskID":id,"hostSessionID":host,"generation":1,"status":"resume_available","phase":"resume_available","presetID":prior["presetID"],"operationID":operation_id,"worldID":null,"world":null,"progress":null,"errorCode":null,"cancelRequested":false,"pollAttempts":0,"deadlineMS":at.saturating_add(POLL_INTERVAL*POLL_BUDGET)});
        polling(&tx, owner, &mut t, at)?;
        lib["currentTaskID"] = json!(id);
        save(&tx, owner, &mut lib, Some(&t))?;
    } else {
        save(&tx, owner, &mut lib, None)?;
    }
    tx.execute(
        "UPDATE marble_control_libraries SET legacy_hash=?2 WHERE owner=?1",
        params![owner, model::digest(&digest_input)],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(())
}
fn transition(c: &mut Connection, root: &Path, method: &str, p: Value, at: u64) -> Result<Value> {
    let owner = text(&p, "owner")?.to_owned();
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let mut lib = library(&tx, &owner)?;
    if method == "marble_control_read" {
        return output(&tx, &owner, &lib);
    }
    let host = text(&p, "hostSessionID")?.to_owned();
    let request_id = text(&p, "requestID")?.to_owned();
    let canonical = encoded(&json!({"method":method,"params":p}))?;
    if let Some((input, result)) = tx
        .query_row(
            "SELECT input,output FROM marble_control_commands WHERE owner=?1 AND request=?2",
            params![owner, request_id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?
    {
        if input != canonical {
            return Err("marble_control_receipt_conflict");
        }
        return decoded(result);
    }
    let mut extra = json!({});
    match method {
        "marble_control_command" => {
            expected(&p, &lib)?;
            let op = text(&p, "op")?;
            if op == "select" {
                let id = text(&p, "worldID")?;
                if !lib["worlds"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|w| w["id"] == id)
                {
                    return Err("marble_control_unknown_world");
                }
                lib["selectedWorldID"] = json!(id);
                save(&tx, &owner, &mut lib, None)?;
            } else if ["space.marble.resume", "space.marble.cancel"].contains(&op) {
                let id = text(&lib, "currentTaskID")?.to_owned();
                let mut t = task(&tx, &owner, &id)?;
                if op == "space.marble.cancel" {
                    if t["status"] == "completed" || t["status"] == "cancelled" {
                        return Err("marble_control_invalid_input");
                    }
                    t["cancelRequested"] = json!(true);
                    let a = current_action(&tx, &owner, &t)?;
                    t["status"] = json!(if t["operationID"].is_string() {
                        "cancelled_remote"
                    } else if a["status"] == "queued" {
                        "cancelled"
                    } else {
                        "unknown"
                    });
                    t["phase"] = json!(if t["status"] == "cancelled" {
                        "cancelled"
                    } else {
                        "cancelled_remote_operation_may_continue"
                    });
                } else {
                    if t["status"] == "unknown" {
                        return Err("marble_control_unknown_result");
                    }
                    let queued = current_action(&tx, &owner, &t)?;
                    let unsent = t["operationID"].is_null()
                        && queued["kind"] == "generate"
                        && queued["status"] == "queued";
                    if !unsent {
                        text(&t, "operationID")?;
                    }
                    t["hostSessionID"] = json!(host);
                    t["cancelRequested"] = json!(false);
                    t["errorCode"] = Value::Null;
                    t["deadlineMS"] = json!(at.saturating_add(POLL_INTERVAL * POLL_BUDGET));
                    t["pollAttempts"] = json!(0);
                    t["status"] = json!("pending");
                    t["phase"] = json!("generating");
                    if unsent {
                        let mut a = queued;
                        a["hostSessionID"] = json!(host);
                        a["dueAtMS"] = json!(at);
                        tx.execute("UPDATE marble_control_actions SET input=?4 WHERE owner=?1 AND task=?2 AND action=?3",params![owner,text(&t,"taskID")?,text(&a,"actionID")?,encoded(&a)?]).map_err(|_|"storage_unavailable")?;
                    } else {
                        polling(&tx, &owner, &mut t, at)?;
                    }
                }
                save(&tx, &owner, &mut lib, Some(&t))?;
            } else {
                if let Some(id) = lib["currentTaskID"].as_str() {
                    let prior = task(&tx, &owner, id)?;
                    if prior["status"] == "unknown"
                        || (!matches!(prior["status"].as_str(), Some("completed" | "cancelled"))
                            && (prior["operationID"].is_string()
                                || matches!(
                                    prior["status"].as_str(),
                                    Some("pending" | "inflight" | "resume_available")
                                )))
                    {
                        return Err("marble_control_busy");
                    }
                }
                let mut selected = None;
                if op == "activate_preset" {
                    let preset_id = text(&p, "presetID")?;
                    preset(preset_id)?;
                    let binding:Option<String>=tx.query_row("SELECT binding FROM marble_control_presets WHERE owner=?1 AND preset=?2",params![owner,preset_id],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
                    selected = binding
                        .map(decoded)
                        .transpose()?
                        .and_then(|v| v["worldID"].as_str().map(str::to_owned))
                        .or(catalog_preset(&lib, preset_id)?);
                }
                if let Some(id) = selected {
                    lib["selectedWorldID"] = json!(id);
                    save(&tx, &owner, &mut lib, None)?;
                } else {
                    let id = uuid::Uuid::new_v4().to_string();
                    let mut t = json!({"owner":owner,"taskID":id,"hostSessionID":host,"generation":1,"status":"pending","phase":"generating","presetID":p["presetID"],"operationID":null,"worldID":null,"world":null,"progress":null,"errorCode":null,"cancelRequested":false,"pollAttempts":0,"deadlineMS":at.saturating_add(POLL_INTERVAL*POLL_BUDGET)});
                    match op {
                        "space.marble.generate" | "activate_preset" => {
                            let body = preset(text(&p, "presetID")?)?;
                            action(
                                &tx,
                                &owner,
                                &mut t,
                                "generate",
                                Some("POST"),
                                Some("/marble/v1/worlds:generate".into()),
                                body,
                                at,
                            )?;
                        }
                        "space.marble.import" => {
                            let id = path_id(text(&p, "worldID")?)?;
                            t["presetID"] = Value::Null;
                            t["worldID"] = json!(id);
                            action(
                                &tx,
                                &owner,
                                &mut t,
                                "world",
                                Some("GET"),
                                Some(format!("/marble/v1/worlds/{id}")),
                                Value::Null,
                                at,
                            )?;
                        }
                        "refresh" => {
                            let size = p["pageSize"].as_u64().unwrap_or(50).clamp(1, 100);
                            t["presetID"] = Value::Null;
                            action(
                                &tx,
                                &owner,
                                &mut t,
                                "list",
                                Some("POST"),
                                Some("/marble/v1/worlds:list".into()),
                                json!({"page_size":size,"sort_by":"created_at","status":"SUCCEEDED"}),
                                at,
                            )?;
                            if lib["selectionImported"] != true {
                                lib["selectedWorldID"] = p["savedSelectedWorldID"].clone();
                                lib["selectionImported"] = json!(true);
                            }
                        }
                        _ => return Err("marble_control_invalid_input"),
                    }
                    lib["currentTaskID"] = json!(id);
                    save(&tx, &owner, &mut lib, Some(&t))?;
                }
            }
        }
        "marble_control_action_claim" => {
            expected(&p, &lib)?;
            let mut t = task(&tx, &owner, text(&p, "taskID")?)?;
            if lib["currentTaskID"] != t["taskID"] || t["hostSessionID"] != host {
                return Err("marble_control_stale_session");
            }
            if t["status"] != "pending" {
                return Err("marble_control_unknown_result");
            }
            let mut a = current_action(&tx, &owner, &t)?;
            if a["status"] != "queued" {
                return Err("marble_control_unknown_result");
            }
            let due = a["dueAtMS"].as_u64().ok_or("marble_control_corrupt")?;
            if a["kind"] == "operation"
                && (at >= t["deadlineMS"].as_u64().unwrap_or(0)
                    || t["pollAttempts"].as_u64().unwrap_or(0) >= POLL_BUDGET)
            {
                t["status"] = json!("failed");
                t["phase"] = json!("failed");
                t["errorCode"] = json!("marble_control_generation_timed_out");
                save(&tx, &owner, &mut lib, Some(&t))?;
            } else if due > at {
                // A not-due observation claims nothing. Journaling this clock-dependent
                // response would permanently fence the stable claim ID behind old waitMS.
                let mut result = output(&tx, &owner, &lib)?;
                result["action"] = Value::Null;
                result["waitMS"] = json!(due - at);
                tx.commit().map_err(|_| "storage_unavailable")?;
                return Ok(result);
            } else {
                if a["kind"] == "operation" {
                    t["pollAttempts"] = json!(t["pollAttempts"].as_u64().unwrap_or(0) + 1);
                }
                a["status"] = json!("inflight");
                t["status"] = json!("inflight");
                tx.execute("UPDATE marble_control_actions SET input=?4 WHERE owner=?1 AND task=?2 AND action=?3",params![owner,text(&t,"taskID")?,text(&a,"actionID")?,encoded(&a)?]).map_err(|_|"storage_unavailable")?;
                save(&tx, &owner, &mut lib, Some(&t))?;
                extra = json!({"action":a,"waitMS":0});
            }
        }
        "marble_control_action_receipt" => {
            let mut t = task(&tx, &owner, text(&p, "taskID")?)?;
            let id = text(&p, "actionID")?;
            let (raw,prior)=tx.query_row("SELECT input,receipt FROM marble_control_actions WHERE owner=?1 AND task=?2 AND action=?3",params![owner,text(&t,"taskID")?,id],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Option<String>>(1)?))).map_err(|_|"marble_control_unknown_action")?;
            let a = decoded(raw)?;
            if a["hostSessionID"] != host
                || a["generation"] != p["generation"]
                || a["taskID"] != p["taskID"]
            {
                return Err("marble_control_stale_session");
            }
            let fingerprint = encoded(&p["fact"])?;
            if let Some(prior) = prior {
                if prior != fingerprint {
                    return Err("marble_control_receipt_conflict");
                }
                extra = json!({"duplicate":true});
            } else {
                if a["status"] != "inflight" || t["actionID"] != p["actionID"] {
                    return Err("marble_control_unknown_result");
                }
                let original_task = t.clone();
                let original_library = lib.clone();
                tx.execute_batch("SAVEPOINT marble_receipt_decision")
                    .map_err(|_| "storage_unavailable")?;
                let result = (|| -> Result<()> {
                    if t["cancelRequested"] == true
                        && !["generate", "operation"].contains(&a["kind"].as_str().unwrap_or(""))
                    {
                        return Ok(());
                    }
                    match a["kind"].as_str().ok_or("marble_control_corrupt")? {
                        "generate" | "operation" => {
                            let value = http_body(&p["fact"])?;
                            operation(&tx, &owner, &mut t, &value, at)?;
                        }
                        "world" => {
                            let raw = http_body(&p["fact"])?;
                            let value = raw.get("world").unwrap_or(&raw);
                            let w = normalized_world(value)?;
                            if w["id"] != t["worldID"] {
                                return Err("marble_control_identity_mismatch");
                            }
                            if w["colliderURL"].is_null()
                                || w["splatFallbacks"].as_array().unwrap().is_empty()
                            {
                                return Err("marble_control_assets_missing");
                            }
                            t["world"] = w;
                            t["status"] = json!("pending");
                            t["phase"] = json!("downloading");
                            action(
                                &tx,
                                &owner,
                                &mut t,
                                "prepare_package",
                                None,
                                None,
                                Value::Null,
                                at,
                            )?;
                        }
                        "list" => {
                            let raw = http_body(&p["fact"])?;
                            let rows = raw["worlds"]
                                .as_array()
                                .filter(|r| r.len() <= 100)
                                .ok_or("marble_control_invalid_response")?;
                            let mut worlds = rows
                                .iter()
                                .map(normalized_world)
                                .collect::<Result<Vec<_>>>()?;
                            let mut ids = std::collections::HashSet::new();
                            for w in &worlds {
                                if !ids.insert(text(w, "id")?.to_owned()) {
                                    return Err("marble_control_invalid_response");
                                }
                            }
                            for w in public_worlds().as_array().unwrap() {
                                if ids.insert(text(w, "id")?.to_owned()) {
                                    worlds.push(w.clone());
                                }
                            }
                            lib["worlds"] = json!(worlds);
                            select_catalog(&mut lib)?;
                            t["status"] = json!("completed");
                            t["phase"] = json!("idle");
                        }
                        "prepare_package" => {
                            if let Some(code) = p["fact"]["preparationErrorCode"].as_str() {
                                if !["native_preparation_failed", "native_cancelled"]
                                    .contains(&code)
                                {
                                    return Err("marble_control_invalid_input");
                                }
                                t["status"] = json!("failed");
                                t["phase"] = json!("failed");
                                t["errorCode"] = json!("marble_control_package_preparation_failed");
                                return Ok(());
                            }
                            let binding = package(&tx, root, &t, &p["fact"], at)?;
                            if let Some(preset_id) = t["presetID"].as_str() {
                                tx.execute("INSERT INTO marble_control_presets VALUES(?1,?2,?3) ON CONFLICT(owner,preset) DO UPDATE SET binding=excluded.binding",params![owner,preset_id,encoded(&binding)?]).map_err(|_|"storage_unavailable")?;
                            }
                            let worlds = lib["worlds"].as_array_mut().unwrap();
                            worlds.retain(|w| w["id"] != t["worldID"]);
                            worlds.insert(0, t["world"].clone());
                            lib["selectedWorldID"] = t["worldID"].clone();
                            t["package"] = binding;
                            t["completedOperationID"] = t["operationID"].clone();
                            t["operationID"] = Value::Null;
                            t["status"] = json!("completed");
                            t["phase"] = json!("registered");
                        }
                        _ => return Err("marble_control_corrupt"),
                    }
                    Ok(())
                })();
                if let Err(code) = result {
                    tx.execute_batch(
                        "ROLLBACK TO marble_receipt_decision; RELEASE marble_receipt_decision",
                    )
                    .map_err(|_| "storage_unavailable")?;
                    t = original_task;
                    lib = original_library;
                    t["errorCode"] = json!(code);
                    let before_http = ["missing_api_key", "invalid_plan"]
                        .contains(&p["fact"]["transportErrorCode"].as_str().unwrap_or(""));
                    t["status"] = json!(if (a["kind"] == "generate" && !before_http)
                        || a["kind"] == "prepare_package"
                    {
                        "unknown"
                    } else {
                        "failed"
                    });
                    t["phase"] = json!("failed");
                    if a["kind"] == "list" {
                        // Preserve available catalog data and acknowledge only the local selection.
                        // The provider action remains failed; no successful refresh is fabricated.
                        select_catalog(&mut lib)?;
                    }
                } else {
                    tx.execute_batch("RELEASE marble_receipt_decision")
                        .map_err(|_| "storage_unavailable")?;
                }
                if t["cancelRequested"] == true {
                    t["status"] = json!(if t["operationID"].is_string() {
                        "cancelled_remote"
                    } else if a["kind"] == "generate"
                        && !["missing_api_key", "invalid_plan"]
                            .contains(&p["fact"]["transportErrorCode"].as_str().unwrap_or(""))
                    {
                        "unknown"
                    } else {
                        "cancelled"
                    });
                    t["phase"] = json!("cancelled_remote_operation_may_continue");
                }
                tx.execute("UPDATE marble_control_actions SET receipt=?4 WHERE owner=?1 AND task=?2 AND action=?3",params![owner,text(&t,"taskID")?,id,fingerprint]).map_err(|_|"storage_unavailable")?;
                save(&tx, &owner, &mut lib, Some(&t))?;
            }
        }
        _ => return Err("unknown_method"),
    }
    let mut result = output(&tx, &owner, &lib)?;
    result
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    tx.execute(
        "INSERT INTO marble_control_commands VALUES(?1,?2,?3,?4)",
        params![owner, request_id, canonical, encoded(&result)?],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        db: Connection,
        root: std::path::PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let parent = std::env::temp_dir()
                .canonicalize()
                .unwrap()
                .join(format!("gmgn-marble-{}", uuid::Uuid::new_v4()));
            let root = parent.join("TaskService");
            files::directory(&root).unwrap();
            let db = Connection::open(root.join("test.sqlite")).unwrap();
            schema(&db).unwrap();
            world::schema(&db).unwrap();
            Self { db, root }
        }
        fn call(&mut self, method: &str, p: Value, at: u64) -> Result<Value> {
            transition(&mut self.db, &self.root, method, p, at)
        }
        fn read(&mut self) -> Value {
            self.call("marble_control_read", json!({"owner":"test"}), 1)
                .unwrap()
        }
        fn command(&mut self, op: &str, id: &str, at: u64) -> Result<Value> {
            let revision = self.read()["revision"].clone();
            self.call("marble_control_command",json!({"owner":"test","hostSessionID":"actual-host","requestID":id,"expectedRevision":revision,"op":op,"presetID":"dj_house"}),at)
        }
        fn claim(&mut self, id: &str, at: u64) -> Value {
            let state = self.read();
            self.call("marble_control_action_claim",json!({"owner":"test","hostSessionID":"actual-host","requestID":id,"expectedRevision":state["revision"],"taskID":state["task"]["taskID"]}),at).unwrap()
        }
        fn receipt(&mut self, a: &Value, id: &str, fact: Value, at: u64) -> Result<Value> {
            self.call("marble_control_action_receipt",json!({"owner":"test","hostSessionID":a["hostSessionID"],"taskID":a["taskID"],"actionID":a["actionID"],"generation":a["generation"],"requestID":id,"fact":fact}),at)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(self.root.parent().unwrap());
        }
    }
    fn http(v: Value) -> Value {
        json!({"statusCode":200,"bodyBase64":base64::engine::general_purpose::STANDARD.encode(serde_json::to_vec(&v).unwrap())})
    }
    fn remote_world(id: &str) -> Value {
        json!({"world":{"world_id":id,"display_name":"exact world","assets":{"mesh":{"collider_mesh_url":"https://fixture.invalid/collider.glb"},"splats":{"spz_urls":{"100k":"https://fixture.invalid/small.spz","500k":"https://fixture.invalid/scene.spz"},"semantics_metadata":{"metric_scale_factor":2,"ground_plane_offset":0.3}}}}})
    }
    fn generate_done(f: &mut Fixture) -> Value {
        f.command("space.marble.generate", "start", 1000).unwrap();
        let a = f.claim("claim-generate", 1000)["action"].clone();
        f.receipt(&a,"generated",http(json!({"operation_id":"operation-exact","done":true,"response":{"world_id":"world-exact"}})),1000).unwrap();
        let a = f.claim("claim-world", 1000)["action"].clone();
        f.receipt(&a, "world-result", http(remote_world("world-exact")), 1000)
            .unwrap();
        f.claim("claim-package", 1000)["action"].clone()
    }
    fn physical_package(f: &Fixture) -> String {
        let dir = f
            .root
            .parent()
            .unwrap()
            .join("WorldPackages")
            .join(model::digest(b"world-exact"));
        files::directory(&dir).unwrap();
        let mut resources = vec![];
        for (id, path, bytes) in [
            (
                "environment.spz",
                "scene.spz",
                b"private-codec-output".as_slice(),
            ),
            (
                "environment.collider",
                "collider.glb",
                b"private-native-decoded-output".as_slice(),
            ),
            (
                "environment.marble",
                "marble-runtime.json",
                b"{}".as_slice(),
            ),
        ] {
            files::publish(&dir.join(path), bytes).unwrap();
            resources.push(json!({"id":id,"kind":id,"path":path,"sha256":model::digest(bytes)}));
        }
        let manifest = json!({"worldID":"world-exact","packageID":format!("marble-{}",model::digest(b"world-exact")),"packageVersion":"1.0.0","spawn":{"position":{"x":0,"y":0,"z":0},"rotation":{"x":0,"y":0,"z":0,"w":1},"scale":{"x":1,"y":1,"z":1}},"resources":resources});
        let bytes = serde_json::to_vec(&manifest).unwrap();
        files::publish(&dir.join("world.json"), &bytes).unwrap();
        model::digest(&bytes)
    }
    #[test]
    fn submission_is_recorded_before_dispatch_and_restart_unknown_never_resubmits() {
        let mut f = Fixture::new();
        let original = f.command("space.marble.generate", "start", 1000).unwrap();
        assert_eq!(original["task"]["status"], "pending");
        assert_eq!(
            f.db.query_row("SELECT count(*) FROM marble_control_actions", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        let claimed = f.claim("claimed", 1000);
        assert_eq!(claimed["action"]["status"], "inflight");
        recover(&f.db).unwrap();
        assert_eq!(f.read()["task"]["status"], "unknown");
        assert_eq!(
            f.command("space.marble.generate", "new-bill", 2000)
                .unwrap_err(),
            "marble_control_busy"
        );
        assert_eq!(
            f.command("space.marble.resume", "unsafe-resume", 2000)
                .unwrap_err(),
            "marble_control_unknown_result"
        );
        assert_eq!(
            f.db.query_row("SELECT count(*) FROM marble_control_actions", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            1
        );
        // An original raw receipt arriving late resolves uncertainty without another POST.
        let receipt = f
            .receipt(
                &claimed["action"],
                "late-http",
                http(json!({"operation_id":"operation-exact","done":false})),
                2000,
            )
            .unwrap();
        assert_eq!(receipt["task"]["operationID"], "operation-exact");
        assert_eq!(receipt["task"]["status"], "pending");
    }
    #[test]
    fn rust_poll_due_deadline_and_operation_identity() {
        let mut f = Fixture::new();
        f.command("space.marble.generate", "start", 1000).unwrap();
        let a = f.claim("submit", 1000)["action"].clone();
        f.receipt(
            &a,
            "submit-http",
            http(json!({"operation_id":"operation-exact","done":false})),
            1000,
        )
        .unwrap();
        let due = f.claim("early", 2000);
        assert!(due["action"].is_null());
        assert_eq!(due["waitMS"], 2000);
        let a = f.claim("poll", 4000)["action"].clone();
        assert_eq!(a["path"], "/marble/v1/operations/operation-exact");
        let r=f.receipt(&a,"wrong-op",http(json!({"operation_id":"other","done":true,"response":{"world_id":"world-exact"}})),4000).unwrap();
        assert_eq!(r["task"]["errorCode"], "marble_control_identity_mismatch");
        assert_eq!(r["task"]["operationID"], "operation-exact");
        f.command("space.marble.resume", "resume-known", 5000)
            .unwrap();
        let timeout = f.claim("deadline", 365000);
        assert_eq!(
            timeout["task"]["errorCode"],
            "marble_control_generation_timed_out"
        );
        assert!(timeout["action"].is_null());
    }
    #[test]
    fn same_stable_claim_id_observes_clock_until_due_then_journals_dispatch_once() {
        let mut f = Fixture::new();
        f.command("space.marble.generate", "start-clock", 1000)
            .unwrap();
        let a = f.claim("submit-clock", 1000)["action"].clone();
        f.receipt(
            &a,
            "submit-clock-http",
            http(json!({"operation_id":"operation-exact","done":false})),
            1000,
        )
        .unwrap();
        let early = f.claim("stable-clock-claim", 2000);
        assert!(early["action"].is_null());
        assert_eq!(early["waitMS"], 2000);
        assert_eq!(
            f.db.query_row(
                "SELECT count(*) FROM marble_control_commands WHERE request='stable-clock-claim'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            0
        );
        let later = f.claim("stable-clock-claim", 3000);
        assert!(later["action"].is_null());
        assert_eq!(later["waitMS"], 1000);
        assert_eq!(later["revision"], early["revision"]);
        let due = f.claim("stable-clock-claim", 4000);
        assert_eq!(due["action"]["status"], "inflight");
        assert_eq!(
            due["action"]["path"],
            "/marble/v1/operations/operation-exact"
        );
        assert_eq!(due["task"]["pollAttempts"], 1);
        let params = json!({"owner":"test","hostSessionID":"actual-host","requestID":"stable-clock-claim","taskID":due["task"]["taskID"],"expectedRevision":early["revision"]});
        let replay = f.call("marble_control_action_claim", params, 5000).unwrap();
        assert_eq!(replay, due);
        assert_eq!(f.read()["task"]["pollAttempts"], 1);
    }
    #[test]
    fn strict_receipt_identity_and_canonical_replay() {
        let mut f = Fixture::new();
        f.command("space.marble.generate", "start", 1000).unwrap();
        let a = f.claim("submit", 1000)["action"].clone();
        let fact = http(json!({"operation_id":"operation-exact","done":false}));
        let first = f.receipt(&a, "first", fact.clone(), 1000).unwrap();
        assert_eq!(f.receipt(&a, "first", fact.clone(), 1000).unwrap(), first);
        assert_eq!(
            f.receipt(&a, "other-request", fact.clone(), 2000).unwrap()["duplicate"],
            true
        );
        assert_eq!(
            f.receipt(
                &a,
                "changed",
                http(json!({"operation_id":"other","done":false})),
                2000
            )
            .unwrap_err(),
            "marble_control_receipt_conflict"
        );
        let mut wrong = a.clone();
        wrong["hostSessionID"] = json!("other-host");
        assert_eq!(
            f.receipt(&wrong, "foreign", fact, 2000).unwrap_err(),
            "marble_control_stale_session"
        );
    }
    #[test]
    fn cancellation_records_remote_uncertainty_and_never_registers() {
        let mut f = Fixture::new();
        f.command("space.marble.generate", "start", 1000).unwrap();
        let a = f.claim("submit", 1000)["action"].clone();
        let cancelled = f.command("space.marble.cancel", "cancel", 1000).unwrap();
        assert_eq!(cancelled["task"]["status"], "unknown");
        let r=f.receipt(&a,"late",http(json!({"operation_id":"operation-exact","done":true,"response":{"world_id":"world-exact"}})),2000).unwrap();
        assert_eq!(
            r["task"]["phase"],
            "cancelled_remote_operation_may_continue"
        );
        assert_eq!(r["task"]["operationID"], "operation-exact");
        assert_eq!(
            f.db.query_row("SELECT count(*) FROM world_records", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
    #[test]
    fn real_files_and_sql_registration_receipt_precede_completed_publish() {
        let mut f = Fixture::new();
        let a = generate_done(&mut f);
        assert_eq!(a["world"]["splatFallbacks"][0]["quality"], "500k");
        assert_eq!(a["world"]["semantics"]["metricScale"].as_f64(), Some(2.0));
        assert_eq!(f.read()["task"]["status"], "inflight");
        let digest = physical_package(&f);
        let r = f
            .receipt(&a, "registered", json!({"manifestSHA256":digest}), 2000)
            .unwrap();
        assert_eq!(r["task"]["status"], "completed");
        assert_eq!(r["task"]["phase"], "registered");
        assert!(r["task"]["operationID"].is_null());
        assert_eq!(r["presetWorldIDs"]["dj_house"], "world-exact");
        assert_eq!(r["presetPackages"]["dj_house"]["manifestSHA256"], digest);
        let before = world::materialize(&f.db, "world-exact").unwrap().unwrap();
        assert_eq!(before["worldTime"], 2000);
        recover(&f.db).unwrap();
        let duplicate = f
            .receipt(&a, "registered", json!({"manifestSHA256":digest}), 9999)
            .unwrap();
        assert_eq!(duplicate, r);
        assert_eq!(
            world::materialize(&f.db, "world-exact").unwrap().unwrap(),
            before
        );
    }
    #[test]
    fn wrong_world_and_modified_resource_are_not_completed() {
        let mut f = Fixture::new();
        f.command("space.marble.generate", "start", 1000).unwrap();
        let a = f.claim("submit", 1000)["action"].clone();
        f.receipt(&a,"generated",http(json!({"operation_id":"operation-exact","done":true,"response":{"world_id":"world-exact"}})),1000).unwrap();
        let a = f.claim("world", 1000)["action"].clone();
        let r = f
            .receipt(&a, "wrong-world", http(remote_world("wrong-world")), 1000)
            .unwrap();
        assert_eq!(r["task"]["errorCode"], "marble_control_identity_mismatch");
        assert_eq!(r["task"]["worldID"], "world-exact");
        let mut f = Fixture::new();
        let a = generate_done(&mut f);
        let digest = physical_package(&f);
        let path = f
            .root
            .parent()
            .unwrap()
            .join("WorldPackages")
            .join(model::digest(b"world-exact"))
            .join("scene.spz");
        files::publish(&path, b"changed").unwrap();
        let r = f
            .receipt(&a, "tampered", json!({"manifestSHA256":digest}), 2000)
            .unwrap();
        assert_eq!(r["task"]["status"], "unknown");
        assert_eq!(
            f.db.query_row("SELECT count(*) FROM world_records", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
    }
    #[test]
    fn empty_account_catalog_keeps_public_examples_and_sql_selection() {
        let mut f = Fixture::new();
        f.command("refresh", "refresh", 1000).unwrap();
        let a = f.claim("list", 1000)["action"].clone();
        let r = f
            .receipt(&a, "list-response", http(json!({"worlds":[]})), 1000)
            .unwrap();
        assert_eq!(r["worlds"].as_array().unwrap().len(), 5);
        assert_eq!(r["selectedWorldID"], "world-labs-example-elegant-library");
        let mut p = json!({"owner":"test","hostSessionID":"actual-host","requestID":"select","op":"select","worldID":"world-labs-example-modern-house","expectedRevision":r["revision"]});
        let selected = f.call("marble_control_command", p.clone(), 1000).unwrap();
        assert_eq!(selected["selectedWorldID"], p["worldID"]);
        p["requestID"] = json!("stale-select");
        assert_eq!(
            f.call("marble_control_command", p, 1000).unwrap_err(),
            "marble_control_revision_conflict"
        );
    }
    #[test]
    fn failed_account_refresh_selects_available_catalog_without_success_receipt() {
        let mut f = Fixture::new();
        f.command("refresh", "refresh-failure", 1000).unwrap();
        let a = f.claim("failed-list", 1000)["action"].clone();
        let r = f
            .receipt(
                &a,
                "unavailable",
                json!({"transportErrorCode":"missing_api_key"}),
                1000,
            )
            .unwrap();
        assert_eq!(r["task"]["status"], "failed");
        assert_eq!(r["worlds"].as_array().unwrap().len(), 5);
        assert_eq!(r["selectedWorldID"], "world-labs-example-elegant-library");
        let p = json!({"owner":"test","hostSessionID":"actual-host","requestID":"select-after-failure","op":"select","worldID":"world-labs-example-modern-house","expectedRevision":r["revision"]});
        f.call("marble_control_command", p, 1000).unwrap();
        f.command("refresh", "refresh-second", 1000).unwrap();
        let a = f.claim("failed-second-list", 1000)["action"].clone();
        let r = f
            .receipt(
                &a,
                "second-unavailable",
                json!({"transportErrorCode":"timeout"}),
                1000,
            )
            .unwrap();
        assert_eq!(r["selectedWorldID"], "world-labs-example-modern-house");
        assert_eq!(r["task"]["status"], "failed");
    }
}
