//! Raw provider library edits. The existing music tables remain the sole projection.
use crate::{canonical_json, model::Result};
use rusqlite::{params, Connection, OptionalExtension, Transaction};
use serde_json::{json, Value};
use std::{
    cmp::Ordering,
    collections::{BTreeMap, BTreeSet},
};

const MAX_ITEMS: usize = 10_000;
const MAX_BYTES: usize = 8 * 1024 * 1024;
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS music_library_commands(id TEXT PRIMARY KEY,input TEXT NOT NULL,output TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS music_library_generations(playlist TEXT PRIMARY KEY,epoch INTEGER NOT NULL);
CREATE TABLE IF NOT EXISTS music_library_batches(id TEXT PRIMARY KEY,kind TEXT NOT NULL,playlist TEXT,provider TEXT,epoch INTEGER,offset INTEGER,page_limit INTEGER,strict INTEGER,cache_mode TEXT,state TEXT NOT NULL,input TEXT,output TEXT,created_at INTEGER NOT NULL);")
        .map_err(|_| "storage_unavailable")
}
fn encoded(v: &Value) -> Result<String> {
    canonical_json::to_string(v).map_err(|_| "music_library_invalid_input")
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= 4096)
        .ok_or("music_library_invalid_input")
}
fn provider(v: &str) -> Result<()> {
    if ["local", "netease", "qq-music", "apple-music"].contains(&v) {
        Ok(())
    } else {
        Err("music_library_invalid_provider")
    }
}
fn integer(v: &Value, key: &str) -> Result<i64> {
    v[key]
        .as_i64()
        .filter(|n| *n >= 0)
        .ok_or("music_library_invalid_count")
}
fn tracks(v: &Value, owner: &str) -> Result<()> {
    let tracks = v.as_array().ok_or("music_library_invalid_track")?;
    if tracks.len() > MAX_ITEMS {
        return Err("music_library_capacity");
    }
    for t in tracks {
        text(t, "id")?;
        text(t, "title")?;
        if !t["artist"].is_string() || text(t, "providerID")? != owner {
            return Err("music_library_invalid_track");
        }
        let source = text(t, "source")?;
        if source
            != if owner == "local" {
                "localLibrary"
            } else {
                "streaming"
            }
        {
            return Err("music_library_invalid_source");
        }
        for key in ["duration", "matchScore", "userAffinity", "energy"] {
            let n = t[key]
                .as_f64()
                .filter(|n| n.is_finite())
                .ok_or("music_library_invalid_track")?;
            if key == "duration" && n < 0. {
                return Err("music_library_invalid_track");
            }
        }
        if !t["isPlayable"].is_boolean() {
            return Err("music_library_invalid_track");
        }
        for key in ["moodTags", "genres"] {
            if !t[key]
                .as_array()
                .is_some_and(|a| a.len() <= MAX_ITEMS && a.iter().all(Value::is_string))
            {
                return Err("music_library_invalid_track");
            }
        }
        for key in ["canonicalID", "album", "artworkURL"] {
            if !t[key].is_null() && !t[key].is_string() {
                return Err("music_library_invalid_track");
            }
        }
        if !t["releaseYear"].is_null() && t["releaseYear"].as_i64().is_none() {
            return Err("music_library_invalid_track");
        }
    }
    Ok(())
}
fn playlist(v: &Value) -> Result<()> {
    text(v, "id")?;
    text(v, "name")?;
    let p = text(v, "providerID")?;
    provider(p)?;
    tracks(&v["tracks"], p)?;
    if !v["artworkURL"].is_null() && !v["artworkURL"].is_string() {
        return Err("music_library_invalid_input");
    }
    if integer(v, "totalTrackCount")? < v["tracks"].as_array().unwrap().len() as i64 {
        return Err("music_library_invalid_count");
    }
    Ok(())
}
fn library(c: &Connection) -> Result<Value> {
    let revision: i64 = c
        .query_row(
            "SELECT revision FROM music_library_state WHERE singleton=1",
            [],
            |r| r.get(0),
        )
        .map_err(|_| "storage_unavailable")?;
    let mut q = c
        .prepare("SELECT payload FROM music_playlists ORDER BY position,id")
        .map_err(|_| "storage_unavailable")?;
    let rows = q
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(|_| "storage_unavailable")?;
    let rows: Vec<Value> = rows
        .map(|r| {
            serde_json::from_str(&r.map_err(|_| "storage_unavailable")?)
                .map_err(|_| "music_library_corrupt")
        })
        .collect::<Result<_>>()?;
    for row in &rows {
        playlist(row).map_err(|_| "music_library_corrupt")?;
    }
    Ok(json!({"revision":revision,"playlists":rows}))
}
fn bump_epoch(tx: &Transaction<'_>, id: &str) -> Result<()> {
    tx.execute("INSERT INTO music_library_generations VALUES(?1,1) ON CONFLICT(playlist) DO UPDATE SET epoch=epoch+1",[id]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn epoch(c: &Connection, id: &str) -> Result<i64> {
    Ok(c.query_row(
        "SELECT epoch FROM music_library_generations WHERE playlist=?1",
        [id],
        |r| r.get(0),
    )
    .optional()
    .map_err(|_| "storage_unavailable")?
    .unwrap_or(0))
}
fn publish(tx: &Transaction<'_>, rows: &[Value]) -> Result<Value> {
    if rows.len() > MAX_ITEMS || encoded(&json!(rows))?.len() > MAX_BYTES {
        return Err("music_library_capacity");
    }
    tx.execute("DELETE FROM music_playlists", [])
        .map_err(|_| "storage_unavailable")?;
    for (index, row) in rows.iter().enumerate() {
        playlist(row)?;
        tx.execute(
            "INSERT INTO music_playlists VALUES(?1,?2,?3)",
            params![text(row, "id")?, index as i64, encoded(row)?],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    let revision = integer(&library(tx)?, "revision")?
        .checked_add(1)
        .ok_or("music_library_revision_exhausted")?;
    tx.execute(
        "UPDATE music_library_state SET revision=?1 WHERE singleton=1",
        [revision],
    )
    .map_err(|_| "storage_unavailable")?;
    library(tx)
}
#[cfg(target_os = "macos")]
fn compare(a: &str, b: &str) -> Result<Ordering> {
    use std::ffi::{c_char, c_void};
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            allocator: *const c_void,
            bytes: *const u8,
            length: isize,
            encoding: u32,
            external: u8,
        ) -> *const c_void;
        fn CFRelease(value: *const c_void);
    }
    #[link(name = "Foundation", kind = "framework")]
    unsafe extern "C" {}
    #[link(name = "objc")]
    unsafe extern "C" {
        fn sel_registerName(name: *const c_char) -> *const c_void;
        fn objc_msgSend();
        fn objc_autoreleasePoolPush() -> *mut c_void;
        fn objc_autoreleasePoolPop(pool: *mut c_void);
    }
    // CFString/NSString are toll-free bridged. Foundation owns the exact locale/numeric comparison primitive used by the old view model.
    unsafe {
        let pool = objc_autoreleasePoolPush();
        let left = CFStringCreateWithBytes(
            std::ptr::null(),
            a.as_ptr(),
            a.len() as isize,
            0x08000100,
            0,
        );
        let right = CFStringCreateWithBytes(
            std::ptr::null(),
            b.as_ptr(),
            b.len() as isize,
            0x08000100,
            0,
        );
        if left.is_null() || right.is_null() {
            if !left.is_null() {
                CFRelease(left);
            }
            if !right.is_null() {
                CFRelease(right);
            }
            objc_autoreleasePoolPop(pool);
            return Err("music_library_sort_unavailable");
        }
        let send: unsafe extern "C" fn(*const c_void, *const c_void, *const c_void) -> isize =
            std::mem::transmute(objc_msgSend as *const ());
        let result = send(
            left,
            sel_registerName(c"localizedStandardCompare:".as_ptr()),
            right,
        );
        CFRelease(left);
        CFRelease(right);
        objc_autoreleasePoolPop(pool);
        Ok(result.cmp(&0))
    }
}
#[cfg(not(target_os = "macos"))]
fn compare(_: &str, _: &str) -> Result<Ordering> {
    Err("music_library_sort_unavailable")
}
fn sort(rows: &mut [Value]) -> Result<()> {
    let mut failure = None;
    rows.sort_by(|a, b| {
        let p = a["providerID"].as_str().cmp(&b["providerID"].as_str());
        if p != Ordering::Equal {
            return p;
        }
        match compare(a["name"].as_str().unwrap(), b["name"].as_str().unwrap()) {
            Ok(order) => order,
            Err(error) => {
                failure = Some(error);
                Ordering::Equal
            }
        }
    });
    failure.map_or(Ok(()), Err)
}
fn batch_prior(tx: &Transaction<'_>, batch: &str, input: &str) -> Result<Option<Value>> {
    let prior: Option<(Option<String>, Option<String>)> = tx
        .query_row(
            "SELECT input,output FROM music_library_batches WHERE id=?1",
            [batch],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((Some(old), Some(output))) = prior {
        if old != input {
            return Err("music_library_batch_conflict");
        }
        return Ok(Some(
            serde_json::from_str(&output).map_err(|_| "music_library_corrupt")?,
        ));
    }
    Ok(None)
}
fn edit(tx: &Transaction<'_>, e: &Value) -> Result<Value> {
    let mut rows = library(tx)?["playlists"].as_array().unwrap().clone();
    match text(e, "kind")? {
        "merge" => {
            let batch = text(e, "batchID")?;
            let wire = encoded(e)?;
            if let Some(prior) = batch_prior(tx, batch, &wire)? {
                return Ok(prior);
            }
            let incoming = e["playlists"]
                .as_array()
                .ok_or("music_library_invalid_input")?;
            if incoming.len() > MAX_ITEMS {
                return Err("music_library_capacity");
            }
            let mut ids = BTreeSet::new();
            let mut providers = BTreeSet::new();
            for item in incoming {
                playlist(item)?;
                if !ids.insert(text(item, "id")?) {
                    return Err("music_library_duplicate_id");
                }
                providers.insert(text(item, "providerID")?);
            }
            let old: BTreeMap<String, Value> = rows
                .iter()
                .map(|v| (v["id"].as_str().unwrap().into(), v.clone()))
                .collect();
            for item in &rows {
                if providers.contains(text(item, "providerID")?) {
                    bump_epoch(tx, text(item, "id")?)?;
                }
            }
            rows.retain(|v| !providers.contains(v["providerID"].as_str().unwrap()));
            for item in incoming {
                let mut item = item.clone();
                let id = text(&item, "id")?.to_owned();
                if old
                    .get(&id)
                    .is_some_and(|o| o["providerID"] != item["providerID"])
                {
                    return Err("music_library_identity_conflict");
                }
                if let Some(previous) = old.get(&id) {
                    if item["artworkURL"].is_null() {
                        item["artworkURL"] = previous["artworkURL"].clone();
                    }
                    if item["tracks"].as_array().unwrap().is_empty() {
                        item["tracks"] = previous["tracks"].clone();
                    }
                    item["totalTrackCount"] = json!(integer(&item, "totalTrackCount")?
                        .max(integer(previous, "totalTrackCount")?));
                } else {
                    bump_epoch(tx, &id)?;
                }
                rows.push(item);
            }
            sort(&mut rows)?;
            let output = publish(tx, &rows)?;
            tx.execute("INSERT INTO music_library_batches(id,kind,state,input,output,created_at) VALUES(?1,'merge','consumed',?2,?3,unixepoch())",params![batch,wire,encoded(&output)?]).map_err(|_|"music_library_batch_conflict")?;
            Ok(output)
        }
        "remove" => {
            let p = text(e, "providerID")?;
            provider(p)?;
            for row in &rows {
                if row["providerID"] == p {
                    bump_epoch(tx, text(row, "id")?)?;
                }
            }
            rows.retain(|v| v["providerID"] != p);
            publish(tx, &rows)
        }
        "append" => {
            let batch = text(e, "batchID")?;
            let wire = encoded(e)?;
            if let Some(prior) = batch_prior(tx, batch, &wire)? {
                return Ok(prior);
            }
            let row:(String,String,i64,i64,i64,bool,String,i64,String)=tx.query_row("SELECT playlist,provider,epoch,offset,page_limit,strict,state,created_at,cache_mode FROM music_library_batches WHERE id=?1 AND kind='page'",[batch],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?,r.get(7)?,r.get(8)?))).optional().map_err(|_|"storage_unavailable")?.ok_or("music_library_batch_unknown")?;
            let (id, p, g, offset, limit, strict, state, created, cache_mode) = row;
            let now: i64 = tx
                .query_row("SELECT unixepoch()", [], |r| r.get(0))
                .map_err(|_| "storage_unavailable")?;
            if state != "pending" || now - created > 600 || epoch(tx, &id)? != g {
                return Err("music_library_page_stale");
            }
            if text(e, "playlistID")? != id
                || text(e, "providerID")? != p
                || integer(e, "offset")? != offset
            {
                return Err("music_library_page_identity");
            }
            tracks(&e["tracks"], &p)?;
            let page = e["tracks"].as_array().unwrap();
            let total = integer(e, "totalTrackCount")?;
            if page.len() as i64 > limit || total < offset + page.len() as i64 {
                return Err("music_library_page_boundary");
            }
            let current = rows
                .iter_mut()
                .find(|v| v["id"] == id)
                .ok_or("music_library_page_stale")?;
            let current_tracks = current["tracks"].as_array().unwrap().clone();
            if cache_mode == "window" && offset != current_tracks.len() as i64 {
                let output = library(tx)?;
                tx.execute("UPDATE music_library_batches SET state='consumed',input=?1,output=?2 WHERE id=?3",params![wire,encoded(&output)?,batch]).map_err(|_|"storage_unavailable")?;
                return Ok(output);
            }
            let mut seen: BTreeSet<String> = current_tracks
                .iter()
                .map(|v| v["id"].as_str().unwrap().into())
                .collect();
            let mut appended = current_tracks;
            for track in page {
                let inserted = seen.insert(text(track, "id")?.into());
                if strict && !inserted {
                    return Err("music_library_page_duplicate");
                }
                if inserted {
                    appended.push(track.clone());
                }
            }
            if strict && page.is_empty() {
                return Err("music_library_page_no_progress");
            }
            current["tracks"] = json!(appended);
            current["totalTrackCount"] = json!(integer(current, "totalTrackCount")?
                .max(total)
                .max(appended.len() as i64));
            let output = publish(tx, &rows)?;
            tx.execute(
                "UPDATE music_library_batches SET state='consumed',input=?1,output=?2 WHERE id=?3",
                params![wire, encoded(&output)?, batch],
            )
            .map_err(|_| "storage_unavailable")?;
            Ok(output)
        }
        _ => Err("music_library_invalid_edit"),
    }
}
pub fn request(c: &mut Connection, method: &str, input: Value) -> Result<Value> {
    if encoded(&input)?.len() > MAX_BYTES {
        return Err("music_library_capacity");
    }
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let output = match method {
        "music_library_edit" | "music_library_page_begin" => {
            let id = text(&input, "requestID")?;
            let wire = encoded(&input)?;
            let prior: Option<(String, String)> = tx
                .query_row(
                    "SELECT input,output FROM music_library_commands WHERE id=?1",
                    [id],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .optional()
                .map_err(|_| "storage_unavailable")?;
            if let Some((old, output)) = prior {
                if old != wire {
                    return Err("music_library_request_conflict");
                }
                return serde_json::from_str(&output).map_err(|_| "music_library_corrupt");
            }
            for table in ["music_library_commands", "music_library_batches"] {
                let sql = format!(
                    "SELECT count(*),coalesce(sum(length(input)+length(output)),0) FROM {table}"
                );
                let (count, bytes): (i64, i64) = tx
                    .query_row(&sql, [], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map_err(|_| "storage_unavailable")?;
                if count >= 20_000 || bytes >= 256 * 1024 * 1024 {
                    return Err("music_library_capacity");
                }
            }
            let output = if method == "music_library_edit" {
                edit(&tx, &input["edit"])?
            } else {
                let id = text(&input, "playlistID")?;
                let offset = integer(&input, "offset")?;
                let limit = integer(&input, "limit")?;
                if !(1..=10_000).contains(&limit) {
                    return Err("music_library_page_boundary");
                }
                let strict = if input["strict"].is_null() {
                    false
                } else {
                    input["strict"]
                        .as_bool()
                        .ok_or("music_library_invalid_input")?
                };
                let cache_mode = match input.get("cacheMode") {
                    None => "deduplicate",
                    Some(value) => value.as_str().ok_or("music_library_invalid_page")?,
                };
                if !["deduplicate", "window"].contains(&cache_mode) {
                    return Err("music_library_invalid_input");
                }
                let snapshot = library(&tx)?;
                let row = snapshot["playlists"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .find(|v| v["id"] == id)
                    .ok_or("music_library_playlist_missing")?;
                let maximum = if cache_mode == "window" {
                    integer(row, "totalTrackCount")?
                } else {
                    row["tracks"].as_array().unwrap().len() as i64
                };
                if offset > maximum {
                    return Err("music_library_page_boundary");
                }
                let active:i64=tx.query_row("SELECT count(*) FROM music_library_batches WHERE kind='page' AND state='pending' AND created_at>unixepoch()-600",[],|r|r.get(0)).map_err(|_|"storage_unavailable")?;
                if active >= 64 {
                    return Err("music_library_page_busy");
                }
                let batch = uuid::Uuid::new_v4().to_string();
                let p = text(row, "providerID")?;
                tx.execute("INSERT INTO music_library_batches(id,kind,playlist,provider,epoch,offset,page_limit,strict,cache_mode,state,created_at) VALUES(?1,'page',?2,?3,?4,?5,?6,?7,?8,'pending',unixepoch())",params![batch,id,p,epoch(&tx,id)?,offset,limit,strict,cache_mode]).map_err(|_|"storage_unavailable")?;
                json!({"batchID":batch,"playlistID":id,"providerID":p,"offset":offset,"limit":limit})
            };
            tx.execute(
                "INSERT INTO music_library_commands VALUES(?1,?2,?3)",
                params![id, wire, encoded(&output)?],
            )
            .map_err(|_| "storage_unavailable")?;
            output
        }
        "music_library_page_end" => {
            let batch = text(&input, "batchID")?;
            tx.execute("UPDATE music_library_batches SET state='cancelled' WHERE id=?1 AND state='pending'",[batch]).map_err(|_|"storage_unavailable")?;
            json!({"released":true})
        }
        _ => return Err("unknown_method"),
    };
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        crate::music::schema(&c).unwrap();
        schema(&c).unwrap();
        c
    }
    fn track(id: &str, provider: &str) -> Value {
        json!({"id":id,"providerID":provider,"source":if provider=="local"{"localLibrary"}else{"streaming"},"title":id,"artist":"fixture","duration":120,"isPlayable":true,"matchScore":1,"userAffinity":1,"energy":0.4,"moodTags":[],"genres":[]})
    }
    fn row(id: &str, provider: &str, name: &str, tracks: Vec<Value>) -> Value {
        json!({"id":id,"providerID":provider,"name":name,"artworkURL":"https://fixture.invalid/art","tracks":tracks,"totalTrackCount":5})
    }
    fn merge(c: &mut Connection, id: &str, rows: Vec<Value>) -> Value {
        request(c,"music_library_edit",json!({"requestID":id,"edit":{"kind":"merge","batchID":format!("batch-{id}"),"playlists":rows}})).unwrap()
    }
    fn ticket(c: &mut Connection, id: &str, offset: i64, strict: bool) -> Value {
        request(c,"music_library_page_begin",json!({"requestID":uuid::Uuid::new_v4().to_string(),"playlistID":id,"offset":offset,"limit":10,"strict":strict})).unwrap()
    }
    fn append(id: &str, t: &Value, tracks: Vec<Value>) -> Value {
        json!({"requestID":id,"edit":{"kind":"append","batchID":t["batchID"],"providerID":t["providerID"],"playlistID":t["playlistID"],"offset":t["offset"],"totalTrackCount":5,"tracks":tracks}})
    }
    #[test]
    fn raw_provider_replace_retains_empty_tracks_artwork_total_and_other_provider() {
        let mut c = db();
        merge(
            &mut c,
            "one",
            vec![
                row("n", "netease", "N", vec![track("a", "netease")]),
                row("q", "qq-music", "Q", vec![]),
            ],
        );
        let mut replacement = row("n", "netease", "Updated", vec![]);
        replacement["artworkURL"] = Value::Null;
        replacement["totalTrackCount"] = json!(0);
        let result = merge(&mut c, "two", vec![replacement]);
        assert_eq!(result["playlists"][0]["tracks"][0]["id"], "a");
        assert_eq!(result["playlists"][0]["totalTrackCount"], 5);
        assert_eq!(
            result["playlists"][0]["artworkURL"],
            "https://fixture.invalid/art"
        );
        assert_eq!(result["playlists"][1]["id"], "q");
        let empty = merge(&mut c, "empty", vec![]);
        assert_eq!(empty["playlists"], result["playlists"]);
        let removed = request(
            &mut c,
            "music_library_edit",
            json!({"requestID":"remove","edit":{"kind":"remove","providerID":"netease"}}),
        )
        .unwrap();
        assert_eq!(removed["playlists"].as_array().unwrap().len(), 1);
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn exact_foundation_natural_order_and_incoming_replaces_whole_provider() {
        let mut c = db();
        merge(&mut c, "old", vec![row("old", "netease", "Old", vec![])]);
        let output = merge(
            &mut c,
            "new",
            vec![
                row("ten", "netease", "歌单10", vec![]),
                row("two", "netease", "歌单2", vec![]),
            ],
        );
        assert_eq!(output["playlists"][0]["id"], "two");
        assert_eq!(output["playlists"][1]["id"], "ten");
        assert!(!output["playlists"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v["id"] == "old"));
    }
    #[test]
    fn page_dedup_exact_request_and_batch_retries_do_not_advance_twice() {
        let mut c = db();
        merge(
            &mut c,
            "merge",
            vec![row("n", "netease", "N", vec![track("a", "netease")])],
        );
        let t = ticket(&mut c, "n", 0, false);
        let input = append(
            "page",
            &t,
            vec![
                track("a", "netease"),
                track("b", "netease"),
                track("b", "netease"),
            ],
        );
        let output = request(&mut c, "music_library_edit", input.clone()).unwrap();
        assert_eq!(
            output["playlists"][0]["tracks"].as_array().unwrap().len(),
            2
        );
        assert_eq!(
            request(&mut c, "music_library_edit", input.clone()).unwrap(),
            output
        );
        let mut retry = input.clone();
        retry["requestID"] = json!("different-request-same-batch");
        assert_eq!(
            request(&mut c, "music_library_edit", retry).unwrap(),
            output
        );
        assert_eq!(library(&c).unwrap()["revision"], output["revision"]);
        let mut changed = input;
        changed["edit"]["tracks"] = json!([track("c", "netease")]);
        assert_eq!(
            request(&mut c, "music_library_edit", changed).unwrap_err(),
            "music_library_request_conflict"
        );
    }
    #[test]
    fn late_wrong_provider_strict_duplicate_and_cancelled_pages_fail_closed() {
        let mut c = db();
        merge(
            &mut c,
            "old",
            vec![row("n", "netease", "N", vec![track("a", "netease")])],
        );
        let t = ticket(&mut c, "n", 1, true);
        assert_eq!(
            request(
                &mut c,
                "music_library_edit",
                append("dup", &t, vec![track("a", "netease")])
            )
            .unwrap_err(),
            "music_library_page_duplicate"
        );
        assert_eq!(
            request(
                &mut c,
                "music_library_edit",
                append("wrong", &t, vec![track("b", "qq-music")])
            )
            .unwrap_err(),
            "music_library_invalid_track"
        );
        let mut source = track("b", "netease");
        source["source"] = json!("localLibrary");
        assert_eq!(
            request(
                &mut c,
                "music_library_edit",
                append("source", &t, vec![source])
            )
            .unwrap_err(),
            "music_library_invalid_source"
        );
        merge(&mut c, "replace", vec![row("n", "netease", "New", vec![])]);
        assert_eq!(
            request(
                &mut c,
                "music_library_edit",
                append("late", &t, vec![track("b", "netease")])
            )
            .unwrap_err(),
            "music_library_page_stale"
        );
        let t = ticket(&mut c, "n", 1, true);
        request(
            &mut c,
            "music_library_page_end",
            json!({"batchID":t["batchID"]}),
        )
        .unwrap();
        assert_eq!(
            request(
                &mut c,
                "music_library_edit",
                append("cancelled", &t, vec![track("b", "netease")])
            )
            .unwrap_err(),
            "music_library_page_stale"
        );
        assert_eq!(
            library(&c).unwrap()["playlists"][0]["tracks"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
    }
    #[test]
    fn random_window_validates_source_without_introducing_cache_holes() {
        let mut c = db();
        merge(
            &mut c,
            "merge",
            vec![row("n", "netease", "N", vec![track("a", "netease")])],
        );
        let t=request(&mut c,"music_library_page_begin",json!({"requestID":"window","playlistID":"n","offset":3,"limit":1,"cacheMode":"window"})).unwrap();
        let before = library(&c).unwrap();
        assert_eq!(
            request(
                &mut c,
                "music_library_edit",
                append("window-page", &t, vec![track("d", "netease")])
            )
            .unwrap(),
            before
        );
        assert_eq!(library(&c).unwrap(), before);
    }
    #[test]
    fn sqlite_reopen_keeps_library_batch_identity_and_exact_receipt() {
        let path =
            std::env::temp_dir().join(format!("gmgn-library-{}.sqlite3", uuid::Uuid::new_v4()));
        let mut c = Connection::open(&path).unwrap();
        crate::music::schema(&c).unwrap();
        schema(&c).unwrap();
        merge(&mut c, "initial", vec![row("n", "netease", "N", vec![])]);
        let t = ticket(&mut c, "n", 0, false);
        let input = append("persisted-page", &t, vec![track("a", "netease")]);
        let output = request(&mut c, "music_library_edit", input.clone()).unwrap();
        drop(c);
        let mut reopened = Connection::open(&path).unwrap();
        assert_eq!(library(&reopened).unwrap(), output);
        assert_eq!(
            request(&mut reopened, "music_library_edit", input).unwrap(),
            output
        );
        drop(reopened);
        std::fs::remove_file(path).unwrap();
    }
}
