use crate::{
    files, memory, messages,
    model::{self, Job, Result, Stored, Submit, MODEL_LIMIT, PNG_LIMIT},
    resident,
};
use base64::Engine;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::mpsc,
};
use tokio::sync::{oneshot, watch};

type Command = Box<dyn FnOnce(&mut Store) + Send>;
#[derive(Clone)]
pub struct Database {
    tx: mpsc::Sender<Command>,
    pub changed: watch::Sender<u64>,
}
pub struct Store {
    pub connection: Connection,
    pub root: PathBuf,
    pub changed: watch::Sender<u64>,
}

impl Database {
    pub fn open(root: PathBuf, legacy: Option<PathBuf>) -> Result<Self> {
        let (tx, rx) = mpsc::channel::<Command>();
        let (changed, _) = watch::channel(0);
        let change = changed.clone();
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        std::thread::Builder::new()
            .name("taskd-storage".into())
            .spawn(move || {
                let initialized = Store::open(root, change).and_then(|mut s| {
                    s.import(legacy)?;
                    s.recover()?;
                    Ok(s)
                });
                match initialized {
                    Ok(mut store) => {
                        let _ = ready_tx.send(Ok(()));
                        while let Ok(command) = rx.recv() {
                            command(&mut store);
                        }
                    }
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                    }
                }
            })
            .map_err(|_| "storage_unavailable")?;
        ready_rx.recv().map_err(|_| "storage_unavailable")??;
        Ok(Self { tx, changed })
    }
    pub async fn call<T: Send + 'static>(
        &self,
        action: impl FnOnce(&mut Store) -> Result<T> + Send + 'static,
    ) -> Result<T> {
        let (tx, rx) = oneshot::channel();
        self.tx
            .send(Box::new(move |store| {
                let _ = tx.send(action(store));
            }))
            .map_err(|_| "storage_unavailable")?;
        rx.await.map_err(|_| "storage_unavailable")?
    }
}

/// Versioned schema migrations over the one tasks.sqlite3.
///
/// Version 1 is the original job/event/message schema. Its DDL is idempotent
/// (`IF NOT EXISTS`) so opening an existing install records version 1 without
/// touching any row. Version 2 adds the resident state/event/message tables.
/// Version 3 adds the memory storage tables (memory-storage-v1). Every step
/// commits inside its own transaction; a failed step rolls back and leaves the
/// database at its previous version, so an upgrade failure never corrupts an
/// existing store.
fn migrate(connection: &mut Connection) -> Result<()> {
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, name TEXT NOT NULL);",
        )
        .map_err(|_| "storage_unavailable")?;
    let applied: i64 = connection
        .query_row(
            "SELECT COALESCE(MAX(version),0) FROM schema_migrations",
            [],
            |row| row.get(0),
        )
        .map_err(|_| "storage_unavailable")?;
    if applied < 1 {
        apply_step(connection, 1, "taskd-v1", |connection| {
            connection
                .execute_batch(
                    "CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, data TEXT NOT NULL);
                    CREATE TABLE IF NOT EXISTS events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, job TEXT NOT NULL);
                    CREATE INDEX IF NOT EXISTS events_identity_sequence ON events(json_extract(job,'$.id'),sequence);
                    CREATE TABLE IF NOT EXISTS migrations(path TEXT PRIMARY KEY);",
                )
                .map_err(|_| "storage_unavailable")?;
            messages::init_schema(connection).map_err(|e| e.code)
        })?;
    }
    if applied < 2 {
        apply_step(connection, 2, "resident-storage-v1", |connection| {
            resident::schema(connection).map_err(|e| e.code)
        })?;
    }
    if applied < 3 {
        apply_step(connection, 3, "memory-storage-v1", memory::schema)?;
    }
    Ok(())
}

