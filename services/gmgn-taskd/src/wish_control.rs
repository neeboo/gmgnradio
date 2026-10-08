//! Wish persistence and lifecycle authority on the existing taskd connection.
//! Spatial eligibility remains a trusted-host gate during this migration.
use crate::{canonical_json, model::Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS wish_control_documents(owner TEXT PRIMARY KEY,session TEXT NOT NULL,revision INTEGER NOT NULL,payload TEXT NOT NULL,import_hash TEXT);")
        .map_err(|_| "storage_unavailable")
}
fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 256)
        .ok_or("wish_control_invalid_request")
}
fn encode(v: &Value) -> Result<String> {
    let s = canonical_json::to_string(v).map_err(|_| "wish_control_invalid_request")?;
    if s.len() > 12 * 1024 * 1024 {
        return Err("wish_control_invalid_request");
    }
    Ok(s)
}
fn validate(v: &Value) -> Result<()> {
    for key in ["authorizations", "jobs", "events"] {
        let rows = v[key].as_array().ok_or("wish_control_invalid_request")?;
        let mut ids = std::collections::HashSet::new();
        for row in rows {
            if !ids.insert(text(row, "id")?.to_lowercase()) {
                return Err("wish_control_invalid_request");
            }
        }
    }
    for key in ["pendingDrafts", "delegations"] {
        if let Some(rows) = v.get(key).filter(|v| !v.is_null()) {
            let rows = rows.as_array().ok_or("wish_control_invalid_request")?;
            let mut ids = std::collections::HashSet::new();
            for row in rows {
                if !ids.insert(text(row, "id")?.to_lowercase()) {
                    return Err("wish_control_invalid_request");
                }
            }
        }
    }
    Ok(())
}
fn validate_grant(v: &Value, job: &Value) -> Result<()> {
    let grant = text(job, "authorizationID")?;
    if v["jobs"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|j| {
            j["authorizationID"]
                .as_str()
                .is_some_and(|s| s.eq_ignore_ascii_case(grant))
        })
        .count()
        != 1
    {
        return Err("wish_control_unauthorized");
    }
    let auth = v["authorizations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|a| {
            a["id"]
                .as_str()
                .is_some_and(|id| id.eq_ignore_ascii_case(grant))
        })
        .ok_or("wish_control_unauthorized")?;
    if auth["worldID"] != job["worldID"] || auth["residentScope"] != job["residentScope"] {
        return Err("wish_control_wrong_scope");
    }
    if !auth["attachments"]
        .as_array()
        .is_some_and(|a| a.iter().any(|a| a["id"] == job["attachmentID"]))
    {
        return Err("wish_control_unauthorized");
    }
    Ok(())
}
fn find(rows: &Value, id: &str) -> Option<usize> {
    rows.as_array()?
        .iter()
        .position(|v| v["id"].as_str().is_some_and(|s| s.eq_ignore_ascii_case(id)))
}
// Foundation UUID encoding uses uppercase; UUID spelling is not a new identity.
// Non-UUID tokens and scope strings retain their exact comparison semantics.
fn uuid_value_equal(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::String(a), Value::String(b)) => {
            match (uuid::Uuid::parse_str(a), uuid::Uuid::parse_str(b)) {
                (Ok(a), Ok(b)) => a == b,
                _ => a == b,
            }
        }
        (Value::Array(a), Value::Array(b)) => {
            a.len() == b.len() && a.iter().zip(b).all(|(a, b)| uuid_value_equal(a, b))
        }
        _ => a == b,
    }
}
fn immutable_equal(key: &str, a: &Value, b: &Value) -> bool {
    if matches!(
        key,
        "id" | "wishID"
            | "authorityID"
            | "submittedJobID"
            | "authorizationID"
            | "attachmentID"
            | "requestID"
            | "objectID"
            | "jobID"
            | "continuationResumeAuthorizationIDs"
    ) {
        uuid_value_equal(a, b)
    } else {
        a == b
    }
}
fn receipt(revision: i64, archive: Value) -> Value {
    let pending: Vec<&Value> = optional_rows(&archive["events"])
        .iter()
        .filter(|e| e["acknowledged"] != true)
        .collect();
    let unpublished: Vec<&Value> = pending
        .iter()
        .copied()
        .filter(|e| e["forwardedToDaemon"] != true)
        .collect();
    let continuation: Vec<&Value> = pending
        .iter()
        .copied()
        .filter(|e| {
            let Some(job) = optional_rows(&archive["jobs"])
                .iter()
                .find(|j| uuid_value_equal(&j["id"], &e["wishID"]))
            else {
                return false;
            };
            if job["autoContinuationPaused"] == true {
                return false;
            }
            if job["worldID"] != e["worldID"] || job["residentScope"] != e["residentScope"] {
                return false;
            }
            if optional_rows(&archive["delegations"]).iter().any(|d| {
                uuid_value_equal(&d["authorizationID"], &job["authorizationID"])
                    && d["worldID"] == e["worldID"]
                    && d["residentScope"] == e["residentScope"]
                    && d["state"] == "placed"
            }) {
                return false;
            }
            let resumed = !e["continuationResumeAuthorizationID"].is_null();
            if resumed {
                let last = optional_rows(&job["continuationResumeAuthorizationIDs"])
                    .last()
                    .unwrap_or(&Value::Null);
                if !uuid_value_equal(last, &e["continuationResumeAuthorizationID"]) {
                    return false;
                }
            }
            resumed
                || matches!(e["kind"].as_str(), Some("failed" | "cancelled" | "interrupted" | "placed"))
                || (e["kind"] == "outputReady" && job["stage"] != "claimed")
        })
        .collect();
    let grants: Vec<&Value> = optional_rows(&archive["authorizations"])
        .iter()
        .filter(|a| {
            !optional_rows(&archive["jobs"])
                .iter()
                .any(|j| uuid_value_equal(&j["authorizationID"], &a["id"]))
        })
        .collect();
    json!({"revision":revision,"archive":archive,"views":{"pendingEvents":pending,"unpublishedEvents":unpublished,
        "continuationEvents":continuation,"availableAuthorizations":grants}})
}
fn scope(v: &Value, p: &Value) -> Result<()> {
    if v["worldID"] != p["worldID"] || v["residentScope"] != p["residentScope"] {
        return Err("wish_control_wrong_scope");
    }
    text(p, "worldID")?;
    text(p, "residentScope")?;
    Ok(())
}
fn output(db: &Connection, job: &Value) -> Result<()> {
    let id = text(job, "jobID")?;
    let raw: Option<String> = db
        .query_row(
            "SELECT data FROM jobs WHERE lower(id)=lower(?1)",
            [id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let stored: crate::model::Stored = serde_json::from_str(&raw.ok_or("wish_control_not_ready")?)
        .map_err(|_| "wish_control_not_ready")?;
    let core = stored.job;
    let context = core.context.ok_or("wish_control_wrong_scope")?;
    if Some(context.world_id.as_str()) != job["worldID"].as_str()
        || Some(context.resident_scope.as_str()) != job["residentScope"].as_str()
    {
        return Err("wish_control_wrong_scope");
    }
    if core.cancel_requested
        || core.receipt.as_ref().and_then(|r| r["state"].as_str()) != Some("completed")
    {
        return Err("wish_control_not_ready");
    }
    let path = core.local_model_path.ok_or("wish_control_not_ready")?;
    let database: String = db
        .query_row(
            "SELECT file FROM pragma_database_list WHERE name='main'",
            [],
            |r| r.get(0),
        )
        .map_err(|_| "storage_unavailable")?;
    let root = std::path::Path::new(&database)
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .ok_or("wish_control_not_ready")?;
    let expected = root.join(format!("{}.glb", core.id));
    if std::path::Path::new(&path) != expected || job["modelPath"].as_str() != Some(path.as_str()) {
        return Err("wish_control_not_ready");
    }
    let bytes = crate::files::read(&expected, crate::model::MODEL_LIMIT)
        .map_err(|_| "wish_control_not_ready")?;
    crate::model::validate_glb(
        &bytes,
        core.receipt.as_ref().ok_or("wish_control_not_ready")?,
    )
    .map_err(|_| "wish_control_not_ready")?;
    Ok(())
}
fn published(db: &Connection, event: &Value) -> Result<()> {
    let row: Option<(String,String)> = db.query_row("SELECT kind,payload FROM messages WHERE lower(id)=lower(?1) AND world_id=?2 AND resident_scope=?3",
        params![text(event,"id")?,text(event,"worldID")?,text(event,"residentScope")?], |r| Ok((r.get(0)?,r.get(1)?))).optional()
        .map_err(|_| "storage_unavailable")?;
    let (kind, raw) = row.ok_or("wish_control_not_published")?;
    let payload: Value = serde_json::from_str(&raw).map_err(|_| "wish_control_not_published")?;
    if kind != format!("wish.{}", text(event, "kind")?)
        || payload["object_id"] != event["objectID"]
        || !payload["wish_id"]
            .as_str()
            .zip(event["wishID"].as_str())
            .is_some_and(|(a, b)| a.eq_ignore_ascii_case(b))
    {
        return Err("wish_control_not_published");
    }
    Ok(())
}
fn claim_observation(db: &Connection, job: &Value, p: &Value) -> Result<()> {
    let e = &p["observation"];
    if e["worldID"] != job["worldID"]
        || e["objectID"] != job["objectID"]
        || e["outputAvailable"] != true
        || e["activityID"] != "wish_machine.collect"
        || e["phase"] != "loop"
        || !e["distanceMeters"]
            .as_f64()
            .is_some_and(|d| d.is_finite() && (0.0..=0.25).contains(&d))
    {
        return Err("wish_control_not_at_machine");
    }
    let world = text(job, "worldID")?;
    let raw: Option<String> = db
        .query_row(
            "SELECT payload FROM world_activity_runs WHERE world_id=?1",
            [world],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let state: Value = serde_json::from_str(&raw.ok_or("wish_control_not_at_machine")?)
        .map_err(|_| "wish_control_not_at_machine")?;
    let run = &state["run"];
    if run["status"] != "running"
        || run["definition"]["id"] != e["activityID"]
        || run["phase"] != e["phase"]
        || run["requestID"].as_str().is_none()
        || run["requestID"] != e["activityRequestID"]
        || run["generation"].as_u64().is_none()
        || run["generation"] != e["activityGeneration"]
        || run["phaseGeneration"].as_u64().is_none()
        || run["phaseGeneration"] != e["phaseGeneration"]
        || run["hostSessionID"].as_str().is_none()
        || run["hostSessionID"] != e["activityHostSessionID"]
        || state["hostSessionID"] != run["hostSessionID"]
    {
        return Err("wish_control_not_at_machine");
    }
    let raw:Option<String>=db.query_row("SELECT value FROM world_records WHERE world_id=?1 AND domain='worlds' AND key='state' AND tombstone=0",[world],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
    let snapshot: Value = serde_json::from_str(&raw.ok_or("wish_control_not_at_machine")?)
        .map_err(|_| "wish_control_not_at_machine")?;
    if snapshot["worldID"] != job["worldID"]
        || snapshot["activeActivity"]["activityID"] != e["activityID"]
        || snapshot["activeActivity"]["status"] != "running"
    {
        return Err("wish_control_not_at_machine");
    }
    let mut squared = 0.0;
    for axis in ["x", "y", "z"] {
        let a = snapshot["agentTransform"]["position"][axis]
            .as_f64()
            .filter(|n| n.is_finite())
            .ok_or("wish_control_not_at_machine")?;
        let b = run["target"][axis]
            .as_f64()
            .filter(|n| n.is_finite())
            .ok_or("wish_control_not_at_machine")?;
        squared += (a - b).powi(2);
    }
    if squared > 0.25_f64.powi(2) {
        return Err("wish_control_not_at_machine");
    }
    Ok(())
}
fn wall_time() -> Result<f64> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| "wish_control_invalid_request")?
        .as_secs_f64()
        - 978307200.0)
}
fn optional_rows(v: &Value) -> &[Value] {
    v.as_array().map(Vec::as_slice).unwrap_or(&[])
}
fn protected_rows_equal(a: &Value, b: &Value) -> bool {
    let a = optional_rows(a);
    let b = optional_rows(b);
    a.len() == b.len()
        && a.iter().zip(b).all(|(a, b)| {
            let (Some(a), Some(b)) = (a.as_object(), b.as_object()) else {
                return false;
            };
            a.keys().chain(b.keys()).all(|key| {
                immutable_equal(
                    key,
                    a.get(key).unwrap_or(&Value::Null),
                    b.get(key).unwrap_or(&Value::Null),
                )
            })
        })
}
fn valid_target(v: &Value) -> bool {
    text(v, "surfaceID").is_ok()
        && ["x", "y", "z"]
            .iter()
            .all(|k| v["position"][k].as_f64().is_some_and(f64::is_finite))
        && v["yaw"].as_f64().is_some_and(f64::is_finite)
}
fn targets_equal(a: &Value, b: &Value) -> bool {
    valid_target(a)
        && valid_target(b)
        && a["surfaceID"] == b["surfaceID"]
        && ["x", "y", "z"].iter().all(|k| {
            a["position"][k].as_f64().map(|n| n as f32)
                == b["position"][k].as_f64().map(|n| n as f32)
        })
        && a["yaw"].as_f64().map(|n| n as f32) == b["yaw"].as_f64().map(|n| n as f32)
}
fn surfaces(p: &Value) -> Result<Value> {
    let rows = p["allowedSurfaceIDs"]
        .as_array()
        .filter(|s| !s.is_empty() && s.len() <= 8)
        .ok_or("wish_control_invalid_request")?;
    let mut seen = std::collections::HashSet::new();
    for row in rows {
        let s = row
            .as_str()
            .filter(|s| !s.is_empty() && s.len() <= 256)
            .ok_or("wish_control_invalid_request")?;
        if !seen.insert(s) {
            return Err("wish_control_invalid_request");
        }
    }
    if !p["explicitTarget"].is_null()
        && (!valid_target(&p["explicitTarget"])
            || !rows.iter().any(|s| s == &p["explicitTarget"]["surfaceID"]))
    {
        return Err("wish_control_invalid_request");
    }
    Ok(json!(rows))
}
fn scoped_delegation(archive: &Value, p: &Value) -> Result<usize> {
    text(p, "objectID")?;
    text(p, "worldID")?;
    text(p, "residentScope")?;
    optional_rows(&archive["delegations"])
        .iter()
        .position(|d| scope(d, p).is_ok() && d["objectID"] == p["objectID"])
        .ok_or("wish_control_unauthorized")
}
fn emit_placement(archive: &mut Value, job: &Value) {
    if optional_rows(&archive["events"]).iter().any(|e| {
        uuid_value_equal(&e["wishID"], &job["id"])
            && e["kind"] == "placed"
            && e["failureSource"].is_null()
    }) {
        return;
    }
    archive["events"].as_array_mut().unwrap().push(json!({"id":uuid::Uuid::new_v4().to_string(),
        "wishID":job["id"],"worldID":job["worldID"],"residentScope":job["residentScope"],"objectID":job["objectID"],
        "kind":"placed","computeMayContinue":job["computeMayContinue"].as_bool().unwrap_or(false),
        "acknowledged":false,"stage":job["stage"],"remoteState":job["remoteState"],"message":job["lastError"],"cancelRequested":job["cancelRequested"]}));
}
fn emit(archive: &mut Value, index: usize, kind: &str) {
    let job = archive["jobs"][index].clone();
    if optional_rows(&archive["events"]).iter().any(|e| {
        uuid_value_equal(&e["wishID"], &job["id"])
            && e["kind"] == kind
            && e["failureSource"].is_null()
            && (kind != "stateChanged"
                || e["stage"] == job["stage"]
                    && e["remoteState"] == job["remoteState"]
                    && e["message"] == job["lastError"]
                    && e["cancelRequested"] == job["cancelRequested"])
    }) {
        return;
    }
    let mut event = json!({"id":uuid::Uuid::new_v4().to_string(),"wishID":job["id"],"worldID":job["worldID"],
        "residentScope":job["residentScope"],"objectID":job["objectID"],"kind":kind,
        "computeMayContinue":job["computeMayContinue"].as_bool().unwrap_or(false),"acknowledged":false,"stage":job["stage"]});
    for (output, input) in [
        ("remoteState", "remoteState"),
        ("message", "lastError"),
        ("cancelRequested", "cancelRequested"),
    ] {
        if let Some(v) = job.get(input).filter(|v| !v.is_null()) {
            event[output] = v.clone();
        }
    }
    archive["events"].as_array_mut().unwrap().push(event);
}
fn file_attachment(a: &Value) -> bool {
    text(a, "id").is_ok()
        && a["displayName"].is_string()
        && a["url"]
            .as_str()
            .and_then(|s| reqwest::Url::parse(s).ok())
            .is_some_and(|u| u.scheme() == "file")
}
fn authorize_images(archive: &mut Value, p: &Value, attachments: Value) -> Result<Value> {
    serde_json::from_value::<crate::model::Source>(p["source"].clone())
        .map_err(|_| "wish_control_invalid_request")?;
    text(p, "worldID")?;
    text(p, "residentScope")?;
    let id = text(p, "authorizationID")?;
    let rows = attachments
        .as_array()
        .filter(|a| !a.is_empty() && a.len() <= 4)
        .ok_or("wish_control_unknown_attachment")?;
    let mut ids = std::collections::HashSet::new();
    if rows
        .iter()
        .any(|a| !file_attachment(a) || !ids.insert(a["id"].as_str().unwrap_or("").to_lowercase()))
    {
        return Err("wish_control_unknown_attachment");
    }
    if let Some(i) = find(&archive["authorizations"], id) {
        let a = &archive["authorizations"][i];
        if scope(a, p).is_err()
            || !protected_rows_equal(&a["attachments"], &attachments)
            || a["source"] != p["source"]
        {
            return Err("wish_control_conflicting_call");
        }
        return Ok(a.clone());
    }
    let a = json!({"id":p["authorizationID"],"worldID":p["worldID"],"residentScope":p["residentScope"],"attachments":attachments,"source":p["source"]});
    archive["authorizations"]
        .as_array_mut()
        .unwrap()
        .push(a.clone());
    Ok(a)
}
fn submission_material(archive: &Value, job: &Value) -> Result<Value> {
    let i = find(&archive["authorizations"], text(job, "authorizationID")?)
        .ok_or("wish_control_unauthorized")?;
    let a = &archive["authorizations"][i];
    if a["worldID"] != job["worldID"] || a["residentScope"] != job["residentScope"] {
        return Err("wish_control_wrong_scope");
    }
    let image = optional_rows(&a["attachments"])
        .iter()
        .find(|a| uuid_value_equal(&a["id"], &job["attachmentID"]))
        .ok_or("wish_control_unknown_attachment")?;
    let source = optional_rows(&archive["webReferences"])
        .iter()
        .find(|a| uuid_value_equal(&a["attachmentID"], &job["attachmentID"]))
        .map(|v| v["source"].clone())
        .unwrap_or_else(|| a["source"].clone());
    Ok(json!({"job":job,"imageURL":image["url"],"source":source}))
}
fn core_job(db: &Connection, job: &Value) -> Result<Option<crate::model::Job>> {
    let Some(id) = job["jobID"].as_str() else {
        return Ok(None);
    };
    let raw: Option<String> = db
        .query_row(
            "SELECT data FROM jobs WHERE lower(id)=lower(?1)",
            [id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let Some(raw) = raw else { return Ok(None) };
    let stored: crate::model::Stored =
        serde_json::from_str(&raw).map_err(|_| "wish_control_invalid_request")?;
    if !stored.job.context.as_ref().is_some_and(|c| {
        Some(c.world_id.as_str()) == job["worldID"].as_str()
            && Some(c.resident_scope.as_str()) == job["residentScope"].as_str()
    }) {
        return Err("wish_control_wrong_scope");
    }
    Ok(Some(stored.job))
}
fn observe_job(
    db: &Connection,
    archive: &mut Value,
    index: usize,
    preparation_error: Option<&str>,
) -> Result<()> {
    if archive["jobs"][index]["stage"] == "claimed" {
        return Ok(());
    }
    let Some(core) = core_job(db, &archive["jobs"][index])? else {
        if let Some(error) = preparation_error {
            archive["jobs"][index]["stage"] = json!("submissionUncertain");
            archive["jobs"][index]["lastError"] = json!(error);
            emit(archive, index, "stateChanged");
        }
        return Ok(());
    };
    let remote = core.receipt.as_ref().and_then(|r| r["state"].as_str());
    let j = &mut archive["jobs"][index];
    j["daemonAccepted"] = json!(true);
    j["lastError"] = json!(core.last_error);
    if core.cancel_requested {
        j["cancelRequested"] = json!(true)
    }
    j["remoteState"] = json!(remote);
    j["computeMayContinue"] = json!(core
        .receipt
        .as_ref()
        .and_then(|r| r["compute_may_continue"].as_bool())
        .unwrap_or(j["cancelRequested"] == true && core.backend_stage != "cancelled"));
    let terminal = match core.backend_stage.as_str() {
        "cancelled" => Some("cancelled"),
        "interrupted" => Some("interrupted"),
        "failed" if remote != Some("completed") => Some("failed"),
        _ => None,
    };
    if let Some(kind) = terminal {
        j["stage"] = json!(kind);
        emit(archive, index, kind);
        return Ok(());
    }
    if core.receipt.is_none() {
        j["stage"] = json!(if [
            "queued",
            "submitting",
            "awaiting_configuration",
            "cancel_requested"
        ]
        .contains(&core.backend_stage.as_str())
        {
            "submitting"
        } else {
            "submissionUncertain"
        });
        if core.backend_stage == "awaiting_configuration" && j["lastError"].is_null() {
            j["lastError"] = json!("后台等待服务配置。");
        }
        emit(archive, index, "stateChanged");
        return Ok(());
    }
    match remote {
        Some("completed") => {
            if j["stage"] != "ready" {
                j["stage"] = json!("generated")
            }
            emit(archive, index, "generationCompleted");
            if core.backend_stage == "ready" {
                let prior_path = archive["jobs"][index]["modelPath"].clone();
                if let Some(path) = core.local_model_path {
                    archive["jobs"][index]["modelPath"] = json!(path);
                    if output(db, &archive["jobs"][index]).is_ok() {
                        archive["jobs"][index]["stage"] = json!("ready");
                        archive["jobs"][index]["lastError"] = Value::Null;
                        emit(archive, index, "outputReady");
                    } else {
                        archive["jobs"][index]["modelPath"] = prior_path;
                        archive["jobs"][index]["stage"] = json!("generated");
                    }
                }
            }
        }
        Some(kind @ ("failed" | "cancelled" | "interrupted")) => {
            archive["jobs"][index]["stage"] = json!(kind);
            emit(archive, index, kind);
        }
        _ => archive["jobs"][index]["stage"] = json!("generating"),
    }
    emit(archive, index, "stateChanged");
    Ok(())
}
fn renderer_command(db: &Connection, archive: &mut Value, p: &Value) -> Result<Value> {
    match text(p, "command")? {
        "renderer_failure" | "renderer_clear" => {
            let index =
                find(&archive["jobs"], text(p, "wishID")?).ok_or("wish_control_wrong_scope")?;
            let job = archive["jobs"][index].clone();
            scope(&job, p)?;
            let old = optional_rows(&archive["events"]).iter().position(|e| {
                uuid_value_equal(&e["wishID"], &job["id"])
                    && e["failureSource"] == "renderer"
                    && e["kind"] == "failed"
            });
            if p["command"] == "renderer_clear" {
                if let Some(index) = old {
                    archive["events"].as_array_mut().unwrap().remove(index);
                    return Ok(json!(true));
                }
                return Ok(json!(false));
            }
            if job["stage"] != "ready" {
                return Err("wish_control_not_ready");
            }
            output(db, &job)?;
            let message = format!(
                "成品场景加载失败：{}",
                p["message"]
                    .as_str()
                    .ok_or("wish_control_invalid_request")?
            );
            if let Some(index) = old {
                let event = &mut archive["events"][index];
                event["message"] = json!(message);
                event["stage"] = job["stage"].clone();
                event["remoteState"] = job["remoteState"].clone();
                event["cancelRequested"] = job["cancelRequested"].clone();
            } else {
                archive["events"].as_array_mut().unwrap().push(json!({"id":uuid::Uuid::new_v4().to_string(),
                    "wishID":job["id"],"worldID":job["worldID"],"residentScope":job["residentScope"],"objectID":job["objectID"],
                    "kind":"failed","computeMayContinue":job["computeMayContinue"].as_bool().unwrap_or(false),"acknowledged":false,
                    "stage":job["stage"],"remoteState":job["remoteState"],"message":message,"cancelRequested":job["cancelRequested"],"failureSource":"renderer"}));
            }
            Ok(Value::Null)
        }
        _ => Err("wish_control_invalid_request"),
    }
}
fn command(archive: &mut Value, p: &Value, now: f64) -> Result<Value> {
    match text(p, "command")? {
        "draft_record" => {
            for k in [
                "id",
                "authorityID",
                "requestID",
                "attachmentID",
                "worldID",
                "residentScope",
            ] {
                text(p, k)?;
            }
            p["name"].as_str().ok_or("wish_control_invalid_request")?;
            let needs = p["needs"]
                .as_array()
                .ok_or("wish_control_invalid_request")?;
            if needs.iter().any(|v| !v.is_string()) {
                return Err("wish_control_invalid_request");
            }
            if !archive["pendingDrafts"].is_array() {
                archive["pendingDrafts"] = json!([]);
            }
            let rows = archive["pendingDrafts"].as_array_mut().unwrap();
            rows.retain(|d| d["createdAt"].as_f64().is_some_and(|t| now - t <= 86400.0));
            if let Some(d) = rows.iter_mut().find(|d| {
                uuid_value_equal(&d["id"], &p["id"])
                    || uuid_value_equal(&d["authorityID"], &p["authorityID"])
                        && d["requestID"] == p["requestID"]
            }) {
                scope(d, p)?;
                d["needs"] = json!(needs);
                d["attempt"] = json!(d["attempt"]
                    .as_u64()
                    .ok_or("wish_control_invalid_request")?
                    .checked_add(1)
                    .ok_or("wish_control_invalid_request")?);
                return Ok(d.clone());
            }
            let mut draft = json!({"id":p["id"],"authorityID":p["authorityID"],"requestID":p["requestID"],"attachmentID":p["attachmentID"],
                "name":p["name"],"worldID":p["worldID"],"residentScope":p["residentScope"],"createdAt":now,"needs":needs,"attempt":1});
            for k in ["destinationSurfaceIDs", "destinationTarget"] {
                if let Some(v) = p.get(k) {
                    draft[k] = v.clone();
                }
            }
            rows.push(draft.clone());
            Ok(draft)
        }
        "draft_list" | "draft_resolve" => {
            text(p, "worldID")?;
            text(p, "residentScope")?;
            let drafts: Vec<Value> = optional_rows(&archive["pendingDrafts"])
                .iter()
                .filter(|d| {
                    scope(d, p).is_ok()
                        && d["createdAt"].as_f64().is_some_and(|t| now - t <= 86400.0)
                })
                .cloned()
                .collect();
            if p["command"] == "draft_list" {
                return Ok(json!(drafts));
            }
            text(p, "attachmentID")?;
            p["name"].as_str().ok_or("wish_control_invalid_request")?;
            if drafts.is_empty() {
                return Ok(json!({"resolution":"fresh"}));
            }
            if let Some(id) = p["pendingID"].as_str() {
                let matched = drafts.iter().find(|d| {
                    d["id"].as_str().is_some_and(|v| v.eq_ignore_ascii_case(id))
                        && uuid_value_equal(&d["attachmentID"], &p["attachmentID"])
                        && d["name"] == p["name"]
                });
                return Ok(match matched {
                    Some(d) => json!({"resolution":"resume","draft":d}),
                    None => json!({"resolution":"ambiguous","drafts":drafts}),
                });
            }
            let matches: Vec<&Value> = drafts
                .iter()
                .filter(|d| {
                    uuid_value_equal(&d["attachmentID"], &p["attachmentID"])
                        && d["name"] == p["name"]
                        && d["submittedJobID"].is_null()
                })
                .collect();
            Ok(match matches.len() {
                0 => json!({"resolution":"fresh"}),
                1 => json!({"resolution":"resume","draft":matches[0]}),
                _ => json!({"resolution":"ambiguous","drafts":matches}),
            })
        }
        "draft_submit" => {
            let id = text(p, "id")?;
            let job_id = text(p, "jobID")?;
            let Some(index) = find(&archive["pendingDrafts"], id) else {
                return Ok(Value::Null);
            };
            let job = optional_rows(&archive["jobs"])
                .iter()
                .find(|j| {
                    j["id"]
                        .as_str()
                        .is_some_and(|v| v.eq_ignore_ascii_case(job_id))
                })
                .ok_or("wish_control_unauthorized")?;
            let draft = &archive["pendingDrafts"][index];
            if !uuid_value_equal(&job["authorizationID"], &draft["authorityID"])
                || !uuid_value_equal(&job["attachmentID"], &draft["attachmentID"])
                || job["worldID"] != draft["worldID"]
                || job["residentScope"] != draft["residentScope"]
            {
                return Err("wish_control_unauthorized");
            }
            if !draft["submittedJobID"].is_null()
                && !uuid_value_equal(&draft["submittedJobID"], &p["jobID"])
            {
                return Err("wish_control_conflicting_call");
            }
            archive["pendingDrafts"][index]["submittedJobID"] = p["jobID"].clone();
            Ok(archive["pendingDrafts"][index].clone())
        }
        "delegation_authorize" => {
            let authorization = text(p, "authorizationID")?;
            let grant = find(&archive["authorizations"], authorization)
                .ok_or("wish_control_unauthorized")?;
            scope(&archive["authorizations"][grant], p)?;
            let allowed = surfaces(p)?;
            if let Some(d) = optional_rows(&archive["delegations"])
                .iter()
                .find(|d| uuid_value_equal(&d["authorizationID"], &p["authorizationID"]))
            {
                if d["allowedSurfaceIDs"] != allowed || d["explicitTarget"] != p["explicitTarget"] {
                    return Err("wish_control_conflicting_call");
                }
                return Ok(d.clone());
            }
            if !archive["delegations"].is_array() {
                archive["delegations"] = json!([]);
            }
            let d = json!({"id":uuid::Uuid::new_v4().to_string(),"authorizationID":p["authorizationID"],"requestID":format!("placement.{}",uuid::Uuid::new_v4()),
                "worldID":p["worldID"],"residentScope":p["residentScope"],"allowedSurfaceIDs":allowed,"explicitTarget":p["explicitTarget"],"state":"awaitingSubmission"});
            archive["delegations"]
                .as_array_mut()
                .unwrap()
                .push(d.clone());
            Ok(d)
        }
        "delegation_resolve" | "delegation_complete" => {
            let index = scoped_delegation(archive, p)?;
            let d = &archive["delegations"][index];
            if d["state"] == "revoked" {
                return Err("wish_control_placement_revoked");
            }
            if p["command"] == "delegation_complete" && d["state"] == "placed" {
                if d["requestID"] != p["requestID"] {
                    return Err("wish_control_unauthorized");
                }
                return Ok(d.clone());
            }
            if d["state"] != "pending" {
                return Err("wish_control_unauthorized");
            }
            let job = optional_rows(&archive["jobs"])
                .iter()
                .find(|j| {
                    scope(j, p).is_ok() && j["objectID"] == p["objectID"] && j["stage"] == "claimed"
                })
                .cloned()
                .ok_or("wish_control_unauthorized")?;
            let surface = text(p, "surfaceID")?;
            if !optional_rows(&d["allowedSurfaceIDs"])
                .iter()
                .any(|v| v == surface)
                || !valid_target(&p["target"])
                || p["target"]["surfaceID"] != surface
            {
                return Err("wish_control_conflicting_call");
            }
            if !d["explicitTarget"].is_null() && !targets_equal(&d["explicitTarget"], &p["target"])
            {
                return Err("wish_control_conflicting_call");
            }
            if p["command"] == "delegation_complete" {
                if d["requestID"] != p["requestID"] {
                    return Err("wish_control_unauthorized");
                }
                if d["explicitTarget"].is_null() && !targets_equal(&d["boundTarget"], &p["target"])
                {
                    return Err("wish_control_conflicting_call");
                }
                archive["delegations"][index]["state"] = json!("placed");
                archive["delegations"][index]
                    .as_object_mut()
                    .unwrap()
                    .remove("lastError");
                emit_placement(archive, &job);
            } else if d["explicitTarget"].is_null() {
                archive["delegations"][index]["boundTarget"] = p["target"].clone();
            }
            Ok(archive["delegations"][index].clone())
        }
        "delegation_fail" => {
            let index = scoped_delegation(archive, p)?;
            if archive["delegations"][index]["state"] == "pending" {
                archive["delegations"][index]["state"] = json!("failed");
                archive["delegations"][index]["lastError"] =
                    json!(p["reason"].as_str().ok_or("wish_control_invalid_request")?);
            }
            Ok(archive["delegations"][index].clone())
        }
        "delegation_revoke" => {
            text(p, "worldID")?;
            text(p, "residentScope")?;
            if let Some(rows) = archive.get_mut("delegations").and_then(Value::as_array_mut) {
                for d in rows {
                    if scope(d, p).is_ok() && d["state"] == "pending" {
                        d["state"] = json!("revoked");
                    }
                }
            }
            Ok(Value::Null)
        }
        _ => Err("wish_control_invalid_request"),
    }
}
fn runtime_command(db: &Connection, archive: &mut Value, p: &Value, now: f64) -> Result<Value> {
    match text(p, "command")? {
        "confirmation_prepare" => {
            let indexes: Vec<usize> = optional_rows(&archive["jobs"])
                .iter()
                .enumerate()
                .filter(|(_, job)| {
                    job["stage"] == "submissionUncertain"
                        && job["lastError"].as_str().is_some_and(|s| {
                            matches!(s.trim(), "network_unavailable" | "remote_unavailable")
                        })
                })
                .map(|(i, _)| i)
                .collect();
            let mut directives = Vec::new();
            for index in indexes {
                let job = archive["jobs"][index].clone();
                let prior = optional_rows(&archive["networkConfirmations"])
                    .iter()
                    .find(|r| uuid_value_equal(&r["wishID"], &job["id"]))
                    .cloned();
                if prior.as_ref().is_some_and(|r| {
                    r["attempts"].as_u64().unwrap_or(0) >= 3
                        || r["nextAt"].as_f64().is_some_and(|t| now < t)
                }) {
                    continue;
                }
                let retry = json!({"command":"retry_prepare","wishID":job["id"],"worldID":job["worldID"],"residentScope":job["residentScope"]});
                let Ok(directive) = runtime_command(db, archive, &retry, now) else {
                    continue;
                };
                let attempts = prior
                    .as_ref()
                    .and_then(|r| r["attempts"].as_u64())
                    .unwrap_or(0)
                    + 1;
                let random = uuid::Uuid::new_v4();
                let jitter = f64::from(u16::from_be_bytes([
                    random.as_bytes()[0],
                    random.as_bytes()[1],
                ])) / 65535.0;
                let next = now
                    + (30.0 * 2.0_f64.powi(attempts.saturating_sub(1) as i32)).min(240.0)
                    + 48.0 * jitter;
                if !archive["networkConfirmations"].is_array() {
                    archive["networkConfirmations"] = json!([]);
                }
                let rows = archive["networkConfirmations"].as_array_mut().unwrap();
                let record =
                    json!({"wishID":job["id"],"attempts":attempts,"lastAt":now,"nextAt":next});
                if let Some(index) = rows
                    .iter()
                    .position(|r| uuid_value_equal(&r["wishID"], &job["id"]))
                {
                    rows[index] = record;
                } else {
                    rows.push(record);
                }
                directives.push(directive);
            }
            Ok(json!(directives))
        }
        "renderer_failure" | "renderer_clear" => renderer_command(db, archive, p),
        "event_published" => {
            let id = text(p, "eventID")?;
            let Some(index) = find(&archive["events"], id) else {
                return Ok(Value::Null);
            };
            if archive["events"][index]["forwardedToDaemon"] == true {
                return Ok(Value::Null);
            }
            published(db, &archive["events"][index])?;
            archive["events"][index]["forwardedToDaemon"] = json!(true);
            Ok(Value::Null)
        }
        "authorize_images" => authorize_images(archive, p, p["attachments"].clone()),
        "register_images" => {
            text(p, "worldID")?;
            text(p, "residentScope")?;
            text(p, "conversationID")?;
            let images = p["attachments"]
                .as_array()
                .filter(|a| !a.is_empty())
                .ok_or("wish_control_unknown_attachment")?;
            if images.iter().any(|a| !file_attachment(a)) {
                return Err("wish_control_unknown_attachment");
            }
            if !archive["imageRegistrations"].is_array() {
                archive["imageRegistrations"] = json!([]);
            }
            for image in images {
                if let Some(old) = optional_rows(&archive["imageRegistrations"])
                    .iter()
                    .find(|r| uuid_value_equal(&r["attachment"]["id"], &image["id"]))
                {
                    if scope(old, p).is_err()
                        || old["conversationID"] != p["conversationID"]
                        || !protected_rows_equal(&json!([old["attachment"]]), &json!([image]))
                    {
                        return Err("wish_control_wrong_scope");
                    }
                } else {
                    archive["imageRegistrations"].as_array_mut().unwrap().push(json!({"attachment":image,"worldID":p["worldID"],"residentScope":p["residentScope"],"conversationID":p["conversationID"]}));
                }
            }
            Ok(Value::Null)
        }
        "authorize_registered" => {
            let ids = p["registeredImageIDs"]
                .as_array()
                .filter(|a| !a.is_empty())
                .ok_or("wish_control_unknown_attachment")?;
            let mut images = Vec::new();
            for id in ids {
                let image = optional_rows(&archive["imageRegistrations"])
                    .iter()
                    .find(|r| {
                        scope(r, p).is_ok()
                            && r["conversationID"] == p["conversationID"]
                            && uuid_value_equal(&r["attachment"]["id"], id)
                    })
                    .ok_or("wish_control_unknown_attachment")?;
                images.push(image["attachment"].clone());
            }
            authorize_images(archive, p, json!(images))
        }
        "register_web_reference" => {
            text(p, "worldID")?;
            text(p, "residentScope")?;
            let id = text(p, "authorizationID")?;
            if !file_attachment(&p["attachment"]) {
                return Err("wish_control_wrong_scope");
            }
            let url = p["imageURL"]
                .as_str()
                .and_then(|s| reqwest::Url::parse(s).ok())
                .ok_or("wish_control_unknown_attachment")?;
            if url.scheme() != "https"
                || url.host_str().is_none()
                || !url.username().is_empty()
                || url.password().is_some()
                || url.port().is_some_and(|port| port != 443)
            {
                return Err("wish_control_unknown_attachment");
            }
            if optional_rows(&archive["jobs"])
                .iter()
                .any(|j| uuid_value_equal(&j["authorizationID"], &p["authorizationID"]))
            {
                return Err("wish_control_consumed_authorization");
            }
            let reference = json!({"attachmentID":p["attachment"]["id"],"imageURL":p["imageURL"],"source":p["source"]});
            if let Some(old) = optional_rows(&archive["webReferences"])
                .iter()
                .find(|r| uuid_value_equal(&r["attachmentID"], &reference["attachmentID"]))
            {
                if !immutable_equal(
                    "attachmentID",
                    &old["attachmentID"],
                    &reference["attachmentID"],
                ) || old["imageURL"] != reference["imageURL"]
                    || old["source"] != reference["source"]
                {
                    return Err("wish_control_conflicting_call");
                }
            }
            if let Some(i) = find(&archive["authorizations"], id) {
                scope(&archive["authorizations"][i], p)?;
                if let Some(old) = optional_rows(&archive["authorizations"][i]["attachments"])
                    .iter()
                    .find(|a| uuid_value_equal(&a["id"], &p["attachment"]["id"]))
                {
                    if !protected_rows_equal(&json!([old]), &json!([p["attachment"]])) {
                        return Err("wish_control_conflicting_call");
                    }
                } else {
                    if optional_rows(&archive["authorizations"][i]["attachments"]).len() >= 4 {
                        return Err("wish_control_image_limit");
                    }
                    archive["authorizations"][i]["attachments"]
                        .as_array_mut()
                        .unwrap()
                        .push(p["attachment"].clone());
                }
            } else {
                authorize_images(archive, p, json!([p["attachment"]]))?;
            }
            if !archive["webReferences"].is_array() {
                archive["webReferences"] = json!([]);
            }
            if !optional_rows(&archive["webReferences"])
                .iter()
                .any(|r| uuid_value_equal(&r["attachmentID"], &reference["attachmentID"]))
            {
                archive["webReferences"]
                    .as_array_mut()
                    .unwrap()
                    .push(reference.clone());
            }
            Ok(reference)
        }
        "submit_prepare" => {
            text(p, "requestID")?;
            let auth = text(p, "authorizationID")?;
            text(p, "attachmentID")?;
            let i = find(&archive["authorizations"], auth).ok_or("wish_control_unauthorized")?;
            scope(&archive["authorizations"][i], p)?;
            if !optional_rows(&archive["authorizations"][i]["attachments"])
                .iter()
                .any(|a| uuid_value_equal(&a["id"], &p["attachmentID"]))
            {
                return Err("wish_control_unknown_attachment");
            }
            if let Some(job) = optional_rows(&archive["jobs"])
                .iter()
                .find(|j| uuid_value_equal(&j["authorizationID"], &p["authorizationID"]))
            {
                if job["requestID"] != p["requestID"] {
                    return Err("wish_control_consumed_authorization");
                }
                if !uuid_value_equal(&job["attachmentID"], &p["attachmentID"])
                    || job["name"] != p["name"]
                    || job["heightMeters"].as_f64() != p["heightMeters"].as_f64()
                    || !job["sizeIntent"].is_null()
                        && !p["sizeIntent"].is_null()
                        && job["sizeIntent"] != p["sizeIntent"]
                {
                    return Err("wish_control_conflicting_call");
                }
                let job = job.clone();
                if !p["destinationSurfaceIDs"].is_null() {
                    let mut grant = p.clone();
                    grant["command"] = json!("delegation_authorize");
                    grant["allowedSurfaceIDs"] = p["destinationSurfaceIDs"].clone();
                    grant["explicitTarget"] = p["destinationTarget"].clone();
                    command(archive, &grant, now)?;
                }
                let mut result = submission_material(archive, &job)?;
                result["action"] = json!("none");
                return Ok(result);
            }
            let name = p["name"]
                .as_str()
                .filter(|s| !s.is_empty() && s.chars().count() <= 100)
                .ok_or("wish_control_invalid_request")?;
            let height = p["heightMeters"]
                .as_f64()
                .filter(|n| n.is_finite() && (0.01..=3.0).contains(n))
                .ok_or("wish_control_invalid_request")?;
            if !p["sizeIntent"].is_null() {
                let size: crate::model::SizeIntent =
                    serde_json::from_value(p["sizeIntent"].clone())
                        .map_err(|_| "wish_control_invalid_request")?;
                size.validate()
                    .map_err(|_| "wish_control_invalid_request")?;
                if size
                    .required_height_meters()
                    .is_some_and(|required| required != height)
                {
                    return Err("wish_control_invalid_request");
                }
            }
            if !p["destinationSurfaceIDs"].is_null() {
                let mut grant = p.clone();
                grant["command"] = json!("delegation_authorize");
                grant["allowedSurfaceIDs"] = p["destinationSurfaceIDs"].clone();
                grant["explicitTarget"] = p["destinationTarget"].clone();
                command(archive, &grant, now)?;
            }
            let id = uuid::Uuid::new_v4().to_string();
            let mut job = json!({"id":id,"jobID":id,"worldID":p["worldID"],"residentScope":p["residentScope"],"authorizationID":p["authorizationID"],
                "attachmentID":p["attachmentID"],"requestID":p["requestID"],"name":name,"heightMeters":height,
                "objectID":format!("wish-prop-{id}"),"stage":"submitting","computeMayContinue":false});
            if !p["sizeIntent"].is_null() {
                job["sizeIntent"] = p["sizeIntent"].clone();
            }
            archive["jobs"].as_array_mut().unwrap().push(job.clone());
            let index = archive["jobs"].as_array().unwrap().len() - 1;
            emit(archive, index, "stateChanged");
            let mut result = submission_material(archive, &job)?;
            result["action"] = json!("create");
            Ok(result)
        }
        "recover" | "observe_all" => {
            let count = optional_rows(&archive["jobs"]).len();
            for index in 0..count {
                if p["command"] == "recover" && archive["jobs"][index]["stage"] == "submitting" {
                    archive["jobs"][index]["stage"] = json!("submissionUncertain");
                    archive["jobs"][index]["lastError"] =
                        json!("提交结果未确认，可确认原提交；不会自动再次生成。");
                    emit(archive, index, "stateChanged");
                }
                observe_job(db, archive, index, None)?;
            }
            bind_accepted_delegations(db, archive)?;
            Ok(Value::Null)
        }
        "observe" | "submit_finish" => {
            text(p, "worldID")?;
            text(p, "residentScope")?;
            let indexes: Vec<usize> = optional_rows(&archive["jobs"])
                .iter()
                .enumerate()
                .filter(|(_, j)| {
                    scope(j, p).is_ok()
                        && (p["wishID"].is_null() || uuid_value_equal(&j["id"], &p["wishID"]))
                })
                .map(|(i, _)| i)
                .collect();
            if !p["wishID"].is_null() && indexes.is_empty() {
                return Err("wish_control_wrong_scope");
            }
            let error = if p["command"] == "submit_finish" {
                Some(
                    p["nativePreparationError"]
                        .as_str()
                        .unwrap_or("后台受理结果未确认，请按原任务编号核实。"),
                )
            } else {
                None
            };
            for i in indexes.iter().copied() {
                observe_job(db, archive, i, error)?;
            }
            bind_accepted_delegations(db, archive)?;
            Ok(if indexes.len() == 1 {
                archive["jobs"][indexes[0]].clone()
            } else {
                json!(indexes
                    .iter()
                    .map(|i| archive["jobs"][*i].clone())
                    .collect::<Vec<_>>())
            })
        }
        "retry_prepare" | "cancel_prepare" => {
            let index =
                find(&archive["jobs"], text(p, "wishID")?).ok_or("wish_control_wrong_scope")?;
            scope(&archive["jobs"][index], p)?;
            let job = archive["jobs"][index].clone();
            if job["jobID"].is_null() {
                return Err("wish_control_not_ready");
            }
            if p["command"] == "cancel_prepare" {
                if [
                    "claimed",
                    "cancelled",
                    "failed",
                    "interrupted",
                    "ready",
                    "generated",
                ]
                .iter()
                .any(|s| job["stage"] == *s)
                {
                    return Ok(json!({"job":job,"action":"none"}));
                }
                archive["jobs"][index]["cancelRequested"] = json!(true);
                archive["jobs"][index]["computeMayContinue"] = json!(true);
                emit(archive, index, "stateChanged");
                return Ok(json!({"job":archive["jobs"][index],"action":"cancel"}));
            }
            validate_grant(archive, &job)?;
            if job["cancelRequested"] == true
                || !["submissionUncertain", "submitting", "generated", "failed"]
                    .iter()
                    .any(|s| job["stage"] == *s)
            {
                return Err("wish_control_retry_unavailable");
            }
            let core = core_job(db, &job)?;
            if job["stage"] != "failed"
                && core.as_ref().is_some_and(|c| {
                    c.receipt.is_some()
                        && !(c
                            .receipt
                            .as_ref()
                            .is_some_and(|r| r["state"] == "completed")
                            && c.local_model_path.is_none())
                })
            {
                observe_job(db, archive, index, None)?;
                return Ok(json!({"job":archive["jobs"][index],"action":"none"}));
            }
            let mut result = submission_material(archive, &job)?;
            result["action"] = json!(if core.is_some() { "retry" } else { "create" });
            Ok(result)
        }
        _ => command(archive, p, now),
    }
}
fn bind_accepted_delegations(db: &Connection, archive: &mut Value) -> Result<()> {
    if optional_rows(&archive["delegations"]).is_empty() {
        return Ok(());
    }
    let mut accepted = Vec::new();
    for job in optional_rows(&archive["jobs"]) {
        let Some(id) = job["jobID"].as_str() else {
            continue;
        };
        let raw: Option<String> = db
            .query_row(
                "SELECT data FROM jobs WHERE lower(id)=lower(?1)",
                [id],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        let Some(raw) = raw else { continue };
        let core: crate::model::Stored =
            serde_json::from_str(&raw).map_err(|_| "wish_control_invalid_request")?;
        if core.job.receipt.is_some()
            && core.job.context.as_ref().is_some_and(|context| {
                Some(context.world_id.as_str()) == job["worldID"].as_str()
                    && Some(context.resident_scope.as_str()) == job["residentScope"].as_str()
            })
        {
            accepted.push(job.clone());
        }
    }
    if let Some(rows) = archive["delegations"].as_array_mut() {
        for d in rows {
            if !d["objectID"].is_null() {
                continue;
            }
            if let Some(job) = accepted.iter().find(|j| {
                uuid_value_equal(&j["authorizationID"], &d["authorizationID"])
                    && j["worldID"] == d["worldID"]
                    && j["residentScope"] == d["residentScope"]
            }) {
                d["objectID"] = job["objectID"].clone();
                d["state"] = json!(if job["autoContinuationPaused"] == true
                    || d["state"] == "revoked"
                {
                    "revoked"
                } else {
                    "pending"
                });
            }
        }
    }
    Ok(())
}
pub fn request(db: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let owner = text(p, "ownerID")?;
    let session = text(p, "hostSessionID")?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(|_| "storage_unavailable")?;
    let old: Option<(String,i64,String,Option<String>)> = tx.query_row("SELECT session,revision,payload,import_hash FROM wish_control_documents WHERE owner=?1",[owner], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))
        .optional().map_err(|_| "storage_unavailable")?;
    if method == "wish_control_open" {
        let imported = p.get("legacyArchive").filter(|v| !v.is_null());
        let mut hash = None;
        if let Some(v) = imported {
            validate(v)?;
            let actual = format!("{:x}", Sha256::digest(encode(v)?.as_bytes()));
            if p.get("importSHA256").is_some() && p["importSHA256"].as_str() != Some(&actual) {
                return Err("wish_control_import_conflict");
            }
            hash = Some(actual);
        }
        let (revision, archive) = if let Some((_, revision, raw, previous)) = old {
            if hash.is_some() && previous != hash {
                return Err("wish_control_import_conflict");
            }
            tx.execute(
                "UPDATE wish_control_documents SET session=?2 WHERE owner=?1",
                params![owner, session],
            )
            .map_err(|_| "storage_unavailable")?;
            (
                revision,
                serde_json::from_str(&raw).map_err(|_| "wish_control_invalid_request")?,
            )
        } else {
            let archive = imported
                .cloned()
                .unwrap_or_else(|| json!({"authorizations":[],"jobs":[],"events":[]}));
            tx.execute(
                "INSERT INTO wish_control_documents VALUES(?1,?2,0,?3,?4)",
                params![owner, session, encode(&archive)?, hash],
            )
            .map_err(|_| "storage_unavailable")?;
            (0, archive)
        };
        tx.commit().map_err(|_| "storage_unavailable")?;
        return Ok(receipt(revision, archive));
    }
    let (current, revision, raw, _) = old.ok_or("wish_control_invalid_request")?;
    if current != session {
        return Err("wish_control_stale_session");
    }
    let mut archive: Value =
        serde_json::from_str(&raw).map_err(|_| "wish_control_invalid_request")?;
    if method == "wish_control_read" {
        return Ok(receipt(revision, archive));
    }
    if p["expectedRevision"].as_i64() != Some(revision) {
        return Err("wish_control_revision_conflict");
    }
    let before = archive.clone();
    let mut command_result = Value::Null;
    match method {
        "wish_control_command" => {
            command_result = runtime_command(&tx, &mut archive, p, wall_time()?)?;
            if matches!(p["command"].as_str(), Some("delegation_authorize")) {
                bind_accepted_delegations(&tx, &mut archive)?;
                if let Some(d) = optional_rows(&archive["delegations"])
                    .iter()
                    .find(|d| uuid_value_equal(&d["id"], &command_result["id"]))
                {
                    command_result = d.clone();
                }
            }
        }
        "wish_control_commit" => {
            let candidate = p["archive"].clone();
            validate(&candidate)?;
            for key in [
                "authorizations",
                "jobs",
                "events",
                "imageRegistrations",
                "webReferences",
                "pendingDrafts",
                "delegations",
                "networkConfirmations",
                "unreadableJobs",
            ] {
                if !protected_rows_equal(&archive[key], &candidate[key]) {
                    return Err("wish_control_transition_rejected");
                }
            }
            for old_job in archive["jobs"].as_array().unwrap() {
                let id = text(old_job, "id")?;
                let index =
                    find(&candidate["jobs"], id).ok_or("wish_control_transition_rejected")?;
                let next = &candidate["jobs"][index];
                for key in [
                    "id",
                    "worldID",
                    "residentScope",
                    "authorizationID",
                    "attachmentID",
                    "requestID",
                    "objectID",
                    "jobID",
                    "autoContinuationPaused",
                    "autoContinuationStoppedByUser",
                    "continuationResumeAuthorizationIDs",
                ] {
                    if !immutable_equal(key, &old_job[key], &next[key]) {
                        return Err("wish_control_transition_rejected");
                    }
                }
                if (old_job["stage"] == "claimed") != (next["stage"] == "claimed") {
                    return Err("wish_control_transition_rejected");
                }
            }
            for event in archive["events"].as_array().unwrap() {
                let Some(index) = find(&candidate["events"], text(event, "id")?) else {
                    // Renderer verdicts are host-derived, revocable observations,
                    // unlike durable provider/claim/consumption facts.
                    if event["kind"] == "failed" && event["failureSource"] == "renderer" {
                        continue;
                    }
                    return Err("wish_control_transition_rejected");
                };
                let next = &candidate["events"][index];
                for key in [
                    "id",
                    "wishID",
                    "worldID",
                    "residentScope",
                    "objectID",
                    "kind",
                ] {
                    if !immutable_equal(key, &next[key], &event[key]) {
                        return Err("wish_control_transition_rejected");
                    }
                }
                if next["acknowledged"] != event["acknowledged"] {
                    return Err("wish_control_transition_rejected");
                }
                if next["forwardedToDaemon"] == true && event["forwardedToDaemon"] != true {
                    published(&tx, next)?;
                }
            }
            if let Some(delegations) = archive["delegations"].as_array() {
                for old in delegations {
                    let next = candidate["delegations"]
                        .as_array()
                        .and_then(|a| a.iter().find(|d| uuid_value_equal(&d["id"], &old["id"])))
                        .ok_or("wish_control_transition_rejected")?;
                    if old["state"] == "placed" && next["state"] != "placed" {
                        return Err("wish_control_transition_rejected");
                    }
                    if old["state"] == "revoked"
                        && !["revoked", "placed", "failed"]
                            .iter()
                            .any(|s| next["state"] == *s)
                    {
                        return Err("wish_control_transition_rejected");
                    }
                }
            }
            for job in candidate["jobs"].as_array().unwrap() {
                if find(&archive["jobs"], text(job, "id")?).is_none() {
                    validate_grant(&candidate, job)?;
                    if job["stage"] == "claimed" || job["autoContinuationPaused"] == true {
                        return Err("wish_control_transition_rejected");
                    }
                }
            }
            for event in candidate["events"].as_array().unwrap() {
                if find(&archive["events"], text(event, "id")?).is_none()
                    && event["acknowledged"] == true
                {
                    return Err("wish_control_transition_rejected");
                }
            }
            archive = candidate;
            bind_accepted_delegations(&tx, &mut archive)?;
        }
        "wish_control_claim" => {
            let index =
                find(&archive["jobs"], text(p, "wishID")?).ok_or("wish_control_wrong_scope")?;
            scope(&archive["jobs"][index], p)?;
            validate_grant(&archive, &archive["jobs"][index])?;
            if archive["jobs"][index]["stage"] != "claimed" {
                if archive["jobs"][index]["stage"] != "ready" {
                    return Err("wish_control_not_ready");
                }
                output(&tx, &archive["jobs"][index])?;
                claim_observation(&tx, &archive["jobs"][index], p)?;
                archive["jobs"][index]["stage"] = json!("claimed");
                let job = &archive["jobs"][index];
                let event = json!({"id":uuid::Uuid::new_v4().to_string(),"wishID":job["id"],"worldID":job["worldID"],"residentScope":job["residentScope"],"objectID":job["objectID"],"kind":"claimed","computeMayContinue":false,"acknowledged":false,"stage":"claimed"});
                archive["events"].as_array_mut().unwrap().push(event);
            }
        }
        "wish_control_pause" => {
            text(p, "worldID")?;
            text(p, "residentScope")?;
            for job in archive["jobs"].as_array_mut().unwrap() {
                if scope(job, p).is_ok() {
                    job["autoContinuationPaused"] = json!(true);
                    job["autoContinuationStoppedByUser"] = json!(true);
                }
            }
            if let Some(delegations) = archive["delegations"].as_array_mut() {
                for d in delegations {
                    if scope(d, p).is_ok() && d["state"] == "pending" {
                        d["state"] = json!("revoked");
                    }
                }
            }
        }
        "wish_control_discard_unproven_pauses" => {
            let mut reopened = std::collections::HashSet::new();
            let mut events = Vec::new();
            for job in archive["jobs"].as_array_mut().unwrap() {
                if job["autoContinuationPaused"] == true
                    && job["autoContinuationStoppedByUser"] != true
                {
                    reopened.insert((
                        job["worldID"].clone().to_string(),
                        job["residentScope"].clone().to_string(),
                        job["authorizationID"].clone().to_string(),
                    ));
                    job["autoContinuationPaused"] = json!(false);
                    job.as_object_mut()
                        .unwrap()
                        .remove("autoContinuationStoppedByUser");
                    events.push(json!({"id":uuid::Uuid::new_v4().to_string(),
                        "wishID":job["id"],"worldID":job["worldID"],"residentScope":job["residentScope"],
                        "objectID":job["objectID"],"kind":"stateChanged","stage":job["stage"],
                        "computeMayContinue":job["computeMayContinue"].as_bool().unwrap_or(false),
                        "autoContinuationPaused":false,"acknowledged":false,
                        "message":"已解除没有用户停止依据的临时暂停，不需要手动解除。"}));
                }
            }
            if reopened.is_empty() {
                tx.commit().map_err(|_| "storage_unavailable")?;
                return Ok(receipt(revision, archive));
            }
            archive["events"].as_array_mut().unwrap().extend(events);
            if let Some(delegations) = archive["delegations"].as_array_mut() {
                for d in delegations {
                    if d["state"] == "revoked"
                        && reopened.contains(&(
                            d["worldID"].clone().to_string(),
                            d["residentScope"].clone().to_string(),
                            d["authorizationID"].clone().to_string(),
                        ))
                    {
                        d["state"] = json!(if d["objectID"].is_null() {
                            "awaitingSubmission"
                        } else {
                            "pending"
                        });
                    }
                }
            }
        }
        "wish_control_resume" => {
            let index =
                find(&archive["jobs"], text(p, "wishID")?).ok_or("wish_control_wrong_scope")?;
            scope(&archive["jobs"][index], p)?;
            validate_grant(&archive, &archive["jobs"][index])?;
            let authorization = text(p, "authorizationID")?;
            // A grant is bound to the current scheduler's real human run/session.
            let allowed: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM agent_loop_human_messages WHERE world=?1 AND scope=?2 AND lower(run)=lower(?3) AND session=?4 AND state IN ('claimed','steer_claimed'))",params![text(p,"worldID")?,text(p,"residentScope")?,authorization,session],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
            if !allowed {
                return Err("wish_control_resume_unauthorized");
            }
            let job = &archive["jobs"][index];
            let used = job["continuationResumeAuthorizationIDs"]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let same_authorization = |v: &Value| {
                v.as_str()
                    .is_some_and(|s| s.eq_ignore_ascii_case(authorization))
            };
            if used.iter().any(same_authorization) {
                // A lost response may retry the latest completed grant, but a
                // subsequent stop or a different grant cannot reuse its authority.
                if used.last().is_some_and(same_authorization)
                    && job["autoContinuationPaused"] != true
                    && job["autoContinuationStoppedByUser"] != true
                {
                    return Ok(receipt(revision, archive));
                }
                return Err("wish_control_resume_unauthorized");
            }
            let delegation = archive["delegations"].as_array().and_then(|a| {
                a.iter().position(|d| {
                    scope(d, p).is_ok() && d["authorizationID"] == job["authorizationID"]
                })
            });
            if job["cancelRequested"] == true
                || ["failed", "cancelled", "interrupted"]
                    .iter()
                    .any(|s| job["stage"] == *s)
                || ["failed", "cancelled", "interrupted", "cancel_requested"]
                    .iter()
                    .any(|s| job["remoteState"] == *s)
            {
                return Err("wish_control_transition_rejected");
            }
            if delegation.is_some_and(|i| archive["delegations"][i]["state"] == "failed") {
                return Err("wish_control_transition_rejected");
            }
            let already_placed = delegation
                .is_some_and(|i| archive["delegations"][i]["state"] == "placed")
                || (job["stage"] == "claimed" && p["placementAlreadyCompleted"] == true);
            if job["stage"] == "claimed"
                && !already_placed
                && (p["placementAlreadyCompleted"] != false || delegation.is_none())
            {
                return Err("wish_control_transition_rejected");
            }
            if already_placed {
                archive["jobs"][index]["autoContinuationPaused"] = json!(false);
                archive["jobs"][index]
                    .as_object_mut()
                    .unwrap()
                    .remove("autoContinuationStoppedByUser");
                if let Some(i) = delegation {
                    archive["delegations"][i]["state"] = json!("placed");
                }
            } else {
                let job = &mut archive["jobs"][index];
                let mut used = used;
                used.push(json!(authorization));
                job["continuationResumeAuthorizationIDs"] = json!(used);
                job["autoContinuationPaused"] = json!(false);
                job.as_object_mut()
                    .unwrap()
                    .remove("autoContinuationStoppedByUser");
                let event = json!({"id":uuid::Uuid::new_v4().to_string(),"wishID":job["id"],"worldID":job["worldID"],"residentScope":job["residentScope"],"objectID":job["objectID"],"kind":"stateChanged","computeMayContinue":job["computeMayContinue"].as_bool().unwrap_or(false),"acknowledged":false,"stage":job["stage"],"autoContinuationPaused":false,"continuationResumeAuthorizationID":authorization});
                archive["events"].as_array_mut().unwrap().push(event);
                let original_authorization = archive["jobs"][index]["authorizationID"].clone();
                if let Some(delegations) = archive["delegations"].as_array_mut() {
                    for d in delegations {
                        if scope(d, p).is_ok()
                            && d["authorizationID"] == original_authorization
                            && d["state"] == "revoked"
                        {
                            d["state"] = json!(if d["objectID"].is_null() {
                                "awaitingSubmission"
                            } else {
                                "pending"
                            });
                        }
                    }
                }
            }
        }
        "wish_control_event_ack" => {
            let index =
                find(&archive["events"], text(p, "eventID")?).ok_or("wish_control_wrong_scope")?;
            scope(&archive["events"][index], p)?;
            published(&tx, &archive["events"][index])?;
            let consumed: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM message_acks WHERE lower(message_id)=lower(?1) AND consumer='agent')",[text(p,"eventID")?],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
            if !consumed {
                return Err("wish_control_not_published");
            }
            archive["events"][index]["acknowledged"] = json!(true);
        }
        "wish_control_retry_authorize" => {
            let index =
                find(&archive["jobs"], text(p, "wishID")?).ok_or("wish_control_wrong_scope")?;
            let job = &archive["jobs"][index];
            scope(job, p)?;
            validate_grant(&archive, job)?;
            if job["cancelRequested"] == true
                || !["submissionUncertain", "submitting", "generated", "failed"]
                    .iter()
                    .any(|s| job["stage"] == *s)
            {
                return Err("wish_control_transition_rejected");
            }
            // This readback grants no new identity or automatic retry.
            return Ok(receipt(revision, archive));
        }
        _ => return Err("unknown_method"),
    }
    if method == "wish_control_command" && archive == before {
        tx.commit().map_err(|_| "storage_unavailable")?;
        let mut response = receipt(revision, archive);
        response["result"] = command_result;
        return Ok(response);
    }
    tx.execute(
        "UPDATE wish_control_documents SET revision=?2,payload=?3 WHERE owner=?1",
        params![owner, revision + 1, encode(&archive)?],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    let mut response = receipt(revision + 1, archive);
    if method == "wish_control_command" {
        response["result"] = command_result;
    }
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        db: Connection,
        root: std::path::PathBuf,
    }
    impl std::ops::Deref for Fixture {
        type Target = Connection;
        fn deref(&self) -> &Connection {
            &self.db
        }
    }
    impl std::ops::DerefMut for Fixture {
        fn deref_mut(&mut self) -> &mut Connection {
            &mut self.db
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    fn setup() -> Fixture {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-wish-control-{}", uuid::Uuid::new_v4()));
        crate::files::directory(&root).unwrap();
        let mut db = Connection::open(root.join("tasks.sqlite3")).unwrap();
        db.execute_batch("PRAGMA foreign_keys=ON;").unwrap();
        crate::memory::register_vec();
        crate::store::migrate(&mut db).unwrap();
        Fixture { db, root }
    }
    fn archive() -> Value {
        json!({"authorizations":[{"id":"grant","worldID":"world","residentScope":"resident","attachments":[{"id":"image"}]}],"jobs":[{"id":"wish","worldID":"world","residentScope":"resident","authorizationID":"grant","attachmentID":"image","requestID":"request","objectID":"object","jobID":"core","stage":"ready","modelPath":"/missing/private-fixture.glb"}],"events":[]})
    }
    fn call(db: &mut Connection, method: &str, revision: i64, extra: Value) -> Result<Value> {
        let mut p =
            json!({"ownerID":"owner","hostSessionID":"session","expectedRevision":revision});
        for (k, v) in extra.as_object().unwrap() {
            p[k] = v.clone();
        }
        request(db, method, &p)
    }
    fn collection_observation(db: &mut Connection) -> Value {
        let tx = db.transaction().unwrap();
        crate::world::commit(
            &tx,
            &crate::world::CommitRequest {
                world_id: "world".into(),
                request_id: "collection-seed".into(),
                expected_revision: 0,
                producer: None,
                intent: None,
                ops: vec![crate::world::Op {
                    op: "replaceState".into(),
                    state: Some(
                        json!({"worldID":"world","revision":0,"worldTime":1000,"objectStates":{},
                "agentTransform":{"position":{"x":0,"y":0,"z":0}}}),
                    ),
                    ..Default::default()
                }],
            },
        )
        .unwrap();
        tx.commit().unwrap();
        let execute = |db: &mut Connection, method: &str, input: Value| {
            let tx = db.transaction().unwrap();
            let result = crate::world_activity::request(&tx, method, input).unwrap();
            tx.commit().unwrap();
            result
        };
        let phases:[Value;6]=["approach","enter","loop","exit","interrupt","failed"].map(|phase|json!({"phase":phase,"motionIDs":["fixture-motion"],"requiredAnchorIDs":[],"propIDs":[]}));
        execute(
            db,
            "world_activity_bind_catalog",
            json!({"worldID":"world","hostSessionID":"native-host","requestID":"collection-bind",
            "definitions":[{"id":"wish_machine.collect","displayName":"Collection fixture","activity":{"type":"interact","anchorID":"collector"},"interruptible":true,"cooldownSeconds":0,"phases":phases}],
            "waypoints":[{"id":"collector","position":{"x":0,"y":0,"z":0},"arrivalRadius":0.1,"enabled":true}],"routes":[],
            "authoredActivities":[{"id":"wish_machine.collect","entryWaypointID":"collector","transform":{"rotation":{"x":0,"y":0,"z":0,"w":1}}}]}),
        );
        let snapshot = crate::world::snapshot(
            db,
            &crate::world::SnapshotRequest {
                world_id: "world".into(),
                include_state: Some(true),
            },
        )
        .unwrap();
        let mut start = json!({"worldID":"world","hostSessionID":"native-host","requestID":"collection-start",
            "expectedRevision":snapshot["record"]["recordRevision"],"expectedLayoutRevision":snapshot["record"]["state"]["layoutRevision"],"checkpoint":snapshot["record"]["state"],"definitionID":"wish_machine.collect",
            "priority":0,"waitsForRenderedCompletion":true});
        let prepared = execute(db, "world_activity_prepare", start.clone());
        assert_eq!(prepared["stage"], "ready", "fixture is already at the authored collector waypoint");
        start["planSHA256"] = prepared["planSHA256"].clone();
        start["preparedAtMS"] = prepared["preparedAtMS"].clone();
        let approached = execute(
            db,
            "world_activity_start",
            start,
        );
        let run = &approached["activity"]["run"];
        let entered = execute(
            db,
            "world_activity_receipt",
            json!({"worldID":"world","hostSessionID":"native-host","requestID":"collection-arrived",
            "expectedRevision":approached["snapshot"]["record"]["recordRevision"],"checkpoint":approached["snapshot"]["record"]["state"],
            "runRequestID":run["requestID"],"generation":run["generation"],"phaseGeneration":run["phaseGeneration"],"phase":run["phase"],"kind":"arrived"}),
        );
        let run = &entered["activity"]["run"];
        let looping = execute(
            db,
            "world_activity_receipt",
            json!({"worldID":"world","hostSessionID":"native-host","requestID":"collection-clip",
            "expectedRevision":entered["snapshot"]["record"]["recordRevision"],"checkpoint":entered["snapshot"]["record"]["state"],
            "runRequestID":run["requestID"],"generation":run["generation"],"phaseGeneration":run["phaseGeneration"],"phase":run["phase"],"kind":"clipCompleted"}),
        );
        let run = &looping["activity"]["run"];
        assert_eq!(run["phase"], "loop");
        assert!(
            looping["snapshot"]["record"]["state"]["activeActivity"]
                .get("phase")
                .is_none(),
            "real world projection has no phase; the bound run owns phase"
        );
        assert_eq!(
            looping["snapshot"]["record"]["state"]["activeActivity"]["status"],
            "running"
        );
        json!({"worldID":"world","activityID":"wish_machine.collect","phase":"loop","distanceMeters":0.0,"outputAvailable":true,"objectID":"object",
            "activityRequestID":run["requestID"],"activityGeneration":run["generation"],"phaseGeneration":run["phaseGeneration"],"activityHostSessionID":run["hostSessionID"]})
    }
    #[test]
    fn confirmation_authority_is_bounded_durable_and_uses_internal_clock() {
        let db = setup();
        let mut a = archive();
        a["authorizations"][0]["attachments"][0] =
            json!({"id":"image","url":"file:///private/fixture.png","displayName":"fixture"});
        a["authorizations"][0]["source"] = json!({"author":"fixture","license":"CC0"});
        a["jobs"][0]["stage"] = json!("submissionUncertain");
        a["jobs"][0]["lastError"] = json!("network_unavailable");
        let p = json!({"command":"confirmation_prepare","now":1e12});
        assert_eq!(
            runtime_command(&db, &mut a, &p, 1000.0)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(a["networkConfirmations"][0]["attempts"], 1);
        assert!(runtime_command(&db, &mut a, &p, 1001.0)
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(
            runtime_command(&db, &mut a, &p, 1100.0)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            runtime_command(&db, &mut a, &p, 1300.0)
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert!(runtime_command(&db, &mut a, &p, 10000.0)
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(a["networkConfirmations"][0]["attempts"], 3);
        a["networkConfirmations"] = json!([]);
        a["jobs"][0]["lastError"] = json!("已恢复 network_unavailable 之后");
        assert!(runtime_command(&db, &mut a, &p, 10000.0)
            .unwrap()
            .as_array()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn rust_views_suppress_paused_placed_old_resume_and_acknowledged_events() {
        let mut a = archive();
        a["events"] = json!([{"id":"event","wishID":"wish","worldID":"world","residentScope":"resident","kind":"outputReady","acknowledged":false}]);
        assert_eq!(
            receipt(1, a.clone())["views"]["continuationEvents"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        a["jobs"][0]["autoContinuationPaused"] = json!(true);
        assert!(receipt(1, a.clone())["views"]["continuationEvents"]
            .as_array()
            .unwrap()
            .is_empty());
        a["jobs"][0]["autoContinuationPaused"] = json!(false);
        a["events"][0]["continuationResumeAuthorizationID"] = json!("old");
        a["jobs"][0]["continuationResumeAuthorizationIDs"] = json!(["new"]);
        assert!(receipt(1, a.clone())["views"]["continuationEvents"]
            .as_array()
            .unwrap()
            .is_empty());
        a["events"][0]["continuationResumeAuthorizationID"] = json!("new");
        a["delegations"] = json!([{"authorizationID":"grant","worldID":"world","residentScope":"resident","state":"placed"}]);
        assert!(receipt(1, a.clone())["views"]["continuationEvents"]
            .as_array()
            .unwrap()
            .is_empty());
        a["events"][0]["acknowledged"] = json!(true);
        assert!(receipt(1, a)["views"]["pendingEvents"]
            .as_array()
            .unwrap()
            .is_empty());
    }
    #[test]
    fn continuation_classification_is_rust_authority_not_native_kind_or_payload() {
        let mut a = archive();
        for kind in ["stateChanged", "submitted", "unknown", ""] {
            a["events"] = json!([{"id":"event","wishID":"wish","worldID":"world","residentScope":"resident","kind":kind,"acknowledged":false}]);
            assert!(receipt(1, a.clone())["views"]["continuationEvents"].as_array().unwrap().is_empty());
        }
        for kind in ["outputReady", "failed", "cancelled", "interrupted", "placed"] {
            a["events"][0]["kind"] = json!(kind);
            assert_eq!(receipt(2, a.clone())["views"]["continuationEvents"].as_array().unwrap().len(), 1);
        }
        a["events"][0]["kind"] = json!("outputReady");
        a["jobs"][0]["stage"] = json!("claimed");
        assert!(receipt(3, a.clone())["views"]["continuationEvents"].as_array().unwrap().is_empty());
        a["events"][0]["kind"] = json!("stateChanged");
        a["events"][0]["continuationResumeAuthorizationID"] = json!("old");
        a["jobs"][0]["continuationResumeAuthorizationIDs"] = json!(["current"]);
        assert!(receipt(4, a.clone())["views"]["continuationEvents"].as_array().unwrap().is_empty());
        a["events"][0]["continuationResumeAuthorizationID"] = json!("current");
        assert_eq!(receipt(5, a.clone())["views"]["continuationEvents"].as_array().unwrap().len(), 1);
        a["events"][0]["residentScope"] = json!("foreign");
        assert!(receipt(6, a.clone())["views"]["continuationEvents"].as_array().unwrap().is_empty());
        assert_eq!(receipt(6, a)["views"]["pendingEvents"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn submit_commands_own_identity_consumption_and_observe_requires_real_core() {
        let db = setup();
        let mut a = json!({"authorizations":[],"jobs":[],"events":[]});
        let grant = json!({"command":"authorize_images","worldID":"world","residentScope":"resident",
            "authorizationID":"grant","attachments":[{"id":"image","url":"file:///private/fixture.png","displayName":"fixture"}],
            "source":{"author":"fixture","license":"CC0"}});
        runtime_command(&db, &mut a, &grant, 1000.0).unwrap();
        let p = json!({"command":"submit_prepare","worldID":"world","residentScope":"resident","authorizationID":"grant",
            "attachmentID":"image","requestID":"original","name":"chair","heightMeters":0.5});
        let first = runtime_command(&db, &mut a, &p, 1000.0).unwrap();
        assert_eq!(first["action"], "create");
        assert_eq!(first["job"]["id"], first["job"]["jobID"]);
        assert_eq!(
            runtime_command(&db, &mut a, &p, 1001.0).unwrap()["action"],
            "none"
        );
        assert_eq!(a["jobs"].as_array().unwrap().len(), 1);
        let mut conflict = p.clone();
        conflict["requestID"] = json!("new");
        assert_eq!(
            runtime_command(&db, &mut a, &conflict, 1001.0),
            Err("wish_control_consumed_authorization")
        );
        let finish = json!({"command":"submit_finish","worldID":"world","residentScope":"resident","wishID":first["job"]["id"],
            "nativePreparationError":"network_unavailable","stage":"ready","daemonAccepted":true});
        let uncertain = runtime_command(&db, &mut a, &finish, 1002.0).unwrap();
        assert_eq!(uncertain["stage"], "submissionUncertain");
        assert_ne!(uncertain["daemonAccepted"], true);
        assert!(uncertain["modelPath"].is_null());
        let retry = json!({"command":"retry_prepare","worldID":"world","residentScope":"resident","wishID":first["job"]["id"]});
        let directive = runtime_command(&db, &mut a, &retry, 1003.0).unwrap();
        assert_eq!(directive["action"], "create");
        assert_eq!(directive["job"]["id"], first["job"]["id"]);
        assert_eq!(a["authorizations"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn draft_commands_use_authority_clock_original_identity_and_explicit_replay() {
        let mut a = archive();
        let p = json!({"command":"draft_record","id":"draft","authorityID":"grant","requestID":"request",
            "attachmentID":"image","name":"chair","worldID":"world","residentScope":"resident","needs":["height"]});
        let first = command(&mut a, &p, 1000.0).unwrap();
        assert_eq!(first["createdAt"], 1000.0);
        assert_eq!(first["attempt"], 1);
        let mut retry = p.clone();
        retry["id"] = json!("other-id");
        retry["needs"] = json!(["dimensions"]);
        let retried = command(&mut a, &retry, 1001.0).unwrap();
        assert_eq!(retried["id"], "draft");
        assert_eq!(retried["createdAt"], 1000.0);
        assert_eq!(retried["attempt"], 2);
        let resolve = json!({"command":"draft_resolve","worldID":"world","residentScope":"resident","attachmentID":"image","name":"chair"});
        assert_eq!(
            command(&mut a, &resolve, 87400.0).unwrap()["resolution"],
            "resume"
        );
        assert_eq!(
            command(&mut a, &resolve, 87400.001).unwrap()["resolution"],
            "fresh"
        );
        command(
            &mut a,
            &json!({"command":"draft_submit","id":"draft","jobID":"wish"}),
            1002.0,
        )
        .unwrap();
        assert_eq!(
            command(&mut a, &resolve, 1003.0).unwrap()["resolution"],
            "fresh"
        );
        let mut explicit = resolve.clone();
        explicit["pendingID"] = json!("draft");
        assert_eq!(
            command(&mut a, &explicit, 1003.0).unwrap()["draft"]["submittedJobID"],
            "wish"
        );
        explicit["name"] = json!("other");
        assert_eq!(
            command(&mut a, &explicit, 1003.0).unwrap()["resolution"],
            "ambiguous"
        );
        let mut fresh = p;
        fresh["id"] = json!("fresh");
        fresh["requestID"] = json!("fresh-request");
        command(&mut a, &fresh, 87400.001).unwrap();
        assert_eq!(a["pendingDrafts"].as_array().unwrap().len(), 1);
        assert_eq!(a["pendingDrafts"][0]["id"], "fresh");
    }
    #[test]
    fn placement_commands_enforce_claim_surface_float_target_revocation_and_receipts() {
        let mut a = archive();
        a["jobs"][0]["stage"] = json!("claimed");
        a["delegations"] = json!([{"id":"d","authorizationID":"grant","requestID":"placement-d","worldID":"world",
            "residentScope":"resident","allowedSurfaceIDs":["table"],"objectID":"object","state":"pending"}]);
        let target = json!({"surfaceID":"table","position":{"x":0.1,"y":0,"z":0.3},"yaw":0});
        let p = json!({"command":"delegation_resolve","worldID":"world","residentScope":"resident","objectID":"object",
            "surfaceID":"table","target":target});
        command(&mut a, &p, 0.0).unwrap();
        let mut newer = p.clone();
        newer["target"]["position"]["x"] = json!(0.2);
        command(&mut a, &newer, 0.0).unwrap();
        let mut completion = p.clone();
        completion["command"] = json!("delegation_complete");
        completion["requestID"] = json!("placement-d");
        assert_eq!(
            command(&mut a, &completion, 0.0),
            Err("wish_control_conflicting_call")
        );
        completion["target"] = newer["target"].clone();
        completion["target"]["position"]["x"] = json!(0.20000000298023224);
        command(&mut a, &completion, 0.0).unwrap();
        let after = a.clone();
        command(&mut a, &completion, 0.0).unwrap();
        assert_eq!(a, after);
        assert_eq!(a["events"].as_array().unwrap().len(), 1);
        assert_eq!(a["events"][0]["kind"], "placed");
        a["delegations"][0]["state"] = json!("pending");
        command(
            &mut a,
            &json!({"command":"delegation_revoke","worldID":"world","residentScope":"resident"}),
            0.0,
        )
        .unwrap();
        assert_eq!(
            command(&mut a, &p, 0.0),
            Err("wish_control_placement_revoked")
        );
        assert_eq!(
            command(&mut a, &completion, 0.0),
            Err("wish_control_placement_revoked")
        );
        a["delegations"][0]["state"] = json!("pending");
        a["jobs"][0]["stage"] = json!("ready");
        assert_eq!(command(&mut a, &p, 0.0), Err("wish_control_unauthorized"));
    }
    #[test]
    fn draft_and_delegation_mutations_cannot_enter_through_candidate_commit() {
        let mut fixture = setup();
        let mut old = archive();
        old["jobs"] = json!([]);
        call(
            &mut fixture,
            "wish_control_open",
            0,
            json!({"legacyArchive":old}),
        )
        .unwrap();
        let authorized=call(&mut fixture,"wish_control_command",0,json!({"command":"delegation_authorize",
            "authorizationID":"grant","worldID":"world","residentScope":"resident","allowedSurfaceIDs":["table"]})).unwrap();
        assert_eq!(authorized["result"]["state"], "awaitingSubmission");
        let mut forged = authorized["archive"].clone();
        forged["delegations"][0]["state"] = json!("placed");
        assert_eq!(
            call(
                &mut fixture,
                "wish_control_commit",
                1,
                json!({"archive":forged})
            ),
            Err("wish_control_transition_rejected")
        );
        let recorded=call(&mut fixture,"wish_control_command",1,json!({"command":"draft_record","id":"draft","authorityID":"grant",
            "requestID":"original","attachmentID":"image","name":"chair","needs":["height"],"worldID":"world","residentScope":"resident",
            "now":-1e15,"createdAt":-1e15})).unwrap();
        assert!(
            recorded["result"]["createdAt"].as_f64().unwrap() > 0.0,
            "RPC supplied clock never determines expiry"
        );
        let mut forged = recorded["archive"].clone();
        forged["pendingDrafts"][0]["submittedJobID"] = json!("arbitrary-job");
        assert_eq!(
            call(
                &mut fixture,
                "wish_control_commit",
                2,
                json!({"archive":forged})
            ),
            Err("wish_control_transition_rejected")
        );
        let listed = call(
            &mut fixture,
            "wish_control_command",
            2,
            json!({"command":"draft_list","worldID":"world","residentScope":"resident"}),
        )
        .unwrap();
        assert_eq!(listed["revision"], 2);
        assert_eq!(listed["result"].as_array().unwrap().len(), 1);
    }
    #[test]
    fn delegation_object_binding_requires_real_store_receipt_and_exact_scope() {
        let mut fixture = setup();
        let a = archive();
        call(
            &mut fixture,
            "wish_control_open",
            0,
            json!({"legacyArchive":a}),
        )
        .unwrap();
        let granted=call(&mut fixture,"wish_control_command",0,json!({"command":"delegation_authorize",
            "authorizationID":"grant","worldID":"world","residentScope":"resident","allowedSurfaceIDs":["table"]})).unwrap();
        let mut candidate = granted["archive"].clone();
        candidate["jobs"][0]["remoteState"] = json!("generating");
        let forged = call(
            &mut fixture,
            "wish_control_commit",
            1,
            json!({"archive":candidate}),
        );
        assert_eq!(forged, Err("wish_control_transition_rejected"));
        let observed = granted;
        assert!(
            observed["archive"]["delegations"][0]["objectID"].is_null(),
            "candidate observation cannot manufacture provider acceptance"
        );
        let mut core = json!({"job":{"id":"core","name":"fixture","endpoint":"https://example.invalid","imagePath":"unused","imageSHA256":"0".repeat(64),
            "heightMeters":0.5,"source":{"author":"fixture","license":"CC0"},"idempotencyKey":"core","receipt":{"state":"generating"},
            "context":{"worldID":"foreign","residentScope":"resident"}},"attempted":true});
        fixture
            .execute(
                "INSERT INTO jobs(id,data) VALUES('core',?1)",
                [core.to_string()],
            )
            .unwrap();
        let foreign = call(
            &mut fixture,
            "wish_control_command",
            1,
            json!({"command":"delegation_authorize","authorizationID":"grant","worldID":"world","residentScope":"resident","allowedSurfaceIDs":["table"]}),
        )
        .unwrap();
        assert!(foreign["archive"]["delegations"][0]["objectID"].is_null());
        core["job"]["context"]["worldID"] = json!("world");
        fixture
            .execute(
                "UPDATE jobs SET data=?1 WHERE id='core'",
                [core.to_string()],
            )
            .unwrap();
        let accepted = call(
            &mut fixture,
            "wish_control_command",
            foreign["revision"].as_i64().unwrap(),
            json!({"command":"delegation_authorize","authorizationID":"grant","worldID":"world","residentScope":"resident","allowedSurfaceIDs":["table"]}),
        )
        .unwrap();
        assert_eq!(accepted["archive"]["delegations"][0]["objectID"], "object");
        assert_eq!(accepted["archive"]["delegations"][0]["state"], "pending");
    }
    #[test]
    fn absent_delegations_remain_absent_during_reconcile_and_scope_revocation() {
        let mut fixture = setup();
        let mut a = archive();
        let original = a.clone();
        bind_accepted_delegations(&fixture, &mut a).unwrap();
        assert_eq!(a, original);
        assert!(a.get("delegations").is_none());
        call(
            &mut fixture,
            "wish_control_open",
            0,
            json!({"legacyArchive":a}),
        )
        .unwrap();
        let revoked = call(
            &mut fixture,
            "wish_control_command",
            0,
            json!({"command":"delegation_revoke","worldID":"world","residentScope":"resident"}),
        )
        .unwrap();
        assert_eq!(revoked["revision"], 0);
        assert_eq!(revoked["archive"], original);
        assert!(revoked["archive"].get("delegations").is_none());
    }
    #[test]
    fn unproven_pause_release_has_one_durable_fact_and_never_lifts_user_stop() {
        let mut db = setup();
        let mut legacy = archive();
        legacy["jobs"][0]["autoContinuationPaused"] = json!(true);
        call(
            &mut db,
            "wish_control_open",
            0,
            json!({"legacyArchive":legacy}),
        )
        .unwrap();
        let released = call(
            &mut db,
            "wish_control_discard_unproven_pauses",
            0,
            json!({}),
        )
        .unwrap();
        assert_eq!(
            released["archive"]["jobs"][0]["autoContinuationPaused"],
            false
        );
        let events = released["archive"]["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["kind"], "stateChanged");
        assert!(events[0]["message"]
            .as_str()
            .unwrap()
            .contains("不需要手动解除"));
        assert_eq!(events[0]["acknowledged"], false);
        assert_eq!(
            call(
                &mut db,
                "wish_control_discard_unproven_pauses",
                1,
                json!({})
            )
            .unwrap(),
            released
        );
        let stopped = call(
            &mut db,
            "wish_control_pause",
            1,
            json!({"worldID":"world","residentScope":"resident"}),
        )
        .unwrap();
        let unchanged = call(
            &mut db,
            "wish_control_discard_unproven_pauses",
            2,
            json!({}),
        )
        .unwrap();
        assert_eq!(unchanged, stopped);
        assert_eq!(
            unchanged["archive"]["jobs"][0]["autoContinuationStoppedByUser"],
            true
        );
    }

    #[test]
    fn foundation_uuid_round_trip_preserves_event_identity_without_scope_aliases() {
        let mut db = setup();
        let id = uuid::Uuid::new_v4();
        let a = json!({"authorizations":[],"jobs":[],"events":[{
            "id":id.to_string(),"wishID":"wish","worldID":"World","residentScope":"Scope",
            "objectID":"object","kind":"claimed","acknowledged":false
        }]});
        call(&mut db, "wish_control_open", 0, json!({"legacyArchive":a})).unwrap();
        let mut upper = a.clone();
        upper["events"][0]["id"] = json!(id.to_string().to_uppercase());
        call(&mut db, "wish_control_commit", 0, json!({"archive":upper})).unwrap();
        let mut foreign = upper.clone();
        foreign["events"][0]["id"] = json!(uuid::Uuid::new_v4().to_string());
        assert_eq!(
            call(
                &mut db,
                "wish_control_commit",
                1,
                json!({"archive":foreign})
            )
            .unwrap_err(),
            "wish_control_transition_rejected"
        );
        let mut scope_alias = upper;
        scope_alias["events"][0]["worldID"] = json!("world");
        assert_eq!(
            call(
                &mut db,
                "wish_control_commit",
                1,
                json!({"archive":scope_alias})
            )
            .unwrap_err(),
            "wish_control_transition_rejected"
        );
        assert!(!uuid_value_equal(&json!("opaque-A"), &json!("opaque-a")));
    }

    #[test]
    fn import_is_hashed_idempotent_and_never_overwrites_authority() {
        let mut db = setup();
        let a = archive();
        let hash = format!("{:x}", Sha256::digest(encode(&a).unwrap().as_bytes()));
        call(
            &mut db,
            "wish_control_open",
            0,
            json!({"legacyArchive":a,"importSHA256":hash}),
        )
        .unwrap();
        assert_eq!(
            call(
                &mut db,
                "wish_control_open",
                0,
                json!({"legacyArchive":archive(),"importSHA256":hash})
            )
            .unwrap()["revision"],
            0
        );
        let mut changed = archive();
        changed["jobs"][0]["name"] = json!("changed");
        assert_eq!(
            call(
                &mut db,
                "wish_control_open",
                0,
                json!({"legacyArchive":changed})
            ),
            Err("wish_control_import_conflict")
        );
        assert_eq!(
            call(&mut db, "wish_control_read", 0, json!({})).unwrap()["archive"],
            archive()
        );
    }
    #[test]
    fn protected_candidate_cannot_claim_unpause_or_ack() {
        let mut db = setup();
        call(
            &mut db,
            "wish_control_open",
            0,
            json!({"legacyArchive":archive()}),
        )
        .unwrap();
        for (key, value) in [
            ("stage", json!("claimed")),
            ("autoContinuationPaused", json!(false)),
            ("continuationResumeAuthorizationIDs", json!(["fake"])),
        ] {
            let mut a = archive();
            a["jobs"][0][key] = value;
            assert_eq!(
                call(&mut db, "wish_control_commit", 0, json!({"archive":a})),
                Err("wish_control_transition_rejected")
            );
        }
        assert_eq!(
            call(
                &mut db,
                "wish_control_claim",
                0,
                json!({"wishID":"wish","worldID":"world","residentScope":"resident","outputAvailable":true})
            ),
            Err("wish_control_not_ready")
        );
    }
    #[test]
    fn pause_persists_and_only_real_current_human_run_can_resume_once() {
        let mut db = setup();
        call(
            &mut db,
            "wish_control_open",
            0,
            json!({"legacyArchive":archive()}),
        )
        .unwrap();
        let p = call(
            &mut db,
            "wish_control_pause",
            0,
            json!({"worldID":"world","residentScope":"resident"}),
        )
        .unwrap();
        assert_eq!(
            p["archive"]["jobs"][0]["autoContinuationStoppedByUser"],
            true
        );
        let resume = json!({"wishID":"wish","worldID":"world","residentScope":"resident","authorizationID":"human"});
        assert_eq!(
            call(&mut db, "wish_control_resume", 1, resume.clone()),
            Err("wish_control_resume_unauthorized")
        );
        db.execute("INSERT INTO agent_loop_human_messages(world,scope,message,input_ref,state,event,run,session) VALUES('world','resident','message','input','claimed','event','human','session')",[]).unwrap();
        let r = call(&mut db, "wish_control_resume", 1, resume.clone()).unwrap();
        assert_eq!(r["archive"]["jobs"][0]["autoContinuationPaused"], false);
        let repeated = call(&mut db, "wish_control_resume", 2, resume.clone()).unwrap();
        assert_eq!(
            repeated, r,
            "retry must not write a revision, event or delegation"
        );
        db.execute(
            "UPDATE agent_loop_human_messages SET state='finished' WHERE run='human'",
            [],
        )
        .unwrap();
        assert_eq!(
            call(&mut db, "wish_control_resume", 2, resume.clone()),
            Err("wish_control_resume_unauthorized")
        );
        db.execute(
            "UPDATE agent_loop_human_messages SET state='claimed' WHERE run='human'",
            [],
        )
        .unwrap();
        let stopped = call(
            &mut db,
            "wish_control_pause",
            2,
            json!({"worldID":"world","residentScope":"resident"}),
        )
        .unwrap();
        assert_eq!(stopped["revision"], 3);
        assert_eq!(
            call(&mut db, "wish_control_resume", 3, resume),
            Err("wish_control_resume_unauthorized")
        );
        assert_eq!(
            call(
                &mut db,
                "wish_control_pause",
                0,
                json!({"worldID":"world","residentScope":"resident"})
            ),
            Err("wish_control_revision_conflict")
        );
    }
    #[test]
    fn new_session_invalidates_old_writer_without_replaying_effects() {
        let mut db = setup();
        call(&mut db, "wish_control_open", 0, json!({})).unwrap();
        request(
            &mut db,
            "wish_control_open",
            &json!({"ownerID":"owner","hostSessionID":"new"}),
        )
        .unwrap();
        assert_eq!(
            call(
                &mut db,
                "wish_control_commit",
                0,
                json!({"archive":{"authorizations":[],"jobs":[],"events":[]}})
            ),
            Err("wish_control_stale_session")
        );
    }
    #[test]
    fn legacy_orphan_remains_visible_but_cannot_gain_claim_or_retry_permission() {
        let mut db = setup();
        let mut old = archive();
        old["authorizations"] = json!([]);
        old["jobs"][0]["stage"] = json!("submissionUncertain");
        old["unreadableJobs"] = json!([{"rawJSON":"{\"id\":\"broken\"}","reason":"missing field"}]);
        let opened = call(
            &mut db,
            "wish_control_open",
            0,
            json!({"legacyArchive":old}),
        )
        .unwrap();
        assert_eq!(opened["archive"], old);
        let committed = call(&mut db, "wish_control_commit", 0, json!({"archive":old})).unwrap();
        assert_eq!(committed["archive"], old);
        let p = json!({"wishID":"wish","worldID":"world","residentScope":"resident"});
        assert_eq!(
            call(&mut db, "wish_control_claim", 1, p.clone()),
            Err("wish_control_unauthorized")
        );
        assert_eq!(
            call(&mut db, "wish_control_retry_authorize", 1, p),
            Err("wish_control_unauthorized")
        );
    }
    #[test]
    fn acknowledgement_requires_actual_bound_message_and_agent_consumption() {
        let mut db = setup();
        let mut a = archive();
        a["events"] = json!([{"id":"event","wishID":"wish","worldID":"world","residentScope":"resident","objectID":"object","kind":"outputReady","acknowledged":false}]);
        call(&mut db, "wish_control_open", 0, json!({"legacyArchive":a})).unwrap();
        let p = json!({"eventID":"event","worldID":"world","residentScope":"resident"});
        assert_eq!(
            call(&mut db, "wish_control_event_ack", 0, p.clone()),
            Err("wish_control_not_published")
        );
        db.execute("INSERT INTO jobs(id,data) VALUES('core','{}')", [])
            .unwrap();
        db.execute("INSERT INTO messages(id,task_id,world_id,resident_scope,kind,payload) VALUES('event','core','world','resident','wish.outputReady',?1)",[json!({"wish_id":"wish","object_id":"object"}).to_string()]).unwrap();
        assert_eq!(
            call(&mut db, "wish_control_event_ack", 0, p.clone()),
            Err("wish_control_not_published")
        );
        db.execute("INSERT INTO message_acks VALUES('event','agent')", [])
            .unwrap();
        assert_eq!(
            call(&mut db, "wish_control_event_ack", 0, p).unwrap()["archive"]["events"][0]
                ["acknowledged"],
            true
        );
    }
    #[test]
    fn claim_reverifies_actual_private_artifact_and_cannot_replay_missing_or_corrupt_output() {
        use base64::Engine;
        let mut db = setup();
        let bytes = base64::engine::general_purpose::STANDARD
            .decode("Z2xURgIAAAAYAAAABAAAAEpTT057fSAg")
            .unwrap();
        let path = db.root.join("core.glb");
        crate::files::publish(&path, &bytes).unwrap();
        let mut a = archive();
        a["jobs"][0]["modelPath"] = json!(path.to_string_lossy());
        let core = json!({"job":{"id":"core","name":"fixture","endpoint":"https://example.invalid","imagePath":"unused","imageSHA256":"0".repeat(64),"heightMeters":0.5,"source":{"author":"fixture","license":"CC0"},"idempotencyKey":"core","receipt":{"state":"completed","result":{"inspection":{"bytes":bytes.len(),"sha256":crate::model::digest(&bytes)}}},"localModelPath":path.to_string_lossy(),"context":{"worldID":"world","residentScope":"resident"}},"attempted":true});
        db.execute(
            "INSERT INTO jobs(id,data) VALUES('core',?1)",
            [core.to_string()],
        )
        .unwrap();
        call(&mut db, "wish_control_open", 0, json!({"legacyArchive":a})).unwrap();
        let p = json!({"wishID":"wish","worldID":"world","residentScope":"resident","observation":collection_observation(&mut db)});
        crate::files::publish(&path, b"corrupt").unwrap();
        assert_eq!(
            call(&mut db, "wish_control_claim", 0, p.clone()),
            Err("wish_control_not_ready")
        );
        #[cfg(unix)]
        {
            let target = db.root.join("other.glb");
            crate::files::publish(&target, &bytes).unwrap();
            std::fs::remove_file(&path).unwrap();
            std::os::unix::fs::symlink(&target, &path).unwrap();
            assert_eq!(
                call(&mut db, "wish_control_claim", 0, p.clone()),
                Err("wish_control_not_ready")
            );
            std::fs::remove_file(&path).unwrap();
        }
        crate::files::publish(&path, &bytes).unwrap();
        let mut missing = p.clone();
        missing.as_object_mut().unwrap().remove("observation");
        assert_eq!(
            call(&mut db, "wish_control_claim", 0, missing),
            Err("wish_control_not_at_machine")
        );
        for (key, value) in [
            ("objectID", json!("foreign-output")),
            ("phase", json!("enter")),
            ("activityRequestID", json!("old-run")),
            ("activityGeneration", json!(999)),
            ("phaseGeneration", json!(999)),
            ("activityHostSessionID", json!("old-host")),
            ("distanceMeters", json!(0.251)),
            ("outputAvailable", json!(false)),
        ] {
            let mut stale = p.clone();
            stale["observation"][key] = value;
            assert_eq!(
                call(&mut db, "wish_control_claim", 0, stale),
                Err("wish_control_not_at_machine"),
                "field {key}"
            );
        }
        let r = call(&mut db, "wish_control_claim", 0, p.clone()).unwrap();
        assert_eq!(r["archive"]["jobs"][0]["stage"], "claimed");
        assert_eq!(r["archive"]["events"].as_array().unwrap().len(), 1);
        // A later retry returns the same durable claim without issuing another effect/event.
        let r = call(&mut db, "wish_control_claim", 1, p).unwrap();
        assert_eq!(r["archive"]["events"].as_array().unwrap().len(), 1);
    }
}
