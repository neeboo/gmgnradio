//! Audio cache authority. SQL owns identity/state; bounded file work never runs on storage thread.
use crate::{
    files,
    model::{digest, Result},
    store::Database,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
const LIMIT: usize = 256 * 1024 * 1024;

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS music_cache_entries(key TEXT PRIMARY KEY, action_id TEXT NOT NULL UNIQUE, session TEXT NOT NULL, request_id TEXT NOT NULL, identity TEXT NOT NULL, extension TEXT NOT NULL, state TEXT NOT NULL, sha TEXT, bytes INTEGER, UNIQUE(session,request_id));
CREATE TABLE IF NOT EXISTS music_cache_actions(action_id TEXT PRIMARY KEY,key TEXT NOT NULL,session TEXT NOT NULL,request_id TEXT NOT NULL,identity TEXT NOT NULL,extension TEXT NOT NULL,state TEXT NOT NULL,sha TEXT,bytes INTEGER);
CREATE TRIGGER IF NOT EXISTS music_cache_action_insert AFTER INSERT ON music_cache_entries BEGIN
INSERT INTO music_cache_actions VALUES(NEW.action_id,NEW.key,NEW.session,NEW.request_id,NEW.identity,NEW.extension,NEW.state,NEW.sha,NEW.bytes); END;
CREATE TRIGGER IF NOT EXISTS music_cache_action_update AFTER UPDATE ON music_cache_entries BEGIN
INSERT INTO music_cache_actions VALUES(NEW.action_id,NEW.key,NEW.session,NEW.request_id,NEW.identity,NEW.extension,NEW.state,NEW.sha,NEW.bytes)
ON CONFLICT(action_id) DO UPDATE SET session=excluded.session,request_id=excluded.request_id,state=excluded.state,sha=excluded.sha,bytes=excluded.bytes; END;").map_err(|_|"storage_unavailable")
}
pub fn recover(c: &Connection) -> Result<()> {
    c.execute(
        "UPDATE music_cache_entries SET state='unknown' WHERE state IN ('claimed','publishing')",
        [],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(())
}
#[derive(Clone)]
struct Row {
    key: String,
    action: String,
    session: String,
    identity: String,
    extension: String,
    state: String,
    sha: Option<String>,
    bytes: Option<u64>,
}
fn row(c: &Connection, field: &str, id: &str) -> Result<Option<Row>> {
    let sql=format!("SELECT key,action_id,session,identity,extension,state,sha,bytes FROM music_cache_entries WHERE {field}=?1");
    c.query_row(&sql, [id], |r| {
        Ok(Row {
            key: r.get(0)?,
            action: r.get(1)?,
            session: r.get(2)?,
            identity: r.get(3)?,
            extension: r.get(4)?,
            state: r.get(5)?,
            sha: r.get(6)?,
            bytes: r.get(7)?,
        })
    })
    .optional()
    .map_err(|_| "storage_unavailable")
}
fn paths(root: &Path, r: &Row) -> (PathBuf, PathBuf) {
    let dir = root.join("MusicCache");
    (
        dir.join(format!("{}.stage", r.action)),
        dir.join(format!("{}.{}", r.key, r.extension)),
    )
}
fn output(root: &Path, r: &Row) -> Value {
    let (stage, final_path) = paths(root, r);
    json!({"state":r.state,"key":r.key,"actionID":r.action,"stagePath":stage,"finalPath":final_path,"sha256":r.sha,"bytes":r.bytes})
}
fn string<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 512 && !s.chars().any(char::is_control))
        .ok_or("music_cache_invalid_input")
}
fn audio(b: &[u8]) -> bool {
    b.starts_with(b"ID3")
        || (b.len() > 1 && b[0] == 255 && b[1] & 224 == 224)
        || b.starts_with(b"fLaC")
        || b.starts_with(b"OggS")
        || (b.starts_with(b"RIFF") && b.get(8..12) == Some(b"WAVE"))
        || (b.starts_with(b"FORM") && matches!(b.get(8..12), Some(b"AIFF") | Some(b"AIFC")))
        || b.get(4..8) == Some(b"ftyp")
}
async fn verify(path: PathBuf, sha: String, size: u64) -> Result<Vec<u8>> {
    tokio::task::spawn_blocking(move || {
        let b = files::read(&path, LIMIT).map_err(|_| "music_cache_unsafe_path")?;
        if b.len() as u64 != size || digest(&b) != sha {
            return Err("music_cache_receipt_mismatch");
        }
        if !audio(&b) {
            return Err("music_cache_invalid_audio");
        }
        Ok(b)
    })
    .await
    .map_err(|_| "storage_unavailable")?
}
async fn get(db: &Database, field: &'static str, id: String) -> Result<Row> {
    db.call(move |s| {
        if let Some(r) = row(&s.connection, field, &id)? {
            return Ok(r);
        }
        let historic: bool = s
            .connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM music_cache_actions WHERE action_id=?1)",
                [&id],
                |r| r.get(0),
            )
            .map_err(|_| "storage_unavailable")?;
        Err(if historic {
            "music_cache_receipt_mismatch"
        } else {
            "music_cache_invalid_input"
        })
    })
    .await
}
async fn state(
    db: &Database,
    r: &Row,
    old: &str,
    new: &str,
    sha: Option<String>,
    bytes: Option<u64>,
) -> Result<Row> {
    let action = r.action.clone();
    let old = old.to_owned();
    let new = new.to_owned();
    db.call(move|s|{let count=s.connection.execute("UPDATE music_cache_entries SET state=?1,sha=COALESCE(?2,sha),bytes=COALESCE(?3,bytes) WHERE action_id=?4 AND state=?5",params![new,sha,bytes,action,old]).map_err(|_|"storage_unavailable")?;if count!=1{return Err("music_cache_receipt_mismatch");}row(&s.connection,"action_id",&action)?.ok_or("music_cache_invalid_input")}).await
}
async fn validated(db: &Database, r: Row, replacement_extension: Option<String>) -> Result<Row> {
    if r.state != "ready" && !(r.state == "unknown" && r.sha.is_some() && r.bytes.is_some()) {
        return Ok(r);
    }
    let (_, path) = paths(&db.root, &r);
    let good = verify(
        path,
        r.sha.clone().ok_or("music_cache_receipt_mismatch")?,
        r.bytes.ok_or("music_cache_receipt_mismatch")?,
    )
    .await
    .is_ok();
    if r.state == "unknown" {
        return if good {
            state(db, &r, "unknown", "ready", None, None).await
        } else {
            Ok(r)
        };
    }
    if good {
        Ok(r)
    } else {
        renew(db, &r, "ready", replacement_extension).await
    }
}
async fn renew(db: &Database, r: &Row, previous: &str, extension: Option<String>) -> Result<Row> {
    let old = r.action.clone();
    let previous = previous.to_owned();
    let next = uuid::Uuid::new_v4().to_string();
    db.call(move|s|{let changed=s.connection.execute("UPDATE music_cache_entries SET action_id=?1,state='pending',sha=NULL,bytes=NULL,extension=COALESCE(?4,extension) WHERE action_id=?2 AND state=?3",params![next,old,previous,extension]).map_err(|_|"storage_unavailable")?;if changed!=1{return Err("music_cache_receipt_mismatch");}row(&s.connection,"action_id",&next)?.ok_or("storage_unavailable")}).await
}
pub async fn request(db: &Database, method: &str, p: Value) -> Result<Value> {
    let session = string(&p, "hostSessionID")?.to_owned();
    let mut r = if method == "music_cache_prepare" {
        let request = string(&p, "requestID")?.to_owned();
        let provider = string(&p, "providerID")?;
        let track = string(&p, "trackID")?;
        if !matches!(provider, "netease" | "qq-music")
            || !track.starts_with(&format!("{provider}:"))
            || track.len() <= provider.len() + 1
        {
            return Err("music_cache_invalid_input");
        }
        let extension = string(&p, "extension")?.to_ascii_lowercase();
        if !matches!(
            extension.as_str(),
            "mp3" | "m4a" | "aac" | "flac" | "ogg" | "wav" | "aiff" | "alac" | "opus"
        ) {
            return Err("music_cache_invalid_input");
        }
        let identity =
            crate::canonical_json::to_string(&json!({"providerID":provider,"trackID":track}))
                .map_err(|_| "music_cache_invalid_input")?;
        let key = digest(identity.as_bytes());
        let owner = session.clone();
        db.call(move|s|{let existing:Option<String>=s.connection.query_row("SELECT key FROM music_cache_actions WHERE session=?1 AND request_id=?2 LIMIT 1",params![owner,request],|r|r.get(0)).optional().map_err(|_|"storage_unavailable")?;if existing.as_ref().is_some_and(|v|v!=&key){return Err("music_cache_identity_mismatch");} if let Some(r)=row(&s.connection,"key",&key)?{if r.identity!=identity{return Err("music_cache_identity_mismatch");}return Ok(r);}let action=uuid::Uuid::new_v4().to_string();s.connection.execute("INSERT INTO music_cache_entries(key,action_id,session,request_id,identity,extension,state) VALUES(?1,?2,?3,?4,?5,?6,'pending')",params![key,action,owner,request,identity,extension]).map_err(|_|"storage_unavailable")?;row(&s.connection,"key",&key)?.ok_or("storage_unavailable")}).await?
    } else {
        get(db, "action_id", string(&p, "actionID")?.to_owned()).await?
    };
    if method != "music_cache_prepare" && r.session != session {
        return Err("music_cache_identity_mismatch");
    }
    let replacement_extension = if method == "music_cache_prepare" {
        Some(string(&p, "extension")?.to_ascii_lowercase())
    } else {
        None
    };
    r = validated(db, r, replacement_extension.clone()).await?;
    if method == "music_cache_prepare" && r.state == "failed" {
        r = renew(db, &r, "failed", replacement_extension).await?;
    }
    if method == "music_cache_prepare" && r.state == "pending" && r.session != session {
        let owner = session.clone();
        let request = string(&p, "requestID")?.to_owned();
        let action = r.action.clone();
        let next = uuid::Uuid::new_v4().to_string();
        r=db.call(move|s|{let changed=s.connection.execute("UPDATE music_cache_entries SET session=?1,request_id=?2,action_id=?4 WHERE action_id=?3 AND state='pending'",params![owner,request,action,next]).map_err(|_|"storage_unavailable")?;if changed!=1{return Err("music_cache_receipt_mismatch");}row(&s.connection,"action_id",&next)?.ok_or("storage_unavailable")}).await?;
    }
    if method == "music_cache_prepare" || method == "music_cache_read" {
        return Ok(output(&db.root, &r));
    }
    if r.session != session {
        return Err("music_cache_identity_mismatch");
    }
    match method {
        "music_cache_claim" => {
            if r.state == "unknown" || r.state == "claimed" {
                return Err("music_cache_claim_unknown");
            }
            if r.state != "pending" {
                return Err("music_cache_receipt_mismatch");
            }
            let root = db.root.join("MusicCache");
            tokio::task::spawn_blocking(move || files::directory(&root))
                .await
                .map_err(|_| "storage_unavailable")??;
            r = state(db, &r, "pending", "claimed", None, None).await?;
        }
        "music_cache_receipt" => {
            if p["outcome"] == "failed" {
                if r.state == "failed" {
                    return Ok(output(&db.root, &r));
                }
                if r.state != "claimed" && r.state != "unknown" {
                    return Err("music_cache_receipt_mismatch");
                }
                let old = r.state.clone();
                r = state(db, &r, &old, "failed", None, None).await?;
                return Ok(output(&db.root, &r));
            }
            if p["outcome"] != "completed" || p["audioValid"] != true {
                return Err("music_cache_invalid_audio");
            }
            let sha = string(&p, "sha256")?.to_owned();
            let size = p["bytes"]
                .as_u64()
                .filter(|n| *n > 0 && *n <= LIMIT as u64)
                .ok_or("music_cache_invalid_input")?;
            if sha.len() != 64 || !sha.bytes().all(|v| v.is_ascii_hexdigit()) {
                return Err("music_cache_invalid_input");
            }
            if r.state == "ready" {
                if r.sha.as_ref() != Some(&sha) || r.bytes != Some(size) {
                    return Err("music_cache_receipt_mismatch");
                }
                return Ok(output(&db.root, &r));
            }
            if r.state != "claimed" && r.state != "unknown" {
                return Err("music_cache_receipt_mismatch");
            }
            let (stage, final_path) = paths(&db.root, &r);
            let data = verify(stage, sha.clone(), size).await?;
            let old = r.state.clone();
            r = state(db, &r, &old, "publishing", Some(sha), Some(size)).await?;
            tokio::task::spawn_blocking(move || files::publish(&final_path, &data))
                .await
                .map_err(|_| "storage_unavailable")??;
            r = state(db, &r, "publishing", "ready", None, None).await?;
            let (stage, _) = paths(&db.root, &r);
            let sha = r.sha.clone().unwrap();
            let size = r.bytes.unwrap();
            // Ready is already durable. Cleanup is optional and may only remove
            // this action's independently verified private staging payload.
            let _ = tokio::task::spawn_blocking(move || {
                let b = files::read(&stage, LIMIT)?;
                if b.len() as u64 == size && digest(&b) == sha {
                    std::fs::remove_file(&stage).map_err(|_| "storage_unavailable")?;
                }
                Ok::<(), &'static str>(())
            })
            .await;
        }
        _ => return Err("music_cache_invalid_input"),
    }
    Ok(output(&db.root, &r))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn real_private_file_receipts_and_restart_unknown() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-music-cache-test-{}", uuid::Uuid::new_v4()));
        files::directory(&root).unwrap();
        let root = root.canonicalize().unwrap();
        let db = Database::open(root.clone(), None).unwrap();
        db.call(|s| schema(&s.connection)).await.unwrap();
        let input = json!({"hostSessionID":"host","requestID":"request","providerID":"netease","trackID":"netease:42","extension":"mp3"});
        let prepared = request(&db, "music_cache_prepare", input.clone())
            .await
            .unwrap();
        let action = prepared["actionID"].as_str().unwrap();
        assert_eq!(
            request(
                &db,
                "music_cache_read",
                json!({"hostSessionID":"other","actionID":action})
            )
            .await
            .unwrap_err(),
            "music_cache_identity_mismatch"
        );
        let claim = json!({"hostSessionID":"host","actionID":action});
        let command = request(&db, "music_cache_claim", claim.clone())
            .await
            .unwrap();
        let body = b"ID3\x04\x00private real bytes";
        files::publish(Path::new(command["stagePath"].as_str().unwrap()), body).unwrap();
        let receipt = json!({"hostSessionID":"host","actionID":action,"outcome":"completed","sha256":digest(body),"bytes":body.len(),"audioValid":true});
        let mut bad = receipt.clone();
        bad["sha256"] = json!("0".repeat(64));
        assert_eq!(
            request(&db, "music_cache_receipt", bad).await.unwrap_err(),
            "music_cache_receipt_mismatch"
        );
        let ready = request(&db, "music_cache_receipt", receipt.clone())
            .await
            .unwrap();
        assert_eq!(ready["state"], "ready");
        let mut other_format = input.clone();
        other_format["extension"] = json!("m4a");
        let same = request(&db, "music_cache_prepare", other_format)
            .await
            .unwrap();
        assert_eq!(same["state"], "ready");
        assert_eq!(same["actionID"], ready["actionID"]);
        assert_eq!(same["finalPath"], ready["finalPath"]);
        assert_eq!(
            request(&db, "music_cache_receipt", receipt).await.unwrap()["state"],
            "ready"
        );
        assert_eq!(
            request(&db, "music_cache_prepare", input.clone())
                .await
                .unwrap()["state"],
            "ready"
        );
        files::publish(
            Path::new(ready["finalPath"].as_str().unwrap()),
            b"<html>broken</html>",
        )
        .unwrap();
        let replaced = request(&db, "music_cache_prepare", input.clone())
            .await
            .unwrap();
        assert_eq!(replaced["state"], "pending");
        assert_ne!(replaced["actionID"], prepared["actionID"]);
        let mut changed_identity = input.clone();
        changed_identity["trackID"] = json!("netease:43");
        assert_eq!(
            request(&db, "music_cache_prepare", changed_identity)
                .await
                .unwrap_err(),
            "music_cache_identity_mismatch"
        );
        let qq=request(&db,"music_cache_prepare",json!({"hostSessionID":"host","requestID":"qq-request","providerID":"qq-music","trackID":"qq-music:42","extension":"mp3"})).await.unwrap();
        let qq_claim = json!({"hostSessionID":"host","actionID":qq["actionID"]});
        request(&db, "music_cache_claim", qq_claim).await.unwrap();
        let failed = json!({"hostSessionID":"host","actionID":qq["actionID"],"outcome":"failed"});
        assert_eq!(
            request(&db, "music_cache_receipt", failed.clone())
                .await
                .unwrap()["state"],
            "failed"
        );
        assert_eq!(
            request(&db, "music_cache_receipt", failed).await.unwrap()["state"],
            "failed"
        );
        let next = json!({"hostSessionID":"host","actionID":replaced["actionID"]});
        request(&db, "music_cache_claim", next.clone())
            .await
            .unwrap();
        db.call(|s| recover(&s.connection)).await.unwrap();
        assert_eq!(
            request(&db, "music_cache_prepare", input).await.unwrap()["state"],
            "unknown"
        );
        assert_eq!(
            request(&db, "music_cache_claim", next).await.unwrap_err(),
            "music_cache_claim_unknown"
        );
        drop(db);
        std::fs::remove_dir_all(&root).unwrap();
    }
    #[test]
    fn actual_audio_signature_rejects_documents() {
        assert!(audio(b"ID3\x04\x00payload"));
        assert!(audio(b"\x00\x00\x00\x18ftypM4A "));
        assert!(!audio(b"<html>not audio</html>"));
        assert!(!audio(b"{\"audioValid\":true}"));
    }
    #[test]
    fn recovery_never_requeues_claimed() {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        c.execute("INSERT INTO music_cache_entries VALUES('key','action','host','request','identity','mp3','claimed',NULL,NULL)",[]).unwrap();
        recover(&c).unwrap();
        assert_eq!(
            row(&c, "action_id", "action").unwrap().unwrap().state,
            "unknown"
        );
        recover(&c).unwrap();
        assert_eq!(
            row(&c, "action_id", "action").unwrap().unwrap().state,
            "unknown"
        );
    }
    #[test]
    fn provider_identity_prevents_filename_collision() {
        assert_ne!(
            digest(br#"{"providerID":"netease","trackID":"netease:a/b"}"#),
            digest(br#"{"providerID":"netease","trackID":"netease:a-b"}"#)
        );
        assert_ne!(
            digest(br#"{"providerID":"netease","trackID":"netease:42"}"#),
            digest(br#"{"providerID":"qq-music","trackID":"qq-music:42"}"#)
        );
    }
}
