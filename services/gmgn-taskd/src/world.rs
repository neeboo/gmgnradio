//! World state authority: the single writer for world/object state.
//!
//! This module is the Rust side of the migration that moves the world state out
//! of the Swift-written `state.json` and into `gmgn-taskd`. After the migration
//! the rules are:
//!
//! * **One writer.** Only this module writes world state. `state.json` becomes a
//!   read-only pre-image (see `world_import`, which consumes it exactly once and
//!   records the fact in `world_imports`).
//! * **One truth per record.** A record is a row in `world_records`, keyed by
//!   `(worldID, domain, key)`, with its own monotonic `revision`, its own
//!   content `hash`, a `tombstone` flag and an `updated_by` writer identity —
//!   the record shape the cloud-sync design asks for.
//! * **Append-only facts.** Every accepted commit appends facts to
//!   `world_facts`, each with a global `seq`, a caller-supplied idempotency key
//!   (`id`), the subject record, the resulting revision and the producer. The
//!   per-object facts (`object.registered` / `object.placed` / `object.resized`
//!   / `object.enabledChanged` / `object.withdrawn` / `object.removed`) are
//!   **derived by diffing** the previous and next record, so the authority never
//!   re-implements Swift's layout rules: Swift still decides *what* the next
//!   document is, Rust decides *what is true*, *when it changed* and *who may
//!   write next*.
//! * **Optimistic concurrency, never silent overwrite.** A commit carries
//!   `expectedRevision`; a mismatch is rejected with `revision_conflict` and the
//!   caller must reconcile. A simulation revision regression inside the document
//!   is rejected with `subject_revision_regression`.
//! * **Idempotency.** `(worldID, requestID)` is recorded with the request's
//!   content hash: the same request replayed returns the recorded result and
//!   appends nothing; the same request id with different content is
//!   `request_id_conflict`.
//! * **Content-addressed blobs.** Large files (GLB, collision proxies) live in
//!   `world_blobs` keyed by sha256; records carry `blobRef`s, never bytes.
//!   A row in `world_blobs` is a *claim* about bytes, not the bytes: `blob_get`
//!   re-runs `stat` + the sha256 on every read and reports
//!   `localState: present|missing|corrupt|not_local`, appending a `blob.missing`
//!   / `blob.corrupt` fact when the claim no longer holds. "Row exists" must
//!   never read as "bytes exist" — the caller would otherwise only find out when
//!   the renderer fails.
//! * **Blob references are local-absolute, outbound-relative.** `local_path` is
//!   an absolute path on *this* machine (it stops being valid after a device or
//!   user-name change), so anything that leaves the machine — sync, MCP, another
//!   device — must carry the root-relative `localRef` that `blob_get` returns,
//!   never `localPath`. `world_blobs` deliberately carries **no refcount**: a
//!   blob is reachable only through the `blobRef`s actually present in
//!   `world_records`, so garbage collection has to be *derived* from those
//!   records (recorded refs win, orphans lose) and never from a second counter
//!   that can drift away from the truth.
//! * **Import is idempotent by content**, not only by request id: importing the
//!   same pre-image twice leaves one record set and one fact set.
//!
//! Everything runs on the single `taskd-storage` writer thread's connection (or
//! inside a transaction handed in by it); this module never opens a second
//! database.

use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

/// Domain of the world-level record (the state document minus `objectStates`).
pub const WORLD_DOMAIN: &str = "worlds";
/// Domain of one record per object.
pub const OBJECT_DOMAIN: &str = "objects";
/// Key of the single world-level record per world.
pub const WORLD_KEY: &str = "state";
/// Max serialized size of the world-level record value (JSON object).
pub const WORLD_RECORD_LIMIT: usize = 4 * 1024 * 1024;
/// Max serialized size of one object record value (JSON object).
pub const OBJECT_RECORD_LIMIT: usize = 256 * 1024;
/// Max serialized size of one fact payload.
pub const FACT_PAYLOAD_LIMIT: usize = 256 * 1024;
/// Max serialized size of one metadata string inside an object record.
pub const METADATA_LIMIT: usize = 64 * 1024;
/// Max ops in one commit.
pub const MAX_OPERATIONS: usize = 512;
/// Max facts appended by one commit (state fact + per-object facts).
pub const MAX_FACTS: usize = 1024;
pub const DEFAULT_READ_LIMIT: usize = 100;
pub const MAX_READ_LIMIT: usize = 500;
/// Length cap shared by world ids, keys, ids, request ids, kinds and consumers.
pub const TOKEN_LIMIT: usize = 200;
/// Max blob size accepted by `blob_put` (mirrors the daemon's 12 MiB frame budget).
pub const BLOB_LIMIT: u64 = 64 * 1024 * 1024;

pub const CONSUMERS: [&str; 5] = ["world", "ui", "agent", "cloud", "mcp"];

/// Metadata key holding the serialized generated-prop record.
pub const GENERATED_PROP_KEY: &str = "gmgn.generated-prop.v1";
/// Metadata key holding the support-surface id.
pub const SUPPORT_SURFACE_KEY: &str = "gmgn.support-surface.v1";

