//! Native supplies file facts; Rust owns draft/submission references and ordering.
use crate::model::{self, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, fs, io::Read, path::Path, time::{SystemTime, UNIX_EPOCH}};

#[derive(Clone, Serialize, Deserialize, PartialEq, Debug)]
#[serde(rename_all = "camelCase")]
struct Attachment {
    id: String, local_path: String, display_name: String, sha256: String,
    byte_count: u64, frame_generation: u64,
}
#[derive(Clone, Serialize, Deserialize)]
struct Fact { attachment: Attachment, order: u64, ever_submitted: bool, deletion_offered: bool }
#[derive(Serialize, Deserialize)]
struct Submission {
    session: String, ids: Vec<String>, has_text: bool, issued_at: u64,
    order: u64, state: String, restored: bool,
}
#[derive(Default, Serialize, Deserialize)]
struct State {
    session: String, directory: String, closed: bool, revision: u64,
    frame_generation: u64, sequence: u64, draft: Vec<String>,
    facts: BTreeMap<String, Fact>, submissions: BTreeMap<String, Submission>,
}
pub fn schema(db: &Connection) -> Result<()> {
    db.execute_batch("CREATE TABLE IF NOT EXISTS chat_attachment_authority(owner TEXT PRIMARY KEY NOT NULL,value TEXT NOT NULL);")
        .map_err(|_| "storage_unavailable")
}
fn text<'a>(p: &'a Value, key: &str, limit: usize) -> Result<&'a str> {
    p[key].as_str().filter(|s| !s.is_empty() && s.len() <= limit)
        .ok_or("chat_attachments_invalid_input")
}
fn number(p: &Value, key: &str) -> Result<u64> {
    p[key].as_u64().ok_or("chat_attachments_invalid_input")
}
fn uuid(p: &Value, key: &str) -> Result<String> {
    let raw = text(p, key, 36)?;
    let id = uuid::Uuid::parse_str(raw).map_err(|_| "chat_attachments_invalid_id")?;
    if id.is_nil() || id.to_string() != raw { return Err("chat_attachments_invalid_id"); }
    Ok(raw.into())
}
fn strict(p: &Value, fields: &[&str]) -> Result<()> {
    let o = p.as_object().ok_or("chat_attachments_invalid_input")?;
    if o.keys().any(|k| !fields.contains(&k.as_str())) { return Err("chat_attachments_invalid_input"); }
    Ok(())
}
fn private_directory(raw: &str) -> Result<String> {
    let path = Path::new(raw);
    let meta = fs::symlink_metadata(path).map_err(|_| "chat_attachments_invalid_directory")?;
    if !meta.is_dir() || meta.file_type().is_symlink() { return Err("chat_attachments_invalid_directory"); }
    #[cfg(unix)] {
        use std::os::unix::fs::MetadataExt;
        if meta.mode() & 0o777 != 0o700 || meta.uid() != unsafe { libc::geteuid() } {
            return Err("chat_attachments_invalid_directory");
        }
    }
    let canonical = fs::canonicalize(path).map_err(|_| "chat_attachments_invalid_directory")?;
    if canonical != path || canonical.parent().is_none() { return Err("chat_attachments_invalid_directory"); }
    canonical.to_str().map(str::to_owned).ok_or("chat_attachments_invalid_directory")
}
fn registered_file(directory: &str, raw: &str) -> Result<Vec<u8>> {
    // Exact direct child, canonical path and no symlink. Open with NOFOLLOW too,
    // so replacing the final component during validation cannot redirect reads.
    let path = Path::new(raw);
    if path.parent() != Some(Path::new(directory)) { return Err("chat_attachments_invalid_path"); }
    private_directory(directory)?;
    let meta = fs::symlink_metadata(path).map_err(|_| "chat_attachments_invalid_file")?;
    if !meta.is_file() || meta.file_type().is_symlink() || fs::canonicalize(path).ok().as_deref() != Some(path) {
        return Err("chat_attachments_invalid_file");
    }
    let mut options = fs::OpenOptions::new(); options.read(true);
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.custom_flags(libc::O_NOFOLLOW); }
    let mut file = options.open(path).map_err(|_| "chat_attachments_invalid_file")?;
    let opened = file.metadata().map_err(|_| "chat_attachments_invalid_file")?;
    #[cfg(unix)] {
        use std::os::unix::fs::MetadataExt;
        if opened.mode() & 0o777 != 0o600 || opened.uid() != unsafe { libc::geteuid() }
            || opened.ino() != meta.ino() || opened.dev() != meta.dev() { return Err("chat_attachments_invalid_file"); }
    }
    if !opened.is_file() || opened.len() > model::PNG_LIMIT as u64 { return Err("chat_attachments_invalid_file"); }
    let mut bytes = Vec::new();
    (&mut file).take(model::PNG_LIMIT as u64 + 1).read_to_end(&mut bytes).map_err(|_| "chat_attachments_invalid_file")?;
    model::validate_png(&bytes)?;
    Ok(bytes)
}
fn ids(p: &Value) -> Result<Vec<String>> {
    let values = p["attachmentIDs"].as_array().ok_or("chat_attachments_invalid_input")?;
    let mut result = Vec::new();
    for value in values {
        let id = uuid(&json!({"id": value}), "id")?;
        if result.contains(&id) { return Err("chat_attachments_invalid_input"); }
        result.push(id);
    }
    Ok(result)
}
fn cas(s: &State, p: &Value) -> Result<()> {
    if number(p, "expectedRevision")? != s.revision { return Err("chat_attachments_stale_revision"); }
    Ok(())
}
fn snapshot(s: &State, delete_paths: Vec<String>) -> Value {
    let attachments: Vec<_> = s.draft.iter().filter_map(|id| s.facts.get(id)).map(|f| &f.attachment).collect();
    json!({"snapshot": {"revision": s.revision, "frameGeneration": s.frame_generation,
        "attachments": attachments, "canSend": !s.closed && s.draft.len() <= 4}, "deletePaths": delete_paths})
}
fn bump(s: &mut State) -> Result<()> {
    if s.sequence >= u64::MAX / 8 { return Err("chat_attachments_revision_exhausted"); }
    s.revision = s.revision.checked_add(1).ok_or("chat_attachments_revision_exhausted")?;
    s.sequence = s.sequence.checked_add(1).ok_or("chat_attachments_revision_exhausted")?;
    Ok(())
}
fn collect(s: &mut State) -> Vec<String> {
    let unused: Vec<_> = s.facts.iter().filter(|(id, fact)| !fact.ever_submitted
        && !s.draft.contains(id) && !s.submissions.values().any(|r| r.state != "completed" && r.ids.contains(id)))
        .map(|(id, f)| (id.clone(), f.attachment.clone())).collect();
    let mut paths = Vec::new();
    for (id, attachment) in unused {
        // Validate again before handing a deletion capability back to native.
        if let Ok(bytes) = registered_file(&s.directory, &attachment.local_path) {
            if bytes.len() as u64 != attachment.byte_count || format!("{:x}", Sha256::digest(&bytes)) != attachment.sha256 { continue; }
            // Repeat the same capability while the exact verified file exists:
            // a lost remove/close response must be recoverable by a read.
            paths.push(attachment.local_path);
            s.facts.get_mut(&id).unwrap().deletion_offered = true;
        }
    }
    paths
}
pub fn request(db: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let owner = text(p, "ownerID", 256)?;
    let session = text(p, "hostSessionID", 256)?;
    let fields: &[&str] = match method {
        "chat_attachments_open" => &["ownerID", "hostSessionID", "directory"],
        "chat_attachments_read" => &["ownerID", "hostSessionID", "submissionID"],
        "chat_attachments_register" => &["ownerID", "hostSessionID", "expectedRevision", "frameGeneration", "attachmentID", "localPath", "sha256", "byteCount", "displayName"],
        "chat_attachments_remove" => &["ownerID", "hostSessionID", "expectedRevision", "attachmentID"],
        "chat_attachments_take" => &["ownerID", "hostSessionID", "expectedRevision", "submissionID", "attachmentIDs", "hasText"],
        "chat_attachments_restore" => &["ownerID", "hostSessionID", "expectedRevision", "submissionID"],
        "chat_attachments_finish" => &["ownerID", "hostSessionID", "expectedRevision", "submissionID", "state"],
        "chat_attachments_close" => &["ownerID", "hostSessionID", "expectedRevision"],
        _ => return Err("unknown_method"),
    };
    strict(p, fields)?;
    let tx = db.transaction().map_err(|_| "storage_unavailable")?;
    let stored: Option<String> = tx.query_row("SELECT value FROM chat_attachment_authority WHERE owner=?1", [owner], |r| r.get(0))
        .optional().map_err(|_| "storage_unavailable")?;
    let mut s: State = stored.as_deref().map(serde_json::from_str).transpose().map_err(|_| "chat_attachments_invalid_state")?.unwrap_or_default();
    if method == "chat_attachments_open" {
        let directory = private_directory(text(p, "directory", 4096)?)?;
        if s.session == session {
            if s.directory != directory || s.closed { return Err("chat_attachments_session_conflict"); }
        } else {
            // Never resume another host's issued work automatically.
            for r in s.submissions.values_mut().filter(|r| r.state == "issued") { r.state = "unknown".into(); }
            s.draft.clear(); s.session = session.into(); s.directory = directory; s.closed = false; s.frame_generation = 0;
            bump(&mut s)?;
        }
    } else {
        if s.session != session { return Err("chat_attachments_stale_session"); }
        if s.closed && !["chat_attachments_read", "chat_attachments_finish"].contains(&method) { return Err("chat_attachments_closed"); }
        match method {
            "chat_attachments_read" => {},
            "chat_attachments_register" => {
                cas(&s, p)?;
                let generation = number(p, "frameGeneration")?;
                if generation < s.frame_generation { return Err("chat_attachments_stale_frame"); }
                let id = uuid(p, "attachmentID")?;
                let path = text(p, "localPath", 4096)?;
                let bytes = registered_file(&s.directory, path)?;
                let digest = format!("{:x}", Sha256::digest(&bytes));
                if number(p, "byteCount")? != bytes.len() as u64 || text(p, "sha256", 64)? != digest {
                    return Err("chat_attachments_file_mismatch");
                }
                let attachment = Attachment { id: id.clone(), local_path: path.into(),
                    display_name: text(p, "displayName", 256)?.into(), sha256: digest,
                    byte_count: bytes.len() as u64, frame_generation: generation };
                if let Some(existing) = s.facts.get(&id) {
                    if existing.attachment != attachment || !s.draft.contains(&id) { return Err("chat_attachments_id_conflict"); }
                } else {
                    if s.draft.len() >= 4 { return Err("chat_attachments_limit"); }
                    if s.facts.values().any(|f| f.attachment.local_path == path) { return Err("chat_attachments_path_conflict"); }
                    bump(&mut s)?; s.frame_generation = generation;
                    s.facts.insert(id.clone(), Fact { attachment, order: s.sequence * 8, ever_submitted: false, deletion_offered: false });
                    s.draft.push(id);
                }
            },
            "chat_attachments_remove" => {
                cas(&s, p)?; let id = uuid(p, "attachmentID")?;
                if !s.draft.contains(&id) { return Err("chat_attachments_not_in_draft"); }
                s.draft.retain(|i| i != &id); bump(&mut s)?;
            },
            "chat_attachments_take" => {
                let id = uuid(p, "submissionID")?; let requested = ids(p)?;
                let has_text = p["hasText"].as_bool().ok_or("chat_attachments_invalid_input")?;
                if let Some(old) = s.submissions.get(&id) {
                    if old.session != session { return Err("chat_attachments_stale_session"); }
                    if old.ids != requested || old.has_text != has_text { return Err("chat_attachments_submission_conflict"); }
                    if old.state == "unknown" { return Err("chat_attachments_submission_unknown"); }
                    // Exact duplicate never issues a second submission, even after completion.
                } else {
                    cas(&s, p)?;
                    if requested != s.draft || requested.len() > 4 || (!has_text && requested.is_empty()) { return Err("chat_attachments_invalid_selection"); }
                    for item in &requested {
                        let f = s.facts.get(item).ok_or("chat_attachments_invalid_state")?;
                        let bytes = registered_file(&s.directory, &f.attachment.local_path)?;
                        if format!("{:x}", Sha256::digest(&bytes)) != f.attachment.sha256 { return Err("chat_attachments_file_mismatch"); }
                    }
                    bump(&mut s)?;
                    for (index, item) in requested.iter().enumerate() {
                        let fact = s.facts.get_mut(item).ok_or("chat_attachments_invalid_state")?;
                        fact.ever_submitted = true; fact.order = s.sequence * 8 + index as u64;
                    }
                    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|_| "chat_attachments_clock")?.as_millis();
                    s.submissions.insert(id, Submission { session: session.into(), ids: requested,
                        has_text, issued_at: now.try_into().map_err(|_| "chat_attachments_clock")?, order: s.sequence,
                        state: "issued".into(), restored: false });
                    s.draft.clear();
                }
            },
            "chat_attachments_restore" => {
                let id = uuid(p, "submissionID")?;
                let issued = s.submissions.get(&id).ok_or("chat_attachments_not_issued")?;
                if issued.session != session { return Err("chat_attachments_stale_session"); }
                if !issued.restored {
                    cas(&s, p)?;
                    if issued.state != "issued" && issued.state != "cancelled" { return Err("chat_attachments_not_restorable"); }
                    let restore_ids = issued.ids.clone();
                    for item in restore_ids { if !s.draft.contains(&item) { s.draft.push(item); } }
                    s.draft.sort_by_key(|item| (s.facts[item].order, item.clone()));
                    s.submissions.get_mut(&id).unwrap().restored = true;
                    bump(&mut s)?;
                }
            },
            "chat_attachments_finish" => {
                let id = uuid(p, "submissionID")?;
                let state = text(p, "state", 16)?;
                if !["completed", "cancelled", "unknown"].contains(&state) { return Err("chat_attachments_invalid_input"); }
                let issued = s.submissions.get(&id).ok_or("chat_attachments_not_issued")?;
                if issued.session != session { return Err("chat_attachments_stale_session"); }
                if issued.state != state {
                    cas(&s, p)?;
                    if issued.state != "issued" { return Err("chat_attachments_terminal_conflict"); }
                    s.submissions.get_mut(&id).unwrap().state = state.into(); bump(&mut s)?;
                }
            },
            "chat_attachments_close" => { cas(&s, p)?; s.draft.clear(); s.closed = true; bump(&mut s)?; },
            _ => unreachable!(),
        }
    }
    let paths = collect(&mut s);
    let mut reply = snapshot(&s, paths);
    if method == "chat_attachments_read" && p.get("submissionID").is_some() {
        let id = uuid(p, "submissionID")?;
        reply["submission"] = match s.submissions.get(&id) {
            Some(issued) => {
                if issued.session != session { return Err("chat_attachments_stale_session"); }
                json!({"submissionID":id,"attachmentIDs":issued.ids,"hasText":issued.has_text,"state":issued.state})
            },
            None => Value::Null,
        };
    }
    let encoded = serde_json::to_string(&s).map_err(|_| "chat_attachments_invalid_state")?;
    tx.execute("INSERT INTO chat_attachment_authority(owner,value) VALUES(?1,?2) ON CONFLICT(owner) DO UPDATE SET value=excluded.value", params![owner, encoded])
        .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(reply)
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::{os::unix::fs::PermissionsExt, path::PathBuf};
    struct Fixture { db: Connection, directory: PathBuf, revision: u64 }
    impl Fixture {
        fn new() -> Self {
            let directory = fs::canonicalize(std::env::temp_dir()).unwrap().join(format!("gmgn-attachments-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&directory).unwrap(); fs::set_permissions(&directory, fs::Permissions::from_mode(0o700)).unwrap();
            let db = Connection::open_in_memory().unwrap(); schema(&db).unwrap();
            let mut f = Self { db, directory, revision: 0 };
            f.call("open", json!({"directory": f.directory.to_str().unwrap()})).unwrap(); f
        }
        fn call(&mut self, method: &str, mut p: Value) -> Result<Value> {
            p["ownerID"] = json!("owner"); p["hostSessionID"] = json!("host");
            if !["open", "read"].contains(&method) && p.get("expectedRevision").is_none() { p["expectedRevision"] = json!(self.revision); }
            let reply = request(&mut self.db, &format!("chat_attachments_{method}"), &p)?;
            self.revision = reply["snapshot"]["revision"].as_u64().unwrap(); Ok(reply)
        }
        fn image(&self) -> (String, PathBuf, Vec<u8>) {
            let id = uuid::Uuid::new_v4().to_string(); let path = self.directory.join(format!("{id}.png"));
            let mut bytes = Vec::new();
            { let mut encoder = png::Encoder::new(&mut bytes, 1, 1); encoder.set_color(png::ColorType::Rgba); encoder.set_depth(png::BitDepth::Eight);
                encoder.write_header().unwrap().write_image_data(&[1, 2, 3, 255]).unwrap(); }
            fs::write(&path, &bytes).unwrap(); fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap(); (id, path, bytes)
        }
        fn register_params(&self, image: &(String, PathBuf, Vec<u8>), generation: u64) -> Value {
            json!({"attachmentID":image.0,"localPath":image.1.to_str().unwrap(),"sha256":format!("{:x}",Sha256::digest(&image.2)),
                "byteCount":image.2.len(),"displayName":"image.png","frameGeneration":generation})
        }
        fn register(&mut self) -> String {
            let image = self.image(); self.call("register", self.register_params(&image, 1)).unwrap(); image.0
        }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.directory); } }

    #[test]
    fn draft_cas_file_integrity_and_deletion_capability() {
        let mut f = Fixture::new(); let image = f.image(); let p = f.register_params(&image, 3);
        let reply = f.call("register", p.clone()).unwrap();
        assert_eq!(reply["snapshot"]["attachments"][0]["id"], image.0);
        let mut stale = p.clone(); stale["expectedRevision"] = json!(0);
        assert_eq!(f.call("register", stale).unwrap_err(), "chat_attachments_stale_revision");
        let other = f.image();
        assert_eq!(f.call("register", f.register_params(&other, 2)).unwrap_err(), "chat_attachments_stale_frame");
        fs::write(&other.1, b"not a png").unwrap();
        assert!(f.call("register", f.register_params(&other, 4)).is_err());
        let reply = f.call("remove", json!({"attachmentID":image.0})).unwrap();
        assert_eq!(reply["deletePaths"], json!([image.1.to_str().unwrap()]));
        assert_eq!(f.call("read", json!({})).unwrap()["deletePaths"], json!([image.1.to_str().unwrap()]));
        assert!(image.1.exists(), "Rust never deletes the native file");
        fs::remove_file(&image.1).unwrap();
        assert_eq!(f.call("read", json!({})).unwrap()["deletePaths"], json!([]));
        assert!(f.call("register", p).is_err(), "removed stable IDs cannot be rebound");
    }

    #[test]
    fn take_is_exact_idempotent_and_restore_keeps_new_draft() {
        let mut f = Fixture::new(); let first = f.register(); let second = f.register();
        let submission = uuid::Uuid::new_v4().to_string();
        let p = json!({"submissionID":submission,"attachmentIDs":[first,second],"hasText":false});
        let mut wrong = p.clone(); wrong["attachmentIDs"] = json!([second,first]);
        assert!(f.call("take", wrong).is_err());
        f.call("take", p.clone()).unwrap(); let revision = f.revision;
        f.call("take", p.clone()).unwrap(); assert_eq!(f.revision, revision);
        let third = f.register();
        f.call("finish", json!({"submissionID":submission,"state":"cancelled"})).unwrap();
        let reply = f.call("restore", json!({"submissionID":submission})).unwrap();
        let ids: Vec<_> = reply["snapshot"]["attachments"].as_array().unwrap().iter().map(|v|v["id"].as_str().unwrap()).collect();
        assert_eq!(ids, [first.as_str(),second.as_str(),third.as_str()]);
        f.call("remove", json!({"attachmentID":first})).unwrap();
        let revision = f.revision;
        f.call("restore", json!({"submissionID":submission,"expectedRevision":0})).unwrap();
        assert_eq!(f.revision, revision);
        assert_eq!(f.call("read", json!({})).unwrap()["snapshot"]["attachments"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn overflow_restore_blocks_send_unknown_and_new_session_reject_receipts() {
        let mut f = Fixture::new(); let old: Vec<_> = (0..4).map(|_| f.register()).collect();
        let submission = uuid::Uuid::new_v4().to_string();
        f.call("take", json!({"submissionID":submission,"attachmentIDs":old,"hasText":true})).unwrap();
        f.register();
        assert_eq!(f.call("restore", json!({"submissionID":submission})).unwrap()["snapshot"]["canSend"], false);
        f.call("finish", json!({"submissionID":submission,"state":"unknown"})).unwrap();
        assert_eq!(f.call("take", json!({"submissionID":submission,"attachmentIDs":old,"hasText":true})).unwrap_err(), "chat_attachments_submission_unknown");
        let reply = f.call("close", json!({})).unwrap(); assert_eq!(reply["deletePaths"].as_array().unwrap().len(),1);
        assert_eq!(request(&mut f.db,"chat_attachments_open", &json!({"ownerID":"owner","hostSessionID":"next","directory":f.directory.to_str().unwrap()})).unwrap()["snapshot"]["attachments"], json!([]));
        assert_eq!(f.call("finish",json!({"submissionID":submission,"state":"completed"})).unwrap_err(), "chat_attachments_stale_session");
        assert_eq!(request(&mut f.db,"chat_attachments_finish", &json!({"ownerID":"owner","hostSessionID":"next","submissionID":submission,"state":"completed","expectedRevision":99})).unwrap_err(), "chat_attachments_stale_session");
    }

    #[test]
    fn symlinks_public_permissions_and_forged_callbacks_rejected() {
        let mut f = Fixture::new(); let image = f.image();
        fs::set_permissions(&image.1,fs::Permissions::from_mode(0o644)).unwrap();
        assert!(f.call("register",f.register_params(&image,1)).is_err());
        fs::set_permissions(&image.1,fs::Permissions::from_mode(0o600)).unwrap();
        let link = f.directory.join("link.png"); std::os::unix::fs::symlink(&image.1,&link).unwrap();
        let mut p=f.register_params(&image,1); p["localPath"]=json!(link.to_str().unwrap()); assert!(f.call("register",p).is_err());
        assert_eq!(f.call("restore",json!({"submissionID":uuid::Uuid::new_v4().to_string()})).unwrap_err(),"chat_attachments_not_issued");
        fs::set_permissions(&f.directory,fs::Permissions::from_mode(0o755)).unwrap();
        assert!(f.call("open",json!({"directory":f.directory.to_str().unwrap()})).is_err());
    }

    #[test]
    fn completed_submission_retains_file_and_empty_text_only_take_is_valid() {
        let mut f = Fixture::new();
        assert!(f.call("take",json!({"submissionID":uuid::Uuid::new_v4().to_string(),"attachmentIDs":[],"hasText":false})).is_err());
        let text_submission=uuid::Uuid::new_v4().to_string();
        f.call("take",json!({"submissionID":text_submission,"attachmentIDs":[],"hasText":true})).unwrap();
        let image=f.image(); f.call("register",f.register_params(&image,1)).unwrap();
        let submission=uuid::Uuid::new_v4().to_string();
        f.call("take",json!({"submissionID":submission,"attachmentIDs":[image.0],"hasText":true})).unwrap();
        f.call("close",json!({})).unwrap();
        let reply=f.call("finish",json!({"submissionID":submission,"state":"completed"})).unwrap();
        assert_eq!(reply["deletePaths"],json!([])); assert!(image.1.exists());
        let raw:String=f.db.query_row("SELECT value FROM chat_attachment_authority WHERE owner='owner'",[],|r|r.get(0)).unwrap();
        let state:State=serde_json::from_str(&raw).unwrap();
        assert_eq!(state.submissions[&submission].state,"completed");
        assert!(state.facts[&image.0].ever_submitted);
    }

    #[test]
    fn lost_take_read_binding_and_lost_close_deletion_recover_without_mutation() {
        let mut f=Fixture::new();let image=f.register();let submission=uuid::Uuid::new_v4().to_string();
        f.call("take",json!({"submissionID":submission,"attachmentIDs":[image],"hasText":true})).unwrap();
        let revision=f.revision;
        let read=f.call("read",json!({"submissionID":submission})).unwrap();
        assert_eq!(read["submission"],json!({"submissionID":submission,"attachmentIDs":[image],"hasText":true,"state":"issued"}));
        assert_eq!(f.revision,revision);
        assert_eq!(f.call("read",json!({"submissionID":uuid::Uuid::new_v4().to_string()})).unwrap()["submission"],Value::Null);
        f.call("finish",json!({"submissionID":submission,"state":"unknown"})).unwrap();
        assert_eq!(f.call("read",json!({"submissionID":submission})).unwrap()["submission"]["state"],"unknown");
        let unsent=f.image();f.call("register",f.register_params(&unsent,2)).unwrap();
        let closed=f.call("close",json!({})).unwrap();
        assert_eq!(closed["deletePaths"],json!([unsent.1.to_str().unwrap()]));
        let revision=f.revision;
        assert_eq!(f.call("read",json!({})).unwrap()["deletePaths"],closed["deletePaths"]);
        assert_eq!(f.revision,revision);
        fs::remove_file(&unsent.1).unwrap();assert_eq!(f.call("read",json!({})).unwrap()["deletePaths"],json!([]));
    }
}
