//! Local stage video catalog, bindings and sequence authority. Trusted host UI
//! only; AVQueuePlayer/codec and file-selection remain native evidence leaves.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS stage_video_state(scope TEXT PRIMARY KEY,revision INTEGER NOT NULL,payload TEXT NOT NULL,imported INTEGER NOT NULL DEFAULT 0);CREATE TABLE IF NOT EXISTS stage_video_requests(scope TEXT NOT NULL,request_id TEXT NOT NULL,digest TEXT NOT NULL,response TEXT NOT NULL,PRIMARY KEY(scope,request_id));").map_err(|_|"storage_unavailable")
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 16_384)
        .ok_or("stage_video_invalid_input")
}
fn empty() -> Value {
    json!({"assets":[],"bindings":{},"selectedAssetID":null,"enabled":false,"mode":"loop","brightness":0.68,
        "rankedIDs":[],"temporaryBoundTrackID":null,"pendingBoundVideo":null,
        "playback":{"hostSessionID":null,"generation":0,"queue":[],"active":false,"paused":false},"pendingAction":null})
}
fn load(c: &Connection, scope: &str) -> Result<(u64, Value, bool)> {
    let row: Option<(u64, String, bool)> = c
        .query_row(
            "SELECT revision,payload,imported FROM stage_video_state WHERE scope=?1",
            [scope],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    match row {
        Some((rev, raw, imported)) => Ok((
            rev,
            serde_json::from_str(&raw).map_err(|_| "stage_video_invalid_state")?,
            imported,
        )),
        None => Ok((0, empty(), false)),
    }
}
fn view(revision: u64, state: &Value) -> Value {
    json!({"revision":revision,"state":state})
}
pub fn read(c: &Connection, input: &Value) -> Result<Value> {
    let scope = text(input, "scope")?;
    let (rev, state, _) = load(c, scope)?;
    Ok(view(rev, &state))
}
fn asset_ids(s: &Value) -> Vec<String> {
    s["assets"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|v| v["id"].as_str().map(str::to_owned))
        .collect()
}
fn has(s: &Value, id: &str) -> bool {
    asset_ids(s).iter().any(|v| v == id)
}
fn assets(raw: &Value) -> Result<Vec<Value>> {
    let values = raw
        .as_array()
        .filter(|a| a.len() <= 10_000)
        .ok_or("stage_video_invalid_input")?;
    let mut result = Vec::new();
    for v in values {
        let id = text(v, "id")?;
        let url = reqwest::Url::parse(text(v, "url")?).map_err(|_| "stage_video_invalid_input")?;
        if url.scheme() != "file"
            || url.query().is_some()
            || url.fragment().is_some()
            || url
                .to_file_path()
                .ok()
                .and_then(|p| p.to_str().map(str::to_owned))
                .as_deref()
                != Some(id)
        {
            return Err("stage_video_invalid_input");
        }
        text(v, "displayName")?;
        if !v["tags"].as_array().is_some_and(|a| {
            a.iter()
                .all(|v| v.as_str().is_some_and(|s| s.len() <= 1024))
        }) {
            return Err("stage_video_invalid_input");
        }
        if !result.iter().any(|p: &Value| p["id"].as_str() == Some(id)) {
            result.push(v.clone());
        }
    }
    Ok(result)
}
fn mode(v: &Value) -> Result<&str> {
    v.as_str()
        .filter(|s| ["once", "loop", "randomSequence"].contains(s))
        .ok_or("stage_video_invalid_input")
}
fn queue(s: &Value) -> Vec<Value> {
    s["playback"]["queue"].as_array().unwrap().clone()
}
fn random_next(current: usize, count: usize) -> usize {
    if count <= 1 {
        return 0;
    }
    let draw = (uuid::Uuid::new_v4().as_u128() % (count - 1) as u128) as usize;
    if draw >= current {
        draw + 1
    } else {
        draw
    }
}
fn entry(id: &str) -> Value {
    json!({"entryID":uuid::Uuid::new_v4().to_string(),"assetID":id})
}
fn action(
    s: &mut Value,
    host: &str,
    kind: &str,
    entries: Vec<Value>,
    play_mode: &str,
) -> Result<()> {
    if !s["pendingAction"].is_null() {
        return Err("stage_video_pending_action");
    }
    let generation = s["playback"]["generation"]
        .as_u64()
        .unwrap()
        .checked_add(1)
        .ok_or("stage_video_invalid_state")?;
    s["pendingAction"] = json!({"actionID":uuid::Uuid::new_v4().to_string(),"hostSessionID":host,
        "generation":generation,"kind":kind,"mode":play_mode,"entries":entries,"executionStatus":"planned"});
    Ok(())
}
fn start(s: &mut Value, host: &str, force_bound: Option<&str>) -> Result<()> {
    let selected = force_bound
        .map(str::to_owned)
        .or_else(|| s["selectedAssetID"].as_str().map(str::to_owned));
    let Some(selected) = selected.filter(|id| has(s, id)) else {
        return action(s, host, "stop", vec![], "once");
    };
    if force_bound.is_none() && s["enabled"] != true {
        return action(s, host, "stop", vec![], "once");
    }
    let play_mode = if force_bound.is_some() {
        "loop"
    } else {
        mode(&s["mode"])?
    }
    .to_owned();
    let mut entries = vec![entry(&selected)];
    if play_mode == "randomSequence" {
        let all = asset_ids(s);
        let ranked: Vec<String> = s["rankedIDs"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|v| {
                v.as_str()
                    .filter(|id| all.iter().any(|x| x == id))
                    .map(str::to_owned)
            })
            .collect();
        let source = if ranked.is_empty() { all } else { ranked };
        let mut current = source.iter().position(|id| id == &selected).unwrap_or(0);
        entries = vec![entry(&source[current])];
        for _ in 1..(source.len() * 2).clamp(4, 12) {
            current = random_next(current, source.len());
            entries.push(entry(&source[current]));
        }
    }
    action(s, host, "replace", entries, &play_mode)
}
fn bound(s: &Value, track: &str) -> Option<String> {
    s["bindings"][track]
        .as_str()
        .filter(|id| has(s, id))
        .map(str::to_owned)
}
fn play_bound(s: &mut Value, host: &str, track: &str) -> Result<()> {
    if let Some(id) = bound(s, track) {
        s["selectedAssetID"] = json!(id);
        s["temporaryBoundTrackID"] = if s["enabled"] == true {
            Value::Null
        } else {
            json!(track)
        };
        s["pendingBoundVideo"] = Value::Null;
        start(s, host, Some(&id))?;
    }
    Ok(())
}
fn rank(s: &Value, cue: &Value) -> Result<Vec<Value>> {
    let mut tags: Vec<&str> = match text(cue, "mood")? {
        "pulse" => vec![
            "neon", "city", "night", "drive", "dance", "霓虹", "城市", "夜", "公路", "舞台",
        ],
        "liquid" => vec![
            "water", "ocean", "rain", "river", "cloud", "水", "海", "雨", "河", "云",
        ],
        "afterglow" => vec![
            "cozy", "wood", "cafe", "sunset", "morning", "温暖", "木屋", "咖啡", "日落", "清晨",
        ],
        _ => return Err("stage_video_invalid_input"),
    };
    tags.extend(match text(cue, "role")? {
        "opener" => vec!["intro", "arrival", "开场", "进入"],
        "build" => vec!["flow", "travel", "流动", "行走"],
        "peak" => vec!["peak", "fast", "高潮", "高能"],
        "cooldown" => vec!["calm", "slow", "安静", "慢"],
        "closer" => vec!["outro", "sleep", "晚安", "结束"],
        _ => return Err("stage_video_invalid_input"),
    });
    let mut rows: Vec<(usize, String)> = s["assets"]
        .as_array()
        .unwrap()
        .iter()
        .map(|a| {
            let name = a["displayName"].as_str().unwrap().to_lowercase();
            let score = tags
                .iter()
                .filter(|t| {
                    name.contains(**t)
                        || a["tags"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .any(|v| v.as_str() == Some(**t))
                })
                .count();
            (score, a["id"].as_str().unwrap().to_owned())
        })
        .collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    Ok(rows.into_iter().map(|(_, id)| json!(id)).collect())
}
fn command(s: &mut Value, input: &Value) -> Result<()> {
    let host = text(input, "hostSessionID")?;
    let op = text(input, "op")?;
    if op == "recoverStopped" {
        let a = &s["pendingAction"];
        let executor = text(input, "executorInstanceID")?;
        if a.is_null()
            || a["actionID"] != input["actionID"]
            || a["generation"] != input["generation"]
            || a["hostSessionID"].as_str() != Some(host)
            || a["executorInstanceID"].as_str() != Some(executor)
            || input["queueEmpty"] != true
            || input["rateZero"] != true
        {
            return Err("stage_video_stale_receipt");
        }
        s["playback"] = json!({"hostSessionID":host,"generation":a["generation"],"queue":[],"active":false,"paused":false,"mode":"once"});
        s["pendingAction"] = Value::Null;
        s["enabled"] = json!(false);
        s["temporaryBoundTrackID"] = Value::Null;
        s["pendingBoundVideo"] = Value::Null;
        return Ok(());
    }
    if op == "claimAction" {
        let a = &s["pendingAction"];
        if a.is_null()
            || a["actionID"] != input["actionID"]
            || a["generation"] != input["generation"]
            || a["hostSessionID"].as_str() != Some(host)
            || a["executionStatus"] != "planned"
        {
            return Err("stage_video_stale_receipt");
        }
        s["pendingAction"]["executionStatus"] = json!("claimed");
        return Ok(());
    }
    if !s["pendingAction"].is_null() {
        return Err("stage_video_pending_action");
    }
    match op {
        "add" => {
            let imported = assets(&input["assets"])?;
            if !imported.is_empty() {
                let first = imported[0]["id"].clone();
                let mut all = s["assets"].as_array().unwrap().clone();
                for a in imported {
                    if !all.iter().any(|v| v["id"] == a["id"]) {
                        all.push(a);
                    }
                }
                s["assets"] = json!(all);
                s["selectedAssetID"] = first;
                s["enabled"] = json!(true);
                start(s, host, None)?;
            }
        }
        "select" | "toggle" => {
            let id = text(input, "assetID")?;
            if !has(s, id) {
                return Err("stage_video_unknown_asset");
            }
            if op == "toggle"
                && s["playback"]["active"] == true
                && s["playback"]["queue"][0]["assetID"].as_str() == Some(id)
            {
                s["enabled"] = json!(false);
                s["temporaryBoundTrackID"] = Value::Null;
                s["pendingBoundVideo"] = Value::Null;
                action(s, host, "stop", vec![], "once")?;
            } else {
                s["selectedAssetID"] = json!(id);
                s["enabled"] = json!(true);
                s["temporaryBoundTrackID"] = Value::Null;
                start(s, host, None)?;
            }
        }
        "remove" => {
            let id = text(input, "assetID")?;
            if !has(s, id) {
                return Err("stage_video_unknown_asset");
            }
            let resume = s["enabled"] == true && s["playback"]["active"] == true;
            s["assets"]
                .as_array_mut()
                .unwrap()
                .retain(|v| v["id"].as_str() != Some(id));
            s["bindings"]
                .as_object_mut()
                .unwrap()
                .retain(|_, v| v.as_str() != Some(id));
            if s["selectedAssetID"].as_str() == Some(id) {
                s["selectedAssetID"] = asset_ids(s).first().map_or(Value::Null, |v| json!(v));
            }
            s["rankedIDs"]
                .as_array_mut()
                .unwrap()
                .retain(|v| v.as_str() != Some(id));
            if resume && !s["selectedAssetID"].is_null() {
                start(s, host, None)?;
            } else {
                action(s, host, "stop", vec![], "once")?;
            }
        }
        "bind" => {
            let id = text(input, "assetID")?;
            let track = text(input, "trackID")?;
            if !has(s, id) {
                return Err("stage_video_unknown_asset");
            }
            s["bindings"][track] = json!(id);
        }
        "unbind" => {
            s["bindings"]
                .as_object_mut()
                .unwrap()
                .remove(text(input, "trackID")?);
        }
        "mode" => {
            s["mode"] = json!(mode(&input["mode"])?);
            s["enabled"] = json!(true);
            s["temporaryBoundTrackID"] = Value::Null;
            if !s["selectedAssetID"].is_null() {
                start(s, host, None)?;
            }
        }
        "brightness" => {
            let b = input["brightness"]
                .as_f64()
                .filter(|v| v.is_finite())
                .ok_or("stage_video_invalid_input")?;
            s["brightness"] = json!(b.clamp(0.15, 1.0));
        }
        "stop" => {
            s["enabled"] = json!(false);
            s["temporaryBoundTrackID"] = Value::Null;
            s["pendingBoundVideo"] = Value::Null;
            action(s, host, "stop", vec![], "once")?;
        }
        "start" => start(s, host, None)?,
        "pause" => action(s, host, "pause", vec![], "once")?,
        "resume" => {
            if s["enabled"] == true || !s["temporaryBoundTrackID"].is_null() {
                if queue(s).is_empty() {
                    start(s, host, None)?;
                } else {
                    action(s, host, "resume", vec![], "once")?;
                }
            }
        }
        "playBound" => play_bound(s, host, text(input, "trackID")?)?,
        "playPending" => {
            if let Some(track) = s["pendingBoundVideo"]["trackID"]
                .as_str()
                .map(str::to_owned)
            {
                play_bound(s, host, &track)?;
            }
        }
        "dismiss" => {
            if input["promptID"].is_null() || input["promptID"] == s["pendingBoundVideo"]["id"] {
                s["pendingBoundVideo"] = Value::Null;
            }
        }
        "cue" => {
            s["rankedIDs"] = json!(rank(s, input)?);
            if let Some(track) = input["trackID"].as_str() {
                s["pendingBoundVideo"] = Value::Null;
                if s["temporaryBoundTrackID"].as_str() != Some(track) {
                    s["temporaryBoundTrackID"] = Value::Null;
                }
                if let Some(id) = bound(s, track) {
                    if s["enabled"] == true {
                        play_bound(s, host, track)?;
                    } else {
                        s["pendingBoundVideo"] = json!({"id":format!("{track}::{id}"),"trackID":track,"trackTitle":input["trackTitle"].as_str().unwrap_or("这首歌"),"assetID":id});
                        action(s, host, "stop", vec![], "once")?;
                    }
                } else if s["enabled"] != true {
                    action(s, host, "stop", vec![], "once")?;
                } else if s["mode"] == "randomSequence" {
                    start(s, host, None)?;
                }
            } else if s["enabled"] == true
                && s["playback"]["active"] == true
                && s["mode"] == "randomSequence"
            {
                start(s, host, None)?;
            }
        }
        "ended" => {
            if s["playback"]["hostSessionID"].as_str() != Some(host)
                || input["generation"] != s["playback"]["generation"]
                || input["entryID"] != s["playback"]["queue"][0]["entryID"]
                || input["entryID"].is_null()
            {
                return Err("stage_video_stale_receipt");
            }
            let play_mode = s["playback"]["mode"].as_str().unwrap_or("once").to_owned();
            if play_mode == "once" {
                s["playback"]["queue"] = json!([]);
                s["playback"]["active"] = json!(false);
            } else if play_mode == "randomSequence" {
                let mut q = queue(s);
                let ended = q.remove(0);
                let ids = asset_ids(s);
                let ranked: Vec<String> = s["rankedIDs"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .filter_map(|v| {
                        v.as_str()
                            .filter(|id| ids.iter().any(|x| x == id))
                            .map(str::to_owned)
                    })
                    .collect();
                let source = if ranked.is_empty() { ids } else { ranked };
                s["playback"]["queue"] = json!(q);
                if !source.is_empty() {
                    let previous = s["playback"]["queue"]
                        .as_array()
                        .unwrap()
                        .last()
                        .unwrap_or(&ended)["assetID"]
                        .as_str()
                        .unwrap();
                    let current = source.iter().position(|id| id == previous).unwrap_or(0);
                    let next = random_next(current, source.len());
                    action(
                        s,
                        host,
                        "append",
                        vec![entry(&source[next])],
                        "randomSequence",
                    )?;
                }
            }
        }
        _ => return Err("stage_video_invalid_input"),
    }
    if !s["pendingAction"].is_null() {
        if let Some(executor) = input.get("executorInstanceID") {
            text(input, "executorInstanceID")?;
            s["pendingAction"]["executorInstanceID"] = executor.clone();
        }
    }
    Ok(())
}
fn receipt(s: &mut Value, input: &Value) -> Result<()> {
    let a = s["pendingAction"].clone();
    if a.is_null()
        || a["executionStatus"] != "claimed"
        || a["actionID"] != input["actionID"]
        || a["generation"] != input["generation"]
        || a["hostSessionID"] != input["hostSessionID"]
    {
        return Err("stage_video_stale_receipt");
    }
    let accepted = input["accepted"]
        .as_bool()
        .ok_or("stage_video_invalid_input")?;
    if accepted {
        match a["kind"].as_str().unwrap() {
            "replace" => {
                s["playback"] = json!({"hostSessionID":a["hostSessionID"],"generation":a["generation"],"queue":a["entries"],"active":true,"paused":false,"mode":a["mode"]});
            }
            "append" => {
                s["playback"]["queue"]
                    .as_array_mut()
                    .unwrap()
                    .extend(a["entries"].as_array().unwrap().iter().cloned());
            }
            "stop" => {
                s["playback"] = json!({"hostSessionID":a["hostSessionID"],"generation":a["generation"],"queue":[],"active":false,"paused":false,"mode":"once"});
            }
            "pause" => s["playback"]["paused"] = json!(true),
            "resume" => {
                s["playback"]["paused"] = json!(false);
                s["playback"]["active"] = json!(true);
            }
            _ => return Err("stage_video_invalid_state"),
        }
    }
    s["pendingAction"] = Value::Null;
    Ok(())
}
pub fn request(c: &Connection, method: &str, input: &Value) -> Result<Value> {
    if method == "stage_video_read" {
        return read(c, input);
    }
    let scope = text(input, "scope")?;
    let request_id = text(input, "requestID")?;
    if scope.len() > 128
        || request_id.len() > 128
        || input["hostSessionID"]
            .as_str()
            .is_some_and(|s| s.is_empty() || s.len() > 128)
    {
        return Err("stage_video_invalid_input");
    }
    let bytes = crate::canonical_json::to_vec(&json!({"method":method,"input":input}))
        .map_err(|_| "stage_video_invalid_input")?;
    let digest = format!("{:x}", Sha256::digest(bytes));
    let tx = c
        .unchecked_transaction()
        .map_err(|_| "storage_unavailable")?;
    let previous: Option<(String, String)> = tx
        .query_row(
            "SELECT digest,response FROM stage_video_requests WHERE scope=?1 AND request_id=?2",
            params![scope, request_id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((old, response)) = previous {
        if old != digest {
            return Err("request_id_conflict");
        }
        let original: Value =
            serde_json::from_str(&response).map_err(|_| "stage_video_invalid_state")?;
        let (current_revision, current, _) = load(&tx, scope)?;
        let mut value = view(current_revision, &current);
        value["replayed"] = json!(true);
        value["replayedActionID"] = input
            .get("actionID")
            .cloned()
            .unwrap_or_else(|| original["state"]["pendingAction"]["actionID"].clone());
        return Ok(value);
    }
    let (rev, mut state, mut imported) = load(&tx, scope)?;
    if input["expectedRevision"].as_u64() != Some(rev) {
        return Err("revision_conflict");
    }
    match method {
        "stage_video_import" => {
            if !imported && rev == 0 {
                let a = assets(&input["assets"])?;
                state["assets"] = json!(a);
                state["mode"] = json!(input["mode"]
                    .as_str()
                    .filter(|m| ["once", "loop", "randomSequence"].contains(m))
                    .unwrap_or("loop"));
                state["brightness"] = json!(input["brightness"]
                    .as_f64()
                    .filter(|v| v.is_finite())
                    .unwrap_or(0.68)
                    .clamp(0.15, 1.0));
                let selected = input["selectedAssetID"]
                    .as_str()
                    .filter(|id| has(&state, id))
                    .map(str::to_owned)
                    .or_else(|| asset_ids(&state).first().cloned());
                state["selectedAssetID"] = selected.map_or(Value::Null, |v| json!(v));
                state["enabled"] = json!(input["enabled"]
                    .as_bool()
                    .unwrap_or(!asset_ids(&state).is_empty()));
                if let Some(bindings) = input["bindings"].as_object() {
                    for (track, id) in bindings {
                        // Legacy bindings survive a temporarily absent file.
                        // New bind commands still require a live known asset.
                        if track.is_empty() || track.len() > 16_384 {
                            return Err("stage_video_invalid_input");
                        }
                        if let Some(id) = id
                            .as_str()
                            .filter(|id| !id.is_empty() && id.len() <= 16_384)
                        {
                            state["bindings"][track] = json!(id);
                        }
                    }
                }
                imported = true;
            }
            imported = true;
        }
        "stage_video_command" => command(&mut state, input)?,
        "stage_video_receipt" => receipt(&mut state, input)?,
        _ => return Err("method_not_found"),
    }
    let revision = rev.checked_add(1).ok_or("stage_video_invalid_state")?;
    let response = view(revision, &state);
    let raw = crate::canonical_json::to_string(&state).map_err(|_| "stage_video_invalid_state")?;
    if raw.len() > 4 * 1024 * 1024 {
        return Err("stage_video_invalid_input");
    }
    let response_raw =
        crate::canonical_json::to_string(&response).map_err(|_| "stage_video_invalid_state")?;
    tx.execute("INSERT INTO stage_video_state(scope,revision,payload,imported)VALUES(?1,?2,?3,?4)ON CONFLICT(scope)DO UPDATE SET revision=excluded.revision,payload=excluded.payload,imported=excluded.imported",params![scope,revision,raw,imported]).map_err(|_|"storage_unavailable")?;
    tx.execute(
        "INSERT INTO stage_video_requests(scope,request_id,digest,response)VALUES(?1,?2,?3,?4)",
        params![scope, request_id, digest, response_raw],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        c
    }
    fn raw_assets() -> Value {
        json!([
        {"id":"/tmp/night.mp4","url":"file:///tmp/night.mp4","displayName":"night neon intro","tags":["night","neon","intro"]},
        {"id":"/tmp/rain.mp4","url":"file:///tmp/rain.mp4","displayName":"rain slow","tags":["rain","slow"]}])
    }
    fn invoke(c: &Connection, method: &str, mut input: Value) -> Result<Value> {
        let revision = read(c, &json!({"scope":"fixture"})).unwrap()["revision"].clone();
        input["scope"] = json!("fixture");
        input["requestID"] = json!(uuid::Uuid::new_v4().to_string());
        input["expectedRevision"] = revision;
        input["hostSessionID"] = json!("actual-host");
        request(c, method, &input)
    }
    fn import(c: &Connection) -> Value {
        invoke(c,"stage_video_import",json!({"assets":raw_assets(),"enabled":true,"mode":"randomSequence","selectedAssetID":"/tmp/night.mp4","bindings":{"song":"/tmp/rain.mp4"}})).unwrap()
    }
    fn settle(c: &Connection, v: &Value) -> Value {
        let a = &v["state"]["pendingAction"];
        invoke(
            c,
            "stage_video_command",
            json!({"op":"claimAction","actionID":a["actionID"],"generation":a["generation"]}),
        )
        .unwrap();
        invoke(
            c,
            "stage_video_receipt",
            json!({"actionID":a["actionID"],"generation":a["generation"],"accepted":true}),
        )
        .unwrap()
    }
    #[test]
    fn unknown_stop_requires_exact_live_executor_and_raw_stopped_facts() {
        let c = db();
        import(&c);
        let planned = invoke(
            &c,
            "stage_video_command",
            json!({"op":"start","executorInstanceID":"live-device"}),
        )
        .unwrap();
        let a = &planned["state"]["pendingAction"];
        let valid = json!({"op":"recoverStopped","actionID":a["actionID"],"generation":a["generation"],"executorInstanceID":"live-device","queueEmpty":true,"rateZero":true});
        for (key, value) in [
            ("executorInstanceID", json!("new-device")),
            ("actionID", json!("wrong")),
            ("generation", json!(999)),
            ("queueEmpty", json!(false)),
            ("rateZero", json!(false)),
        ] {
            let mut wrong = valid.clone();
            wrong[key] = value;
            assert_eq!(
                invoke(&c, "stage_video_command", wrong).unwrap_err(),
                "stage_video_stale_receipt"
            );
            assert_eq!(
                read(&c, &json!({"scope":"fixture"})).unwrap()["state"]["pendingAction"],
                *a
            );
        }
        let mut input = valid;
        input["scope"] = json!("fixture");
        input["hostSessionID"] = json!("actual-host");
        input["requestID"] = json!("verified-stop");
        input["expectedRevision"] = planned["revision"].clone();
        let mut other_host = input.clone();
        other_host["hostSessionID"] = json!("old-host");
        assert_eq!(
            request(&c, "stage_video_command", &other_host).unwrap_err(),
            "stage_video_stale_receipt"
        );
        let stopped = request(&c, "stage_video_command", &input).unwrap();
        assert!(stopped["state"]["pendingAction"].is_null());
        assert_eq!(stopped["state"]["playback"]["active"], false);
        assert_eq!(
            request(&c, "stage_video_command", &input).unwrap()["replayed"],
            true
        );
    }
    #[test]
    fn import_once_binding_and_delete_fallback_are_sql_authority() {
        let c = db();
        import(&c);
        let again = invoke(
            &c,
            "stage_video_import",
            json!({"assets":[],"enabled":false}),
        )
        .unwrap();
        assert_eq!(again["state"]["assets"].as_array().unwrap().len(), 2);
        assert_eq!(again["state"]["enabled"], true);
        let started = invoke(&c, "stage_video_command", json!({"op":"start"})).unwrap();
        let active = settle(&c, &started);
        assert_eq!(
            active["state"]["playback"]["queue"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
        let removed = invoke(
            &c,
            "stage_video_command",
            json!({"op":"remove","assetID":"/tmp/night.mp4"}),
        )
        .unwrap();
        assert_eq!(removed["state"]["selectedAssetID"], "/tmp/rain.mp4");
        assert_eq!(removed["state"]["bindings"]["song"], "/tmp/rain.mp4");
        assert_eq!(
            removed["state"]["pendingAction"]["entries"][0]["assetID"],
            "/tmp/rain.mp4"
        );
        settle(&c, &removed);
        let removed = invoke(
            &c,
            "stage_video_command",
            json!({"op":"remove","assetID":"/tmp/rain.mp4"}),
        )
        .unwrap();
        assert!(removed["state"]["bindings"]["song"].is_null());
        assert_eq!(removed["state"]["pendingAction"]["kind"], "stop");
    }
    #[test]
    fn legacy_orphan_binding_survives_missing_file_and_real_readd() {
        let c = db();
        let imported = invoke(
            &c,
            "stage_video_import",
            json!({"assets":[],"bindings":{"old-song":"/tmp/rain.mp4"}}),
        )
        .unwrap();
        assert_eq!(imported["state"]["bindings"]["old-song"], "/tmp/rain.mp4");
        assert!(bound(&imported["state"], "old-song").is_none());
        assert_eq!(
            invoke(
                &c,
                "stage_video_command",
                json!({"op":"bind","assetID":"/tmp/rain.mp4","trackID":"new-song"})
            ),
            Err("stage_video_unknown_asset")
        );
        let added = invoke(
            &c,
            "stage_video_command",
            json!({"op":"add","assets":[raw_assets()[1]]}),
        )
        .unwrap();
        assert_eq!(
            bound(&added["state"], "old-song"),
            Some("/tmp/rain.mp4".to_owned())
        );
        settle(&c, &added);
        let removed = invoke(
            &c,
            "stage_video_command",
            json!({"op":"remove","assetID":"/tmp/rain.mp4"}),
        )
        .unwrap();
        assert!(removed["state"]["bindings"]["old-song"].is_null());
    }
    #[test]
    fn claimed_actions_receipts_and_replays_never_repeat_native_effects() {
        let c = db();
        import(&c);
        let rev = read(&c, &json!({"scope":"fixture"})).unwrap()["revision"].clone();
        let input = json!({"scope":"fixture","requestID":"command-lost-reply","expectedRevision":rev,"hostSessionID":"actual-host","op":"start"});
        let fresh = request(&c, "stage_video_command", &input).unwrap();
        let replay = request(&c, "stage_video_command", &input).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(
            fresh["state"]["pendingAction"],
            replay["state"]["pendingAction"]
        );
        let action = &fresh["state"]["pendingAction"];
        assert_eq!(
            invoke(
                &c,
                "stage_video_receipt",
                json!({"actionID":action["actionID"],"generation":action["generation"],"accepted":true})
            ),
            Err("stage_video_stale_receipt")
        );
        let claim = json!({"scope":"fixture","requestID":"claim-lost-reply","expectedRevision":fresh["revision"],"hostSessionID":"actual-host","op":"claimAction","actionID":action["actionID"],"generation":action["generation"]});
        request(&c, "stage_video_command", &claim).unwrap();
        assert_eq!(
            request(&c, "stage_video_command", &claim).unwrap()["replayed"],
            true
        );
        assert_eq!(
            invoke(&c, "stage_video_command", json!({"op":"start"})),
            Err("stage_video_pending_action")
        );
        let receipt = json!({"scope":"fixture","requestID":"receipt-lost-reply","expectedRevision":read(&c,&json!({"scope":"fixture"})).unwrap()["revision"],"hostSessionID":"actual-host","actionID":action["actionID"],"generation":action["generation"],"accepted":true});
        let accepted = request(&c, "stage_video_receipt", &receipt).unwrap();
        let repeated = request(&c, "stage_video_receipt", &receipt).unwrap();
        assert_eq!(accepted["revision"], repeated["revision"]);
        assert_eq!(repeated["replayed"], true);
        assert_eq!(
            accepted["state"]["playback"]["queue"]
                .as_array()
                .unwrap()
                .len(),
            4
        );
        let brightness = invoke(
            &c,
            "stage_video_command",
            json!({"op":"brightness","brightness":0.9}),
        )
        .unwrap();
        let current_replay = request(&c, "stage_video_command", &input).unwrap();
        assert_eq!(current_replay["revision"], brightness["revision"]);
        assert!(current_replay["state"]["pendingAction"].is_null());
        assert_eq!(current_replay["state"]["brightness"], json!(0.9));
        assert_eq!(current_replay["replayedActionID"], action["actionID"]);
        let mut changed = receipt;
        changed["accepted"] = json!(false);
        assert_eq!(
            request(&c, "stage_video_receipt", &changed),
            Err("request_id_conflict")
        );
    }
    #[test]
    fn random_unique_slots_and_exact_terminal_identity_do_not_skip_new_queue() {
        let c = db();
        import(&c);
        let started = invoke(&c, "stage_video_command", json!({"op":"start"})).unwrap();
        let active = settle(&c, &started);
        let p = &active["state"]["playback"];
        let q = p["queue"].as_array().unwrap();
        for pair in q.windows(2) {
            assert_ne!(pair[0]["assetID"], pair[1]["assetID"]);
            assert_ne!(pair[0]["entryID"], pair[1]["entryID"]);
        }
        assert_eq!(
            invoke(
                &c,
                "stage_video_command",
                json!({"op":"ended","entryID":q[1]["entryID"],"generation":p["generation"]})
            ),
            Err("stage_video_stale_receipt")
        );
        let next = invoke(
            &c,
            "stage_video_command",
            json!({"op":"ended","entryID":q[0]["entryID"],"generation":p["generation"]}),
        )
        .unwrap();
        assert_eq!(next["state"]["pendingAction"]["kind"], "append");
        let next = settle(&c, &next);
        assert_eq!(
            next["state"]["playback"]["queue"].as_array().unwrap().len(),
            4
        );
        assert_eq!(
            invoke(
                &c,
                "stage_video_command",
                json!({"op":"ended","entryID":q[0]["entryID"],"generation":p["generation"]})
            ),
            Err("stage_video_stale_receipt")
        );
    }
    #[test]
    fn cue_rank_bound_prompt_temporary_permission_and_stop_preserve_original_rules() {
        let c = db();
        import(&c);
        let stop = invoke(&c, "stage_video_command", json!({"op":"stop"})).unwrap();
        settle(&c, &stop);
        let cue=invoke(&c,"stage_video_command",json!({"op":"cue","mood":"pulse","role":"opener","trackID":"song","trackTitle":"actual song"})).unwrap();
        assert_eq!(cue["state"]["rankedIDs"][0], "/tmp/night.mp4");
        assert_eq!(
            cue["state"]["pendingBoundVideo"]["assetID"],
            "/tmp/rain.mp4"
        );
        settle(&c, &cue);
        let temporary = invoke(&c, "stage_video_command", json!({"op":"playPending"})).unwrap();
        assert_eq!(temporary["state"]["enabled"], false);
        assert_eq!(temporary["state"]["temporaryBoundTrackID"], "song");
        assert_eq!(temporary["state"]["pendingAction"]["mode"], "loop");
        settle(&c, &temporary);
        let next = invoke(
            &c,
            "stage_video_command",
            json!({"op":"cue","mood":"liquid","role":"cooldown","trackID":"another"}),
        )
        .unwrap();
        assert!(next["state"]["temporaryBoundTrackID"].is_null());
        assert_eq!(next["state"]["pendingAction"]["kind"], "stop");
    }
}
