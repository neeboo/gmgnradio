//! Generation configuration authority. SQL contains metadata only; secrets remain private files.
use crate::{
    canonical_json,
    files,
    model::{self, Result},
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS generation_configuration(singleton INTEGER PRIMARY KEY CHECK(singleton=1),revision INTEGER NOT NULL,endpoint TEXT,secret_ref TEXT,imported INTEGER NOT NULL);CREATE TABLE IF NOT EXISTS generation_configuration_requests(request TEXT PRIMARY KEY,digest TEXT NOT NULL,response TEXT NOT NULL);").map_err(|_|"storage_unavailable")
}
fn secret_root(root: &Path) -> Result<PathBuf> {
    let parent = root
        .parent()
        .ok_or("generation_configuration_invalid_request")?;
    let directory = parent.join("secrets");
    // Delegate to the crate-wide private-storage policy instead of hand-rolling
    // one here. unix: create/re-secure with mode 0700 behind an
    // `O_NOFOLLOW|O_DIRECTORY` handle, and reject symlinked ancestors. Windows:
    // create it with a protected DACL granting only the current user. Windows
    // has no mode bits, so 0700 has no literal equivalent there — the protected
    // DACL is the equivalent control.
    files::directory(&directory).map_err(|_| "generation_configuration_secret_unavailable")?;
    Ok(directory)
}
fn identifier(v: &Value) -> Result<&str> {
    let id = v
        .as_str()
        .ok_or("generation_configuration_invalid_request")?;
    uuid::Uuid::parse_str(id).map_err(|_| "generation_configuration_invalid_request")?;
    Ok(id)
}
fn read_leaf(root: &Path, reference: &str, limit: u64) -> Result<Vec<u8>> {
    identifier(&json!(reference))?;
    let path = secret_root(root)?.join(format!("generation-{reference}.secret"));
    let metadata =
        fs::symlink_metadata(&path).map_err(|_| "generation_configuration_secret_unavailable")?;
    if !metadata.is_file() || metadata.len() > limit {
        return Err("generation_configuration_secret_unavailable");
    }
    // unix: a secret that group or other can touch at all is not private, no
    // matter who wrote it — re-check the mode here instead of trusting the
    // writer. Windows has no mode bits, so nothing is checked from metadata
    // there; confidentiality is the file's protected DACL and `files::read`
    // additionally refuses reparse points and hard-linked leaves.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err("generation_configuration_secret_unavailable");
        }
    }
    // `files::read` opens with `O_NOFOLLOW` (unix) or `FILE_FLAG_OPEN_REPARSE_POINT`
    // plus a link-count check (Windows), so swapping the leaf for a symlink
    // between the metadata read above and the open cannot redirect the read.
    files::read(&path, limit as usize).map_err(|_| "generation_configuration_secret_unavailable")
}
fn token(bytes: Vec<u8>) -> Result<String> {
    let value = String::from_utf8(bytes).map_err(|_| "invalid_token")?;
    if value.is_empty() || value.len() > 8192 || !value.bytes().all(|b| (33..=126).contains(&b)) {
        return Err("invalid_token");
    }
    Ok(value)
}
fn store_secret(root: &Path, id: &str, token: &str) -> Result<String> {
    let digest = Sha256::digest(format!("generation-config:{id}").as_bytes());
    let reference = uuid::Uuid::from_bytes(
        digest[..16]
            .try_into()
            .map_err(|_| "generation_configuration_invalid_request")?,
    )
    .to_string();
    let path = secret_root(root)?.join(format!("generation-{reference}.secret"));
    // `create_new_private` keeps create-new semantics on both platforms (unix
    // `O_CREAT|O_EXCL` mode 0600; Windows `CREATE_NEW` + protected DACL) so the
    // `AlreadyExists` arm below stays reachable, which is what makes a retried
    // identical request idempotent while a different token is a conflict.
    match files::create_new_private(&path) {
        Ok(mut file) => {
            file.write_all(token.as_bytes())
                .and_then(|_| file.sync_all())
                .map_err(|_| "generation_configuration_secret_unavailable")?;
        }
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            if read_leaf(root, &reference, 8192)? != token.as_bytes() {
                return Err("request_conflict");
            }
        }
        Err(_) => return Err("generation_configuration_secret_unavailable"),
    }
    Ok(reference)
}
pub fn snapshot(c: &Connection) -> Result<Value> {
    let row:Option<(i64,Option<String>,Option<String>,bool)>=c.query_row("SELECT revision,endpoint,secret_ref,imported FROM generation_configuration WHERE singleton=1",[],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?))).optional().map_err(|_|"storage_unavailable")?;
    let (revision, endpoint, reference, imported) = row.unwrap_or((0, None, None, false));
    Ok(
        json!({"revision":revision,"endpoint":endpoint,"secretRef":reference,"imported":imported,"configured":endpoint.is_some()&&reference.is_some()}),
    )
}
pub fn dispatch(c: &mut Connection, root: &Path, method: &str, p: &Value) -> Result<Value> {
    if method == "generation_configuration_read" {
        if p.as_object()
            .is_none_or(|o| o.keys().any(|k| k != "endpoint"))
        {
            return Err("generation_configuration_invalid_request");
        }
        let result = snapshot(c)?;
        if let Some(raw) = p.get("endpoint") {
            let origin = model::endpoint(raw.as_str().ok_or("invalid_endpoint")?.trim())?;
            if result["endpoint"].as_str() != Some(origin.as_str()) {
                return Err("generation_endpoint_requires_token");
            }
        }
        return Ok(result);
    }
    let allowed = if method == "generation_configuration_import" {
        vec![
            "requestID",
            "expectedRevision",
            "currentExists",
            "currentRef",
            "legacyRef",
        ]
    } else if method == "generation_configuration_save" {
        vec!["requestID", "expectedRevision", "endpoint", "tokenRef"]
    } else {
        return Err("method_not_found");
    };
    if p.as_object()
        .is_none_or(|o| o.keys().any(|k| !allowed.contains(&k.as_str())))
    {
        return Err("generation_configuration_invalid_request");
    }
    let id = identifier(&p["requestID"])?;
    let digest = format!(
        "{:x}",
        Sha256::digest(
            canonical_json::to_vec(&json!({"method":method,"params":p}))
                .map_err(|_| "generation_configuration_invalid_request")?
        )
    );
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    if let Some((old, response)) = tx
        .query_row(
            "SELECT digest,response FROM generation_configuration_requests WHERE request=?",
            [id],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?
    {
        if old != digest {
            return Err("request_conflict");
        }
        return serde_json::from_str(&response).map_err(|_| "storage_unavailable");
    }
    let before = snapshot(&tx)?;
    if p["expectedRevision"].as_i64() != before["revision"].as_i64() {
        return Err("revision_conflict");
    }
    let mut endpoint = before["endpoint"].as_str().map(str::to_owned);
    let mut reference = before["secretRef"].as_str().map(str::to_owned);
    if method == "generation_configuration_import" {
        if !before["imported"].as_bool().unwrap_or(false) {
            let exists = p["currentExists"]
                .as_bool()
                .ok_or("generation_configuration_invalid_request")?;
            let candidate = if exists {
                p["currentRef"]
                    .as_str()
                    .ok_or("generation_configuration_legacy_unreadable")
                    .map(Some)?
            } else {
                p["legacyRef"].as_str()
            };
            if let Some(candidate) = candidate {
                let raw = read_leaf(root, candidate, 32768)?;
                let old: Value = serde_json::from_slice(&raw)
                    .map_err(|_| "generation_configuration_legacy_unreadable")?;
                let origin = model::endpoint(old["endpoint"].as_str().ok_or("invalid_endpoint")?)?;
                let secret = token(
                    old["token"]
                        .as_str()
                        .ok_or("invalid_token")?
                        .as_bytes()
                        .to_vec(),
                )?;
                endpoint = Some(origin);
                reference = Some(store_secret(root, id, &secret)?);
            }
        }
    } else {
        let origin = model::endpoint(p["endpoint"].as_str().ok_or("invalid_endpoint")?.trim())?;
        if let Some(staged) = p["tokenRef"].as_str() {
            let secret = token(read_leaf(root, staged, 8192)?)?;
            reference = Some(store_secret(root, id, &secret)?);
        } else if p["tokenRef"].is_null() {
            if endpoint.as_deref() != Some(origin.as_str()) || reference.is_none() {
                return Err("generation_endpoint_requires_token");
            }
            token(read_leaf(root, reference.as_deref().unwrap(), 8192)?)?;
        } else {
            return Err("generation_configuration_invalid_request");
        }
        endpoint = Some(origin);
    }
    let revision = before["revision"]
        .as_i64()
        .unwrap()
        .checked_add(1)
        .ok_or("generation_configuration_invalid_request")?;
    tx.execute("INSERT INTO generation_configuration VALUES(1,?,?,?,1) ON CONFLICT(singleton) DO UPDATE SET revision=excluded.revision,endpoint=excluded.endpoint,secret_ref=excluded.secret_ref,imported=1",params![revision,endpoint,reference]).map_err(|_|"storage_unavailable")?;
    let result = snapshot(&tx)?;
    tx.execute(
        "INSERT INTO generation_configuration_requests VALUES(?,?,?)",
        params![id, digest, result.to_string()],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        root: PathBuf,
        parent: PathBuf,
        connection: Connection,
    }
    impl Fixture {
        fn new() -> Self {
            let parent =
                std::env::temp_dir().join(format!("gmgn-generation-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&parent).unwrap();
            let parent = fs::canonicalize(parent).unwrap();
            let root = parent.join("TaskService");
            fs::create_dir(&root).unwrap();
            let connection = Connection::open(root.join("tasks.sqlite3")).unwrap();
            schema(&connection).unwrap();
            Self {
                root,
                parent,
                connection,
            }
        }
        fn stage(&self, bytes: &[u8]) -> String {
            let id = uuid::Uuid::new_v4().to_string();
            let file = secret_root(&self.root)
                .unwrap()
                .join(format!("generation-{id}.secret"));
            let mut f = files::create_new_private(&file).unwrap();
            f.write_all(bytes).unwrap();
            id
        }
        fn call(&mut self, m: &str, p: Value) -> Result<Value> {
            dispatch(&mut self.connection, &self.root, m, &p)
        }
        fn empty_import(&mut self) -> Value {
            self.call("generation_configuration_import",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":0,"currentExists":false})).unwrap()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.parent);
        }
    }
    #[test]
    fn endpoint_token_binding_cas_and_no_secret_sql() {
        let mut f = Fixture::new();
        let before = f.empty_import();
        let staged = f.stage(b"synthetic-secret-one");
        let saved=f.call("generation_configuration_save",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":before["revision"],"endpoint":"https://EXAMPLE.com:443/","tokenRef":staged})).unwrap();
        assert_eq!(saved["endpoint"], "https://example.com");
        let same=f.call("generation_configuration_save",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":saved["revision"],"endpoint":"https://example.com","tokenRef":null})).unwrap();
        assert_eq!(same["secretRef"], saved["secretRef"]);
        assert_eq!(f.call("generation_configuration_save",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":same["revision"],"endpoint":"https://other.example","tokenRef":null})),Err("generation_endpoint_requires_token"));
        assert_eq!(f.call("generation_configuration_save",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":0,"endpoint":"https://example.com","tokenRef":null})),Err("revision_conflict"));
        let sql: String = f
            .connection
            .query_row(
                "SELECT group_concat(response,'') FROM generation_configuration_requests",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert!(!sql.contains("synthetic-secret"));
        assert!(!same.to_string().contains("synthetic-secret"));
    }
    #[test]
    fn import_current_failure_blocks_legacy_and_explicit_repair() {
        let mut f = Fixture::new();
        let legacy =
            f.stage(br#"{"endpoint":"https://legacy.example","token":"synthetic-old-secret"}"#);
        assert_eq!(f.call("generation_configuration_import",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":0,"currentExists":true,"legacyRef":legacy})),Err("generation_configuration_legacy_unreadable"));
        let corrupt = f.stage(b"bad-json");
        assert_eq!(f.call("generation_configuration_import",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":0,"currentExists":true,"currentRef":corrupt,"legacyRef":legacy})),Err("generation_configuration_legacy_unreadable"));
        assert_eq!(snapshot(&f.connection).unwrap()["revision"], 0);
        let fresh = f.stage(b"synthetic-repair-secret");
        let fixed=f.call("generation_configuration_save",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":0,"endpoint":"https://fresh.example","tokenRef":fresh})).unwrap();
        assert_eq!(fixed["endpoint"], "https://fresh.example");
        assert_eq!(fixed["imported"], true);
    }
    #[test]
    fn restart_lost_receipt_nested_key_order_and_conflict() {
        let mut f = Fixture::new();
        f.empty_import();
        let secret = f.stage(b"synthetic-key");
        let id = uuid::Uuid::new_v4();
        let first = json!({"requestID":id,"expectedRevision":1,"endpoint":"https://example.com","tokenRef":secret});
        let output = f
            .call("generation_configuration_save", first.clone())
            .unwrap();
        let mut reopened = Connection::open(f.root.join("tasks.sqlite3")).unwrap();
        let reordered:Value=serde_json::from_str(&format!(r#"{{"tokenRef":"{secret}","endpoint":"https://example.com","expectedRevision":1,"requestID":"{id}"}}"#)).unwrap();
        assert_eq!(
            dispatch(
                &mut reopened,
                &f.root,
                "generation_configuration_save",
                &reordered
            )
            .unwrap(),
            output
        );
        let mut changed = first;
        changed["endpoint"] = json!("https://different.example");
        assert_eq!(
            dispatch(
                &mut reopened,
                &f.root,
                "generation_configuration_save",
                &changed
            ),
            Err("request_conflict")
        );
        assert_eq!(snapshot(&reopened).unwrap(), output);
    }
    // Unix-only: creating the symlink needs `std::os::unix::fs::symlink`, and on
    // Windows an unprivileged process cannot create one at all. The equivalent
    // Windows attack surface (reparse points / hard links) is covered by
    // `files::reject_links`, `files::read` and `files::directory`, but cannot be
    // exercised from a normal Windows test process.
    #[cfg(unix)]
    #[test]
    fn symlink_and_outside_ref_rejected_without_state_change() {
        let mut f = Fixture::new();
        f.empty_import();
        let secret = f.stage(b"synthetic-key");
        let leaf = secret_root(&f.root)
            .unwrap()
            .join(format!("generation-{secret}.secret"));
        fs::remove_file(&leaf).unwrap();
        std::os::unix::fs::symlink(f.parent.join("outside"), leaf).unwrap();
        assert_eq!(f.call("generation_configuration_save",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":1,"endpoint":"https://example.com","tokenRef":secret})),Err("generation_configuration_secret_unavailable"));
        assert_eq!(f.call("generation_configuration_save",json!({"requestID":uuid::Uuid::new_v4(),"expectedRevision":1,"endpoint":"https://example.com","tokenRef":"../../outside"})),Err("generation_configuration_invalid_request"));
        assert_eq!(snapshot(&f.connection).unwrap()["revision"], 1);
    }
}
