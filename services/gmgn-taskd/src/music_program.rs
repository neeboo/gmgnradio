//! DJ planning and program lifecycle authority. Native supplies music provider
//! facts and trusted runner configuration, never a candidate ProgramPlan.
use crate::{model::Result, music_program_rules as rules, store::Database};
use gmgn_agent_runtime::{
    oneshot_transport::{self, OneshotConfig},
    CancellationToken,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{collections::BTreeMap, path::PathBuf, time::Duration};

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS music_dj_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1),revision INTEGER NOT NULL,payload TEXT NOT NULL);
        INSERT OR IGNORE INTO music_dj_state VALUES(1,0,'{}');
        CREATE TABLE IF NOT EXISTS music_dj_owned(id TEXT PRIMARY KEY,payload TEXT NOT NULL);").map_err(|_|"storage_unavailable")
}
fn encode(v: &Value) -> Result<String> {
    crate::canonical_json::to_string(v).map_err(|_| "music_program_invalid_input")
}
fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 4096)
        .ok_or("music_program_invalid_input")
}
fn now(c: &Connection) -> Result<String> {
    c.query_row("SELECT strftime('%Y-%m-%dT%H:%M:%SZ','now')", [], |r| {
        r.get(0)
    })
    .map_err(|_| "music_program_clock_unavailable")
}
fn strings(v: &Value) -> bool {
    v.as_array().is_some_and(|a| {
        a.len() <= 10000
            && a.iter()
                .all(|s| s.as_str().is_some_and(|s| s.len() <= 4096))
    })
}
fn validate_brief(v: &Value) -> Result<()> {
    text(v, "id")?;
    if !v["targetDuration"].as_f64().is_some_and(f64::is_finite)
        || !strings(&v["moodTags"])
        || !strings(&v["blockedTrackIDs"])
        || !strings(&v["recentlySkippedTrackIDs"])
        || !v["energyArc"].as_array().is_some_and(|a| {
            a.len() <= 10000 && a.iter().all(|v| v.as_f64().is_some_and(f64::is_finite))
        })
        || !matches!(
            v["conversationMode"].as_str(),
            Some("quiet" | "ambient" | "conversational")
        )
    {
        return Err("music_program_invalid_input");
    }
    if let Some(s) = v.get("immediateUserInstruction").filter(|v| !v.is_null()) {
        if !s.as_str().is_some_and(|s| s.len() <= 65536) {
            return Err("music_program_invalid_input");
        }
    }
    Ok(())
}
fn validate_candidate(v: &Value) -> Result<()> {
    for key in ["id", "providerID"] {
        text(v, key)?;
    }
    for key in ["title", "artist"] {
        if !v[key].as_str().is_some_and(|s| s.len() <= 4096) {
            return Err("music_program_invalid_input");
        }
    }
    if !matches!(v["source"].as_str(), Some("localLibrary" | "streaming"))
        || v["isPlayable"].as_bool().is_none()
        || !strings(&v["moodTags"])
        || !strings(&v["genres"])
        || ["duration", "matchScore", "userAffinity", "energy"]
            .iter()
            .any(|key| !v[*key].as_f64().is_some_and(f64::is_finite))
    {
        return Err("music_program_invalid_input");
    }
    for key in ["canonicalID", "album", "artworkURL"] {
        if let Some(value) = v.get(key).filter(|v| !v.is_null()) {
            if !value.as_str().is_some_and(|s| s.len() <= 16384) {
                return Err("music_program_invalid_input");
            }
        }
    }
    if v.get("releaseYear")
        .is_some_and(|v| !v.is_null() && v.as_i64().is_none())
    {
        return Err("music_program_invalid_input");
    }
    Ok(())
}
pub(crate) fn owned(c: &Connection, id: &str) -> Result<Value> {
    let value: String = c
        .query_row(
            "SELECT payload FROM music_dj_owned WHERE id=?1",
            [id],
            |r| r.get(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?
        .ok_or("music_program_not_prepared")?;
    serde_json::from_str(&value).map_err(|_| "music_program_invalid_archive")
}
fn save(c: &Connection, plan: &Value, index: &Value, pending: bool) -> Result<()> {
    let id = text(&plan["brief"], "id")?;
    let date = now(c)?;
    let saved = json!({"plan":plan,"activeSlotIndex":index,"updatedAt":date});
    c.execute("INSERT INTO music_programs VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at,pending=excluded.pending,payload=excluded.payload",params![id,date,pending,encode(&saved)?]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn state(c: &Connection) -> Result<(u64, Value)> {
    let (r, p): (u64, String) = c
        .query_row(
            "SELECT revision,payload FROM music_dj_state WHERE singleton=1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .map_err(|_| "storage_unavailable")?;
    Ok((
        r,
        serde_json::from_str(&p).map_err(|_| "music_program_invalid_archive")?,
    ))
}
fn view(c: &mut Connection) -> Result<Value> {
    let (mut revision, mut state) = state(c)?;
    if state["pendingLoaded"] != true {
        let raw:Option<String>=c.query_row("SELECT payload FROM music_programs WHERE pending=1 ORDER BY updated_at DESC,id LIMIT 1",[],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
        if let Some(raw) = raw {
            let saved: Value =
                serde_json::from_str(&raw).map_err(|_| "music_program_invalid_archive")?;
            state["pendingPlan"] = saved["plan"].clone();
        }
        state["pendingLoaded"] = json!(true);
        revision = revision
            .checked_add(1)
            .ok_or("music_program_revision_exhausted")?;
        c.execute(
            "UPDATE music_dj_state SET revision=?1,payload=?2 WHERE singleton=1",
            params![revision, encode(&state)?],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    let mut result = crate::music::request(c, "music_program_list", json!({}))?;
    result["revision"] = json!(revision);
    for key in ["plan", "pendingPlan", "activeSlotIndex"] {
        if let Some(v) = state.get(key) {
            result[key] = v.clone();
        }
    }
    Ok(result)
}
pub fn request(c: &mut Connection, method: &str, p: Value) -> Result<Value> {
    if serde_json::to_vec(&p)
        .map_err(|_| "music_program_invalid_input")?
        .len()
        > 4 * 1024 * 1024
    {
        return Err("music_capacity_exceeded");
    }
    match method {
        "music_dj_playlist_plan" => {
            let id = text(&p, "playlistID")?;
            let payload: String = c
                .query_row(
                    "SELECT payload FROM music_playlists WHERE id=?1",
                    [id],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|_| "storage_unavailable")?
                .ok_or("music_playlist_not_found")?;
            let playlist: Value =
                serde_json::from_str(&payload).map_err(|_| "music_program_invalid_archive")?;
            let plan = rules::playlist_plan(&playlist, &now(c)?)?;
            c.execute("INSERT INTO music_dj_owned VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",params![id,encode(&plan)?]).map_err(|_|"storage_unavailable")?;
            Ok(plan)
        }
        "music_dj_candidates" => {
            let mut knowledge = p["knowledge"]
                .as_array()
                .filter(|v| v.len() <= 10000)
                .ok_or("music_program_invalid_input")?
                .clone();
            // Use SQLite's UTC date parsing and authority clock, not host date arithmetic.
            for track in &mut knowledge {
                for key in ["lastPlayedAt", "lastSkippedAt"] {
                    if let Some(date) = track[key].as_str() {
                        let seconds: Option<f64> = c
                            .query_row("SELECT CAST(strftime('%s',?1) AS REAL)", [date], |r| {
                                r.get(0)
                            })
                            .map_err(|_| "music_program_invalid_input")?;
                        track[key] = json!(seconds.ok_or("music_program_invalid_input")?);
                    }
                }
            }
            let seconds: f64 = c
                .query_row("SELECT CAST(strftime('%s','now') AS REAL)", [], |r| {
                    r.get(0)
                })
                .map_err(|_| "music_program_clock_unavailable")?;
            rules::candidate_pool(&knowledge, &p["brief"], seconds)
        }
        "music_dj_discovery" => {
            if p["dailyBrief"] == true {
                let instruction = p
                    .get("instruction")
                    .filter(|v| !v.is_null())
                    .map(|v| {
                        v.as_str()
                            .filter(|s| s.len() <= 65536)
                            .ok_or("music_program_invalid_input")
                    })
                    .transpose()?;
                let hour: u32 = c
                    .query_row(
                        "SELECT CAST(strftime('%H','now','localtime') AS INTEGER)",
                        [],
                        |r| r.get(0),
                    )
                    .map_err(|_| "music_program_clock_unavailable")?;
                let brief = rules::daily_brief(
                    hour,
                    &format!("program-{}", uuid::Uuid::new_v4()),
                    instruction,
                )?;
                return Ok(json!({"brief": brief}));
            }
            rules::discovery(&p["brief"])
        }
        "music_dj_read" => view(c),
        "music_dj_command" => {
            let expected = p["expectedRevision"]
                .as_u64()
                .ok_or("music_program_invalid_revision")?;
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            let (revision, mut state) = state(&tx)?;
            if expected != revision {
                return Err("music_program_revision_conflict");
            }
            let mut selected = None;
            match text(&p, "op")? {
                "publish" | "draft" => {
                    let plan = owned(&tx, text(&p, "programID")?)?;
                    if p["op"] == "draft" {
                        state["pendingPlan"] = plan.clone();
                        save(&tx, &plan, &Value::Null, true)?;
                    } else {
                        state["plan"] = plan.clone();
                        state["activeSlotIndex"] = Value::Null;
                        if state["pendingPlan"]["brief"]["id"] == plan["brief"]["id"] {
                            state.as_object_mut().unwrap().remove("pendingPlan");
                        }
                        save(&tx, &plan, &Value::Null, false)?;
                    }
                    selected = Some(plan);
                }
                "take_pending" => {
                    selected = state.get("pendingPlan").cloned();
                    state.as_object_mut().unwrap().remove("pendingPlan");
                }
                "activate_slot" => {
                    let index = p["index"].as_i64().ok_or("music_program_invalid_input")?;
                    if let Some(plan) = state.get("plan").cloned() {
                        let count = plan["slots"]
                            .as_array()
                            .ok_or("music_program_invalid_archive")?
                            .len();
                        let active = if index >= 0 && (index as usize) < count {
                            json!(index)
                        } else {
                            Value::Null
                        };
                        state["activeSlotIndex"] = active.clone();
                        save(&tx, &plan, &active, false)?;
                    }
                }
                "select" => {
                    let id = text(&p, "programID")?;
                    let raw: Option<String> = tx
                        .query_row(
                            "SELECT payload FROM music_programs WHERE id=?1",
                            [id],
                            |r| r.get(0),
                        )
                        .optional()
                        .map_err(|_| "storage_unavailable")?;
                    if let Some(raw) = raw {
                        let saved: Value = serde_json::from_str(&raw)
                            .map_err(|_| "music_program_invalid_archive")?;
                        state["plan"] = saved["plan"].clone();
                        state["activeSlotIndex"] = Value::Null;
                        selected = Some(saved["plan"].clone());
                        if state["pendingPlan"]["brief"]["id"] == json!(id) {
                            state.as_object_mut().unwrap().remove("pendingPlan");
                        }
                    }
                }
                "restore_latest" => {
                    let raw:Option<String>=tx.query_row("SELECT payload FROM music_programs WHERE pending=0 ORDER BY updated_at DESC,id LIMIT 1",[],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
                    if let Some(raw) = raw {
                        let saved: Value = serde_json::from_str(&raw)
                            .map_err(|_| "music_program_invalid_archive")?;
                        state["plan"] = saved["plan"].clone();
                        state["activeSlotIndex"] = saved["activeSlotIndex"].clone();
                        selected = Some(saved["plan"].clone());
                    }
                }
                "revise" => {
                    let current = state
                        .get("plan")
                        .filter(|v| v["brief"]["id"] == p["programID"])
                        .cloned()
                        .ok_or("music_program_not_active")?;
                    let proposal = owned(&tx, text(&p, "proposalID")?)?;
                    let plan = rules::revise(
                        &current,
                        p["index"].as_i64().ok_or("music_program_invalid_input")?,
                        &proposal,
                        text(&p, "mode")?,
                        &now(&tx)?,
                    )?;
                    tx.execute("INSERT INTO music_dj_owned VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",params![text(&plan["brief"],"id")?,encode(&plan)?]).map_err(|_|"storage_unavailable")?;
                    selected = Some(plan);
                }
                _ => return Err("music_program_invalid_operation"),
            }
            let next = revision
                .checked_add(1)
                .ok_or("music_program_revision_exhausted")?;
            tx.execute(
                "UPDATE music_dj_state SET revision=?1,payload=?2 WHERE singleton=1",
                params![next, encode(&state)?],
            )
            .map_err(|_| "storage_unavailable")?;
            tx.commit().map_err(|_| "storage_unavailable")?;
            let mut v = view(c)?;
            if let Some(plan) = selected {
                v["selectedPlan"] = plan;
            }
            Ok(v)
        }
        _ => Err("unsupported_method"),
    }
}
fn prompt(brief: &Value, candidates: &[Value], host: &str) -> Result<String> {
    let candidates: Vec<_> = candidates
        .iter()
        .take(30)
        .map(|v| {
            let mut item = json!({});
            for key in [
                "id",
                "title",
                "artist",
                "album",
                "duration",
                "userAffinity",
                "energy",
                "moodTags",
                "genres",
                "releaseYear",
            ] {
                if let Some(value) = v.get(key) {
                    item[key] = value.clone();
                }
            }
            item
        })
        .collect();
    let input = serde_json::to_string_pretty(&json!({"brief":brief,"candidates":candidates}))
        .map_err(|_| "music_program_invalid_input")?;
    Ok(format!("{host}\n\n请策划一段完整的电台节目。兼顾用户偏好、能量曲线、艺人间隔和主持衔接。\n只从候选歌曲中选择，按播放顺序给出 5 到 8 个节目位置。\n为节目写一个简短标题和整体方向。每个位置需要说明选择理由、是否在歌前主持、\n与前后内容的转场意图，以及给视觉系统的情绪、色彩、运动和 0 到 1 强度。\n歌曲事实只能使用输入中提供的资料。用户要求少说时，减少主持位置。\n不要调用工具，不要读取文件，只完成节目策划。\n\n{input}"))
}
fn resolve_plan(
    brief: &Value,
    candidates: &[Value],
    output: Option<&str>,
    revision: u64,
    at: &str,
) -> Result<Value> {
    let parsed = output.and_then(|s| serde_json::from_str::<Value>(s).ok());
    let proposal = parsed
        .as_ref()
        .and_then(|p| rules::sanitize_proposal(p, candidates).ok())
        .filter(|p| p["slots"].as_array().is_some_and(|v| !v.is_empty()));
    let preferred: Vec<String> = proposal
        .as_ref()
        .and_then(|p| p["slots"].as_array())
        .map(|slots| {
            slots
                .iter()
                .filter_map(|s| s["track_id"].as_str().map(str::to_owned))
                .collect()
        })
        .unwrap_or_default();
    rules::plan(
        brief,
        candidates,
        &preferred,
        proposal.as_ref(),
        revision,
        at,
    )
}
fn model_projection(raw: &str, candidates: &[Value], mode: &str) -> Result<Value> {
    let value: Value = serde_json::from_str(raw).map_err(|_| "music_program_invalid_response")?;
    if let Ok(proposal) = rules::sanitize_proposal(&value, candidates) {
        let slots = proposal["slots"].as_array().unwrap();
        if !slots.is_empty() {
            return match mode {
                "proposal" => Ok(proposal),
                "ranked" => Ok(
                    json!({"trackIDs": slots.iter().map(|s| s["track_id"].clone()).collect::<Vec<_>>()}),
                ),
                _ => Err("music_program_invalid_input"),
            };
        }
    }
    if mode != "ranked" {
        return Err("music_program_invalid_response");
    }
    let ids = value["track_ids"]
        .as_array()
        .ok_or("music_program_invalid_response")?;
    if ids.iter().any(|v| !v.is_string()) {
        return Err("music_program_invalid_response");
    }
    let known: std::collections::HashSet<&str> =
        candidates.iter().filter_map(|v| v["id"].as_str()).collect();
    let mut seen = std::collections::HashSet::new();
    let ranked: Vec<&str> = ids
        .iter()
        .filter_map(Value::as_str)
        .filter(|id| known.contains(id) && seen.insert(*id))
        .collect();
    if ranked.is_empty() {
        return Err("music_program_invalid_response");
    }
    Ok(json!({"trackIDs": ranked}))
}
#[derive(Clone)]
pub struct ProgramService {
    db: Database,
}
impl ProgramService {
    pub fn new(db: Database) -> Self {
        Self { db }
    }
    pub async fn plan(&self, p: Value) -> Result<Value> {
        if serde_json::to_vec(&p)
            .map_err(|_| "music_program_invalid_input")?
            .len()
            > 4 * 1024 * 1024
        {
            return Err("music_capacity_exceeded");
        }
        let brief = p["brief"].clone();
        validate_brief(&brief)?;
        let discovery = p["discoveryCandidates"]
            .as_array()
            .ok_or("music_program_invalid_input")?;
        let library = p["libraryCandidates"]
            .as_array()
            .ok_or("music_program_invalid_input")?;
        if discovery.len() + library.len() > 10000 {
            return Err("music_capacity_exceeded");
        }
        for candidate in discovery.iter().chain(library) {
            validate_candidate(candidate)?;
        }
        let prepared = rules::prepare(&brief, discovery, library)?;
        let candidates = prepared["candidates"].as_array().unwrap().clone();
        let host = p["hostPrompt"].as_str().unwrap_or("");
        if host.len() > 65536 {
            return Err("music_program_invalid_input");
        }
        let input = prompt(&brief, &candidates, host)?;
        if let Some(mode) = p.get("outputMode") {
            let mode = mode
                .as_str()
                .filter(|m| matches!(*m, "ranked" | "proposal"))
                .ok_or("music_program_invalid_input")?;
            return model_projection(&self.execute(&p, input).await?, &candidates, mode);
        }
        // The entire runner boundary is Rust-owned. CLI/model failures preserve
        // the deterministic fallback; they never manufacture a model proposal.
        let output = self.execute(&p, input).await.ok();
        self.db.call(move |s|{
            let tx=s.connection.transaction().map_err(|_|"storage_unavailable")?;
            let previous:Option<String>=tx.query_row("SELECT payload FROM music_dj_owned WHERE id=?1",[text(&brief,"id")?],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;
            let revision=previous.and_then(|s|serde_json::from_str::<Value>(&s).ok()).and_then(|v|v["revision"].as_u64()).unwrap_or(0).checked_add(1).ok_or("music_program_revision_exhausted")?;
            let plan=resolve_plan(&brief,&candidates,output.as_deref(),revision,&now(&tx)?)?;
            tx.execute("INSERT INTO music_dj_owned VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",params![text(&brief,"id")?,encode(&plan)?]).map_err(|_|"storage_unavailable")?;
            tx.commit().map_err(|_|"storage_unavailable")?;Ok(plan)
        }).await
    }
    async fn execute(&self, p: &Value, input: String) -> Result<String> {
        let executable = PathBuf::from(text(p, "executable")?);
        if !executable.is_absolute() || p.get("arguments").is_some() {
            return Err("music_program_unsafe_runner");
        }
        let model = p["model"].as_str().filter(|s| !s.is_empty());
        if model.is_some_and(|s| {
            s.len() > 128
                || s.starts_with('-')
                || s.chars().any(|c| c.is_control() || c.is_whitespace())
        }) {
            return Err("music_program_unsafe_runner");
        }
        let environment: BTreeMap<String, String> =
            serde_json::from_value(p.get("environment").cloned().unwrap_or(json!({})))
                .map_err(|_| "music_program_unsafe_runner")?;
        let allowed = [
            "PATH",
            "HOME",
            "TMPDIR",
            "USER",
            "LOGNAME",
            "SHELL",
            "LANG",
            "LC_ALL",
            "OPENAI_API_KEY",
        ];
        if environment
            .iter()
            .any(|(k, v)| !allowed.contains(&k.as_str()) || v.len() > 32768 || v.contains('\0'))
        {
            return Err("music_program_unsafe_runner");
        }
        let directory = self
            .db
            .root
            .join(format!("music-dj-run-{}", uuid::Uuid::new_v4()));
        crate::files::directory(&directory)?;
        struct Scratch(PathBuf);
        impl Drop for Scratch {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _scratch = Scratch(directory.clone());
        let schema = directory.join("show-proposal.schema.json");
        let output = directory.join("show-proposal.json");
        let schema_data = show_schema();
        tokio::fs::write(&schema, encode(&schema_data)?)
            .await
            .map_err(|_| "storage_unavailable")?;
        let mut args = vec!["exec".to_owned()];
        if let Some(model) = model {
            args.extend(["--model".into(), model.into()]);
        }
        args.extend(
            [
                "--ephemeral",
                "--ignore-user-config",
                "--ignore-rules",
                "--sandbox",
                "read-only",
                "--skip-git-repo-check",
                "--color",
                "never",
                "--output-schema",
            ]
            .map(str::to_owned),
        );
        args.push(schema.to_string_lossy().into_owned());
        args.push("--output-last-message".into());
        args.push(output.to_string_lossy().into_owned());
        args.push("-C".into());
        args.push(directory.to_string_lossy().into_owned());
        args.push("-".into());
        let result = oneshot_transport::run(
            OneshotConfig {
                executable,
                arguments: args,
                environment,
                working_directory: Some(directory),
                lifetime: Duration::from_secs(180),
            },
            input,
            CancellationToken::new(),
        )
        .await
        .map_err(|_| "music_program_model_failed")?;
        if !result.status.success() {
            return Err("music_program_model_failed");
        }
        let bytes = crate::files::read(&output, 1024 * 1024)?;
        String::from_utf8(bytes)
            .map(|s| s.trim().to_owned())
            .map_err(|_| "music_program_invalid_proposal")
    }
}
fn show_schema() -> Value {
    let visual = json!({"type":"object","properties":{"mood":{"type":"string"},"palette":{"type":"string"},"motion":{"type":"string"},"intensity":{"type":"number"}},"required":["mood","palette","motion","intensity"],"additionalProperties":false});
    json!({"type":"object","properties":{"title":{"type":"string"},"direction":{"type":"string"},"slots":{"type":"array","minItems":5,"maxItems":8,"items":{"type":"object","properties":{"track_id":{"type":"string"},"selection_reason":{"type":"string"},"should_talk_before":{"type":"boolean"},"transition_intent":{"type":"string"},"visual":visual},"required":["track_id","selection_reason","should_talk_before","transition_intent","visual"],"additionalProperties":false}}},"required":["title","direction","slots"],"additionalProperties":false})
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn original_short_rank_and_proposal_projection_preserve_order_and_filter() {
        let candidates: Vec<Value> = (0..5).map(candidate).collect();
        assert_eq!(
            model_projection(
                r#"{"track_ids":["track3","invented","track1","track3","track2"]}"#,
                &candidates,
                "ranked"
            )
            .unwrap(),
            json!({"trackIDs":["track3","track1","track2"]})
        );
        let raw = json!({"title":"title","direction":"direction","slots":[{"track_id":"track3","selection_reason":"reason","should_talk_before":false,"transition_intent":"transition","visual":{"mood":"calm","palette":"blue","motion":"slow","intensity":0.5}},{"track_id":"track1","selection_reason":"reason","should_talk_before":true,"transition_intent":"transition","visual":{"mood":"calm","palette":"blue","motion":"slow","intensity":0.5}}]}).to_string();
        assert_eq!(
            model_projection(&raw, &candidates, "ranked").unwrap(),
            json!({"trackIDs":["track3","track1"]})
        );
        assert_eq!(
            model_projection(&raw, &candidates, "proposal").unwrap()["slots"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
        assert!(model_projection(r#"{"track_ids":["invented"]}"#, &candidates, "ranked").is_err());
        assert!(model_projection(r#"{"track_ids":[1]}"#, &candidates, "ranked").is_err());
    }
    fn candidate(id: usize) -> Value {
        json!({"id":format!("track{id}"),"providerID":"local","source":"localLibrary","title":format!("Title{id}"),"artist":format!("Artist{id}"),"duration":240,"isPlayable":true,"matchScore":0.8,"userAffinity":0.7,"energy":0.5,"moodTags":["calm"],"genres":[]})
    }
    fn brief(id: &str) -> Value {
        json!({"id":id,"targetDuration":1200,"moodTags":["calm"],"energyArc":[0.3,0.8,0.2],"conversationMode":"ambient","blockedTrackIDs":[],"recentlySkippedTrackIDs":[]})
    }
    fn database() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        crate::music::schema(&c).unwrap();
        schema(&c).unwrap();
        c
    }
    fn stage(c: &Connection, id: &str) -> Value {
        let plan = resolve_plan(
            &brief(id),
            &(0..8).map(candidate).collect::<Vec<_>>(),
            None,
            1,
            "2026-10-08T00:00:00Z",
        )
        .unwrap();
        c.execute(
            "INSERT INTO music_dj_owned VALUES(?1,?2)",
            params![id, encode(&plan).unwrap()],
        )
        .unwrap();
        plan
    }
    fn command(c: &mut Connection, op: &str, extra: Value) -> Result<Value> {
        let revision = view(c).unwrap()["revision"].clone();
        let mut p = extra;
        p["op"] = json!(op);
        p["expectedRevision"] = revision;
        request(c, "music_dj_command", p)
    }
    #[test]
    fn lifecycle_commits_only_owned_plan_and_restores_real_saved_index() {
        let mut c = database();
        let p = stage(&c, "one");
        assert_eq!(
            command(&mut c, "publish", json!({"programID":"forged","plan":p})).unwrap_err(),
            "music_program_not_prepared"
        );
        let published = command(&mut c, "publish", json!({"programID":"one"})).unwrap();
        assert_eq!(published["plan"], p);
        assert!(published["activeSlotIndex"].is_null());
        let active = command(&mut c, "activate_slot", json!({"index":2})).unwrap();
        assert_eq!(active["activeSlotIndex"], 2);
        assert_eq!(active["programs"][0]["activeSlotIndex"], 2);
        let restored = command(&mut c, "restore_latest", json!({})).unwrap();
        assert_eq!(restored["activeSlotIndex"], 2);
        let cleared = command(&mut c, "activate_slot", json!({"index":999})).unwrap();
        assert!(cleared["activeSlotIndex"].is_null());
        assert!(cleared["programs"][0]["activeSlotIndex"].is_null());
    }
    #[test]
    fn draft_take_publish_and_cas_failure_are_durable_and_not_optimistic() {
        let mut c = database();
        let p = stage(&c, "draft");
        let d = command(&mut c, "draft", json!({"programID":"draft"})).unwrap();
        assert_eq!(d["pendingPlan"], p);
        assert!(d["plan"].is_null());
        let old = view(&mut c).unwrap();
        assert_eq!(
            request(
                &mut c,
                "music_dj_command",
                json!({"op":"publish","programID":"draft","expectedRevision":0})
            )
            .unwrap_err(),
            "music_program_revision_conflict"
        );
        assert_eq!(view(&mut c).unwrap(), old);
        let take = command(&mut c, "take_pending", json!({})).unwrap();
        assert_eq!(take["selectedPlan"], p);
        assert!(view(&mut c).unwrap()["pendingPlan"].is_null());
        let published = command(&mut c, "publish", json!({"programID":"draft"})).unwrap();
        assert_eq!(published["pendingIDs"], json!([]));
        assert_eq!(published["plan"], p);
    }
    #[test]
    fn malformed_model_and_unknown_tracks_use_actual_fallback() {
        let b = brief("one");
        let candidates: Vec<_> = (0..8).map(candidate).collect();
        let fallback = resolve_plan(&b, &candidates, None, 1, "2026-10-08T00:00:00Z").unwrap();
        assert_eq!(
            resolve_plan(&b, &candidates, Some("not JSON"), 1, "2026-10-08T00:00:00Z").unwrap(),
            fallback
        );
        assert_eq!(
            resolve_plan(
                &b,
                &candidates,
                Some("{\"title\":\"x\",\"direction\":\"y\",\"slots\":[]}"),
                1,
                "2026-10-08T00:00:00Z"
            )
            .unwrap(),
            fallback
        );
        assert!(resolve_plan(&b, &candidates[..4], None, 1, "2026-10-08T00:00:00Z").is_err());
    }
    #[test]
    fn playlist_plan_reads_sql_facts_not_host_candidate_document() {
        let mut c = database();
        let playlist =
            json!({"id":"playlist","name":"我的歌单","tracks":[candidate(0),candidate(1)]});
        c.execute(
            "INSERT INTO music_playlists VALUES('playlist',0,?1)",
            [encode(&playlist).unwrap()],
        )
        .unwrap();
        let p = request(
            &mut c,
            "music_dj_playlist_plan",
            json!({"playlistID":"playlist","candidatePlan":{"brief":{"id":"forged"}}}),
        )
        .unwrap();
        assert_eq!(p["brief"]["id"], "playlist");
        assert_eq!(p["slots"].as_array().unwrap().len(), 2);
        assert_eq!(owned(&c, "playlist").unwrap(), p);
        assert_eq!(
            request(
                &mut c,
                "music_dj_playlist_plan",
                json!({"playlistID":"missing"})
            )
            .unwrap_err(),
            "music_playlist_not_found"
        );
    }
    #[tokio::test]
    #[cfg(unix)]
    async fn actual_rust_owned_mock_cli_schema_proposal_fallback_and_database() {
        use std::os::unix::fs::PermissionsExt;
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-dj-private-{}", uuid::Uuid::new_v4()));
        crate::files::directory(&root).unwrap();
        struct PrivateRoot(PathBuf);
        impl Drop for PrivateRoot {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = PrivateRoot(root.clone());
        let executable = root.join("mock-codex");
        let proposal = json!({"title":"真实私有模拟","direction":"输入事实", "slots":[{"track_id":"track4","selection_reason":"model reason","should_talk_before":true,"transition_intent":"next","visual":{"mood":"calm","palette":"blue","motion":"slow","intensity":0.3}}]});
        let script=format!("#!/bin/sh\nset -eu\n[ \"$1\" = exec ]\nout=''\nschema=''\nwhile [ $# -gt 0 ]; do\ncase \"$1\" in --output-last-message) shift; out=$1;; --output-schema) shift; schema=$1;; esac\nshift\ndone\n[ -f \"$schema\" ]\ninput=$(cat)\ncase \"$input\" in *\"只从候选歌曲中选择\"*) ;; *) exit 8;; esac\nprintf '%s' '{}' > \"$out\"\n",proposal.to_string().replace('\'',"'\\''"));
        std::fs::write(&executable, script).unwrap();
        std::fs::set_permissions(&executable, std::fs::Permissions::from_mode(0o700)).unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        let service = ProgramService::new(db.clone());
        let mut p = json!({"brief":brief("actual"),"discoveryCandidates":(0..8).map(candidate).collect::<Vec<_>>(),"libraryCandidates":[],"hostPrompt":"private","executable":executable.to_string_lossy(),"environment":{"PATH":"/usr/bin:/bin"},"model":"private-model"});
        let plan = service.plan(p.clone()).await.unwrap();
        assert_eq!(plan["title"], "真实私有模拟");
        assert_eq!(plan["slots"][0]["track"]["id"], "track4");
        assert_eq!(
            plan["slots"][0]["hostHint"]["selectionReason"],
            "model reason"
        );
        let saved = db.call(|s| owned(&s.connection, "actual")).await.unwrap();
        assert_eq!(saved, plan);
        p["executable"] = json!(root.join("absent").to_string_lossy());
        p["brief"]["id"] = json!("fallback");
        let fallback = service.plan(p).await.unwrap();
        assert!(fallback["title"].is_null());
        assert_eq!(fallback["slots"].as_array().unwrap().len(), 5);
        let artifacts: Vec<_> = std::fs::read_dir(&root)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().starts_with("music-dj-run-"))
            .collect();
        assert!(artifacts.is_empty());
    }
}
