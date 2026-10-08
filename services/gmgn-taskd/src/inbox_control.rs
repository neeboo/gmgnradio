//! Typed inbox transitions. The resident inbox record remains the only entry store.
//! Human reads are not delivery-consumer ACKs. No request here acknowledges messages.
use crate::{model::Result, resident};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::time::{SystemTime, UNIX_EPOCH};

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS inbox_control_requests(world TEXT NOT NULL,scope TEXT NOT NULL,id TEXT NOT NULL,digest TEXT NOT NULL,changed INTEGER NOT NULL,PRIMARY KEY(world,scope,id));CREATE TABLE IF NOT EXISTS inbox_control_imports(world TEXT NOT NULL,scope TEXT NOT NULL,PRIMARY KEY(world,scope));").map_err(|_|"storage_unavailable")
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Delivery {
    #[serde(rename = "eventID")]
    pub event_id: String,
    #[serde(rename = "taskID")]
    pub task_id: String,
    pub kind: String,
    pub title: String,
    pub status: String,
    pub detail: String,
    pub terminal: bool,
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Entry {
    pub task_key: String,
    #[serde(rename = "lastEventID")]
    pub last_event_id: String,
    pub kind: String,
    pub title: String,
    pub status: String,
    pub detail: String,
    pub terminal: bool,
    pub is_read: bool,
    pub read_at: Option<f64>,
    pub delivered_at: f64,
    pub updated_at: f64,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Read {
    scope: resident::Scope,
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Mutation {
    scope: resident::Scope,
    #[serde(rename = "requestID")]
    request_id: String,
    expected_revision: i64,
    #[serde(default)]
    deliveries: Option<Vec<Delivery>>,
    #[serde(default)]
    task_key: Option<String>,
    #[serde(default, rename = "expectedEventID")]
    expected_event_id: Option<String>,
    #[serde(default, rename = "messageID")]
    message_id: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    detail: Option<String>,
    #[serde(default)]
    entries: Option<Vec<Entry>>,
}
fn token(s: &str) -> Result<()> {
    if s.is_empty() || s.len() > 200 || s.chars().any(char::is_control) {
        Err("inbox_invalid_input")
    } else {
        Ok(())
    }
}
fn text(s: &str, max: usize) -> Result<()> {
    if s.len() > max || s.contains('\0') {
        Err("inbox_invalid_input")
    } else {
        Ok(())
    }
}
fn validate_delivery(d: &Delivery) -> Result<()> {
    token(&d.event_id)?;
    token(&d.task_id)?;
    token(&d.kind)?;
    text(&d.title, resident::STATE_VALUE_LIMIT)?;
    text(&d.status, resident::STATE_VALUE_LIMIT)?;
    text(&d.detail, resident::STATE_VALUE_LIMIT)
}
fn validate_entries(entries: &[Entry]) -> Result<()> {
    let mut tasks = std::collections::BTreeSet::new();
    for e in entries {
        validate_delivery(&Delivery {
            event_id: e.last_event_id.clone(),
            task_id: e.task_key.clone(),
            kind: e.kind.clone(),
            title: e.title.clone(),
            status: e.status.clone(),
            detail: e.detail.clone(),
            terminal: e.terminal,
        })?;
        if !tasks.insert(&e.task_key)
            || !e.delivered_at.is_finite()
            || !e.updated_at.is_finite()
            || e.delivered_at < 0.0
            || e.updated_at < e.delivered_at
            || e.read_at.is_some_and(|n| !n.is_finite() || n < 0.0)
            || (!e.is_read && e.read_at.is_some())
        {
            return Err("inbox_invalid_state");
        }
    }
    // Match the existing resident state's whole JSON value UTF-8 budget;
    // historical delivery/import fields never had the agent-post field caps.
    if serde_json::to_vec(&json!({"entries": entries}))
        .map_err(|_| "inbox_invalid_state")?
        .len()
        > resident::STATE_VALUE_LIMIT
    {
        return Err("inbox_too_large");
    }
    Ok(())
}
fn load(c: &Connection, scope: &resident::Scope) -> Result<(i64, Vec<Entry>)> {
    resident::validate_scope(&scope.world_id, &scope.resident_scope).map_err(|e| e.code)?;
    let record = resident::read_state(c, scope, "inbox", "entries").map_err(|e| e.code)?;
    match record {
        None => Ok((0, Vec::new())),
        Some(record) => {
            let entries: Vec<Entry> = serde_json::from_value(
                record
                    .value
                    .get("entries")
                    .cloned()
                    .ok_or("inbox_invalid_state")?,
            )
            .map_err(|_| "inbox_invalid_state")?;
            validate_entries(&entries)?;
            Ok((record.revision, entries))
        }
    }
}
fn response(
    c: &Connection,
    scope: &resident::Scope,
    revision: i64,
    mut entries: Vec<Entry>,
    changed: bool,
    replayed: bool,
) -> Result<Value> {
    entries.sort_by(|a, b| {
        b.updated_at
            .total_cmp(&a.updated_at)
            .then(a.task_key.cmp(&b.task_key))
    });
    let unread = entries.iter().filter(|e| !e.is_read).count();
    let expiries: std::collections::BTreeMap<&str, f64> = entries
        .iter()
        .filter(|e| e.terminal)
        .map(|e| (e.task_key.as_str(), e.updated_at + 30.0))
        .collect();
    let imported = revision > 0
        || c.query_row(
            "SELECT 1 FROM inbox_control_imports WHERE world=?1 AND scope=?2",
            params![scope.world_id, scope.resident_scope],
            |_| Ok(()),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?
        .is_some();
    Ok(
        json!({"revision":revision,"entries":entries,"unreadCount":unread,"promptExpiries":expiries,"changed":changed,"replayed":replayed,"legacyImported":imported}),
    )
}
pub fn request(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "inbox_clock_unavailable")?
        .as_secs_f64();
    request_at(c, method, p, now)
}
fn request_at(c: &mut Connection, method: &str, p: &Value, now: f64) -> Result<Value> {
    if method == "inbox_control_read" {
        let p: Read = serde_json::from_value(p.clone()).map_err(|_| "inbox_invalid_input")?;
        let (revision, entries) = load(c, &p.scope)?;
        return response(c, &p.scope, revision, entries, false, false);
    }
    if ![
        "inbox_control_deliver",
        "inbox_control_post",
        "inbox_control_mark_read",
        "inbox_control_import",
    ]
    .contains(&method)
    {
        return Err("unsupported_method");
    }
    let m: Mutation = serde_json::from_value(p.clone()).map_err(|_| "inbox_invalid_input")?;
    token(&m.request_id)?;
    if m.expected_revision < 0 {
        return Err("invalid_revision");
    }
    let digest = format!(
        "{:x}",
        Sha256::digest(
            crate::canonical_json::to_string(&json!([method, p]))
                .map_err(|_| "inbox_invalid_input")?
        )
    );
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let (revision, mut entries) = load(&tx, &m.scope)?;
    let prior:Option<(String,bool)>=tx.query_row("SELECT digest,changed FROM inbox_control_requests WHERE world=?1 AND scope=?2 AND id=?3",params![m.scope.world_id,m.scope.resident_scope,m.request_id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
    if let Some((hash, changed)) = prior {
        if hash != digest {
            return Err("request_id_conflict");
        }
        return response(&tx, &m.scope, revision, entries, changed, true);
    }
    if revision != m.expected_revision {
        return Err("revision_conflict");
    }
    let mut changed = false;
    let mut messages = Vec::new();
    match method {
        "inbox_control_deliver" => {
            if m.task_key.is_some()
                || m.expected_event_id.is_some()
                || m.message_id.is_some()
                || m.title.is_some()
                || m.detail.is_some()
                || m.entries.is_some()
            {
                return Err("inbox_invalid_input");
            }
            let deliveries = m
                .deliveries
                .as_ref()
                .filter(|a| !a.is_empty() && a.len() <= 500)
                .ok_or("inbox_invalid_input")?;
            for d in deliveries {
                validate_delivery(d)?;
                if let Some(e) = entries.iter_mut().find(|e| e.task_key == d.task_id) {
                    let identical = e.kind == d.kind
                        && e.title == d.title
                        && e.status == d.status
                        && e.detail == d.detail
                        && e.terminal == d.terminal;
                    if identical {
                        continue;
                    }
                    if e.last_event_id != d.event_id {
                        e.last_event_id = d.event_id.clone();
                        e.is_read = false;
                        e.read_at = None;
                        e.updated_at = now.max(e.updated_at);
                    }
                    e.kind = d.kind.clone();
                    e.title = d.title.clone();
                    e.status = d.status.clone();
                    e.detail = d.detail.clone();
                    e.terminal = d.terminal;
                    changed = true;
                } else {
                    entries.push(Entry {
                        task_key: d.task_id.clone(),
                        last_event_id: d.event_id.clone(),
                        kind: d.kind.clone(),
                        title: d.title.clone(),
                        status: d.status.clone(),
                        detail: d.detail.clone(),
                        terminal: d.terminal,
                        is_read: false,
                        read_at: None,
                        delivered_at: now,
                        updated_at: now,
                    });
                    changed = true;
                }
            }
        }
        "inbox_control_mark_read" => {
            if m.deliveries.is_some()
                || m.message_id.is_some()
                || m.title.is_some()
                || m.detail.is_some()
                || m.entries.is_some()
            {
                return Err("inbox_invalid_input");
            }
            let task = m.task_key.as_deref().ok_or("inbox_invalid_input")?;
            token(task)?;
            let event = m
                .expected_event_id
                .as_deref()
                .ok_or("inbox_invalid_input")?;
            token(event)?;
            let entry = entries
                .iter_mut()
                .find(|e| e.task_key == task)
                .ok_or("notification_missing")?;
            if entry.last_event_id != event {
                return Err("notification_changed");
            }
            if !entry.is_read {
                entry.is_read = true;
                entry.read_at = Some(now);
                changed = true;
            }
        }
        "inbox_control_post" => {
            if m.deliveries.is_some()
                || m.task_key.is_some()
                || m.expected_event_id.is_some()
                || m.entries.is_some()
            {
                return Err("inbox_invalid_input");
            }
            let id = m.message_id.as_deref().ok_or("inbox_invalid_input")?;
            uuid::Uuid::parse_str(id).map_err(|_| "inbox_invalid_input")?;
            let title = m.title.as_deref().ok_or("inbox_invalid_input")?;
            let detail = m.detail.as_deref().ok_or("inbox_invalid_input")?;
            if title.trim().is_empty() || detail.trim().is_empty() {
                return Err("inbox_invalid_input");
            }
            text(title, 512)?;
            text(detail, 16384)?;
            let key = format!("agent-message:{id}");
            if let Some(entry) = entries.iter().find(|e| e.task_key == key) {
                if entry.title != title
                    || entry.detail != detail
                    || entry.kind != "agent_message"
                    || entry.last_event_id != id
                {
                    return Err("request_id_conflict");
                }
            } else {
                entries.push(Entry {
                    task_key: key.clone(),
                    last_event_id: id.to_owned(),
                    kind: "agent_message".into(),
                    title: title.into(),
                    status: "pending".into(),
                    detail: detail.into(),
                    terminal: false,
                    is_read: false,
                    read_at: None,
                    delivered_at: now,
                    updated_at: now,
                });
                changed = true;
                messages.push(resident::Item {
                    id: id.into(),
                    kind: "system_inbox".into(),
                    payload: json!({"taskKey":key,"eventID":id}),
                });
            }
        }
        "inbox_control_import" => {
            if m.deliveries.is_some()
                || m.task_key.is_some()
                || m.expected_event_id.is_some()
                || m.message_id.is_some()
                || m.title.is_some()
                || m.detail.is_some()
            {
                return Err("inbox_invalid_input");
            }
            let legacy = m.entries.as_ref().ok_or("inbox_invalid_input")?;
            validate_entries(legacy)?;
            let imported = tx
                .query_row(
                    "SELECT 1 FROM inbox_control_imports WHERE world=?1 AND scope=?2",
                    params![m.scope.world_id, m.scope.resident_scope],
                    |_| Ok(()),
                )
                .optional()
                .map_err(|_| "storage_unavailable")?
                .is_some();
            if revision == 0 && !imported && !legacy.is_empty() {
                entries = legacy.clone();
                changed = true;
            }
            tx.execute(
                "INSERT OR IGNORE INTO inbox_control_imports(world,scope) VALUES(?1,?2)",
                params![m.scope.world_id, m.scope.resident_scope],
            )
            .map_err(|_| "storage_unavailable")?;
        }
        _ => unreachable!(),
    }
    validate_entries(&entries)?;
    let next = if changed {
        resident::commit(
            &tx,
            &resident::CommitRequest {
                scope: m.scope.clone(),
                domain: "inbox".into(),
                key: "entries".into(),
                expected_revision: revision,
                request_id: m.request_id.clone(),
                value: json!({"entries":entries}),
                events: Vec::new(),
                messages,
            },
        )
        .map_err(|e| e.code)?
        .revision
    } else {
        revision
    };
    tx.execute(
        "INSERT INTO inbox_control_requests(world,scope,id,digest,changed) VALUES(?1,?2,?3,?4,?5)",
        params![
            m.scope.world_id,
            m.scope.resident_scope,
            m.request_id,
            digest,
            changed
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    response(c, &m.scope, next, entries, changed, false)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn setup() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        resident::schema(&c).unwrap();
        schema(&c).unwrap();
        c
    }
    fn scope() -> Value {
        json!({"worldID":"world-a","residentScope":"resident-a"})
    }
    fn deliver(id: &str, event: &str, revision: i64, status: &str) -> Value {
        json!({"scope":scope(),"requestID":id,"expectedRevision":revision,"deliveries":[{"eventID":event,"taskID":"wish-a","kind":"wish","title":"Wish","status":status,"detail":"detail","terminal":status=="completed"}]})
    }
    #[test]
    fn event_merge_read_and_prompt_clock_are_authoritative() {
        let mut c = setup();
        let first = request_at(
            &mut c,
            "inbox_control_deliver",
            &deliver("first", "event-a", 0, "working"),
            100.125,
        )
        .unwrap();
        assert_eq!(first["unreadCount"], 1);
        assert_eq!(first["entries"][0]["updatedAt"], 100.125);
        let read = json!({"scope":scope(),"requestID":"read","expectedRevision":1,"taskKey":"wish-a","expectedEventID":"event-a"});
        let read = request_at(&mut c, "inbox_control_mark_read", &read, 105.75).unwrap();
        assert_eq!(read["entries"][0]["readAt"], 105.75);
        let refresh = request_at(
            &mut c,
            "inbox_control_deliver",
            &deliver("refresh", "event-a", 2, "completed"),
            200.0,
        )
        .unwrap();
        assert_eq!(refresh["unreadCount"], 0);
        assert_eq!(refresh["entries"][0]["updatedAt"], 100.125);
        assert_eq!(refresh["entries"][0]["readAt"], 105.75);
        assert_eq!(refresh["promptExpiries"]["wish-a"], 130.125);
        let identical = request_at(
            &mut c,
            "inbox_control_deliver",
            &deliver("same-content", "event-b", 3, "completed"),
            300.0,
        )
        .unwrap();
        assert_eq!(identical["changed"], false);
        assert_eq!(identical["revision"], 3);
        assert_eq!(identical["entries"][0]["lastEventID"], "event-a");
        let fresh = request_at(
            &mut c,
            "inbox_control_deliver",
            &deliver("fresh", "event-c", 3, "working"),
            400.5,
        )
        .unwrap();
        assert_eq!(fresh["unreadCount"], 1);
        assert_eq!(fresh["entries"][0]["readAt"], Value::Null);
        assert_eq!(fresh["entries"][0]["deliveredAt"], 100.125);
        assert_eq!(fresh["entries"][0]["updatedAt"], 400.5);
        assert_eq!(
            request_at(
                &mut c,
                "inbox_control_mark_read",
                &json!({"scope":scope(),"requestID":"stale-read","expectedRevision":4,"taskKey":"wish-a","expectedEventID":"event-a"}),
                500.0
            ),
            Err("notification_changed")
        );
        let mut untrusted = deliver("clock", "event-d", 4, "completed");
        untrusted["now"] = json!(9999);
        assert_eq!(
            request_at(&mut c, "inbox_control_deliver", &untrusted, 500.0),
            Err("inbox_invalid_input")
        );
    }
    #[test]
    fn replay_cas_scope_and_legacy_import_preserve_confirmed_entries() {
        let mut c = setup();
        let p = deliver("same-request", "event-a", 0, "working");
        request_at(&mut c, "inbox_control_deliver", &p, 10.25).unwrap();
        let replay = request_at(&mut c, "inbox_control_deliver", &p, 80.0).unwrap();
        assert_eq!(replay["replayed"], true);
        assert_eq!(replay["revision"], 1);
        assert_eq!(replay["entries"][0]["updatedAt"], 10.25);
        assert_eq!(
            request_at(
                &mut c,
                "inbox_control_deliver",
                &deliver("same-request", "event-a", 0, "completed"),
                90.0
            ),
            Err("request_id_conflict")
        );
        assert_eq!(
            request_at(
                &mut c,
                "inbox_control_deliver",
                &deliver("stale", "event-b", 0, "completed"),
                90.0
            ),
            Err("revision_conflict")
        );
        let mut other = p.clone();
        other["scope"]["worldID"] = json!("world-b");
        let other = request_at(&mut c, "inbox_control_deliver", &other, 20.0).unwrap();
        assert_eq!(other["entries"][0]["updatedAt"], 20.0);
        let empty_scope = json!({"worldID":"empty","residentScope":"resident-a"});
        let empty=request_at(&mut c,"inbox_control_import",&json!({"scope":empty_scope,"requestID":"empty-import","expectedRevision":0,"entries":[]}),30.0).unwrap();
        assert_eq!(empty["legacyImported"], true);
        let old = other["entries"].clone();
        let later=request_at(&mut c,"inbox_control_import",&json!({"scope":empty_scope,"requestID":"later-import","expectedRevision":0,"entries":old}),40.0).unwrap();
        assert_eq!(later["entries"], json!([])); // Missing legacy data was checked once; cannot resurrect later.
        let legacy_scope = json!({"worldID":"legacy","residentScope":"resident-a"});
        let imported=request_at(&mut c,"inbox_control_import",&json!({"scope":legacy_scope,"requestID":"legacy-import","expectedRevision":0,"entries":old}),300.0).unwrap();
        assert_eq!(imported["entries"][0]["updatedAt"], 20.0);
        assert_eq!(imported["entries"][0]["deliveredAt"], 20.0);
    }
    #[test]
    fn historical_large_fields_preserve_whole_value_utf8_budget() {
        let mut c = setup();
        let mut p = deliver("large-delivery", "large-event", 0, "working");
        p["deliveries"][0]["title"] = json!("旧".repeat(600));
        p["deliveries"][0]["detail"] = json!("旧错误".repeat(3000));
        let first = request_at(&mut c, "inbox_control_deliver", &p, 10.0).unwrap();
        let old = first["entries"].clone();
        let import = json!({"scope":{"worldID":"historical","residentScope":"resident-a"},"requestID":"large-import","expectedRevision":0,"entries":old});
        let imported = request_at(&mut c, "inbox_control_import", &import, 20.0).unwrap();
        assert_eq!(imported["entries"], first["entries"]);
        let mut oversized = p.clone();
        oversized["requestID"] = json!("too-large");
        oversized["expectedRevision"] = json!(1);
        oversized["deliveries"][0]["title"] = json!("a".repeat(140_000));
        oversized["deliveries"][0]["detail"] = json!("b".repeat(140_000));
        assert_eq!(
            request_at(&mut c, "inbox_control_deliver", &oversized, 30.0),
            Err("inbox_too_large")
        );
        let sc: resident::Scope = serde_json::from_value(scope()).unwrap();
        let state = resident::read_state(&c, &sc, "inbox", "entries")
            .unwrap()
            .unwrap();
        assert_eq!(state.revision, 1);
        assert_eq!(state.value["entries"], first["entries"]);
        let mut oversized_import = import;
        oversized_import["scope"]["worldID"] = json!("oversized-import");
        oversized_import["requestID"] = json!("too-large-import");
        oversized_import["entries"][0]["title"] = json!("a".repeat(140_000));
        oversized_import["entries"][0]["detail"] = json!("b".repeat(140_000));
        assert_eq!(
            request_at(&mut c, "inbox_control_import", &oversized_import, 30.0),
            Err("inbox_too_large")
        );
        let post = json!({"scope":scope(),"requestID":"post-cap","expectedRevision":1,"messageID":"c464c970-e829-4e86-b3b6-683ab517dc6f","title":"a".repeat(513),"detail":"text"});
        assert_eq!(
            request_at(&mut c, "inbox_control_post", &post, 40.0),
            Err("inbox_invalid_input")
        );
    }
    #[test]
    fn posting_and_wakeup_are_one_transaction_and_never_ack() {
        let mut c = setup();
        let id = "c464c970-e829-4e86-b3b6-683ab517dc6c";
        let post = json!({"scope":scope(),"requestID":"post","expectedRevision":0,"messageID":id,"title":"Title","detail":"Text"});
        let first = request_at(&mut c, "inbox_control_post", &post, 100.0).unwrap();
        assert_eq!(first["revision"], 1);
        let sc: resident::Scope = serde_json::from_value(scope()).unwrap();
        let (messages, _) = resident::read_messages(&c, &sc, "agent", 0, 100).unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].id, id);
        let mut repeat = post.clone();
        repeat["requestID"] = json!("post-again");
        repeat["expectedRevision"] = json!(1);
        let same = request_at(&mut c, "inbox_control_post", &repeat, 200.0).unwrap();
        assert_eq!(same["changed"], false);
        assert_eq!(same["revision"], 1);
        let mut conflict = repeat.clone();
        conflict["title"] = json!("different");
        conflict["requestID"] = json!("conflict");
        assert_eq!(
            request_at(&mut c, "inbox_control_post", &conflict, 300.0),
            Err("request_id_conflict")
        );
        let (messages, _) = resident::read_messages(&c, &sc, "agent", 0, 100).unwrap();
        assert_eq!(messages.len(), 1);
        let id2 = "c464c970-e829-4e86-b3b6-683ab517dc6d";
        let tx = c.transaction().unwrap();
        resident::commit(
            &tx,
            &resident::CommitRequest {
                scope: sc.clone(),
                domain: "world".into(),
                key: "fixture".into(),
                expected_revision: 0,
                request_id: "seed-conflict".into(),
                value: json!({}),
                events: vec![],
                messages: vec![resident::Item {
                    id: id2.into(),
                    kind: "different".into(),
                    payload: json!({}),
                }],
            },
        )
        .unwrap();
        tx.commit().unwrap();
        let mut rollback = repeat;
        rollback["requestID"] = json!("rollback");
        rollback["messageID"] = json!(id2);
        assert_eq!(
            request_at(&mut c, "inbox_control_post", &rollback, 400.0),
            Err("message_id_conflict")
        );
        let state = resident::read_state(&c, &sc, "inbox", "entries")
            .unwrap()
            .unwrap();
        assert_eq!(state.revision, 1);
        assert_eq!(state.value["entries"].as_array().unwrap().len(), 1);
    }
}
