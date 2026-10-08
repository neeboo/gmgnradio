//! Raw provider observations and listening facts -> persistent merged knowledge.
use crate::{canonical_json, model::Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS music_knowledge_tracks(scope TEXT,identity TEXT,payload TEXT,PRIMARY KEY(scope,identity));CREATE TABLE IF NOT EXISTS music_knowledge_commands(scope TEXT,request TEXT,input TEXT,response TEXT,PRIMARY KEY(scope,request));CREATE TABLE IF NOT EXISTS music_knowledge_state(scope TEXT PRIMARY KEY,revision INTEGER NOT NULL);").map_err(|_|"storage_unavailable")
}
fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 4096)
        .ok_or("music_knowledge_invalid_input")
}
fn clean(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}
#[cfg(target_os = "macos")]
fn folded(s: &str, flags: usize) -> Result<String> {
    if s.len() > 4096 || s.contains('\0') {
        return Err("music_knowledge_invalid_input");
    }
    use std::ffi::{c_char, c_void};
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(
            a: *const c_void,
            b: *const u8,
            n: isize,
            e: u32,
            x: u8,
        ) -> *const c_void;
        fn CFStringCreateMutableCopy(a: *const c_void, n: isize, s: *const c_void) -> *mut c_void;
        fn CFLocaleCreate(a: *const c_void, id: *const c_void) -> *const c_void;
        fn CFStringFold(s: *mut c_void, flags: usize, locale: *const c_void);
        fn CFStringLowercase(s: *mut c_void, locale: *const c_void);
        fn CFStringGetLength(s: *const c_void) -> isize;
        fn CFStringGetMaximumSizeForEncoding(n: isize, e: u32) -> isize;
        fn CFStringGetCString(s: *const c_void, out: *mut c_char, n: isize, e: u32) -> u8;
        fn CFRelease(s: *const c_void);
    }
    // Same fixed Foundation primitive as the former Swift folding options,
    // followed by invariant lowercasing. No NFKD/ASCII approximation.
    unsafe {
        let create = |s: &str| {
            CFStringCreateWithBytes(
                std::ptr::null(),
                s.as_ptr(),
                s.len() as isize,
                0x08000100,
                0,
            )
        };
        let source = create(s);
        let locale_id = create("en_US_POSIX");
        if source.is_null() || locale_id.is_null() {
            if !source.is_null() {
                CFRelease(source);
            }
            if !locale_id.is_null() {
                CFRelease(locale_id);
            }
            return Err("music_knowledge_normalization_unavailable");
        }
        let mutable = CFStringCreateMutableCopy(std::ptr::null(), 0, source);
        let locale = CFLocaleCreate(std::ptr::null(), locale_id);
        CFRelease(source);
        CFRelease(locale_id);
        if mutable.is_null() || locale.is_null() {
            if !mutable.is_null() {
                CFRelease(mutable);
            }
            if !locale.is_null() {
                CFRelease(locale);
            }
            return Err("music_knowledge_normalization_unavailable");
        }
        if flags != 0 {
            CFStringFold(mutable, flags, locale);
        }
        CFStringLowercase(mutable, std::ptr::null());
        let n = CFStringGetMaximumSizeForEncoding(CFStringGetLength(mutable), 0x08000100) + 1;
        let mut bytes = vec![0u8; n.max(1) as usize];
        let good = CFStringGetCString(mutable, bytes.as_mut_ptr().cast(), n, 0x08000100) != 0;
        CFRelease(mutable);
        CFRelease(locale);
        if !good {
            return Err("music_knowledge_normalization_unavailable");
        }
        bytes.truncate(bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len()));
        String::from_utf8(bytes).map_err(|_| "music_knowledge_normalization_unavailable")
    }
}
#[cfg(not(target_os = "macos"))]
fn folded(s: &str, _flags: usize) -> Result<String> {
    if s.len() > 4096 || s.contains('\0') {
        return Err("music_knowledge_invalid_input");
    }
    if s.is_ascii() {
        Ok(s.to_ascii_lowercase())
    } else {
        Err("music_knowledge_normalization_unavailable")
    }
}
fn labels(v: &Value) -> Result<Value> {
    let a = v
        .as_array()
        .filter(|v| v.len() <= 10000)
        .ok_or("music_knowledge_invalid_input")?;
    let mut out = BTreeSet::new();
    for s in a {
        let s = s
            .as_str()
            .filter(|s| s.len() <= 4096)
            .ok_or("music_knowledge_invalid_input")?;
        let s = folded(&clean(s), 0)?;
        if !s.is_empty() {
            out.insert(s);
        }
    }
    Ok(json!(out))
}
fn num(v: &Value, k: &str) -> Result<f64> {
    v[k].as_f64()
        .filter(|x| x.is_finite())
        .ok_or("music_knowledge_invalid_input")
}
fn source(candidate: &Value) -> Result<Value> {
    let provider = text(candidate, "providerID")?;
    let id = text(candidate, "id")?;
    let kind = text(candidate, "source")?;
    if !matches!(kind, "localLibrary" | "streaming") || !candidate["isPlayable"].is_boolean() {
        return Err("music_knowledge_invalid_input");
    }
    Ok(
        json!({"providerID":provider,"trackID":id,"source":kind,"isPlayable":candidate["isPlayable"],"matchScore":num(candidate,"matchScore")?.clamp(0.,1.),"userAffinity":num(candidate,"userAffinity")?.clamp(0.,1.)}),
    )
}
fn fresh(c: &Value, origin: &str, at: f64) -> Result<Value> {
    let title = clean(
        c["title"]
            .as_str()
            .filter(|s| s.len() <= 4096)
            .ok_or("music_knowledge_invalid_input")?,
    );
    let artist = clean(
        c["artist"]
            .as_str()
            .filter(|s| s.len() <= 4096)
            .ok_or("music_knowledge_invalid_input")?,
    );
    let key = format!("{}|{}", folded(&title, 129)?, folded(&artist, 129)?);
    let canonical = match c["canonicalID"].as_str() {
        Some(s) => {
            let s = folded(s.trim(), 0)?;
            if s.is_empty() {
                Value::Null
            } else {
                json!(s)
            }
        }
        None if c["canonicalID"].is_null() => Value::Null,
        _ => return Err("music_knowledge_invalid_input"),
    };
    let identity = canonical
        .as_str()
        .map(|s| format!("canonical:{s}"))
        .unwrap_or_else(|| format!("metadata:{key}"));
    for k in ["album", "artworkURL"] {
        if !c[k].is_null() && !c[k].is_string() {
            return Err("music_knowledge_invalid_input");
        }
    }
    if !c["releaseYear"].is_null() && c["releaseYear"].as_i64().is_none() {
        return Err("music_knowledge_invalid_input");
    }
    let duration = num(c, "duration")?;
    if duration < 0. {
        return Err("music_knowledge_invalid_input");
    }
    Ok(
        json!({"identity":identity,"canonicalID":canonical,"normalizedMetadataKey":key,"title":title,"artist":artist,"album":c["album"].as_str().map(clean),"duration":duration,"energy":num(c,"energy")?.clamp(0.,1.),"moodTags":labels(&c["moodTags"])? ,"genres":labels(&c["genres"])? ,"releaseYear":c["releaseYear"],"artworkURL":c["artworkURL"],"sources":[source(c)?],"origins":[origin],"firstSeenAt":at,"lastSeenAt":at,"playCount":0,"completedPlayCount":0,"skipCount":0,"isLiked":false,"lastPlayedAt":null,"lastSkippedAt":null}),
    )
}
fn merge(v: &mut Value, old: &Value) -> Result<()> {
    if v["canonicalID"].is_null() && !old["canonicalID"].is_null() {
        v["canonicalID"] = old["canonicalID"].clone();
        v["identity"] = json!(format!(
            "canonical:{}",
            old["canonicalID"]
                .as_str()
                .ok_or("music_knowledge_corrupt")?
        ));
    }
    let mut sources = v["sources"].as_array().unwrap().clone();
    for source in old["sources"].as_array().ok_or("music_knowledge_corrupt")? {
        if !sources
            .iter()
            .any(|s| s["providerID"] == source["providerID"] && s["trackID"] == source["trackID"])
        {
            sources.push(source.clone());
        }
    }
    sources.sort_by(|a, b| {
        (b["isPlayable"] == true)
            .cmp(&(a["isPlayable"] == true))
            .then_with(|| {
                b["matchScore"]
                    .as_f64()
                    .unwrap_or(0.)
                    .total_cmp(&a["matchScore"].as_f64().unwrap_or(0.))
            })
            .then_with(|| a["providerID"].as_str().cmp(&b["providerID"].as_str()))
            .then_with(|| a["trackID"].as_str().cmp(&b["trackID"].as_str()))
    });
    v["sources"] = json!(sources);
    for key in ["origins", "moodTags", "genres"] {
        let mut set = BTreeSet::new();
        for s in v[key]
            .as_array()
            .unwrap()
            .iter()
            .chain(old[key].as_array().ok_or("music_knowledge_corrupt")?)
        {
            set.insert(s.as_str().ok_or("music_knowledge_corrupt")?.to_owned());
        }
        v[key] = json!(set);
    }
    v["firstSeenAt"] = json!(num(v, "firstSeenAt")?.min(num(old, "firstSeenAt")?));
    v["lastSeenAt"] = json!(num(v, "lastSeenAt")?.max(num(old, "lastSeenAt")?));
    for k in ["playCount", "completedPlayCount", "skipCount"] {
        v[k] = json!(v[k]
            .as_i64()
            .unwrap_or(0)
            .checked_add(old[k].as_i64().ok_or("music_knowledge_corrupt")?)
            .ok_or("music_knowledge_capacity")?);
    }
    v["isLiked"] = json!(v["isLiked"] == true || old["isLiked"] == true);
    for k in ["lastPlayedAt", "lastSkippedAt"] {
        v[k] = match (v[k].as_f64(), old[k].as_f64()) {
            (Some(a), Some(b)) => json!(a.max(b)),
            (None, Some(b)) => json!(b),
            _ => v[k].clone(),
        };
    }
    if v["album"].as_str().is_none_or(str::is_empty) {
        v["album"] = old["album"].clone();
    }
    if num(v, "duration")? <= 0. {
        v["duration"] = old["duration"].clone();
    }
    v["energy"] = json!(((num(v, "energy")? + num(old, "energy")?) / 2.).clamp(0., 1.));
    for k in ["releaseYear", "artworkURL"] {
        if v[k].is_null() {
            v[k] = old[k].clone();
        }
    }
    Ok(())
}
fn load(c: &Connection, scope: &str) -> Result<BTreeMap<String, Value>> {
    let mut q = c
        .prepare(
            "SELECT identity,payload FROM music_knowledge_tracks WHERE scope=?1 ORDER BY identity",
        )
        .map_err(|_| "storage_unavailable")?;
    let rows = q
        .query_map([scope], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
        })
        .map_err(|_| "storage_unavailable")?;
    let mut out = BTreeMap::new();
    for row in rows {
        let (id, raw) = row.map_err(|_| "storage_unavailable")?;
        out.insert(
            id,
            serde_json::from_str(&raw).map_err(|_| "music_knowledge_corrupt")?,
        );
    }
    Ok(out)
}
fn snapshot(c: &Connection, scope: &str) -> Result<Value> {
    let r = c
        .query_row(
            "SELECT revision FROM music_knowledge_state WHERE scope=?1",
            [scope],
            |r| r.get::<_, i64>(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?
        .unwrap_or(0);
    let tracks = load(c, scope)?
        .into_values()
        .map(|mut v| {
            let source_affinity = v["sources"]
                .as_array()
                .unwrap()
                .iter()
                .filter_map(|s| s["userAffinity"].as_f64())
                .fold(0.0, f64::max);
            let play = (v["playCount"].as_i64().unwrap_or(0) as f64 * 0.035).min(0.2);
            let completion =
                (v["completedPlayCount"].as_i64().unwrap_or(0) as f64 * 0.025).min(0.15);
            let like = if v["isLiked"] == true { 0.25 } else { 0.0 };
            let skip = (v["skipCount"].as_i64().unwrap_or(0) as f64 * 0.12).min(0.45);
            v["affinityScore"] =
                json!((source_affinity + play + completion + like - skip).clamp(0.0, 1.0));
            v
        })
        .collect::<Vec<_>>();
    Ok(json!({"revision":r,"tracks":tracks}))
}
pub fn request(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    let scope = text(p, "scope")?;
    if method == "music_knowledge_read" {
        return snapshot(c, scope);
    }
    if !matches!(method, "music_knowledge_ingest" | "music_knowledge_event") {
        return Err("unknown_method");
    }
    let id = text(p, "requestID")?;
    let raw = canonical_json::to_string(p).map_err(|_| "music_knowledge_invalid_input")?;
    if raw.len() > 8 * 1024 * 1024 {
        return Err("music_knowledge_capacity");
    }
    let digest = format!("{method}:{:x}", Sha256::digest(raw.as_bytes()));
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let prior: Option<(String, String)> = tx
        .query_row(
            "SELECT input,response FROM music_knowledge_commands WHERE scope=?1 AND request=?2",
            params![scope, id],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    if let Some((input, _response)) = prior {
        if input != digest {
            return Err("music_knowledge_request_conflict");
        }
        return snapshot(&tx, scope);
    }
    let mut tracks = load(&tx, scope)?;
    let previous = tracks.clone();
    if method == "music_knowledge_ingest" {
        let origin = text(p, "origin")?;
        if !matches!(origin, "saved" | "recent" | "discovery") {
            return Err("music_knowledge_invalid_input");
        }
        let at = num(p, "seenAt")?;
        let candidates = p["candidates"]
            .as_array()
            .filter(|a| a.len() <= 10000)
            .ok_or("music_knowledge_invalid_input")?;
        for candidate in candidates {
            let mut value = fresh(candidate, origin, at)?;
            let matching: Vec<_> = tracks
                .iter()
                .filter(|(id, v)| {
                    **id == value["identity"].as_str().unwrap()
                        || v["normalizedMetadataKey"] == value["normalizedMetadataKey"]
                })
                .map(|(id, _)| id.clone())
                .collect();
            for id in matching {
                merge(&mut value, &tracks.remove(&id).unwrap())?;
            }
            tracks.insert(value["identity"].as_str().unwrap().to_owned(), value);
        }
    } else {
        let event = text(p, "event")?;
        if !matches!(event, "played" | "completed" | "skipped" | "liked") {
            return Err("music_knowledge_invalid_input");
        }
        let track_id = text(p, "trackID")?;
        if event == "played" && !p["completed"].is_boolean()
            || event == "liked" && !p["isLiked"].is_boolean()
        {
            return Err("music_knowledge_invalid_input");
        }
        let at = num(p, "at")?;
        let identity = tracks
            .keys()
            .find(|id| id.as_str() == track_id)
            .cloned()
            .or_else(|| {
                tracks
                    .iter()
                    .find(|(_, v)| {
                        v["sources"]
                            .as_array()
                            .is_some_and(|a| a.iter().any(|v| v["trackID"] == track_id))
                    })
                    .map(|(id, _)| id.clone())
            });
        if let Some(id) = identity {
            let v = tracks.get_mut(&id).unwrap();
            match event {
                "played" => {
                    v["playCount"] = json!(v["playCount"]
                        .as_i64()
                        .unwrap()
                        .checked_add(1)
                        .ok_or("music_knowledge_capacity")?);
                    if p["completed"]
                        .as_bool()
                        .ok_or("music_knowledge_invalid_input")?
                    {
                        v["completedPlayCount"] = json!(v["completedPlayCount"]
                            .as_i64()
                            .unwrap()
                            .checked_add(1)
                            .ok_or("music_knowledge_capacity")?);
                    }
                    v["lastPlayedAt"] = json!(v["lastPlayedAt"].as_f64().unwrap_or(at).max(at));
                }
                "completed" => {
                    v["completedPlayCount"] = json!(v["completedPlayCount"]
                        .as_i64()
                        .unwrap()
                        .checked_add(1)
                        .ok_or("music_knowledge_capacity")?);
                    v["lastPlayedAt"] = json!(v["lastPlayedAt"].as_f64().unwrap_or(at).max(at));
                }
                "skipped" => {
                    v["skipCount"] = json!(v["skipCount"]
                        .as_i64()
                        .unwrap()
                        .checked_add(1)
                        .ok_or("music_knowledge_capacity")?);
                    v["lastSkippedAt"] = json!(v["lastSkippedAt"].as_f64().unwrap_or(at).max(at));
                }
                "liked" => {
                    v["isLiked"] = json!(p["isLiked"]
                        .as_bool()
                        .ok_or("music_knowledge_invalid_input")?)
                }
                _ => unreachable!(),
            }
        }
    }
    if tracks.len() > 10000 {
        return Err("music_knowledge_capacity");
    }
    for id in previous.keys().filter(|id| !tracks.contains_key(*id)) {
        tx.execute(
            "DELETE FROM music_knowledge_tracks WHERE scope=?1 AND identity=?2",
            params![scope, id],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    for (id, v) in tracks {
        if previous.get(&id) == Some(&v) {
            continue;
        }
        tx.execute(
            "INSERT INTO music_knowledge_tracks VALUES(?1,?2,?3) ON CONFLICT(scope,identity) DO UPDATE SET payload=excluded.payload",
            params![scope, id, v.to_string()],
        )
        .map_err(|_| "storage_unavailable")?;
    }
    tx.execute("INSERT INTO music_knowledge_state VALUES(?1,1) ON CONFLICT(scope) DO UPDATE SET revision=revision+1",[scope]).map_err(|_|"storage_unavailable")?;
    let output = snapshot(&tx, scope)?;
    tx.execute(
        "INSERT INTO music_knowledge_commands VALUES(?1,?2,?3,?4)",
        params![
            scope,
            id,
            digest,
            json!({"revision":output["revision"]}).to_string()
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn candidate(
        id: &str,
        canonical: Option<&str>,
        title: &str,
        artist: &str,
        provider: &str,
    ) -> Value {
        json!({"id":id,"canonicalID":canonical,"title":title,"artist":artist,"providerID":provider,"source":"streaming","album":null,"duration":120.0,"energy":0.6,"isPlayable":true,"matchScore":0.8,"userAffinity":0.4,"moodTags":[" Warm ","warm"],"genres":["Jazz"],"releaseYear":2024,"artworkURL":null})
    }
    fn ingest(c: &mut Connection, id: &str, rows: Vec<Value>, origin: &str, at: f64) -> Value {
        request(c,"music_knowledge_ingest",&json!({"scope":"fixture","requestID":id,"candidates":rows,"origin":origin,"seenAt":at})).unwrap()
    }
    #[test]
    fn canonical_arrival_preserves_actual_listening_history() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        ingest(
            &mut c,
            "a",
            vec![candidate(
                "local-a",
                None,
                "Blue Hour",
                "The Lights",
                "local",
            )],
            "recent",
            1000.,
        );
        request(&mut c,"music_knowledge_event",&json!({"scope":"fixture","requestID":"play","event":"played","trackID":"local-a","completed":false,"at":2000.})).unwrap();
        request(&mut c,"music_knowledge_event",&json!({"scope":"fixture","requestID":"finish","event":"completed","trackID":"local-a","at":3000.})).unwrap();
        let merged = ingest(
            &mut c,
            "b",
            vec![candidate(
                "stream-b",
                Some(" ISRC:ONE "),
                " Blue   Hour ",
                "The Lights",
                "netease",
            )],
            "saved",
            4000.,
        );
        let t = &merged["tracks"][0];
        assert_eq!(merged["tracks"].as_array().unwrap().len(), 1);
        assert_eq!(t["identity"], "canonical:isrc:one");
        assert_eq!(t["sources"].as_array().unwrap().len(), 2);
        assert_eq!(t["playCount"], 1);
        assert_eq!(t["completedPlayCount"], 1);
        assert_eq!(t["firstSeenAt"], 1000.);
        assert_eq!(t["lastSeenAt"], 4000.);
        assert_eq!(t["moodTags"], json!(["warm"]));
        assert!((t["affinityScore"].as_f64().unwrap() - 0.46).abs() < 1e-9);
    }
    #[test]
    fn duplicate_facts_do_not_increment_and_conflicting_request_ids_fail() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        ingest(
            &mut c,
            "a",
            vec![candidate("a", None, "One", "Artist", "local")],
            "saved",
            1000.,
        );
        let mut p = json!({"scope":"fixture","requestID":"event","event":"skipped","trackID":"a","at":2000.});
        let first = request(&mut c, "music_knowledge_event", &p).unwrap();
        assert_eq!(request(&mut c, "music_knowledge_event", &p).unwrap(), first);
        assert_eq!(first["tracks"][0]["skipCount"], 1);
        p["at"] = json!(3000.);
        assert_eq!(
            request(&mut c, "music_knowledge_event", &p),
            Err("music_knowledge_request_conflict")
        );
        p["requestID"] = json!("invalid");
        p["event"] = json!("played");
        p["trackID"] = json!("unknown");
        assert_eq!(
            request(&mut c, "music_knowledge_event", &p),
            Err("music_knowledge_invalid_input")
        );
    }
    #[test]
    fn bridge_merges_existing_identities_and_latest_source_observation_wins() {
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        ingest(
            &mut c,
            "a",
            vec![
                candidate(
                    "a",
                    Some("ISRC:BRIDGE"),
                    "Blue Remaster",
                    "Artist",
                    "netease",
                ),
                candidate("b", None, "Blue", "Artist", "local"),
            ],
            "saved",
            1000.,
        );
        let mut latest = candidate("a", Some("isrc:bridge"), "Blue", "Artist", "netease");
        latest["isPlayable"] = json!(false);
        let out = ingest(&mut c, "b", vec![latest], "discovery", 2000.);
        assert_eq!(out["tracks"].as_array().unwrap().len(), 1);
        let sources = out["tracks"][0]["sources"].as_array().unwrap();
        assert_eq!(sources.len(), 2);
        assert_eq!(
            sources.iter().find(|s| s["trackID"] == "a").unwrap()["isPlayable"],
            false
        );
    }
    #[cfg(target_os = "macos")]
    #[test]
    fn real_foundation_fixed_locale_folding_preserves_accent_merge() {
        assert_eq!(folded("Café Blue", 129).unwrap(), "cafe blue");
        assert_eq!(folded("Beyoncé", 129).unwrap(), "beyonce");
        assert_eq!(folded("İstanbul", 129).unwrap(), "istanbul");
        assert_eq!(folded("Straße", 129).unwrap(), "strasse");
        let mut c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        ingest(
            &mut c,
            "a",
            vec![candidate("a", None, "Café Blue", "Beyoncé", "local")],
            "recent",
            1000.,
        );
        let out = ingest(
            &mut c,
            "b",
            vec![candidate(
                "b",
                Some("ISRC:ONE"),
                "Cafe Blue",
                "Beyonce",
                "netease",
            )],
            "saved",
            2000.,
        );
        assert_eq!(out["tracks"].as_array().unwrap().len(), 1);
    }
}
