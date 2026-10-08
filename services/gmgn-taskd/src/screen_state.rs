//! Screen definitions/page metadata. SQLite is the only writer; legacy JSON is read once.
use crate::{files, model::Result, store::Database};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS screen_state_records(world TEXT PRIMARY KEY,revision INTEGER NOT NULL,payload TEXT NOT NULL);
 CREATE TABLE IF NOT EXISTS screen_state_commands(world TEXT NOT NULL,request TEXT NOT NULL,input TEXT NOT NULL,output TEXT NOT NULL,PRIMARY KEY(world,request));
 CREATE TABLE IF NOT EXISTS screen_state_imports(source TEXT PRIMARY KEY,digest TEXT NOT NULL,receipt TEXT NOT NULL);") .map_err(|_|"storage_unavailable")
}
fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.chars().count() <= 256)
        .ok_or("screen_state_invalid_input")
}
fn object<'a>(v: &'a Value) -> Result<&'a serde_json::Map<String, Value>> {
    v.as_object().ok_or("screen_state_invalid_record")
}
fn definition(id: &str, v: &Value) -> Result<()> {
    object(v)?;
    if text(v, "objectID")? != id
        || !matches!(
            v["source"].as_str().unwrap_or("calibrated"),
            "calibrated" | "inferred" | "default"
        )
        || text(v, "note")?.chars().count() > 240
        || text(v, "note")?.trim().is_empty()
    {
        return Err("screen_state_invalid_definition");
    }
    let center = v["center"]
        .as_array()
        .filter(|v| v.len() == 3)
        .ok_or("screen_state_invalid_definition")?;
    for number in center {
        let n = number.as_f64().ok_or("screen_state_invalid_definition")? as f32;
        if !n.is_finite() || n.abs() > 100.0 {
            return Err("screen_state_invalid_definition");
        }
    }
    for (key, default, minimum, maximum) in [
        (
            "yaw",
            Some(0.0),
            -4.0 * std::f32::consts::PI,
            4.0 * std::f32::consts::PI,
        ),
        (
            "pitch",
            Some(0.0),
            -std::f32::consts::PI / 2.0,
            std::f32::consts::PI / 2.0,
        ),
        ("halfWidth", None, 0.02, 5.0),
        ("halfHeight", None, 0.02, 5.0),
    ] {
        let n = v
            .get(key)
            .map(|v| v.as_f64().map(|n| n as f32))
            .unwrap_or(default)
            .ok_or("screen_state_invalid_definition")?;
        if !n.is_finite() || n < minimum || n > maximum {
            return Err("screen_state_invalid_definition");
        }
    }
    Ok(())
}
fn content(id: &str, v: &Value) -> Result<()> {
    object(v)?;
    if text(v, "objectID")? != id || v["title"].as_str().is_none() {
        return Err("screen_state_invalid_content");
    }
    let raw = v["url"]
        .as_str()
        .filter(|s| s.chars().count() <= 2048)
        .ok_or("screen_state_invalid_content")?;
    let url = reqwest::Url::parse(raw).map_err(|_| "screen_state_invalid_content")?;
    if url.scheme() != "https" || url.host_str().is_none() {
        return Err("screen_state_invalid_content");
    }
    match v["kind"].as_str() {
        Some("native_link") => {}
        Some("official_embed") => {
            let query: std::collections::HashMap<_, _> = url.query_pairs().collect();
            let valid = match url.host_str().unwrap() {
                "youtube.com"
                | "www.youtube.com"
                | "youtube-nocookie.com"
                | "www.youtube-nocookie.com" => {
                    url.path().strip_prefix("/embed/").is_some_and(|id| {
                        id.len() == 11
                            && id
                                .bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"_-".contains(&b))
                    })
                }
                "player.bilibili.com" => {
                    url.path().starts_with("/player.html")
                        && (query.get("aid").is_some_and(|v| !v.is_empty())
                            || query.get("bvid").is_some_and(|v| {
                                v.starts_with("BV")
                                    && v.chars().count() == 12
                                    && v.chars().all(char::is_alphanumeric)
                            }))
                }
                "player.twitch.tv" => {
                    query.get("channel").is_some_and(|v| !v.is_empty())
                        || query.get("video").is_some_and(|v| !v.is_empty())
                }
                _ => false,
            };
            if !valid {
                return Err("screen_state_invalid_content");
            }
        }
        _ => return Err("screen_state_invalid_content"),
    };
    Ok(())
}
fn record(v: &Value) -> Result<()> {
    if crate::canonical_json::to_string(v)
        .map_err(|_| "screen_state_invalid_record")?
        .len()
        > 1024 * 1024
    {
        return Err("screen_state_limit");
    }
    object(v)?;
    for (kind, validate) in [
        ("definitions", definition as fn(&str, &Value) -> Result<()>),
        ("contents", content as fn(&str, &Value) -> Result<()>),
    ] {
        let values = object(&v[kind])?;
        if values.len() > 2048 {
            return Err("screen_state_limit");
        }
        for (id, value) in values {
            if id.is_empty() || id.chars().count() > 256 {
                return Err("screen_state_invalid_record");
            }
            validate(id, value)?;
        }
    }
    Ok(())
}
fn read(c: &Connection, world: &str) -> Result<Value> {
    let row = c
        .query_row(
            "SELECT revision,payload FROM screen_state_records WHERE world=?1",
            [world],
            |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    let (revision, value) = if let Some((revision, raw)) = row {
        (
            revision,
            serde_json::from_str(&raw).map_err(|_| "screen_state_invalid_record")?,
        )
    } else {
        (0, json!({"definitions":{},"contents":{}}))
    };
    record(&value)?;
    Ok(json!({"worldID":world,"revision":revision,"record":value}))
}
pub fn request(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let world = text(p, "worldID")?;
    if method == "screen_state_read" {
        return read(c, world);
    }
    if method != "screen_state_mutate" {
        return Err("unknown_method");
    }
    let request = text(p, "requestID")?;
    let id = text(p, "objectID")?;
    let canonical =
        crate::canonical_json::to_string(p).map_err(|_| "screen_state_invalid_input")?;
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let prior = tx
        .query_row(
            "SELECT input,output FROM screen_state_commands WHERE world=?1 AND request=?2",
            params![world, request],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((input, output)) = prior {
        if input != canonical {
            return Err("screen_state_receipt_conflict");
        }
        return serde_json::from_str(&output).map_err(|_| "screen_state_invalid_record");
    }
    let mut snapshot = read(&tx, world)?;
    if p["expectedRevision"].as_i64() != snapshot["revision"].as_i64() {
        return Err("screen_state_revision_conflict");
    }
    match text(p, "operation")? {
        "definition" => {
            if !p["value"].is_null() {
                definition(id, &p["value"])?;
                snapshot["record"]["definitions"][id] = p["value"].clone();
            } else {
                snapshot["record"]["definitions"]
                    .as_object_mut()
                    .unwrap()
                    .remove(id);
            }
        }
        "content" => {
            content(id, &p["value"])?;
            snapshot["record"]["contents"][id] = p["value"].clone();
        }
        "remove" => {
            snapshot["record"]["definitions"]
                .as_object_mut()
                .unwrap()
                .remove(id);
            snapshot["record"]["contents"]
                .as_object_mut()
                .unwrap()
                .remove(id);
        }
        _ => return Err("screen_state_invalid_input"),
    };
    record(&snapshot["record"])?;
    snapshot["revision"] = json!(snapshot["revision"]
        .as_i64()
        .unwrap()
        .checked_add(1)
        .ok_or("screen_state_limit")?);
    let payload = crate::canonical_json::to_string(&snapshot["record"])
        .map_err(|_| "screen_state_invalid_record")?;
    tx.execute("INSERT INTO screen_state_records VALUES(?1,?2,?3) ON CONFLICT(world) DO UPDATE SET revision=excluded.revision,payload=excluded.payload",params![world,snapshot["revision"].as_i64(),payload]).map_err(|_|"storage_unavailable")?;
    tx.execute(
        "INSERT INTO screen_state_commands VALUES(?1,?2,?3,?4)",
        params![world, request, canonical, snapshot.to_string()],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(snapshot)
}

pub fn import(c: &mut Connection, root: &Path, p: &Value) -> Result<Value> {
    let requested = PathBuf::from(
        p["legacyPath"]
            .as_str()
            .ok_or("screen_state_invalid_input")?,
    );
    if !requested.is_absolute()
        || requested.file_name().and_then(|s| s.to_str()) != Some("ScreenState.json")
    {
        return Err("screen_state_unsafe_legacy_path");
    }
    let parent = requested
        .parent()
        .and_then(|p| p.canonicalize().ok())
        .ok_or("screen_state_unsafe_legacy_path")?;
    let root = root.canonicalize().map_err(|_| "storage_unavailable")?;
    if parent != root && Some(parent.as_path()) != root.parent() {
        return Err("screen_state_unsafe_legacy_path");
    }
    if requested.ancestors().any(|path| {
        std::fs::symlink_metadata(path).is_ok_and(|metadata| metadata.file_type().is_symlink())
    }) {
        return Err("screen_state_legacy_unreadable");
    }
    // The existing file guard rejects all symlink ancestors and never writes legacy bytes.
    let canonical = parent.join("ScreenState.json");
    let source = canonical
        .to_str()
        .ok_or("screen_state_unsafe_legacy_path")?
        .to_owned();
    let prior = c
        .query_row(
            "SELECT receipt FROM screen_state_imports WHERE source=?1",
            [&source],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some(prior) = prior {
        let mut receipt: Value =
            serde_json::from_str(&prior).map_err(|_| "screen_state_invalid_record")?;
        receipt["alreadyImported"] = json!(true);
        return Ok(receipt);
    }
    let metadata = std::fs::symlink_metadata(&requested);
    let bytes = match metadata {
        Ok(_) => Some(
            files::read(&requested, 8 * 1024 * 1024)
                .map_err(|_| "screen_state_legacy_unreadable")?,
        ),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(_) => return Err("screen_state_legacy_unreadable"),
    };
    let document = if let Some(bytes) = &bytes {
        serde_json::from_slice::<Value>(bytes).map_err(|_| "screen_state_legacy_invalid")?
    } else {
        json!({"worlds":{}})
    };
    let worlds = object(&document["worlds"])?;
    if worlds.len() > 256 {
        return Err("screen_state_limit");
    }
    for (world, value) in worlds {
        if world.is_empty() || world.chars().count() > 256 {
            return Err("screen_state_legacy_invalid");
        }
        record(value)?;
    }
    let digest = bytes
        .as_ref()
        .map(|b| format!("{:x}", Sha256::digest(b)))
        .unwrap_or_else(|| "missing".to_owned());
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let mut inserted = 0;
    for (world, value) in worlds {
        let existing = tx
            .query_row(
                "SELECT payload FROM screen_state_records WHERE world=?1",
                [world],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map_err(|_| "storage_unavailable")?;
        if let Some(raw) = existing {
            let old: Value =
                serde_json::from_str(&raw).map_err(|_| "screen_state_invalid_record")?;
            if old != *value {
                return Err("screen_state_import_conflict");
            }
            continue;
        }
        tx.execute(
            "INSERT INTO screen_state_records VALUES(?1,1,?2)",
            params![
                world,
                crate::canonical_json::to_string(value)
                    .map_err(|_| "screen_state_invalid_record")?
            ],
        )
        .map_err(|_| "storage_unavailable")?;
        inserted += 1;
    }
    let receipt = json!({"importedWorlds":inserted,"alreadyImported":false,"legacyMissing":bytes.is_none(),"sha256":digest});
    tx.execute(
        "INSERT INTO screen_state_imports VALUES(?1,?2,?3)",
        params![source, digest, receipt.to_string()],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(receipt)
}
pub struct ScreenStateService {
    db: Database,
}
impl ScreenStateService {
    pub fn new(db: Database) -> Self {
        Self { db }
    }
    pub async fn request(&self, method: &str, p: &Value) -> Result<Value> {
        let method = method.to_owned();
        let p = p.clone();
        self.db
            .call(move |store| {
                if method == "screen_state_import" {
                    import(&mut store.connection, &store.root, &p)
                } else {
                    request(&mut store.connection, &method, &p)
                }
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn definition_value() -> Value {
        json!({"objectID":"tv","source":"calibrated","center":[0,1,0],"yaw":0,"pitch":0,"halfWidth":1,"halfHeight":0.5,"note":"fixture"})
    }
    #[test]
    fn real_sqlite_cas_and_exact_duplicate() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let p = json!({"worldID":"w","objectID":"tv","requestID":"definition","expectedRevision":0,"operation":"definition","value":definition_value()});
        let first = request(&mut c, "screen_state_mutate", &p).unwrap();
        assert_eq!(first["revision"], 1);
        assert_eq!(request(&mut c, "screen_state_mutate", &p).unwrap(), first);
        let mut stale = p.clone();
        stale["requestID"] = json!("stale");
        assert_eq!(
            request(&mut c, "screen_state_mutate", &stale).unwrap_err(),
            "screen_state_revision_conflict"
        );
        let mut conflict = p;
        conflict["value"]["note"] = json!("changed");
        assert_eq!(
            request(&mut c, "screen_state_mutate", &conflict).unwrap_err(),
            "screen_state_receipt_conflict"
        );
    }
    #[test]
    fn legacy_read_only_import_reopen_and_malformed_fail_closed() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-screen-state-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let file = root.join("ScreenState.json");
        std::fs::write(&file, b"invalid json").unwrap();
        let database = root.join("private.sqlite");
        let mut c = Connection::open(&database).unwrap();
        schema(&c).unwrap();
        let p = json!({"legacyPath":file});
        assert_eq!(
            import(&mut c, &root, &p).unwrap_err(),
            "screen_state_legacy_invalid"
        );
        let document = json!({"worlds":{"w":{"definitions":{"tv":definition_value()},"contents":{"tv":{"objectID":"tv","kind":"native_link","url":"https://www.youtube.com/watch?v=aaaaaaaaaaa&list=PLfixture","title":"fixture"}}}}});
        let bytes = serde_json::to_vec(&document).unwrap();
        std::fs::write(&file, &bytes).unwrap();
        assert_eq!(import(&mut c, &root, &p).unwrap()["importedWorlds"], 1);
        assert_eq!(std::fs::read(&file).unwrap(), bytes);
        drop(c);
        let mut reopened = Connection::open(&database).unwrap();
        assert_eq!(
            import(&mut reopened, &root, &p).unwrap()["alreadyImported"],
            true
        );
        assert_eq!(
            request(&mut reopened, "screen_state_read", &json!({"worldID":"w"})).unwrap()["record"],
            document["worlds"]["w"]
        );
    }
    #[test]
    fn import_never_overwrites_existing_world_and_rejects_symlink() {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("gmgn-screen-conflict-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        request(&mut c,"screen_state_mutate",&json!({"worldID":"w","objectID":"tv","requestID":"d","expectedRevision":0,"operation":"definition","value":definition_value()})).unwrap();
        let file = root.join("ScreenState.json");
        std::fs::write(
            &file,
            b"{\"worlds\":{\"w\":{\"definitions\":{},\"contents\":{}}}}",
        )
        .unwrap();
        assert_eq!(
            import(&mut c, &root, &json!({"legacyPath":file})).unwrap_err(),
            "screen_state_import_conflict"
        );
        assert_eq!(
            c.query_row("SELECT count(*) FROM screen_state_imports", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        #[cfg(unix)]
        {
            let alias = root.join("alias");
            std::os::unix::fs::symlink(&root, &alias).unwrap();
            assert_eq!(
                import(
                    &mut c,
                    &root,
                    &json!({"legacyPath":alias.join("ScreenState.json")})
                )
                .unwrap_err(),
                "screen_state_legacy_unreadable"
            );
        }
    }
}
