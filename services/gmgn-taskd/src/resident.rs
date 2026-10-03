//! World/resident scoped durable state, event stream, and message inbox.
//!
//! This module adds a second persistent layer beside the job store: states are
//! CAS-updated JSON objects keyed by `(worldID, residentScope, domain, key)`,
//! and every `state_commit` atomically appends the same-scope event/message
//! attachments that travel with it. Reads and writes all go through the one
//! `taskd-storage` writer thread; functions here only implement SQL on a
//! `Connection`/`Transaction` and never open a second database.
//!
//! Revision rules (frozen 2026-09-08 with the main agent):
//! - revision counts successful commits, not value versions: every new
//!   `requestID` whose CAS succeeds advances the revision by one, even when
//!   the value is unchanged and only attachments are new;
//! - same `requestID` + identical content replays the recorded revision
//!   without reapplying, and same `requestID` + different content conflicts;
//! - `expectedRevision` must equal the current revision (0 creates);
//! - an event/message `id` is unique inside one scope: same id + same
//!   kind+payload is idempotent, same id + different content conflicts;
//! - ids are free to repeat across different scopes.
//!
//! Nothing here deletes events: v1 keeps every fact and leaves pruning to a
//! future explicit contract change. Sequences are global AUTOINCREMENT values
//! but every query filters strictly by scope.

use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

/// Max serialized size of a state value (JSON object), 256 KiB.
pub const STATE_VALUE_LIMIT: usize = 256 * 1024;
/// Max serialized size of one event/message payload (JSON object).
pub const PAYLOAD_LIMIT: usize = 256 * 1024;
pub const DEFAULT_READ_LIMIT: usize = 100;
pub const MAX_READ_LIMIT: usize = 500;
/// Length cap shared by scope parts, keys, ids, request ids and kinds.
pub const TOKEN_LIMIT: usize = 200;

pub const DOMAINS: [&str; 5] = ["resident", "world", "wish", "inbox", "conversation"];
pub const CONSUMERS: [&str; 3] = ["world", "ui", "agent"];

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Error {
    pub code: &'static str,
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code)
    }
}
impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self {
            code: "resident_storage_failed",
        }
    }
}
pub type Result<T> = std::result::Result<T, Error>;