fn apply_step(
    connection: &mut Connection,
    version: i64,
    name: &str,
    apply: impl Fn(&Connection) -> Result<()>,
) -> Result<()> {
    // The step's DDL and the version row share one transaction; dropping the
    // transaction on error rolls the step back completely, so a failed
    // migration leaves the database at its previous version.
    let tx = connection
        .transaction()
        .map_err(|_| "storage_unavailable")?;
    if let Err(code) = apply(&tx) {
        drop(tx);
        return Err(code);
    }
    tx.execute(
        "INSERT INTO schema_migrations(version,name) VALUES(?1,?2)",
        params![version, name],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")
}

impl Store {
    fn open(root: PathBuf, changed: watch::Sender<u64>) -> Result<Self> {
        let path = root.join("tasks.sqlite3");
        files::open_private(&path)?;
        for suffix in [
            "tasks.sqlite3-journal",
            "tasks.sqlite3-wal",
            "tasks.sqlite3-shm",
        ] {
            let p = root.join(suffix);
            if let Ok(m) = std::fs::symlink_metadata(p) {
                if !m.is_file() || m.file_type().is_symlink() {
                    return Err("unsafe_path");
                }
            }
        }
        // sqlite-vec registers through sqlite3_auto_extension before the first
        // connection opens; every later connection in this process gets the
        // vec0 module, so per-scope partitions can be created on demand.
        crate::memory::register_vec();
        let mut connection = Connection::open(path).map_err(|_| "storage_unavailable")?;
        connection
            .execute_batch(
                "PRAGMA journal_mode=DELETE; PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;",
            )
            .map_err(|_| "storage_unavailable")?;
        migrate(&mut connection)?;
        Ok(Self {
            connection,
            root,
            changed,
        })
    }    pub fn all(&self) -> Result<Vec<Stored>> {
        let mut stmt = self
            .connection
            .prepare("SELECT data FROM jobs ORDER BY rowid")
            .map_err(|_| "storage_unavailable")?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|_| "storage_unavailable")?;
        rows.map(|r| {
            serde_json::from_str(&r.map_err(|_| "storage_unavailable")?)
                .map_err(|_| "history_unavailable")
        })
        .collect()
    }
    pub fn get(&self, id: &str) -> Result<Stored> {
        let data: Option<String> = self
            .connection
            .query_row("SELECT data FROM jobs WHERE id=?1", [id], |r| r.get(0))
            .optional()
            .map_err(|_| "storage_unavailable")?;
        serde_json::from_str(&data.ok_or("missing_task")?).map_err(|_| "history_unavailable")
    }
    pub fn save(&mut self, value: &Stored) -> Result<()> {
        match self.get(&value.job.id) {
            Ok(old) if old.job == value.job && old.attempted == value.attempted => return Ok(()),
            Ok(_) | Err("missing_task") => {}
            Err(code) => return Err(code),
        }
        let serialized = serde_json::to_string(value).map_err(|_| "invalid_input")?;
        let job = serde_json::to_string(&value.job).map_err(|_| "invalid_input")?;
        let tx = self
            .connection
            .transaction()
            .map_err(|_| "storage_unavailable")?;
        tx.execute("INSERT INTO jobs(id,data) VALUES(?1,?2) ON CONFLICT(id) DO UPDATE SET data=excluded.data", params![value.job.id,serialized]).map_err(|_| "storage_unavailable")?;
        tx.execute("INSERT INTO events(job) VALUES(?1)", [job])
            .map_err(|_| "storage_unavailable")?;
        let sequence = tx.last_insert_rowid();
        if let Some(context) = &value.job.context {
            messages::publish(&tx, &messages::NewMessage {
                id: uuid::Uuid::new_v4().to_string(), task_id: value.job.id.clone(),
                world_id: context.world_id.clone(), resident_scope: context.resident_scope.clone(),
                kind: "task.stateChanged".into(), payload: json!({"backendStage":value.job.backend_stage,"cancelRequested":value.job.cancel_requested,"lastError":value.job.last_error}),
            }).map_err(|e| e.code)?;
        }
        tx.commit().map_err(|_| "storage_unavailable")?;
        self.changed.send_modify(|v| *v = sequence as u64);
        Ok(())
    }
    pub fn snapshot(&self, cursor: Option<String>) -> Result<Value> {
        let latest: i64 = self
            .connection
            .query_row("SELECT COALESCE(MAX(sequence),0) FROM events", [], |r| {
                r.get(0)
            })
            .map_err(|_| "storage_unavailable")?;
        let (sequence, after) = if let Some(cursor) = cursor {
            if cursor.len() > 512 {
                return Err("invalid_cursor");
            }
            let decoded = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(cursor)
                .map_err(|_| "invalid_cursor")?;
            let cursor: Value = serde_json::from_slice(&decoded).map_err(|_| "invalid_cursor")?;
            let sequence = cursor["sequence"]
                .as_i64()
                .filter(|s| *s >= 0 && *s <= latest)
                .ok_or("invalid_cursor")?;
            let after = model::identity(cursor["after"].as_str().ok_or("invalid_cursor")?)
                .map_err(|_| "invalid_cursor")?;
            (sequence, after)
        } else {
            (latest, String::new())
        };
        // Every page reads the same historical event boundary, including if tasks
        // change or are added between pages. Events after this sequence reconcile
        // the completed snapshot through the existing subscription protocol.
        let mut statement = self
            .connection
            .prepare(
                "SELECT job FROM events WHERE sequence IN (
            SELECT MAX(sequence) FROM events WHERE sequence<=?1 GROUP BY json_extract(job,'$.id'))
            AND json_extract(job,'$.id')>?2 ORDER BY json_extract(job,'$.id')",
            )
            .map_err(|_| "storage_unavailable")?;
        let mut rows = statement
            .query(params![sequence, after])
            .map_err(|_| "storage_unavailable")?;
        let mut bytes = 0;
        let mut jobs: Vec<Value> = Vec::new();
        let mut more = false;
        while let Some(row) = rows.next().map_err(|_| "storage_unavailable")? {
            let data: String = row.get(0).map_err(|_| "history_unavailable")?;
            if bytes + data.len() + 1 > 2 * 1024 * 1024 - 4096 || jobs.len() >= 128 {
                if jobs.is_empty() {
                    return Err("history_record_too_large");
                }
                more = true;
                break;
            }
            bytes += data.len() + 1;
            jobs.push(serde_json::from_str(&data).map_err(|_| "history_unavailable")?);
        }
        let next = if more {
            let after = jobs
                .last()
                .and_then(|j| j["id"].as_str())
                .ok_or("history_unavailable")?;
            Some(
                base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(
                    serde_json::to_vec(&json!({"sequence":sequence,"after":after}))
                        .map_err(|_| "history_unavailable")?,
                ),
            )
        } else {
            None
        };
        let mut result = json!({"jobs":jobs,"sequence":sequence});
        if let Some(next) = next {
            result["nextCursor"] = Value::String(next);
        }
        Ok(result)
    }
    pub fn events(&self, after: i64) -> Result<Vec<Value>> {
        let mut stmt = self
            .connection
            .prepare(
                "SELECT sequence,job FROM events WHERE sequence>?1 ORDER BY sequence LIMIT 128",
            )
            .map_err(|_| "storage_unavailable")?;
        let rows = stmt
            .query_map([after], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(|_| "storage_unavailable")?;
        rows.map(|r| {
            let (sequence, data) = r.map_err(|_| "storage_unavailable")?;
            let job: Value = serde_json::from_str(&data).map_err(|_| "history_unavailable")?;
            Ok(json!({"sequence":sequence,"job":job}))
        })
        .collect()
    }
    pub fn submit(&mut self, mut input: Submit) -> Result<Job> {
        let bytes = input.validate()?;
        let hash = model::digest(&bytes);
        let existing = match self.get(&input.id) {
            Ok(value) => Some(value),
            Err("missing_task") => None,
            Err(code) => return Err(code),
        };
        if let Some(existing) = existing {
            let j = existing.job;
            if j.endpoint != input.endpoint
                || j.name != input.name
                || j.source != input.source
                || j.height_meters != input.height_meters
                || j.image_sha256 != hash
                || j.context != input.context
            {
                return Err("idempotency_conflict");
            }
            return Ok(j);
        }
        let path = self.root.join(format!("{}.png", input.id));
        files::publish(&path, &bytes)?;
        let job = Job {
            id: input.id.clone(),
            name: input.name,
            endpoint: input.endpoint,
            image_path: path.to_string_lossy().into(),
            image_sha256: hash,
            height_meters: input.height_meters,
            source: input.source,
            idempotency_key: input.id,
            receipt: None,
            local_model_path: None,
            last_error: None,
            backend_stage: "queued".into(),
            cancel_requested: false,
            context: input.context,
        };
        self.save(&Stored {
            job: job.clone(),
            attempted: false,
        })?;
        Ok(job)
    }
    pub fn cancel(&mut self, id: &str) -> Result<Job> {
        let mut s = self.get(id)?;
        let remote_terminal =
            s.job.receipt.as_ref().is_some_and(|r| {
                [Some("failed"), Some("cancelled")].contains(&r["state"].as_str())
            });
        if s.job.backend_stage == "ready"
            || s.job.backend_stage == "cancelled"
            || remote_terminal
            || (s.job.backend_stage == "failed" && s.job.receipt.is_none())
        {
            return Ok(s.job);
        }
        s.job.cancel_requested = true;
        s.job.backend_stage = if !s.attempted && s.job.receipt.is_none() {
            "cancelled"
        } else if s.job.receipt.is_none() && s.job.backend_stage == "submission_uncertain" {
            "submission_uncertain"
        } else {
            "cancel_requested"
        }
        .into();
        self.save(&s)?;
        Ok(s.job)
    }
    pub fn retry(&mut self, id: &str) -> Result<Job> {
        let mut s = self.get(id)?;
        if s.job.receipt.as_ref().is_some_and(|r| {
            [Some("failed"), Some("cancelled"), Some("interrupted")].contains(&r["state"].as_str())
        }) {
            return Err("terminal_remote_task");
        }
        if ["ready", "cancelled", "submitting"].contains(&s.job.backend_stage.as_str()) {
            return Err("retry_unavailable");
        }
        if s.job.receipt.is_none() {
            s.job.backend_stage = "queued".into();
        } else {
            s.job.backend_stage = model::stage(&s.job).into();
        }
        s.job.last_error = None;
        self.save(&s)?;
        Ok(s.job)
    }
    fn recover(&mut self) -> Result<()> {
        for mut value in self.all()? {
            let j = &mut value.job;
            if j.receipt.is_none()
                && value.attempted
                && ["submitting", "cancel_requested"].contains(&j.backend_stage.as_str())
            {
                j.backend_stage = "submission_uncertain".into();
                j.last_error = Some("submission_uncertain".into());
            }
            if let Some(path) = j.local_model_path.clone() {
                let expected = self.root.join(format!("{}.glb", j.id));
                let valid = Path::new(&path) == expected
                    && files::read(&expected, MODEL_LIMIT)
                        .and_then(|b| {
                            model::validate_glb(&b, j.receipt.as_ref().ok_or("missing_receipt")?)
                        })
                        .is_ok();
                if !valid {
                    j.local_model_path = None;
                    j.backend_stage = "interrupted".into();
                    j.last_error = Some("local_model_unavailable".into());
                }
            }
            self.save(&value)?;
        }
        Ok(())
    }
    fn import(&mut self, legacy: Option<PathBuf>) -> Result<()> {
        let Some(root) = legacy else {
            return Ok(());
        };
        let path = root.join("tasks.json");
        if !path.try_exists().map_err(|_| "legacy_unavailable")? {
            return Ok(());
        }
        if std::fs::symlink_metadata(&root)
            .map_err(|_| "legacy_unavailable")?
            .file_type()
            .is_symlink()
        {
            return Err("unsafe_legacy_path");
        }
        let root = root.canonicalize().map_err(|_| "legacy_unavailable")?;
        let marker = root.to_string_lossy().into_owned();
        let done: bool = self
            .connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM migrations WHERE path=?1)",
                [&marker],
                |r| r.get(0),
            )
            .map_err(|_| "storage_unavailable")?;
        if done {
            return Ok(());
        }
        let values: Vec<Job> = serde_json::from_slice(&files::read(&path, 64 * 1024 * 1024)?)
            .map_err(|_| "legacy_unavailable")?;
        // Validate all rows and private copies before admitting any imported identity.
        let mut prepared = Vec::new();
        for mut job in values {
            job.id = model::identity(&job.id)?;
            job.endpoint = model::endpoint(&job.endpoint)?;
            if model::identity(&job.idempotency_key)? != job.id {
                return Err("invalid_legacy_identity");
            }
            match self.get(&job.id) {
                Ok(_) => continue,
                Err("missing_task") => {}
                Err(code) => return Err(code),
            }
            let source = Path::new(&job.image_path);
            if source.parent().and_then(|p| p.canonicalize().ok()).as_ref() != Some(&root) {
                return Err("unsafe_legacy_path");
            }
            let bytes = files::read(source, PNG_LIMIT)?;
            model::validate_png(&bytes)?;
            if model::digest(&bytes) != job.image_sha256 {
                return Err("legacy_integrity_failed");
            }
            let dest = self.root.join(format!("{}.png", job.id));
            files::publish(&dest, &bytes)?;
            job.image_path = dest.to_string_lossy().into();
            job.last_error = None;
            job.context = None;
            job.backend_stage = if let Some(r) = &job.receipt {
                model::receipt(r, &job)?;
                model::stage(&job)
            } else {
                "submission_uncertain"
            }
            .into();
            if let Some(model_path) = job.local_model_path.take() {
                let source = Path::new(&model_path);
                if source.parent().and_then(|p| p.canonicalize().ok()).as_ref() != Some(&root) {
                    return Err("unsafe_legacy_path");
                }
                let bytes = files::read(source, MODEL_LIMIT)?;
                model::validate_glb(&bytes, job.receipt.as_ref().ok_or("missing_receipt")?)?;
                let dest = self.root.join(format!("{}.glb", job.id));
                files::publish(&dest, &bytes)?;
                job.local_model_path = Some(dest.to_string_lossy().into());
                job.backend_stage = "ready".into();
            }
            prepared.push(Stored {
                job,
                attempted: true,
            });
        }
        for value in prepared {
            self.save(&value)?;
        }
        self.connection
            .execute("INSERT INTO migrations(path) VALUES(?1)", [&marker])
            .map_err(|_| "storage_unavailable")?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn malformed_existing_identity_is_never_replaced_by_save() {
        let connection = Connection::open_in_memory().unwrap();
        connection.execute_batch("CREATE TABLE jobs(id TEXT PRIMARY KEY,data TEXT NOT NULL); CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT,job TEXT NOT NULL);").unwrap();
        let id = "B4B8F45D-F7F8-4584-BC74-C9D3BE3FE413";
        connection
            .execute("INSERT INTO jobs(id,data) VALUES(?1,'corrupt')", [id])
            .unwrap();
        let mut store = Store {
            connection,
            root: PathBuf::from("/unused"),
            changed: watch::channel(0).0,
        };
        let job: Job = serde_json::from_value(json!({"id":id,"name":"test","endpoint":"https://example.invalid","imagePath":"/unused/image.png","imageSHA256":"0".repeat(64),"heightMeters":0.5,"source":{"author":"test","license":"CC0"},"idempotencyKey":id,"backendStage":"queued","cancelRequested":false})).unwrap();
        assert_eq!(
            store.save(&Stored {
                job,
                attempted: false
            }),
            Err("history_unavailable")
        );
        let data: String = store
            .connection
            .query_row("SELECT data FROM jobs WHERE id=?1", [id], |r| r.get(0))
            .unwrap();
        assert_eq!(data, "corrupt");
    }

    #[test]
    fn migration_preserves_v1_database_and_enables_resident_ops() {
        use crate::resident::{self, CommitRequest, Item, Scope};
        use serde_json::json;
        let dir = std::env::temp_dir().join(format!("gmgn-migrate-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("tasks.sqlite3");
        let job_id = "91B2F6C2-96EE-4D4B-8593-7E9EBFC18263";
        let message_id = uuid::Uuid::new_v4().to_string();
        {
            // Exactly the v1 schema the previous binary created.
            let connection = Connection::open(&path).unwrap();
            connection
                .execute_batch("PRAGMA foreign_keys=ON;
                    CREATE TABLE jobs(id TEXT PRIMARY KEY, data TEXT NOT NULL);
                    CREATE TABLE events(sequence INTEGER PRIMARY KEY AUTOINCREMENT, job TEXT NOT NULL);
                    CREATE TABLE migrations(path TEXT PRIMARY KEY);
                    CREATE TABLE messages(sequence INTEGER PRIMARY KEY AUTOINCREMENT,id TEXT NOT NULL UNIQUE,task_id TEXT NOT NULL REFERENCES jobs(id),world_id TEXT NOT NULL,resident_scope TEXT NOT NULL,kind TEXT NOT NULL,payload TEXT NOT NULL);
                    CREATE TABLE message_acks(message_id TEXT NOT NULL REFERENCES messages(id),consumer TEXT NOT NULL CHECK (consumer IN ('world','ui','agent')),PRIMARY KEY(message_id,consumer));")
                .unwrap();
            connection
                .execute("INSERT INTO jobs(id,data) VALUES(?1,'queued')", [job_id])
                .unwrap();
            connection
                .execute(
                    "INSERT INTO events(job) VALUES('{\"id\":\"91B2F6C2-96EE-4D4B-8593-7E9EBFC18263\"}')",
                    [],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO messages(id,task_id,world_id,resident_scope,kind,payload) VALUES(?1,?2,'world-a','resident-a','wish.outputReady','{\"path\":\"model.glb\"}')",
                    params![message_id, job_id],
                )
                .unwrap();
            connection
                .execute(
                    "INSERT INTO message_acks(message_id,consumer) VALUES(?1,'ui')",
                    [&message_id],
                )
                .unwrap();
        }
        let mut connection = Connection::open(&path).unwrap();
        migrate(&mut connection).unwrap();
        let version: i64 = connection
            .query_row(
                "SELECT COALESCE(MAX(version),0) FROM schema_migrations",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(version, 3);
        // v1 rows and the full old message contract survive untouched.
        let jobs: i64 = connection
            .query_row("SELECT COUNT(*) FROM jobs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(jobs, 1);
        let agent =
            messages::pending_after(&connection, "agent", "world-a", "resident-a", 0, 256).unwrap();
        assert_eq!(agent.len(), 1);
        assert!(agent[0].id == message_id.to_lowercase());
        assert!(
            messages::pending_after(&connection, "ui", "world-a", "resident-a", 0, 256)
                .unwrap()
                .is_empty()
        );
        // Resident schema is live on the migrated connection.
        let scope = Scope {
            world_id: "world-a".into(),
            resident_scope: "resident-a".into(),
        };
        let tx = connection.transaction().unwrap();
        resident::commit(
            &tx,
            &CommitRequest {
                scope: scope.clone(),
                domain: "resident".into(),
                key: "mood".into(),
                expected_revision: 0,
                request_id: uuid::Uuid::new_v4().to_string(),
                value: json!({"state": "migrated"}),
                events: vec![Item {
                    id: uuid::Uuid::new_v4().to_string(),
                    kind: "wish.claimed".into(),
                    payload: json!({"by": "resident"}),
                }],
                messages: vec![],
            },
        )
        .unwrap();
        tx.commit().unwrap();
        let record = resident::read_state(&connection, &scope, "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.value, json!({"state": "migrated"}));
        // v3 memory schema is live on the same migrated connection.
        for table in ["memory_snapshots", "memory_requests", "memory_vec_rows"] {
            let count: i64 = connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1",
                    [table],
                    |row| row.get(0),
                )
                .unwrap();
            assert_eq!(count, 1, "{table}");
        }
        assert_eq!(
            resident::read_events(&connection, &scope, 0, 100)
                .unwrap()
                .0
                .len(),
            1
        );
        drop(connection);
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(&dir).unwrap();
    }

    #[test]
    fn failed_migration_step_rolls_back_completely() {
        let mut connection = Connection::open_in_memory().unwrap();
        connection
            .execute_batch(
                "CREATE TABLE schema_migrations(version INTEGER PRIMARY KEY, name TEXT NOT NULL);",
            )
            .unwrap();
        let outcome = apply_step(&mut connection, 99, "must-fail", |connection| {
            // This DDL lands inside the step's transaction...
            connection
                .execute_batch("CREATE TABLE half_done(v INTEGER);")
                .map_err(|_| "storage_unavailable")?;
            // ...then the step fails: the table and the version row must not
            // survive, so the database stays at its previous version.
            Err::<(), &'static str>("boom")
        });
        assert_eq!(outcome, Err("boom"));
        let tables: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='half_done'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tables, 0);
        let versions: i64 = connection
            .query_row(
                "SELECT COUNT(*) FROM schema_migrations WHERE version=99",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(versions, 0);
    }
}
