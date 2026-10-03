//! VoiceMem selective Rust port: scoped durable memory snapshots + retrieval.
//!
//! # ⚠️ 长期记忆已由用户决定**不做**（2026-10-01）
//!
//! 本模块的**压缩层**（`memory_snapshots` / `memory_requests` / `memory_vec_rows`
//! 三张表、快照形状、代次账本、`commit` / `recorded_replay` / `CompactCommit`）
//! **保留但不在计划内**：
//!
//! * **保留**是因为**删表收益低于风险** —— 老库里可能已有账本行，而结构本身是
//!   一段历史记录；`schema()` 的 DDL 幂等且纯增量，留着不产生运行成本。
//! * **不在计划内**是因为用户拍板「长期记忆不要搞」：`memory_compact`（冻结合同
//!   §3.7）**不会接线**，这里现已 dead 的**写入方**（`commit` / `recorded_replay`
//!   / `CompactCommit` / `VecEntry` 等）**不接**任何生产调用点。
//! * 模块级 `#![allow(dead_code)]` 就是为这些保留结构开的豁免（见下方注释）。
//!   **新增死代码请单独处理，不要依赖这条豁免。**
//! * 界面上**不再**出现任何「长期记忆暂不可用 / 等压缩接上后自动恢复」之类的
//!   提示——既然不做，就不该宣传一个不会有的能力。判据在
//!   `tools/test-no-long-term-memory-capability.swift`（注入回来 ⇒ FAIL）。
//! * **不影响对话连续性**：会话内连续性来自 DSH 自己的 session，不来自本模块。
//! * **存储范围（最终口径）**：只持久化**空间状态**（世界 + 物件 + 资产引用）到
//!   本地 Rust 权威；长期记忆、消息投递迁移、云端同步均**不在计划内**。
//!
//! 历史的原文层（volatile pending turns）已于同日整体退役，判据见本模块
//! `raw_conversation_text_layer_is_gone_and_cannot_come_back_silently`。
//!
//! This module adds a third persistent layer beside the job store and the
//! resident state/event/message store, all inside the one `tasks.sqlite3` and
//! the one `taskd-storage` writer thread (no second database, no second
//! writer). The wire contract is frozen in
//! `docs/plans/2026-09-08-voicemem-rust-contract.md` (additive IPC,
//! `memory_status/read/query/turn/pending` plus the local
//! `memory_ingest/recall` of the orchestration contract); nothing here
//! changes the existing `configure/snapshot/submit/cancel/retry/...` or the
//! resident contracts.
//!
//! 为什么保留这张表和这套账本：快照、请求幂等行和向量代次是本地记忆的续存
//! 依据（水位、revision、代次必须跨重启一致）。外部 VoiceMem 服务层已整体
//! 移除：daemon 不再向任何 compaction/embedding endpoint 发 HTTP，也不再持有
//! endpoint/token/model 配置，因此本模块不再产生向量。为后续在 Rust 内自行
//! 实现语义抽取，表结构与代次账本原样保留，只是向量写入侧不再执行。
//!
//! Data model (frozen):
//! - Long-term memory is one versioned snapshot per `(worldID, residentScope)`
//!   with two sections: atomic long-term `facts`/preferences and grounded
//!   `notes` (relationship/experience). A snapshot is committed atomically by
//!   one transaction and generation-matched (`vectorGeneration`).
//! - Conversation raw text exists only as volatile in-process pending turns
//!   keyed by scope (VoiceMem `SessionBuffer` commit-after-durability): turns
//!   stay pending until a durable commit of that scope, then pending turns with
//!   `watermark <= processedWatermark` are cleared. A crash loses the volatile
//!   pending text; committed snapshots and watermark counters survive.
//!
//! Storage layout (schema v3 `memory-storage-v1`, additive):
//! - `memory_snapshots`: one row per scope with scalar snapshot fields +
//!   serialized sections.
//! - `memory_requests`: per-scope requestID idempotency (revision, generation,
//!   processed watermark, digest of the request content).
//! - `memory_vec_rows`: rowid->entry map for each scope's sqlite-vec
//!   partition. Retained as ledger structure only: nothing writes it since the
//!   embedding provider was removed, and no DROP is ever issued.
//! - per-scope `memory_vec_<sha256>` vec0 partitions (`float32[dims]`,
//!   `distance_metric=cosine`) created by older binaries are left untouched on
//!   disk; the module neither creates nor queries them any more.
//!
//! sqlite-vec is statically linked (pinned `=0.1.9`, MIT/Apache-2.0) and
//! registered process-wide through `sqlite3_auto_extension` before any
//! connection is opened, so an existing database that still carries vec0
//! partitions keeps opening cleanly. Provenance notes for the VoiceMem
//! semantics (Apache 2.0, reference commit
//! a450911fc8cbb44c46d810aace2f3288bad287e4) and the sqlite-vec notice live in
//! this module's docs and in `services/gmgn-taskd/VoiceMem-NOTICE.md`.

// 为什么整模块允许 dead_code：外部 VoiceMem 服务层拆除后，快照提交与幂等账本
// （commit / recorded_replay / CompactCommit 等）暂时没有生产调用方——它们是
// "留在 Rust 里的**压缩层**"的存储层，等本地抽取实现接手；产品决定要求保留账本
// 结构，所以不能为了消警告把它们删掉。除此之外本模块没有其它未使用代码，
// 新增死代码请单独处理而不是依赖这条豁免。
//
// 注意：**原文层（volatile pending turns）不在这条豁免之内**——它已于 2026-10-01
// 被整体删除（真机 `pendingTurns` 恒为 0、三表 0 行、唯一生产用途恒空转），
// 不要再以"等实现接手"为理由把它加回来。见 `voicemem-rust-contract.md`「已移除」。
#![allow(dead_code)]