/// v4 schema: the world authority tables. Idempotent (`IF NOT EXISTS`) so it can
/// be re-run, and additive: it touches no existing table.
pub fn schema(connection: &Connection) -> Result<()> {
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS world_records (
                world_id TEXT NOT NULL,
                domain TEXT NOT NULL,
                key TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK (revision >= 1),
                updated_at_ms INTEGER NOT NULL,
                updated_by TEXT NOT NULL,
                tombstone INTEGER NOT NULL DEFAULT 0,
                hash TEXT NOT NULL,
                value TEXT NOT NULL,
                PRIMARY KEY (world_id, domain, key)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS world_requests (
                world_id TEXT NOT NULL,
                request_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                hash TEXT NOT NULL,
                seq INTEGER NOT NULL,
                result TEXT NOT NULL,
                committed_at_ms INTEGER NOT NULL,
                PRIMARY KEY (world_id, request_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS world_facts (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                world_id TEXT NOT NULL,
                id TEXT NOT NULL,
                kind TEXT NOT NULL,
                subject_domain TEXT NOT NULL,
                subject_key TEXT NOT NULL,
                revision INTEGER NOT NULL,
                payload TEXT NOT NULL,
                producer TEXT NOT NULL,
                at_ms INTEGER NOT NULL,
                UNIQUE (world_id, id)
            );
            CREATE INDEX IF NOT EXISTS world_facts_world_sequence
                ON world_facts(world_id, seq);
            CREATE INDEX IF NOT EXISTS world_facts_world_subject
                ON world_facts(world_id, subject_domain, subject_key, seq);
            CREATE TABLE IF NOT EXISTS world_cursors (
                world_id TEXT NOT NULL,
                consumer TEXT NOT NULL,
                seq INTEGER NOT NULL CHECK (seq >= 0),
                updated_at_ms INTEGER NOT NULL,
                PRIMARY KEY (world_id, consumer)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS world_blobs (
                sha256 TEXT PRIMARY KEY,
                bytes INTEGER NOT NULL CHECK (bytes >= 0),
                mime TEXT NOT NULL,
                local_path TEXT,
                remote_key TEXT,
                created_at_ms INTEGER NOT NULL
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS world_imports (
                world_id TEXT PRIMARY KEY,
                source_hash TEXT NOT NULL,
                package_id TEXT NOT NULL,
                package_version TEXT NOT NULL,
                request_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                seq INTEGER NOT NULL,
                imported_at_ms INTEGER NOT NULL
            ) WITHOUT ROWID;",
        )
        .map_err(|_| "storage_unavailable")?;
    Ok(())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn bounded(raw: &str, code: &'static str) -> Result<String> {
    if raw.is_empty()
        || raw.len() > TOKEN_LIMIT
        || raw.trim() != raw
        || raw.chars().any(char::is_control)
    {
        return Err(code);
    }
    Ok(raw.to_owned())
}

/// Canonical JSON text of a value (object keys sorted by `serde_json`'s
/// BTreeMap-backed map) — the one definition of a record's content.
fn canonical(value: &Value) -> Result<String> {
    serde_json::to_string(value).map_err(|_| "invalid_world_state")
}

fn digest_of(value: &Value) -> Result<String> {
    let mut hasher = Sha256::new();
    hasher.update(canonical(value)?.as_bytes());
    Ok(format!("{:x}", hasher.finalize()))
}


// ---------------------------------------------------------------------------
// wire shapes
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SnapshotRequest {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(default)]
    pub include_state: Option<bool>,
}

#[derive(Clone, Debug, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommitRequest {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub expected_revision: i64,
    #[serde(default)]
    pub producer: Option<String>,
    /// Optional human/agent-readable label of what this commit was for. It is
    /// recorded in the fact payload and never decides behaviour.
    #[serde(default)]
    pub intent: Option<Value>,
    pub ops: Vec<Op>,
}

#[derive(Clone, Debug, Default, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Op {
    pub op: String,
    #[serde(default)]
    pub state: Option<Value>,
    #[serde(default)]
    pub facts: Option<Value>,
    #[serde(default)]
    pub object: Option<Value>,
    #[serde(rename = "objectID", default)]
    pub object_id: Option<String>,
    #[serde(default)]
    pub expected_object_revision: Option<i64>,
    #[serde(default)]
    pub consumer: Option<String>,
    #[serde(default)]
    pub seq: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ImportRequest {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(default)]
    pub producer: Option<String>,
    #[serde(rename = "packageID")]
    pub package_id: String,
    pub package_version: String,
    /// sha256 of the raw pre-image bytes (`state.json` exactly as exported).
    pub state_sha256: String,
    /// The raw pre-image text. Rust verifies `sha256(stateJson) == stateSha256`
    /// before parsing, so the adopted bytes are provably the exported ones.
    pub state_json: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FactsRequest {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(default)]
    pub after: Option<i64>,
    #[serde(default)]
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecordsRequest {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(default)]
    pub domain: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CursorsRequest {
    #[serde(rename = "worldID")]
    pub world_id: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BlobPutRequest {
    pub sha256: String,
    pub mime: String,
    pub local_path: String,
    #[serde(default)]
    pub remote_key: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct BlobGetRequest {
    pub sha256: String,
}

// ---------------------------------------------------------------------------
// validation
// ---------------------------------------------------------------------------

fn validate_world_id(world_id: &str) -> Result<()> {
    bounded(world_id, "invalid_world_id")?;
    Ok(())
}

fn validate_consumer(consumer: &str) -> Result<String> {
    let consumer = bounded(consumer, "invalid_consumer")?;
    if CONSUMERS.contains(&consumer.as_str()) {
        Ok(consumer)
    } else {
        Err("invalid_consumer")
    }
}

fn finite_number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(number) => number.as_f64().filter(|n| n.is_finite()),
        _ => None,
    }
}

fn validate_vector(value: &Value, components: &[&str]) -> Result<()> {
    let object = value.as_object().ok_or("invalid_world_state")?;
    for component in components {
        let raw = object.get(*component).ok_or("invalid_world_state")?;
        if finite_number(raw).is_none() {
            return Err("invalid_world_state");
        }
    }
    Ok(())
}

fn validate_transform(value: &Value) -> Result<()> {
    let object = value.as_object().ok_or("invalid_world_state")?;
    validate_vector(
        object.get("position").ok_or("invalid_world_state")?,
        &["x", "y", "z"],
    )?;
    validate_vector(
        object.get("rotation").ok_or("invalid_world_state")?,
        &["x", "y", "z", "w"],
    )?;
    validate_vector(
        object.get("scale").ok_or("invalid_world_state")?,
        &["x", "y", "z"],
    )?;
    Ok(())
}

fn validate_metadata(value: &Value) -> Result<()> {
    let object = value.as_object().ok_or("invalid_world_state")?;
    for (key, item) in object {
        let text = item.as_str().ok_or("invalid_world_state")?;
        if key.is_empty() || key.len() > TOKEN_LIMIT || text.len() > METADATA_LIMIT {
            return Err("invalid_world_state");
        }
    }
    if let Some(blob) = object.get(GENERATED_PROP_KEY) {
        validate_generated_prop(blob.as_str().ok_or("invalid_world_state")?)?;
    }
    Ok(())
}

/// The generated-prop blob is a serialized JSON object. Validating it here is
/// what lets the authority *diff* two object records into typed facts
/// (`size` changed ⇒ `object.resized`) without re-implementing the size policy:
/// the blob is opaque except for the three keys the facts are named after.
fn validate_generated_prop(text: &str) -> Result<Value> {
    let parsed: Value = serde_json::from_str(text).map_err(|_| "invalid_generated_prop")?;
    let object = parsed.as_object().ok_or("invalid_generated_prop")?;
    match object.get("objectID").and_then(Value::as_str) {
        Some(id) if !id.is_empty() && id.len() <= TOKEN_LIMIT => {}
        _ => return Err("invalid_generated_prop"),
    }
    let size = object
        .get("size")
        .and_then(Value::as_object)
        .ok_or("invalid_generated_prop")?;
    for component in ["x", "y", "z"] {
        let value = finite_number(size.get(component).ok_or("invalid_generated_prop")?)
            .ok_or("invalid_generated_prop")?;
        if value <= 0.0 {
            return Err("invalid_generated_prop");
        }
    }
    Ok(parsed)
}

/// Validate one object entry and return its canonical stored form.
fn validate_object_entry(object_id: &str, value: &Value) -> Result<Value> {
    bounded(object_id, "invalid_object_id")?;
    let object = value.as_object().ok_or("invalid_world_state")?;
    for key in object.keys() {
        if !matches!(key.as_str(), "isEnabled" | "transform" | "metadata") {
            return Err("invalid_world_state");
        }
    }
    let is_enabled = object
        .get("isEnabled")
        .and_then(Value::as_bool)
        .ok_or("invalid_world_state")?;
    let transform = object.get("transform").ok_or("invalid_world_state")?;
    validate_transform(transform)?;
    let metadata = object.get("metadata").ok_or("invalid_world_state")?;
    validate_metadata(metadata)?;
    let entry = json!({
        "isEnabled": is_enabled,
        "transform": transform.clone(),
        "metadata": metadata.clone(),
    });
    if canonical(&entry)?.len() > OBJECT_RECORD_LIMIT {
        return Err("object_record_too_large");
    }
    Ok(entry)
}

/// Validate a whole `state.json` document and split it into the world-level
/// record value and the per-object entries.
fn validate_document(state: &Value) -> Result<(Value, Vec<(String, Value)>)> {
    let object = state.as_object().ok_or("invalid_world_state")?;
    if let Some(world_id) = object.get("worldID") {
        if world_id.as_str().is_none() {
            return Err("invalid_world_state");
        }
    }
    if let Some(revision) = object.get("revision") {
        if revision.as_u64().is_none() {
            return Err("invalid_world_state");
        }
    }
    let mut objects = Vec::new();
    if let Some(entries) = object.get("objectStates") {
        let entries = entries.as_object().ok_or("invalid_world_state")?;
        for (object_id, entry) in entries {
            objects.push((object_id.clone(), validate_object_entry(object_id, entry)?));
        }
    }
    let mut world = Map::new();
    for (key, value) in object {
        if key == "objectStates" {
            continue;
        }
        world.insert(key.clone(), value.clone());
    }
    Ok((Value::Object(world), objects))
}

// ---------------------------------------------------------------------------
// rows
// ---------------------------------------------------------------------------

struct RecordRow {
    revision: i64,
    value: Value,
    hash: String,
    tombstone: bool,
    updated_at_ms: i64,
}

fn world_row(connection: &Connection, world_id: &str) -> Result<Option<RecordRow>> {
    let row: Option<(i64, String, String, i64, i64)> = connection
        .query_row(
            "SELECT revision, value, hash, tombstone, updated_at_ms FROM world_records
             WHERE world_id=?1 AND domain=?2 AND key=?3",
            params![world_id, WORLD_DOMAIN, WORLD_KEY],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            },
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    row.map(|(revision, value, hash, tombstone, updated_at_ms)| {
        Ok(RecordRow {
            revision,
            value: serde_json::from_str(&value).map_err(|_| "world_record_unreadable")?,
            hash,
            tombstone: tombstone != 0,
            updated_at_ms,
        })
    })
    .transpose()
}

fn object_rows(connection: &Connection, world_id: &str) -> Result<Vec<(String, RecordRow)>> {
    let mut statement = connection
        .prepare(
            "SELECT key, revision, value, hash, tombstone, updated_at_ms FROM world_records
             WHERE world_id=?1 AND domain=?2 ORDER BY key",
        )
        .map_err(|_| "storage_unavailable")?;
    let rows = statement
        .query_map(params![world_id, OBJECT_DOMAIN], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
            ))
        })
        .map_err(|_| "storage_unavailable")?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| "storage_unavailable")?;
    rows.into_iter()
        .map(|(key, revision, value, hash, tombstone, updated_at_ms)| {
            Ok((
                key,
                RecordRow {
                    revision,
                    value: serde_json::from_str(&value).map_err(|_| "world_record_unreadable")?,
                    hash,
                    tombstone: tombstone != 0,
                    updated_at_ms,
                },
            ))
        })
        .collect()
}

fn world_revision(connection: &Connection, world_id: &str) -> Result<i64> {
    Ok(world_row(connection, world_id)?.map(|row| row.revision).unwrap_or(0))
}

/// The materialized `state.json` document: the world record value plus every
/// live object record. `None` when the world has no authority record yet.
pub fn materialize(connection: &Connection, world_id: &str) -> Result<Option<Value>> {
    let Some(world) = world_row(connection, world_id)? else {
        return Ok(None);
    };
    let mut document = world
        .value
        .as_object()
        .cloned()
        .ok_or("world_record_unreadable")?;
    let mut objects = Map::new();
    for (object_id, row) in object_rows(connection, world_id)? {
        if row.tombstone {
            continue;
        }
        objects.insert(object_id, row.value);
    }
    document.insert("objectStates".into(), Value::Object(objects));
    Ok(Some(Value::Object(document)))
}

// ---------------------------------------------------------------------------
// snapshot / reads
// ---------------------------------------------------------------------------

pub fn snapshot(connection: &Connection, request: &SnapshotRequest) -> Result<Value> {
    validate_world_id(&request.world_id)?;
    let world_id = &request.world_id;
    let Some(world) = world_row(connection, world_id)? else {
        return Ok(json!({ "record": Value::Null }));
    };
    let include_state = request.include_state.unwrap_or(true);
    let document = materialize(connection, world_id)?.ok_or("world_record_unreadable")?;
    let mut objects = Vec::new();
    for (object_id, row) in object_rows(connection, world_id)? {
        objects.push(json!({
            "objectID": object_id,
            "revision": row.revision,
            "isEnabled": row.value.get("isEnabled").and_then(Value::as_bool).unwrap_or(false),
            "tombstone": row.tombstone,
            "hash": row.hash,
            "updatedAtMs": row.updated_at_ms,
        }));
    }
    let boundary_seq: i64 = connection
        .query_row(
            "SELECT COALESCE(MAX(seq),0) FROM world_facts WHERE world_id=?1",
            params![world_id],
            |row| row.get(0),
        )
        .map_err(|_| "storage_unavailable")?;
    let mut record = json!({
        "recordRevision": world.revision,
        "boundarySeq": boundary_seq,
        "updatedAtMs": world.updated_at_ms,
        "stateSha256": digest_of(&document)?,
        "objects": objects,
    });
    if include_state {
        record["state"] = document;
    }
    Ok(json!({ "record": record }))
}

pub fn read_window(after: Option<i64>, limit: Option<usize>) -> Result<(i64, usize)> {
    let after = after.unwrap_or(0);
    if after < 0 {
        return Err("invalid_cursor");
    }
    let limit = limit.unwrap_or(DEFAULT_READ_LIMIT);
    if limit == 0 || limit > MAX_READ_LIMIT {
        return Err("invalid_limit");
    }
    Ok((after, limit))
}

pub fn read_facts(
    connection: &Connection,
    request: &FactsRequest,
) -> Result<(Vec<Value>, i64)> {
    validate_world_id(&request.world_id)?;
    let (after, limit) = read_window(request.after, request.limit)?;
    let mut statement = connection
        .prepare(
            "SELECT seq, id, kind, subject_domain, subject_key, revision, payload, producer, at_ms
             FROM world_facts WHERE world_id=?1 AND seq>?2 ORDER BY seq LIMIT ?3",
        )
        .map_err(|_| "storage_unavailable")?;
    let rows = statement
        .query_map(params![request.world_id, after, limit as i64], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, String>(7)?,
                row.get::<_, i64>(8)?,
            ))
        })
        .map_err(|_| "storage_unavailable")?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| "storage_unavailable")?;
    let mut facts = Vec::new();
    let mut next = after;
    for (seq, id, kind, domain, key, revision, payload, producer, at_ms) in rows {
        next = seq;
        facts.push(json!({
            "seq": seq,
            "id": id,
            "kind": kind,
            "subject": {"domain": domain, "key": key},
            "revision": revision,
            "payload": serde_json::from_str::<Value>(&payload)
                .map_err(|_| "world_fact_unreadable")?,
            "producer": producer,
            "atMs": at_ms,
        }));
    }
    Ok((facts, next))
}

