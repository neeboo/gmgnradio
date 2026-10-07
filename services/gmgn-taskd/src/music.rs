//! Music authority shares taskd's single SQLite writer; model payloads preserve
//! the complete client Codable contract, while identities/revisions are SQL keys.
use crate::model::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::collections::HashSet;

const MAX_ITEMS: usize = 10_000;
// Leave room for the list response envelope and pending IDs in 12 MiB HTTP JSON.
const MAX_BYTES: usize = 8 * 1024 * 1024;

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE music_programs(id TEXT PRIMARY KEY, updated_at TEXT NOT NULL, pending INTEGER NOT NULL CHECK(pending IN (0,1)), payload TEXT NOT NULL);
        CREATE INDEX music_program_updated ON music_programs(updated_at DESC,id);
        CREATE TABLE music_playlists(id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE music_library_state(singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
        INSERT INTO music_library_state VALUES(1,0);
        CREATE TABLE music_imports(source TEXT PRIMARY KEY);")
        .map_err(|_| "storage_unavailable")
}

fn string<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 4096)
        .ok_or("invalid_music_input")
}
fn date_key(date: &str) -> Result<String> {
    let bytes = date.as_bytes();
    if bytes.len() < 20
        || bytes[4] != b'-'
        || bytes[7] != b'-'
        || bytes[10] != b'T'
        || bytes[13] != b':'
        || bytes[16] != b':'
        || bytes.last() != Some(&b'Z')
    {
        return Err("invalid_music_date");
    }
    let part = |start, end| -> Result<u32> {
        let value = bytes.get(start..end).ok_or("invalid_music_date")?;
        if !value.iter().all(u8::is_ascii_digit) {
            return Err("invalid_music_date");
        }
        std::str::from_utf8(value)
            .map_err(|_| "invalid_music_date")?
            .parse()
            .map_err(|_| "invalid_music_date")
    };
    let year = part(0, 4)?;
    let month = part(5, 7)?;
    let day = part(8, 10)?;
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => {
            if leap {
                29
            } else {
                28
            }
        }
        _ => 0,
    };
    if year == 0
        || day == 0
        || day > days
        || part(11, 13)? > 23
        || part(14, 16)? > 59
        || part(17, 19)? > 59
    {
        return Err("invalid_music_date");
    }
    let fraction = if bytes.len() == 20 {
        ""
    } else {
        if bytes[19] != b'.' || bytes.len() > 30 || bytes.len() < 22 {
            return Err("invalid_music_date");
        }
        let fraction = &bytes[20..bytes.len() - 1];
        if !fraction.iter().all(u8::is_ascii_digit) {
            return Err("invalid_music_date");
        }
        std::str::from_utf8(fraction).map_err(|_| "invalid_music_date")?
    };
    Ok(format!("{}.{:0<9}Z", &date[..19], fraction))
}
fn program(v: &Value) -> Result<(&str, String)> {
    let id = string(&v["plan"]["brief"], "id")?;
    let date = string(v, "updatedAt")?;
    let date = date_key(date)?;
    date_key(string(&v["plan"], "generatedAt")?)?;
    if v["plan"]["revision"].as_u64().is_none()
        || v["plan"]["replanAfterTrackCount"].as_u64().is_none()
        || v["plan"]["brief"]["targetDuration"].as_f64().is_none()
    {
        return Err("invalid_music_input");
    }
    let slots = v["plan"]["slots"].as_array().ok_or("invalid_music_input")?;
    if slots.len() > MAX_ITEMS {
        return Err("music_capacity_exceeded");
    }
    for slot in slots {
        string(&slot["track"], "id")?;
        string(&slot["track"], "providerID")?;
        string(slot, "role")?;
        if !slot["hostHint"].is_object() {
            return Err("invalid_music_input");
        }
    }
    if !v["activeSlotIndex"].is_null() {
        let index = v["activeSlotIndex"].as_u64().ok_or("invalid_music_input")?;
        if index >= slots.len() as u64 {
            return Err("invalid_music_slot");
        }
    }
    Ok((id, date))
}
fn playlists(v: &Value) -> Result<&Vec<Value>> {
    let list = v.as_array().ok_or("invalid_music_input")?;
    if list.len() > MAX_ITEMS {
        return Err("music_capacity_exceeded");
    }
    let mut ids = HashSet::new();
    for p in list {
        let id = string(p, "id")?;
        string(p, "providerID")?;
        string(p, "name")?;
        let tracks = p["tracks"].as_array().ok_or("invalid_music_input")?;
        let count = p["totalTrackCount"].as_u64().ok_or("invalid_music_input")?;
        if tracks.len() > MAX_ITEMS || count < tracks.len() as u64 || count > i64::MAX as u64 {
            return Err("invalid_music_count");
        }
        if !ids.insert(id) {
            return Err("duplicate_music_id");
        }
    }
    Ok(list)
}
fn revision(c: &Connection) -> Result<i64> {
    c.query_row(
        "SELECT revision FROM music_library_state WHERE singleton=1",
        [],
        |r| r.get(0),
    )
    .map_err(|_| "storage_unavailable")
}
fn read_payloads(c: &Connection, sql: &str) -> Result<Vec<Value>> {
    let mut stmt = c.prepare(sql).map_err(|_| "storage_unavailable")?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|_| "storage_unavailable")?;
    rows.map(|r| {
        serde_json::from_str(&r.map_err(|_| "storage_unavailable")?)
            .map_err(|_| "music_storage_corrupt")
    })
    .collect()
}
fn library(c: &Connection) -> Result<Value> {
    Ok(
        json!({"playlists":read_payloads(c,"SELECT payload FROM music_playlists ORDER BY position,id")?, "revision":revision(c)?}),
    )
}
fn capacity(c: &Connection) -> Result<()> {
    for sql in [
        "SELECT COUNT(*),COALESCE(SUM(length(CAST(payload AS BLOB))),0) FROM music_programs",
        "SELECT COUNT(*),COALESCE(SUM(length(CAST(payload AS BLOB))),0) FROM music_playlists",
    ] {
        let (count, bytes): (i64, i64) = c
            .query_row(sql, [], |r| Ok((r.get(0)?, r.get(1)?)))
            .map_err(|_| "storage_unavailable")?;
        if count > MAX_ITEMS as i64 || bytes > MAX_BYTES as i64 {
            return Err("music_capacity_exceeded");
        }
    }
    Ok(())
}
pub fn request(c: &mut Connection, method: &str, input: Value) -> Result<Value> {
    if serde_json::to_vec(&input)
        .map_err(|_| "invalid_music_input")?
        .len()
        > MAX_BYTES
    {
        return Err("music_capacity_exceeded");
    }
    match method {
        "music_program_save" => {
            let value = &input["program"];
            let (id, date) = program(value)?;
            let pending = input["pending"].as_bool().ok_or("invalid_music_input")?;
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            tx.execute("INSERT INTO music_programs VALUES(?1,?2,?3,?4) ON CONFLICT(id) DO UPDATE SET updated_at=excluded.updated_at,pending=excluded.pending,payload=excluded.payload", params![id,date,pending,value.to_string()]).map_err(|_| "storage_unavailable")?;
            capacity(&tx)?;
            tx.commit().map_err(|_| "storage_unavailable")?;
            Ok(json!({"saved":true}))
        }
        "music_program_list" => {
            let programs = read_payloads(
                c,
                "SELECT payload FROM music_programs ORDER BY updated_at DESC,id",
            )?;
            let mut stmt = c
                .prepare(
                    "SELECT id FROM music_programs WHERE pending=1 ORDER BY updated_at DESC,id",
                )
                .map_err(|_| "storage_unavailable")?;
            let ids = stmt
                .query_map([], |r| r.get::<_, String>(0))
                .map_err(|_| "storage_unavailable")?
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| "storage_unavailable")?;
            Ok(json!({"programs":programs,"pendingIDs":ids}))
        }
        "music_library_read" => library(c),
        "music_library_commit" => {
            let list = playlists(&input["playlists"])?;
            let base = input["baseRevision"]
                .as_i64()
                .filter(|n| *n >= 0)
                .ok_or("invalid_music_revision")?;
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            if revision(&tx)? != base {
                return Err("music_revision_conflict");
            }
            let next = base.checked_add(1).ok_or("music_revision_exhausted")?;
            tx.execute("DELETE FROM music_playlists", [])
                .map_err(|_| "storage_unavailable")?;
            for (index, p) in list.iter().enumerate() {
                tx.execute(
                    "INSERT INTO music_playlists VALUES(?1,?2,?3)",
                    params![p["id"].as_str(), index as i64, p.to_string()],
                )
                .map_err(|_| "storage_unavailable")?;
            }
            tx.execute(
                "UPDATE music_library_state SET revision=?1 WHERE singleton=1",
                [next],
            )
            .map_err(|_| "storage_unavailable")?;
            capacity(&tx)?;
            tx.commit().map_err(|_| "storage_unavailable")?;
            library(c)
        }
        "music_import" => {
            let source = string(&input, "source")?;
            let programs = input["programs"].as_array().ok_or("invalid_music_input")?;
            if programs.len() > MAX_ITEMS {
                return Err("music_capacity_exceeded");
            }
            let list = playlists(&input["playlists"])?;
            let mut ids = HashSet::new();
            for p in programs {
                if !ids.insert(program(p)?.0) {
                    return Err("duplicate_music_id");
                }
            }
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            let exists: Option<String> = tx
                .query_row(
                    "SELECT source FROM music_imports WHERE source=?1",
                    [source],
                    |r| r.get(0),
                )
                .optional()
                .map_err(|_| "storage_unavailable")?;
            if exists.is_some() {
                return Ok(
                    json!({"importedPrograms":0,"importedPlaylists":0,"alreadyImported":true,"revision":revision(&tx)?}),
                );
            }
            let mut pc = 0;
            let mut lc = 0;
            for p in programs {
                let (id, date) = program(p)?;
                pc += tx
                    .execute(
                        "INSERT OR IGNORE INTO music_programs VALUES(?1,?2,0,?3)",
                        params![id, date, p.to_string()],
                    )
                    .map_err(|_| "storage_unavailable")?;
            }
            let position: i64 = tx
                .query_row(
                    "SELECT COALESCE(MAX(position)+1,0) FROM music_playlists",
                    [],
                    |r| r.get(0),
                )
                .map_err(|_| "storage_unavailable")?;
            for (index, p) in list.iter().enumerate() {
                lc += tx
                    .execute(
                        "INSERT OR IGNORE INTO music_playlists VALUES(?1,?2,?3)",
                        params![p["id"].as_str(), position + index as i64, p.to_string()],
                    )
                    .map_err(|_| "storage_unavailable")?;
            }
            capacity(&tx)?;
            let rev = revision(&tx)?
                .checked_add(i64::from(lc > 0))
                .ok_or("music_revision_exhausted")?;
            tx.execute(
                "UPDATE music_library_state SET revision=?1 WHERE singleton=1",
                [rev],
            )
            .map_err(|_| "storage_unavailable")?;
            tx.execute("INSERT INTO music_imports VALUES(?1)", [source])
                .map_err(|_| "storage_unavailable")?;
            tx.commit().map_err(|_| "storage_unavailable")?;
            Ok(
                json!({"importedPrograms":pc,"importedPlaylists":lc,"alreadyImported":false,"revision":rev}),
            )
        }
        _ => Err("unknown_method"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn saved(id: &str, updated: &str) -> Value {
        json!({"plan":{"brief":{"id":id,"targetDuration":1200},"revision":1,
            "generatedAt":"2026-10-07T00:00:00Z","replanAfterTrackCount":3,"slots":[]},"updatedAt":updated})
    }
    #[test]
    fn dates_validate_calendar_and_fraction_order() {
        assert!(date_key("2026-02-29T00:00:00Z").is_err());
        assert!(date_key("2024-02-29T23:59:59Z").is_ok());
        assert!(date_key("2026-10-07T24:00:00Z").is_err());
        assert!(date_key("2026-10-07T00:00:00.1234567890Z").is_err());
        assert!(
            date_key("2026-10-07T00:00:00Z").unwrap() < date_key("2026-10-07T00:00:00.1Z").unwrap()
        );
    }
    #[test]
    fn import_is_atomic_and_failed_import_can_retry() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let mut bad = saved("bad", "2026-10-07T00:00:00Z");
        bad["activeSlotIndex"] = json!(0);
        let input = json!({"source":"test","programs":[saved("good","2026-10-07T00:00:00Z"),bad],"playlists":[]});
        assert_eq!(
            request(&mut c, "music_import", input),
            Err("invalid_music_slot")
        );
        assert!(
            request(&mut c, "music_program_list", json!({})).unwrap()["programs"]
                .as_array()
                .unwrap()
                .is_empty()
        );
        let result = request(&mut c,"music_import",json!({"source":"test","programs":[saved("good","2026-10-07T00:00:00Z")],"playlists":[]})).unwrap();
        assert_eq!(result["importedPrograms"], 1);
        assert_eq!(result["alreadyImported"], false);
    }
    #[test]
    fn program_date_order_preserves_payload_and_pending() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        for (id, date) in [
            ("a", "2026-10-07T00:00:00Z"),
            ("b", "2026-10-07T00:00:00.1Z"),
        ] {
            request(
                &mut c,
                "music_program_save",
                json!({"program":saved(id,date),"pending":true}),
            )
            .unwrap();
        }
        let result = request(&mut c, "music_program_list", json!({})).unwrap();
        assert_eq!(result["pendingIDs"], json!(["b", "a"]));
        assert_eq!(result["programs"][0]["updatedAt"], "2026-10-07T00:00:00.1Z");
    }
    #[test]
    fn revision_overflow_is_visible_and_does_not_delete_playlists() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        c.execute("UPDATE music_library_state SET revision=?1", [i64::MAX])
            .unwrap();
        assert_eq!(
            request(
                &mut c,
                "music_library_commit",
                json!({"baseRevision":i64::MAX,"playlists":[]})
            ),
            Err("music_revision_exhausted")
        );
        assert_eq!(revision(&c).unwrap(), i64::MAX);
    }
    #[test]
    fn aggregate_program_capacity_rolls_back_the_second_write() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        let mut first = saved("first", "2026-10-07T00:00:00Z");
        first["plan"]["direction"] = json!("x".repeat(MAX_BYTES / 2));
        request(
            &mut c,
            "music_program_save",
            json!({"program":first,"pending":true}),
        )
        .unwrap();
        let mut second = saved("second", "2026-10-07T00:00:00Z");
        second["plan"]["direction"] = json!("x".repeat(MAX_BYTES / 2));
        assert_eq!(
            request(
                &mut c,
                "music_program_save",
                json!({"program":second,"pending":false})
            ),
            Err("music_capacity_exceeded")
        );
        let count: i64 = c
            .query_row("SELECT COUNT(*) FROM music_programs", [], |r| r.get(0))
            .unwrap();
        assert_eq!(count, 1);
    }
}
