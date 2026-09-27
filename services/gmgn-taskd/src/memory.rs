//! VoiceMem selective Rust port: scoped durable memory snapshots + retrieval.
//!
//! This module adds a third persistent layer beside the job store and the
//! resident state/event/message store, all inside the one `tasks.sqlite3` and
//! the one `taskd-storage` writer thread (no second database, no second
//! writer). The wire contract is frozen in
//! `docs/plans/2026-09-08-voicemem-rust-contract.md` (additive IPC,
//! `memory_configure/status/read/query/turn/pending/compact`); nothing here
//! changes the existing `configure/snapshot/submit/cancel/retry/...` or the
//! resident contracts.
//!
//! Data model (frozen):
//! - Long-term memory is one versioned snapshot per `(worldID, residentScope)`
//!   with two sections: atomic long-term `facts`/preferences and grounded
//!   `notes` (relationship/experience). Snapshot text and its derived vectors
//!   are replaced atomically in one transaction, generation-matched
//!   (`vectorGeneration`); old-generation vectors never survive a commit.
//! - Conversation raw text exists only as volatile in-process pending turns
//!   keyed by scope (VoiceMem `SessionBuffer` commit-after-durability): turns
//!   stay pending until a `memory_compact` commits durably, then pending turns
//!   with `watermark <= processedWatermark` are cleared. A crash loses the
//!   volatile pending text; committed snapshots and watermark counters
//!   survive.
//! - Semantic compaction and embedding always go through explicitly configured
//!   providers (real HTTP calls). Missing configuration is an explicit
//!   unavailable status/error; this code never substitutes lexical hashing,
//!   concatenation or truncation for semantic vectors or compaction.
//!
//! Storage layout (schema v3 `memory-storage-v1`, additive):
//! - `memory_snapshots`: one row per scope with scalar snapshot fields +
//!   serialized sections.
//! - `memory_requests`: per-scope requestID idempotency (revision, generation,
//!   processed watermark, digest of the request content).
//! - `memory_vec_rows`: rowid->entry map for each scope's sqlite-vec
//!   partition; a row only ever exists for the current generation.
//! - per-scope `memory_vec_<sha256>` vec0 partitions (`float32[dims]`,
//!   `distance_metric=cosine`, table name derived from the scope) created on
//!   first commit, holding only the current generation's vectors, so a KNN
//!   query is structurally "filter by scope before top-k" (never a global
//!   top-k with a late scope filter).
//!
//! sqlite-vec is statically linked (pinned `=0.1.9`, MIT/Apache-2.0) and
//! registered process-wide through `sqlite3_auto_extension` before any
//! connection is opened. Provenance notes for the VoiceMem semantics (Apache
//! 2.0, reference commit a450911fc8cbb44c46d810aace2f3288bad287e4) and the
//! sqlite-vec notice live in this module's docs and in
//! `services/gmgn-taskd/VoiceMem-NOTICE.md`.

use crate::memory_orchestrator::{
    self as orchestration, Outcome as OrchOutcome, Policy as OrchPolicy, Registry as OrchRegistry,
};
use crate::resident::Scope;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::RwLock as AsyncRwLock;

pub type Result<T> = std::result::Result<T, &'static str>;

fn fail<T>(code: &'static str) -> Result<T> {
    Err(code)
}

/// Frozen constants (contract §1). Character limits are measured in Unicode
/// scalar values (`chars().count()`), byte limits in UTF-8 bytes.
pub const PENDING_TURNS_LIMIT: usize = 200;
pub const TURN_TEXT_LIMIT: usize = 2000;
pub const QUERY_TEXT_LIMIT: usize = 500;
pub const TOP_K_MAX: usize = 20;
pub const FACTS_LIMIT: usize = 200;
pub const NOTES_LIMIT: usize = 80;
pub const ENTRY_TEXT_LIMIT: usize = 400;
pub const OBSERVED_AT_LIMIT: usize = 32;
pub const GROUNDING_LIMIT: usize = 200;
pub const EMBEDDING_DIM_LIMIT: usize = 8192;
pub const SNAPSHOT_LIMIT: usize = 1024 * 1024;

pub const SCHEMA_VERSION: i64 = 1;

// Orchestration-plan constants (2026-09-08-voicemem-rust-orchestration.md).
pub const RECALL_FACT_LIMIT_DEFAULT: usize = 6;
pub const RECALL_FACT_LIMIT_MAX: usize = 12;
pub const RECALL_NOTE_LIMIT_DEFAULT: usize = 4;
pub const RECALL_NOTE_LIMIT_MAX: usize = 8;
/// Bounded fused recall context, in Unicode characters.
pub const RECALL_CONTEXT_LIMIT: usize = 8000;
/// Volatile per-scope (scope, requestID) receipt bound (ingest idempotency).
pub const INGEST_RECEIPTS_LIMIT: usize = 200;
/// Volatile per-scope delivered-pair bound (extraction feedback context).
pub const INGEST_PAIRS_LIMIT: usize = 200;
/// Bounded pending-turn restore inside a fresh-session recall context.
pub const FRESH_RESTORE_TURNS: usize = 6;
/// Marker phrase every notes section of a fused context must carry.
pub const NOTES_TONE_MARKER: &str =
    "本段仅为语气与相处风格参考；禁止照读，禁止据此认定人格。";

/// Provider wire contract used by the daemon's own client (documented in the
/// module docs and README; the frozen CC-facing IPC only configures providers,
/// it never sees these paths). Both endpoints are the standard
/// OpenAI-compatible shapes so any OpenAI-compatible service implements them:
/// semantic compaction goes through `POST {endpoint}/v1/chat/completions`
/// (configured model + a system `COMPACTION_RULES` prompt + the previous
/// snapshot/turns/limits JSON as the user content; the assistant `content` is
/// parsed as the frozen envelope JSON) and embedding goes through
/// `POST {endpoint}/v1/embeddings` (`input` array; response `data[index]`
/// entries carry `embedding` + `model`, validated for count/index/model/
/// dimensions/finite/nonzero).
pub const COMPACTION_PATH: &str = "/v1/chat/completions";
pub const EMBEDDING_PATH: &str = "/v1/embeddings";
/// Response body caps for the two provider calls (streamed, checked while
/// reading). Compaction output is bounded by the section/entry limits;
/// embeddings carry up to (200 facts + 80 notes) dense vectors.
pub const COMPACTION_RESPONSE_LIMIT: usize = 4 * 1024 * 1024;
pub const EMBEDDING_RESPONSE_LIMIT: usize = 64 * 1024 * 1024;

/// Semantic rules sent as the chat-completions system prompt for every real
/// compaction (contract §4.1). Deterministic, model-agnostic instructions that
/// pin the sections split, the anti-hallucination rules and the frozen output
/// envelope; the daemon still validates the returned envelope on its own and
/// never relies on the model to self-police shape or caps.
pub const COMPACTION_RULES: &str = "\
You consolidate a resident conversation transcript into a durable memory snapshot.
Output exactly one JSON object, and nothing else, matching this frozen shape:
{\"facts\":[{\"category\":\"fact|preference\",\"text\":\"...\",\"observedAt\":\"YYYY-MM-DD\",\"grounding\":\"turn:<watermark>\"}],\"notes\":[{\"category\":\"relationship|experience\",\"text\":\"...\",\"observedAt\":\"YYYY-MM-DD\",\"grounding\":\"turn:<watermark>\"}],\"removed\":[\"<previous snapshot entry id>\"]}
Rules:
1. \"facts\" holds only stable long-term facts and preferences about the resident or world. One-off requests, immediate answers, present commands or transactional help are NOT memories; do not record them.
2. \"notes\" holds only grounded relationship/experience/communication observations for tone and topic guidance. Every note requires a grounding reference to the observed utterance (\"turn:<watermark>\").
3. A single transient mood, feeling or one occurrence must never be promoted into a stable personality trait or preference.
4. Preserve concrete dates, names and numbers exactly as spoken; do not generalize or round them.
5. Notes are internal guidance only and must never be quoted or read back to the user.
6. Corrections and deletions are expressed explicitly: keep prior long-term entries unless correcting or deleting; list each removed previous entry id under \"removed\" (ids that existed in the previous snapshot only) and emit corrected or replacement entries in the new sections.
7. Observe the entry text / observedAt / grounding length limits given in the data; never invent content that is not supported by the transcript or the previous snapshot.
Return the JSON object as plain text; do not wrap it in prose or markdown fences.";

/// Per-connection cancellation that reaches into an in-flight memory_compact
/// (contract §2.4: a client disconnect invalidates an uncommitted compaction).
/// The flag is checked before the commit barrier and again inside the commit
/// closure on the storage thread, so a compaction whose provider call already
/// returned cannot land after the client disconnected.
#[derive(Clone, Default)]
pub struct Cancellation {
    inner: Arc<AtomicBool>,
}

impl Cancellation {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.inner.store(true, Ordering::Release);
    }
    pub fn canceled(&self) -> bool {
        self.inner.load(Ordering::Acquire)
    }
}

/// Registered once per process before any SQLite connection is opened. The
/// sqlite-vec crate statically links `sqlite-vec.c` (SQLITE_CORE) and exposes
/// `sqlite3_vec_init`; SQLite deduplicates identical auto-extension function
/// pointers, so repeated calls are harmless no-ops.
pub fn register_vec() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| unsafe {
        let entry: unsafe extern "C" fn(
            *mut rusqlite::ffi::sqlite3,
            *mut *mut std::os::raw::c_char,
            *const rusqlite::ffi::sqlite3_api_routines,
        ) -> std::os::raw::c_int = std::mem::transmute(sqlite_vec::sqlite3_vec_init as *const ());
        let rc = rusqlite::ffi::sqlite3_auto_extension(Some(entry));
        debug_assert_eq!(rc, 0);
    });
}

// ---------------------------------------------------------------------------
// Data model
// ---------------------------------------------------------------------------

/// A volatile pending turn (contract §2.3). Raw conversation text lives only
/// here, in process memory, keyed by scope; it is never persisted.
#[derive(Clone, Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VolatileTurn {
    #[serde(rename = "turnID")]
    pub turn_id: String,
    pub watermark: i64,
    pub role: String,
    pub text: String,
    pub interrupted: bool,
}