/// The cloud-sync record shape (§7.1): `id / scope / domain / key / revision /
/// updatedAt / updatedBy / tombstone / hash / value`.
pub fn read_records(connection: &Connection, request: &RecordsRequest) -> Result<Vec<Value>> {
    validate_world_id(&request.world_id)?;
    let domain = match &request.domain {
        Some(domain) => Some(bounded(domain, "invalid_domain")?),
        None => None,
    };
    let mut statement = connection
        .prepare(
            "SELECT domain, key, revision, updated_at_ms, updated_by, tombstone, hash, value
             FROM world_records WHERE world_id=?1 AND (?2 IS NULL OR domain=?2)
             ORDER BY domain, key",
        )
        .map_err(|_| "storage_unavailable")?;
    let rows = statement
        .query_map(params![request.world_id, domain], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, String>(4)?,
                row.get::<_, i64>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, String>(7)?,
            ))
        })
        .map_err(|_| "storage_unavailable")?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| "storage_unavailable")?;
    let mut records = Vec::new();
    for (domain, key, revision, updated_at, updated_by, tombstone, hash, value) in rows {
        let id = if domain == WORLD_DOMAIN {
            format!("world:{}:{}", request.world_id, key)
        } else {
            format!("object:{}", key)
        };
        records.push(json!({
            "id": id,
            "scope": format!("world:{}", request.world_id),
            "domain": domain,
            "key": key,
            "revision": revision,
            "updatedAt": updated_at,
            "updatedBy": updated_by,
            "tombstone": tombstone != 0,
            "hash": hash,
            "value": serde_json::from_str::<Value>(&value)
                .map_err(|_| "world_record_unreadable")?,
        }));
    }
    Ok(records)
}

pub fn read_cursors(connection: &Connection, world_id: &str) -> Result<Vec<Value>> {
    validate_world_id(world_id)?;
    let mut statement = connection
        .prepare("SELECT consumer, seq, updated_at_ms FROM world_cursors WHERE world_id=?1 ORDER BY consumer")
        .map_err(|_| "storage_unavailable")?;
    let rows = statement
        .query_map(params![world_id], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
            ))
        })
        .map_err(|_| "storage_unavailable")?
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| "storage_unavailable")?;
    Ok(rows
        .into_iter()
        .map(|(consumer, seq, updated_at)| {
            json!({"consumer": consumer, "seq": seq, "updatedAtMs": updated_at})
        })
        .collect())
}

// ---------------------------------------------------------------------------
// blobs
// ---------------------------------------------------------------------------

pub fn blob_put(
    connection: &Connection,
    root: &Path,
    request: &BlobPutRequest,
) -> Result<Value> {
    let sha256 = request.sha256.trim().to_ascii_lowercase();
    if sha256.len() != 64 || !sha256.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("invalid_blob_hash");
    }
    let mime = bounded(&request.mime, "invalid_blob_mime")?;
    let path = std::fs::canonicalize(&request.local_path).map_err(|_| "invalid_blob_path")?;
    let root = std::fs::canonicalize(root).map_err(|_| "storage_unavailable")?;
    if !path.starts_with(&root) {
        // Content-addressed bytes stay inside the private root; a record may
        // reference them, it may not point at an arbitrary host path.
        return Err("blob_outside_private_root");
    }
    let metadata = std::fs::symlink_metadata(&path).map_err(|_| "invalid_blob_path")?;
    if !metadata.is_file() || metadata.len() > BLOB_LIMIT {
        return Err("invalid_blob");
    }
    let bytes = std::fs::read(&path).map_err(|_| "invalid_blob")?;
    let actual = digest_text_bytes(&bytes);
    if actual != sha256 {
        return Err("blob_hash_mismatch");
    }
    let size = bytes.len() as i64;
    connection
        .execute(
            "INSERT INTO world_blobs(sha256, bytes, mime, local_path, remote_key, created_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6)
             ON CONFLICT(sha256) DO UPDATE SET
                mime=excluded.mime,
                local_path=excluded.local_path,
                remote_key=COALESCE(excluded.remote_key, world_blobs.remote_key)",
            params![
                sha256,
                size,
                mime,
                path.to_string_lossy(),
                request.remote_key,
                now_ms()
            ],
        )
        .map_err(|_| "storage_unavailable")?;
    Ok(json!({"sha256": sha256, "bytes": size, "mime": mime}))
}

fn digest_text_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("{:x}", hasher.finalize())
}

/// 预像缺失/损坏时事实落在哪个作用域：blob 是内容寻址的、本身不属于任何世界。
/// 只要有记录引用它，事实就落在那条记录的世界下；一个引用都没有时落在这里，
/// 仍然能被 `world_facts_read {worldID: "_blobs"}` 读到。
pub const BLOB_SCOPE: &str = "_blobs";

/// 内容寻址字节在本机上的状态。**每次读都要重新判定**：行在 ≠ 字节在。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum BlobLocalState {
    /// 行在、文件在、大小与 sha256 都对得上。
    Present,
    /// 行在，文件不在（被删、被移走、路径失效）。
    Missing,
    /// 行在、文件在，但内容不是当初写进去的那份（被截断/被改写）。
    Corrupt,
    /// 本来就没有本机副本（例如只存在云端 `remote_key`）。
    NotLocal,
}

impl BlobLocalState {
    pub fn as_str(self) -> &'static str {
        match self {
            BlobLocalState::Present => "present",
            BlobLocalState::Missing => "missing",
            BlobLocalState::Corrupt => "corrupt",
            BlobLocalState::NotLocal => "not_local",
        }
    }
}

/// 读时校验：`stat` + 重算 sha256。写侧再严也挡不住"写完之后文件被删/被截断"。
fn inspect_blob(
    local: Option<&str>,
    expected_sha256: &str,
    expected_bytes: i64,
) -> (BlobLocalState, Option<i64>) {
    let Some(local) = local else {
        return (BlobLocalState::NotLocal, None);
    };
    let Ok(metadata) = std::fs::symlink_metadata(local) else {
        return (BlobLocalState::Missing, None);
    };
    if !metadata.is_file() {
        return (BlobLocalState::Missing, None);
    }
    let observed = metadata.len() as i64;
    if observed != expected_bytes {
        return (BlobLocalState::Corrupt, Some(observed));
    }
    match std::fs::read(local) {
        Ok(bytes) if digest_text_bytes(&bytes) == expected_sha256 => {
            (BlobLocalState::Present, Some(observed))
        }
        Ok(_) => (BlobLocalState::Corrupt, Some(observed)),
        Err(_) => (BlobLocalState::Missing, None),
    }
}

/// 外发引用必须是**相对私根**的路径：`local_path` 是本机绝对路径，换设备/换
/// 用户名就失效。本机继续用 `localPath`，任何离开本机的形状只带 `localRef`。
/// 词法剥离（不 `canonicalize`）：文件不在了也要能给出引用，那正是最需要它的时候。
pub fn outbound_ref(local_path: &str, root: &Path) -> Option<String> {
    let root = std::fs::canonicalize(root).ok()?;
    let relative = Path::new(local_path).strip_prefix(&root).ok()?;
    Some(relative.to_string_lossy().into_owned())
}

/// 把"字节不在了"变成一条**可见**事实，而不是让调用方以为成功。
///
/// 幂等键是 `(状态, sha256)`：同一状态重复读只留一行（`ON CONFLICT DO NOTHING`）；
/// `missing → 恢复 → missing` 的第二次不会再留一条，这是有意的取舍——事实回答
/// 的是"这份字节曾经被判为不可用"，不是一条读取审计日志。
fn record_blob_fault(
    connection: &Connection,
    sha256: &str,
    state: BlobLocalState,
    observed_bytes: Option<i64>,
) -> Result<()> {
    let kind = match state {
        BlobLocalState::Missing => "blob.missing",
        BlobLocalState::Corrupt => "blob.corrupt",
        BlobLocalState::Present | BlobLocalState::NotLocal => return Ok(()),
    };
    let payload = canonical(&json!({
        "sha256": sha256,
        "localState": state.as_str(),
        "observedBytes": observed_bytes,
    }))?;
    // 事实按引用它的记录归属到对应世界；一个都没引用时落在保留 scope。
    let mut scopes: Vec<String> = Vec::new();
    {
        let mut statement = connection
            .prepare("SELECT DISTINCT world_id FROM world_records WHERE value LIKE '%' || ?1 || '%'")
            .map_err(|_| "storage_unavailable")?;
        let rows = statement
            .query_map(params![sha256], |row| row.get::<_, String>(0))
            .map_err(|_| "storage_unavailable")?;
        for row in rows {
            scopes.push(row.map_err(|_| "storage_unavailable")?);
        }
    }
    if scopes.is_empty() {
        scopes.push(BLOB_SCOPE.to_owned());
    }
    scopes.sort();
    scopes.dedup();
    let id = format!("blob:{}:{}", state.as_str(), sha256);
    let at = now_ms();
    for world_id in scopes {
        connection
            .execute(
                "INSERT INTO world_facts(world_id, id, kind, subject_domain, subject_key, revision, payload, producer, at_ms)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
                 ON CONFLICT(world_id, id) DO NOTHING",
                params![world_id, id, kind, "blobs", sha256, 0i64, payload, "taskd", at],
            )
            .map_err(|_| "storage_unavailable")?;
    }
    Ok(())
}

