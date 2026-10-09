//! Presence selection policy and persistence. Native reports decoded catalog
//! resources and actual renderer receipts, never a proposed selection state.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

const ORB: &str = "builtin.orb";
const IDLE: &str = "builtin.motion.natural-idle";
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS presence_selection(scope TEXT PRIMARY KEY,revision INTEGER NOT NULL,catalog TEXT NOT NULL,state TEXT NOT NULL);CREATE TABLE IF NOT EXISTS presence_selection_requests(scope TEXT NOT NULL,request TEXT NOT NULL,digest TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(scope,request));").map_err(|_|"storage_unavailable")
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control))
        .ok_or("presence_invalid_input")
}
fn load(c: &Connection, scope: &str) -> Result<(i64, Value, Value)> {
    let row = c
        .query_row(
            "SELECT revision,catalog,state FROM presence_selection WHERE scope=?1",
            [scope],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                ))
            },
        )
        .optional()
        .map_err(|_| "storage_unavailable")?
        .ok_or("presence_catalog_unbound")?;
    Ok((
        row.0,
        serde_json::from_str(&row.1).map_err(|_| "presence_invalid_state")?,
        serde_json::from_str(&row.2).map_err(|_| "presence_invalid_state")?,
    ))
}
fn projection(revision: i64, catalog: &Value, state: &Value) -> Value {
    let mut result = state.clone();
    result["revision"] = json!(revision);
    result["engine"] =
        catalog["avatars"][state["avatarID"].as_str().unwrap_or(ORB)]["engine"].clone();
    result["policy"] = catalog["policy"].clone();
    result
}
fn compatible(policy: &str, engine: &str, format: &str) -> bool {
    match (engine, format) {
        (_, "procedural") => true,
        ("pmx", "vmd") => true,
        ("vrm", "vrma") => true,
        ("vrm", "vmd") => policy == "native",
        _ => false,
    }
}
fn available(catalog: &Value, id: &str) -> bool {
    let engine = catalog["avatars"][id]["engine"].as_str();
    catalog["avatars"][id]["rendererAvailable"] == true
        && engine.is_some_and(|engine| {
            catalog["supportedEngines"]
                .as_array()
                .is_some_and(|a| a.iter().any(|v| v.as_str() == Some(engine)))
        })
}
fn usable(catalog: &Value, avatar: &str, motion: &str) -> bool {
    compatible(
        catalog["policy"].as_str().unwrap_or("unity"),
        catalog["avatars"][avatar]["engine"]
            .as_str()
            .unwrap_or("orb"),
        catalog["motions"][motion]["format"]
            .as_str()
            .unwrap_or("missing"),
    )
}
fn effective(catalog: &Value, avatar: &str, motion: &str) -> Value {
    if motion != IDLE {
        return json!(motion);
    }
    let suffix = match catalog["avatars"][avatar]["engine"].as_str() {
        Some("pmx") => "pmx",
        Some("vrm") => "vrm",
        _ => return Value::Null,
    };
    let id = format!("gmgn.motion.bones.idle-loop-{suffix}");
    if usable(catalog, avatar, &id) && catalog["motions"][&id]["loop"] == true {
        json!(id)
    } else {
        Value::Null
    }
}
fn choose(catalog: &Value, state: &mut Value, avatar: &str, motion: &str) {
    state["avatarID"] = json!(avatar);
    state["motionID"] = json!(motion);
    state["effectiveMotionID"] = effective(catalog, avatar, motion);
    state["pendingRenderer"] = json!(true);
    state["rendererStatus"] = json!("loading");
    state["pendingPreference"] = Value::Null;
    if avatar == ORB {
        state["pendingRenderer"] = json!(false);
        state["rendererStatus"] = json!("not_required");
        state["confirmedAvatarID"] = json!(ORB);
        state["confirmedMotionID"] = json!(IDLE);
        state["confirmedEffectiveMotionID"] = Value::Null;
    }
}
fn validate_file(record: &Value, root: &Path, kind: &str) -> Result<()> {
    let id = text(record, "id")?;
    if (kind == "avatars" && id == ORB && record["engine"] == "orb")
        || (kind == "motions" && id == IDLE && record["format"] == "procedural")
    {
        return Ok(());
    }
    let path = PathBuf::from(text(record, "path")?);
    let actual = path
        .canonicalize()
        .map_err(|_| "presence_resource_missing")?;
    if !actual.is_file() {
        return Err("presence_resource_missing");
    }
    let extension = actual
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let format = record[if kind == "avatars" {
        "engine"
    } else {
        "format"
    }]
    .as_str()
    .ok_or("presence_invalid_catalog")?;
    if !matches!(
        (format, extension.as_str()),
        ("vrm", "vrm") | ("pmx", "pmx") | ("vrma", "vrma") | ("vmd", "vmd") | ("live2d", "json")
    ) {
        return Err("presence_invalid_catalog");
    }
    if !record["builtIn"].as_bool().unwrap_or(false) {
        let canonical_root = root
            .canonicalize()
            .map_err(|_| "presence_invalid_catalog")?;
        if !actual.starts_with(&canonical_root) {
            return Err("presence_resource_outside_root");
        }
        let manifest_path = canonical_root.join(id).join("manifest.json");
        let manifest: Value = serde_json::from_slice(
            &std::fs::read(manifest_path).map_err(|_| "presence_resource_missing")?,
        )
        .map_err(|_| "presence_invalid_catalog")?;
        if manifest["id"].as_str() != Some(id)
            || manifest[if kind == "avatars" {
                "engine"
            } else {
                "format"
            }]
            .as_str()
                != Some(format)
        {
            return Err("presence_catalog_identity_mismatch");
        }
        if kind == "motions"
            && record["loop"].as_bool() != Some(manifest["loop"].as_bool().unwrap_or(true))
        {
            return Err("presence_catalog_identity_mismatch");
        }
        let entry = text(&manifest, "entry")?;
        let expected = canonical_root
            .join(id)
            .join(entry)
            .canonicalize()
            .map_err(|_| "presence_resource_missing")?;
        if actual != expected {
            return Err("presence_catalog_identity_mismatch");
        }
    }
    Ok(())
}
fn catalog(p: &Value) -> Result<Value> {
    let policy = text(p, "policy")?;
    if !matches!(policy, "native" | "unity") {
        return Err("presence_invalid_catalog");
    }
    let scope = Path::new(text(p, "scope")?);
    if Path::new(text(p, "packageRoot")?).parent() != Some(scope)
        || Path::new(text(p, "motionRoot")?).parent() != Some(scope)
    {
        return Err("presence_invalid_catalog_scope");
    }
    let engines = p["supportedEngines"]
        .as_array()
        .filter(|v| v.len() <= 4)
        .ok_or("presence_invalid_catalog")?;
    if !engines
        .iter()
        .all(|v| matches!(v.as_str(), Some("orb" | "vrm" | "pmx" | "live2d")))
    {
        return Err("presence_invalid_catalog");
    }
    let mut result = json!({"policy":policy,"supportedEngines":engines,"avatars":{},"motions":{}});
    for (kind, key) in [("avatars", "packageRoot"), ("motions", "motionRoot")] {
        let root = Path::new(text(p, key)?);
        let records = p[kind]
            .as_array()
            .filter(|v| v.len() <= 4096)
            .ok_or("presence_invalid_catalog")?;
        for record in records {
            let id = text(record, "id")?;
            if id.len() > 256
                || id.contains('/')
                || id.contains('\\')
                || id == "."
                || id == ".."
                || !result[kind][id].is_null()
            {
                return Err("presence_invalid_catalog");
            }
            validate_file(record, root, kind)?;
            result[kind][id] = record.clone();
        }
    }
    if result["avatars"][ORB]["engine"] != "orb"
        || result["motions"][IDLE]["format"] != "procedural"
        || !available(&result, ORB)
    {
        return Err("presence_invalid_catalog");
    }
    result["packageRoot"] = p["packageRoot"].clone();
    result["motionRoot"] = p["motionRoot"].clone();
    Ok(result)
}
fn legacy_id(root: &str) -> Option<String> {
    let bytes = std::fs::read(Path::new(root).join(".selection.json")).ok()?;
    if bytes.len() > 16384 {
        return None;
    }
    let v: Value = serde_json::from_slice(&bytes).ok()?;
    v["activeID"].as_str().map(str::to_owned)
}
/// The exact record printed for a refused presence request: the method, the
/// authority's own code and the fields a host can actually check against
/// (`event`/`id`/`expectedRevision`). Without it a UI refusal reached the
/// person as an anonymous message and left no trace in this daemon's log
/// (2026-10-09 「选定动作」 report: nothing to read anywhere).
fn rejection_record(method: &str, p: &Value, code: &str) -> Value {
    json!({
        "event": "rejected",
        "code": code,
        "method": method,
        "scope": p["scope"].as_str().unwrap_or(""),
        "eventName": p["event"].as_str().unwrap_or(""),
        "id": p["id"].as_str().unwrap_or(""),
        "requestID": p["requestID"].as_str().unwrap_or(""),
        "expectedRevision": p["expectedRevision"].clone(),
    })
}
pub fn request(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let result = dispatch(c, method, p);
    if let Err(code) = &result {
        eprintln!("gmgn-taskd: {}", rejection_record(method, p, code));
    }
    result
}
fn dispatch(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    if !matches!(
        method,
        "presence_selection_read"
            | "presence_selection_bind_catalog"
            | "presence_selection_event"
            | "presence_selection_remove_intent"
            | "presence_selection_remove_claim"
            | "presence_selection_remove_receipt"
    ) {
        return Err("presence_invalid_input");
    }
    let scope = text(p, "scope")?;
    if method == "presence_selection_read" {
        let (r, cat, s) = load(c, scope)?;
        return Ok(projection(r, &cat, &s));
    }
    let request = text(p, "requestID")?;
    let digest = format!(
        "{:x}",
        Sha256::digest(
            crate::canonical_json::to_vec(&json!({"method":method,"params":p}))
                .map_err(|_| "presence_invalid_input")?
        )
    );
    let prior = c
        .query_row(
            "SELECT digest,response FROM presence_selection_requests WHERE scope=?1 AND request=?2",
            params![scope, request],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((old, response)) = prior {
        if old != digest {
            return Err("presence_request_conflict");
        }
        let mut result: Value =
            serde_json::from_str(&response).map_err(|_| "presence_invalid_state")?;
        if method == "presence_selection_remove_claim" {
            result["removal"]["execute"] = json!(false);
        }
        return Ok(result);
    }
    let (revision, cat, state) = if method == "presence_selection_bind_catalog" {
        let cat = catalog(p)?;
        match load(c, scope) {
            Ok((r, _, mut s)) => {
                if matches!(
                    s["removal"]["status"].as_str(),
                    Some("queued" | "inflight" | "unknown")
                ) {
                    return Err("presence_removal_pending");
                }
                let avatar = s["avatarID"]
                    .as_str()
                    .filter(|id| available(&cat, id))
                    .unwrap_or(ORB)
                    .to_owned();
                let motion = s["motionID"]
                    .as_str()
                    .filter(|id| usable(&cat, &avatar, id))
                    .unwrap_or(IDLE)
                    .to_owned();
                let expected = effective(&cat, &avatar, &motion);
                if s["avatarID"] != avatar
                    || s["motionID"] != motion
                    || s["effectiveMotionID"] != expected
                {
                    choose(&cat, &mut s, &avatar, &motion);
                }
                (r, cat, s)
            }
            Err("presence_catalog_unbound") => {
                let default_avatar = cat["avatars"]
                    .as_object()
                    .and_then(|a| {
                        a.iter()
                            .find(|(id, v)| {
                                *id != ORB && v["builtIn"] == true && available(&cat, id)
                            })
                            .map(|(id, _)| id.clone())
                    })
                    .unwrap_or_else(|| ORB.into());
                let avatar = legacy_id(text(p, "packageRoot")?)
                    .filter(|id| id != "builtin.vrm.arisu-maid" && available(&cat, id))
                    .unwrap_or(default_avatar);
                let motion = legacy_id(text(p, "motionRoot")?)
                    .filter(|id| {
                        !matches!(
                            id.as_str(),
                            "builtin.motion.studio-groove"
                                | "builtin.motion.2b-full"
                                | "builtin.motion.2b-hand"
                                | "builtin.motion.2b-hand-short"
                        ) && usable(&cat, &avatar, id)
                    })
                    .unwrap_or_else(|| IDLE.into());
                let mut s = json!({"avatarID":ORB,"motionID":IDLE,"effectiveMotionID":null,"confirmedAvatarID":ORB,"confirmedMotionID":IDLE,"confirmedEffectiveMotionID":null,"preferences":{},"pendingRenderer":false,"rendererStatus":"unverified"});
                for engine in ["vrm", "pmx"] {
                    if let Some(id) = p["legacyPreferences"][engine].as_str() {
                        if let Some(format) = cat["motions"][id]["format"].as_str() {
                            if compatible(cat["policy"].as_str().unwrap_or("unity"), engine, format)
                            {
                                s["preferences"][engine] = json!(id);
                            }
                        }
                    }
                }
                choose(&cat, &mut s, &avatar, &motion);
                (0, cat, s)
            }
            Err(e) => return Err(e),
        }
    } else {
        let (r, mut cat, mut s) = load(c, scope)?;
        if p["expectedRevision"].as_i64() != Some(r) {
            return Err("presence_revision_conflict");
        }
        if method.starts_with("presence_selection_remove_") {
            let session = text(p, "hostSessionID")?;
            match method {
                "presence_selection_remove_intent" => {
                    if matches!(
                        s["removal"]["status"].as_str(),
                        Some("queued" | "inflight" | "unknown")
                    ) {
                        return Err("presence_removal_pending");
                    }
                    let kind = text(p, "kind")?;
                    if !matches!(kind, "avatars" | "motions") {
                        return Err("presence_invalid_input");
                    }
                    let id = text(p, "id")?;
                    let record = &cat[kind][id];
                    if record.is_null() {
                        return Err("presence_resource_missing");
                    }
                    if record["builtIn"] != false {
                        return Err("presence_remove_builtin");
                    }
                    let root = Path::new(text(
                        &cat,
                        if kind == "avatars" {
                            "packageRoot"
                        } else {
                            "motionRoot"
                        },
                    )?);
                    validate_file(record, root, kind)?;
                    let path = root.join(id);
                    let canonical = path
                        .canonicalize()
                        .map_err(|_| "presence_resource_missing")?;
                    if canonical != path || !canonical.is_dir() {
                        return Err("presence_resource_outside_root");
                    }
                    s["removal"] = json!({"intentID":request,"hostSessionID":session,"kind":kind,"id":id,"path":path,"status":"queued","execute":false});
                }
                "presence_selection_remove_claim" | "presence_selection_remove_receipt" => {
                    if s["removal"]["hostSessionID"].as_str() != Some(session)
                        || s["removal"]["intentID"].as_str() != Some(text(p, "intentID")?)
                    {
                        return Err("presence_removal_identity_mismatch");
                    }
                    if method == "presence_selection_remove_claim" {
                        if s["removal"]["status"] != "queued" {
                            return Err("presence_removal_not_dispatchable");
                        }
                        s["removal"]["status"] = json!("inflight");
                        s["removal"]["execute"] = json!(false);
                    } else {
                        if !matches!(
                            s["removal"]["status"].as_str(),
                            Some("inflight" | "unknown")
                        ) {
                            return Err("presence_removal_receipt_stale");
                        }
                        let outcome = text(p, "outcome")?;
                        let path = Path::new(text(&s["removal"], "path")?);
                        let exists = match std::fs::symlink_metadata(path) {
                            Ok(_) => true,
                            Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
                            Err(_) => return Err("presence_removal_verification_failed"),
                        };
                        if (outcome == "removed" && exists) || (outcome == "failed" && !exists) {
                            return Err("presence_removal_verification_failed");
                        }
                        if !matches!(outcome, "removed" | "failed" | "unknown") {
                            return Err("presence_invalid_input");
                        }
                        if outcome == "removed" {
                            let kind = text(&s["removal"], "kind")?.to_owned();
                            let id = text(&s["removal"], "id")?.to_owned();
                            cat[&kind]
                                .as_object_mut()
                                .ok_or("presence_invalid_state")?
                                .remove(&id);
                            if let Some(preferences) = s["preferences"].as_object_mut() {
                                preferences.retain(|_, v| v != &id);
                            }
                            let avatar = s["avatarID"]
                                .as_str()
                                .filter(|id| available(&cat, id))
                                .unwrap_or(ORB)
                                .to_owned();
                            let motion = s["motionID"]
                                .as_str()
                                .filter(|id| usable(&cat, &avatar, id))
                                .unwrap_or(IDLE)
                                .to_owned();
                            if s["avatarID"] != avatar
                                || s["motionID"] != motion
                                || s["effectiveMotionID"] != effective(&cat, &avatar, &motion)
                            {
                                choose(&cat, &mut s, &avatar, &motion);
                            }
                        }
                        s["removal"]["status"] = json!(outcome);
                        s["removal"]["execute"] = json!(false);
                    }
                }
                _ => unreachable!(),
            }
        } else {
            if matches!(
                s["removal"]["status"].as_str(),
                Some("queued" | "inflight" | "unknown")
            ) {
                return Err("presence_removal_pending");
            }
            match text(p, "event")? {
                "renderer_ack" => {
                    if !s["pendingRenderer"].as_bool().unwrap_or(false) {
                        return Err("presence_renderer_receipt_stale");
                    }
                    let success = p["success"].as_bool().ok_or("presence_invalid_input")?;
                    if success {
                        s["confirmedAvatarID"] = s["avatarID"].clone();
                        s["confirmedMotionID"] = s["motionID"].clone();
                        s["confirmedEffectiveMotionID"] = s["effectiveMotionID"].clone();
                        if let (Some(engine), Some(id)) = (
                            s["pendingPreference"]["engine"].as_str(),
                            s["pendingPreference"]["id"].as_str(),
                        ) {
                            let engine = engine.to_owned();
                            let id = id.to_owned();
                            s["preferences"][engine] = json!(id);
                        }
                        s["rendererStatus"] = json!("ready");
                    } else {
                        let avatar = s["confirmedAvatarID"]
                            .as_str()
                            .filter(|id| available(&cat, id))
                            .unwrap_or(ORB)
                            .to_owned();
                        let motion = s["confirmedMotionID"]
                            .as_str()
                            .filter(|id| usable(&cat, &avatar, id))
                            .unwrap_or(IDLE)
                            .to_owned();
                        choose(&cat, &mut s, &avatar, &motion);
                        s["rendererStatus"] = json!("failed");
                    }
                    s["pendingRenderer"] = json!(false);
                    s["pendingPreference"] = Value::Null;
                }
                event => {
                    if s["pendingRenderer"] == true {
                        return Err("presence_renderer_pending");
                    }
                    let avatar = s["avatarID"].as_str().unwrap_or(ORB).to_owned();
                    match event {
                        "select_avatar" => {
                            let id = text(p, "id")?;
                            if !available(&cat, id) {
                                return Err("presence_avatar_unavailable");
                            }
                            let engine = cat["avatars"][id]["engine"].as_str().unwrap_or("orb");
                            let motion = if cat["policy"] == "native" {
                                s["preferences"][engine]
                                    .as_str()
                                    .filter(|m| usable(&cat, id, m))
                                    .unwrap_or(IDLE)
                            } else {
                                IDLE
                            }
                            .to_owned();
                            choose(&cat, &mut s, id, &motion);
                        }
                        "select_motion" => {
                            let id = text(p, "id")?;
                            if !usable(&cat, &avatar, id) {
                                return Err("presence_motion_incompatible");
                            }
                            let engine =
                                cat["avatars"][&avatar]["engine"].as_str().unwrap_or("orb");
                            choose(&cat, &mut s, &avatar, id);
                            s["pendingPreference"] = json!({"engine":engine,"id":id});
                        }
                        "motion_finished" | "stop_motion" => {
                            if event == "motion_finished"
                                && (s["effectiveMotionID"] != p["id"]
                                    || cat["motions"][p["id"].as_str().unwrap_or("")]["loop"]
                                        != false)
                            {
                                return Err("presence_motion_receipt_stale");
                            }
                            choose(&cat, &mut s, &avatar, IDLE);
                        }
                        _ => return Err("presence_invalid_event"),
                    }
                }
            }
        }
        (r, cat, s)
    };
    let unchanged = method == "presence_selection_bind_catalog"
        && load(c, scope).is_ok_and(|(_, old_cat, old_state)| old_cat == cat && old_state == state);
    let next = if unchanged {
        revision
    } else {
        revision.checked_add(1).ok_or("presence_invalid_state")?
    };
    let mut response = projection(next, &cat, &state);
    if method == "presence_selection_remove_claim" {
        response["removal"]["execute"] = json!(true);
    }
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    tx.execute("INSERT INTO presence_selection(scope,revision,catalog,state) VALUES(?1,?2,?3,?4) ON CONFLICT(scope) DO UPDATE SET revision=excluded.revision,catalog=excluded.catalog,state=excluded.state",params![scope,next,cat.to_string(),state.to_string()]).map_err(|_|"storage_unavailable")?;
    tx.execute("INSERT INTO presence_selection_requests(scope,request,digest,response) VALUES(?1,?2,?3,?4)",params![scope,request,digest,response.to_string()]).map_err(|_|"storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        c: Connection,
        root: PathBuf,
        bind: Value,
        next: u64,
    }
    impl Fixture {
        fn new(policy: &str) -> Self {
            let nonce = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root =
                std::env::temp_dir().join(format!("gmgn-presence-{nonce}-{}", std::process::id()));
            let packages = root.join("PresencePackages");
            let motions = root.join("MotionPackages");
            std::fs::create_dir_all(&packages).unwrap();
            std::fs::create_dir_all(&motions).unwrap();
            let root = root.canonicalize().unwrap();
            let packages = root.join("PresencePackages");
            let motions = root.join("MotionPackages");
            let mut avatars =
                vec![json!({"id":ORB,"engine":"orb","builtIn":true,"rendererAvailable":true})];
            for (id, engine) in [("test.pmx", "pmx"), ("test.vrm", "vrm")] {
                let dir = packages.join(id);
                std::fs::create_dir_all(&dir).unwrap();
                let entry = format!("model.{engine}");
                std::fs::write(dir.join(&entry), b"native-decoded resource fixture").unwrap();
                std::fs::write(
                    dir.join("manifest.json"),
                    json!({"id":id,"engine":engine,"entry":entry}).to_string(),
                )
                .unwrap();
                avatars.push(json!({"id":id,"engine":engine,"builtIn":false,"rendererAvailable":true,"path":dir.join(entry)}));
            }
            let mut clips =
                vec![json!({"id":IDLE,"format":"procedural","loop":true,"builtIn":true})];
            for (id, format, looped) in [
                ("test.vmd", "vmd", false),
                ("test.vrma", "vrma", true),
                ("gmgn.motion.bones.idle-loop-pmx", "vmd", true),
                ("gmgn.motion.bones.idle-loop-vrm", "vrma", true),
            ] {
                let dir = motions.join(id);
                std::fs::create_dir_all(&dir).unwrap();
                let entry = format!("clip.{format}");
                std::fs::write(dir.join(&entry), b"native-decoded clip fixture").unwrap();
                std::fs::write(
                    dir.join("manifest.json"),
                    json!({"id":id,"format":format,"entry":entry,"loop":looped}).to_string(),
                )
                .unwrap();
                clips.push(json!({"id":id,"format":format,"loop":looped,"builtIn":false,"path":dir.join(entry)}));
            }
            let c = Connection::open_in_memory().unwrap();
            schema(&c).unwrap();
            let bind = json!({"scope":root,"requestID":"bind-1","packageRoot":packages,"motionRoot":motions,"policy":policy,"supportedEngines":["orb","vrm","pmx"],"avatars":avatars,"motions":clips});
            Self {
                c,
                root,
                bind,
                next: 0,
            }
        }
        fn bind(&mut self) -> Value {
            request(&mut self.c, "presence_selection_bind_catalog", &self.bind).unwrap()
        }
        fn event(&mut self, event: &str, id: Option<&str>, success: Option<bool>) -> Result<Value> {
            self.next += 1;
            let before = request(
                &mut self.c,
                "presence_selection_read",
                &json!({"scope":self.root}),
            )?;
            let mut p = json!({"scope":self.root,"requestID":format!("event-{}",self.next),"expectedRevision":before["revision"],"event":event});
            if let Some(id) = id {
                p["id"] = json!(id);
            }
            if let Some(success) = success {
                p["success"] = json!(success);
            }
            request(&mut self.c, "presence_selection_event", &p)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    fn reverse_objects(value: &Value) -> Value {
        match value {
            Value::Object(map) => Value::Object(
                map.iter()
                    .rev()
                    .map(|(k, v)| (k.clone(), reverse_objects(v)))
                    .collect(),
            ),
            Value::Array(items) => Value::Array(items.iter().map(reverse_objects).collect()),
            _ => value.clone(),
        }
    }
    #[test]
    fn nested_key_order_replays_same_request_but_content_and_route_conflict() {
        let mut f = Fixture::new("native");
        let first = f.bind();
        let reordered = reverse_objects(&f.bind);
        assert_ne!(reordered.to_string(), f.bind.to_string());
        assert_eq!(
            request(&mut f.c, "presence_selection_bind_catalog", &reordered).unwrap(),
            first
        );
        let before: (i64, String, String) =
            f.c.query_row(
                "SELECT revision,catalog,state FROM presence_selection",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        let mut changed = reordered.clone();
        changed["avatars"][1]["rendererAvailable"] = json!(false);
        assert_eq!(
            request(&mut f.c, "presence_selection_bind_catalog", &changed).unwrap_err(),
            "presence_request_conflict"
        );
        assert_eq!(
            request(&mut f.c, "presence_selection_event", &reordered).unwrap_err(),
            "presence_request_conflict"
        );
        changed = reordered.clone();
        changed["avatars"].as_array_mut().unwrap().reverse();
        assert_eq!(
            request(&mut f.c, "presence_selection_bind_catalog", &changed).unwrap_err(),
            "presence_request_conflict"
        );
        let after: (i64, String, String) =
            f.c.query_row(
                "SELECT revision,catalog,state FROM presence_selection",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(before, after);
        let count: i64 =
            f.c.query_row(
                "SELECT count(*) FROM presence_selection_requests",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }
    fn removal(f: &mut Fixture, method: &str, extra: Value) -> Result<Value> {
        f.next += 1;
        let before = request(
            &mut f.c,
            "presence_selection_read",
            &json!({"scope":f.root}),
        )?;
        let mut p = json!({"scope":f.root,"requestID":format!("remove-{}",f.next),"expectedRevision":before["revision"],"hostSessionID":"host-a"});
        p.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        request(&mut f.c, method, &p)
    }
    #[test]
    fn removal_claim_once_actual_ack_and_active_avatar_fallback() {
        let mut f = Fixture::new("native");
        f.bind();
        f.event("select_avatar", Some("test.pmx"), None).unwrap();
        f.event("renderer_ack", None, Some(true)).unwrap();
        let q = removal(
            &mut f,
            "presence_selection_remove_intent",
            json!({"kind":"avatars","id":"test.pmx"}),
        )
        .unwrap();
        let intent = q["removal"]["intentID"].clone();
        let p = json!({"scope":f.root,"requestID":"claim-stable","expectedRevision":q["revision"],"hostSessionID":"host-a","intentID":intent});
        let claimed = request(&mut f.c, "presence_selection_remove_claim", &p).unwrap();
        assert_eq!(claimed["removal"]["execute"], true);
        assert_eq!(
            request(
                &mut f.c,
                "presence_selection_read",
                &json!({"scope":f.root})
            )
            .unwrap()["removal"]["execute"],
            false
        );
        assert_eq!(
            request(&mut f.c, "presence_selection_remove_receipt", &p).unwrap_err(),
            "presence_request_conflict"
        );
        assert_eq!(
            request(&mut f.c, "presence_selection_remove_claim", &p).unwrap()["removal"]["execute"],
            false
        );
        assert_eq!(
            removal(
                &mut f,
                "presence_selection_remove_receipt",
                json!({"intentID":intent,"outcome":"removed"})
            )
            .unwrap_err(),
            "presence_removal_verification_failed"
        );
        assert_eq!(
            removal(
                &mut f,
                "presence_selection_remove_receipt",
                json!({"intentID":intent,"hostSessionID":"host-b","outcome":"unknown"})
            )
            .unwrap_err(),
            "presence_removal_identity_mismatch"
        );
        std::fs::remove_dir_all(f.root.join("PresencePackages/test.pmx")).unwrap();
        let done = removal(
            &mut f,
            "presence_selection_remove_receipt",
            json!({"intentID":intent,"outcome":"removed"}),
        )
        .unwrap();
        assert_eq!(done["avatarID"], ORB);
        assert_eq!(done["confirmedAvatarID"], ORB);
        assert_eq!(
            load(&f.c, f.root.to_str().unwrap()).unwrap().1["avatars"]["test.pmx"],
            Value::Null
        );
    }
    #[test]
    fn motion_removal_clears_preference_values_and_unknown_blocks_replay() {
        let mut f = Fixture::new("native");
        f.bind();
        f.event("select_avatar", Some("test.pmx"), None).unwrap();
        f.event("renderer_ack", None, Some(true)).unwrap();
        f.event("select_motion", Some("test.vmd"), None).unwrap();
        f.event("renderer_ack", None, Some(true)).unwrap();
        let q = removal(
            &mut f,
            "presence_selection_remove_intent",
            json!({"kind":"motions","id":"test.vmd"}),
        )
        .unwrap();
        let id = q["removal"]["intentID"].clone();
        removal(
            &mut f,
            "presence_selection_remove_claim",
            json!({"intentID":id}),
        )
        .unwrap();
        removal(
            &mut f,
            "presence_selection_remove_receipt",
            json!({"intentID":id,"outcome":"unknown"}),
        )
        .unwrap();
        assert_eq!(
            removal(
                &mut f,
                "presence_selection_remove_claim",
                json!({"intentID":id})
            )
            .unwrap_err(),
            "presence_removal_not_dispatchable"
        );
        f.bind["requestID"] = json!("bind-while-unknown");
        assert_eq!(
            request(&mut f.c, "presence_selection_bind_catalog", &f.bind).unwrap_err(),
            "presence_removal_pending"
        );
        std::fs::remove_dir_all(f.root.join("MotionPackages/test.vmd")).unwrap();
        let done = removal(
            &mut f,
            "presence_selection_remove_receipt",
            json!({"intentID":id,"outcome":"removed"}),
        )
        .unwrap();
        assert_eq!(done["motionID"], IDLE);
        assert_eq!(done["avatarID"], "test.pmx");
        assert!(done["preferences"]["pmx"].is_null());
    }
    #[test]
    fn removal_builtin_and_replaced_symlink_are_rejected() {
        let mut f = Fixture::new("unity");
        f.bind();
        assert_eq!(
            removal(
                &mut f,
                "presence_selection_remove_intent",
                json!({"kind":"avatars","id":ORB})
            )
            .unwrap_err(),
            "presence_remove_builtin"
        );
        #[cfg(unix)]
        {
            let original = f.root.join("PresencePackages/test.pmx");
            let target = f.root.join("outside");
            std::fs::rename(&original, &target).unwrap();
            std::os::unix::fs::symlink(&target, &original).unwrap();
            assert_eq!(
                removal(
                    &mut f,
                    "presence_selection_remove_intent",
                    json!({"kind":"avatars","id":"test.pmx"})
                )
                .unwrap_err(),
                "presence_resource_outside_root"
            );
        }
    }
    #[test]
    fn raw_selection_requires_real_ack_and_failure_rolls_back() {
        let mut f = Fixture::new("unity");
        let first = f.bind();
        assert_eq!(first["avatarID"], ORB);
        let selected = f.event("select_avatar", Some("test.pmx"), None).unwrap();
        assert_eq!(
            selected["effectiveMotionID"],
            "gmgn.motion.bones.idle-loop-pmx"
        );
        assert_eq!(selected["confirmedAvatarID"], ORB);
        assert_eq!(selected["pendingRenderer"], true);
        assert_eq!(
            f.event("select_motion", Some("test.vmd"), None)
                .unwrap_err(),
            "presence_renderer_pending"
        );
        f.event("renderer_ack", None, Some(true)).unwrap();
        assert_eq!(
            f.event("select_motion", Some("test.vrma"), None)
                .unwrap_err(),
            "presence_motion_incompatible"
        );
        f.event("select_motion", Some("test.vmd"), None).unwrap();
        let failed = f.event("renderer_ack", None, Some(false)).unwrap();
        assert_eq!(failed["motionID"], IDLE);
        assert_eq!(failed["rendererStatus"], "failed");
        assert_eq!(
            f.event("renderer_ack", None, Some(true)).unwrap_err(),
            "presence_renderer_receipt_stale"
        );
    }
    /// A refused selection has to be readable from this daemon's own log: the
    /// method, the authority's code, and the motion the person clicked. The
    /// 2026-10-09 「选定动作」 report left nothing readable anywhere, so a
    /// refusal that names itself is what makes the next one diagnosable.
    #[test]
    fn a_refused_motion_selection_is_logged_with_its_code_and_motion() {
        let mut f = Fixture::new("unity");
        f.bind();
        f.event("select_avatar", Some("test.pmx"), None).unwrap();
        f.event("renderer_ack", None, Some(true)).unwrap();
        let before = request(
            &mut f.c,
            "presence_selection_read",
            &json!({"scope":f.root}),
        )
        .unwrap();
        // The exact request the Swift client builds for 选定动作.
        let p = json!({"scope":f.root,"requestID":"log-refusal","expectedRevision":before["revision"],
            "event":"select_motion","id":"test.vrma"});
        assert_eq!(
            request(&mut f.c, "presence_selection_event", &p).unwrap_err(),
            "presence_motion_incompatible"
        );
        let record = rejection_record("presence_selection_event", &p, "presence_motion_incompatible");
        assert_eq!(record["event"], "rejected");
        assert_eq!(record["method"], "presence_selection_event");
        assert_eq!(record["code"], "presence_motion_incompatible");
        assert_eq!(record["eventName"], "select_motion");
        assert_eq!(record["id"], "test.vrma");
        assert_eq!(record["requestID"], "log-refusal");
        assert_eq!(record["expectedRevision"], before["revision"]);
    }
    #[test]
    fn catalog_scope_path_identity_and_stale_revision_fail_closed() {
        let mut f = Fixture::new("unity");
        let first = f.bind();
        let stale = json!({"scope":f.root,"requestID":"stale","expectedRevision":0,"event":"select_avatar","id":"test.pmx"});
        assert_eq!(
            request(&mut f.c, "presence_selection_event", &stale).unwrap_err(),
            "presence_revision_conflict"
        );
        f.bind["requestID"] = json!("bind-2");
        let second = f.bind();
        assert_eq!(first["revision"], second["revision"]);
        f.bind["requestID"] = json!("bind-bad");
        f.bind["avatars"][1]["engine"] = json!("vrm");
        assert_eq!(
            request(&mut f.c, "presence_selection_bind_catalog", &f.bind).unwrap_err(),
            "presence_invalid_catalog"
        );
    }
    #[test]
    fn one_shot_finish_and_unity_engine_switch_choose_idle_in_rust() {
        let mut f = Fixture::new("unity");
        f.bind();
        f.event("select_avatar", Some("test.pmx"), None).unwrap();
        f.event("renderer_ack", None, Some(true)).unwrap();
        f.event("select_motion", Some("test.vmd"), None).unwrap();
        f.event("renderer_ack", None, Some(true)).unwrap();
        assert_eq!(
            f.event("motion_finished", Some("test.vrma"), None)
                .unwrap_err(),
            "presence_motion_receipt_stale"
        );
        let finished = f.event("motion_finished", Some("test.vmd"), None).unwrap();
        assert_eq!(finished["motionID"], IDLE);
        f.event("renderer_ack", None, Some(true)).unwrap();
        let vrm = f.event("select_avatar", Some("test.vrm"), None).unwrap();
        assert_eq!(vrm["motionID"], IDLE);
        assert_eq!(vrm["effectiveMotionID"], "gmgn.motion.bones.idle-loop-vrm");
    }
}