use crate::resident::Scope;
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::time::{SystemTime, UNIX_EPOCH};

pub type Result<T> = std::result::Result<T, &'static str>;

fn fail<T>(code: &'static str) -> Result<T> {
    Err(code)
}

/// Frozen constants (contract §1). Character limits are measured in Unicode
/// scalar values (`chars().count()`), byte limits in UTF-8 bytes.
///
/// **原文层（volatile pending turns）已整体移除**，所以 `PENDING_TURNS_LIMIT` /
/// `TURN_TEXT_LIMIT` / `INGEST_RECEIPTS_LIMIT` / `FRESH_RESTORE_TURNS` 都不在了。
/// 依据见 `docs/plans/2026-09-08-voicemem-rust-contract.md` 的「已移除」一节：
/// 真机 `pendingTurns` 恒为 0、三张记忆表 0 行、`memory_compact` 从未有 dispatch，
/// 原文层唯一的生产用途（`freshSession` 恢复段）在 pending=0 时**恒为空转**；
/// 保留死代码 + 死合同本身就是负担。
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
/// Bounded recall context, in Unicode characters.
pub const RECALL_CONTEXT_LIMIT: usize = 8000;
/// Marker phrase every notes section of a fused context must carry.
pub const NOTES_TONE_MARKER: &str =
    "本段仅为语气与相处风格参考；禁止照读，禁止据此认定人格。";

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

/// One snapshot entry (contract §2.1). `grounding` is optional for facts and
/// conventionally present for notes; the write side enforces the section
/// category whitelist and the length caps (see `commit`), because clients
/// decode the snapshot strictly and an out-of-contract category would be
/// rejected as a malformed response on their side.
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

fn bounded_chars(raw: &str, limit: usize) -> bool {    raw.chars().count() <= limit
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
/// mapping table. Idempotent DDL, additive only. 为什么连向量表也保留：老数据库
/// 里已经有这些表（甚至已有 vec0 分区），删表或 DROP 会毁掉用户已有的账本；
/// 现在不再写入它们，但结构必须原样留着，好让后续本地实现接手同一份数据。
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

/// Result of a durable snapshot commit (also used for in-transaction replay).
#[derive(Clone, Debug, PartialEq)]
pub struct CompactResult {
    pub revision: i64,
    pub vector_generation: i64,
    pub processed_watermark: i64,
    pub replayed: bool,
}

/// One snapshot entry with the section it belongs to. Kept as a distinct type
/// because the section decides the category whitelist and the stored order of
/// the two sections is the wire order clients read back.
#[derive(Clone, Debug)]
pub struct VecEntry {
    pub section: &'static str,
    pub entry: Entry,
}

/// Everything needed to persist one snapshot atomically.
///
/// 为什么还带 `embedding`：它是快照里冻结的向量元数据字段（模型 + 维度），
/// 客户端严格解码它，且代次一致性校验依赖它；本地实现接手后仍要写同一字段，
/// 只是现在没有代码再去请求向量。
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
}

fn is_primary_key_conflict(error: &rusqlite::Error) -> bool {
    matches!(
        error,
        rusqlite::Error::SqliteFailure(e, _)
            if e.code == rusqlite::ErrorCode::ConstraintViolation
                && e.extended_code == rusqlite::ffi::SQLITE_CONSTRAINT_PRIMARYKEY
    )
}

/// Snapshot write-side shape check: the category whitelist of the frozen
/// sections and the entry length caps. 为什么放在存储层：这些限制原本由
/// provider 输出校验承担，provider 拆掉后如果没人管，坏形状会直接落库，而
/// 客户端读侧是严格解码（未知 category 会被判为畸形响应）。谁写快照都必须
/// 过这一关。
fn validate_entry(entry: &Entry, section: &str) -> Result<()> {
    let categories: &[&str] = match section {
        "facts" => &["fact", "preference"],
        "notes" => &["relationship", "experience"],
        _ => return fail("memory_storage_failed"),
    };
    if !categories.contains(&entry.category.as_str()) {
        return fail("compaction_rejected");
    }
    if entry.id.is_empty() || !bounded_chars(&entry.text, ENTRY_TEXT_LIMIT) {
        return fail("compaction_rejected");
    }
    if entry.text.chars().any(char::is_control) {
        return fail("compaction_rejected");
    }
    if entry
        .observed_at
        .as_deref()
        .is_some_and(|observed| !bounded_chars(observed, OBSERVED_AT_LIMIT))
    {
        return fail("compaction_rejected");
    }
    if entry
        .grounding
        .as_deref()
        .is_some_and(|grounding| !bounded_chars(grounding, GROUNDING_LIMIT))
    {
        return fail("compaction_rejected");
    }
    Ok(())
}