pub fn blob_get(connection: &Connection, root: &Path, request: &BlobGetRequest) -> Result<Value> {
    let sha256 = request.sha256.trim().to_ascii_lowercase();
    let row: Option<(i64, String, Option<String>, Option<String>, i64)> = connection
        .query_row(
            "SELECT bytes, mime, local_path, remote_key, created_at_ms FROM world_blobs WHERE sha256=?1",
            params![sha256],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    match row {
        None => Ok(json!({"blob": Value::Null})),
        Some((bytes, mime, local, remote, created_at)) => {
            // 读时不设防的代价是"调用方看起来成功、渲染时才炸"，所以这里必须
            // 每次都验；判定失败要同时**返回状态**并**留下事实**。
            let (state, observed) = inspect_blob(local.as_deref(), &sha256, bytes);
            let local_ref = local.as_deref().and_then(|path| outbound_ref(path, root));
            if matches!(state, BlobLocalState::Missing | BlobLocalState::Corrupt) {
                record_blob_fault(connection, &sha256, state, observed)?;
            }
            Ok(json!({"blob": {
                "sha256": sha256,
                "bytes": bytes,
                "mime": mime,
                "localPath": local,
                "localRef": local_ref,
                "remoteKey": remote,
                "createdAtMs": created_at,
                "localState": state.as_str(),
                "observedBytes": observed,
            }}))
        }
    }
}

// ---------------------------------------------------------------------------
// commit
// ---------------------------------------------------------------------------

#[derive(Clone)]
struct Fact {
    id: String,
    kind: String,
    subject_domain: String,
    subject_key: String,
    revision: i64,
    payload: Value,
}

struct Applied {
    revision: i64,
    state_sha256: String,
    changed_objects: Vec<String>,
    changed_world_keys: Vec<String>,
    facts: Vec<Fact>,
}

fn request_hash(request: &CommitRequest) -> Result<String> {
    let value = serde_json::to_value(request).map_err(|_| "invalid_world_state")?;
    digest_of(&value)
}

fn recorded_request(
    connection: &Connection,
    world_id: &str,
    request_id: &str,
) -> Result<Option<(String, Value)>> {
    let row: Option<(String, String)> = connection
        .query_row(
            "SELECT hash, result FROM world_requests WHERE world_id=?1 AND request_id=?2",
            params![world_id, request_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    row.map(|(hash, result)| {
        Ok((
            hash,
            serde_json::from_str::<Value>(&result).map_err(|_| "world_request_unreadable")?,
        ))
    })
    .transpose()
}

/// Upsert one object record, deriving its revision and its typed fact by
/// diffing the stored value against the new one.
fn upsert_object(
    objects: &mut std::collections::BTreeMap<String, RecordRow>,
    object_id: &str,
    value: Value,
    expected_revision: Option<i64>,
    facts: &mut Vec<Fact>,
    changed_objects: &mut Vec<String>,
) -> Result<()> {
// Object upsert with diff-derived facts. `revision` is per object and counts
// successful mutations of that object; a tombstoned record keeps its
// revision so a re-registration continues the same identity.

let canonical_value = validate_object_entry(object_id, &value)?;
let hash = digest_of(&canonical_value)?;
let previous = objects.get(object_id);
if let Some(expected) = expected_revision {
    let current = previous.map(|row| row.revision).unwrap_or(0);
    if expected != current {
        return Err("object_revision_conflict");
    }
}
let (revision, tombstone) = match previous {
    Some(row) if row.hash == hash && !row.tombstone => (row.revision, false),
    Some(row) => (row.revision + 1, false),
    None => (1, false),
};
if previous.map(|row| row.hash.clone()) == Some(hash.clone())
    && previous.map(|row| row.tombstone) == Some(false)
{
    return Ok(());
}
let kind = match previous {
    None => "object.registered",
    Some(row) if row.tombstone => "object.registered",
    Some(row) => object_change_kind(&row.value, &canonical_value),
};
let payload = json!({
    "objectID": object_id,
    "revision": revision,
    "from": previous.map(|row| row.value.clone()),
    "to": canonical_value.clone(),
});
facts.push(Fact {
    id: format!("object:{}:{}:{}", kind, object_id, revision),
    kind: kind.into(),
    subject_domain: OBJECT_DOMAIN.into(),
    subject_key: object_id.into(),
    revision,
    payload,
});
objects.insert(
    object_id.to_owned(),
    RecordRow {
        revision,
        value: canonical_value,
        hash,
        tombstone,
        updated_at_ms: now_ms(),
    },
);
changed_objects.push(object_id.to_owned());
Ok(())
}

/// Apply the ops of one commit to the records, deriving facts and revisions.
fn apply(
    transaction: &Transaction<'_>,
    world_id: &str,
    producer: &str,
    ops: &[Op],
) -> Result<Applied> {
    let existing_world = world_row(transaction, world_id)?;
    let mut world_value = match &existing_world {
        Some(row) => row
            .value
            .as_object()
            .cloned()
            .ok_or("world_record_unreadable")?,
        None => Map::new(),
    };
    let mut objects: std::collections::BTreeMap<String, RecordRow> = object_rows(transaction, world_id)?
        .into_iter()
        .collect();
    let previous_state = {
        let mut document = world_value.clone();
        let mut live = Map::new();
        for (object_id, row) in &objects {
            if !row.tombstone {
                live.insert(object_id.clone(), row.value.clone());
            }
        }
        document.insert("objectStates".into(), Value::Object(live));
        Value::Object(document)
    };
    let previous_simulation_revision = previous_state
        .get("revision")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    // Tracked across ops: a commit with several `replaceState`/`setWorldFacts`
    // ops must stay monotonic against the value the previous op installed, not
    // only against the pre-commit document.
    let mut current_simulation_revision = previous_simulation_revision;

    let mut facts: Vec<Fact> = Vec::new();
    let mut changed_objects: Vec<String> = Vec::new();
    let mut changed_world_keys: Vec<String> = Vec::new();

    for op in ops {
        match op.op.as_str() {
            "replaceState" => {
                let state = op.state.as_ref().ok_or("invalid_op")?;
                let (next_world, next_objects) = validate_document(state)?;
                let next_revision = state.get("revision").and_then(Value::as_u64).unwrap_or(0);
                if next_revision < current_simulation_revision {
                    return Err("subject_revision_regression");
                }
                current_simulation_revision = next_revision;
                if let (Some(stored), Some(incoming)) = (
                    world_value.get("layoutRevision").and_then(Value::as_u64),
                    next_world.get("layoutRevision").and_then(Value::as_u64),
                ) {
                    if incoming < stored {
                        return Err("subject_revision_regression");
                    }
                }
                let next_world_object = next_world.as_object().ok_or("invalid_world_state")?;
                for key in next_world_object.keys() {
                    if world_value.get(key) != next_world_object.get(key) {
                        changed_world_keys.push(key.clone());
                    }
                }
                for key in world_value.keys() {
                    if !next_world_object.contains_key(key) {
                        changed_world_keys.push(key.clone());
                    }
                }
                world_value = next_world_object.clone();
                let live: std::collections::BTreeSet<String> = next_objects
                    .iter()
                    .map(|(object_id, _)| object_id.clone())
                    .collect();
                // Objects the new document no longer mentions are removed from
                // the world (tombstoned, never deleted: history stays).
                let removed: Vec<(String, RecordRow)> = objects
                    .iter()
                    .filter(|(object_id, row)| !row.tombstone && !live.contains(*object_id))
                    .map(|(object_id, row)| (object_id.clone(), clone_row(row)))
                    .collect();
                for (object_id, row) in removed {
                    let revision = row.revision + 1;
                    facts.push(Fact {
                        id: format!("object:object.removed:{}:{}", object_id, revision),
                        kind: "object.removed".into(),
                        subject_domain: OBJECT_DOMAIN.into(),
                        subject_key: object_id.clone(),
                        revision,
                        payload: json!({"objectID": object_id, "revision": revision, "from": row.value}),
                    });
                    objects.insert(
                        object_id.clone(),
                        RecordRow {
                            revision,
                            value: row.value,
                            hash: row.hash,
                            tombstone: true,
                            updated_at_ms: now_ms(),
                        },
                    );
                    changed_objects.push(object_id);
                }
                for (object_id, value) in next_objects {
                    upsert_object(&mut objects, &object_id, value, None, &mut facts, &mut changed_objects)?;
                }
            }
            "setWorldFacts" => {
                let facts_value = op.facts.as_ref().ok_or("invalid_op")?;
                let patch = facts_value.as_object().ok_or("invalid_world_facts")?;
                if patch.contains_key("objectStates") {
                    return Err("invalid_world_facts");
                }
                if let (Some(stored), Some(incoming)) = (
                    world_value.get("revision").and_then(Value::as_u64),
                    patch.get("revision").and_then(Value::as_u64),
                ) {
                    if incoming < stored {
                        return Err("subject_revision_regression");
                    }
                    current_simulation_revision = incoming;
                }
                if let (Some(stored), Some(incoming)) = (
                    world_value.get("layoutRevision").and_then(Value::as_u64),
                    patch.get("layoutRevision").and_then(Value::as_u64),
                ) {
                    if incoming < stored {
                        return Err("subject_revision_regression");
                    }
                }
                for (key, value) in patch {
                    if world_value.get(key) != Some(value) {
                        changed_world_keys.push(key.clone());
                    }
                    world_value.insert(key.clone(), value.clone());
                }
            }
            "upsertObject" => {
                let value = op.object.as_ref().ok_or("invalid_op")?;
                let object_id = op.object_id.clone().or_else(|| {
                    value.get("objectID").and_then(Value::as_str).map(str::to_owned)
                });
                let object_id = object_id.ok_or("invalid_object_id")?;
                upsert_object(
                    &mut objects,
                    &object_id,
                    value.clone(),
                    op.expected_object_revision,
                    &mut facts,
                    &mut changed_objects,
                )?;
            }
            "deleteObject" => {
                let object_id = op.object_id.clone().ok_or("invalid_object_id")?;
                let Some(row) = objects.get(&object_id) else {
                    return Err("object_not_found");
                };
                if row.tombstone {
                    continue;
                }
                let revision = row.revision + 1;
                let previous = row.value.clone();
                facts.push(Fact {
                    id: format!("object:object.removed:{}:{}", object_id, revision),
                    kind: "object.removed".into(),
                    subject_domain: OBJECT_DOMAIN.into(),
                    subject_key: object_id.clone(),
                    revision,
                    payload: json!({"objectID": object_id, "revision": revision, "from": previous.clone()}),
                });
                objects.insert(
                    object_id.clone(),
                    RecordRow {
                        revision,
                        value: previous,
                        hash: row.hash.clone(),
                        tombstone: true,
                        updated_at_ms: now_ms(),
                    },
                );
                changed_objects.push(object_id);
            }
            "advanceCursor" => {
                let consumer = validate_consumer(op.consumer.as_deref().ok_or("invalid_consumer")?)?;
                let seq = op.seq.ok_or("invalid_cursor")?;
                if seq < 0 {
                    return Err("invalid_cursor");
                }
                transaction
                    .execute(
                        "INSERT INTO world_cursors(world_id, consumer, seq, updated_at_ms)
                         VALUES(?1,?2,?3,?4)
                         ON CONFLICT(world_id, consumer) DO UPDATE SET
                            seq=MAX(world_cursors.seq, excluded.seq),
                            updated_at_ms=excluded.updated_at_ms",
                        params![world_id, consumer, seq, now_ms()],
                    )
                    .map_err(|_| "storage_unavailable")?;
            }
            _ => return Err("invalid_op"),
        }
    }

    // Persist the world-level record.
    let revision = existing_world
        .as_ref()
        .map(|row| row.revision)
        .unwrap_or(0)
        + 1;
    let world_value = Value::Object(world_value);
    let world_hash = digest_of(&world_value)?;
    // A world record must carry its own identity: it is the foreign key every
    // object record hangs off. An op that would leave the record without (or
    // with a different) worldID is rejected rather than stored half-formed.
    match world_value.get("worldID").and_then(Value::as_str) {
        Some(value) if value == world_id => {}
        _ => return Err("world_id_mismatch"),
    }
    let serialized = canonical(&world_value)?;
    if serialized.len() > WORLD_RECORD_LIMIT {
        return Err("world_record_too_large");
    }
    let at = now_ms();
    transaction
        .execute(
            "INSERT INTO world_records(world_id, domain, key, revision, updated_at_ms, updated_by, tombstone, hash, value)
             VALUES(?1,?2,?3,?4,?5,?6,0,?7,?8)
             ON CONFLICT(world_id, domain, key) DO UPDATE SET
                revision=excluded.revision,
                updated_at_ms=excluded.updated_at_ms,
                updated_by=excluded.updated_by,
                tombstone=0,
                hash=excluded.hash,
                value=excluded.value",
            params![world_id, WORLD_DOMAIN, WORLD_KEY, revision, at, producer, world_hash, serialized],
        )
        .map_err(|_| "storage_unavailable")?;

    // Persist every object row touched above (all rows are already in `objects`).
    for (object_id, row) in &objects {
        transaction
            .execute(
                "INSERT INTO world_records(world_id, domain, key, revision, updated_at_ms, updated_by, tombstone, hash, value)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
                 ON CONFLICT(world_id, domain, key) DO UPDATE SET
                    revision=excluded.revision,
                    updated_at_ms=excluded.updated_at_ms,
                    updated_by=excluded.updated_by,
                    tombstone=excluded.tombstone,
                    hash=excluded.hash,
                    value=excluded.value",
                params![
                    world_id,
                    OBJECT_DOMAIN,
                    object_id,
                    row.revision,
                    row.updated_at_ms,
                    producer,
                    if row.tombstone { 1 } else { 0 },
                    row.hash,
                    canonical(&row.value)?
                ],
            )
            .map_err(|_| "storage_unavailable")?;
    }

    changed_objects.sort();
    changed_objects.dedup();
    changed_world_keys.sort();
    changed_world_keys.dedup();

    let document = materialize(transaction, world_id)?.ok_or("world_record_unreadable")?;
    let state_sha256 = digest_of(&document)?;
    Ok(Applied {
        revision,
        state_sha256,
        changed_objects,
        changed_world_keys,
        facts,
    })
}

fn clone_row(row: &RecordRow) -> RecordRow {
    RecordRow {
        revision: row.revision,
        value: row.value.clone(),
        hash: row.hash.clone(),
        tombstone: row.tombstone,
        updated_at_ms: row.updated_at_ms,
    }
}

/// Name the typed fact for a changed object record. Size comes from the
/// generated-prop blob; placement from the transform/support surface; enabled
/// from the flag. Several aspects can change at once ⇒ several facts.
fn object_change_kind(previous: &Value, next: &Value) -> &'static str {
    let previous_size = prop_size(previous);
    let next_size = prop_size(next);
    if previous_size != next_size && next_size.is_some() {
        return "object.resized";
    }
    let previous_transform = previous.get("transform");
    let next_transform = next.get("transform");
    let previous_surface = previous
        .get("metadata")
        .and_then(|metadata| metadata.get(SUPPORT_SURFACE_KEY));
    let next_surface = next
        .get("metadata")
        .and_then(|metadata| metadata.get(SUPPORT_SURFACE_KEY));
    if previous_transform != next_transform || previous_surface != next_surface {
        return "object.placed";
    }
    let previous_enabled = previous.get("isEnabled").and_then(Value::as_bool);
    let next_enabled = next.get("isEnabled").and_then(Value::as_bool);
    if previous_enabled != next_enabled {
        return match next_enabled {
            Some(true) => "object.enabledChanged",
            _ => "object.withdrawn",
        };
    }
    "object.updated"
}

fn prop_size(value: &Value) -> Option<Value> {
    let blob = value
        .get("metadata")?
        .get(GENERATED_PROP_KEY)?
        .as_str()?;
    let parsed: Value = serde_json::from_str(blob).ok()?;
    parsed.get("size").cloned()
}

/// One commit: idempotency, CAS, ops, facts, all in the caller's transaction.
pub fn commit(transaction: &Transaction<'_>, request: &CommitRequest) -> Result<Value> {
    validate_world_id(&request.world_id)?;
    let request_id = bounded(&request.request_id, "invalid_request_id")?;
    if request.expected_revision < 0 {
        return Err("invalid_revision");
    }
    if request.ops.is_empty() || request.ops.len() > MAX_OPERATIONS {
        return Err("invalid_op_count");
    }
    let producer = match &request.producer {
        Some(producer) => bounded(producer, "invalid_producer")?,
        None => "taskd".to_owned(),
    };
    // Serialize the request before any mutation: the recorded hash must describe
    // exactly what was accepted, and a replay with different content must fail
    // loudly rather than being treated as a retry.
    let hash = request_hash(request)?;

    if let Some((recorded_hash, result)) =
        recorded_request(transaction, &request.world_id, &request_id)?
    {
        if recorded_hash != hash {
            return Err("request_id_conflict");
        }
        let mut result = result;
        result["replayed"] = json!(true);
        return Ok(result);
    }

    let current = world_revision(transaction, &request.world_id)?;
    if request.expected_revision != current {
        return Err("revision_conflict");
    }

    let applied = apply(transaction, &request.world_id, &producer, &request.ops)?;
    let at = now_ms();

    // The commit fact is inserted first so the commit's own `seq` is the first
    // fact's seq; it is keyed by the request id, so exactly one exists per
    // accepted commit and a replay appends nothing.
    let commit_fact = Fact {
        id: format!("commit:{}", request_id),
        kind: "world.stateCommitted".into(),
        subject_domain: WORLD_DOMAIN.into(),
        subject_key: WORLD_KEY.into(),
        revision: applied.revision,
        payload: json!({
            "requestID": request_id,
            "intent": request.intent,
            "revision": applied.revision,
            "stateSha256": applied.state_sha256,
            "changedObjects": applied.changed_objects,
            "changedWorldKeys": applied.changed_world_keys,
            "objectFactCount": applied.facts.len(),
        }),
    };
    let mut all_facts = vec![commit_fact];
    all_facts.extend(applied.facts.clone());
    if all_facts.len() > MAX_FACTS {
        return Err("too_many_facts");
    }
    let mut fact_ids = Vec::new();
    let mut first_seq = 0i64;
    for (index, fact) in all_facts.iter().enumerate() {
        let payload = canonical(&fact.payload)?;
        if payload.len() > FACT_PAYLOAD_LIMIT {
            return Err("fact_payload_too_large");
        }
        transaction
            .execute(
                "INSERT INTO world_facts(world_id, id, kind, subject_domain, subject_key, revision, payload, producer, at_ms)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
                 ON CONFLICT(world_id, id) DO NOTHING",
                params![
                    request.world_id,
                    fact.id,
                    fact.kind,
                    fact.subject_domain,
                    fact.subject_key,
                    fact.revision,
                    payload,
                    producer,
                    at
                ],
            )
            .map_err(|_| "storage_unavailable")?;
        let seq: i64 = transaction
            .query_row(
                "SELECT seq FROM world_facts WHERE world_id=?1 AND id=?2",
                params![request.world_id, fact.id],
                |row| row.get(0),
            )
            .map_err(|_| "storage_unavailable")?;
        if index == 0 {
            first_seq = seq;
        }
        fact_ids.push(json!({"id": fact.id, "kind": fact.kind, "seq": seq}));
    }

    let result = json!({
        "revision": applied.revision,
        "seq": first_seq,
        "replayed": false,
        "stateSha256": applied.state_sha256,
        "changedObjects": applied.changed_objects,
        "changedWorldKeys": applied.changed_world_keys,
        "facts": fact_ids,
    });
    transaction
        .execute(
            "INSERT INTO world_requests(world_id, request_id, revision, hash, seq, result, committed_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![
                request.world_id,
                request_id,
                applied.revision,
                hash,
                first_seq,
                canonical(&result)?,
                at
            ],
        )
        .map_err(|_| "storage_unavailable")?;
    Ok(result)
}

// ---------------------------------------------------------------------------
// import
// ---------------------------------------------------------------------------

/// One-time import of a legacy `state.json`. Idempotent **by content**: the same
/// pre-image imported again (even with a different request id) replays the
/// recorded result and writes nothing.
pub fn import(transaction: &Transaction<'_>, request: &ImportRequest) -> Result<Value> {
    validate_world_id(&request.world_id)?;
    let request_id = bounded(&request.request_id, "invalid_request_id")?;
    let package_id = bounded(&request.package_id, "invalid_package_id")?;
    let package_version = bounded(&request.package_version, "invalid_package_version")?;
    let producer = match &request.producer {
        Some(producer) => bounded(producer, "invalid_producer")?,
        None => "import".to_owned(),
    };
    // Verify the pre-image bytes before parsing them: the declared hash is over
    // the raw text, so a tampered or partially copied bundle cannot be adopted.
    let declared = request.state_sha256.trim().to_ascii_lowercase();
    if declared.len() != 64 || !declared.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err("invalid_import_hash");
    }
    if digest_text_bytes(request.state_json.as_bytes()) != declared {
        return Err("import_hash_mismatch");
    }
    let state: Value =
        serde_json::from_str(&request.state_json).map_err(|_| "invalid_world_state")?;
    let (_, objects) = validate_document(&state)?;
    if state.get("worldID").and_then(Value::as_str) != Some(request.world_id.as_str()) {
        return Err("world_id_mismatch");
    }
    let source_hash = digest_of(&state)?;

    // Already imported this content ⇒ replay, whatever the request id is.
    let marker: Option<(String, i64, i64)> = transaction
        .query_row(
            "SELECT source_hash, revision, seq FROM world_imports WHERE world_id=?1",
            params![request.world_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((recorded_hash, revision, seq)) = marker {
        if recorded_hash == source_hash {
            return Ok(json!({
                "revision": revision,
                "seq": seq,
                "replayed": true,
                "imported": false,
                "stateSha256": source_hash,
                "objectCount": objects.len(),
            }));
        }
        return Err("import_conflict");
    }
    // A world that already has authority records but no import marker was
    // written by the authority itself; importing over it needs a decision, not
    // a silent overwrite.
    let current = world_revision(transaction, &request.world_id)?;
    if current > 0 {
        return Err("import_conflict");
    }

    let op = Op {
        op: "replaceState".into(),
        state: Some(state),
        ..Op::default()
    };
    let applied = apply(transaction, &request.world_id, &producer, &[op])?;
    let at = now_ms();
    let commit_fact = Fact {
        id: format!("import:{}", request_id),
        kind: "world.imported".into(),
        subject_domain: WORLD_DOMAIN.into(),
        subject_key: WORLD_KEY.into(),
        revision: applied.revision,
        payload: json!({
            "requestID": request_id,
            "packageID": package_id,
            "packageVersion": package_version,
            "preImageSha256": declared,
            "sourceSha256": source_hash,
            "objectCount": objects.len(),
            "stateSha256": applied.state_sha256,
        }),
    };
    let mut all_facts = vec![commit_fact];
    all_facts.extend(applied.facts.clone());
    if all_facts.len() > MAX_FACTS {
        return Err("too_many_facts");
    }
    let mut fact_ids = Vec::new();
    let mut first_seq = 0i64;
    for (index, fact) in all_facts.iter().enumerate() {
        let payload = canonical(&fact.payload)?;
        transaction
            .execute(
                "INSERT INTO world_facts(world_id, id, kind, subject_domain, subject_key, revision, payload, producer, at_ms)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9)
                 ON CONFLICT(world_id, id) DO NOTHING",
                params![
                    request.world_id,
                    fact.id,
                    fact.kind,
                    fact.subject_domain,
                    fact.subject_key,
                    fact.revision,
                    payload,
                    producer,
                    at
                ],
            )
            .map_err(|_| "storage_unavailable")?;
        let seq: i64 = transaction
            .query_row(
                "SELECT seq FROM world_facts WHERE world_id=?1 AND id=?2",
                params![request.world_id, fact.id],
                |row| row.get(0),
            )
            .map_err(|_| "storage_unavailable")?;
        if index == 0 {
            first_seq = seq;
        }
        fact_ids.push(json!({"id": fact.id, "kind": fact.kind, "seq": seq}));
    }
    transaction
        .execute(
            "INSERT INTO world_imports(world_id, source_hash, package_id, package_version, request_id, revision, seq, imported_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
            params![
                request.world_id,
                source_hash,
                package_id,
                package_version,
                request_id,
                applied.revision,
                first_seq,
                at
            ],
        )
        .map_err(|_| "storage_unavailable")?;
    transaction
        .execute(
            "INSERT INTO world_requests(world_id, request_id, revision, hash, seq, result, committed_at_ms)
             VALUES(?1,?2,?3,?4,?5,?6,?7)",
            params![
                request.world_id,
                request_id,
                applied.revision,
                source_hash,
                first_seq,
                canonical(&json!({
                    "revision": applied.revision,
                    "seq": first_seq,
                    "replayed": false,
                    "imported": true,
                    "stateSha256": applied.state_sha256,
                }))?,
                at
            ],
        )
        .map_err(|_| "storage_unavailable")?;
    Ok(json!({
        "revision": applied.revision,
        "seq": first_seq,
        "replayed": false,
        "imported": true,
        "stateSha256": applied.state_sha256,
        "objectCount": objects.len(),
        "facts": fact_ids,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::collections::BTreeMap;

    const WORLD: &str = "84503420-3010-4944-8fde-2f383cd08ebe";

    fn setup() -> Connection {
        let connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        connection
    }

    fn prop_blob(object_id: &str, size: (f64, f64, f64)) -> String {
        json!({
            "objectID": object_id,
            "sourceWishID": "EBFC07BE-6AF3-4E25-AF6C-9E795C6E28C6",
            "assetID": "sha256:d656c46b21ee0c6601f754d44643285538c7d7ed32271c9095eadb875cc689f8",
            "displayName": "E2E-0907 咖啡机",
            "sourceHeight": 0.7465656,
            "size": {"x": size.0, "y": size.1, "z": size.2},
        })
        .to_string()
    }

    fn object_entry(object_id: &str, enabled: bool, x: f64, size: (f64, f64, f64)) -> Value {
        json!({
            "isEnabled": enabled,
            "transform": {
                "position": {"x": x, "y": 0.52, "z": -4.875},
                "rotation": {"w": 1.0, "x": 0.0, "y": 0.0, "z": 0.0},
                "scale": {"x": 0.4688, "y": 0.4688, "z": 0.4688},
            },
            "metadata": {
                GENERATED_PROP_KEY: prop_blob(object_id, size),
                SUPPORT_SURFACE_KEY: "grid.layerPropSupportLayer(layer: 1, supportHeight: 0.52, center: WorldRuntime.WorldVector3(x: -2.75, y: 0.52, z: -5.0))",
            },
        })
    }

    fn document(revision: u64, layout_revision: u64, objects: Vec<(&str, Value)>) -> Value {
        let mut object_states = Map::new();
        for (object_id, entry) in objects {
            object_states.insert(object_id.to_owned(), entry);
        }
        json!({
            "agentTransform": {
                "position": {"x": 0.8, "y": -0.037016094, "z": -3.55},
                "rotation": {"w": 0.97821593, "x": 0.0, "y": -0.20758995, "z": 0.0},
                "scale": {"x": 1.0, "y": 1.0, "z": 1.0},
            },
            "completedGoals": {},
            "lastObservedWallTime": 1788594244345.278,
            "layoutReceipts": {
                "placement.7f29c6b9": {"place": {"objectID": "wish-prop-ebfc07be",
                    "placement": {"position": {"x": -2.7, "y": 0.52, "z": -5.0},
                                  "surfaceID": "resident.display_table", "yaw": 0.0}}}
            },
            "layoutRevision": layout_revision,
            "revision": revision,
            "weather": "clear",
            "worldID": WORLD,
            "worldTime": 1788821988294.7507,
            "objectStates": Value::Object(object_states),
        })
    }

    fn fixture() -> Value {
        document(
            6965564,
            16,
            vec![
                ("wish-prop-ebfc07be", object_entry("wish-prop-ebfc07be", true, -2.625, (0.29, 0.35, 0.47))),
                ("wish-prop-02bfee6e", object_entry("wish-prop-02bfee6e", true, -2.625, (0.88, 0.7, 0.086))),
            ],
        )
    }

    fn import(connection: &mut Connection, request_id: &str, state: Value) -> Result<Value> {
        let transaction = connection.transaction().unwrap();
        let state_json = canonical(&state)?;
        let state_sha256 = digest_text_bytes(state_json.as_bytes());
        let result = super::import(&transaction, &ImportRequest {
            world_id: WORLD.into(),
            request_id: request_id.into(),
            producer: None,
            package_id: "marble-living-cabin".into(),
            package_version: "1.2.0".into(),
            state_sha256,
            state_json,
        });
        match result {
            Ok(value) => {
                transaction.commit().unwrap();
                Ok(value)
            }
            Err(code) => Err(code),
        }
    }

    fn import_err(connection: &mut Connection, request_id: &str, state: Value) -> &'static str {
        let transaction = connection.transaction().unwrap();
        let state_json = canonical(&state).unwrap();
        let state_sha256 = digest_text_bytes(state_json.as_bytes());
        let code = super::import(&transaction, &ImportRequest {
            world_id: WORLD.into(),
            request_id: request_id.into(),
            producer: None,
            package_id: "marble-living-cabin".into(),
            package_version: "1.2.0".into(),
            state_sha256,
            state_json,
        })
        .unwrap_err();
        drop(transaction);
        code
    }

    fn commit(
        connection: &mut Connection,
        request_id: &str,
        expected_revision: i64,
        ops: Vec<Op>,
    ) -> Result<Value> {
        let transaction = connection.transaction().unwrap();
        let result = super::commit(&transaction, &CommitRequest {
            world_id: WORLD.into(),
            request_id: request_id.into(),
            expected_revision,
            producer: Some("test".into()),
            intent: None,
            ops,
        });
        match result {
            Ok(value) => {
                transaction.commit().unwrap();
                Ok(value)
            }
            Err(code) => Err(code),
        }
    }

    fn commit_err(
        connection: &mut Connection,
        request_id: &str,
        expected_revision: i64,
        ops: Vec<Op>,
    ) -> &'static str {
        let transaction = connection.transaction().unwrap();
        let code = super::commit(&transaction, &CommitRequest {
            world_id: WORLD.into(),
            request_id: request_id.into(),
            expected_revision,
            producer: None,
            intent: None,
            ops,
        })
        .unwrap_err();
        drop(transaction);
        code
    }

    fn snapshot_state(connection: &Connection) -> Value {
        snapshot(connection, &SnapshotRequest {
            world_id: WORLD.into(),
            include_state: Some(true),
        })
        .unwrap()["record"]["state"]
            .clone()
    }

    fn reload() -> Op {
        Op { op: "replaceState".into(), state: None, ..Op::default() }
    }

    fn fact_kinds(connection: &Connection) -> Vec<String> {
        let mut statement = connection
            .prepare("SELECT kind FROM world_facts ORDER BY seq")
            .unwrap();
        statement
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap()
    }

    /// Every wire shape is camelCase with `ID` suffixes spelled out. A typo here
    /// is a contract break that the daemon would report as `invalid_*` at
    /// runtime, so it is asserted at compile/test time instead.
    #[test]
    fn wire_shapes_accept_the_camel_case_contract() {
        let commit: CommitRequest = serde_json::from_value(json!({
            "worldID": WORLD,
            "requestID": "request-1",
            "expectedRevision": 3,
            "producer": "swift",
            "intent": {"kind": "layout.place", "objectID": "wish-prop-1"},
            "ops": [
                {"op": "replaceState", "state": {"worldID": WORLD}},
                {"op": "upsertObject", "objectID": "wish-prop-1",
                 "object": {"isEnabled": true,
                            "transform": {"position": {"x": 0, "y": 0, "z": 0},
                                          "rotation": {"x": 0, "y": 0, "z": 0, "w": 1},
                                          "scale": {"x": 1, "y": 1, "z": 1}},
                            "metadata": {}},
                 "expectedObjectRevision": 1},
                {"op": "deleteObject", "objectID": "wish-prop-1"},
                {"op": "setWorldFacts", "facts": {"weather": "clear"}},
                {"op": "advanceCursor", "consumer": "ui", "seq": 4},
            ],
        }))
        .unwrap();
        assert_eq!(commit.expected_revision, 3);
        assert_eq!(commit.ops.len(), 5);
        assert_eq!(commit.ops[1].expected_object_revision, Some(1));
        assert_eq!(commit.ops[4].consumer.as_deref(), Some("ui"));
        let import: ImportRequest = serde_json::from_value(json!({
            "worldID": WORLD,
            "requestID": "import-1",
            "packageID": "marble-living-cabin",
            "packageVersion": "1.2.0",
            "stateSha256": "abc",
            "stateJson": "{\"worldID\":\"x\"}",
        }))
        .unwrap();
        assert_eq!(import.package_id, "marble-living-cabin");
        assert_eq!(import.package_version, "1.2.0");
        assert_eq!(import.state_sha256, "abc");
        assert_eq!(import.state_json, "{\"worldID\":\"x\"}");
        let blob: BlobPutRequest = serde_json::from_value(json!({
            "sha256": "aa", "mime": "model/gltf-binary", "localPath": "/tmp/x.glb",
            "remoteKey": "cloud/x.glb",
        }))
        .unwrap();
        assert_eq!(blob.local_path, "/tmp/x.glb");
        assert_eq!(blob.remote_key.as_deref(), Some("cloud/x.glb"));
        let cursors: CursorsRequest =
            serde_json::from_value(json!({"worldID": WORLD})).unwrap();
        assert_eq!(cursors.world_id, WORLD);
        let records: RecordsRequest =
            serde_json::from_value(json!({"worldID": WORLD, "domain": "objects"})).unwrap();
        assert_eq!(records.domain.as_deref(), Some("objects"));
        // strictness: an unknown key is rejected, not dropped
        assert!(serde_json::from_value::<CursorsRequest>(json!({"worldID": WORLD, "extra": 1})).is_err());
    }

    #[test]
    fn schema_is_idempotent() {
        let connection = setup();
        schema(&connection).unwrap();
        let names: Vec<String> = connection
            .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'world\\_%' ESCAPE '\\' ORDER BY name")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<std::result::Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(names, vec!["world_blobs", "world_cursors", "world_facts", "world_imports", "world_records", "world_requests"]);
    }

    #[test]
    fn import_then_snapshot_round_trips_the_document_field_by_field() {
        let mut connection = setup();
        let state = fixture();
        import(&mut connection, "import-1", state.clone()).unwrap();
        let materialized = snapshot_state(&connection);
        assert_eq!(canonical(&materialized).unwrap(), canonical(&state).unwrap());
        // and the equivalence witness agrees on both documents
        assert_eq!(digest_of(&materialized).unwrap(), digest_of(&state).unwrap());
    }

    #[test]
    fn import_is_idempotent_by_content() {
        let mut connection = setup();
        let state = fixture();
        let first = import(&mut connection, "import-1", state.clone()).unwrap();
        let records_after_first: i64 = connection
            .query_row("SELECT COUNT(*) FROM world_records", [], |row| row.get(0))
            .unwrap();
        let facts_after_first = fact_kinds(&connection).len();
        // same bytes, different request id: a replay, not a second copy
        let second = import(&mut connection, "import-2", state.clone()).unwrap();
        assert_eq!(first["revision"], second["revision"]);
        assert_eq!(first["seq"], second["seq"]);
        assert_eq!(second["replayed"], true);
        assert_eq!(second["imported"], false);
        let records_after_second: i64 = connection
            .query_row("SELECT COUNT(*) FROM world_records", [], |row| row.get(0))
            .unwrap();
        assert_eq!(records_after_first, records_after_second);
        assert_eq!(facts_after_first, fact_kinds(&connection).len());
    }

    #[test]
    fn import_rejects_a_different_pre_image_for_the_same_world() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let other = document(1, 1, vec![]);
        assert_eq!(import_err(&mut connection, "import-2", other), "import_conflict");
    }

    #[test]
    fn import_verifies_the_pre_image_bytes_before_adopting_them() {
        let mut connection = setup();
        let transaction = connection.transaction().unwrap();
        let state_json = canonical(&fixture()).unwrap();
        // a hash that does not describe the bytes is refused
        let code = super::import(&transaction, &ImportRequest {
            world_id: WORLD.into(),
            request_id: "import-1".into(),
            producer: None,
            package_id: "marble-living-cabin".into(),
            package_version: "1.2.0".into(),
            state_sha256: "0".repeat(64),
            state_json: state_json.clone(),
        })
        .unwrap_err();
        assert_eq!(code, "import_hash_mismatch");
        // tampered text under an otherwise valid hash is refused too
        let mut tampered = fixture();
        tampered["weather"] = json!("rain");
        let code = super::import(&transaction, &ImportRequest {
            world_id: WORLD.into(),
            request_id: "import-2".into(),
            producer: None,
            package_id: "marble-living-cabin".into(),
            package_version: "1.2.0".into(),
            state_sha256: digest_text_bytes(state_json.as_bytes()),
            state_json: canonical(&tampered).unwrap(),
        })
        .unwrap_err();
        assert_eq!(code, "import_hash_mismatch");
        // a short/illegal declared hash is its own code, not a silent accept
        let code = super::import(&transaction, &ImportRequest {
            world_id: WORLD.into(),
            request_id: "import-3".into(),
            producer: None,
            package_id: "marble-living-cabin".into(),
            package_version: "1.2.0".into(),
            state_sha256: "nope".into(),
            state_json,
        })
        .unwrap_err();
        assert_eq!(code, "invalid_import_hash");
    }

    #[test]
    fn commit_requires_the_exact_expected_revision() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let state = fixture();
        let op = Op { state: Some(state.clone()), ..reload() };
        // stale
        assert_eq!(commit_err(&mut connection, "commit-stale", 0, vec![op.clone()]), "revision_conflict");
        // future
        assert_eq!(commit_err(&mut connection, "commit-future", 7, vec![op.clone()]), "revision_conflict");
        // exact
        let ok = commit(&mut connection, "commit-1", 1, vec![op]).unwrap();
        assert_eq!(ok["revision"], 2);
        assert_eq!(ok["replayed"], false);
    }

    #[test]
    fn commit_rejects_a_stale_projection_pushing_an_older_simulation_revision() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let stale = document(6965000, 16, vec![]);
        let op = Op { state: Some(stale), ..reload() };
        assert_eq!(
            commit_err(&mut connection, "commit-old", 1, vec![op]),
            "subject_revision_regression"
        );
        // nothing was written by the rejected commit
        assert_eq!(world_revision(&connection, WORLD).unwrap(), 1);
        assert_eq!(fact_kinds(&connection).len(), 3); // import fact + 2 registrations
    }

    #[test]
    fn commit_replays_the_same_request_id_and_conflicts_on_different_content() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let moved = document(6965565, 16, vec![
            ("wish-prop-ebfc07be", object_entry("wish-prop-ebfc07be", true, -2.0, (0.29, 0.35, 0.47))),
            ("wish-prop-02bfee6e", object_entry("wish-prop-02bfee6e", true, -2.625, (0.88, 0.7, 0.086))),
        ]);
        let op = Op { state: Some(moved.clone()), ..reload() };
        let first = commit(&mut connection, "request-1", 1, vec![op.clone()]).unwrap();
        let replay = commit(&mut connection, "request-1", 1, vec![op]).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["revision"], first["revision"]);
        assert_eq!(replay["seq"], first["seq"]);
        // same id, different content: a contract violation, not a retry
        let other = document(6965566, 16, vec![
            ("wish-prop-ebfc07be", object_entry("wish-prop-ebfc07be", true, -3.5, (0.29, 0.35, 0.47))),
            ("wish-prop-02bfee6e", object_entry("wish-prop-02bfee6e", true, -2.625, (0.88, 0.7, 0.086))),
        ]);
        let op = Op { state: Some(other), ..reload() };
        assert_eq!(commit_err(&mut connection, "request-1", 1, vec![op]), "request_id_conflict");
    }

    #[test]
    fn every_commit_appends_exactly_one_state_fact_and_typed_object_facts() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let before = fact_kinds(&connection);
        assert_eq!(before, vec!["world.imported", "object.registered", "object.registered"]);
        // move one object, resize the other
        let next = document(6965565, 17, vec![
            ("wish-prop-ebfc07be", object_entry("wish-prop-ebfc07be", false, -2.625, (0.29, 0.35, 0.47))),
            ("wish-prop-02bfee6e", object_entry("wish-prop-02bfee6e", true, -2.625, (0.95, 0.755, 0.093))),
        ]);
        let op = Op { state: Some(next), ..reload() };
        let result = commit(&mut connection, "request-1", 1, vec![op]).unwrap();
        assert_eq!(result["facts"].as_array().unwrap().len(), 3);
        let after = fact_kinds(&connection);
        // object id order is the deterministic order of the stored document
        assert_eq!(&after[3..], &["world.stateCommitted", "object.resized", "object.withdrawn"]);
        // the committed document is the one the caller sent
        assert_eq!(canonical(&snapshot_state(&connection)).unwrap(),
                   canonical(&document(6965565, 17, vec![
                       ("wish-prop-ebfc07be", object_entry("wish-prop-ebfc07be", false, -2.625, (0.29, 0.35, 0.47))),
                       ("wish-prop-02bfee6e", object_entry("wish-prop-02bfee6e", true, -2.625, (0.95, 0.755, 0.093))),
                   ])).unwrap());
    }

    #[test]
    fn object_revisions_advance_only_for_the_object_that_changed() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let record = snapshot(&connection, &SnapshotRequest {
            world_id: WORLD.into(),
            include_state: Some(false),
        })
        .unwrap();
        let revisions: BTreeMap<String, i64> = record["record"]["objects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| (entry["objectID"].as_str().unwrap().to_owned(), entry["revision"].as_i64().unwrap()))
            .collect();
        assert_eq!(revisions["wish-prop-ebfc07be"], 1);
        assert_eq!(revisions["wish-prop-02bfee6e"], 1);

        let next = document(6965565, 17, vec![
            ("wish-prop-ebfc07be", object_entry("wish-prop-ebfc07be", true, -2.0, (0.29, 0.35, 0.47))),
            ("wish-prop-02bfee6e", object_entry("wish-prop-02bfee6e", true, -2.625, (0.88, 0.7, 0.086))),
        ]);
        let op = Op { state: Some(next), ..reload() };
        commit(&mut connection, "request-1", 1, vec![op]).unwrap();
        let record = snapshot(&connection, &SnapshotRequest {
            world_id: WORLD.into(),
            include_state: Some(false),
        })
        .unwrap();
        let revisions: BTreeMap<String, i64> = record["record"]["objects"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| (entry["objectID"].as_str().unwrap().to_owned(), entry["revision"].as_i64().unwrap()))
            .collect();
        assert_eq!(revisions["wish-prop-ebfc07be"], 2, "moved object keeps its own revision");
        assert_eq!(revisions["wish-prop-02bfee6e"], 1, "untouched object must not advance");
    }

    #[test]
    fn removed_object_is_tombstoned_and_omitted_from_the_document() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let next = document(6965565, 17, vec![
            ("wish-prop-ebfc07be", object_entry("wish-prop-ebfc07be", true, -2.625, (0.29, 0.35, 0.47))),
        ]);
        let op = Op { state: Some(next), ..reload() };
        let result = commit(&mut connection, "request-1", 1, vec![op]).unwrap();
        assert_eq!(result["changedObjects"], json!(["wish-prop-02bfee6e"]));
        let materialized = snapshot_state(&connection);
        assert!(materialized["objectStates"].get("wish-prop-02bfee6e").is_none());
        let tombstone: i64 = connection
            .query_row(
                "SELECT tombstone FROM world_records WHERE world_id=?1 AND domain=?2 AND key=?3",
                params![WORLD, OBJECT_DOMAIN, "wish-prop-02bfee6e"],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(tombstone, 1, "removal is a tombstone, never a deleted row");
        assert!(fact_kinds(&connection).contains(&"object.removed".to_string()));
    }

    #[test]
    fn upsert_object_conflicts_on_a_stale_object_revision() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let op = Op {
            op: "upsertObject".into(),
            object: Some(object_entry("wish-prop-ebfc07be", true, -2.0, (0.29, 0.35, 0.47))),
            object_id: Some("wish-prop-ebfc07be".into()),
            expected_object_revision: Some(5),
            ..Op::default()
        };
        assert_eq!(commit_err(&mut connection, "request-1", 1, vec![op]), "object_revision_conflict");
        let op = Op {
            op: "upsertObject".into(),
            object: Some(object_entry("wish-prop-ebfc07be", true, -2.0, (0.29, 0.35, 0.47))),
            object_id: Some("wish-prop-ebfc07be".into()),
            expected_object_revision: Some(1),
            ..Op::default()
        };
        let result = commit(&mut connection, "request-2", 1, vec![op]).unwrap();
        assert_eq!(result["changedObjects"], json!(["wish-prop-ebfc07be"]));
    }

    #[test]
    fn facts_read_window_returns_a_monotonic_next_cursor() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let (facts, next) = read_facts(&connection, &FactsRequest {
            world_id: WORLD.into(),
            after: Some(0),
            limit: Some(2),
        })
        .unwrap();
        assert_eq!(facts.len(), 2);
        assert_eq!(next, facts[1]["seq"].as_i64().unwrap());
        let (rest, next2) = read_facts(&connection, &FactsRequest {
            world_id: WORLD.into(),
            after: Some(next),
            limit: Some(100),
        })
        .unwrap();
        assert_eq!(rest.len(), 1);
        assert_eq!(next2, rest[0]["seq"].as_i64().unwrap());
        assert!(next2 > next);
        // a re-read of the same window is stable
        let (again, next3) = read_facts(&connection, &FactsRequest {
            world_id: WORLD.into(),
            after: Some(0),
            limit: Some(2),
        })
        .unwrap();
        assert_eq!(again, facts);
        assert_eq!(next3, next);
    }

    #[test]
    fn cursor_advance_is_monotonic() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let op = |seq: i64| Op {
            op: "advanceCursor".into(),
            consumer: Some("ui".into()),
            seq: Some(seq),
            ..Op::default()
        };
        commit(&mut connection, "cursor-1", 1, vec![op(3)]).unwrap();
        commit(&mut connection, "cursor-2", 2, vec![op(1)]).unwrap();
        let cursors = read_cursors(&connection, WORLD).unwrap();
        assert_eq!(cursors[0]["consumer"], "ui");
        assert_eq!(cursors[0]["seq"], 3, "a cursor never moves backwards");
    }

    #[test]
    fn records_expose_the_cloud_sync_shape() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let records = read_records(&connection, &RecordsRequest {
            world_id: WORLD.into(),
            domain: None,
        })
        .unwrap();
        assert_eq!(records.len(), 3); // 1 world + 2 objects
        for record in &records {
            for key in ["id", "scope", "domain", "key", "revision", "updatedAt", "updatedBy", "tombstone", "hash", "value"] {
                assert!(record.get(key).is_some(), "missing {key} in {record}");
            }
            assert_eq!(record["scope"], format!("world:{}", WORLD));
            assert_eq!(record["updatedBy"], "import");
            assert_eq!(record["revision"], 1);
            assert_eq!(record["tombstone"], false);
            assert_eq!(record["hash"].as_str().unwrap().len(), 64);
        }
        let objects = read_records(&connection, &RecordsRequest {
            world_id: WORLD.into(),
            domain: Some(OBJECT_DOMAIN.into()),
        })
        .unwrap();
        assert_eq!(objects.len(), 2);
        assert!(objects[0]["id"].as_str().unwrap().starts_with("object:"));
    }

    #[test]
    fn blob_put_is_content_addressed_and_verifies_the_hash() {
        let connection = setup();
        let root = std::env::temp_dir().join(format!("gmgn-world-blob-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let bytes = b"glTF\x02\x00\x00\x00 fake model bytes";
        let path = root.join("model.glb");
        std::fs::write(&path, bytes).unwrap();
        let sha256 = digest_text_bytes(bytes);
        let stored = blob_put(&connection, &root, &BlobPutRequest {
            sha256: sha256.clone(),
            mime: "model/gltf-binary".into(),
            local_path: path.to_string_lossy().into_owned(),
            remote_key: None,
        })
        .unwrap();
        assert_eq!(stored["sha256"], sha256);
        assert_eq!(stored["bytes"], bytes.len() as i64);
        // idempotent by content: a second put is a no-op, not a second row
        blob_put(&connection, &root, &BlobPutRequest {
            sha256: sha256.clone(),
            mime: "model/gltf-binary".into(),
            local_path: path.to_string_lossy().into_owned(),
            remote_key: Some("cloud/model.glb".into()),
        })
        .unwrap();
        let count: i64 = connection
            .query_row("SELECT COUNT(*) FROM world_blobs", [], |row| row.get(0))
            .unwrap();
        assert_eq!(count, 1);
        let fetched = blob_get(&connection, &root, &BlobGetRequest { sha256: sha256.clone() }).unwrap();
        assert_eq!(fetched["blob"]["remoteKey"], "cloud/model.glb");
        // 本机绝对路径是本机细节；外发必须用相对私根的 localRef。
        assert_eq!(fetched["blob"]["localState"], "present");
        assert_eq!(fetched["blob"]["localRef"], "model.glb");
        // a declared hash that does not match the bytes is refused
        let code = blob_put(&connection, &root, &BlobPutRequest {
            sha256: "1".repeat(64),
            mime: "model/gltf-binary".into(),
            local_path: path.to_string_lossy().into_owned(),
            remote_key: None,
        })
        .unwrap_err();
        assert_eq!(code, "blob_hash_mismatch");
        // and bytes outside the private root are refused by path, not by hash
        let outside = std::env::temp_dir().join(format!("gmgn-outside-{}", uuid::Uuid::new_v4()));
        std::fs::write(&outside, bytes).unwrap();
        let code = blob_put(&connection, &root, &BlobPutRequest {
            sha256: digest_text_bytes(bytes),
            mime: "model/gltf-binary".into(),
            local_path: outside.to_string_lossy().into_owned(),
            remote_key: None,
        })
        .unwrap_err();
        assert_eq!(code, "blob_outside_private_root");
        std::fs::remove_dir_all(&root).ok();
        std::fs::remove_file(&outside).ok();
    }

    #[test]
    fn blob_get_reports_a_missing_local_file_and_appends_a_visible_fact() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        let root = std::env::temp_dir().join(format!("gmgn-world-blob-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let bytes = b"glTF\x02\x00\x00\x00 fake model bytes";
        let path = root.join("model.glb");
        std::fs::write(&path, bytes).unwrap();
        let sha256 = digest_text_bytes(bytes);
        blob_put(
            &connection,
            &root,
            &BlobPutRequest {
                sha256: sha256.clone(),
                mime: "model/gltf-binary".into(),
                local_path: path.to_string_lossy().into_owned(),
                remote_key: None,
            },
        )
        .unwrap();
        // 让一条物件记录真的**引用**这份字节（记录只带 blobRef，不带字节）。
        let mut referencing = object_entry("wish-prop-blobref", true, -2.625, (0.29, 0.35, 0.47));
        referencing["metadata"]["blobRef"] = json!(sha256);
        let op = Op {
            op: "upsertObject".into(),
            object: Some(referencing),
            object_id: Some("wish-prop-blobref".into()),
            ..Op::default()
        };
        commit(&mut connection, "blob-ref", 1, vec![op]).unwrap();
        // 写侧校验通过 ≠ 字节还在：把文件删掉，读侧必须**可见地**失败。
        std::fs::remove_file(&path).unwrap();
        let fetched = blob_get(&connection, &root, &BlobGetRequest { sha256: sha256.clone() }).unwrap();
        assert_eq!(fetched["blob"]["localState"], "missing");
        assert!(fetched["blob"]["observedBytes"].is_null());
        // 文件不在了也必须给得出**相对**引用：那正是最需要它的时候。
        assert_eq!(fetched["blob"]["localRef"], "model.glb");
        // 本机绝对路径是本机细节（`blob_put` 存的是规范化后的路径，含符号链接
        // 解析结果），所以只断言它确实是绝对路径 + 文件名；**外发只认 localRef**。
        let stored_path = fetched["blob"]["localPath"].as_str().unwrap();
        assert!(stored_path.starts_with('/') && stored_path.ends_with("model.glb"));
        // 引用它的世界下必须留下一条可读事实，而不是静默返回一条行。
        let (facts, _) = read_facts(
            &connection,
            &FactsRequest {
                world_id: WORLD.into(),
                after: Some(0),
                limit: Some(MAX_READ_LIMIT),
            },
        )
        .unwrap();
        let missing: Vec<&Value> = facts.iter().filter(|fact| fact["kind"] == "blob.missing").collect();
        assert_eq!(missing.len(), 1);
        assert_eq!(missing[0]["subject"]["domain"], "blobs");
        assert_eq!(missing[0]["subject"]["key"], sha256);
        // 幂等：再读一次不留第二条同样的事实。
        blob_get(&connection, &root, &BlobGetRequest { sha256: sha256.clone() }).unwrap();
        let (facts, _) = read_facts(
            &connection,
            &FactsRequest {
                world_id: WORLD.into(),
                after: Some(0),
                limit: Some(MAX_READ_LIMIT),
            },
        )
        .unwrap();
        assert_eq!(facts.iter().filter(|fact| fact["kind"] == "blob.missing").count(), 1);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn blob_get_reports_a_truncated_local_file_as_corrupt() {
        let connection = setup();
        let root = std::env::temp_dir().join(format!("gmgn-world-blob-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let bytes = b"glTF\x02\x00\x00\x00 fake model bytes";
        let path = root.join("model.glb");
        std::fs::write(&path, bytes).unwrap();
        let sha256 = digest_text_bytes(bytes);
        blob_put(
            &connection,
            &root,
            &BlobPutRequest {
                sha256: sha256.clone(),
                mime: "model/gltf-binary".into(),
                local_path: path.to_string_lossy().into_owned(),
                remote_key: None,
            },
        )
        .unwrap();
        // 截断：大小先对不上，直接判 corrupt（不会拿半个模型去渲染）。
        std::fs::write(&path, &bytes[..8]).unwrap();
        let fetched = blob_get(&connection, &root, &BlobGetRequest { sha256: sha256.clone() }).unwrap();
        assert_eq!(fetched["blob"]["localState"], "corrupt");
        assert_eq!(fetched["blob"]["observedBytes"], 8);
        // 等长改写也必须被抓到：这时只能靠重算 sha256。
        std::fs::write(&path, b"glTF\x02\x00\x00\x00 FAKE model bytes").unwrap();
        let fetched = blob_get(&connection, &root, &BlobGetRequest { sha256: sha256.clone() }).unwrap();
        assert_eq!(fetched["blob"]["localState"], "corrupt");
        assert_eq!(fetched["blob"]["observedBytes"], bytes.len() as i64);
        // 一个引用都没有的 blob 落到保留 scope，但事实依然可读。
        let (facts, _) = read_facts(
            &connection,
            &FactsRequest {
                world_id: BLOB_SCOPE.into(),
                after: Some(0),
                limit: Some(MAX_READ_LIMIT),
            },
        )
        .unwrap();
        assert_eq!(facts.iter().filter(|fact| fact["kind"] == "blob.corrupt").count(), 1);
        std::fs::remove_dir_all(&root).ok();
    }

    #[test]
    fn malformed_records_are_rejected_by_name() {
        let mut connection = setup();
        import(&mut connection, "import-1", fixture()).unwrap();
        // worldID that does not match the request
        let mut mismatched = fixture();
        mismatched["worldID"] = json!("some-other-world");
        let op = Op { state: Some(mismatched), ..reload() };
        assert_eq!(commit_err(&mut connection, "bad-1", 1, vec![op]), "world_id_mismatch");
        // an object whose generated-prop blob is not decodable
        let mut broken = fixture();
        broken["objectStates"]["wish-prop-ebfc07be"]["metadata"][GENERATED_PROP_KEY] = json!("{not json");
        let op = Op { state: Some(broken), ..reload() };
        assert_eq!(commit_err(&mut connection, "bad-2", 1, vec![op]), "invalid_generated_prop");
        // a document whose object entry carries an unknown field
        let mut unknown = fixture();
        unknown["objectStates"]["wish-prop-ebfc07be"]["colour"] = json!("red");
        let op = Op { state: Some(unknown), ..reload() };
        assert_eq!(commit_err(&mut connection, "bad-3", 1, vec![op]), "invalid_world_state");
        // setWorldFacts may not smuggle object state past the object records
        let op = Op {
            op: "setWorldFacts".into(),
            facts: Some(json!({"objectStates": {}})),
            ..Op::default()
        };
        assert_eq!(commit_err(&mut connection, "bad-4", 1, vec![op]), "invalid_world_facts");
        // an unknown op name is refused rather than ignored
        let op = Op { op: "teleport".into(), ..Op::default() };
        assert_eq!(commit_err(&mut connection, "bad-5", 1, vec![op]), "invalid_op");
    }

    #[test]
    fn snapshot_of_an_unknown_world_is_null_not_an_empty_world() {
        let connection = setup();
        let record = snapshot(&connection, &SnapshotRequest {
            world_id: "nobody".into(),
            include_state: Some(true),
        })
        .unwrap();
        assert_eq!(record["record"], Value::Null);
    }
}