fn error(code: &'static str) -> Error {
    Error { code }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Scope {
    #[serde(rename = "worldID")]
    pub world_id: String,
    #[serde(rename = "residentScope")]
    pub resident_scope: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub revision: i64,
    pub value: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CommitResult {
    pub revision: i64,
    pub replayed: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub kind: String,
    pub payload: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StoredEvent {
    pub sequence: i64,
    pub id: String,
    pub kind: String,
    pub payload: Value,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct StoredMessage {
    pub sequence: i64,
    pub id: String,
    pub kind: String,
    pub payload: Value,
}

// Wire request shapes. Top-level params are strict so a contract typo fails
// loudly instead of silently dropping a field; item-level extra fields are
// ignored, matching how message items were treated before.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateReadRequest {
    pub scope: Scope,
    pub domain: String,
    pub key: String,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct CommitRequest {
    pub scope: Scope,
    pub domain: String,
    pub key: String,
    pub expected_revision: i64,
    #[serde(rename = "requestID")]
    pub request_id: String,
    pub value: Value,
    #[serde(default)]
    pub events: Vec<Item>,
    #[serde(default)]
    pub messages: Vec<Item>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct EventReadRequest {
    pub scope: Scope,
    pub after: Option<i64>,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MessageReadRequest {
    pub scope: Scope,
    pub consumer: String,
    pub after: Option<i64>,
    pub limit: Option<usize>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AckRequest {
    pub scope: Scope,
    pub consumer: String,
    pub id: String,
}

/// v2 schema: resident state/events/messages plus their per-consumer acks.
/// Idempotent (`IF NOT EXISTS`) so it can be run against an existing v1
/// database after the base schema migration.
pub fn schema(connection: &Connection) -> Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS resident_states (
            world_id TEXT NOT NULL,
            resident_scope TEXT NOT NULL,
            domain TEXT NOT NULL,
            key TEXT NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 1),
            value TEXT NOT NULL,
            updated_at_ms INTEGER NOT NULL,
            PRIMARY KEY (world_id, resident_scope, domain, key)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS resident_requests (
            world_id TEXT NOT NULL,
            resident_scope TEXT NOT NULL,
            domain TEXT NOT NULL,
            key TEXT NOT NULL,
            request_id TEXT NOT NULL,
            revision INTEGER NOT NULL,
            hash TEXT NOT NULL,
            committed_at_ms INTEGER NOT NULL,
            PRIMARY KEY (world_id, resident_scope, domain, key, request_id)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS resident_events (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            world_id TEXT NOT NULL,
            resident_scope TEXT NOT NULL,
            id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload TEXT NOT NULL,
            UNIQUE (world_id, resident_scope, id)
        );
        CREATE INDEX IF NOT EXISTS resident_events_scope_sequence
            ON resident_events(world_id, resident_scope, sequence);
        CREATE TABLE IF NOT EXISTS resident_messages (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            world_id TEXT NOT NULL,
            resident_scope TEXT NOT NULL,
            id TEXT NOT NULL,
            kind TEXT NOT NULL,
            payload TEXT NOT NULL,
            UNIQUE (world_id, resident_scope, id)
        );
        CREATE INDEX IF NOT EXISTS resident_messages_scope_sequence
            ON resident_messages(world_id, resident_scope, sequence);
        CREATE TABLE IF NOT EXISTS resident_message_acks (
            world_id TEXT NOT NULL,
            resident_scope TEXT NOT NULL,
            sequence INTEGER NOT NULL REFERENCES resident_messages(sequence),
            consumer TEXT NOT NULL CHECK (consumer IN ('world', 'ui', 'agent')),
            PRIMARY KEY (world_id, resident_scope, sequence, consumer)
        ) WITHOUT ROWID;",
    )?;
    Ok(())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

pub fn validate_scope(world_id: &str, resident_scope: &str) -> Result<()> {
    for value in [world_id, resident_scope] {
        bounded(value, "invalid_scope")?;
    }
    Ok(())
}

fn validate_domain(domain: &str) -> Result<()> {
    if DOMAINS.contains(&domain) {
        Ok(())
    } else {
        Err(error("invalid_domain"))
    }
}

fn validate_consumer(consumer: &str) -> Result<()> {
    if CONSUMERS.contains(&consumer) {
        Ok(())
    } else {
        Err(error("invalid_consumer"))
    }
}

fn bounded(raw: &str, code: &'static str) -> Result<String> {
    if raw.is_empty()
        || raw.len() > TOKEN_LIMIT
        || raw.trim() != raw
        || raw.chars().any(char::is_control)
    {
        return Err(error(code));
    }
    Ok(raw.to_owned())
}

fn identity(raw: &str, code: &'static str) -> Result<String> {
    let value = bounded(raw, code)?;
    // UUID-shaped ids are canonicalized to lowercase hyphenated so retries and
    // acks match regardless of client casing; opaque ids are kept verbatim.
    Ok(uuid::Uuid::parse_str(&value)
        .map(|u| u.hyphenated().to_string())
        .unwrap_or(value))
}

fn object_text(payload: &Value, invalid: &'static str, limit: usize) -> Result<String> {
    if !payload.is_object() {
        return Err(error(invalid));
    }
    let text = serde_json::to_string(payload).map_err(|_| error(invalid))?;
    if text.len() > limit {
        return Err(error(if invalid == "invalid_state_value" {
            "state_value_too_large"
        } else if invalid == "invalid_event_payload" {
            "event_payload_too_large"
        } else {
            "message_payload_too_large"
        }));
    }
    Ok(text)
}

/// Normalized event/message entry ready for comparison and insertion.
struct Entry {
    id: String,
    kind: String,
    payload: String,
}

fn event_entry(item: &Item) -> Result<Entry> {
    Ok(Entry {
        id: identity(&item.id, "invalid_event_id")?,
        kind: bounded(&item.kind, "invalid_event_kind")?,
        payload: object_text(&item.payload, "invalid_event_payload", PAYLOAD_LIMIT)?,
    })
}

fn message_entry(item: &Item) -> Result<Entry> {
    Ok(Entry {
        id: identity(&item.id, "invalid_message_id")?,
        kind: bounded(&item.kind, "invalid_message_kind")?,
        payload: object_text(&item.payload, "invalid_message_payload", PAYLOAD_LIMIT)?,
    })
}

/// Deterministic content fingerprint for request-id idempotency. The state
/// value is canonical JSON (object key order is normalized by serde_json), and
/// attachments are recorded in the order the client provided them.
fn content_digest(request: &CommitRequest) -> Result<String> {
    let mut hasher = Sha256::new();
    let mut body = Vec::new();
    body.extend_from_slice(
        &serde_json::to_vec(&request.value).map_err(|_| error("invalid_state_value"))?,
    );
    for item in &request.events {
        let entry = event_entry(item)?;
        body.extend_from_slice(entry.id.as_bytes());
        body.extend_from_slice(entry.kind.as_bytes());
        body.extend_from_slice(entry.payload.as_bytes());
    }
    for item in &request.messages {
        let entry = message_entry(item)?;
        body.extend_from_slice(entry.id.as_bytes());
        body.extend_from_slice(entry.kind.as_bytes());
        body.extend_from_slice(entry.payload.as_bytes());
    }
    hasher.update(body);
    Ok(format!("{:x}", hasher.finalize()))
}

pub fn read_state(
    connection: &Connection,
    scope: &Scope,
    domain: &str,
    key: &str,
) -> Result<Option<Record>> {
    validate_scope(&scope.world_id, &scope.resident_scope)?;
    validate_domain(domain)?;
    let key = bounded(key, "invalid_state_key")?;
    let row: Option<(i64, String)> = connection
        .query_row(
            "SELECT revision, value FROM resident_states
             WHERE world_id=?1 AND resident_scope=?2 AND domain=?3 AND key=?4",
            params![scope.world_id, scope.resident_scope, domain, key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    row.map(|(revision, value)| {
        Ok(Record {
            revision,
            value: serde_json::from_str(&value)
                .map_err(|_| error("resident_history_unavailable"))?,
        })
    })
    .transpose()
}

/// Atomic state CAS + event/message attachment commit. Runs inside the
/// transaction handed in by the single writer thread; on error the caller
/// rolls the transaction back and nothing is persisted.
pub fn commit(transaction: &Transaction<'_>, request: &CommitRequest) -> Result<CommitResult> {
    validate_scope(&request.scope.world_id, &request.scope.resident_scope)?;
    validate_domain(&request.domain)?;
    let key = bounded(&request.key, "invalid_state_key")?;
    let request_id = identity(&request.request_id, "invalid_request_id")?;
    if request.expected_revision < 0 {
        return Err(error("invalid_revision"));
    }
    if !request.value.is_object() {
        return Err(error("invalid_state_value"));
    }
    // Normalize attachments before touching the database so a malformed item
    // fails fast and rolls nothing back.
    let value = serde_json::to_string(&request.value).map_err(|_| error("invalid_state_value"))?;
    if value.len() > STATE_VALUE_LIMIT {
        return Err(error("state_value_too_large"));
    }
    let events: Vec<Entry> = request
        .events
        .iter()
        .map(event_entry)
        .collect::<Result<_>>()?;
    let messages: Vec<Entry> = request
        .messages
        .iter()
        .map(message_entry)
        .collect::<Result<_>>()?;
    let hash = content_digest(request)?;
    let scope = (&request.scope.world_id, &request.scope.resident_scope);

    // requestID idempotency: replay the recorded result, do not reapply.
    let recorded: Option<(i64, String)> = transaction
        .query_row(
            "SELECT revision, hash FROM resident_requests
             WHERE world_id=?1 AND resident_scope=?2 AND domain=?3 AND key=?4 AND request_id=?5",
            params![scope.0, scope.1, request.domain, key, request_id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if let Some((revision, previous)) = recorded {
        if previous != hash {
            return Err(error("request_id_conflict"));
        }
        return Ok(CommitResult {
            revision,
            replayed: true,
        });
    }

    // CAS against the current revision.
    let current: Option<(i64, String)> = transaction
        .query_row(
            "SELECT revision, value FROM resident_states
             WHERE world_id=?1 AND resident_scope=?2 AND domain=?3 AND key=?4",
            params![scope.0, scope.1, request.domain, key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    // Revision counts successful commits, not value versions: any new
    // requestID whose CAS passes advances it by one, even when the value is
    // unchanged and only the attachments differ. A stale expectedRevision can
    // therefore never slip in behind another writer that committed the same
    // value.
    let revision = match &current {
        None => {
            if request.expected_revision != 0 {
                return Err(error("revision_conflict"));
            }
            1
        }
        Some((current_revision, _)) => {
            if request.expected_revision != *current_revision {
                return Err(error("revision_conflict"));
            }
            *current_revision + 1
        }
    };

    let append = |entry: &Entry, table: &str, conflict: &'static str| -> Result<()> {
        let existing: Option<(String, String)> = transaction
            .query_row(
                &format!(
                    "SELECT kind, payload FROM {table}
                     WHERE world_id=?1 AND resident_scope=?2 AND id=?3"
                ),
                params![scope.0, scope.1, entry.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        match existing {
            None => {
                transaction.execute(
                    &format!(
                        "INSERT INTO {table} (world_id, resident_scope, id, kind, payload)
                         VALUES (?1, ?2, ?3, ?4, ?5)"
                    ),
                    params![scope.0, scope.1, entry.id, entry.kind, entry.payload],
                )?;
                Ok(())
            }
            Some((kind, payload)) => {
                if kind != entry.kind || payload != entry.payload {
                    Err(error(conflict))
                } else {
                    Ok(())
                }
            }
        }
    };
    for entry in &events {
        append(entry, "resident_events", "event_id_conflict")?;
    }
    for entry in &messages {
        append(entry, "resident_messages", "message_id_conflict")?;
    }

    match current {
        None => {
            transaction.execute(
                "INSERT INTO resident_states
                    (world_id, resident_scope, domain, key, revision, value, updated_at_ms)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    scope.0,
                    scope.1,
                    request.domain,
                    key,
                    revision,
                    value,
                    now_ms()
                ],
            )?;
        }
        Some(_) => {
            // The revision always advanced above, so the row is rewritten even
            // when the value is byte-identical.
            transaction.execute(
                "UPDATE resident_states
                 SET revision=?5, value=?6, updated_at_ms=?7
                 WHERE world_id=?1 AND resident_scope=?2 AND domain=?3 AND key=?4",
                params![
                    scope.0,
                    scope.1,
                    request.domain,
                    key,
                    revision,
                    value,
                    now_ms()
                ],
            )?;
        }
    }

    transaction.execute(
        "INSERT INTO resident_requests
            (world_id, resident_scope, domain, key, request_id, revision, hash, committed_at_ms)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        params![
            scope.0,
            scope.1,
            request.domain,
            key,
            request_id,
            revision,
            hash,
            now_ms()
        ],
    )?;
    Ok(CommitResult {
        revision,
        replayed: false,
    })
}

/// Resolve the `after` watermark and `limit` from wire params. `after` is the
/// only read boundary (no opaque cursor): it defaults to 0 and must be a
/// non-negative sequence.
pub fn read_window(after: Option<i64>, limit: Option<usize>) -> Result<(i64, usize)> {
    let after = after.unwrap_or(0);
    if after < 0 {
        return Err(error("invalid_cursor"));
    }
    let limit = limit.unwrap_or(DEFAULT_READ_LIMIT);
    if limit < 1 {
        return Err(error("invalid_limit"));
    }
    if limit > MAX_READ_LIMIT {
        return Err(error("limit_exceeded"));
    }
    Ok((after, limit))
}

fn check_read(after: i64, limit: usize) -> Result<()> {
    if after < 0 {
        return Err(error("invalid_cursor"));
    }
    if limit < 1 {
        return Err(error("invalid_limit"));
    }
    if limit > MAX_READ_LIMIT {
        return Err(error("limit_exceeded"));
    }
    Ok(())
}

fn read_row(
    row: &rusqlite::Row<'_>,
    payload_column: usize,
) -> rusqlite::Result<(i64, String, String, Value)> {
    let payload: String = row.get(payload_column)?;
    let payload = serde_json::from_str(&payload).map_err(|e| {
        rusqlite::Error::FromSqlConversionFailure(
            payload_column,
            rusqlite::types::Type::Text,
            Box::new(e),
        )
    })?;
    Ok((row.get(0)?, row.get(1)?, row.get(2)?, payload))
}

/// Read one scope's event stream after a sequence boundary. `nextCursor` is
/// always returned as the caller's watermark: the last returned sequence, or
/// the requested `after` when no row matched. Pollers advance `after` to it on
/// every read; events are append-only, so this is exactly the high-water mark
/// even when the page is empty.
pub fn read_events(
    connection: &Connection,
    scope: &Scope,
    after: i64,
    limit: usize,
) -> Result<(Vec<StoredEvent>, i64)> {
    validate_scope(&scope.world_id, &scope.resident_scope)?;
    check_read(after, limit)?;
    let mut statement = connection.prepare(
        "SELECT sequence, id, kind, payload FROM resident_events
         WHERE world_id=?1 AND resident_scope=?2 AND sequence>?3
         ORDER BY sequence LIMIT ?4",
    )?;
    let mut rows = statement.query(params![
        scope.world_id,
        scope.resident_scope,
        after,
        limit as i64
    ])?;
    let mut events = Vec::new();
    while let Some(row) = rows.next()? {
        let (sequence, id, kind, payload) = read_row(row, 3)?;
        events.push(StoredEvent {
            sequence,
            id,
            kind,
            payload,
        });
    }
    let watermark = events.last().map_or(after, |event| event.sequence);
    Ok((events, watermark))
}

/// Read unacknowledged messages of one consumer inside a scope. Sequences are
/// the same stream for all three consumers; each consumer independently tracks
/// its own acks. The integer `nextCursor` watermark matches `read_events`.
pub fn read_messages(
    connection: &Connection,
    scope: &Scope,
    consumer: &str,
    after: i64,
    limit: usize,
) -> Result<(Vec<StoredMessage>, i64)> {
    validate_scope(&scope.world_id, &scope.resident_scope)?;
    validate_consumer(consumer)?;
    check_read(after, limit)?;
    let mut statement = connection.prepare(
        "SELECT m.sequence, m.id, m.kind, m.payload FROM resident_messages m
         WHERE m.world_id=?1 AND m.resident_scope=?2 AND m.sequence>?3
           AND NOT EXISTS (
               SELECT 1 FROM resident_message_acks a
               WHERE a.world_id=m.world_id AND a.resident_scope=m.resident_scope
                 AND a.sequence=m.sequence AND a.consumer=?4)
         ORDER BY m.sequence LIMIT ?5",
    )?;
    let mut rows = statement.query(params![
        scope.world_id,
        scope.resident_scope,
        after,
        consumer,
        limit as i64
    ])?;
    let mut messages = Vec::new();
    while let Some(row) = rows.next()? {
        let (sequence, id, kind, payload) = read_row(row, 3)?;
        messages.push(StoredMessage {
            sequence,
            id,
            kind,
            payload,
        });
    }
    let watermark = messages.last().map_or(after, |message| message.sequence);
    Ok((messages, watermark))
}

/// Acknowledge one message for one consumer. Only messages that exist in the
/// same scope may be acknowledged; repeating an ack is idempotent.
pub fn ack(transaction: &Transaction<'_>, scope: &Scope, consumer: &str, id: &str) -> Result<()> {
    validate_scope(&scope.world_id, &scope.resident_scope)?;
    validate_consumer(consumer)?;
    let id = identity(id, "invalid_message_id")?;
    let sequence: Option<i64> = transaction
        .query_row(
            "SELECT sequence FROM resident_messages
             WHERE world_id=?1 AND resident_scope=?2 AND id=?3",
            params![scope.world_id, scope.resident_scope, id],
            |row| row.get(0),
        )
        .optional()?;
    let sequence = sequence.ok_or(error("message_not_found"))?;
    transaction.execute(
        "INSERT INTO resident_message_acks (world_id, resident_scope, sequence, consumer)
         VALUES (?1, ?2, ?3, ?4) ON CONFLICT DO NOTHING",
        params![scope.world_id, scope.resident_scope, sequence, consumer],
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use uuid::Uuid;

    const WORLD_A: &str = "world-a";
    const RESIDENT_A: &str = "resident-a";

    fn setup(connection: &Connection) {
        schema(connection).unwrap();
    }

    fn scope(world: &str, resident: &str) -> Scope {
        Scope {
            world_id: world.into(),
            resident_scope: resident.into(),
        }
    }

    fn scope_a() -> Scope {
        scope(WORLD_A, RESIDENT_A)
    }

    fn request(world: &str, resident: &str) -> CommitRequest {
        CommitRequest {
            scope: scope(world, resident),
            domain: "resident".into(),
            key: "mood".into(),
            expected_revision: 0,
            request_id: Uuid::new_v4().to_string(),
            value: json!({"state": "content"}),
            events: vec![],
            messages: vec![],
        }
    }

    fn request_a() -> CommitRequest {
        request(WORLD_A, RESIDENT_A)
    }

    fn send(connection: &mut Connection, request: &CommitRequest) -> CommitResult {
        let transaction = connection.transaction().unwrap();
        let result = commit(&transaction, request).unwrap();
        transaction.commit().unwrap();
        result
    }

    fn send_err(connection: &mut Connection, request: &CommitRequest) -> &'static str {
        let transaction = connection.transaction().unwrap();
        let code = commit(&transaction, request).unwrap_err().code;
        drop(transaction);
        code
    }

    #[test]
    fn schema_is_idempotent_and_creates_all_resident_tables() {
        let connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        setup(&connection);
        let names: Vec<String> = connection
            .prepare(
                "SELECT name FROM sqlite_master
                 WHERE type='table' AND name LIKE 'resident\\_%' ESCAPE '\\'
                 ORDER BY name",
            )
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<rusqlite::Result<_>>()
            .unwrap();
        assert_eq!(
            names,
            vec![
                "resident_events",
                "resident_message_acks",
                "resident_messages",
                "resident_requests",
                "resident_states",
            ]
        );
    }

    #[test]
    fn create_read_update_and_stale_cas_are_rejected() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let mut request = request_a();
        let created = send(&mut connection, &request);
        assert_eq!(
            created,
            CommitResult {
                revision: 1,
                replayed: false
            }
        );
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.revision, 1);
        assert_eq!(record.value, json!({"state": "content"}));

        // Creating an already-existing key with expectedRevision=0 conflicts
        // when it is a genuinely new request (same request id would replay).
        request.request_id = Uuid::new_v4().to_string();
        assert_eq!(send_err(&mut connection, &request), "revision_conflict");
        // A stale expectedRevision conflicts while the current revision is 1.
        request.expected_revision = 2;
        request.request_id = Uuid::new_v4().to_string();
        assert_eq!(send_err(&mut connection, &request), "revision_conflict");
        request.expected_revision = 3;
        assert_eq!(send_err(&mut connection, &request), "revision_conflict");
        // The correct CAS advances the revision.
        request.expected_revision = 1;
        request.value = json!({"state": "ready"});
        let updated = send(&mut connection, &request);
        assert_eq!(updated.revision, 2);
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.value, json!({"state": "ready"}));
        // Missing key with a nonzero expectedRevision conflicts.
        let mut other = request_a();
        other.key = "missing".into();
        other.expected_revision = 3;
        assert_eq!(send_err(&mut connection, &other), "revision_conflict");
    }

    #[test]
    fn same_value_with_a_new_request_still_advances_revision() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let mut first = request_a();
        first.events = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "resident.awake".into(),
            payload: json!({"at": 1}),
        }];
        assert_eq!(send(&mut connection, &first).revision, 1);
        // A new requestID writes the same value but appends a new fact: the
        // commit succeeds and revision advances even though value is unchanged.
        let mut second = request_a();
        second.expected_revision = 1;
        second.request_id = Uuid::new_v4().to_string();
        second.events = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "resident.pondered".into(),
            payload: json!({"at": 2}),
        }];
        let result = send(&mut connection, &second);
        assert_eq!(
            result,
            CommitResult {
                revision: 2,
                replayed: false
            }
        );
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.revision, 2);
        assert_eq!(record.value, json!({"state": "content"}));
        let (events, _) = read_events(&connection, &scope_a(), 0, 100).unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(events[1].kind, "resident.pondered");
    }

    #[test]
    fn same_request_id_replays_revision_and_different_content_conflicts() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let mut request = request_a();
        request.request_id = "29B7E2F3-4D44-47E0-9D66-0C5E08C8C6AC".to_string();
        // Two-key object typed with keys in one order; the retry below uses the
        // opposite textual order and must still count as identical content.
        request.value = serde_json::from_str(r#"{"alpha": 1, "state": "content"}"#).unwrap();
        request.events = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "wish.claimed".into(),
            payload: json!({"by": "resident"}),
        }];
        let first = send(&mut connection, &request);
        assert_eq!(first.revision, 1);
        // Retry with identical content in a different JSON key order.
        request.value = serde_json::from_str(r#"{"state": "content", "alpha": 1}"#).unwrap();
        let replay = send(&mut connection, &request);
        assert_eq!(
            replay,
            CommitResult {
                revision: 1,
                replayed: true
            }
        );
        let (events, _) = read_events(&connection, &scope_a(), 0, 100).unwrap();
        assert_eq!(events.len(), 1, "replay must not append events again");
        // Same request id but different content conflicts and rolls back.
        request.value = json!({"state": "conflict"});
        let code = send_err(&mut connection, &request);
        assert_eq!(code, "request_id_conflict");
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.revision, 1);
        assert_eq!(record.value, json!({"alpha": 1, "state": "content"}));
    }

    #[test]
    fn duplicate_ids_conflict_only_when_content_differs_and_are_scoped() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let id = Uuid::new_v4().to_string();
        let mut commit = request_a();
        commit.events = vec![Item {
            id: id.clone(),
            kind: "wish.placed".into(),
            payload: json!({"at": [1, 2, 3]}),
        }];
        assert_eq!(send(&mut connection, &commit).revision, 1);
        // Same event id with different content in the same scope conflicts.
        let mut retry = request_a();
        retry.expected_revision = 1;
        retry.events = vec![Item {
            id: id.clone(),
            kind: "wish.placed".into(),
            payload: json!({"at": [9, 9, 9]}),
        }];
        assert_eq!(send_err(&mut connection, &retry), "event_id_conflict");
        // The same id with identical content is idempotent for the event
        // stream, but the fresh requestID still counts as a successful commit
        // and advances the revision.
        let mut again = request_a();
        again.expected_revision = 1;
        again.events = vec![Item {
            id: id.clone(),
            kind: "wish.placed".into(),
            payload: json!({"at": [1, 2, 3]}),
        }];
        assert_eq!(send(&mut connection, &again).revision, 2);
        let (events, _) = read_events(&connection, &scope_a(), 0, 100).unwrap();
        assert_eq!(events.len(), 1);
        // The same id is free in a different scope with different content.
        let mut other_scope = request("world-b", "resident-a");
        other_scope.events = vec![Item {
            id: id.clone(),
            kind: "wish.placed".into(),
            payload: json!({"at": [4, 5, 6]}),
        }];
        assert_eq!(send(&mut connection, &other_scope).revision, 1);
        assert_eq!(
            read_events(&connection, &other_scope.scope, 0, 100)
                .unwrap()
                .0
                .len(),
            1
        );
        // Messages follow the same rules (current revision is 2 after "again").
        let mut message_commit = request_a();
        message_commit.expected_revision = 2;
        message_commit.request_id = Uuid::new_v4().to_string();
        message_commit.messages = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "wish.outputReady".into(),
            payload: json!({"path": "model.glb"}),
        }];
        let message = send(&mut connection, &message_commit);
        assert_eq!(message.revision, 3);
        let mut changed = request_a();
        changed.expected_revision = 3;
        changed.request_id = Uuid::new_v4().to_string();
        changed.messages = vec![Item {
            id: message_commit.messages[0].id.clone(),
            kind: "wish.outputReady".into(),
            payload: json!({"path": "different.glb"}),
        }];
        assert_eq!(send_err(&mut connection, &changed), "message_id_conflict");
    }

    #[test]
    fn events_messages_and_state_are_isolated_by_scope() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let event = Item {
            id: Uuid::new_v4().to_string(),
            kind: "world.observed".into(),
            payload: json!({"noise": true}),
        };
        let message = Item {
            id: Uuid::new_v4().to_string(),
            kind: "wish.placed".into(),
            payload: json!({"prop": "clock"}),
        };
        let mut commit = request_a();
        commit.events = vec![event.clone()];
        commit.messages = vec![message.clone()];
        send(&mut connection, &commit);
        // A sibling resident in the same world owns its own rows; the original
        // scope is untouched and cannot see the sibling's stream either.
        let mut sibling = request(WORLD_A, "resident-b");
        sibling.events = vec![event.clone()];
        sibling.messages = vec![message.clone()];
        assert_eq!(send(&mut connection, &sibling).revision, 1);
        let sibling_scope = sibling.scope.clone();
        let record = read_state(&connection, &sibling_scope, "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.revision, 1, "sibling got its own state row");
        let (events, _) = read_events(&connection, &sibling_scope, 0, 100).unwrap();
        assert_eq!(events.len(), 1, "sibling only sees its own event");
        assert_eq!(events[0].kind, "world.observed");
        let (messages, _) = read_messages(&connection, &sibling_scope, "agent", 0, 100).unwrap();
        assert_eq!(messages.len(), 1);
        // The original scope still has its own single event/message and state.
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.revision, 1);
        assert_eq!(record.value, json!({"state": "content"}));
        assert_eq!(
            read_events(&connection, &scope_a(), 0, 100)
                .unwrap()
                .0
                .len(),
            1
        );
        // A different world with the same resident scope is fully separate.
        let foreign = scope("world-z", RESIDENT_A);
        assert!(read_state(&connection, &foreign, "resident", "mood")
            .unwrap()
            .is_none());
        assert!(read_events(&connection, &foreign, 0, 100)
            .unwrap()
            .0
            .is_empty());
        assert!(read_messages(&connection, &foreign, "agent", 0, 100)
            .unwrap()
            .0
            .is_empty());
    }

    #[test]
    fn message_consumers_are_independent_and_acks_survive_reopen() {
        let path = std::env::temp_dir().canonicalize().unwrap().join(format!("gmgn-resident-{}.sqlite", Uuid::new_v4()));
        let message_id;
        let sequence;
        {
            let mut connection = Connection::open(&path).unwrap();
            setup(&connection);
            let mut commit = request_a();
            commit.messages = vec![Item {
                id: Uuid::new_v4().to_string(),
                kind: "wish.placed".into(),
                payload: json!({"prop": "chair"}),
            }];
            let result = send(&mut connection, &commit);
            assert_eq!(result.revision, 1);
            message_id = commit.messages[0].id.clone();
            sequence = read_messages(&connection, &scope_a(), "ui", 0, 100)
                .unwrap()
                .0[0]
                .sequence;
            for consumer in ["world", "ui", "agent"] {
                let (messages, _) =
                    read_messages(&connection, &scope_a(), consumer, 0, 100).unwrap();
                assert_eq!(messages.len(), 1, "{consumer}");
            }
            let transaction = connection.transaction().unwrap();
            ack(&transaction, &scope_a(), "ui", &message_id).unwrap();
            ack(&transaction, &scope_a(), "ui", &message_id).unwrap();
            transaction.commit().unwrap();
            assert!(read_messages(&connection, &scope_a(), "ui", 0, 100)
                .unwrap()
                .0
                .is_empty());
            assert_eq!(
                read_messages(&connection, &scope_a(), "agent", 0, 100)
                    .unwrap()
                    .0
                    .len(),
                1
            );
        }
        {
            let mut connection = Connection::open(&path).unwrap();
            setup(&connection);
            // Acknowledged state survives the reopen for ui, agent is pending.
            assert!(read_messages(&connection, &scope_a(), "ui", 0, 100)
                .unwrap()
                .0
                .is_empty());
            assert_eq!(
                read_messages(&connection, &scope_a(), "agent", 0, 100)
                    .unwrap()
                    .0
                    .len(),
                1
            );
            // A new message after the old boundary is still delivered.
            let mut later = request_a();
            later.expected_revision = 1;
            later.request_id = Uuid::new_v4().to_string();
            later.messages = vec![Item {
                id: Uuid::new_v4().to_string(),
                kind: "wish.claimed".into(),
                payload: json!({"prop": "chair"}),
            }];
            send(&mut connection, &later);
            let (messages, _) =
                read_messages(&connection, &scope_a(), "ui", sequence, 100).unwrap();
            assert_eq!(messages.len(), 1);
        }
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(format!("{}-journal", path.display()));
    }

    #[test]
    fn failed_commit_rolls_back_state_events_messages_and_request_id() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let existing = Item {
            id: Uuid::new_v4().to_string(),
            kind: "wish.placed".into(),
            payload: json!({"prop": "lamp"}),
        };
        let mut first = request_a();
        first.events = vec![existing.clone()];
        send(&mut connection, &first);

        let request_id = Uuid::new_v4().to_string();
        let mut bad = request_a();
        bad.expected_revision = 1;
        bad.request_id = request_id.clone();
        bad.value = json!({"state": "must not land"});
        bad.events = vec![
            Item {
                id: Uuid::new_v4().to_string(),
                kind: "wish.placed".into(),
                payload: json!({"prop": "chair"}),
            },
            Item {
                id: existing.id.clone(),
                kind: "wish.placed".into(),
                payload: json!({"prop": "conflicting lamp"}),
            },
        ];
        assert_eq!(send_err(&mut connection, &bad), "event_id_conflict");
        // State, attachments and the request row all rolled back together.
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.revision, 1);
        assert_eq!(record.value, json!({"state": "content"}));
        let (events, _) = read_events(&connection, &scope_a(), 0, 100).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].id, existing.id);
        // The failed request id was not recorded: a corrected retry commits
        // fresh with replayed=false and lands the intended state.
        let mut fixed = request_a();
        fixed.expected_revision = 1;
        fixed.request_id = request_id;
        fixed.value = json!({"state": "must not land"});
        fixed.events = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "wish.placed".into(),
            payload: json!({"prop": "chair"}),
        }];
        let result = send(&mut connection, &fixed);
        assert_eq!(
            result,
            CommitResult {
                revision: 2,
                replayed: false
            }
        );
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.value, json!({"state": "must not land"}));
        let (events, _) = read_events(&connection, &scope_a(), 0, 100).unwrap();
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn pagination_returns_watermarks_and_validates_limits() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let mut request = request_a();
        let mut expected = 0_i64;
        let mut revisions = Vec::new();
        for index in 0..5 {
            request.expected_revision = expected;
            request.request_id = Uuid::new_v4().to_string();
            request.events = vec![Item {
                id: Uuid::new_v4().to_string(),
                kind: "wish.placed".into(),
                payload: json!({"index": index}),
            }];
            let result = send(&mut connection, &request);
            expected = result.revision;
            revisions.push(result.revision);
        }
        assert_eq!(revisions, vec![1, 2, 3, 4, 5]);
        let (page_one, watermark) = read_events(&connection, &scope_a(), 0, 2).unwrap();
        assert_eq!(page_one.len(), 2);
        assert_eq!(watermark, page_one[1].sequence);
        let (page_two, watermark) = read_events(&connection, &scope_a(), watermark, 2).unwrap();
        assert_eq!(page_two.len(), 2);
        let (page_three, watermark) = read_events(&connection, &scope_a(), watermark, 2).unwrap();
        assert_eq!(page_three.len(), 1);
        // An empty page returns the caller's boundary as the watermark, so a
        // poller can keep advancing (or holding) its cursor on every read.
        let after = watermark;
        let (empty, watermark) = read_events(&connection, &scope_a(), after, 2).unwrap();
        assert!(empty.is_empty());
        assert_eq!(watermark, after);
        assert!(read_events(&connection, &scope_a(), -1, 2).is_err());
        assert!(read_events(&connection, &scope_a(), 0, 0).is_err());
        assert_eq!(
            read_events(&connection, &scope_a(), 0, 501)
                .unwrap_err()
                .code,
            "limit_exceeded"
        );
        assert_eq!(
            read_window(Some(0), Some(501)).unwrap_err().code,
            "limit_exceeded"
        );
        assert_eq!(
            read_window(Some(0), Some(0)).unwrap_err().code,
            "invalid_limit"
        );
        assert_eq!(
            read_window(Some(-1), None).unwrap_err().code,
            "invalid_cursor"
        );
        assert_eq!(read_window(None, None).unwrap(), (0, DEFAULT_READ_LIMIT));
    }

    #[test]
    fn invalid_scope_domain_key_ids_consumer_and_values_are_rejected() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let mut request = request_a();
        request.scope.world_id = "".into();
        assert_eq!(send_err(&mut connection, &request), "invalid_scope");
        request = request_a();
        request.domain = "pod".into();
        assert_eq!(send_err(&mut connection, &request), "invalid_domain");
        request = request_a();
        request.key = " a".into();
        assert_eq!(send_err(&mut connection, &request), "invalid_state_key");
        request = request_a();
        request.value = json!(["not", "an", "object"]);
        assert_eq!(send_err(&mut connection, &request), "invalid_state_value");
        request = request_a();
        request.value = json!({"big": "界".repeat(STATE_VALUE_LIMIT / 2)});
        assert_eq!(send_err(&mut connection, &request), "state_value_too_large");
        request = request_a();
        request.expected_revision = -1;
        assert_eq!(send_err(&mut connection, &request), "invalid_revision");
        request = request_a();
        request.events = vec![Item {
            id: "".into(),
            kind: "wish.placed".into(),
            payload: json!({}),
        }];
        assert_eq!(send_err(&mut connection, &request), "invalid_event_id");
        request = request_a();
        request.events = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "b\nad".into(),
            payload: json!({}),
        }];
        assert_eq!(send_err(&mut connection, &request), "invalid_event_kind");
        request = request_a();
        request.messages = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "wish.placed".into(),
            payload: json!(["not", "an", "object"]),
        }];
        assert_eq!(
            send_err(&mut connection, &request),
            "invalid_message_payload"
        );
        // Reads validate scope/domain/consumer too.
        assert_eq!(
            read_state(&connection, &scope_a(), "bogus", "mood")
                .unwrap_err()
                .code,
            "invalid_domain"
        );
        assert_eq!(
            read_messages(&connection, &scope_a(), "other", 0, 100)
                .unwrap_err()
                .code,
            "invalid_consumer"
        );
        // Ack of an unknown message or consumer fails.
        let transaction = connection.transaction().unwrap();
        assert_eq!(
            ack(
                &transaction,
                &scope_a(),
                "agent",
                &Uuid::new_v4().to_string()
            )
            .unwrap_err()
            .code,
            "message_not_found"
        );
        assert_eq!(
            ack(
                &transaction,
                &scope_a(),
                "admin",
                &Uuid::new_v4().to_string()
            )
            .unwrap_err()
            .code,
            "invalid_consumer"
        );
    }

    #[test]
    fn ack_must_match_the_message_scope() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        let mut commit = request_a();
        commit.messages = vec![Item {
            id: Uuid::new_v4().to_string(),
            kind: "wish.claimed".into(),
            payload: json!({"prop": "lamp"}),
        }];
        send(&mut connection, &commit);
        let transaction = connection.transaction().unwrap();
        assert_eq!(
            ack(
                &transaction,
                &scope("world-a", "resident-other"),
                "agent",
                &commit.messages[0].id
            )
            .unwrap_err()
            .code,
            "message_not_found"
        );
        assert_eq!(
            ack(
                &transaction,
                &scope("world-b", "resident-a"),
                "agent",
                &commit.messages[0].id
            )
            .unwrap_err()
            .code,
            "message_not_found"
        );
    }

    #[test]
    fn state_commit_values_must_be_json_objects_only() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        for value in [
            json!(null),
            json!(true),
            json!(42),
            json!("text"),
            json!([1, 2]),
        ] {
            let mut request = request_a();
            request.value = value;
            assert_eq!(send_err(&mut connection, &request), "invalid_state_value");
        }
    }

    #[test]
    fn second_commit_with_same_expected_value_but_new_facts_is_rejected() {
        let mut connection = Connection::open_in_memory().unwrap();
        setup(&connection);
        assert_eq!(send(&mut connection, &request_a()).revision, 1);
        // Writers A and B both observed revision 1 and both intend to write the
        // exact same value; only their attached facts differ.
        let build = |marker: &str| {
            let mut request = request_a();
            request.expected_revision = 1;
            request.request_id = Uuid::new_v4().to_string();
            request.events = vec![Item {
                id: Uuid::new_v4().to_string(),
                kind: "wish.placed".into(),
                payload: json!({"racer": marker}),
            }];
            request
        };
        let first = build("a");
        assert_eq!(send(&mut connection, &first).revision, 2);
        // B retries with the stale expected revision it read before A landed:
        // the revision advanced even though the value is identical, so the
        // second CAS is rejected and B's fact never lands.
        let second = build("b");
        assert_eq!(send_err(&mut connection, &second), "revision_conflict");
        let record = read_state(&connection, &scope_a(), "resident", "mood")
            .unwrap()
            .unwrap();
        assert_eq!(record.revision, 2);
        assert_eq!(record.value, json!({"state": "content"}));
        let (events, _) = read_events(&connection, &scope_a(), 0, 100).unwrap();
        assert_eq!(events.len(), 1, "only the first racer's fact may land");
        assert_eq!(events[0].payload, json!({"racer": "a"}));
    }

    #[tokio::test]
    async fn racing_commits_with_same_expected_and_value_only_one_wins() {
        let dir = std::env::temp_dir().canonicalize().unwrap().join(format!("gmgn-resident-race-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        let database = crate::store::Database::open(dir.clone(), None).unwrap();
        let seeded = database
            .call(move |s| {
                let tx = s
                    .connection
                    .transaction()
                    .map_err(|_| "storage_unavailable")?;
                let result = commit(&tx, &request_a()).map_err(|e| e.code)?;
                tx.commit().map_err(|_| "storage_unavailable")?;
                Ok(result.revision)
            })
            .await
            .unwrap();
        assert_eq!(seeded, 1);
        // Two writers race from the same observed revision 1 with the same
        // value and different facts. The single-writer storage thread
        // serializes them; the winner advances the revision so the loser's
        // CAS fails and its fact is rolled back.
        let race = |marker: &'static str| {
            let mut request = request_a();
            request.expected_revision = 1;
            request.request_id = Uuid::new_v4().to_string();
            request.events = vec![Item {
                id: Uuid::new_v4().to_string(),
                kind: "wish.placed".into(),
                payload: json!({"racer": marker}),
            }];
            request
        };
        let racer_a = race("a");
        let racer_b = race("b");
        let (left, right) = tokio::join!(
            database.call(move |s| {
                let tx = s
                    .connection
                    .transaction()
                    .map_err(|_| "storage_unavailable")?;
                let result = commit(&tx, &racer_a).map_err(|e| e.code)?;
                tx.commit().map_err(|_| "storage_unavailable")?;
                Ok(result.revision)
            }),
            database.call(move |s| {
                let tx = s
                    .connection
                    .transaction()
                    .map_err(|_| "storage_unavailable")?;
                let result = commit(&tx, &racer_b).map_err(|e| e.code)?;
                tx.commit().map_err(|_| "storage_unavailable")?;
                Ok(result.revision)
            }),
        );
        let mut winners = 0;
        let mut conflicts = 0;
        for outcome in [left, right] {
            match outcome {
                Ok(revision) => {
                    assert_eq!(revision, 2);
                    winners += 1;
                }
                Err("revision_conflict") => conflicts += 1,
                Err(code) => panic!("unexpected commit error: {code}"),
            }
        }
        assert_eq!(winners, 1, "exactly one racer may commit");
        assert_eq!(conflicts, 1, "the other racer must lose the CAS");
        let state = database
            .call(move |s| {
                read_state(&s.connection, &scope_a(), "resident", "mood").map_err(|e| e.code)
            })
            .await
            .unwrap()
            .unwrap();
        assert_eq!(state.revision, 2);
        let (events, _) = database
            .call(move |s| read_events(&s.connection, &scope_a(), 0, 100).map_err(|e| e.code))
            .await
            .unwrap();
        assert_eq!(events.len(), 1, "loser's event must roll back");
        drop(database);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