/// One snapshot entry (contract §2.1). `grounding` is optional for facts and
/// required for notes (daemon-enforced at compaction validation).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub category: String,
    pub text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub observed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub grounding: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Sections {
    pub facts: Vec<Entry>,
    pub notes: Vec<Entry>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct EmbeddingRef {
    pub model: String,
    pub dimensions: usize,
}

/// A stored snapshot row as kept in `memory_snapshots` (scalars + sections;
/// the full §2.1 JSON is assembled on read).
#[derive(Clone, Debug, PartialEq)]
pub struct StoredRow {
    pub revision: i64,
    pub vector_generation: i64,
    pub processed_watermark: i64,
    pub next_watermark: i64,
    pub embedding: EmbeddingRef,
    pub sections: Sections,
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

pub fn scope_valid(world_id: &str, resident_scope: &str) -> bool {
    [world_id, resident_scope]
        .iter()
        .all(|v| !v.is_empty() && v.len() <= 200 && v.trim() == *v && !v.chars().any(char::is_control))
}

/// Canonicalize a UUID-shaped identifier to lowercase hyphenated form (retries
/// and replay match regardless of client casing).
pub fn identity(raw: &str) -> Result<String> {
    uuid::Uuid::parse_str(raw)
        .map(|u| u.hyphenated().to_string())
        .map_err(|_| "invalid_id")
}

/// Content digest of one `memory_ingest` delivery, for volatile
/// (scope, requestID) idempotency (in-memory only; never persisted).
fn ingest_digest(user_text: &str, agent_reply: &str, source: &str, observed_at: &Option<String>) -> String {
    let mut hasher = Sha256::new();
    hasher.update(user_text.as_bytes());
    hasher.update(b"\0");
    hasher.update(agent_reply.as_bytes());
    hasher.update(b"\0");
    hasher.update(source.as_bytes());
    match observed_at {
        None => hasher.update(b"\0"),
        Some(observed_at) => {
            hasher.update(b"\0");
            hasher.update(observed_at.as_bytes());
        }
    }
    format!("{:x}", hasher.finalize())
}

fn trim_no_control(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() || trimmed.chars().any(char::is_control) {
        return None;
    }
    Some(trimmed.to_owned())
}

fn bounded_chars(raw: &str, limit: usize) -> bool {
    raw.chars().count() <= limit
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

// ---------------------------------------------------------------------------
// Schema (v3, additive)
// ---------------------------------------------------------------------------

/// v3 schema: memory snapshots, requestID idempotency rows and the vec rowid
/// mapping table. Per-scope vec0 partitions are created lazily on the first
/// commit (their dimension is only known after the first embedding response),
/// inside the same transaction as that commit. Idempotent DDL, additive only.
pub fn schema(connection: &Connection) -> Result<()> {
    connection
        .execute_batch(
            "CREATE TABLE IF NOT EXISTS memory_snapshots (
                world_id TEXT NOT NULL,
                resident_scope TEXT NOT NULL,
                revision INTEGER NOT NULL CHECK (revision >= 1),
                vector_generation INTEGER NOT NULL CHECK (vector_generation >= 1),
                processed_watermark INTEGER NOT NULL CHECK (processed_watermark >= 0),
                next_watermark INTEGER NOT NULL CHECK (next_watermark >= 1),
                embedding_model TEXT NOT NULL,
                embedding_dimensions INTEGER NOT NULL
                    CHECK (embedding_dimensions > 0 AND embedding_dimensions <= 8192),
                sections TEXT NOT NULL,
                updated_at_ms INTEGER NOT NULL,
                PRIMARY KEY (world_id, resident_scope)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS memory_requests (
                world_id TEXT NOT NULL,
                resident_scope TEXT NOT NULL,
                request_id TEXT NOT NULL,
                revision INTEGER NOT NULL,
                vector_generation INTEGER NOT NULL,
                processed_watermark INTEGER NOT NULL,
                digest TEXT NOT NULL,
                committed_at_ms INTEGER NOT NULL,
                PRIMARY KEY (world_id, resident_scope, request_id)
            ) WITHOUT ROWID;
            CREATE TABLE IF NOT EXISTS memory_vec_rows (
                world_id TEXT NOT NULL,
                resident_scope TEXT NOT NULL,
                vec_rowid INTEGER NOT NULL,
                entry_id TEXT NOT NULL,
                section TEXT NOT NULL CHECK (section IN ('facts', 'notes')),
                entry TEXT NOT NULL,
                PRIMARY KEY (world_id, resident_scope, vec_rowid)
            ) WITHOUT ROWID;
            CREATE INDEX IF NOT EXISTS memory_vec_rows_scope
                ON memory_vec_rows(world_id, resident_scope);",
        )
        .map_err(|_| "memory_storage_failed")?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Storage helpers
// ---------------------------------------------------------------------------

fn partition_name(world_id: &str, resident_scope: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(world_id.as_bytes());
    hasher.update(b"\0");
    hasher.update(resident_scope.as_bytes());
    format!("memory_vec_{:x}", hasher.finalize())
}

pub fn stored_row(
    connection: &Connection,
    world_id: &str,
    resident_scope: &str,
) -> Result<Option<StoredRow>> {
    let row: Option<(i64, i64, i64, i64, String, i64, String)> = connection
        .query_row(
            "SELECT revision, vector_generation, processed_watermark, next_watermark,
                    embedding_model, embedding_dimensions, sections
             FROM memory_snapshots
             WHERE world_id=?1 AND resident_scope=?2",
            params![world_id, resident_scope],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )
        .optional()
        .map_err(|_| "memory_storage_failed")?;
    row.map(|(revision, vector_generation, processed_watermark, next_watermark, embedding_model, embedding_dimensions, sections)| {
        let sections: Sections = serde_json::from_str(&sections)
            .map_err(|_| "memory_history_unavailable")?;
        Ok(StoredRow {
            revision,
            vector_generation,
            processed_watermark,
            next_watermark,
            embedding: EmbeddingRef {
                model: embedding_model,
                dimensions: embedding_dimensions as usize,
            },
            sections,
        })
    })
    .transpose()
}

/// The durable next watermark for a scope: the committed snapshot's
/// `nextWatermark`, or 1 when the scope has no snapshot yet.
pub fn durable_watermark(
    connection: &Connection,
    world_id: &str,
    resident_scope: &str,
) -> Result<i64> {
    let watermark: Option<i64> = connection
        .query_row(
            "SELECT next_watermark FROM memory_snapshots
             WHERE world_id=?1 AND resident_scope=?2",
            params![world_id, resident_scope],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| "memory_storage_failed")?;
    Ok(watermark.unwrap_or(1))
}

/// Assemble the full §2.1 snapshot JSON for a stored row.
pub fn snapshot_value(row: &StoredRow) -> Result<Value> {
    let value = json!({
        "schemaVersion": SCHEMA_VERSION,
        "revision": row.revision,
        "vectorGeneration": row.vector_generation,
        "processedWatermark": row.processed_watermark,
        "nextWatermark": row.next_watermark,
        "embedding": {
            "model": row.embedding.model,
            "dimensions": row.embedding.dimensions
        },
        "sections": row.sections,
    });
    let serialized = serde_json::to_vec(&value).map_err(|_| "invalid_response")?;
    if serialized.len() > SNAPSHOT_LIMIT {
        return fail("memory_snapshot_too_large");
    }
    Ok(value)
}

/// memory_status memory summary, or `None` when the scope has no snapshot.
pub fn status_summary(
    connection: &Connection,
    world_id: &str,
    resident_scope: &str,
) -> Result<Option<Value>> {
    let row = stored_row(connection, world_id, resident_scope)?;
    Ok(row.map(|row| {
        json!({
            "schemaVersion": SCHEMA_VERSION,
            "revision": row.revision,
            "vectorGeneration": row.vector_generation,
            "processedWatermark": row.processed_watermark,
            "nextWatermark": row.next_watermark,
            "embedding": {
                "model": row.embedding.model,
                "dimensions": row.embedding.dimensions
            },
            "entryCounts": {
                "facts": row.sections.facts.len(),
                "notes": row.sections.notes.len()
            }
        })
    }))
}

/// requestID idempotency read (contract §3.7). Returns the recorded result
/// only when the digest matches; a recorded row with a different digest is a
/// `memory_request_conflict` (same requestID, different content).
pub fn recorded_replay(
    connection: &Connection,
    world_id: &str,
    resident_scope: &str,
    request_id: &str,
    digest: &str,
) -> Result<Option<(i64, i64, i64)>> {
    let row: Option<(i64, i64, i64, String)> = connection
        .query_row(
            "SELECT revision, vector_generation, processed_watermark, digest
             FROM memory_requests
             WHERE world_id=?1 AND resident_scope=?2 AND request_id=?3",
            params![world_id, resident_scope, request_id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()
        .map_err(|_| "memory_storage_failed")?;
    match row {
        None => Ok(None),
        Some((revision, generation, processed, recorded_digest)) => {
            if recorded_digest != digest {
                return fail("memory_request_conflict");
            }
            Ok(Some((revision, generation, processed)))
        }
    }
}

/// Result of a compact commit (also used for in-transaction replay).
#[derive(Clone, Debug, PartialEq)]
pub struct CompactResult {
    pub revision: i64,
    pub vector_generation: i64,
    pub processed_watermark: i64,
    pub replayed: bool,
}

/// One entry destined for the vec mapping table, with the vector column order
/// preserved (`vectors` is parallel to `entries`).
#[derive(Clone, Debug)]
pub struct VecEntry {
    pub section: &'static str,
    pub entry: Entry,
}

/// Everything needed to persist one compaction output atomically.
#[derive(Clone, Debug)]
pub struct CompactCommit {
    pub world_id: String,
    pub resident_scope: String,
    pub request_id: String,
    pub expected: Option<i64>,
    pub digest: String,
    pub processed_watermark: i64,
    pub next_watermark: i64,
    pub embedding: EmbeddingRef,
    pub entries: Vec<VecEntry>,
    pub vectors: Vec<Vec<f32>>,
}

fn is_primary_key_conflict(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(e, _)
            if e.code == rusqlite::ErrorCode::ConstraintViolation
                && e.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_PRIMARYKEY
    )
}

/// Atomically replace a scope's snapshot and vector partition (contract §2.5).
///
/// Runs inside the caller's transaction (single storage thread). The requestID
/// row is reserved first so two racing compactions of the same requestID
/// resolve to a replay instead of double-writing; every later write rolls back
/// together on any failure, so the database never holds "new snapshot + old
/// vectors" or vice versa.
pub fn commit(transaction: &Transaction<'_>, c: &CompactCommit) -> Result<CompactResult> {
    if !scope_valid(&c.world_id, &c.resident_scope) {
        return fail("invalid_scope");
    }
    if c.vectors.len() != c.entries.len() {
        return fail("memory_storage_failed");
    }
    if c.processed_watermark < 1 || c.next_watermark <= c.processed_watermark {
        return fail("memory_storage_failed");
    }
    if c.embedding.dimensions == 0 || c.embedding.dimensions > EMBEDDING_DIM_LIMIT {
        return fail("invalid_vector");
    }

    // requestID idempotency wins over every guard: a retried request replays
    // its recorded result without re-checking CAS or the stale guard (content
    // identical by digest); a recorded row with a different digest is a
    // `memory_request_conflict`.
    if let Some((revision, generation, processed)) =
        recorded_replay(transaction, &c.world_id, &c.resident_scope, &c.request_id, &c.digest)?
    {
        return Ok(CompactResult {
            revision,
            vector_generation: generation,
            processed_watermark: processed,
            replayed: true,
        });
    }

    let previous = stored_row(transaction, &c.world_id, &c.resident_scope)?;

    // CAS and embedding consistency against the stored snapshot.
    let (new_revision, new_generation) = match &previous {
        None => {
            if c.expected.is_some_and(|expected| expected != 0) {
                return fail("memory_conflict");
            }
            (1, 1)
        }
        Some(row) => {
            if c.expected.is_some_and(|expected| expected != row.vector_generation) {
                return fail("memory_conflict");
            }
            // A commit whose captured turns were already processed by an
            // earlier commit must not advance again (late/duplicate
            // compaction, contract §2.4); this also protects writers that did
            // not provide expectedVectorGeneration.
            if row.processed_watermark >= c.processed_watermark {
                return fail("memory_conflict");
            }
            if row.embedding.model != c.embedding.model
                || row.embedding.dimensions != c.embedding.dimensions
            {
                return fail("embedding_dimension_mismatch");
            }
            (row.revision + 1, row.vector_generation + 1)
        }
    };

    // Reserve the requestID first: a racing duplicate of the same requestID
    // must replay the recorded result before any snapshot/vector write happens.
    let insert_request = transaction
        .execute(
            "INSERT INTO memory_requests
                (world_id, resident_scope, request_id, revision, vector_generation,
                 processed_watermark, digest, committed_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                c.world_id,
                c.resident_scope,
                c.request_id,
                new_revision,
                new_generation,
                c.processed_watermark,
                c.digest,
                now_ms()
            ],
        );
    match insert_request {
        Ok(_) => {}
        Err(error) if is_primary_key_conflict(&error) => {
            // Same (scope, requestID) landed between the caller's pre-check and
            // this transaction: replay if content matches, conflict otherwise.
            let recorded = recorded_replay(
                transaction,
                &c.world_id,
                &c.resident_scope,
                &c.request_id,
                &c.digest,
            )?;
            return match recorded {
                Some((revision, generation, processed)) => Ok(CompactResult {
                    revision,
                    vector_generation: generation,
                    processed_watermark: processed,
                    replayed: true,
                }),
                None => fail("memory_request_conflict"),
            };
        }
        Err(_) => return fail("memory_storage_failed"),
    }

    // Assemble and size-check the sections JSON.
    let mut facts: Vec<Entry> = Vec::new();
    let mut notes: Vec<Entry> = Vec::new();
    for entry in &c.entries {
        match entry.section {
            "facts" => facts.push(entry.entry.clone()),
            "notes" => notes.push(entry.entry.clone()),
            _ => return fail("memory_storage_failed"),
        }
    }
    if facts.len() > FACTS_LIMIT || notes.len() > NOTES_LIMIT {
        return fail("compaction_rejected");
    }
    let sections = Sections { facts, notes };
    let sections_text =
        serde_json::to_string(&sections).map_err(|_| "invalid_response")?;
    if sections_text.len() > SNAPSHOT_LIMIT {
        return fail("compaction_rejected");
    }

    // Replace the scope's vector partition contents (create lazily with the
    // stored dimension on first commit) inside this same transaction. Every
    // partition carries a `section` metadata column ('facts'|'notes') so the
    // two recall lanes each rank with a section filter applied *before* the
    // vec0 KNN (never a global top-k with a late section drop). A partition
    // created by an older binary without the column is dropped and recreated
    // in this same transaction (its contents are replaced anyway).
    let table = partition_name(&c.world_id, &c.resident_scope);
    let mut table_exists: bool = connection_table_exists(transaction, &table)?;
    if table_exists && !partition_has_section(transaction, &table)? {
        transaction
            .execute_batch(&format!("DROP TABLE \"{table}\";"))
            .map_err(|_| "memory_storage_failed")?;
        table_exists = false;
    }
    if !table_exists && !c.entries.is_empty() {
        transaction
            .execute_batch(&format!(
                "CREATE VIRTUAL TABLE \"{table}\" USING vec0(v float32[{}] distance_metric=cosine, section text);",
                c.embedding.dimensions
            ))
            .map_err(|_| "memory_storage_failed")?;
    }
    transaction
        .execute(
            "DELETE FROM memory_vec_rows WHERE world_id=?1 AND resident_scope=?2",
            params![c.world_id, c.resident_scope],
        )
        .map_err(|_| "memory_storage_failed")?;
    if table_exists && !c.entries.is_empty() {
        transaction
            .execute(&format!("DELETE FROM \"{table}\"") , [])
            .map_err(|_| "memory_storage_failed")?;
    }
    for (index, entry) in c.entries.iter().enumerate() {
        let vector_json =
            serde_json::to_string(&c.vectors[index]).map_err(|_| "invalid_response")?;
        transaction
            .execute(
                &format!("INSERT INTO \"{table}\" (v, section) VALUES (?1, ?2)"),
                params![vector_json, entry.section],
            )
            .map_err(|_| "memory_storage_failed")?;
        let vec_rowid = transaction.last_insert_rowid();
        let entry_json =
            serde_json::to_string(&entry.entry).map_err(|_| "invalid_response")?;
        transaction
            .execute(
                "INSERT INTO memory_vec_rows
                    (world_id, resident_scope, vec_rowid, entry_id, section, entry)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    c.world_id,
                    c.resident_scope,
                    vec_rowid,
                    entry.entry.id,
                    entry.section,
                    entry_json
                ],
            )
            .map_err(|_| "memory_storage_failed")?;
    }

    // Upsert the snapshot row (scalars + sections) in the same transaction.
    transaction
        .execute(
            "INSERT INTO memory_snapshots
                (world_id, resident_scope, revision, vector_generation,
                 processed_watermark, next_watermark, embedding_model,
                 embedding_dimensions, sections, updated_at_ms)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
             ON CONFLICT(world_id, resident_scope) DO UPDATE SET
                revision=excluded.revision,
                vector_generation=excluded.vector_generation,
                processed_watermark=excluded.processed_watermark,
                next_watermark=excluded.next_watermark,
                embedding_model=excluded.embedding_model,
                embedding_dimensions=excluded.embedding_dimensions,
                sections=excluded.sections,
                updated_at_ms=excluded.updated_at_ms",
            params![
                c.world_id,
                c.resident_scope,
                new_revision,
                new_generation,
                c.processed_watermark,
                c.next_watermark,
                c.embedding.model,
                c.embedding.dimensions as i64,
                sections_text,
                now_ms()
            ],
        )
        .map_err(|_| "memory_storage_failed")?;

    Ok(CompactResult {
        revision: new_revision,
        vector_generation: new_generation,
        processed_watermark: c.processed_watermark,
        replayed: false,
    })
}

/// True when an existing vec0 partition already carries the `section`
/// metadata column used by the two recall lanes.
fn partition_has_section(connection: &Connection, name: &str) -> Result<bool> {
    let sql: Option<String> = connection
        .query_row(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name=?1",
            params![name],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| "memory_storage_failed")?;
    Ok(sql.is_some_and(|sql| sql.contains("section text")))
}

fn connection_table_exists(connection: &Connection, name: &str) -> Result<bool> {
    let exists: bool = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1",
            params![name],
            |_| Ok(()),
        )
        .optional()
        .map_err(|_| "memory_storage_failed")?
        .is_some();
    Ok(exists)
}

/// KNN retrieval on the scope's current-generation partition (contract §3.4):
/// the vec0 table holds only this scope's current-generation vectors, so
/// top-k runs after the structural scope filter, never a global top-k. Query
/// dimension/model equality is checked by the caller before this runs.
pub fn search(
    connection: &Connection,
    world_id: &str,
    resident_scope: &str,
    query_vector: &[f32],
    top_k: usize,
) -> Result<Vec<Value>> {
    let row = stored_row(connection, world_id, resident_scope)?;
    let Some(row) = row else {
        return Ok(Vec::new());
    };
    if row.embedding.dimensions != query_vector.len() {
        return fail("embedding_dimension_mismatch");
    }
    let table = partition_name(world_id, resident_scope);
    if !connection_table_exists(connection, &table)? {
        return Ok(Vec::new());
    }
    let query_json = serde_json::to_string(query_vector).map_err(|_| "invalid_response")?;
    let mut statement = connection
        .prepare(&format!(
            "SELECT rowid, distance FROM \"{table}\"
             WHERE v MATCH ?1 ORDER BY distance LIMIT ?2"
        ))
        .map_err(|_| "memory_storage_failed")?;
    let mut rows = statement
        .query(params![query_json, top_k as i64])
        .map_err(|_| "memory_storage_failed")?;
    let mut hits = Vec::new();
    while let Some(row) = rows.next().map_err(|_| "memory_storage_failed")? {
        let vec_rowid: i64 = row.get(0).map_err(|_| "memory_storage_failed")?;
        let distance: f64 = row.get(1).map_err(|_| "memory_storage_failed")?;
        let mapped: Option<(String, String, String)> = connection
            .query_row(
                "SELECT entry_id, section, entry FROM memory_vec_rows
                 WHERE world_id=?1 AND resident_scope=?2 AND vec_rowid=?3",
                params![world_id, resident_scope, vec_rowid],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()
            .map_err(|_| "memory_storage_failed")?;
        let Some((_entry_id, section, entry_json)) = mapped else {
            continue;
        };
        let entry: Value = serde_json::from_str(&entry_json)
            .map_err(|_| "memory_history_unavailable")?;
        let mut hit = json!({
            "section": section,
            "id": entry["id"],
            "text": entry["text"],
            "distance": distance,
        });
        if let Some(observed_at) = entry.get("observedAt") {
            hit["observedAt"] = observed_at.clone();
        }
        hits.push(hit);
    }
    Ok(hits)
}

/// Per-lane KNN retrieval for `memory_recall`: the vec0 partition carries a
/// `section` metadata column, so sqlite-vec filters by scope (the partition
/// itself is per scope and current-generation only) *and* section before it
/// ranks; the lane top-k is never a global top-k with a late section drop.
/// The caller already re-checked stored model/dimensions inside the same
/// `db.call`, so all returned rows come from one generation/space.
pub fn search_lane(
    connection: &Connection,
    world_id: &str,
    resident_scope: &str,
    section: &str,
    query_vector: &[f32],
    limit: usize,
) -> Result<Vec<Value>> {
    let row = stored_row(connection, world_id, resident_scope)?;
    let Some(row) = row else {
        return Ok(Vec::new());
    };
    if row.embedding.dimensions != query_vector.len() {
        return fail("embedding_dimension_mismatch");
    }
    let table = partition_name(world_id, resident_scope);
    if !connection_table_exists(connection, &table)? {
        return Ok(Vec::new());
    }
    // A partition written by a pre-orchestration binary has no `section`
    // column. It cannot be lane-filtered, and the next consolidation commit
    // already recreates it with the column (commit() upgrades in place), so a
    // recall degrades to no semantic hits until then instead of failing.
    if !partition_has_section(connection, &table)? {
        return Ok(Vec::new());
    }
    let query_json = serde_json::to_string(query_vector).map_err(|_| "invalid_response")?;
    let mut statement = connection
        .prepare(&format!(
            "SELECT rowid, distance FROM \"{table}\"
             WHERE v MATCH ?1 AND section = ?2 ORDER BY distance LIMIT ?3"
        ))
        .map_err(|_| "memory_storage_failed")?;
    let mut rows = statement
        .query(params![query_json, section, limit as i64])
        .map_err(|_| "memory_storage_failed")?;
    let mut hits = Vec::new();
    while let Some(row) = rows.next().map_err(|_| "memory_storage_failed")? {
        let vec_rowid: i64 = row.get(0).map_err(|_| "memory_storage_failed")?;
        let distance: f64 = row.get(1).map_err(|_| "memory_storage_failed")?;
        let mapped: Option<(String, String)> = connection
            .query_row(
                "SELECT entry_id, entry FROM memory_vec_rows
                 WHERE world_id=?1 AND resident_scope=?2 AND vec_rowid=?3",
                params![world_id, resident_scope, vec_rowid],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|_| "memory_storage_failed")?;
        let Some((_entry_id, entry_json)) = mapped else {
            continue;
        };
        let entry: Value = serde_json::from_str(&entry_json)
            .map_err(|_| "memory_history_unavailable")?;
        let mut hit = json!({
            "section": section,
            "id": entry["id"],
            "text": entry["text"],
            "distance": distance,
        });
        if let Some(observed_at) = entry.get("observedAt") {
            hit["observedAt"] = observed_at.clone();
        }
        hits.push(hit);
    }
    Ok(hits)
}

// ---------------------------------------------------------------------------
// Pending buffers and provider configuration (in-memory, per daemon process)
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct ProviderConfig {
    pub endpoint: String,
    pub token: String,
    pub model: Option<String>,
}

#[derive(Clone, Debug, Default)]
pub struct Providers {
    pub compaction: Option<ProviderConfig>,
    pub embedding: Option<ProviderConfig>,
}

/// Volatile metadata of one accepted, delivered `memory_ingest` pair (its two
/// pending turns plus the source/observedAt of the delivery). Kept in memory so
/// the *preceding* delivered agent reply still participates in the next
/// background extraction after its own turns were cleared by a consolidation
/// (right-brain feedback attribution). Never persisted.
#[derive(Clone, Debug)]
struct PairMeta {
    user_watermark: i64,
    agent_reply: String,
    source: String,
    observed_at: Option<String>,
}

impl PairMeta {
    /// The (text, source, observedAt) of this delivered agent reply, as JSON
    /// for the extraction context.
    fn context(&self) -> Value {
        let mut value = json!({
            "text": self.agent_reply,
            "source": self.source,
        });
        if let Some(observed_at) = &self.observed_at {
            value["observedAt"] = json!(observed_at);
        }
        value
    }
}

#[derive(Clone, Debug, Default)]
struct Buffer {
    turns: VecDeque<VolatileTurn>,
    next_watermark: i64,
    /// (scope, requestID) -> content digest, most recent first-bounded FIFO.
    receipts: VecDeque<(String, String)>,
    /// Delivered ingest pairs in watermark order, bounded FIFO.
    pairs: VecDeque<PairMeta>,
}

impl Buffer {
    /// The delivered agent reply immediately preceding the first pending turn
    /// (by user-turn watermark), for background extraction context. `None`
    /// when nothing has been delivered before the current window.
    fn predecessor_context(&self, oldest_pending_watermark: i64) -> Option<Value> {
        self.pairs
            .iter()
            .rev()
            .find(|pair| pair.user_watermark + 1 < oldest_pending_watermark)
            .map(PairMeta::context)
    }
}

// Wire request shapes. Top-level params are strict (`deny_unknown_fields`) so
// a contract typo fails loudly instead of silently dropping a field.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConfigureRequest {
    pub kind: String,
    pub endpoint: String,
    pub token: String,
    #[serde(default)]
    pub model: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StatusRequest {
    pub scope: Scope,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadRequest {
    pub scope: Scope,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct QueryRequest {
    pub scope: Scope,
    pub query: String,
    #[serde(default)]
    pub top_k: Option<usize>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct TurnRequest {
    pub scope: Scope,
    pub role: String,
    pub text: String,
    #[serde(default)]
    pub interrupted: bool,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct PendingRequest {
    pub scope: Scope,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CompactRequest {
    pub scope: Scope,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "expectedVectorGeneration")]
    pub expected: Option<i64>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IngestRequest {
    pub scope: Scope,
    #[serde(rename = "requestID")]
    pub request_id: String,
    #[serde(rename = "userText")]
    pub user_text: String,
    #[serde(rename = "agentReply")]
    pub agent_reply: String,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(rename = "observedAt")]
    pub observed_at: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecallRequest {
    pub scope: Scope,
    pub query: String,
    #[serde(rename = "freshSession")]
    pub fresh_session: Option<bool>,
    #[serde(rename = "factLimit")]
    pub fact_limit: Option<usize>,
    #[serde(rename = "noteLimit")]
    pub note_limit: Option<usize>,
}

// ---------------------------------------------------------------------------
// Provider transports and deterministic output validation
// ---------------------------------------------------------------------------

/// Real HTTP POST to a configured provider (compaction or embedding). Mirrors
/// the existing wish provider rules: no redirects, no proxy, no retry, bearer
/// token, streamed response cap, and a whole-response token leak check.
async fn post_json(
    client: &reqwest::Client,
    endpoint: &str,
    token: &str,
    path: &str,
    body: Value,
    limit: usize,
) -> Result<Value> {
    let url = format!("{endpoint}{path}");
    let mut response = client
        .post(&url)
        .bearer_auth(token)
        .json(&body)
        .send()
        .await
        .map_err(|error| {
            eprintln!("POST {url} send error: {error:?}");
            "network_unavailable"
        })?;
    if !response.status().is_success() {
        return Err(match response.status().as_u16() {
            401 | 403 => "authentication_required",
            300..=399 => "redirect_rejected",
            400 | 409 | 422 => "request_rejected",
            _ => "remote_unavailable",
        });
    }
    if response.url().as_str() != url
        || response
            .content_length()
            .is_some_and(|n| n > limit as u64)
    {
        return Err("response_too_large_or_unsafe");
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| "network_unavailable")? {
        if bytes.len() + chunk.len() > limit {
            return Err("response_too_large_or_unsafe");
        }
        bytes.extend_from_slice(&chunk);
    }
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| "invalid_response")?;
    if crate::provider::contains_secret(&value, token) {
        return Err("invalid_response");
    }
    Ok(value)
}

/// One entry parsed from the provider envelope, id assigned by the daemon.
fn parse_entry(item: &Value, require_grounding: bool) -> Result<Entry> {
    let object = item.as_object().ok_or("compaction_rejected")?;
    let category = object
        .get("category")
        .and_then(Value::as_str)
        .ok_or("compaction_rejected")?;
    let text = object
        .get("text")
        .and_then(Value::as_str)
        .and_then(trim_no_control)
        .filter(|text| bounded_chars(text, ENTRY_TEXT_LIMIT))
        .ok_or("compaction_rejected")?;
    let observed_at = match object.get("observedAt") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_str()
                .and_then(trim_no_control)
                .filter(|observed| bounded_chars(observed, OBSERVED_AT_LIMIT))
                .ok_or("compaction_rejected")?,
        ),
    };
    let grounding = match object.get("grounding") {
        None | Some(Value::Null) => {
            if require_grounding {
                return fail("compaction_rejected");
            }
            None
        }
        Some(value) => Some(
            value
                .as_str()
                .and_then(trim_no_control)
                .filter(|grounding| bounded_chars(grounding, GROUNDING_LIMIT))
                .ok_or("compaction_rejected")?,
        ),
    };
    Ok(Entry {
        id: uuid::Uuid::new_v4().hyphenated().to_string(),
        category: category.to_owned(),
        text,
        observed_at,
        grounding,
    })
}

fn previous_ids(sections: &Sections) -> Vec<String> {
    sections
        .facts
        .iter()
        .chain(sections.notes.iter())
        .map(|entry| entry.id.clone())
        .collect()
}

/// Deterministic compaction envelope validation (contract §4.1). Every rule
/// violation is `compaction_rejected`; the daemon never trusts the model to
/// self-police shape, caps, category whitelists, notes grounding or removed
/// references.
fn parse_compaction_output(previous: Option<&Sections>, value: &Value) -> Result<Vec<VecEntry>> {
    let object = value.as_object().ok_or("compaction_rejected")?;
    let mut entries = Vec::new();
    for (key, categories, require_grounding, limit) in [
        ("facts", &["fact", "preference"][..], false, FACTS_LIMIT),
        ("notes", &["relationship", "experience"][..], true, NOTES_LIMIT),
    ] {
        let array = object.get(key).and_then(Value::as_array).ok_or("compaction_rejected")?;
        if array.len() > limit {
            return fail("compaction_rejected");
        }
        for item in array {
            let entry = parse_entry(item, require_grounding)?;
            if !categories.contains(&entry.category.as_str()) {
                return fail("compaction_rejected");
            }
            entries.push(VecEntry {
                section: key,
                entry,
            });
        }
    }
    // removed must reference entries of the previous version, uniquely, and
    // not reappear as daemon-assigned ids in the new arrays. An empty removed
    // list (or an absent key) carries no constraint, including on the first
    // compaction when there is no previous snapshot yet.
    if let Some(removed) = object.get("removed") {
        let removed_array = removed.as_array().ok_or("compaction_rejected")?;
        if !removed_array.is_empty() {
            let mut removed_ids = Vec::new();
            for id in removed_array {
                let id = id.as_str().ok_or("compaction_rejected")?;
                if removed_ids.contains(&id) {
                    return fail("compaction_rejected");
                }
                removed_ids.push(id);
            }
            let previous = previous.ok_or("compaction_rejected")?;
            let existing = previous_ids(previous);
            for id in removed_ids {
                if !existing.iter().any(|old| old == id) {
                    return fail("compaction_rejected");
                }
            }
        }
    }
    Ok(entries)
}

/// Keep stable entry ids across snapshots: an entry in the provider's new
/// sections whose content exactly matches a previous entry (same lane,
/// category, text, observedAt and grounding) reuses that previous id, so
/// unchanged long-term entries never churn to fresh ids every consolidation.
/// Entries listed under `removed` are excluded (correction/deletion), and an
/// entry with changed content gets a fresh id, exactly as the frozen
/// "removed + replacement" correction semantics require.
fn stabilize_entry_ids(
    previous: Option<&Sections>,
    removed: &[String],
    entries: Vec<VecEntry>,
) -> Vec<VecEntry> {
    let Some(previous) = previous else {
        return entries;
    };
    let mut removed: HashSet<&str> = removed.iter().map(String::as_str).collect();
    type EntryKey = (String, String, Option<String>, Option<String>);
    let mut reusable: HashMap<EntryKey, Vec<String>> = HashMap::new();
    for old in previous.facts.iter().chain(previous.notes.iter()) {
        if removed.remove(old.id.as_str()) {
            continue;
        }
        let key = entry_content_key(old);
        reusable.entry(key).or_default().push(old.id.clone());
    }
    let mut stabilized = entries;
    for entry in &mut stabilized {
        let key = entry_content_key(&entry.entry);
        if let Some(queue) = reusable.get_mut(&key) {
            if let Some(id) = queue.pop() {
                entry.entry.id = id;
            }
        }
    }
    stabilized
}

fn entry_content_key(entry: &Entry) -> (String, String, Option<String>, Option<String>) {
    (
        entry.category.clone(),
        entry.text.clone(),
        // observed_at and grounding participate so a corrected or re-grounded
        // note is treated as new content, never silently rewritten.
        entry.observed_at.clone(),
        entry.grounding.clone(),
    )
}

/// Append `block` to `out` under the shared Unicode-character budget; once the
/// budget is exhausted, later blocks are dropped and a stable truncation marker
/// replaces the tail of the first over-budget block.
fn append_bounded(out: &mut String, budget: usize, truncated: &mut bool, block: &str) {
    if *truncated {
        return;
    }
    const MARKER: &str = "...（上下文已按字符预算截断）";
    let used = out.chars().count();
    let room = budget.saturating_sub(used);
    let block_len = block.chars().count();
    if block_len <= room {
        out.push_str(block);
        return;
    }
    let keep = room.saturating_sub(MARKER.chars().count());
    out.extend(block.chars().take(keep));
    if room >= MARKER.chars().count() {
        out.push_str(MARKER);
    } else {
        out.extend(MARKER.chars().take(room));
    }
    *truncated = true;
}

/// Deterministic bounded plain-text fusion of the two recall lanes plus (only
/// for a genuinely fresh session) a clearly labeled bounded restore of the
/// confirmed local snapshot and volatile pending turns. Notes are always
/// marked as tone/reference-only guidance that must never be read back.
#[allow(clippy::too_many_arguments)]
fn build_recall_context(
    fresh_session: bool,
    status: &str,
    facts: &[Value],
    notes: &[Value],
    sections: Option<&Sections>,
    pending: &[VolatileTurn],
    revision: i64,
    vector_generation: i64,
) -> String {
    let budget = RECALL_CONTEXT_LIMIT;
    let mut out = String::new();
    let mut truncated = false;

    if !facts.is_empty() {
        let mut block = String::from("已确认事实与偏好（供回复引用）：\n");
        for hit in facts {
            block.push_str(" - ");
            block.push_str(hit["text"].as_str().unwrap_or(""));
            block.push('\n');
        }
        append_bounded(&mut out, budget, &mut truncated, &block);
    }
    if !notes.is_empty() {
        let mut block = format!("相处/关系经验参考（{NOTES_TONE_MARKER}）：\n");
        for hit in notes {
            block.push_str(" - ");
            block.push_str(hit["text"].as_str().unwrap_or(""));
            block.push('\n');
        }
        append_bounded(&mut out, budget, &mut truncated, &block);
    }
    if status == "unconfigured" {
        append_bounded(
            &mut out,
            budget,
            &mut truncated,
            "语义记忆检索当前不可用：下列内容仅为本地可确认的快照与未入库缓冲，不代表语义检索命中。\n",
        );
    } else if facts.is_empty() && notes.is_empty() {
        append_bounded(
            &mut out,
            budget,
            &mut truncated,
            "暂无与该话题直接相关的已确认长期记忆证据；请基于已知信息谨慎回应，不要编造具体经历或细节。\n",
        );
    }

    if fresh_session {
        let mut block = String::from("== 新会话恢复 ==\n");
        block.push_str(&format!(
            "已确认长期记忆快照（revision={revision}，vectorGeneration={vector_generation}）：\n",
            revision = revision,
            vector_generation = vector_generation,
        ));
        if let Some(sections) = sections {
            let fact_ids: HashSet<&str> = facts
                .iter()
                .filter_map(|hit| hit["id"].as_str())
                .collect();
            let note_ids: HashSet<&str> = notes
                .iter()
                .filter_map(|hit| hit["id"].as_str())
                .collect();
            if !sections.facts.is_empty() {
                block.push_str("长期事实/偏好：\n");
                for entry in sections
                    .facts
                    .iter()
                    .filter(|entry| !fact_ids.contains(entry.id.as_str()))
                {
                    block.push_str("  * ");
                    block.push_str(&entry.text);
                    block.push('\n');
                }
            }
            if !sections.notes.is_empty() {
                block.push_str(&format!(
                    "相处/经验笔记（{NOTES_TONE_MARKER}）：\n"
                ));
                for entry in sections
                    .notes
                    .iter()
                    .filter(|entry| !note_ids.contains(entry.id.as_str()))
                {
                    block.push_str("  * ");
                    block.push_str(&entry.text);
                    block.push('\n');
                }
            }
        }
        let recent: Vec<&VolatileTurn> = pending.iter().rev().take(FRESH_RESTORE_TURNS).collect();
        if !recent.is_empty() {
            block.push_str("尚未入库的近期回合（易失缓冲，仅供本次恢复参考）：\n");
            for turn in recent.iter().rev() {
                block.push_str("  ");
                block.push_str(&turn.role);
                block.push_str(": ");
                block.push_str(&turn.text);
                block.push('\n');
            }
        }
        block.push_str("== 新会话恢复结束 ==");
        append_bounded(&mut out, budget, &mut truncated, &block);
    }
    out
}

#[derive(Clone, Debug)]
struct EmbeddingResult {
    model: String,
    dimensions: usize,
    vectors: Vec<Vec<f32>>,
}

/// Deterministic embedding response validation (contract §4.2) for the
/// standard OpenAI-compatible `/v1/embeddings` wire: the response object
/// carries `model` (top-level or per `data` item) and a `data` array whose
/// `data[index].embedding` entries must arrive in order (`index == position`)
/// with one dense finite float vector of a single shared dimension in
/// `1..=EMBEDDING_DIM_LIMIT`. Every vector must contain at least one nonzero
/// coordinate (a zero vector carries no cosine direction) and every number
/// must be finite. Never accepts NaN/Inf/zero/over-limit vectors.
fn parse_embedding_response(value: &Value, requested: usize) -> Result<EmbeddingResult> {
    let object = value.as_object().ok_or("embedding_rejected")?;
    let data = object
        .get("data")
        .and_then(Value::as_array)
        .ok_or("embedding_rejected")?;
    if data.len() != requested {
        return fail("embedding_rejected");
    }
    let mut model: Option<String> = object
        .get("model")
        .and_then(Value::as_str)
        .map(str::to_owned);
    let mut parsed = Vec::with_capacity(data.len());
    let mut dimensions: Option<usize> = None;
    for (expected_index, item) in data.iter().enumerate() {
        let entry = item.as_object().ok_or("embedding_rejected")?;
        if entry.get("index").and_then(Value::as_i64) != Some(expected_index as i64) {
            return fail("embedding_rejected");
        }
        if let Some(entry_model) = entry.get("model").and_then(Value::as_str) {
            match model {
                Some(ref resolved) if resolved != entry_model => {
                    return fail("embedding_rejected");
                }
                Some(_) => {}
                None => model = Some(entry_model.to_owned()),
            }
        }
        let vector = entry
            .get("embedding")
            .and_then(Value::as_array)
            .ok_or("embedding_rejected")?;
        if vector.is_empty() || vector.len() > EMBEDDING_DIM_LIMIT {
            return fail("invalid_vector");
        }
        if dimensions.is_some_and(|known| known != vector.len()) {
            return fail("embedding_rejected");
        }
        dimensions.get_or_insert(vector.len());
        let mut dense = Vec::with_capacity(vector.len());
        let mut nonzero = false;
        for number in vector {
            let number = number.as_f64().filter(|n| n.is_finite()).ok_or("invalid_vector")?;
            if number != 0.0 {
                nonzero = true;
            }
            dense.push(number as f32);
        }
        if !nonzero {
            return fail("invalid_vector");
        }
        parsed.push(dense);
    }
    let model = model
        .as_deref()
        .and_then(trim_no_control)
        .filter(|model| model.len() <= 200)
        .ok_or("embedding_rejected")?
        .to_owned();
    let dimensions = dimensions.ok_or("embedding_rejected")?;
    Ok(EmbeddingResult {
        model,
        dimensions,
        vectors: parsed,
    })
}

/// Parse the assistant content of an OpenAI-compatible chat-completions
/// response into the frozen compaction envelope. The response must echo the
/// requested model and carry exactly one choice whose `message.content` string
/// parses as the envelope JSON object (optional ``` fences are tolerated);
/// everything else in the response is ignored.
fn compaction_chat_envelope(value: &Value, requested_model: &str) -> Result<Value> {
    let object = value.as_object().ok_or("compaction_rejected")?;
    if object.get("model").and_then(Value::as_str) != Some(requested_model) {
        return fail("compaction_rejected");
    }
    let choices = object
        .get("choices")
        .and_then(Value::as_array)
        .ok_or("compaction_rejected")?;
    let content = choices
        .first()
        .and_then(|choice| choice.get("message"))
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .ok_or("compaction_rejected")?;
    let content = content.trim();
    let content = content
        .strip_prefix("```json")
        .or_else(|| content.strip_prefix("```"))
        .map(str::trim)
        .unwrap_or(content);
    let content = content.strip_suffix("```").map(str::trim).unwrap_or(content);
    let envelope: Value = serde_json::from_str(content).map_err(|_| "compaction_rejected")?;
    if !envelope.is_object() {
        return fail("compaction_rejected");
    }
    Ok(envelope)
}

// ---------------------------------------------------------------------------
// Memory handle (per-scope volatile pending buffers + provider configuration)
// ---------------------------------------------------------------------------

/// commit-after-durability (contract §2.4): drop the pending turns whose
/// watermark is covered by a snapshot that was just committed durably. Runs on
/// the storage thread inside the same `db.call` as the commit (through an
/// `Arc` clone of the buffer map) so a disconnect/cancellation that aborts the
/// async caller can never leave a durable commit with its turns still pending —
/// that would wedge later compactions of the same turns behind the stale guard.
fn clear_covered(
    buffers: &StdMutex<HashMap<(String, String), Buffer>>,
    world_id: &str,
    resident_scope: &str,
    processed_watermark: i64,
) -> usize {
    let mut buffers = buffers.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let key = (world_id.to_owned(), resident_scope.to_owned());
    let Some(buffer) = buffers.get_mut(&key) else {
        return 0;
    };
    buffer
        .turns
        .retain(|turn| turn.watermark > processed_watermark);
    buffer.turns.len()
}

pub struct Memory {
    db: crate::store::Database,
    providers: AsyncRwLock<Providers>,
    buffers: Arc<StdMutex<HashMap<(String, String), Buffer>>>,
    orchestration: Arc<OrchRegistry>,
    policy: Arc<StdMutex<OrchPolicy>>,
    compaction_ready: AtomicBool,
    embedding_ready: AtomicBool,
}

impl Memory {
    pub fn new(db: crate::store::Database) -> Self {
        Self {
            db,
            providers: AsyncRwLock::new(Providers::default()),
            buffers: Arc::new(StdMutex::new(HashMap::new())),
            orchestration: Arc::new(OrchRegistry::new()),
            policy: Arc::new(StdMutex::new(OrchPolicy::default())),
            compaction_ready: AtomicBool::new(false),
            embedding_ready: AtomicBool::new(false),
        }
    }

    /// Replace the injectable orchestration policy (clock/threshold control for
    /// offline tests; production keeps `OrchPolicy::default()`).
    #[cfg(test)]
    pub fn set_orchestration_policy(&self, policy: OrchPolicy) {
        *self
            .policy
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = policy;
    }

    fn policy(&self) -> OrchPolicy {
        *self
            .policy
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Test introspection of the current orchestration state.
    #[cfg(test)]
    pub fn orchestration_state(&self, world_id: &str, resident_scope: &str) -> Option<orchestration::State> {
        let key = (world_id.to_owned(), resident_scope.to_owned());
        self.orchestration.state_of(&key)
    }

    fn providers_configured(&self) -> bool {
        self.compaction_ready.load(Ordering::Acquire)
            && self.embedding_ready.load(Ordering::Acquire)
    }

    fn lock_buffers(&self) -> std::sync::MutexGuard<'_, HashMap<(String, String), Buffer>> {
        self.buffers.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Ensure a per-scope buffer exists, seeding its watermark counter from the
    /// durable snapshot row (or 1 for a scope that never committed).
    async fn seed_buffer(&self, world_id: &str, resident_scope: &str) -> Result<()> {
        let key = (world_id.to_owned(), resident_scope.to_owned());
        if self.lock_buffers().contains_key(&key) {
            return Ok(());
        }
        let durable = {
            let world_id = world_id.to_owned();
            let resident_scope = resident_scope.to_owned();
            self.db
                .call(move |store| {
                    durable_watermark(&store.connection, &world_id, &resident_scope)
                })
                .await?
        };
        self.lock_buffers().entry(key).or_insert(Buffer {
            turns: VecDeque::new(),
            next_watermark: durable,
            receipts: VecDeque::new(),
            pairs: VecDeque::new(),
        });
        Ok(())
    }

    /// Live pending turns (ascending watermark) plus the live next watermark
    /// and count, when a buffer exists for the scope.
    fn live_state(&self, world_id: &str, resident_scope: &str) -> Option<(Vec<VolatileTurn>, i64, usize)> {
        let buffers = self.lock_buffers();
        let buffer = buffers.get(&(world_id.to_owned(), resident_scope.to_owned()))?;
        Some((
            buffer.turns.iter().cloned().collect(),
            buffer.next_watermark,
            buffer.turns.len(),
        ))
    }

    // -- configuration -----------------------------------------------------

    pub async fn configure(
        &self,
        kind: &str,
        endpoint: &str,
        token: &str,
        model: Option<String>,
    ) -> Result<()> {
        if kind != "compaction" && kind != "embedding" {
            return fail("invalid_kind");
        }
        let origin = crate::model::endpoint(endpoint).map_err(|_| "invalid_endpoint")?;
        if token.is_empty()
            || token.len() > 8192
            || !token.bytes().all(|byte| (33..=126).contains(&byte))
        {
            return fail("invalid_token");
        }
        if model
            .as_deref()
            .is_some_and(|m| m.trim().is_empty() || m.len() > 200)
        {
            return fail("invalid_memory_configure");
        }
        let config = ProviderConfig {
            endpoint: origin,
            token: token.to_owned(),
            model: model.map(|m| m.trim().to_owned()).filter(|m| !m.is_empty()),
        };
        let mut providers = self.providers.write().await;
        if kind == "compaction" {
            providers.compaction = Some(config);
            self.compaction_ready.store(true, Ordering::Release);
        } else {
            providers.embedding = Some(config);
            self.embedding_ready.store(true, Ordering::Release);
        }
        Ok(())
    }

    /// Provider tokens held in memory, for request credential hygiene.
    pub async fn configured_tokens(&self) -> Vec<String> {
        let providers = self.providers.read().await;
        [&providers.compaction, &providers.embedding]
            .into_iter()
            .flatten()
            .map(|config| config.token.clone())
            .collect()
    }

    // -- read-only operations ----------------------------------------------

    pub async fn status(&self, scope: Scope) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let providers = self.providers.read().await;
        let configured = json!({
            "compaction": providers.compaction.is_some(),
            "embedding": providers.embedding.is_some(),
        });
        drop(providers);
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();
        let mut memory = self
            .db
            .call(move |store| status_summary(&store.connection, &world_id, &resident_scope))
            .await?;
        let (pending_turns, live_next) = match self.live_state(&scope.world_id, &scope.resident_scope) {
            Some((_, next, count)) => (count, Some(next)),
            None => (0, None),
        };
        // Report the live next watermark when this process has allocated any,
        // so status matches what memory_turn will hand out next.
        if let Some(memory) = memory.as_mut() {
            if let Some(live_next) = live_next {
                memory["nextWatermark"] = json!(live_next);
            }
        }
        let key = (scope.world_id.clone(), scope.resident_scope.clone());
        let (state, last_error) = match self.orchestration.report(&key) {
            Some((state, last_error)) => (state, last_error),
            None => {
                let providers = self.providers_configured();
                if !providers && pending_turns > 0 {
                    ("unconfigured", None)
                } else {
                    ("idle", None)
                }
            }
        };
        Ok(json!({
            "configured": configured,
            "memory": memory,
            "pendingTurns": pending_turns,
            "orchestration": {
                "state": state,
                "lastError": last_error,
            },
        }))
    }

    pub async fn read(&self, scope: Scope) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();
        let memory = self
            .db
            .call(move |store| {
                let row = stored_row(&store.connection, &world_id, &resident_scope)?;
                match row {
                    None => Ok(None),
                    Some(row) => Ok(Some(snapshot_value(&row)?)),
                }
            })
            .await?;
        Ok(json!({ "memory": memory }))
    }

    pub async fn pending(&self, scope: Scope) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let turns = match self.live_state(&scope.world_id, &scope.resident_scope) {
            Some((turns, _, _)) => turns,
            None => Vec::new(),
        };
        Ok(json!({ "turns": turns }))
    }

    // -- memory_turn -------------------------------------------------------

    pub async fn turn(&self, scope: Scope, role: &str, text: &str, interrupted: bool) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        if role != "user" && role != "agent" {
            return fail("invalid_role");
        }
        let text = text.trim();
        if text.is_empty() || text.chars().any(char::is_control) {
            return fail("invalid_turn_text");
        }
        if text.chars().count() > TURN_TEXT_LIMIT {
            return fail("turn_text_too_large");
        }
        self.seed_buffer(&scope.world_id, &scope.resident_scope).await?;
        let mut buffers = self.lock_buffers();
        let key = (scope.world_id.clone(), scope.resident_scope.clone());
        let buffer = buffers
            .get_mut(&key)
            .ok_or("memory_storage_failed")?;
        let watermark = buffer.next_watermark;
        buffer.next_watermark += 1;
        let turn_id = uuid::Uuid::new_v4().hyphenated().to_string();
        buffer.turns.push_back(VolatileTurn {
            turn_id: turn_id.clone(),
            watermark,
            role: role.to_owned(),
            text: text.to_owned(),
            interrupted,
        });
        while buffer.turns.len() > PENDING_TURNS_LIMIT {
            buffer.turns.pop_front();
        }
        let pending_turns = buffer.turns.len();
        drop(buffers);
        Ok(json!({
            "accepted": true,
            "turnID": turn_id,
            "watermark": watermark,
            "pendingTurns": pending_turns,
        }))
    }

    // -- memory_query ------------------------------------------------------

    pub async fn query(
        &self,
        client: &reqwest::Client,
        scope: Scope,
        query_text: &str,
        top_k: Option<usize>,
    ) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let query_text = query_text.trim();
        if query_text.is_empty() || query_text.chars().count() > QUERY_TEXT_LIMIT {
            return fail("invalid_query");
        }
        let top_k = top_k.unwrap_or(8);
        if !(1..=TOP_K_MAX).contains(&top_k) {
            return fail("invalid_topk");
        }
        let unconfigured = || {
            Ok(json!({ "status": "unconfigured", "results": [] }))
        };
        let embedding = {
            let providers = self.providers.read().await;
            providers.embedding.clone()
        };
        let Some(embedding) = embedding else {
            return unconfigured();
        };
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();
        // Pre-embedding snapshot check: which generation/model/dimensions the
        // scope is on before the (async) embedding call.
        let row = self
            .db
            .call(move |store| stored_row(&store.connection, &world_id, &resident_scope))
            .await?;
        let Some(row) = row else {
            // No snapshot yet: no vector generation exists for this scope.
            return unconfigured();
        };
        let captured_model = row.embedding.model.clone();
        let mut body = json!({ "input": [query_text] });
        if let Some(model) = &embedding.model {
            body["model"] = json!(model);
        }
        let response = post_json(
            client,
            &embedding.endpoint,
            &embedding.token,
            EMBEDDING_PATH,
            body,
            EMBEDDING_RESPONSE_LIMIT,
        )
        .await?;
        let parsed = parse_embedding_response(&response, 1)?;
        if parsed.model != captured_model || parsed.dimensions != row.embedding.dimensions {
            return fail("embedding_dimension_mismatch");
        }
        let query_vector = parsed
            .vectors
            .into_iter()
            .next()
            .ok_or("embedding_rejected")?;
        let expected_model = parsed.model.clone();
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();
        // Post-embedding barrier: re-check model/dimensions against the stored
        // snapshot on the storage thread, in the same `db.call` as the search.
        // A concurrent compaction can only swap generations atomically on this
        // writer thread, so checking here means the returned rows always come
        // from one generation whose embedding space matches the query vector —
        // never a mixed-generation or mixed-model result.
        let hits = self
            .db
            .call(move |store| {
                let current = stored_row(&store.connection, &world_id, &resident_scope)?;
                let Some(current) = current else {
                    return Ok(Vec::new());
                };
                if current.embedding.model != expected_model
                    || current.embedding.dimensions != query_vector.len()
                {
                    return fail("embedding_dimension_mismatch");
                }
                search(
                    &store.connection,
                    &world_id,
                    &resident_scope,
                    &query_vector,
                    top_k,
                )
            })
            .await?;
        let status = if hits.is_empty() { "empty" } else { "ok" };
        Ok(json!({ "status": status, "results": hits }))
    }

    // -- memory_compact ----------------------------------------------------

    /// Memory compaction request content digest for requestID idempotency.
    /// The only client-controlled content of a compact is its scope and the
    /// optional CAS expectation (pending turns are volatile daemon state, and
    /// re-running a compact is always against whatever is pending). Replays
    /// never double-process: the recorded commit cleared its pending turns and
    /// the commit-time stale guard rejects any later writer reusing them.
    fn compact_digest(expected: Option<i64>) -> String {
        match expected {
            None => "expected:none".to_owned(),
            Some(generation) => format!("expected:{generation}"),
        }
    }

    pub async fn compact(
        &self,
        client: &reqwest::Client,
        scope: Scope,
        request_id: &str,
        expected: Option<i64>,
        cancel: Cancellation,
    ) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let request_id = identity(request_id).map_err(|_| "invalid_memory_compact")?;
        if expected.is_some_and(|generation| generation < 0) {
            return fail("invalid_memory_compact");
        }
        let digest = Self::compact_digest(expected);
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();

        // 1. requestID idempotency, before any provider work or CAS: a retried
        //    request replays the recorded result without re-compacting.
        let replay = {
            let request_id = request_id.clone();
            let digest = digest.clone();
            let world_id = world_id.clone();
            let resident_scope = resident_scope.clone();
            self.db
                .call(move |store| {
                    recorded_replay(
                        &store.connection,
                        &world_id,
                        &resident_scope,
                        &request_id,
                        &digest,
                    )
                })
                .await?
        };
        if let Some((revision, generation, processed)) = replay {
            let pending_turns = self
                .live_state(&scope.world_id, &scope.resident_scope)
                .map(|(_, _, count)| count)
                .unwrap_or(0);
            return Ok(json!({
                "revision": revision,
                "vectorGeneration": generation,
                "replayed": true,
                "processedWatermark": processed,
                "pendingTurns": pending_turns,
            }));
        }

        // 2. Both providers must be configured before anything that looks like
        //    a result: an empty pending buffer is a no-op summary only when the
        //    providers are real — a missing provider must surface the explicit
        //    unavailable error, never a masqueraded success (contract §3.7).
        let providers = self.providers.read().await;
        let compaction = providers.compaction.clone();
        let embedding = providers.embedding.clone();
        drop(providers);
        let Some(compaction) = compaction else {
            return fail("compaction_unavailable");
        };
        let Some(embedding) = embedding else {
            return fail("embedding_unavailable");
        };

        // 3. Capture this scope's pending buffer (volatile snapshot of the
        //    compaction input).
        self.seed_buffer(&scope.world_id, &scope.resident_scope).await?;
        let (captured_turns, _) = match self.live_state(&scope.world_id, &scope.resident_scope) {
            Some((turns, next, _)) => (turns, next),
            None => return fail("memory_storage_failed"),
        };
        let Some(processed_watermark) = captured_turns.last().map(|turn| turn.watermark) else {
            // Empty capture with real providers: honest no-op summary, nothing
            // to consolidate and nothing advances.
            let summary = self
                .db
                .call({
                    let world_id = world_id.clone();
                    let resident_scope = resident_scope.clone();
                    move |store| {
                        let row = stored_row(&store.connection, &world_id, &resident_scope)?;
                        Ok(row.map(|row| {
                            (row.revision, row.vector_generation, row.processed_watermark)
                        }))
                    }
                })
                .await?;
            let (revision, generation, processed) = summary.unwrap_or((0, 0, 0));
            if expected.is_some_and(|expected| expected != generation) {
                return fail("memory_conflict");
            }
            return Ok(json!({
                "revision": revision,
                "vectorGeneration": generation,
                "replayed": false,
                "processedWatermark": processed,
                "pendingTurns": 0,
            }));
        };

        // 4. Previous snapshot read on the storage thread: this is the base
        //    generation the compaction actually consolidates. It is bound into
        //    the commit below even when the client omitted
        //    expectedVectorGeneration, so a compaction that read a stale
        //    snapshot can never overwrite a commit that landed meanwhile.
        let previous = self
            .db
            .call({
                let world_id = world_id.clone();
                let resident_scope = resident_scope.clone();
                move |store| stored_row(&store.connection, &world_id, &resident_scope)
            })
            .await?;
        let base_generation = previous
            .as_ref()
            .map(|row| row.vector_generation)
            .unwrap_or(0);
        if cancel.canceled() {
            return fail("cancelled");
        }
        if expected.is_some_and(|requested| requested != base_generation) {
            // The client's CAS expectation is already stale relative to the
            // snapshot this compaction read: conflict before any provider call.
            return fail("memory_conflict");
        }
        let bound_expected = Some(base_generation);

        // 5. Compaction provider call: standard OpenAI-compatible chat
        //    completions with the configured model, the frozen semantic rules
        //    as the system prompt and the previous snapshot + captured pending
        //    turns + the preceding delivered agent reply + limits JSON as the
        //    user content (never host prompts, tool results, or credentials).
        //    The preceding delivered reply is retained in the volatile pairs
        //    list even after its own turns were cleared by an earlier
        //    consolidation, so right-brain feedback attribution still sees it.
        let compaction_model = compaction.model.clone().ok_or("memory_compact_failed")?;
        let previous_value = match &previous {
            Some(row) => json!({
                "revision": row.revision,
                "vectorGeneration": row.vector_generation,
                "processedWatermark": row.processed_watermark,
                "nextWatermark": row.next_watermark,
                "embedding": {
                    "model": row.embedding.model,
                    "dimensions": row.embedding.dimensions
                },
                "sections": row.sections,
            }),
            None => Value::Null,
        };
        let previous_reply = {
            let buffers = self.lock_buffers();
            let oldest = captured_turns.first().map(|turn| turn.watermark).unwrap_or(0);
            buffers
                .get(&(world_id.clone(), resident_scope.clone()))
                .and_then(|buffer| buffer.predecessor_context(oldest))
        };
        let data_value = json!({
            "schemaVersion": SCHEMA_VERSION,
            "previous": previous_value,
            "turns": captured_turns,
            "previousReply": previous_reply,
            "limits": {
                "facts": FACTS_LIMIT,
                "notes": NOTES_LIMIT,
                "entryText": ENTRY_TEXT_LIMIT,
                "observedAt": OBSERVED_AT_LIMIT,
                "grounding": GROUNDING_LIMIT,
            },
        });
        let user_content =
            serde_json::to_string(&data_value).map_err(|_| "invalid_response")?;
        let body = json!({
            "model": compaction_model,
            "messages": [
                { "role": "system", "content": COMPACTION_RULES },
                { "role": "user", "content": user_content },
            ],
        });
        let response = post_json(
            client,
            &compaction.endpoint,
            &compaction.token,
            COMPACTION_PATH,
            body,
            COMPACTION_RESPONSE_LIMIT,
        )
        .await
        .map_err(|_| "memory_compact_failed")?;
        if cancel.canceled() {
            return fail("cancelled");
        }
        let envelope = compaction_chat_envelope(&response, &compaction_model)
            .map_err(|_| "compaction_rejected")?;
        let entries = parse_compaction_output(previous.as_ref().map(|row| &row.sections), &envelope)
            .map_err(|_| "compaction_rejected")?;
        // Entries whose content is unchanged from the previous snapshot keep
        // their stable id (corrections/deletions still replace: a corrected
        // entry has different content and is emitted fresh). `removed` ids are
        // never reused.
        let removed_ids: Vec<String> = envelope
            .get("removed")
            .and_then(Value::as_array)
            .map(|array| {
                array
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        let entries = stabilize_entry_ids(
            previous.as_ref().map(|row| &row.sections),
            &removed_ids,
            entries,
        );

        // 6. Embedding provider call: standard OpenAI-compatible `/v1/embeddings`
        //    over every new snapshot entry. When a compaction produced no
        //    entries and a previous snapshot exists, its embedding record is
        //    carried forward (nothing new to embed, deterministic wipe/correction
        //    commit). A first compaction that found nothing memorable still
        //    anchors the scope's model/dimensions with one empty-text probe so
        //    the empty snapshot row stays dimensionally valid; the probe vector
        //    is discarded, never stored.
        let (embedding_model, embedding_dimensions, vectors) =
            match (entries.is_empty(), previous.as_ref()) {
                (true, Some(previous_row)) => (
                    previous_row.embedding.model.clone(),
                    previous_row.embedding.dimensions,
                    Vec::new(),
                ),
                _ => {
                    let texts: Vec<String> = if entries.is_empty() {
                        vec![String::new()]
                    } else {
                        entries.iter().map(|entry| entry.entry.text.clone()).collect()
                    };
                    let mut embedding_body = json!({ "input": texts });
                    if let Some(model) = &embedding.model {
                        embedding_body["model"] = json!(model);
                    }
                    let embedding_response = post_json(
                        client,
                        &embedding.endpoint,
                        &embedding.token,
                        EMBEDDING_PATH,
                        embedding_body,
                        EMBEDDING_RESPONSE_LIMIT,
                    )
                    .await
                    .map_err(|_| "memory_compact_failed")?;
                    let parsed = parse_embedding_response(&embedding_response, texts.len())?;
                    if previous.as_ref().is_some_and(|row| {
                        row.embedding.model != parsed.model
                            || row.embedding.dimensions != parsed.dimensions
                    }) {
                        return fail("embedding_dimension_mismatch");
                    }
                    let vectors = if entries.is_empty() {
                        Vec::new()
                    } else {
                        parsed.vectors
                    };
                    (parsed.model, parsed.dimensions, vectors)
                }
            };
        if cancel.canceled() {
            return fail("cancelled");
        }

        // 7. Persist: one transaction replaces snapshot + vectors, clears the
        //    covered pending turns and records the requestID. The CAS bound at
        //    step 4 and the stale guard run inside the commit; the cancellation
        //    flag is checked again inside this storage-thread closure so a
        //    disconnect that fired after the provider responses can still stop
        //    the write before it starts.
        let next_watermark = self
            .live_state(&scope.world_id, &scope.resident_scope)
            .map(|(_, next, _)| next)
            .ok_or("memory_storage_failed")?;
        let operation = CompactCommit {
            world_id: scope.world_id.clone(),
            resident_scope: scope.resident_scope.clone(),
            request_id,
            expected: bound_expected,
            digest,
            processed_watermark,
            next_watermark,
            embedding: EmbeddingRef {
                model: embedding_model,
                dimensions: embedding_dimensions,
            },
            entries,
            vectors,
        };
        let buffers = self.buffers.clone();
        let (result, pending_turns) = self
            .db
            .call(move |store| {
                if cancel.canceled() {
                    return fail("cancelled");
                }
                let transaction = store
                    .connection
                    .transaction()
                    .map_err(|_| "storage_unavailable")?;
                let result = commit(&transaction, &operation)?;
                transaction.commit().map_err(|_| "storage_unavailable")?;
                let pending_turns = clear_covered(
                    &buffers,
                    &operation.world_id,
                    &operation.resident_scope,
                    result.processed_watermark,
                );
                Ok((result, pending_turns))
            })
            .await?;

        Ok(json!({
            "revision": result.revision,
            "vectorGeneration": result.vector_generation,
            "replayed": result.replayed,
            "processedWatermark": result.processed_watermark,
            "pendingTurns": pending_turns,
        }))
    }

    // -- memory_ingest (delivered-turn writes + background scheduling) ------

    /// `memory_ingest`: accept one already-delivered (user, agent) turn pair
    /// into the scope's volatile buffer, atomically. Raw text is never
    /// persisted; the durable layer only changes through a later
    /// consolidation. `(scope, requestID)` idempotency is volatile and bounded.
    #[allow(clippy::too_many_arguments)]
    pub async fn ingest(
        self: &Arc<Self>,
        client: &reqwest::Client,
        scope: Scope,
        request_id: &str,
        user_text: &str,
        agent_reply: &str,
        source: &str,
        observed_at: Option<String>,
    ) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let request_id = identity(request_id).map_err(|_| "invalid_memory_ingest")?;
        if source != "text" && source != "voice" {
            return fail("invalid_memory_ingest");
        }
        let observed_at = match observed_at {
            None => None,
            Some(value) => {
                let value = value.trim();
                if value.is_empty() {
                    None
                } else if value.chars().any(char::is_control)
                    || value.chars().count() > OBSERVED_AT_LIMIT
                {
                    return fail("invalid_memory_ingest");
                } else {
                    Some(value.to_owned())
                }
            }
        };
        for text in [user_text, agent_reply] {
            let text = text.trim();
            if text.is_empty() || text.chars().any(char::is_control) {
                return fail("invalid_turn_text");
            }
            if text.chars().count() > TURN_TEXT_LIMIT {
                return fail("turn_text_too_large");
            }
        }
        self.seed_buffer(&scope.world_id, &scope.resident_scope).await?;

        let digest = ingest_digest(user_text.trim(), agent_reply.trim(), source, &observed_at);
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();
        let key = (world_id.clone(), resident_scope.clone());

        // Critical section (no awaits below): the pair is appended atomically,
        // the idempotency receipt recorded and the orchestration decision taken
        // while holding the buffers lock, so a task abort (client disconnect)
        // can only land at the next await and can neither split the pair nor
        // lose the schedule between append and state transition.
        let (replayed, count, decision) = {
            let mut buffers = self.lock_buffers();
            let buffer = buffers
                .get_mut(&key)
                .ok_or("memory_storage_failed")?;
            if let Some((_, recorded_digest)) = buffer
                .receipts
                .iter()
                .find(|(id, _)| *id == request_id)
            {
                if *recorded_digest != digest {
                    return fail("memory_request_conflict");
                }
                // Idempotent replay adds nothing, but it still (re)arms the
                // background schedule: if the original response was lost to a
                // disconnect right after the append, the retry must not leave
                // the accepted turns sitting unscheduled forever.
                let count = buffer.turns.len();
                let configured = self.providers_configured();
                let decision = self
                    .orchestration
                    .turns_changed(&key, count, configured, &self.policy());
                (true, count, decision)
            } else {
                let user_watermark = buffer.next_watermark;
                buffer.turns.push_back(VolatileTurn {
                    turn_id: uuid::Uuid::new_v4().hyphenated().to_string(),
                    watermark: user_watermark,
                    role: "user".into(),
                    text: user_text.trim().to_owned(),
                    interrupted: false,
                });
                buffer.turns.push_back(VolatileTurn {
                    turn_id: uuid::Uuid::new_v4().hyphenated().to_string(),
                    watermark: user_watermark + 1,
                    role: "agent".into(),
                    text: agent_reply.trim().to_owned(),
                    interrupted: false,
                });
                buffer.next_watermark += 2;
                buffer.pairs.push_back(PairMeta {
                    user_watermark,
                    agent_reply: agent_reply.trim().to_owned(),
                    source: source.to_owned(),
                    observed_at: observed_at.clone(),
                });
                while buffer.pairs.len() > INGEST_PAIRS_LIMIT {
                    buffer.pairs.pop_front();
                }
                buffer.receipts.push_back((request_id, digest));
                while buffer.receipts.len() > INGEST_RECEIPTS_LIMIT {
                    buffer.receipts.pop_front();
                }
                while buffer.turns.len() > PENDING_TURNS_LIMIT {
                    buffer.turns.pop_front();
                }
                let count = buffer.turns.len();
                let configured = self.providers_configured();
                let decision = self
                    .orchestration
                    .turns_changed(&key, count, configured, &self.policy());
                (false, count, decision)
            }
        };
        let consolidation = {
            let key = (world_id.clone(), resident_scope.clone());
            match self.orchestration.report(&key) {
                Some((state, _)) => state,
                None => {
                    if self.providers_configured() {
                        "pending"
                    } else {
                        "unconfigured"
                    }
                }
            }
        };
        if let Some(decision) = decision {
            self.spawn_delayed(decision, &world_id, &resident_scope, client);
        }
        Ok(json!({
            "accepted": true,
            "replayed": replayed,
            "pendingTurns": count,
            "consolidation": consolidation,
        }))
    }

    // -- memory_recall (two-lane fused retrieval) ---------------------------

    pub async fn recall(
        &self,
        client: &reqwest::Client,
        scope: Scope,
        query_text: &str,
        fresh_session: bool,
        fact_limit: Option<usize>,
        note_limit: Option<usize>,
    ) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let query_text = query_text.trim();
        if query_text.is_empty() || query_text.chars().count() > QUERY_TEXT_LIMIT {
            return fail("invalid_query");
        }
        let fact_limit = fact_limit.unwrap_or(RECALL_FACT_LIMIT_DEFAULT);
        let note_limit = note_limit.unwrap_or(RECALL_NOTE_LIMIT_DEFAULT);
        if !(1..=RECALL_FACT_LIMIT_MAX).contains(&fact_limit)
            || !(1..=RECALL_NOTE_LIMIT_MAX).contains(&note_limit)
        {
            return fail("invalid_topk");
        }
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();
        let key = (world_id.clone(), resident_scope.clone());

        let (pending_turns, pending) = match self.live_state(&world_id, &resident_scope) {
            Some((turns, _, count)) => (count, turns),
            None => (0, Vec::new()),
        };
        let _ = &key;

        let embedding = {
            let providers = self.providers.read().await;
            providers.embedding.clone()
        };

        // One snapshot read used both to decide availability and (before the
        // async embedding) to capture the generation's model/dimensions.
        let row = self
            .db
            .call({
                let world_id = world_id.clone();
                let resident_scope = resident_scope.clone();
                move |store| stored_row(&store.connection, &world_id, &resident_scope)
            })
            .await?;
        let Some(row) = row else {
            // No snapshot: nothing semantic to search and nothing confirmed to
            // restore. revision/vectorGeneration stay 0.
            let status = "unconfigured";
            let context = build_recall_context(
                fresh_session,
                status,
                &[],
                &[],
                None,
                &pending,
                0,
                0,
            );
            return Ok(json!({
                "status": status,
                "revision": 0,
                "vectorGeneration": 0,
                "facts": [],
                "notes": [],
                "context": context,
                "pendingTurns": pending_turns,
            }));
        };
        let Some(embedding) = embedding else {
            // Embedding missing: facts/notes stay empty with an explicit
            // unconfigured status; a fresh session may still restore the
            // confirmed local snapshot/pending (that is not a semantic claim).
            let context = build_recall_context(
                fresh_session,
                "unconfigured",
                &[],
                &[],
                Some(&row.sections),
                &pending,
                row.revision,
                row.vector_generation,
            );
            return Ok(json!({
                "status": "unconfigured",
                "revision": row.revision,
                "vectorGeneration": row.vector_generation,
                "facts": [],
                "notes": [],
                "context": context,
                "pendingTurns": pending_turns,
            }));
        };

        // One query embedding shared by both lanes.
        let captured_model = row.embedding.model.clone();
        let mut body = json!({ "input": [query_text] });
        if let Some(model) = &embedding.model {
            body["model"] = json!(model);
        }
        let response = post_json(
            client,
            &embedding.endpoint,
            &embedding.token,
            EMBEDDING_PATH,
            body,
            EMBEDDING_RESPONSE_LIMIT,
        )
        .await?;
        let parsed = parse_embedding_response(&response, 1)?;
        if parsed.model != captured_model || parsed.dimensions != row.embedding.dimensions {
            return fail("embedding_dimension_mismatch");
        }
        let query_vector = parsed
            .vectors
            .into_iter()
            .next()
            .ok_or("embedding_rejected")?;
        let expected_model = parsed.model.clone();

        // Same-generation barrier: both lanes search the current generation in
        // one storage-thread call with the model/dimensions re-checked, so the
        // returned rows always share one generation and embedding space.
        let search = self
            .db
            .call({
                let world_id = world_id.clone();
                let resident_scope = resident_scope.clone();
                let query_vector = query_vector.clone();
                move |store| {
                    let current = stored_row(&store.connection, &world_id, &resident_scope)?;
                    let Some(current) = current else {
                        return Ok(json!({
                            "facts": Vec::<Value>::new(),
                            "notes": Vec::<Value>::new(),
                            "revision": 0,
                            "vectorGeneration": 0,
                            "sections": Value::Null,
                        }));
                    };
                    if current.embedding.model != expected_model
                        || current.embedding.dimensions != query_vector.len()
                    {
                        return fail("embedding_dimension_mismatch");
                    }
                    let facts = search_lane(
                        &store.connection,
                        &world_id,
                        &resident_scope,
                        "facts",
                        &query_vector,
                        fact_limit,
                    )?;
                    let notes = search_lane(
                        &store.connection,
                        &world_id,
                        &resident_scope,
                        "notes",
                        &query_vector,
                        note_limit,
                    )?;
                    let sections = serde_json::to_value(&current.sections)
                        .map_err(|_| "memory_history_unavailable")?;
                    Ok(json!({
                        "facts": facts,
                        "notes": notes,
                        "revision": current.revision,
                        "vectorGeneration": current.vector_generation,
                        "sections": sections,
                    }))
                }
            })
            .await?;
        let facts = search["facts"].as_array().cloned().unwrap_or_default();
        let notes = search["notes"].as_array().cloned().unwrap_or_default();
        let revision = search["revision"].as_i64().unwrap_or(0);
        let vector_generation = search["vectorGeneration"].as_i64().unwrap_or(0);
        let sections: Option<Sections> = if search["sections"].is_null() {
            None
        } else {
            serde_json::from_value(search["sections"].clone())
                .map_err(|_| "memory_history_unavailable")?
        };
        let status = if facts.is_empty() && notes.is_empty() { "empty" } else { "ok" };
        let context = build_recall_context(
            fresh_session,
            status,
            &facts,
            &notes,
            sections.as_ref(),
            &pending,
            revision,
            vector_generation,
        );
        Ok(json!({
            "status": status,
            "revision": revision,
            "vectorGeneration": vector_generation,
            "facts": facts,
            "notes": notes,
            "context": context,
            "pendingTurns": pending_turns,
        }))
    }

    // -- background + explicit consolidation orchestration ------------------

    /// Explicit `memory_compact` keeps its disconnect-cancellation semantics
    /// (request-bound `Cancellation`); afterwards the orchestration registry is
    /// refreshed so a scheduled background run does not redundantly fire on
    /// turns an explicit compact already consumed.
    pub async fn compact_explicit(
        self: &Arc<Self>,
        client: &reqwest::Client,
        scope: Scope,
        request_id: &str,
        expected: Option<i64>,
        cancel: Cancellation,
    ) -> Result<Value> {
        let result = self
            .compact(client, scope.clone(), request_id, expected, cancel)
            .await;
        if result.is_ok() {
            let key = (scope.world_id.clone(), scope.resident_scope.clone());
            let count = self
                .live_state(&scope.world_id, &scope.resident_scope)
                .map(|(_, _, count)| count)
                .unwrap_or(0);
            let configured = self.providers_configured();
            let decision = self
                .orchestration
                .turns_changed(&key, count, configured, &self.policy());
            if let Some(decision) = decision {
                self.spawn_delayed(decision, &scope.world_id, &scope.resident_scope, client);
            }
        }
        result
    }

    /// Sleep `decision.delay`, then run one background consolidation for the
    /// scope. The task is fully detached from any client connection: accepted,
    /// delivered turns consolidate even after the short IPC connection closes.
    fn spawn_delayed(
        self: &Arc<Self>,
        decision: orchestration::Decision,
        world_id: &str,
        resident_scope: &str,
        client: &reqwest::Client,
    ) {
        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            // Outside a runtime nothing can sleep; the registry stays Pending
            // and a later ingest/refresh reschedules.
            return;
        };
        let this = self.clone();
        let client = client.clone();
        let world_id = world_id.to_owned();
        let resident_scope = resident_scope.to_owned();
        handle.spawn(async move {
            tokio::time::sleep(decision.delay).await;
            this.background_consolidation(client, world_id, resident_scope, decision.generation)
                .await;
        });
    }

    /// One background consolidation attempt. At most one runs per scope (the
    /// registry `claim`); failures keep pending turns and surface through
    /// `memory_status.orchestration`. `memory_conflict` means a concurrent
    /// writer (explicit compact) already committed the base: its durable state
    /// won, so we re-evaluate whatever pending turns remain.
    async fn background_consolidation(
        self: Arc<Self>,
        client: reqwest::Client,
        world_id: String,
        resident_scope: String,
        generation: u64,
    ) {
        let key = (world_id.clone(), resident_scope.clone());
        if !self.orchestration.claim(&key, generation) {
            return;
        }
        let scope = Scope {
            world_id: world_id.clone(),
            resident_scope: resident_scope.clone(),
        };
        let request_id = uuid::Uuid::new_v4().hyphenated().to_string();
        let outcome = match self
            .compact(&client, scope.clone(), &request_id, None, Cancellation::new())
            .await
        {
            Ok(_) => OrchOutcome::Committed,
            Err(code) => match code {
                "compaction_unavailable" | "embedding_unavailable" => OrchOutcome::Unavailable,
                "memory_conflict" => OrchOutcome::Committed,
                other => OrchOutcome::Failed(other),
            },
        };
        // Settle under the buffers lock so a concurrently appended turn is
        // counted before the state transition (no lost schedule).
        let buffers = self.lock_buffers();
        let count = buffers
            .get(&key)
            .map(|buffer| buffer.turns.len())
            .unwrap_or(0);
        let configured = self.providers_configured();
        let decision = self
            .orchestration
            .settle(&key, outcome, count, configured, &self.policy());
        drop(buffers);
        if let Some(decision) = decision {
            self.spawn_delayed(decision, &world_id, &resident_scope, &client);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Database;
    use serde_json::{json, Value};
    use std::io::{Read, Write};
    use std::sync::{Arc, Mutex as StdMutex};
    use std::time::Duration;

    const WORLD_A: &str = "world-a";
    const WORLD_B: &str = "world-b";
    const RESIDENT_A: &str = "resident-a";
    const RESIDENT_B: &str = "resident-b";
    const MODEL: &str = "fixture-model-1";
    const MODEL_COMP: &str = "fixture-compaction-model-1";
    const TOKEN: &str = "fixture-memory-token-do-not-persist";

    fn scope(world: &str, resident: &str) -> Scope {
        Scope {
            world_id: world.into(),
            resident_scope: resident.into(),
        }
    }

    fn scope_a() -> Scope {
        scope(WORLD_A, RESIDENT_A)
    }

    fn temp_db(prefix: &str) -> (std::path::PathBuf, Database) {
        let dir = std::env::temp_dir().join(format!("gmgn-memory-{prefix}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let database = Database::open(dir.clone(), None).unwrap();
        (dir, database)
    }

    fn entry(category: &str, text: &str) -> Entry {
        Entry {
            id: uuid::Uuid::new_v4().hyphenated().to_string(),
            category: category.into(),
            text: text.into(),
            observed_at: None,
            grounding: None,
        }
    }

    fn fact_entry(text: &str) -> VecEntry {
        VecEntry {
            section: "facts",
            entry: entry("fact", text),
        }
    }

    fn embeddings(model: &str, texts: &[String]) -> EmbeddingResult {
        let mut vectors = Vec::new();
        for (index, text) in texts.iter().enumerate() {
            // Deterministic 4-dim unit vector: one-hot by text index so
            // identical texts are identical and distinct texts differ; the
            // first coordinate is always non-zero (never an all-zero vector).
            let mut v = vec![0.0_f32; 4];
            v[0] = 0.25;
            v[(index + 1) % 4] = 1.0;
            let _ = text;
            vectors.push(v);
        }
        EmbeddingResult {
            model: model.into(),
            dimensions: 4,
            vectors,
        }
    }

    /// OpenAI-compatible `/v1/embeddings` response for a stub embedding result.
    fn embeddings_response(result: &EmbeddingResult) -> Value {
        let data: Vec<Value> = result
            .vectors
            .iter()
            .enumerate()
            .map(|(index, vector)| {
                json!({
                    "object": "embedding",
                    "index": index,
                    "embedding": vector,
                })
            })
            .collect();
        json!({
            "object": "list",
            "data": data,
            "model": result.model,
        })
    }

    /// OpenAI-compatible `/v1/chat/completions` response whose assistant
    /// content is the frozen compaction envelope JSON.
    fn chat_response(model: &str, envelope: Value) -> Value {
        let content = serde_json::to_string(&envelope).unwrap_or_else(|_| "{}".into());
        json!({
            "id": "chatcmpl-fixture",
            "object": "chat.completion",
            "model": model,
            "choices": [{
                "index": 0,
                "message": { "role": "assistant", "content": content },
                "finish_reason": "stop",
            }],
        })
    }

    /// Pull the compaction request's user content (previous snapshot + turns +
    /// limits JSON) out of an OpenAI-compatible chat request body.
    fn chat_user_data(body: &Value) -> Option<Value> {
        let messages = body.get("messages").and_then(Value::as_array)?;
        let user = messages.iter().find(|message| {
            message.get("role").and_then(Value::as_str) == Some("user")
        })?;
        let content = user.get("content").and_then(Value::as_str)?;
        serde_json::from_str(content).ok()
    }

    fn commit_once(
        connection: &mut Connection,
        scope: &Scope,
        request_id: &str,
        entries: Vec<VecEntry>,
        processed: i64,
    ) -> Result<CompactResult> {
        let vectors: Vec<Vec<f32>> = entries
            .iter()
            .enumerate()
            .map(|(index, _)| {
                let mut v = vec![0.0_f32; 4];
                v[index % 4] = 1.0;
                v
            })
            .collect();
        let operation = CompactCommit {
            world_id: scope.world_id.clone(),
            resident_scope: scope.resident_scope.clone(),
            request_id: request_id.into(),
            expected: None,
            digest: "expected:none".into(),
            processed_watermark: processed,
            next_watermark: processed + 1,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 4,
            },
            entries,
            vectors,
        };
        let transaction = connection.transaction().unwrap();
        let result = commit(&transaction, &operation)?;
        transaction.commit().map_err(|_| "storage_unavailable")?;
        Ok(result)
    }

    fn envelope(facts: Value, notes: Value, removed: Value) -> Value {
        json!({ "facts": facts, "notes": notes, "removed": removed })
    }

    // -- minimal loopback HTTP fixture -------------------------------------

    /// A real TCP loopback fixture for the provider wire (no hyper, no third
    /// party). One accept thread owns a listener clone; each accepted
    /// connection is served on its own tracked thread. `Drop` reliably stops
    /// the accept loop (stop flag + one wake-up connect, then join) and joins
    /// every per-connection thread, so cargo test never hangs on a fixture.
    struct Fixture {
        endpoint: String,
        addr: std::net::SocketAddr,
        stop: Arc<AtomicBool>,
        listener: Option<std::net::TcpListener>,
        accept: Option<std::thread::JoinHandle<()>>,
        connections: Arc<StdMutex<Vec<std::thread::JoinHandle<()>>>>,
    }

    type Handler = Arc<dyn Fn(&str, &Value) -> (u16, Value) + Send + Sync>;

    fn fixture(handler: Handler) -> Fixture {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let endpoint = format!("http://127.0.0.1:{}", addr.port());
        let stop = Arc::new(AtomicBool::new(false));
        let accept_stop = stop.clone();
        let connections: Arc<StdMutex<Vec<std::thread::JoinHandle<()>>>> =
            Arc::new(StdMutex::new(Vec::new()));
        let accept_connections = connections.clone();
        let shared = listener.try_clone().unwrap();
        let accept = std::thread::Builder::new()
            .name("fixture-accept".into())
            .spawn(move || {
                for stream in shared.incoming() {
                    if accept_stop.load(Ordering::Acquire) {
                        break;
                    }
                    let Ok(mut stream) = stream else {
                        if accept_stop.load(Ordering::Acquire) {
                            break;
                        }
                        continue;
                    };
                    let handler = handler.clone();
                    let spawn = std::thread::Builder::new().name("fixture-conn".into());
                    let Ok(handle) = spawn.spawn(move || {
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
                        let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));
                        let mut data = Vec::new();
                        let mut buffer = [0u8; 4096];
                        let header_end = loop {
                            match stream.read(&mut buffer) {
                                Ok(0) => break None,
                                Ok(read) => {
                                    data.extend_from_slice(&buffer[..read]);
                                    if let Some(position) = find_header_end(&data) {
                                        break Some(position);
                                    }
                                }
                                Err(_) => break None,
                            }
                        };
                        let (status, response) = match header_end {
                            Some(header_end) => {
                                let length = content_length(&data[..header_end]);
                                while data.len() < header_end + length {
                                    let mut more = [0u8; 4096];
                                    match stream.read(&mut more) {
                                        Ok(0) => break,
                                        Ok(read) => data.extend_from_slice(&more[..read]),
                                        Err(_) => break,
                                    }
                                }
                                let text = String::from_utf8_lossy(&data);
                                let path = text
                                    .split_whitespace()
                                    .nth(1)
                                    .unwrap_or("/")
                                    .to_owned();
                                let body: Value =
                                    serde_json::from_str(text[header_end..].trim())
                                        .unwrap_or(Value::Null);
                                handler(&path, &body)
                            }
                            None => (400, json!({"error": "malformed request"})),
                        };
                        let payload = serde_json::to_vec(&response).unwrap_or_else(|_| b"{}".to_vec());
                        let head = format!(
                            "HTTP/1.1 {status} OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                            payload.len()
                        );
                        let _ = stream.write_all(head.as_bytes());
                        let _ = stream.write_all(&payload);
                        let _ = stream.shutdown(std::net::Shutdown::Write);
                    }) else {
                        continue;
                    };
                    let _ = accept_connections.lock().map(|mut all| all.push(handle));
                }
            })
            .unwrap();
        Fixture {
            endpoint,
            addr,
            stop,
            listener: Some(listener),
            accept: Some(accept),
            connections,
        }
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            // 1. Ask the accept loop to stop and close our listener copy.
            self.stop.store(true, Ordering::Release);
            self.listener.take();
            // 2. Wake a pending accept() on the accept thread's listener clone
            //    (the connect succeeds while that clone is still open); the
            //    loop observes the stop flag and exits. If the loop already
            //    exited the connect simply fails or hits nothing.
            let _ = std::net::TcpStream::connect_timeout(
                &self.addr,
                Duration::from_millis(250),
            );
            if let Some(accept) = self.accept.take() {
                let _ = accept.join();
            }
            // 3. Join every per-connection handler thread. Each handler has a
            //    bounded read/write timeout and never waits on shared state
            //    that outlives the test, so these joins terminate. A handler
            //    still blocked on an explicit test gate is released when the
            //    test's release sender drops during unwinding.
            let connections = std::mem::take(&mut *self
                .connections
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner()));
            for handle in connections {
                let _ = handle.join();
            }
        }
    }

    fn find_header_end(data: &[u8]) -> Option<usize> {
        data.windows(4)
            .position(|window| window == b"\r\n\r\n")
            .map(|position| position + 4)
    }

    fn content_length(head: &[u8]) -> usize {
        let text = String::from_utf8_lossy(head);
        for line in text.lines() {
            if let Some(value) = line.to_ascii_lowercase().strip_prefix("content-length:") {
                return value.trim().parse().unwrap_or(0);
            }
        }
        0
    }


    fn client() -> reqwest::Client {
        crate::provider::client().unwrap()
    }

    /// A provider pair whose compaction fixture (an OpenAI-compatible
    /// `/v1/chat/completions` endpoint) echoes its captured turns into facts
    /// and whose embedding fixture (`/v1/embeddings`) returns the stub
    /// vectors. Records every request body for assertions; refuses requests
    /// that do not carry the configured compaction model or the frozen system
    /// rules, so tests prove the real model/rules are actually sent.
    fn provider_pair(
        compaction_body: Option<Arc<StdMutex<Vec<Value>>>>,
        embedding_body: Option<Arc<StdMutex<Vec<Value>>>>,
        fail_compaction: bool,
        fail_embedding: bool,
        note_categories: bool,
    ) -> (Fixture, Fixture) {
        let compaction_calls = Arc::new(StdMutex::new(0usize));
        let compaction = fixture(Arc::new(move |path, body| {
            if path != crate::memory::COMPACTION_PATH {
                return (404, json!({}));
            }
            let _ = compaction_calls.lock().map(|mut c| *c += 1);
            if let Some(log) = &compaction_body {
                let _ = log.lock().map(|mut b| b.push(body.clone()));
            }
            if fail_compaction {
                return (500, json!({"error": "boom"}));
            }
            let model = body["model"].as_str().unwrap_or("");
            if model != MODEL_COMP {
                return (400, json!({"error": "model not sent"}));
            }
            let system = body["messages"]
                .as_array()
                .and_then(|messages| {
                    messages.iter().find(|message| {
                        message.get("role").and_then(Value::as_str) == Some("system")
                    })
                })
                .and_then(|message| message.get("content"))
                .and_then(Value::as_str)
                .unwrap_or("");
            if system != crate::memory::COMPACTION_RULES {
                return (400, json!({"error": "rules not sent"}));
            }
            let Some(user) = chat_user_data(body) else {
                return (400, json!({"error": "user data not sent"}));
            };
            let turns = user["turns"].as_array().cloned().unwrap_or_default();
            let previous = user["previous"].clone();
            let mut facts = Vec::new();
            for turn in &turns {
                let text = format!("remembered:{}", turn["text"].as_str().unwrap_or(""));
                facts.push(json!({
                    "category": "fact",
                    "text": text,
                    "observedAt": "2026-09-08",
                    "grounding": format!("turn:{}", turn["watermark"])
                }));
            }
            // Carry previous entries forward unless this fixture removes them.
            let removed: Vec<Value> = Vec::new();
            let previous_facts = previous
                .get("sections")
                .and_then(|s| s.get("facts"))
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            for old in previous_facts {
                facts.push(json!({
                    "category": "fact",
                    "text": old["text"],
                    "observedAt": old.get("observedAt").cloned().unwrap_or(Value::Null),
                    "grounding": old.get("grounding").cloned().unwrap_or(Value::Null),
                }));
            }
            let mut notes = Vec::new();
            if note_categories {
                for turn in &turns {
                    notes.push(json!({
                        "category": "experience",
                        "text": format!("noted:{}", turn["text"].as_str().unwrap_or("")),
                        "observedAt": "2026-09-08",
                        "grounding": format!("turn:{}", turn["watermark"])
                    }));
                }
            }
            (
                200,
                chat_response(model, envelope(json!(facts), json!(notes), json!(removed))),
            )
        }));
        let embedding = fixture(Arc::new(move |path, body| {
            if path != crate::memory::EMBEDDING_PATH {
                return (404, json!({}));
            }
            if let Some(log) = &embedding_body {
                let _ = log.lock().map(|mut b| b.push(body.clone()));
            }
            if fail_embedding {
                return (500, json!({"error": "boom"}));
            }
            let texts: Vec<String> = body["input"]
                .as_array()
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            let result = embeddings(MODEL, &texts);
            (200, embeddings_response(&result))
        }));
        (compaction, embedding)
    }

    async fn configure_pair(memory: &Memory, compaction: &Fixture, embedding: &Fixture) {
        memory
            .configure("compaction", &compaction.endpoint, TOKEN, Some(MODEL_COMP.into()))
            .await
            .unwrap();
        memory
            .configure("embedding", &embedding.endpoint, TOKEN, Some(MODEL.into()))
            .await
            .unwrap();
    }

    // -- storage/commit/search unit tests ----------------------------------

    #[test]
    fn schema_is_idempotent_and_creates_all_memory_tables() {
        register_vec();
        let connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        schema(&connection).unwrap();
        let names: Vec<String> = connection
            .prepare(
                "SELECT name FROM sqlite_master
                 WHERE type='table' AND name LIKE 'memory\\_%' ESCAPE '\\'
                 ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(names, vec!["memory_requests", "memory_snapshots", "memory_vec_rows"]);
    }

    #[test]
    fn commit_creates_generation_one_and_reads_back_full_snapshot() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        let request_id = uuid::Uuid::new_v4().to_string();
        let mut facts = vec![fact_entry("resident prefers espresso over drip")];
        facts.push(VecEntry {
            section: "facts",
            entry: {
                let mut preference = entry("preference", "sunrise walks before 9am");
                preference.grounding = Some("turn:2".into());
                preference.observed_at = Some("2026-09-08".into());
                preference
            },
        });
        let result = commit_once(&mut connection, &scope_a(), &request_id, facts, 2).unwrap();
        assert_eq!(
            result,
            CompactResult {
                revision: 1,
                vector_generation: 1,
                processed_watermark: 2,
                replayed: false
            }
        );
        let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
        assert_eq!(row.revision, 1);
        assert_eq!(row.vector_generation, 1);
        assert_eq!(row.next_watermark, 3);
        assert_eq!(row.sections.facts.len(), 2);
        assert!(row.sections.notes.is_empty());
        assert_eq!(row.embedding.model, MODEL);
        assert_eq!(row.embedding.dimensions, 4);
        let snapshot = snapshot_value(&row).unwrap();
        assert_eq!(snapshot["schemaVersion"], 1);
        assert_eq!(snapshot["revision"], 1);
        assert_eq!(snapshot["processedWatermark"], 2);
        assert_eq!(snapshot["nextWatermark"], 3);
        assert_eq!(snapshot["sections"]["facts"][0]["text"], "resident prefers espresso over drip");
        assert_eq!(snapshot["sections"]["facts"][0]["category"], "fact");
        assert_eq!(snapshot["sections"]["facts"][1]["observedAt"], "2026-09-08");
        assert_eq!(snapshot["sections"]["facts"][1]["grounding"], "turn:2");
        // Grounding-optional facts serialize without the key.
        assert!(snapshot["sections"]["facts"][0].get("grounding").is_none());
    }

    #[test]
    fn second_commit_replaces_generation_and_old_vectors_are_gone() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        let first_id = uuid::Uuid::new_v4().to_string();
        commit_once(
            &mut connection,
            &scope_a(),
            &first_id,
            vec![fact_entry("old memory that gets removed")],
            1,
        )
        .unwrap();
        let second_id = uuid::Uuid::new_v4().to_string();
        let result = commit_once(
            &mut connection,
            &scope_a(),
            &second_id,
            vec![fact_entry("current memory")],
            2,
        )
        .unwrap();
        assert_eq!(result.vector_generation, 2);
        assert_eq!(result.revision, 2);
        let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
        assert_eq!(row.vector_generation, 2);
        assert_eq!(row.sections.facts[0].text, "current memory");
        let hits = search(&connection, WORLD_A, RESIDENT_A, &[0.0, 1.0, 0.0, 0.0], 10).unwrap();
        assert_eq!(hits.len(), 1, "old-generation rows must not survive a commit");
        assert_eq!(hits[0]["text"], "current memory");
        // The second commit consumed watermark 2, and next resumed at 3.
        assert_eq!(durable_watermark(&connection, WORLD_A, RESIDENT_A).unwrap(), 3);
    }

    #[test]
    fn cosine_ranking_is_scoped_and_limited_before_top_k() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        // Scope A: query-near and query-far rows.
        let entries_a = vec![fact_entry("near"), fact_entry("far")];
        let vectors_a = vec![vec![0.99, 0.01, 0.0, 0.0], vec![0.0, 0.0, 0.99, 0.0]];
        let operation = CompactCommit {
            world_id: WORLD_A.into(),
            resident_scope: RESIDENT_A.into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            expected: None,
            digest: "expected:none".into(),
            processed_watermark: 2,
            next_watermark: 3,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 4,
            },
            entries: entries_a,
            vectors: vectors_a,
        };
        {
            let tx = connection.transaction().unwrap();
            commit(&tx, &operation).unwrap();
            tx.commit().unwrap();
        }
        // Scope B has a vector that is even closer to the query: it must never
        // leak into scope A's results.
        let operation_b = CompactCommit {
            world_id: WORLD_B.into(),
            resident_scope: RESIDENT_B.into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            expected: None,
            digest: "expected:none".into(),
            processed_watermark: 1,
            next_watermark: 2,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 4,
            },
            entries: vec![fact_entry("intruder")],
            vectors: vec![vec![1.0, 0.0, 0.0, 0.0]],
        };
        {
            let tx = connection.transaction().unwrap();
            commit(&tx, &operation_b).unwrap();
            tx.commit().unwrap();
        }
        let hits = search(&connection, WORLD_A, RESIDENT_A, &[1.0, 0.0, 0.0, 0.0], 8).unwrap();
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0]["text"], "near");
        assert!(hits[0]["distance"].as_f64().unwrap() < hits[1]["distance"].as_f64().unwrap());
        let capped = search(&connection, WORLD_A, RESIDENT_A, &[1.0, 0.0, 0.0, 0.0], 1).unwrap();
        assert_eq!(capped.len(), 1);
        assert_eq!(capped[0]["text"], "near");
        // Other scope still has its own hit, structurally isolated.
        let foreign = search(&connection, WORLD_B, RESIDENT_B, &[1.0, 0.0, 0.0, 0.0], 8).unwrap();
        assert_eq!(foreign.len(), 1);
        assert_eq!(foreign[0]["text"], "intruder");
    }

    #[test]
    fn dimension_mismatch_and_invalid_vectors_are_rejected() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        commit_once(
            &mut connection,
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("dimension keeper")],
            1,
        )
        .unwrap();
        // Query with a different dimension must never be truncated/padded.
        let wrong = search(&connection, WORLD_A, RESIDENT_A, &[1.0, 0.0], 8);
        assert_eq!(wrong.unwrap_err(), "embedding_dimension_mismatch");
        // Commit validation rejects an out-of-range dimension.
        let operation = CompactCommit {
            world_id: WORLD_A.into(),
            resident_scope: RESIDENT_B.into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            expected: None,
            digest: "expected:none".into(),
            processed_watermark: 1,
            next_watermark: 2,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: EMBEDDING_DIM_LIMIT + 1,
            },
            entries: vec![fact_entry("too wide")],
            vectors: vec![vec![0.0; EMBEDDING_DIM_LIMIT + 1]],
        };
        let tx = connection.transaction().unwrap();
        assert_eq!(commit(&tx, &operation).unwrap_err(), "invalid_vector");
        drop(tx);
        // Embedding responses that break the OpenAI wire (missing/invalid
        // data index, no model, NaN, all-zero vectors, count mismatch) are
        // rejected by deterministic validation.
        let openai = |data: Vec<Value>| json!({ "object": "list", "data": data, "model": MODEL });
        assert_eq!(
            parse_embedding_response(&json!({"model": MODEL, "data": []}), 1).unwrap_err(),
            "embedding_rejected"
        );
        assert_eq!(
            parse_embedding_response(
                &json!({"data": [{"object": "embedding", "index": 0, "embedding": [1.0, 0.0]}]}),
                1
            )
            .unwrap_err(),
            "embedding_rejected",
            "a response without a model is rejected"
        );
        assert_eq!(
            parse_embedding_response(
                &openai(vec![json!({"object": "embedding", "index": 1, "embedding": [1.0, 0.0]})]),
                1
            )
            .unwrap_err(),
            "embedding_rejected",
            "data index must equal the array position"
        );
        assert_eq!(
            parse_embedding_response(
                &openai(vec![json!({"object": "embedding", "index": 0,
                                     "embedding": ["x", 1.0]})]),
                1
            )
            .unwrap_err(),
            "invalid_vector"
        );
        assert_eq!(
            parse_embedding_response(
                &openai(vec![json!({"object": "embedding", "index": 0,
                                     "embedding": [1.0, 0.0]}),
                             json!({"object": "embedding", "index": 1,
                                    "embedding": [0.0, 1.0]})]),
                1
            )
            .unwrap_err(),
            "embedding_rejected",
            "count must match the requested batch"
        );
        assert_eq!(
            parse_embedding_response(
                &openai(vec![json!({"object": "embedding", "index": 0,
                                     "embedding": [0.0, 0.0]})]),
                1
            )
            .unwrap_err(),
            "invalid_vector",
            "an all-zero vector carries no cosine direction"
        );
        assert_eq!(
            parse_embedding_response(
                &openai(vec![json!({"object": "embedding", "index": 0,
                                     "embedding": [f64::NAN, 1.0]})]),
                1
            )
            .unwrap_err(),
            "invalid_vector"
        );
        assert_eq!(
            parse_embedding_response(
                &openai(vec![json!({"object": "embedding", "index": 0,
                                     "embedding": [1.0, 0.0]}),
                             json!({"object": "embedding", "index": 1,
                                    "embedding": [1.0, 0.0, 0.0]})]),
                2
            )
            .unwrap_err(),
            "embedding_rejected",
            "all vectors must share one dimension"
        );
        assert_eq!(
            parse_embedding_response(
                &openai(vec![json!({"object": "embedding", "index": 0,
                                     "embedding": [1.0, 0.0]}),
                             json!({"object": "embedding", "index": 1,
                                    "embedding": [2.0, 0.0],
                                    "model": "other-model"})]),
                2
            )
            .unwrap_err(),
            "embedding_rejected",
            "a per-item model that differs from the response model is rejected"
        );
        // A valid OpenAI response parses with its top-level model and per-item
        // embedding dimension.
        let parsed = parse_embedding_response(
            &openai(vec![json!({"object": "embedding", "index": 0,
                                 "embedding": [1.0, 0.0, 0.0, 0.0]}),
                         json!({"object": "embedding", "index": 1,
                                "embedding": [0.0, 1.0, 0.0, 0.0]})]),
            2,
        )
        .unwrap();
        assert_eq!(parsed.model, MODEL);
        assert_eq!(parsed.dimensions, 4);
        assert_eq!(parsed.vectors.len(), 2);
    }

    #[test]
    fn chat_completion_content_parses_envelope_and_echoes_model() {
        // A valid chat response whose content is the frozen envelope parses.
        let envelope = envelope(
            json!([{"category": "fact", "text": "kept"}]),
            json!([]),
            json!([]),
        );
        let response = chat_response(MODEL_COMP, envelope.clone());
        let parsed = compaction_chat_envelope(&response, MODEL_COMP).unwrap();
        assert_eq!(parsed, envelope);
        // Fenced content (```json ... ```) is tolerated.
        let mut fenced = chat_response(MODEL_COMP, envelope.clone());
        let content = fenced["choices"][0]["message"]["content"].as_str().unwrap().to_owned();
        fenced["choices"][0]["message"]["content"] =
            json!(format!("```json\n{content}\n```"));
        assert_eq!(compaction_chat_envelope(&fenced, MODEL_COMP).unwrap(), envelope);
        // A model echo mismatch, missing choices, non-JSON content, or an
        // object-less content all reject deterministically.
        let wrong_model = chat_response("someone-else", envelope.clone());
        assert_eq!(
            compaction_chat_envelope(&wrong_model, MODEL_COMP).unwrap_err(),
            "compaction_rejected"
        );
        assert_eq!(
            compaction_chat_envelope(&json!({"model": MODEL_COMP, "choices": []}), MODEL_COMP)
                .unwrap_err(),
            "compaction_rejected"
        );
        let mut prose = chat_response(MODEL_COMP, json!({}));
        prose["choices"][0]["message"]["content"] = json!("plain prose, not json");
        assert_eq!(
            compaction_chat_envelope(&prose, MODEL_COMP).unwrap_err(),
            "compaction_rejected"
        );
        let mut array = chat_response(MODEL_COMP, json!({}));
        array["choices"][0]["message"]["content"] = json!("[1, 2, 3]");
        assert_eq!(
            compaction_chat_envelope(&array, MODEL_COMP).unwrap_err(),
            "compaction_rejected",
            "content must be a JSON object, not an array"
        );
        let mut missing = chat_response(MODEL_COMP, envelope);
        missing["choices"][0]["message"]["content"] = json!("here are the facts: ...");
        assert_eq!(
            compaction_chat_envelope(&missing, MODEL_COMP).unwrap_err(),
            "compaction_rejected"
        );
    }

    #[test]
    fn stale_generation_cas_and_stale_processed_commit_are_conflicts() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        commit_once(
            &mut connection,
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("first")],
            1,
        )
        .unwrap();
        // A new scope with expected != 0 conflicts (current generation is 0).
        let fresh = CompactCommit {
            world_id: WORLD_B.into(),
            resident_scope: RESIDENT_A.into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            expected: Some(1),
            digest: "expected:1".into(),
            processed_watermark: 1,
            next_watermark: 2,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 4,
            },
            entries: vec![fact_entry("conflict")],
            vectors: vec![vec![0.0, 0.0, 0.0, 0.0]],
        };
        {
            let tx = connection.transaction().unwrap();
            assert_eq!(commit(&tx, &fresh).unwrap_err(), "memory_conflict");
            drop(tx);
        }
        // Stale expectedVectorGeneration on an existing generation-1 scope.
        for expected in [Some(0_i64), Some(2_i64)] {
            let stale = CompactCommit {
                world_id: WORLD_A.into(),
                resident_scope: RESIDENT_A.into(),
                request_id: uuid::Uuid::new_v4().to_string(),
                expected,
                digest: format!("expected:{}", expected.unwrap()),
                processed_watermark: 2,
                next_watermark: 3,
                embedding: EmbeddingRef {
                    model: MODEL.into(),
                    dimensions: 4,
                },
                entries: vec![fact_entry("stale")],
                vectors: vec![vec![0.0, 0.0, 0.0, 0.0]],
            };
            let tx = connection.transaction().unwrap();
            assert_eq!(commit(&tx, &stale).unwrap_err(), "memory_conflict");
            drop(tx);
        }
        // A late compaction whose turns were already processed must conflict
        // even without expectedVectorGeneration (double-processing guard).
        let late = CompactCommit {
            world_id: WORLD_A.into(),
            resident_scope: RESIDENT_A.into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            expected: None,
            digest: "expected:none".into(),
            processed_watermark: 1,
            next_watermark: 2,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 4,
            },
            entries: vec![fact_entry("duplicate")],
            vectors: vec![vec![0.0, 0.0, 0.0, 0.0]],
        };
        {
            let tx = connection.transaction().unwrap();
            assert_eq!(commit(&tx, &late).unwrap_err(), "memory_conflict");
            drop(tx);
        }
        // Nothing was changed by the losers.
        let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
        assert_eq!(row.revision, 1);
        assert_eq!(row.vector_generation, 1);
        assert_eq!(row.sections.facts[0].text, "first");
    }

    #[test]
    fn model_dimension_drift_across_commits_is_a_mismatch() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        commit_once(
            &mut connection,
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("first model")],
            1,
        )
        .unwrap();
        let drift = CompactCommit {
            world_id: WORLD_A.into(),
            resident_scope: RESIDENT_A.into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            expected: None,
            digest: "expected:none".into(),
            processed_watermark: 2,
            next_watermark: 3,
            embedding: EmbeddingRef {
                model: "different-model".into(),
                dimensions: 4,
            },
            entries: vec![fact_entry("drift")],
            vectors: vec![vec![0.0, 0.0, 0.0, 0.0]],
        };
        {
            let tx = connection.transaction().unwrap();
            assert_eq!(commit(&tx, &drift).unwrap_err(), "embedding_dimension_mismatch");
            drop(tx);
        }
        let dimension_drift = CompactCommit {
            world_id: WORLD_A.into(),
            resident_scope: RESIDENT_A.into(),
            request_id: uuid::Uuid::new_v4().to_string(),
            expected: None,
            digest: "expected:none".into(),
            processed_watermark: 2,
            next_watermark: 3,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 8,
            },
            entries: vec![fact_entry("drift")],
            vectors: vec![vec![0.0; 8]],
        };
        {
            let tx = connection.transaction().unwrap();
            assert_eq!(commit(&tx, &dimension_drift).unwrap_err(), "embedding_dimension_mismatch");
            drop(tx);
        }
    }

    #[test]
    fn same_request_id_replays_and_different_digest_conflicts() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        let request_id = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            commit_once(&mut connection, &scope_a(), &request_id, vec![fact_entry("only")], 1)
                .unwrap()
                .revision,
            1
        );
        // Replaying the same requestID + same digest returns the recorded
        // result and does not advance or rewrite.
        let replay = commit_once(&mut connection, &scope_a(), &request_id, vec![fact_entry("only")], 1)
            .unwrap();
        assert_eq!(
            replay,
            CompactResult {
                revision: 1,
                vector_generation: 1,
                processed_watermark: 1,
                replayed: true
            }
        );
        let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
        assert_eq!(row.revision, 1);
        assert_eq!(row.sections.facts[0].text, "only");
        // The same requestID with a different content digest conflicts.
        let changed = CompactCommit {
            world_id: WORLD_A.into(),
            resident_scope: RESIDENT_A.into(),
            request_id: request_id.clone(),
            expected: Some(1),
            digest: "expected:1".into(),
            processed_watermark: 2,
            next_watermark: 3,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 4,
            },
            entries: vec![fact_entry("different content")],
            vectors: vec![vec![0.0, 0.0, 0.0, 0.0]],
        };
        // Same requestID with a different content digest conflicts.
        let tx = connection.transaction().unwrap();
        assert_eq!(commit(&tx, &changed).unwrap_err(), "memory_request_conflict");
        drop(tx);
        // Same requestID with the recorded digest replays the recorded result
        // (content is identical), never rewriting or advancing.
        let mut same_content = changed;
        same_content.expected = None;
        same_content.digest = "expected:none".into();
        let tx = connection.transaction().unwrap();
        let replay = commit(&tx, &same_content).unwrap();
        assert_eq!(
            replay,
            CompactResult {
                revision: 1,
                vector_generation: 1,
                processed_watermark: 1,
                replayed: true
            }
        );
        tx.commit().unwrap();
        let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
        assert_eq!(row.revision, 1);
        assert_eq!(row.sections.facts[0].text, "only");
        // A fresh requestID may commit normally afterwards.
        let after = commit_once(
            &mut connection,
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("fresh")],
            2,
        )
        .unwrap();
        assert_eq!(after.revision, 2);
    }

    #[test]
    fn snapshot_and_vectors_survive_reopen_and_update_delete_on_temp_db() {
        register_vec();
        let path =
            std::env::temp_dir().join(format!("gmgn-memory-file-{}.sqlite", uuid::Uuid::new_v4()));
        {
            let mut connection = Connection::open(&path).unwrap();
            schema(&connection).unwrap();
            commit_once(
                &mut connection,
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![fact_entry("durable one")],
                1,
            )
            .unwrap();
        }
        {
            let mut connection = Connection::open(&path).unwrap();
            schema(&connection).unwrap();
            let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
            assert_eq!(row.revision, 1);
            assert_eq!(row.vector_generation, 1);
            assert_eq!(row.sections.facts[0].text, "durable one");
            // A later compaction replaces (update) then removes everything.
            commit_once(
                &mut connection,
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![fact_entry("updated memory")],
                2,
            )
            .unwrap();
        }
        {
            let mut connection = Connection::open(&path).unwrap();
            schema(&connection).unwrap();
            let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
            assert_eq!(row.revision, 2);
            assert_eq!(row.vector_generation, 2);
            assert_eq!(row.sections.facts[0].text, "updated memory");
            let hits = search(&connection, WORLD_A, RESIDENT_A, &[0.0, 1.0, 0.0, 0.0], 8).unwrap();
            assert_eq!(hits.len(), 1);
            // Delete: compaction with zero entries clears vectors too.
            let tx = connection.transaction().unwrap();
            commit(
                &tx,
                &CompactCommit {
                    world_id: WORLD_A.into(),
                    resident_scope: RESIDENT_A.into(),
                    request_id: uuid::Uuid::new_v4().to_string(),
                    expected: None,
                    digest: "expected:none".into(),
                    processed_watermark: 3,
                    next_watermark: 4,
                    embedding: EmbeddingRef {
                        model: MODEL.into(),
                        dimensions: 4,
                    },
                    entries: vec![],
                    vectors: vec![],
                },
            )
            .unwrap();
            tx.commit().unwrap();
            let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
            assert_eq!(row.revision, 3);
            assert!(row.sections.facts.is_empty() && row.sections.notes.is_empty());
            assert!(search(&connection, WORLD_A, RESIDENT_A, &[0.0, 1.0, 0.0, 0.0], 8)
                .unwrap()
                .is_empty());
        }
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn envelope_validation_enforces_shape_caps_and_grounding() {
        let previous = Sections {
            facts: vec![entry("fact", "old fact")],
            notes: vec![],
        };
        let previous_id = previous.facts[0].id.clone();
        // notes without grounding are rejected.
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(
                json!([]),
                json!([{"category": "experience", "text": "no grounding"}]),
                json!([])
            )
        )
        .is_err());
        // Unknown categories are rejected in both sections.
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(
                json!([{"category": "experience", "text": "wrong section"}]),
                json!([]),
                json!([])
            )
        )
        .is_err());
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(
                json!([]),
                json!([{"category": "fact", "text": "wrong section", "grounding": "turn:1"}]),
                json!([])
            )
        )
        .is_err());
        // removed must reference an existing previous id.
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(
                json!([]),
                json!([]),
                json!([uuid::Uuid::new_v4().to_string()])
            )
        )
        .is_err());
        // A duplicate removed entry is rejected.
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(json!([]), json!([]), json!([previous_id.clone(), previous_id]))
        )
        .is_err());
        // Entry text too long, control chars, or oversize arrays rejected.
        let long_text = "x".repeat(ENTRY_TEXT_LIMIT + 1);
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(json!([{"category": "fact", "text": long_text}]), json!([]), json!([]))
        )
        .is_err());
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(
                json!([{"category": "fact", "text": "bad\ncontrol"}]),
                json!([]),
                json!([])
            )
        )
        .is_err());
        let too_many: Vec<Value> = (0..FACTS_LIMIT + 1)
            .map(|_| json!({"category": "fact", "text": "t"}))
            .collect();
        assert!(parse_compaction_output(
            Some(&previous),
            &envelope(json!(too_many), json!([]), json!([]))
        )
        .is_err());
        // removed referencing an id that is re-added in the output is fine
        // (daemon assigns fresh ids), and valid removal validates.
        let output = parse_compaction_output(
            Some(&previous),
            &envelope(
                json!([{"category": "fact", "text": "old fact"}]),
                json!([]),
                json!([previous_id])
            ),
        )
        .unwrap();
        assert_eq!(output.len(), 1);
        // Grounded notes with valid categories pass.
        let output = parse_compaction_output(
            Some(&previous),
            &envelope(
                json!([{"category": "preference", "text": "likes cold brew"}]),
                json!([{"category": "relationship", "text": "shares plans openly", "grounding": "turn:2", "observedAt": "2026-09-08"}]),
                json!([])
            ),
        )
        .unwrap();
        assert_eq!(output.len(), 2);
        assert_eq!(output[0].section, "facts");
        assert_eq!(output[1].section, "notes");
        assert!(output[1].entry.grounding.as_deref() == Some("turn:2"));
    }

    #[test]
    fn scope_validation_rejects_bad_identifiers() {
        assert!(scope_valid("world-a", "resident-a"));
        for (world, resident) in [
            ("", "resident-a"),
            ("world-a", ""),
            (" world-a", "resident-a"),
            ("world-a", "resident-a "),
            ("world-a\n", "resident-a"),
            ("world-a", "resident-a"),
        ] {
            if world.is_empty() || resident.is_empty() {
                assert!(!scope_valid(world, resident));
            }
        }
        assert!(!scope_valid("w".repeat(201).as_str(), "resident-a"));
        assert!(!scope_valid("world-a", "r".repeat(201).as_str()));
        assert!(identity(&uuid::Uuid::new_v4().to_string().to_uppercase()).is_ok());
        assert!(identity("not-a-uuid").is_err());
    }

    // -- Memory handle + provider fixtures (async) --------------------------

    #[tokio::test]
    async fn pending_turns_are_volatile_and_bounded_fifo() {
        let (_dir, database) = temp_db("pending");
        let memory = Memory::new(database);
        let first = memory.turn(scope_a(), "user", "hello world", false).await.unwrap();
        assert_eq!(first["watermark"], 1);
        assert_eq!(first["pendingTurns"], 1);
        let second = memory.turn(scope_a(), "agent", "hi there", false).await.unwrap();
        assert_eq!(second["watermark"], 2);
        let pending = memory.pending(scope_a()).await.unwrap();
        assert_eq!(pending["turns"].as_array().unwrap().len(), 2);
        assert_eq!(pending["turns"][0]["watermark"], 1);
        assert_eq!(pending["turns"][1]["watermark"], 2);
        assert_eq!(pending["turns"][0]["role"], "user");
        assert_eq!(pending["turns"][1]["text"], "hi there");
        // FIFO bound: oldest turns drop beyond the limit.
        for index in 0..(PENDING_TURNS_LIMIT + 5) {
            memory
                .turn(scope_a(), "user", &format!("turn {index}"), false)
                .await
                .unwrap();
        }
        let pending = memory.pending(scope_a()).await.unwrap();
        let turns = pending["turns"].as_array().unwrap();
        assert_eq!(turns.len(), PENDING_TURNS_LIMIT);
        assert_eq!(turns[0]["text"], "turn 5", "oldest entries dropped FIFO");
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["pendingTurns"], PENDING_TURNS_LIMIT);
        assert_eq!(status["memory"], Value::Null, "no snapshot before first commit");
    }

    #[tokio::test]
    async fn turn_and_compact_respect_scope_isolation() {
        let (_dir, database) = temp_db("isolated");
        let memory = Memory::new(database);
        memory.turn(scope_a(), "user", "only in a", false).await.unwrap();
        memory.turn(scope(WORLD_A, RESIDENT_B), "user", "only in b", false).await.unwrap();
        memory.turn(scope(WORLD_B, RESIDENT_A), "user", "only in world b", false).await.unwrap();
        let pending_a = memory.pending(scope_a()).await.unwrap();
        assert_eq!(pending_a["turns"].as_array().unwrap().len(), 1);
        assert_eq!(pending_a["turns"][0]["text"], "only in a");
        assert_eq!(
            memory.pending(scope(WORLD_B, RESIDENT_A)).await.unwrap()["turns"][0]["text"],
            "only in world b"
        );
    }

    #[tokio::test]
    async fn compact_unavailable_without_providers_and_partial_configuration() {
        let (_dir, database) = temp_db("unconfigured");
        let memory = Memory::new(database);
        memory.turn(scope_a(), "user", "something worth keeping", false).await.unwrap();
        let result = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await;
        assert_eq!(result.unwrap_err(), "compaction_unavailable");
        // Only embedding configured: compaction still unavailable.
        let (_, embedding) = provider_pair(None, None, false, false, false);
        memory
            .configure("embedding", &embedding.endpoint, TOKEN, None)
            .await
            .unwrap();
        assert_eq!(
            memory
                .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
                .await
                .unwrap_err(),
            "compaction_unavailable"
        );
        // Only compaction configured on a fresh memory: embedding unavailable.
        let (_other_dir, other_database) = temp_db("unconfigured2");
        let other = Memory::new(other_database);
        other.turn(scope_a(), "user", "still something worth keeping", false).await.unwrap();
        let (compaction, _) = provider_pair(None, None, false, false, false);
        other
            .configure("compaction", &compaction.endpoint, TOKEN, None)
            .await
            .unwrap();
        assert_eq!(
            other
                .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
                .await
                .unwrap_err(),
            "embedding_unavailable"
        );
    }

    #[tokio::test]
    async fn compact_commits_durably_and_clears_pending_only_after_success() {
        let (_dir, database) = temp_db("durable");
        let memory = Memory::new(database);
        let compaction_bodies = Arc::new(StdMutex::new(Vec::new()));
        let embedding_bodies = Arc::new(StdMutex::new(Vec::new()));
        let (compaction, embedding) = provider_pair(
            Some(compaction_bodies.clone()),
            Some(embedding_bodies.clone()),
            false,
            false,
            true,
        );
        configure_pair(&memory, &compaction, &embedding).await;
        memory.turn(scope_a(), "user", "my dog is named Biscuit", false).await.unwrap();
        memory.turn(scope_a(), "agent", "I will remember that", false).await.unwrap();
        memory.turn(scope_a(), "user", "first name of my childhood friend is Maria", false).await.unwrap();
        let status_before = memory.status(scope_a()).await.unwrap();
        assert_eq!(status_before["pendingTurns"], 3);
        assert_eq!(status_before["configured"]["compaction"], true);
        assert_eq!(status_before["configured"]["embedding"], true);

        let request_id = uuid::Uuid::new_v4().to_string();
        let result = memory.compact(&client(), scope_a(), &request_id, Some(0), Cancellation::new()).await.unwrap();
        assert_eq!(result["revision"], 1);
        assert_eq!(result["vectorGeneration"], 1);
        assert_eq!(result["processedWatermark"], 3);
        assert_eq!(result["replayed"], false);
        assert_eq!(result["pendingTurns"], 0, "pending cleared only after durable commit");

        // The compaction provider really saw an OpenAI-compatible chat request
        // carrying the configured model, the frozen semantic rules as the
        // system prompt and the captured turns/previous as the user content.
        let body = compaction_bodies.lock().unwrap()[0].clone();
        assert_eq!(body["model"], MODEL_COMP, "configured compaction model is sent");
        let system = body["messages"]
            .as_array()
            .unwrap()
            .iter()
            .find(|message| message["role"] == "system")
            .expect("system prompt present");
        assert_eq!(system["content"], COMPACTION_RULES, "semantic rules are sent");
        let user = chat_user_data(&body).expect("user data parses as JSON");
        assert_eq!(user["schemaVersion"], 1);
        let turns = user["turns"].as_array().unwrap().clone();
        assert_eq!(turns.len(), 3);
        assert_eq!(turns[0]["text"], "my dog is named Biscuit");
        assert!(user["previous"].is_null());
        let embedding_input = embedding_bodies.lock().unwrap()[0]["input"].clone();
        let texts: Vec<&str> = embedding_input
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_str().unwrap())
            .collect();
        assert!(
            texts.iter().any(|t| t.contains("Biscuit")),
            "facts text is embedded, not a lexical hash of it: {texts:?}"
        );

        let memory_value = memory.status(scope_a()).await.unwrap();
        assert_eq!(memory_value["memory"]["revision"], 1);
        assert_eq!(memory_value["memory"]["vectorGeneration"], 1);
        assert_eq!(memory_value["memory"]["processedWatermark"], 3);
        assert_eq!(memory_value["memory"]["nextWatermark"], 4);
        assert_eq!(memory_value["memory"]["embedding"]["model"], MODEL);
        assert_eq!(memory_value["memory"]["embedding"]["dimensions"], 4);
        assert_eq!(memory_value["memory"]["entryCounts"]["facts"], 3);
        assert_eq!(memory_value["memory"]["entryCounts"]["notes"], 3);
        assert_eq!(memory_value["pendingTurns"], 0);

        let read = memory.read(scope_a()).await.unwrap();
        assert_eq!(read["memory"]["schemaVersion"], 1);
        assert_eq!(read["memory"]["sections"]["facts"].as_array().unwrap().len(), 3);
        let texts: Vec<&str> = read["memory"]["sections"]["facts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|fact| fact["text"].as_str().unwrap())
            .collect();
        assert!(texts.iter().any(|t| t.contains("remembered:my dog is named Biscuit")));
        // Raw transcript text never lands verbatim: fixture rewrote it and the
        // snapshot only carries facts/notes.
        assert!(read["memory"]["sections"]["facts"]
            .as_array()
            .unwrap()
            .iter()
            .all(|fact| fact["text"].as_str().unwrap().starts_with("remembered:")));
        // Nothing new pending, nothing cleared beyond the committed watermark.
        assert!(memory.pending(scope_a()).await.unwrap()["turns"]
            .as_array()
            .unwrap()
            .is_empty());
    }

    #[tokio::test]
    async fn failed_compaction_keeps_pending_and_old_snapshot() {
        let (_dir, database) = temp_db("failkeeps");
        let memory = Memory::new(database);
        let (compaction, embedding) = provider_pair(None, None, true, false, false);
        configure_pair(&memory, &compaction, &embedding).await;
        memory.turn(scope_a(), "user", "must survive a provider failure", false).await.unwrap();
        let error = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap_err();
        assert_eq!(error, "memory_compact_failed");
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["pendingTurns"], 1, "failure must not clear pending");
        assert_eq!(status["memory"], Value::Null, "no half snapshot");
        // Retry with a healthy compaction provider succeeds.
        let (healthy, _) = provider_pair(None, None, false, false, true);
        memory
            .configure("compaction", &healthy.endpoint, TOKEN, Some(MODEL_COMP.into()))
            .await
            .unwrap();
        memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), Some(0), Cancellation::new())
            .await
            .unwrap();
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["pendingTurns"], 0);
    }

    #[tokio::test]
    async fn rejected_compaction_output_preserves_snapshot_and_pending() {
        let (_dir, database) = temp_db("rejected");
        let memory = Memory::new(database);
        // Fixture returns notes without grounding -> deterministic rejection.
        let bad = fixture(Arc::new(|path, body| {
            if path == crate::memory::COMPACTION_PATH {
                let model = body["model"].as_str().unwrap_or("");
                (
                    200,
                    chat_response(
                        model,
                        json!({
                            "facts": [],
                            "notes": [{"category": "experience", "text": "no grounding"}],
                            "removed": []
                        }),
                    ),
                )
            } else {
                (200, json!({"object": "list", "data": [], "model": MODEL}))
            }
        }));
        configure_pair(&memory, &bad, &bad).await;
        memory.turn(scope_a(), "user", "should be rejected", false).await.unwrap();
        let error = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap_err();
        assert_eq!(error, "compaction_rejected");
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["pendingTurns"], 1);
        assert_eq!(status["memory"], Value::Null);
    }

    #[tokio::test]
    async fn same_request_id_replays_without_recompacting() {
        let (_dir, database) = temp_db("replay");
        let memory = Memory::new(database);
        let compaction_calls = Arc::new(StdMutex::new(0usize));
        let calls = compaction_calls.clone();
        let (compaction, embedding) = provider_pair(None, None, false, false, true);
        let _ = calls;
        configure_pair(&memory, &compaction, &embedding).await;
        memory.turn(scope_a(), "user", "once only", false).await.unwrap();
        let request_id = uuid::Uuid::new_v4().to_string();
        let first = memory.compact(&client(), scope_a(), &request_id, None, Cancellation::new()).await.unwrap();
        assert_eq!(first["revision"], 1);
        assert_eq!(first["pendingTurns"], 0);
        // Retry after the reply was lost: same requestID + same content.
        memory.turn(scope_a(), "user", "a new turn after the commit", false).await.unwrap();
        let replay = memory.compact(&client(), scope_a(), &request_id, None, Cancellation::new()).await.unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["revision"], 1, "replay must not advance the revision");
        assert_eq!(replay["vectorGeneration"], 1);
        assert_eq!(replay["pendingTurns"], 1, "new turn stays pending");
        // The new turn still compacts later under a fresh requestID.
        let second = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), Some(1), Cancellation::new())
            .await
            .unwrap();
        assert_eq!(second["revision"], 2);
        assert_eq!(second["vectorGeneration"], 2);
        assert_eq!(second["processedWatermark"], 2);
        assert_eq!(second["pendingTurns"], 0);
    }

    #[tokio::test]
    async fn query_statuses_dimension_consistency_and_empty_scope() {
        let (_dir, database) = temp_db("query");
        let memory = Memory::new(database);
        // No embedding configured -> unconfigured, not an error.
        let unconfigured = memory
            .query(&client(), scope_a(), "anything", Some(4))
            .await
            .unwrap();
        assert_eq!(unconfigured["status"], "unconfigured");
        let (compaction, embedding) = provider_pair(None, None, false, false, true);
        memory
            .configure("compaction", &compaction.endpoint, TOKEN, Some(MODEL_COMP.into()))
            .await
            .unwrap();
        memory
            .configure("embedding", &embedding.endpoint, TOKEN, Some(MODEL.into()))
            .await
            .unwrap();
        // No snapshot yet -> unconfigured (generation 0).
        let no_memory = memory
            .query(&client(), scope_a(), "anything", None)
            .await
            .unwrap();
        assert_eq!(no_memory["status"], "unconfigured");
        // Invalid queries/topK are rejected before any provider call.
        assert_eq!(
            memory.query(&client(), scope_a(), "   ", None).await.unwrap_err(),
            "invalid_query"
        );
        assert_eq!(
            memory
                .query(&client(), scope_a(), &"q".repeat(QUERY_TEXT_LIMIT + 1), None)
                .await
                .unwrap_err(),
            "invalid_query"
        );
        assert_eq!(
            memory.query(&client(), scope_a(), "q", Some(21)).await.unwrap_err(),
            "invalid_topk"
        );
        assert_eq!(
            memory.query(&client(), scope_a(), "q", Some(0)).await.unwrap_err(),
            "invalid_topk"
        );
        // Compact something so vectors exist, then query.
        memory.turn(scope_a(), "user", "cat likes yarn", false).await.unwrap();
        memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap();
        let query = memory.query(&client(), scope_a(), "cat likes yarn", Some(8)).await.unwrap();
        assert_eq!(query["status"], "ok");
        let results = query["results"].as_array().unwrap();
        assert!(results.len() <= 8);
        let distances: Vec<f64> = results.iter().map(|r| r["distance"].as_f64().unwrap()).collect();
        let mut sorted = distances.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        assert_eq!(distances, sorted, "results are cosine-ascending");
        assert!(results[0]["id"].is_string());
        assert!(results[0]["section"].is_string());
    }

    #[tokio::test]
    async fn restart_loses_volatile_pending_but_keeps_snapshot_and_watermarks() {
        let dir = std::env::temp_dir().join(format!("gmgn-memory-restart-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let compaction_bodies = Arc::new(StdMutex::new(Vec::new()));
        let embedding_bodies = Arc::new(StdMutex::new(Vec::new()));
        let next_watermark_after_commit;
        {
            let database = Database::open(dir.clone(), None).unwrap();
            let memory = Memory::new(database);
            let (compaction, embedding) = provider_pair(
                Some(compaction_bodies.clone()),
                Some(embedding_bodies.clone()),
                false,
                false,
                true,
            );
            configure_pair(&memory, &compaction, &embedding).await;
            memory.turn(scope_a(), "user", "remember me across restarts", false).await.unwrap();
            memory.turn(scope_a(), "user", "a second durable turn", false).await.unwrap();
            memory
                .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
                .await
                .unwrap();
            // The durable next watermark (as committed); then a volatile turn
            // that was never compacted must vanish on restart.
            let durable = memory.status(scope_a()).await.unwrap();
            next_watermark_after_commit = durable["memory"]["nextWatermark"].as_i64().unwrap();
            assert_eq!(next_watermark_after_commit, 3);
            memory.turn(scope_a(), "user", "this will be lost on crash", false).await.unwrap();
            let status = memory.status(scope_a()).await.unwrap();
            assert_eq!(status["pendingTurns"], 1);
        }
        // "Crash": the Database handle is dropped; reopen the same directory.
        let database = Database::open(dir.clone(), None).unwrap();
        let memory = Memory::new(database);
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["pendingTurns"], 0, "volatile pending is gone after restart");
        assert_eq!(status["memory"]["revision"], 1);
        assert_eq!(status["memory"]["vectorGeneration"], 1);
        assert_eq!(status["memory"]["processedWatermark"], 2);
        // The snapshot + vectors survive and query needs a reconfigured
        // embedding provider (providers are in-memory only).
        let (_, embedding) = provider_pair(None, None, false, false, true);
        memory
            .configure("embedding", &embedding.endpoint, TOKEN, Some(MODEL.into()))
            .await
            .unwrap();
        let query = memory.query(&client(), scope_a(), "remember me across restarts", None).await.unwrap();
        assert_eq!(query["status"], "ok");
        // Watermark counter resumes from the durable next watermark.
        let turned = memory.turn(scope_a(), "user", "after restart", false).await.unwrap();
        assert_eq!(turned["watermark"], next_watermark_after_commit);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn query_returns_empty_when_snapshot_has_no_vectors() {
        let (_dir, database) = temp_db("empty-query");
        let memory = Memory::new(database);
        // A fixture whose compaction output is empty sections (all memories
        // removed) and whose embedding endpoint answers the OpenAI wire for
        // any batch (including the single empty-text probe the daemon sends to
        // anchor dimensions for a first all-empty commit).
        let empty = fixture(Arc::new(|path, body| {
            if path == crate::memory::COMPACTION_PATH {
                let model = body["model"].as_str().unwrap_or("");
                (
                    200,
                    chat_response(model, envelope(json!([]), json!([]), json!([]))),
                )
            } else {
                let texts: Vec<String> = body["input"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|item| item.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
                let result = embeddings(MODEL, &texts);
                (200, embeddings_response(&result))
            }
        }));
        configure_pair(&memory, &empty, &empty).await;
        memory.turn(scope_a(), "user", "nothing memorable", false).await.unwrap();
        memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap();
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["memory"]["entryCounts"]["facts"], 0);
        let query = memory
            .query(&client(), scope_a(), "anything", None)
            .await
            .unwrap();
        assert_eq!(query["status"], "empty");
        assert_eq!(query["results"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn configure_validation_and_credential_tokens() {
        let (_dir, database) = temp_db("configure");
        let memory = Memory::new(database);
        assert_eq!(
            memory.configure("bogus", "https://example.com", "t", None).await.unwrap_err(),
            "invalid_kind"
        );
        assert_eq!(
            memory.configure("compaction", "http://example.com", "t", None).await.unwrap_err(),
            "invalid_endpoint"
        );
        assert_eq!(
            memory.configure("compaction", "https://example.com/path", "t", None)
                .await
                .unwrap_err(),
            "invalid_endpoint"
        );
        assert_eq!(
            memory.configure("compaction", "https://example.com", "", None).await.unwrap_err(),
            "invalid_token"
        );
        assert_eq!(
            memory.configure("compaction", "https://example.com", "bad token \n", None)
                .await
                .unwrap_err(),
            "invalid_token"
        );
        assert_eq!(
            memory
                .configure("compaction", "https://example.com", "ok-token", Some("m".repeat(201)))
                .await
                .unwrap_err(),
            "invalid_memory_configure"
        );
        memory
            .configure("compaction", "https://example.com", "ok-token", None)
            .await
            .unwrap();
        let tokens = memory.configured_tokens().await;
        assert_eq!(tokens, vec!["ok-token".to_string()]);
    }

    /// A chat-completions compaction fixture that blocks each request in
    /// arrival order until the test sends on the `Sender<()>` it receives from
    /// `entered_rx`. Used to hold a compaction in flight across a cancellation
    /// or a concurrent writer, exactly like the independent daemon fixture.
    fn gated_compaction_fixture(
        entered_tx: std::sync::mpsc::Sender<std::sync::mpsc::Sender<()>>,
        note_categories: bool,
    ) -> Fixture {
        fixture(Arc::new(move |path, body| {
            if path != crate::memory::COMPACTION_PATH {
                return (404, json!({}));
            }
            let model = body["model"].as_str().unwrap_or("").to_owned();
            let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
            if entered_tx.send(release_tx).is_err() {
                return (500, json!({"error": "test gone"}));
            }
            // Bounded wait: if the test never releases (failure/panic), the
            // handler still finishes so the fixture Drop can join it.
            let _ = release_rx.recv_timeout(Duration::from_secs(15));
            let Some(user) = chat_user_data(body) else {
                return (400, json!({"error": "user data not sent"}));
            };
            let turns = user["turns"].as_array().cloned().unwrap_or_default();
            let mut facts = Vec::new();
            let mut notes = Vec::new();
            for turn in &turns {
                let text = turn["text"].as_str().unwrap_or("");
                facts.push(json!({
                    "category": "fact",
                    "text": format!("remembered:{text}"),
                    "observedAt": "2026-09-08",
                    "grounding": format!("turn:{}", turn["watermark"]),
                }));
                if note_categories {
                    notes.push(json!({
                        "category": "experience",
                        "text": format!("noted:{text}"),
                        "observedAt": "2026-09-08",
                        "grounding": format!("turn:{}", turn["watermark"]),
                    }));
                }
            }
            (200, chat_response(&model, envelope(json!(facts), json!(notes), json!([]))))
        }))
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn cancellation_after_provider_response_never_commits() {
        let (_dir, database) = temp_db("cancel-compact");
        let memory = Arc::new(Memory::new(database));
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let compaction = gated_compaction_fixture(entered_tx, false);
        let (_, embedding) = provider_pair(None, None, false, false, false);
        memory
            .configure("compaction", &compaction.endpoint, TOKEN, Some(MODEL_COMP.into()))
            .await
            .unwrap();
        memory
            .configure("embedding", &embedding.endpoint, TOKEN, Some(MODEL.into()))
            .await
            .unwrap();
        memory
            .turn(scope_a(), "user", "pending-before-cancel", false)
            .await
            .unwrap();

        let cancel = Cancellation::new();
        let request_id = uuid::Uuid::new_v4().to_string();
        let handle = {
            let memory = memory.clone();
            let cancel = cancel.clone();
            tokio::spawn(async move {
                let client = client();
                memory
                    .compact(&client, scope_a(), &request_id, None, cancel)
                    .await
            })
        };
        // The compaction request reached the provider and is blocked there.
        let release = entered_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("compaction call never reached the fixture");
        // Client disconnects (cancellation) while the provider is still
        // holding the request, then the provider's late response arrives.
        cancel.cancel();
        release.send(()).expect("release");
        let outcome = tokio::time::timeout(Duration::from_secs(15), handle)
            .await
            .expect("compact task hung after cancellation")
            .expect("compact task panicked");
        assert_eq!(outcome.unwrap_err(), "cancelled");
        // The late provider response must not have been written.
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["memory"], Value::Null, "canceled compaction must not commit");
        assert_eq!(status["pendingTurns"], 1, "pending must survive a canceled compaction");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn concurrent_compaction_binds_captured_base_generation() {
        let (_dir, database) = temp_db("race-base");
        let memory = Arc::new(Memory::new(database));
        let (entered_tx, entered_rx) = std::sync::mpsc::channel();
        let compaction = gated_compaction_fixture(entered_tx, false);
        let (_, embedding) = provider_pair(None, None, false, false, false);
        memory
            .configure("compaction", &compaction.endpoint, TOKEN, Some(MODEL_COMP.into()))
            .await
            .unwrap();
        memory
            .configure("embedding", &embedding.endpoint, TOKEN, Some(MODEL.into()))
            .await
            .unwrap();

        memory.turn(scope_a(), "user", "input-A", false).await.unwrap();
        let request_a = uuid::Uuid::new_v4().to_string();
        let worker_a = {
            let memory = memory.clone();
            tokio::spawn(async move {
                let client = client();
                memory.compact(&client, scope_a(), &request_a, None, Cancellation::new()).await
            })
        };
        // A captured turn A + no snapshot yet, and blocks in the provider.
        let release_a = entered_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("writer A never reached the fixture");
        memory.turn(scope_a(), "user", "input-B", false).await.unwrap();
        let request_b = uuid::Uuid::new_v4().to_string();
        let worker_b = {
            let memory = memory.clone();
            tokio::spawn(async move {
                let client = client();
                memory.compact(&client, scope_a(), &request_b, None, Cancellation::new()).await
            })
        };
        // B also captured no snapshot yet (generation 0), then blocks.
        let release_b = entered_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("writer B never reached the fixture");

        // A commits generation 1 over its captured turn A.
        release_a.send(()).expect("release A");
        let result_a = tokio::time::timeout(Duration::from_secs(15), worker_a)
            .await
            .expect("writer A hung")
            .expect("writer A panicked")
            .expect("writer A failed");
        assert_eq!(result_a["revision"], 1);
        assert_eq!(result_a["vectorGeneration"], 1);

        // B captured generation 0 but the snapshot advanced to 1: the internal
        // CAS must reject B even though it omitted expectedVectorGeneration.
        release_b.send(()).expect("release B");
        let error_b = tokio::time::timeout(Duration::from_secs(15), worker_b)
            .await
            .expect("writer B hung")
            .expect("writer B panicked")
            .expect_err("stale captured snapshot must not overwrite a newer commit");
        assert_eq!(error_b, "memory_conflict");
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["memory"]["revision"], 1);
        assert_eq!(status["memory"]["vectorGeneration"], 1);
        assert_eq!(status["pendingTurns"], 1, "pending turn B stays for the next compaction");
        let pending = memory.pending(scope_a()).await.unwrap();
        assert_eq!(pending["turns"][0]["text"], "input-B");
        let read = memory.read(scope_a()).await.unwrap();
        let texts: Vec<&str> = read["memory"]["sections"]["facts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|fact| fact["text"].as_str().unwrap())
            .collect();
        assert!(texts.contains(&"remembered:input-A"));
        assert!(!texts.contains(&"remembered:input-B"), "B's stale output must not land");
    }

    #[tokio::test]
    async fn empty_pending_without_providers_is_explicit_unavailable() {
        let (_dir, database) = temp_db("empty-unavailable");
        let memory = Memory::new(database);
        // Nothing pending and no providers: an explicit unavailable error, not
        // a masqueraded success summary.
        let error = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap_err();
        assert_eq!(error, "compaction_unavailable");
        // Compaction configured but embedding missing is still unavailable on
        // an empty scope.
        let (compaction, _) = provider_pair(None, None, false, false, false);
        memory
            .configure("compaction", &compaction.endpoint, TOKEN, Some(MODEL_COMP.into()))
            .await
            .unwrap();
        assert_eq!(
            memory
                .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
                .await
                .unwrap_err(),
            "embedding_unavailable"
        );
        // An idempotent replay still wins even when providers are gone again:
        // commit with real providers, "restart" (new Memory, no providers), and
        // replay the same requestID — the recorded result returns before any
        // availability check.
        let dir = std::env::temp_dir().join(format!("gmgn-replay-no-provider-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let request_id;
        {
            let database = Database::open(dir.clone(), None).unwrap();
            let memory2 = Memory::new(database);
            let (compaction2, embedding2) = provider_pair(None, None, false, false, false);
            memory2
                .configure("compaction", &compaction2.endpoint, TOKEN, Some(MODEL_COMP.into()))
                .await
                .unwrap();
            memory2
                .configure("embedding", &embedding2.endpoint, TOKEN, Some(MODEL.into()))
                .await
                .unwrap();
            memory2.turn(scope_a(), "user", "once", false).await.unwrap();
            request_id = uuid::Uuid::new_v4().to_string();
            let committed = memory2
                .compact(&client(), scope_a(), &request_id, None, Cancellation::new())
                .await
                .unwrap();
            assert_eq!(committed["revision"], 1);
        }
        {
            // After the restart nothing is configured: empty-pending compacts
            // are unavailable, but the recorded requestID replays first.
            let database = Database::open(dir.clone(), None).unwrap();
            let memory2 = Memory::new(database);
            assert_eq!(
                memory2
                    .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
                    .await
                    .unwrap_err(),
                "compaction_unavailable"
            );
            let replay = memory2
                .compact(&client(), scope_a(), &request_id, None, Cancellation::new())
                .await
                .unwrap();
            assert_eq!(replay["replayed"], true, "replay wins before availability checks");
            assert_eq!(replay["revision"], 1);
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[tokio::test]
    async fn stale_client_cas_is_rejected_before_any_provider_call() {
        let (_dir, database) = temp_db("stale-expected");
        let memory = Memory::new(database);
        let compaction_bodies = Arc::new(StdMutex::new(Vec::new()));
        let (compaction, embedding) = provider_pair(
            Some(compaction_bodies.clone()),
            None,
            false,
            false,
            false,
        );
        configure_pair(&memory, &compaction, &embedding).await;
        memory.turn(scope_a(), "user", "first", false).await.unwrap();
        memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap();
        // Generation is now 1; a client CAS expectation of 0 is stale before
        // any provider work (and therefore before any compaction call).
        memory.turn(scope_a(), "user", "second", false).await.unwrap();
        let conflict = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), Some(0), Cancellation::new())
            .await
            .unwrap_err();
        assert_eq!(conflict, "memory_conflict");
        assert_eq!(compaction_bodies.lock().unwrap().len(), 1, "no provider call for a stale CAS");
        // The pending second turn survives for a later, correctly-based retry.
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["pendingTurns"], 1);
        assert_eq!(status["memory"]["revision"], 1);
        let retry = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), Some(1), Cancellation::new())
            .await
            .unwrap();
        assert_eq!(retry["revision"], 2);
        assert_eq!(retry["pendingTurns"], 0);
    }

    #[tokio::test]
    async fn wipe_compaction_reuses_previous_embedding_record() {
        let (_dir, database) = temp_db("wipe");
        let memory = Memory::new(database);
        let embedding_calls = Arc::new(StdMutex::new(0usize));
        let calls = embedding_calls.clone();
        // Compaction fixture carries previous facts forward on the first call
        // and returns an empty (correction/wipe) envelope on the second; the
        // embedding endpoint records how many times it was invoked.
        let wipe = fixture(Arc::new(move |path, body| {
            if path == crate::memory::COMPACTION_PATH {
                let model = body["model"].as_str().unwrap_or("");
                let user = chat_user_data(body).unwrap_or(Value::Null);
                let has_previous = !user.is_null()
                    && user.get("previous").is_some_and(|previous| !previous.is_null());
                if has_previous {
                    (
                        200,
                        chat_response(model, envelope(json!([]), json!([]), json!([]))),
                    )
                } else {
                    let mut facts = Vec::new();
                    for turn in user["turns"].as_array().cloned().unwrap_or_default() {
                        facts.push(json!({
                            "category": "fact",
                            "text": format!("remembered:{}", turn["text"].as_str().unwrap_or("")),
                            "observedAt": "2026-09-08",
                            "grounding": format!("turn:{}", turn["watermark"]),
                        }));
                    }
                    (
                        200,
                        chat_response(model, envelope(json!(facts), json!([]), json!([]))),
                    )
                }
            } else {
                let _ = calls.lock().map(|mut c| *c += 1);
                let texts: Vec<String> = body["input"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|item| item.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
                let result = embeddings(MODEL, &texts);
                (200, embeddings_response(&result))
            }
        }));
        configure_pair(&memory, &wipe, &wipe).await;
        memory.turn(scope_a(), "user", "first memory", false).await.unwrap();
        memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap();
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["memory"]["entryCounts"]["facts"], 1);
        assert!(*embedding_calls.lock().unwrap() > 0, "first commit embeds");
        // Second compaction corrects everything away (empty sections). Its
        // commit carries the previous model/dimension record forward without
        // another embedding call (nothing new to embed), and the wipe is
        // durable with the dimension anchor intact.
        memory.turn(scope_a(), "user", "superseded", false).await.unwrap();
        let before_calls = *embedding_calls.lock().unwrap();
        let wiped = memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), Some(1), Cancellation::new())
            .await
            .unwrap();
        assert_eq!(wiped["revision"], 2);
        assert_eq!(*embedding_calls.lock().unwrap(), before_calls,
                   "a zero-entry compaction with a previous record needs no embedding call");
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["memory"]["entryCounts"]["facts"], 0);
        assert_eq!(status["memory"]["embedding"]["model"], MODEL);
        assert_eq!(status["memory"]["embedding"]["dimensions"], 4);
        assert_eq!(status["pendingTurns"], 0);
        let query = memory
            .query(&client(), scope_a(), "anything", None)
            .await
            .unwrap();
        assert_eq!(query["status"], "empty");
    }

    #[tokio::test]
    async fn query_rejects_embedding_model_drift() {
        let (_dir, database) = temp_db("query-drift");
        let memory = Memory::new(database);
        // An embedding endpoint that echoes the requested model back, so a
        // query configured for a different model proves the drift check.
        let echo = fixture(Arc::new(|path, body| {
            if path == crate::memory::COMPACTION_PATH {
                let model = body["model"].as_str().unwrap_or("");
                let user = chat_user_data(body).unwrap_or(Value::Null);
                let mut facts = Vec::new();
                for turn in user["turns"].as_array().cloned().unwrap_or_default() {
                    facts.push(json!({
                        "category": "fact",
                        "text": format!("remembered:{}", turn["text"].as_str().unwrap_or("")),
                        "observedAt": "2026-09-08",
                        "grounding": format!("turn:{}", turn["watermark"]),
                    }));
                }
                (
                    200,
                    chat_response(model, envelope(json!(facts), json!([]), json!([]))),
                )
            } else {
                let requested = body["model"].as_str().unwrap_or("no-model").to_owned();
                let texts: Vec<String> = body["input"]
                    .as_array()
                    .map(|items| {
                        items
                            .iter()
                            .filter_map(|item| item.as_str().map(str::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
                let result = embeddings(&requested, &texts);
                (200, embeddings_response(&result))
            }
        }));
        // Compact with model X: the snapshot records model X / dims 4.
        memory
            .configure("compaction", &echo.endpoint, TOKEN, Some("model-x".into()))
            .await
            .unwrap();
        memory
            .configure("embedding", &echo.endpoint, TOKEN, Some("model-x".into()))
            .await
            .unwrap();
        memory.turn(scope_a(), "user", "drift check", false).await.unwrap();
        memory
            .compact(&client(), scope_a(), &uuid::Uuid::new_v4().to_string(), None, Cancellation::new())
            .await
            .unwrap();
        // Reconfigure the embedding provider to a different model: the query
        // vector would come from a different embedding space, so the daemon
        // must reject it instead of mixing models.
        memory
            .configure("embedding", &echo.endpoint, TOKEN, Some("model-y".into()))
            .await
            .unwrap();
        let error = memory
            .query(&client(), scope_a(), "drift check", None)
            .await
            .unwrap_err();
        assert_eq!(error, "embedding_dimension_mismatch");
        // The stored snapshot is untouched by the failed query.
        let status = memory.status(scope_a()).await.unwrap();
        assert_eq!(status["memory"]["embedding"]["model"], "model-x");
    }

    // -- orchestration behavior tests (VoiceMem plan Task 1) ---------------

    fn embed_fixture(text: &str) -> Vec<f32> {
        // Deterministic 4-dim vectors by content so per-lane recall distances
        // are predictable offline.
        if text.contains("alice") {
            vec![1.0, 0.0, 0.0, 0.0]
        } else if text.contains("bob") {
            vec![0.0, 1.0, 0.0, 0.0]
        } else if text.contains("cat") {
            vec![0.0, 0.0, 1.0, 0.0]
        } else if text.contains("calm") {
            vec![0.98, 0.02, 0.0, 0.0]
        } else {
            vec![0.5, 0.5, 0.0, 0.0]
        }
    }

    /// An offline provider pair whose compaction always returns the same
    /// deterministic envelope (so unchanged entries must keep their ids across
    /// consolidations) and whose embeddings are content-derived. Records every
    /// chat body and counts embedding calls.
    fn orchestration_providers(
        chat_bodies: Arc<StdMutex<Vec<Value>>>,
        embedding_calls: Arc<StdMutex<usize>>,
        fail_compaction: Arc<AtomicBool>,
    ) -> (Fixture, Fixture) {
        let envelope = json!({
            "facts": [
                {"category": "fact", "text": "alice likes hiking near the cabin",
                 "observedAt": "2026-09-08", "grounding": "turn:1"},
                {"category": "fact", "text": "bob prefers tea over coffee",
                 "observedAt": "2026-09-08", "grounding": "turn:1"},
                {"category": "fact", "text": "the resident owns a grey cat",
                 "observedAt": "2026-09-08", "grounding": "turn:1"},
            ],
            "notes": [
                {"category": "experience",
                 "text": "resident speaks in a calm tone when tired",
                 "observedAt": "2026-09-08", "grounding": "turn:1"},
            ],
            "removed": [],
        });
        let compaction = fixture(Arc::new(move |path, body| {
            if path != crate::memory::COMPACTION_PATH {
                return (404, json!({}));
            }
            let _ = chat_bodies.lock().map(|mut bodies| bodies.push(body.clone()));
            if fail_compaction.load(Ordering::Acquire) {
                return (500, json!({"error": "boom"}));
            }
            let model = body["model"].as_str().unwrap_or("");
            (200, chat_response(model, envelope.clone()))
        }));
        let embedding = fixture(Arc::new(move |path, body| {
            if path != crate::memory::EMBEDDING_PATH {
                return (404, json!({}));
            }
            let _ = embedding_calls.lock().map(|mut calls| *calls += 1);
            let texts: Vec<String> = body["input"]
                .as_array()
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| item.as_str().map(str::to_owned))
                        .collect()
                })
                .unwrap_or_default();
            let data: Vec<Value> = texts
                .iter()
                .enumerate()
                .map(|(index, text)| {
                    json!({"index": index, "embedding": embed_fixture(text)})
                })
                .collect();
            (200, json!({"object": "list", "data": data, "model": MODEL}))
        }));
        (compaction, embedding)
    }

    async fn configure_orchestration(memory: &Memory, compaction: &Fixture, embedding: &Fixture) {
        memory
            .configure("compaction", &compaction.endpoint, TOKEN, Some(MODEL_COMP.into()))
            .await
            .unwrap();
        memory
            .configure("embedding", &embedding.endpoint, TOKEN, Some(MODEL.into()))
            .await
            .unwrap();
    }

    /// Bounded wait for an async predicate; every orchestration test polls in
    /// small controlled increments under a hard deadline (never unbounded).
    async fn wait_until<F, Fut>(mut predicate: F, what: &str)
    where
        F: FnMut() -> Fut,
        Fut: std::future::Future<Output = bool>,
    {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        loop {
            if predicate().await {
                return;
            }
            if tokio::time::Instant::now() >= deadline {
                panic!("timed out waiting for {what}");
            }
            tokio::time::sleep(Duration::from_millis(15)).await;
        }
    }

    async fn revision_of(memory: &Memory) -> i64 {
        memory
            .read(scope_a())
            .await
            .ok()
            .and_then(|value| value["memory"]["revision"].as_i64())
            .unwrap_or(0)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ingest_pair_is_atomic_idempotent_volatile_and_schedules() {
        let (dir, database) = temp_db("ingest-atomic");
        let memory = Arc::new(Memory::new(database));
        memory.set_orchestration_policy(OrchPolicy {
            batch_turns: 2,
            batch_delay: Duration::from_millis(40),
            idle_delay: Duration::from_millis(400),
        });
        let chat_bodies = Arc::new(StdMutex::new(Vec::new()));
        let embedding_calls = Arc::new(StdMutex::new(0usize));
        let fail = Arc::new(AtomicBool::new(false));
        let (compaction, embedding) =
            orchestration_providers(chat_bodies.clone(), embedding_calls.clone(), fail);
        configure_orchestration(&memory, &compaction, &embedding).await;
        let client = client();
        let request_id = uuid::Uuid::new_v4().hyphenated().to_string();
        let marker = format!("raw-{}", uuid::Uuid::new_v4());

        // A delivery below any consolidation returns immediately: no provider
        // call happens inside the ingest reply path.
        let before = *embedding_calls.lock().unwrap();
        let accepted = memory
            .clone()
            .ingest(&client, scope_a(), &request_id, &marker, "确已交付的答复", "voice",
                    Some("2026-09-08T11:00:00+08:00".into()))
            .await
            .unwrap();
        assert_eq!(accepted["pendingTurns"], 2);
        assert_eq!(accepted["replayed"], false);
        assert_eq!(accepted["consolidation"], "pending");
        assert_eq!(*embedding_calls.lock().unwrap(), before);

        // Same requestID replay is idempotent; different content conflicts.
        let replay = memory
            .clone()
            .ingest(&client, scope_a(), &request_id, &marker, "确已交付的答复", "voice",
                    Some("2026-09-08T11:00:00+08:00".into()))
            .await
            .unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["pendingTurns"], 2);
        let conflict = memory
            .clone()
            .ingest(&client, scope_a(), &request_id, "其他内容", "确已交付的答复", "text", None)
            .await
            .unwrap_err();
        assert_eq!(conflict, "memory_request_conflict");
        // A half pair is rejected without leaving anything behind.
        let invalid = memory
            .clone()
            .ingest(&client, scope_a(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                    "would-be-half-pair", "", "text", None)
            .await
            .unwrap_err();
        assert_eq!(invalid, "invalid_turn_text");
        let pending = memory.pending(scope_a()).await.unwrap();
        assert_eq!(pending["turns"].as_array().unwrap().len(), 2);

        // Background batch consolidation commits durably and clears the
        // volatile turns.
        wait_until(|| async { revision_of(&memory).await >= 1 }, "background consolidation").await;
        let read = memory.read(scope_a()).await.unwrap();
        let first_ids: Vec<String> = read["memory"]["sections"]["facts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(first_ids.len(), 3, "fixture facts all stored");
        assert_eq!(memory.pending(scope_a()).await.unwrap()["turns"].as_array().unwrap().len(), 0);
        // Raw transcript must not persist anywhere in the private root.
        for path in std::fs::read_dir(&dir).unwrap().flatten() {
            let bytes = std::fs::read(path.path()).unwrap();
            assert!(
                !bytes.windows(marker.len()).any(|window| window == marker.as_bytes()),
                "raw ingest text leaked to disk in {}",
                path.path().display()
            );
        }

        // The next delivery's extraction still sees the previous delivered
        // reply even though its own turns were cleared by the consolidation.
        memory
            .clone()
            .ingest(&client, scope_a(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                    "下一次反馈", "下一次答复", "voice",
                    Some("2026-09-08T11:01:00+08:00".into()))
            .await
            .unwrap();
        wait_until(|| async { revision_of(&memory).await >= 2 }, "second consolidation").await;
        let second_read = memory.read(scope_a()).await.unwrap();
        let second_ids: Vec<String> = second_read["memory"]["sections"]["facts"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["id"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(first_ids, second_ids, "unchanged entries must retain stable ids");
        let last = {
            let bodies = chat_bodies.lock().unwrap();
            bodies.last().cloned().expect("second chat body")
        };
        let last_json = serde_json::to_string(&last).unwrap();
        assert!(last_json.contains("确已交付的答复"),
                "previous delivered reply must reach the next extraction");
        assert!(last_json.contains("voice"));
        let user = chat_user_data(&last).expect("second user content");
        assert_eq!(user["previousReply"]["text"], "确已交付的答复");
        assert_eq!(user["previousReply"]["source"], "voice");
        assert_eq!(user["previousReply"]["observedAt"], "2026-09-08T11:00:00+08:00");

        // A restart loses the volatile buffer; the durable snapshot survives.
        drop(memory);
        let reopened = Database::open(dir.clone(), None).unwrap();
        let restarted = Memory::new(reopened);
        assert_eq!(restarted.pending(scope_a()).await.unwrap()["turns"].as_array().unwrap().len(), 0);
        assert!(restarted.read(scope_a()).await.unwrap()["memory"].is_object());
        let _ = dir;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn ingest_validation_and_failure_keeps_pending_with_visible_error() {
        let (dir, database) = temp_db("ingest-fail");
        let memory = Arc::new(Memory::new(database));
        memory.set_orchestration_policy(OrchPolicy {
            batch_turns: 2,
            batch_delay: Duration::from_millis(40),
            idle_delay: Duration::from_millis(400),
        });
        let chat_bodies = Arc::new(StdMutex::new(Vec::new()));
        let embedding_calls = Arc::new(StdMutex::new(0usize));
        let fail = Arc::new(AtomicBool::new(true));
        let (compaction, embedding) =
            orchestration_providers(chat_bodies, embedding_calls, fail.clone());
        configure_orchestration(&memory, &compaction, &embedding).await;
        let client = client();
        let s = scope_a();

        type Case = (String, String, String, &'static str, Option<String>, &'static str);
        let cases: Vec<Case> = vec![
            ("not-a-uuid".into(), "u".into(), "r".into(), "text", None, "invalid_memory_ingest"),
            (
                uuid::Uuid::new_v4().hyphenated().to_string(),
                "u".into(), "r".into(), "system", None, "invalid_memory_ingest",
            ),
            (
                uuid::Uuid::new_v4().hyphenated().to_string(),
                "".into(), "r".into(), "text", None, "invalid_turn_text",
            ),
            (
                uuid::Uuid::new_v4().hyphenated().to_string(),
                "u".into(), "".into(), "text", None, "invalid_turn_text",
            ),
            (
                uuid::Uuid::new_v4().hyphenated().to_string(),
                "x".repeat(2001), "r".into(), "text", None, "turn_text_too_large",
            ),
            (
                uuid::Uuid::new_v4().hyphenated().to_string(),
                "u".into(), "r".into(), "text", Some("o".repeat(33)), "invalid_memory_ingest",
            ),
        ];
        for (request_id, user, reply, source, observed, code) in cases {
            let error = memory
                .clone()
                .ingest(&client, s.clone(), &request_id, &user, &reply, source, observed)
                .await
                .unwrap_err();
            assert_eq!(error, code);
        }
        assert_eq!(memory.pending(s.clone()).await.unwrap()["turns"].as_array().unwrap().len(), 0);

        // A failing provider keeps pending and surfaces state=failed with a
        // stable lastError (no silent drop, no fake success).
        memory
            .clone()
            .ingest(&client, s.clone(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                    "u", "r", "text", None)
            .await
            .unwrap();
        wait_until(
            || async {
                memory.orchestration_state(&s.world_id, &s.resident_scope)
                    == Some(orchestration::State::Failed)
            },
            "background consolidation to fail",
        )
        .await;
        assert_eq!(memory.pending(s.clone()).await.unwrap()["turns"].as_array().unwrap().len(), 2);
        let status = memory.status(s.clone()).await.unwrap();
        assert_eq!(status["orchestration"]["state"], "failed");
        assert_eq!(status["orchestration"]["lastError"], "memory_compact_failed");

        // The next delivery retries; once the provider recovers, turns commit.
        fail.store(false, Ordering::Release);
        memory
            .clone()
            .ingest(&client, s.clone(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                    "u2", "r2", "text", None)
            .await
            .unwrap();
        wait_until(
            || async {
                memory.orchestration_state(&s.world_id, &s.resident_scope)
                    == Some(orchestration::State::Idle)
            },
            "recovered background consolidation",
        )
        .await;
        assert_eq!(memory.pending(s.clone()).await.unwrap()["turns"].as_array().unwrap().len(), 0);
        let status = memory.status(s.clone()).await.unwrap();
        assert_eq!(status["orchestration"]["state"], "idle");
        assert_eq!(status["orchestration"]["lastError"], Value::Null);
        drop(memory);
        let _ = dir;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn recall_has_independent_lane_quotas_and_one_embedding() {
        let (dir, database) = temp_db("recall-lanes");
        let memory = Arc::new(Memory::new(database));
        let chat_bodies = Arc::new(StdMutex::new(Vec::new()));
        let embedding_calls = Arc::new(StdMutex::new(0usize));
        let fail = Arc::new(AtomicBool::new(false));
        let (compaction, embedding) =
            orchestration_providers(chat_bodies, embedding_calls.clone(), fail);
        let client = client();

        // Ingest while unconfigured (no background scheduling), then configure
        // and consolidate explicitly so recall starts from a settled snapshot.
        let accepted = memory
            .clone()
            .ingest(&client, scope_a(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                    "hello alice", "hello", "voice", None)
            .await
            .unwrap();
        assert_eq!(accepted["consolidation"], "unconfigured");
        configure_orchestration(&memory, &compaction, &embedding).await;
        let result = memory
            .clone()
            .compact_explicit(&client, scope_a(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                              None, Cancellation::new())
            .await
            .unwrap();
        let generation = result["vectorGeneration"].as_i64().unwrap();

        let before = *embedding_calls.lock().unwrap();
        let recall = memory
            .recall(&client, scope_a(), "alice hiking", false, Some(1), Some(1))
            .await
            .unwrap();
        assert_eq!(recall["status"], "ok");
        assert_eq!(recall["vectorGeneration"].as_i64().unwrap(), generation);
        assert_eq!(recall["revision"].as_i64().unwrap(), 1);
        let facts = recall["facts"].as_array().unwrap();
        let notes = recall["notes"].as_array().unwrap();
        assert_eq!(facts.len(), 1, "fact lane quota is independent");
        assert_eq!(notes.len(), 1, "facts must not crowd out the notes lane");
        assert_eq!(facts[0]["text"], "alice likes hiking near the cabin");
        assert_eq!(facts[0]["section"], "facts");
        assert_eq!(notes[0]["text"], "resident speaks in a calm tone when tired");
        assert_eq!(notes[0]["section"], "notes");
        assert_eq!(recall["pendingTurns"].as_i64().unwrap(), 0);
        let after = *embedding_calls.lock().unwrap();
        assert_eq!(after - before, 1, "one query embedding shared by both lanes");
        let context = recall["context"].as_str().unwrap();
        assert!(context.chars().count() <= RECALL_CONTEXT_LIMIT);
        assert!(context.contains("禁止照读"), "notes must be marked tone-only");
        assert!(!context.contains("新会话恢复"), "non-fresh recall never restores history");

        // A different resident scope sees no semantic memory at all.
        let other = scope(WORLD_A, RESIDENT_B);
        let other_recall = memory
            .recall(&client, other, "alice hiking", false, None, None)
            .await
            .unwrap();
        assert_eq!(other_recall["facts"].as_array().unwrap().len(), 0);
        assert_eq!(other_recall["notes"].as_array().unwrap().len(), 0);
        assert_eq!(other_recall["revision"].as_i64().unwrap(), 0);
        drop(memory);
        let _ = dir;
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn recall_fresh_restores_local_snapshot_without_embedding() {
        // Build a committed snapshot with a first daemon (both providers), then
        // recall on a fresh daemon over the same private root that has no
        // embedding provider configured: status is unconfigured while a fresh
        // session still restores the confirmed local snapshot.
        let (dir, database) = temp_db("recall-fresh");
        let memory = Arc::new(Memory::new(database));
        let chat_bodies = Arc::new(StdMutex::new(Vec::new()));
        let embedding_calls = Arc::new(StdMutex::new(0usize));
        let fail = Arc::new(AtomicBool::new(false));
        let (compaction, embedding) =
            orchestration_providers(chat_bodies, embedding_calls, fail);
        configure_orchestration(&memory, &compaction, &embedding).await;
        let client = client();
        memory
            .clone()
            .ingest(&client, scope_a(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                    "remember alice", "right", "voice", None)
            .await
            .unwrap();
        memory
            .clone()
            .compact_explicit(&client, scope_a(), &uuid::Uuid::new_v4().hyphenated().to_string(),
                              None, Cancellation::new())
            .await
            .unwrap();
        drop(memory);
        let reopened = Database::open(dir.clone(), None).unwrap();
        let restarted = Arc::new(Memory::new(reopened));
        let result = restarted
            .recall(&client, scope_a(), "anything", true, None, None)
            .await
            .unwrap();
        assert_eq!(result["status"], "unconfigured");
        assert_eq!(result["facts"].as_array().unwrap().len(), 0);
        assert_eq!(result["notes"].as_array().unwrap().len(), 0);
        assert_eq!(result["vectorGeneration"].as_i64().unwrap(), 1);
        let context = result["context"].as_str().unwrap();
        assert!(context.contains("新会话恢复"), "fresh session restores a labeled block");
        assert!(context.contains("alice likes hiking near the cabin"));
        assert!(context.contains("禁止照读"));
        assert!(context.contains("语义记忆检索当前不可用"));
        let non_fresh = restarted
            .recall(&client, scope_a(), "anything", false, None, None)
            .await
            .unwrap();
        let context = non_fresh["context"].as_str().unwrap();
        assert!(!context.contains("新会话恢复"));
        assert!(!context.contains("alice likes hiking near the cabin"));
        drop(restarted);
        let _ = dir;
    }
}