/// Atomically replace a scope's snapshot (contract §2.5).
///
/// Runs inside the caller's transaction (single storage thread). The requestID
/// row is reserved first so two racing commits of the same requestID resolve to
/// a replay instead of double-writing; every later write rolls back together on
/// any failure. The vector partition and `memory_vec_rows` are deliberately not
/// touched: there is no embedding provider any more, and the ledger structure is
/// kept as-is (no DROP, no rewrite) so a future local implementation starts from
/// intact generations.
pub fn commit(transaction: &Transaction<'_>, c: &CompactCommit) -> Result<CompactResult> {
    if !scope_valid(&c.world_id, &c.resident_scope) {
        return fail("invalid_scope");
    }
    if c.processed_watermark < 1 || c.next_watermark <= c.processed_watermark {
        return fail("memory_storage_failed");
    }
    if c.embedding.dimensions == 0 || c.embedding.dimensions > EMBEDDING_DIM_LIMIT {
        return fail("invalid_vector");
    }
    for entry in &c.entries {
        validate_entry(&entry.entry, entry.section)?;
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

    // 向量写入侧已删除：这里不再创建 vec0 分区、不再清空/写入 memory_vec_rows，
    // 也不 DROP 任何已存在的分区。压缩产物（facts/notes）仍然照常落库，快照与
    // 代次账本保持一致，只是不再产生新的向量行。
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

// ---------------------------------------------------------------------------
// Wire request shapes
// ---------------------------------------------------------------------------

// Wire request shapes. Top-level params are strict (`deny_unknown_fields`) so
// a contract typo fails loudly instead of silently dropping a field.
// `TurnRequest` / `PendingRequest` / `IngestRequest` 是原文层的三个请求形状，
// 随原文层一起移除（见 `voicemem-rust-contract.md` 的「已移除」一节）。
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
// Recall context assembly (local only)
// ---------------------------------------------------------------------------

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

/// Deterministic bounded plain-text recall context for the local memory layer.
///
/// 为什么长这样：语义压缩/embedding provider 拆掉后，recall 不再有检索命中，
/// 唯一还能带回去的就是**本地已确认的压缩快照**（原文层已整体移除，所以这里
/// 不再有"未入库缓冲"这一段）。上下文因此必须明确声明"语义检索不可用"，好让
/// 模型不要把本地快照当成检索证据；全新会话（freshSession）才整段恢复快照，
/// 避免每轮重复整段注入。notes 仍然带 tone-only 标记，禁止被照读。
fn build_recall_context(
    fresh_session: bool,
    sections: Option<&Sections>,
    revision: i64,
    vector_generation: i64,
) -> String {
    let budget = RECALL_CONTEXT_LIMIT;
    let mut out = String::new();
    let mut truncated = false;
    append_bounded(
        &mut out,
        budget,
        &mut truncated,
        "语义记忆检索当前不可用：下列内容仅为本地可确认的长期记忆快照，不代表语义检索命中。\n",
    );

    if fresh_session {
        let mut block = String::from("== 新会话恢复 ==\n");
        block.push_str(&format!(
            "已确认长期记忆快照（revision={revision}，vectorGeneration={vector_generation}）：\n",
        ));
        if let Some(sections) = sections {
            if !sections.facts.is_empty() {
                block.push_str("长期事实/偏好：\n");
                for entry in &sections.facts {
                    block.push_str("  * ");
                    block.push_str(&entry.text);
                    block.push('\n');
                }
            }
            if !sections.notes.is_empty() {
                block.push_str(&format!("相处/经验笔记（{NOTES_TONE_MARKER}）：\n"));
                for entry in &sections.notes {
                    block.push_str("  * ");
                    block.push_str(&entry.text);
                    block.push('\n');
                }
            }
        }
        block.push_str("== 新会话恢复结束 ==");
        append_bounded(&mut out, budget, &mut truncated, &block);
    }
    out
}

// ---------------------------------------------------------------------------
// Memory handle (local durable snapshots; 原文层已移除，见模块文档)
// ---------------------------------------------------------------------------

pub struct Memory {
    db: crate::store::Database,
}

impl Memory {
    pub fn new(db: crate::store::Database) -> Self {
        Self { db }
    }

    // -- read-only operations ----------------------------------------------

    /// `memory_status`：只剩本地可用的事实——已提交快照摘要。provider 配置、压缩
    /// 编排状态与易失 pending 计数都随原文层/外部服务一起移除；`pendingTurns`
    /// 恒为 0（保留这个键只是为了不改客户端解码契约，值本身已无来源）。
    pub async fn status(&self, scope: Scope) -> Result<Value> {
        if !scope_valid(&scope.world_id, &scope.resident_scope) {
            return fail("invalid_scope");
        }
        let world_id = scope.world_id.clone();
        let resident_scope = scope.resident_scope.clone();
        let memory = self
            .db
            .call(move |store| status_summary(&store.connection, &world_id, &resident_scope))
            .await?;
        Ok(json!({
            "memory": memory,
            "pendingTurns": 0,
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

    // -- memory_query ------------------------------------------------------

    /// `memory_query`：协议与参数校验保留（客户端仍会用同一形状发请求），但
    /// 外部 embedding provider 拆掉后本 daemon 没有查询向量，也就没有可排序的
    /// 向量命中。这里如实返回 `unconfigured` + 空 results，绝不退化成关键词/
    /// 时间序的假检索——那会让调用方把词法巧合当成语义记忆。
    pub async fn query(
        &self,
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
        Ok(json!({ "status": "unconfigured", "results": [] }))
    }

    // -- memory_recall (local restore only) ---------------------------------

    /// `memory_recall`：请求形状与配额校验保持不变（客户端照旧发 factLimit/
    /// noteLimit），但语义检索那一侧已经不存在——没有 embedding provider 就没有
    /// 查询向量，facts/notes 恒为空数组，status 恒为 `unconfigured`。
    ///
    /// 为什么不做关键词/时间序兜底：合同语义是"检索命中的长期记忆证据"，用词法
    /// 巧合冒充语义命中会让模型把无关内容当成事实。真正还能带回去的是本地可确认
    /// 的东西：**已提交的压缩快照**（原文层已整体移除），且只在 freshSession 时
    /// 整段恢复，并在 context 里明确声明语义检索不可用。
    pub async fn recall(
        &self,
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

        let row = self
            .db
            .call({
                let world_id = world_id.clone();
                let resident_scope = resident_scope.clone();
                move |store| stored_row(&store.connection, &world_id, &resident_scope)
            })
            .await?;
        let (revision, vector_generation, sections) = match row {
            // 没有快照：没有可恢复的已确认内容，revision/代次保持 0。
            None => (0, 0, None),
            Some(row) => (row.revision, row.vector_generation, Some(row.sections)),
        };
        let context = build_recall_context(
            fresh_session,
            sections.as_ref(),
            revision,
            vector_generation,
        );
        Ok(json!({
            "status": "unconfigured",
            "revision": revision,
            "vectorGeneration": vector_generation,
            "facts": [],
            "notes": [],
            "context": context,
            // 原文层已移除：这个键保留只为不改客户端解码契约，值恒为 0
            // （不再有易失缓冲，也就没有"尚未入库的回合"可报）。
            "pendingTurns": 0,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::Database;

    const WORLD_A: &str = "world-a";
    const WORLD_B: &str = "world-b";
    const RESIDENT_A: &str = "resident-a";
    const RESIDENT_B: &str = "resident-b";
    const MODEL: &str = "fixture-model-1";

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
        let dir = std::env::temp_dir().canonicalize().unwrap().join(format!("gmgn-memory-{prefix}-{}", uuid::Uuid::new_v4()));
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

    fn note_entry(text: &str) -> VecEntry {
        VecEntry {
            section: "notes",
            entry: {
                let mut note = entry("experience", text);
                note.observed_at = Some("2026-09-08".into());
                note.grounding = Some("turn:2".into());
                note
            },
        }
    }

    /// One commit operation with the frozen scalar shape; tests that need a bad
    /// shape mutate the returned value.
    fn operation(
        scope: &Scope,
        request_id: &str,
        entries: Vec<VecEntry>,
        processed: i64,
        expected: Option<i64>,
    ) -> CompactCommit {
        CompactCommit {
            world_id: scope.world_id.clone(),
            resident_scope: scope.resident_scope.clone(),
            request_id: request_id.into(),
            expected,
            digest: match expected {
                None => "expected:none".to_owned(),
                Some(generation) => format!("expected:{generation}"),
            },
            processed_watermark: processed,
            next_watermark: processed + 1,
            embedding: EmbeddingRef {
                model: MODEL.into(),
                dimensions: 4,
            },
            entries,
        }
    }

    /// Commit on a bare connection: the transaction commits on success and is
    /// dropped (rolled back) on any rejection, so a failed commit can never
    /// leave half a snapshot behind.
    fn raw_commit(connection: &mut Connection, operation: &CompactCommit) -> Result<CompactResult> {
        let transaction = connection.transaction().map_err(|_| "storage_unavailable")?;
        match commit(&transaction, operation) {
            Ok(result) => {
                transaction.commit().map_err(|_| "storage_unavailable")?;
                Ok(result)
            }
            Err(code) => {
                drop(transaction);
                Err(code)
            }
        }
    }

    /// The local commit pipeline: one transaction writes the snapshot and the
    /// requestID idempotency row. 为什么测试要自己驱动它：provider 拆掉后没有
    /// 生产调用方能造出已确认快照，但本地记忆的读写/恢复行为全都建立在
    /// "快照已提交"之上。（原文层移除后这里不再需要清理易失缓冲，所以返回值
    /// 从 `(CompactResult, usize)` 收敛成 `CompactResult`。）
    async fn commit_snapshot(
        memory: &Memory,
        scope: &Scope,
        request_id: &str,
        entries: Vec<VecEntry>,
        processed: i64,
    ) -> Result<CompactResult> {
        let operation = operation(scope, request_id, entries, processed, None);
        memory
            .db
            .call(move |store| {
                let transaction = store
                    .connection
                    .transaction()
                    .map_err(|_| "storage_unavailable")?;
                let result = commit(&transaction, &operation)?;
                transaction.commit().map_err(|_| "storage_unavailable")?;
                Ok(result)
            })
            .await
    }

    // -- 原文层移除的机械判据（含负对照） -----------------------------------

    /// 原文层移除的**机械判据**：源码里不得再存在"回合原文进缓冲/落库/落盘"的路径。
    ///
    /// 为什么做成独立函数而不是只写注释：这类"删掉了又被加回来"的退化，
    /// 靠 code review 是抓不住的（当初它就是被"等实现接手"的理由留下的）。
    /// 判据必须是**可执行**的，而且必须配一条负对照证明它真的会红 ——
    /// 一个"从不失败"的判据等于没有判据。
    ///
    /// 先剥注释再匹配：被删符号的名字在文档注释里是**应该**出现的（记录"已移除"
    /// 本身就是它的用途），所以只有**代码行**里出现才算违规。
    fn raw_text_layer_violations(source: &str) -> Vec<&'static str> {
        // 逐行剥掉 `//`、`//!`、`///` 之后的部分。本模块没有块注释，
        // 字符串字面量里也没有 `//`，所以行级剥离在这里是安全的。
        let code: String = source
            .lines()
            .map(|line| match line.find("//") {
                Some(at) => &line[..at],
                None => line,
            })
            .collect::<Vec<_>>()
            .join("\n");
        let mut found = Vec::new();
        for (pattern, label) in [
            ("VolatileTurn", "原文层类型 VolatileTurn 又出现了"),
            ("struct Buffer", "原文层缓冲 struct Buffer 又出现了"),
            ("PENDING_TURNS_LIMIT", "原文层上限常量 PENDING_TURNS_LIMIT 又出现了"),
            ("TURN_TEXT_LIMIT", "原文层上限常量 TURN_TEXT_LIMIT 又出现了"),
            ("INGEST_RECEIPTS_LIMIT", "原文层幂等上限 INGEST_RECEIPTS_LIMIT 又出现了"),
            ("FRESH_RESTORE_TURNS", "原文层恢复段常量 FRESH_RESTORE_TURNS 又出现了"),
            ("fn ingest_digest", "原文层内容摘要 fn ingest_digest 又出现了"),
            ("fn clear_covered", "原文层清理 fn clear_covered 又出现了"),
            ("struct TurnRequest", "原文层请求形状 TurnRequest 又出现了"),
            ("struct PendingRequest", "原文层请求形状 PendingRequest 又出现了"),
            ("struct IngestRequest", "原文层请求形状 IngestRequest 又出现了"),
            ("fn ingest(", "原文层写入入口 fn ingest( 又出现了"),
            ("fn turn(", "原文层写入入口 fn turn( 又出现了"),
            ("fn pending(", "原文层读取入口 fn pending( 又出现了"),
        ] {
            if code.contains(pattern) {
                found.push(label);
            }
        }
        found
    }

    /// **② 的验收断言**：源码里不再存在"回合原文落盘/落库"的路径。
    ///
    /// 正对照：真实的**生产代码段**必须 0 违规。
    /// 负对照：把一段原文层代码接回去 ⇒ 判据**必须**报出来。
    ///
    /// 两条必须注意的实现细节（第一版就栽在这里）：
    /// 1. 只对**代码行**判 —— 注释里出现这些名字是应该的（那是在记录"已移除"）。
    /// 2. 只扫 `memory.rs` 的**生产代码段**（测试模块之前那一段）。因为本判据的
    ///    函数体与负对照里**必须**写着这些名字，整文件扫描会把判据自己当成违规。
    ///    扫描范围在**编译期**用 `include_str!` 切好，不依赖运行时的工作目录。
    #[test]
    fn raw_conversation_text_layer_is_gone_and_cannot_come_back_silently() {
        const SOURCE: &str = include_str!("memory.rs");
        // 测试模块的开头就是"生产代码到此为止"的边界。
        let production = SOURCE
            .split("#[cfg(test)]\nmod tests")
            .next()
            .expect("memory.rs 必须可切出生产段");

        let violations = raw_text_layer_violations(production);
        assert!(
            violations.is_empty(),
            "原文层又回到了 memory.rs 的生产代码里：{violations:?}"
        );

        // 注释里提到这些名字**不算**违规（文档要记录"已移除"）。
        let commented = "// VolatileTurn / PENDING_TURNS_LIMIT / struct Buffer / fn ingest(\nfn ok() {}\n";
        assert!(
            raw_text_layer_violations(commented).is_empty(),
            "判据不得把注释里的历史记录当成违规（否则删干净以后反而永远红）"
        );

        // 负对照 1：把易失回合缓冲接回来。
        let restored_buffer =
            format!("{production}\n#[derive(Clone, Debug, Default)]\nstruct Buffer {{ turns: Vec<VolatileTurn> }}\n");
        let found = raw_text_layer_violations(&restored_buffer);
        assert!(
            found.iter().any(|label| label.contains("VolatileTurn")),
            "负对照失败：把 VolatileTurn 接回来竟然没被抓到（found={found:?}）"
        );

        // 负对照 2：把写入入口接回来。
        let restored_write = format!("{production}\npub async fn ingest(&self) {{}}\n");
        let found = raw_text_layer_violations(&restored_write);
        assert!(
            found.iter().any(|label| label.contains("fn ingest(")),
            "负对照失败：把 memory_ingest 写入入口接回来竟然没被抓到（found={found:?}）"
        );

        // 负对照 3：把上限常量接回来。
        let restored_limits = format!("{production}\npub const TURN_TEXT_LIMIT: usize = 2000;\n");
        let found = raw_text_layer_violations(&restored_limits);
        assert!(
            found.iter().any(|label| label.contains("TURN_TEXT_LIMIT")),
            "负对照失败：把 TURN_TEXT_LIMIT 接回来竟然没被抓到（found={found:?}）"
        );
    }

    // -- storage/commit unit tests -----------------------------------------

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
        // 向量行表结构保留但永远为空：写入侧已随 embedding provider 删除，
        // 表本身不做 DROP（老数据库的账本必须原样留着）。
        let vec_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM memory_vec_rows", [], |row| row.get(0))
            .unwrap();
        assert_eq!(vec_rows, 0);
    }

    #[test]
    fn commit_creates_generation_one_and_reads_back_full_snapshot() {
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
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
        let result = raw_commit(
            &mut connection,
            &operation(&scope_a(), &uuid::Uuid::new_v4().to_string(), facts, 2, None),
        )
        .unwrap();
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
        // embedding 是账本字段（模型 + 维度），快照读回必须与写入一致。
        assert_eq!(row.embedding.model, MODEL);
        assert_eq!(row.embedding.dimensions, 4);
        let snapshot = snapshot_value(&row).unwrap();
        assert_eq!(snapshot["schemaVersion"], 1);
        assert_eq!(snapshot["revision"], 1);
        assert_eq!(snapshot["processedWatermark"], 2);
        assert_eq!(snapshot["nextWatermark"], 3);
        assert_eq!(snapshot["embedding"]["model"], MODEL);
        assert_eq!(snapshot["sections"]["facts"][0]["text"], "resident prefers espresso over drip");
        assert_eq!(snapshot["sections"]["facts"][0]["category"], "fact");
        assert_eq!(snapshot["sections"]["facts"][1]["observedAt"], "2026-09-08");
        assert_eq!(snapshot["sections"]["facts"][1]["grounding"], "turn:2");
        // Grounding-optional facts serialize without the key.
        assert!(snapshot["sections"]["facts"][0].get("grounding").is_none());
    }

    #[test]
    fn second_commit_advances_generation_and_replaces_sections() {
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        raw_commit(
            &mut connection,
            &operation(
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![fact_entry("old memory that gets replaced")],
                1,
                None,
            ),
        )
        .unwrap();
        let result = raw_commit(
            &mut connection,
            &operation(
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![note_entry("current memory")],
                2,
                None,
            ),
        )
        .unwrap();
        assert_eq!(result.vector_generation, 2);
        assert_eq!(result.revision, 2);
        let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
        assert_eq!(row.vector_generation, 2);
        assert!(row.sections.facts.is_empty());
        assert_eq!(row.sections.notes[0].text, "current memory");
        // The second commit consumed watermark 2, and next resumed at 3.
        assert_eq!(durable_watermark(&connection, WORLD_A, RESIDENT_A).unwrap(), 3);
    }

    #[test]
    fn commit_rejects_out_of_contract_entries_and_ledger_guards() {
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();

        // 段落与类别白名单：客户端读侧严格解码，坏类别绝不允许落库。
        for bad in [
            VecEntry {
                section: "facts",
                entry: entry("experience", "wrong section"),
            },
            VecEntry {
                section: "notes",
                entry: entry("fact", "wrong section"),
            },
            VecEntry {
                section: "facts",
                entry: entry("fact", &"x".repeat(ENTRY_TEXT_LIMIT + 1)),
            },
            VecEntry {
                section: "facts",
                entry: entry("fact", "bad\ncontrol"),
            },
            VecEntry {
                section: "notes",
                entry: {
                    let mut note = entry("relationship", "grounded");
                    note.grounding = Some("t".repeat(GROUNDING_LIMIT + 1));
                    note
                },
            },
            VecEntry {
                section: "facts",
                entry: {
                    let mut fact = entry("fact", "dated");
                    fact.observed_at = Some("2".repeat(OBSERVED_AT_LIMIT + 1));
                    fact
                },
            },
        ] {
            let error = raw_commit(
                &mut connection,
                &operation(&scope_a(), &uuid::Uuid::new_v4().to_string(), vec![bad], 1, None),
            )
            .unwrap_err();
            assert_eq!(error, "compaction_rejected");
        }

        // 段落计数上限。
        let too_many: Vec<VecEntry> = (0..=FACTS_LIMIT)
            .map(|index| fact_entry(&format!("fact {index}")))
            .collect();
        assert_eq!(
            raw_commit(
                &mut connection,
                &operation(&scope_a(), &uuid::Uuid::new_v4().to_string(), too_many, 1, None),
            )
            .unwrap_err(),
            "compaction_rejected"
        );

        // 账本守卫：水位必须从 1 起且严格前进，维度必须在账本上限内。
        assert_eq!(
            raw_commit(
                &mut connection,
                &operation(&scope_a(), &uuid::Uuid::new_v4().to_string(), vec![fact_entry("x")], 0, None),
            )
            .unwrap_err(),
            "memory_storage_failed"
        );
        let mut backwards = operation(
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("x")],
            2,
            None,
        );
        backwards.next_watermark = 2;
        assert_eq!(
            raw_commit(&mut connection, &backwards).unwrap_err(),
            "memory_storage_failed"
        );
        let mut wide = operation(
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("x")],
            1,
            None,
        );
        wide.embedding.dimensions = EMBEDDING_DIM_LIMIT + 1;
        assert_eq!(raw_commit(&mut connection, &wide).unwrap_err(), "invalid_vector");

        // 失败没有留下任何半截快照。
        assert!(stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().is_none());
    }

    #[test]
    fn stale_generation_cas_and_stale_processed_commit_are_conflicts() {
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        raw_commit(
            &mut connection,
            &operation(
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![fact_entry("first")],
                1,
                None,
            ),
        )
        .unwrap();
        // A new scope with expected != 0 conflicts (current generation is 0).
        assert_eq!(
            raw_commit(
                &mut connection,
                &operation(
                    &scope(WORLD_B, RESIDENT_A),
                    &uuid::Uuid::new_v4().to_string(),
                    vec![fact_entry("conflict")],
                    1,
                    Some(1),
                ),
            )
            .unwrap_err(),
            "memory_conflict"
        );
        // Stale expectedVectorGeneration on an existing generation-1 scope.
        for expected in [Some(0_i64), Some(2_i64)] {
            assert_eq!(
                raw_commit(
                    &mut connection,
                    &operation(
                        &scope_a(),
                        &uuid::Uuid::new_v4().to_string(),
                        vec![fact_entry("stale")],
                        2,
                        expected,
                    ),
                )
                .unwrap_err(),
                "memory_conflict"
            );
        }
        // A late commit whose turns were already processed must conflict even
        // without expectedVectorGeneration (double-processing guard).
        assert_eq!(
            raw_commit(
                &mut connection,
                &operation(
                    &scope_a(),
                    &uuid::Uuid::new_v4().to_string(),
                    vec![fact_entry("duplicate")],
                    1,
                    None,
                ),
            )
            .unwrap_err(),
            "memory_conflict"
        );
        // Nothing was changed by the losers.
        let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
        assert_eq!(row.revision, 1);
        assert_eq!(row.vector_generation, 1);
        assert_eq!(row.sections.facts[0].text, "first");
    }

    #[test]
    fn model_dimension_drift_across_commits_is_a_mismatch() {
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        raw_commit(
            &mut connection,
            &operation(
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![fact_entry("first model")],
                1,
                None,
            ),
        )
        .unwrap();
        let mut drift = operation(
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("drift")],
            2,
            None,
        );
        drift.embedding.model = "different-model".into();
        assert_eq!(
            raw_commit(&mut connection, &drift).unwrap_err(),
            "embedding_dimension_mismatch"
        );
        let mut dimension_drift = operation(
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![fact_entry("drift")],
            2,
            None,
        );
        dimension_drift.embedding.dimensions = 8;
        assert_eq!(
            raw_commit(&mut connection, &dimension_drift).unwrap_err(),
            "embedding_dimension_mismatch"
        );
    }

    #[test]
    fn same_request_id_replays_and_different_digest_conflicts() {
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        let request_id = uuid::Uuid::new_v4().to_string();
        assert_eq!(
            raw_commit(
                &mut connection,
                &operation(&scope_a(), &request_id, vec![fact_entry("only")], 1, None),
            )
            .unwrap()
            .revision,
            1
        );
        // Replaying the same requestID + same digest returns the recorded
        // result and does not advance or rewrite.
        let replay = raw_commit(
            &mut connection,
            &operation(&scope_a(), &request_id, vec![fact_entry("only")], 1, None),
        )
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
        let mut changed = operation(
            &scope_a(),
            &request_id,
            vec![fact_entry("different content")],
            2,
            Some(1),
        );
        assert_eq!(
            raw_commit(&mut connection, &changed).unwrap_err(),
            "memory_request_conflict"
        );
        // Same requestID with the recorded digest replays the recorded result
        // (content is identical), never rewriting or advancing.
        changed.expected = None;
        changed.digest = "expected:none".into();
        assert_eq!(
            raw_commit(&mut connection, &changed).unwrap(),
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
        // A fresh requestID may commit normally afterwards.
        let after = raw_commit(
            &mut connection,
            &operation(
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![fact_entry("fresh")],
                2,
                None,
            ),
        )
        .unwrap();
        assert_eq!(after.revision, 2);
    }

    #[test]
    fn snapshot_survives_reopen_and_update_delete_on_temp_db() {
        let path =
            std::env::temp_dir().canonicalize().unwrap().join(format!("gmgn-memory-file-{}.sqlite", uuid::Uuid::new_v4()));
        {
            let mut connection = Connection::open(&path).unwrap();
            schema(&connection).unwrap();
            raw_commit(
                &mut connection,
                &operation(
                    &scope_a(),
                    &uuid::Uuid::new_v4().to_string(),
                    vec![fact_entry("durable one")],
                    1,
                    None,
                ),
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
            // A later commit replaces (update) the sections.
            raw_commit(
                &mut connection,
                &operation(
                    &scope_a(),
                    &uuid::Uuid::new_v4().to_string(),
                    vec![fact_entry("updated memory")],
                    2,
                    None,
                ),
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
            // Delete: a commit with zero entries empties both sections.
            raw_commit(
                &mut connection,
                &operation(&scope_a(), &uuid::Uuid::new_v4().to_string(), vec![], 3, None),
            )
            .unwrap();
            let row = stored_row(&connection, WORLD_A, RESIDENT_A).unwrap().unwrap();
            assert_eq!(row.revision, 3);
            assert!(row.sections.facts.is_empty() && row.sections.notes.is_empty());
        }
        let _ = std::fs::remove_file(&path);
    }

    /// 老数据库里可能已有旧版本建的 vec0 分区。拆除写入侧后这些分区既不写也不
    /// DROP：升级后 daemon 必须还能打开它、还能提交新快照，而且分区里的旧行
    /// 一行都不能少。sqlite-vec 的 auto-extension 正是为了这种库仍然能打开。
    #[test]
    fn legacy_vec_partitions_are_readable_and_left_untouched() {
        register_vec();
        let mut connection = Connection::open_in_memory().unwrap();
        schema(&connection).unwrap();
        connection
            .execute_batch(
                "CREATE VIRTUAL TABLE \"memory_vec_legacy\" USING vec0(v float32[4] distance_metric=cosine, section text);",
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO \"memory_vec_legacy\" (v, section) VALUES (?1, 'facts')",
                params!["[1.0,0.0,0.0,0.0]"],
            )
            .unwrap();
        raw_commit(
            &mut connection,
            &operation(
                &scope_a(),
                &uuid::Uuid::new_v4().to_string(),
                vec![fact_entry("new snapshot")],
                1,
                None,
            ),
        )
        .unwrap();
        let legacy_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM \"memory_vec_legacy\"", [], |row| row.get(0))
            .unwrap();
        assert_eq!(legacy_rows, 1, "旧分区既不清空也不 DROP");
        let vec_rows: i64 = connection
            .query_row("SELECT COUNT(*) FROM memory_vec_rows", [], |row| row.get(0))
            .unwrap();
        assert_eq!(vec_rows, 0, "映射表结构保留但不再写入");
        assert_eq!(
            stored_row(&connection, WORLD_A, RESIDENT_A)
                .unwrap()
                .unwrap()
                .sections
                .facts[0]
                .text,
            "new snapshot"
        );
    }

    #[test]
    fn scope_validation_rejects_bad_identifiers() {
        assert!(scope_valid("world-a", "resident-a"));
        assert!(!scope_valid("", "resident-a"));
        assert!(!scope_valid("world-a", ""));
        assert!(!scope_valid(" world-a", "resident-a"));
        assert!(!scope_valid("world-a", "resident-a "));
        assert!(!scope_valid("world-a\n", "resident-a"));
        assert!(!scope_valid("w".repeat(201).as_str(), "resident-a"));
        assert!(!scope_valid("world-a", "r".repeat(201).as_str()));
        assert!(identity(&uuid::Uuid::new_v4().to_string().to_uppercase()).is_ok());
        assert!(identity("not-a-uuid").is_err());
    }

    #[tokio::test]
    async fn recall_restores_the_local_snapshot_and_reports_semantics_unavailable() {
        let (_dir, database) = temp_db("recall-local");
        let memory = Memory::new(database);
        commit_snapshot(
            &memory,
            &scope_a(),
            &uuid::Uuid::new_v4().to_string(),
            vec![
                fact_entry("alice likes hiking near the cabin"),
                note_entry("resident speaks in a calm tone when tired"),
            ],
            1,
        )
        .await
        .unwrap();

        // 非全新会话：不整段恢复、也没有检索命中，但仍然如实汇报快照的
        // revision/代次（客户端用它判断本地记忆是否前进过）。
        let non_fresh = memory.recall(scope_a(), "alice hiking", false, None, None).await.unwrap();
        assert_eq!(non_fresh["status"], "unconfigured");
        assert_eq!(non_fresh["revision"], 1);
        assert_eq!(non_fresh["vectorGeneration"], 1);
        assert!(non_fresh["facts"].as_array().unwrap().is_empty());
        assert!(non_fresh["notes"].as_array().unwrap().is_empty());
        let context = non_fresh["context"].as_str().unwrap();
        assert!(context.contains("语义记忆检索当前不可用"));
        assert!(!context.contains("新会话恢复"));
        assert!(!context.contains("alice likes hiking near the cabin"));

        // 全新会话：整段恢复**已确认的压缩快照**，并且仍然声明语义检索不可用
        // ——恢复不是检索命中。（原文层移除后这里不再有"易失回合"那一段，
        // 所以 `pendingTurns` 恒为 0、context 里也不该出现未入库文本。）
        let fresh = memory.recall(scope_a(), "anything", true, Some(1), Some(1)).await.unwrap();
        assert_eq!(fresh["status"], "unconfigured");
        assert_eq!(fresh["pendingTurns"], 0, "原文层已移除：不再有未入库回合");
        let context = fresh["context"].as_str().unwrap();
        assert!(context.chars().count() <= RECALL_CONTEXT_LIMIT);
        assert!(context.contains("新会话恢复"));
        assert!(context.contains("alice likes hiking near the cabin"));
        assert!(context.contains("resident speaks in a calm tone when tired"));
        assert!(context.contains(NOTES_TONE_MARKER), "notes 必须带 tone-only 标记");
        assert!(context.contains("语义记忆检索当前不可用"));
        assert!(
            !context.contains("尚未入库的近期回合"),
            "原文层已移除：context 不得再提到未入库缓冲（那会宣称一份不存在的数据）"
        );

        // 另一个 scope 没有已确认内容：revision/代次保持 0，也不越界读别人的快照。
        let other = memory
            .recall(scope(WORLD_A, RESIDENT_B), "anything", true, None, None)
            .await
            .unwrap();
        assert_eq!(other["revision"], 0);
        assert_eq!(other["vectorGeneration"], 0);
        assert_eq!(other["pendingTurns"], 0);
        assert!(!other["context"].as_str().unwrap().contains("alice likes hiking"));
    }

    #[tokio::test]
    async fn recall_validates_query_and_lane_quotas() {
        let (_dir, database) = temp_db("recall-invalid");
        let memory = Memory::new(database);
        assert_eq!(
            memory.recall(scope_a(), "  ", false, None, None).await.unwrap_err(),
            "invalid_query"
        );
        assert_eq!(
            memory
                .recall(scope_a(), &"q".repeat(QUERY_TEXT_LIMIT + 1), false, None, None)
                .await
                .unwrap_err(),
            "invalid_query"
        );
        assert_eq!(
            memory
                .recall(scope_a(), "q", false, Some(RECALL_FACT_LIMIT_MAX + 1), None)
                .await
                .unwrap_err(),
            "invalid_topk"
        );
        assert_eq!(
            memory
                .recall(scope_a(), "q", false, None, Some(RECALL_NOTE_LIMIT_MAX + 1))
                .await
                .unwrap_err(),
            "invalid_topk"
        );
        assert_eq!(
            memory.recall(scope_a(), "q", false, Some(0), None).await.unwrap_err(),
            "invalid_topk"
        );
        assert_eq!(
            memory
                .recall(scope("", RESIDENT_A), "q", false, None, None)
                .await
                .unwrap_err(),
            "invalid_scope"
        );
    }
}
