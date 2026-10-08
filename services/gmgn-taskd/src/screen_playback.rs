//! Screen queue authority. AV supplies actual output receipts; cache state is not EOF.
use crate::{media::Media, model::Result, store::Database};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{collections::HashSet, sync::Arc};
use tokio::sync::Mutex;

pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS screen_playback_sessions(world TEXT NOT NULL,screen TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(world,screen));
        CREATE TABLE IF NOT EXISTS screen_playback_commands(world TEXT NOT NULL,screen TEXT NOT NULL,request TEXT NOT NULL,input TEXT NOT NULL,PRIMARY KEY(world,screen,request));")
        .map_err(|_|"storage_unavailable")
}
fn text<'a>(p: &'a Value, k: &str) -> Result<&'a str> {
    p[k].as_str()
        .filter(|s| !s.is_empty() && s.len() <= 4096)
        .ok_or("screen_playback_invalid_input")
}
fn load(c: &Connection, p: &Value) -> Result<Value> {
    let raw = c
        .query_row(
            "SELECT payload FROM screen_playback_sessions WHERE world=?1 AND screen=?2",
            params![text(p, "worldID")?, text(p, "screenID")?],
            |r| r.get::<_, String>(0),
        )
        .optional()
        .map_err(|_| "storage_unavailable")?;
    raw.map(|s|serde_json::from_str(&s).map_err(|_|"screen_playback_invalid_state")).unwrap_or_else(||Ok(json!({"worldID":p["worldID"],"screenID":p["screenID"],"hostSessionID":"","sessionID":"","generation":0,"status":"empty","pageURL":"","originalURL":"","playlist":null,"playlistID":null,"cacheAction":"none"})))
}
fn save(c: &Connection, p: &Value, s: &Value) -> Result<()> {
    c.execute("INSERT INTO screen_playback_sessions VALUES(?1,?2,?3) ON CONFLICT(world,screen) DO UPDATE SET payload=excluded.payload",params![text(p,"worldID")?,text(p,"screenID")?,crate::canonical_json::to_string(s).map_err(|_|"screen_playback_invalid_state")?]).map_err(|_|"storage_unavailable")?;
    Ok(())
}
fn bump(s: &mut Value) -> Result<()> {
    s["generation"] = json!(s["generation"]
        .as_u64()
        .ok_or("screen_playback_invalid_state")?
        .checked_add(1)
        .filter(|n| *n <= i64::MAX as u64)
        .ok_or("screen_playback_invalid_state")?);
    Ok(())
}
fn fenced(s: &Value, p: &Value) -> Result<()> {
    if s["hostSessionID"] != p["hostSessionID"]
        || s["sessionID"] != p["sessionID"]
        || s["generation"] != p["generation"]
    {
        return Err("screen_playback_stale_session");
    }
    Ok(())
}
fn result(s: Value, duplicate: bool) -> Value {
    let ticket = if ["loading", "playing"].contains(&s["status"].as_str().unwrap_or("")) {
        json!({"worldID":s["worldID"],"screenID":s["screenID"],"hostSessionID":s["hostSessionID"],"sessionID":s["sessionID"],"generation":s["generation"],"pageURL":s["pageURL"],"playlist":s["playlist"]})
    } else {
        Value::Null
    };
    json!({"state":s,"ticket":ticket,"duplicate":duplicate})
}

/// SQLite alone chooses cursor and fences output; downloading never calls this receipt.
pub fn transition(c: &mut Connection, method: &str, p: &Value) -> Result<Value> {
    text(p, "worldID")?;
    text(p, "screenID")?;
    text(p, "hostSessionID")?;
    if method == "screen_playback_read" {
        return Ok(result(load(c, p)?, false));
    }
    let request = text(p, "requestID")?;
    let canonical = crate::canonical_json::to_string(&json!({"method":method,"params":p}))
        .map_err(|_| "screen_playback_invalid_input")?;
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let prior=tx.query_row("SELECT input FROM screen_playback_commands WHERE world=?1 AND screen=?2 AND request=?3",params![text(p,"worldID")?,text(p,"screenID")?,request],|r|r.get::<_,String>(0)).optional().map_err(|_|"storage_unavailable")?;
    let mut s = load(&tx, p)?;
    if let Some(prior) = prior {
        if prior != canonical {
            return Err("screen_playback_receipt_conflict");
        }
        return Ok(result(s, true));
    }
    let mut reused = false;
    match method {
        "screen_playback_begin" => {
            let url = text(p, "pageURL")?;
            let parsed = reqwest::Url::parse(url).map_err(|_| "screen_playback_invalid_input")?;
            if !["https", "file"].contains(&parsed.scheme())
                || parsed.username() != ""
                || parsed.password().is_some()
            {
                return Err("screen_playback_invalid_input");
            }
            let youtube = matches!(
                parsed.host_str(),
                Some(
                    "youtube.com"
                        | "www.youtube.com"
                        | "m.youtube.com"
                        | "music.youtube.com"
                        | "youtu.be"
                )
            );
            let playlist = youtube && parsed.query_pairs().any(|(key, _)| key == "list");
            if playlist {
                crate::media::youtube_playlist_input(p)?;
            }
            if let Some(hint) = p.get("isPlaylist") {
                if hint.as_bool() != Some(playlist) {
                    return Err("screen_playback_invalid_input");
                }
            }
            reused = s["hostSessionID"] == p["hostSessionID"]
                && s["originalURL"] == p["pageURL"]
                && matches!(s["status"].as_str(), Some("loading" | "playing"));
            if reused {
                // Same active authority session: preserve the cursor, native
                // output identity and prefetch ownership. Journal this command
                // below; a native projection cannot grant or veto this result.
            } else {
                if s["status"] == "preparing" || s["status"] == "unknown" {
                    return Err("screen_playback_unresolved_begin");
                }
                let resume = s["status"] == "stopped"
                    && s["originalURL"] == p["pageURL"]
                    && s["playlist"].is_object();
                bump(&mut s)?;
                let mut releases = s["releasePlaylistIDs"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default();
                if !resume && !s["playlistID"].is_null() && !releases.contains(&s["playlistID"]) {
                    releases.push(s["playlistID"].clone());
                }
                s["releasePlaylistIDs"] = json!(releases);
                s["hostSessionID"] = p["hostSessionID"].clone();
                s["sessionID"] = json!(uuid::Uuid::new_v4().to_string());
                s["originalURL"] = json!(url);
                if !resume {
                    s["pageURL"] = json!(url);
                }
                s["beginRequestID"] = json!(request);
                if !resume {
                    s["playlist"] = Value::Null;
                }
                if !resume {
                    s["playlistID"] = if playlist {
                        json!(format!("screen-{}", uuid::Uuid::new_v4()))
                    } else {
                        Value::Null
                    };
                }
                s["status"] = json!(if playlist && !resume {
                    "preparing"
                } else {
                    "loading"
                });
                s["cacheAction"] = json!(if resume {
                    "sync"
                } else if playlist {
                    "import"
                } else {
                    "release"
                });
            }
        }
        "screen_playback_attach" => {
            if s["hostSessionID"] != p["hostSessionID"] {
                bump(&mut s)?;
                s["hostSessionID"] = p["hostSessionID"].clone();
                if ["playing", "loading"].contains(&s["status"].as_str().unwrap_or("")) {
                    s["status"] = json!("stopped");
                }
            }
        }
        "screen_playback_resume" => {
            fenced(&s, p)?;
            if s["status"] != "stopped" {
                return Err("screen_playback_invalid_state");
            }
            bump(&mut s)?;
            s["status"] = json!("loading");
            s["cacheAction"] = json!("sync");
        }
        "screen_playback_stop" => {
            fenced(&s, p)?;
            bump(&mut s)?;
            s["status"] = json!("stopped");
            s["cacheAction"] = json!("release");
        }
        "screen_playback_receipt" => {
            fenced(&s, p)?;
            if text(p, "pageURL")? != text(&s, "pageURL")? {
                return Err("screen_playback_stale_item");
            }
            match text(p, "status")? {
                "playing" => {
                    if s["status"] != "loading" && s["status"] != "playing" {
                        return Err("screen_playback_invalid_state");
                    }
                    s["status"] = json!("playing");
                }
                "failed" => {
                    s["status"] = json!("failed");
                    s["cacheAction"] = json!("release");
                }
                "ended" => {
                    if s["status"] != "playing" {
                        return Err("screen_playback_invalid_state");
                    }
                    if p["isLive"].as_bool() != Some(false) {
                        return Err("screen_playback_invalid_eof");
                    }
                    bump(&mut s)?;
                    let index = s["playlist"]["currentIndex"].as_u64().unwrap_or(0) as usize;
                    if let Some(next) = s["playlist"]["items"].get(index + 1).cloned() {
                        s["playlist"]["currentIndex"] = json!(index + 1);
                        s["playlist"]["revision"] = s["generation"].clone();
                        s["pageURL"] = next["pageURL"].clone();
                        s["status"] = json!("loading");
                        s["cacheAction"] = json!("sync");
                    } else {
                        s["status"] = json!("stopped");
                        s["cacheAction"] = json!("release");
                    }
                }
                _ => return Err("screen_playback_invalid_input"),
            }
        }
        _ => return Err("unknown_method"),
    }
    save(&tx, p, &s)?;
    tx.execute(
        "INSERT INTO screen_playback_commands VALUES(?1,?2,?3,?4)",
        params![
            text(p, "worldID")?,
            text(p, "screenID")?,
            request,
            canonical
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(result(s, reused))
}

pub struct ScreenPlaybackService {
    db: Database,
    media: Arc<Media>,
    active: Arc<Mutex<HashSet<String>>>,
    lane: Mutex<()>,
}
impl ScreenPlaybackService {
    pub fn new(db: Database, media: Arc<Media>) -> Self {
        Self {
            db,
            media,
            active: Arc::new(Mutex::new(HashSet::new())),
            lane: Mutex::new(()),
        }
    }
    pub async fn request(&self, method: &str, p: &Value) -> Result<Value> {
        let lane = self.lane.lock().await;
        let is_begin = method == "screen_playback_begin";
        let method = method.to_owned();
        let input = p.clone();
        let response = self
            .db
            .call(move |store| transition(&mut store.connection, &method, &input))
            .await?;
        let s = &response["state"];
        let importing = is_begin && s["status"] == "preparing" && response["duplicate"] == false;
        if importing {
            self.active
                .lock()
                .await
                .insert(text(s, "playlistID")?.to_owned());
        }
        drop(lane);
        if importing {
            let key = text(s, "playlistID")?.to_owned();
            struct ImportGuard {
                active: Arc<Mutex<HashSet<String>>>,
                key: String,
            }
            impl Drop for ImportGuard {
                fn drop(&mut self) {
                    let active = self.active.clone();
                    let key = self.key.clone();
                    if let Ok(handle) = tokio::runtime::Handle::try_current() {
                        handle.spawn(async move {
                            active.lock().await.remove(&key);
                        });
                    }
                }
            }
            let _guard = ImportGuard {
                active: self.active.clone(),
                key: key.clone(),
            };
            let imported=self.media.request("media_playlist_import",json!({"playlistID":s["playlistID"],"baseRevision":0,"pageURL":s["originalURL"]})).await;
            let expected = s.clone();
            let input = p.clone();
            self.db
                .call(move |store| {
                    let mut current = load(&store.connection, &input)?;
                    if current["sessionID"] != expected["sessionID"]
                        || current["generation"] != expected["generation"]
                        || current["status"] != "preparing"
                    {
                        return Ok(());
                    }
                    match imported {
                        Ok(list) => {
                            current["pageURL"] = list["items"]
                                [list["currentIndex"].as_u64().unwrap_or(0) as usize]["pageURL"]
                                .clone();
                            current["playlist"] = list;
                            current["status"] = json!("loading");
                            current["cacheAction"] = json!("none");
                        }
                        Err(code) => {
                            current["status"] = json!("failed");
                            current["errorCode"] = json!(code);
                            current["cacheAction"] = json!("release");
                        }
                    }
                    save(&store.connection, &input, &current)
                })
                .await?;
            self.active.lock().await.remove(&key);
        }
        self.recover(p).await?;
        let input = p.clone();
        self.db
            .call(move |store| {
                Ok(result(
                    load(&store.connection, &input)?,
                    response["duplicate"].as_bool().unwrap_or(false),
                ))
            })
            .await
    }
    async fn recover(&self, p: &Value) -> Result<()> {
        let _lane = self.lane.lock().await;
        let input = p.clone();
        let mut s = self
            .db
            .call(move |store| load(&store.connection, &input))
            .await?;
        if s["status"] == "preparing"
            && !self
                .active
                .lock()
                .await
                .contains(s["playlistID"].as_str().unwrap_or(""))
        {
            // Import may have committed before taskd died. Read SQLite; never rerun a helper.
            let id = text(&s, "playlistID")?.to_owned();
            let saved=self.db.call(move|store|store.connection.query_row("SELECT revision,current_index,payload FROM video_playlists WHERE id=?1",[id],|r|Ok((r.get::<_,i64>(0)?,r.get::<_,usize>(1)?,r.get::<_,String>(2)?))).optional().map_err(|_|"storage_unavailable")).await?;
            if let Some((revision, index, payload)) = saved {
                let items: Value =
                    serde_json::from_str(&payload).map_err(|_| "screen_playback_invalid_state")?;
                if items.get(index).is_none() {
                    return Err("screen_playback_invalid_state");
                }
                s["pageURL"] = items[index]["pageURL"].clone();
                s["playlist"] = json!({"playlistID":s["playlistID"],"revision":revision,"currentIndex":index,"items":items});
                s["status"] = json!("loading");
                s["cacheAction"] = json!("sync");
            } else {
                s["status"] = json!("unknown");
            }
            let input = p.clone();
            let expected = s.clone();
            self.db
                .call(move |store| {
                    let current = load(&store.connection, &input)?;
                    if current["sessionID"] == expected["sessionID"]
                        && current["generation"] == expected["generation"]
                        && current["status"] == "preparing"
                    {
                        save(&store.connection, &input, &expected)?;
                    }
                    Ok(())
                })
                .await?;
        }
        let mut still_pending = Vec::new();
        for old in s["releasePlaylistIDs"]
            .as_array()
            .cloned()
            .unwrap_or_default()
        {
            let id = old.as_str().ok_or("screen_playback_invalid_state")?;
            if self.active.lock().await.contains(id) {
                still_pending.push(old);
                continue;
            }
            self.media
                .request("media_playlist_release", json!({"playlistID":id}))
                .await?;
        }
        s["releasePlaylistIDs"] = json!(still_pending);
        let input = p.clone();
        let projected = s.clone();
        self.db
            .call(move |store| {
                let mut current = load(&store.connection, &input)?;
                if current["sessionID"] == projected["sessionID"]
                    && current["generation"] == projected["generation"]
                {
                    current["releasePlaylistIDs"] = projected["releasePlaylistIDs"].clone();
                    save(&store.connection, &input, &current)?;
                }
                Ok(())
            })
            .await?;
        match s["cacheAction"].as_str() {
            Some("release") => {
                if let Some(id) = s["playlistID"].as_str() {
                    if self.active.lock().await.contains(id) {
                        return Ok(());
                    }
                    self.media
                        .request("media_playlist_release", json!({"playlistID":id}))
                        .await?;
                }
            }
            Some("sync") => {
                if let Some(id) = s["playlistID"].as_str() {
                    let owned = id.to_owned();
                    let base = self
                        .db
                        .call(move |store| {
                            store
                                .connection
                                .query_row(
                                    "SELECT revision FROM video_playlists WHERE id=?1",
                                    [owned],
                                    |r| r.get::<_, i64>(0),
                                )
                                .optional()
                                .map(|v| v.unwrap_or(0))
                                .map_err(|_| "storage_unavailable")
                        })
                        .await?;
                    self.media.request("media_playlist_commit",json!({"playlistID":id,"baseRevision":base,"currentIndex":s["playlist"]["currentIndex"],"items":s["playlist"]["items"]})).await?;
                }
            }
            _ => return Ok(()),
        }
        let input = p.clone();
        self.db
            .call(move |store| {
                let mut current = load(&store.connection, &input)?;
                if current["sessionID"] == s["sessionID"]
                    && current["generation"] == s["generation"]
                    && current["cacheAction"] == s["cacheAction"]
                {
                    current["cacheAction"] = json!("none");
                    save(&store.connection, &input, &current)?;
                }
                Ok(())
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fresh_repeat_is_authority_reuse_not_native_url_veto() {
        let (mut c, p) = setup();
        let initial = transition(&mut c, "screen_playback_begin", &p).unwrap();
        let mut repeat = p.clone();
        repeat["requestID"] = json!("fresh-repeat");
        let reused = transition(&mut c, "screen_playback_begin", &repeat).unwrap();
        assert_eq!(reused["state"], initial["state"]);
        assert_eq!(reused["ticket"], initial["ticket"]);
        assert_eq!(reused["duplicate"], true);
        let mut playing = initial["state"].clone();
        playing["status"] = json!("playing");
        playing["playlistID"] = json!("actual-owned-list");
        playing["playlist"] =
            json!({"currentIndex":3,"items":[{"pageURL":"https://youtu.be/aaaaaaaaaaa"}]});
        playing["cacheAction"] = json!("sync");
        save(&c, &p, &playing).unwrap();
        repeat["requestID"] = json!("playing-repeat");
        assert_eq!(
            transition(&mut c, "screen_playback_begin", &repeat).unwrap()["state"],
            playing
        );
        // A stale host projection cannot retain another host's native session.
        repeat["requestID"] = json!("new-host");
        repeat["hostSessionID"] = json!("new-host");
        let takeover = transition(&mut c, "screen_playback_begin", &repeat).unwrap();
        assert_eq!(takeover["duplicate"], false);
        assert_ne!(
            takeover["ticket"]["sessionID"],
            initial["ticket"]["sessionID"]
        );
        let mut failed = takeover["state"].clone();
        failed["status"] = json!("failed");
        save(&c, &repeat, &failed).unwrap();
        repeat["requestID"] = json!("reload-after-failure");
        let retry = transition(&mut c, "screen_playback_begin", &repeat).unwrap();
        assert_eq!(retry["duplicate"], false);
        assert_ne!(
            retry["ticket"]["sessionID"],
            takeover["ticket"]["sessionID"]
        );
        let mut unknown = retry["state"].clone();
        unknown["status"] = json!("unknown");
        save(&c, &repeat, &unknown).unwrap();
        repeat["requestID"] = json!("unknown-repeat");
        assert_eq!(
            transition(&mut c, "screen_playback_begin", &repeat).unwrap_err(),
            "screen_playback_unresolved_begin"
        );
    }
    fn setup() -> (Connection, Value) {
        let c = Connection::open_in_memory().unwrap();
        schema(&c).unwrap();
        (
            c,
            json!({"worldID":"w","screenID":"tv","hostSessionID":"host","requestID":"start","pageURL":"https://youtu.be/aaaaaaaaaaa","isPlaylist":false}),
        )
    }
    fn receipt(s: &Value, id: &str, status: &str) -> Value {
        json!({"worldID":s["worldID"],"screenID":s["screenID"],"hostSessionID":s["hostSessionID"],"sessionID":s["sessionID"],"generation":s["generation"],"pageURL":s["pageURL"],"requestID":id,"status":status,"isLive":false})
    }
    #[test]
    fn actual_eof_advances_once_and_rejects_late_receipts() {
        let (mut c, mut p) = setup();
        p["pageURL"] = json!("https://www.youtube.com/playlist?list=PLfixture&index=1");
        p["isPlaylist"] = json!(true);
        let mut s = transition(&mut c, "screen_playback_begin", &p).unwrap()["state"].clone();
        s["status"] = json!("loading");
        s["pageURL"] = json!("https://youtu.be/aaaaaaaaaaa");
        s["playlistID"] = json!("screen-fixture");
        s["playlist"] = json!({"playlistID":"screen-fixture","revision":1,"currentIndex":0,"items":[{"pageURL":"https://youtu.be/aaaaaaaaaaa"},{"pageURL":"https://youtu.be/bbbbbbbbbbb"}]});
        save(&c, &p, &s).unwrap();
        let eof = receipt(&s, "eof", "ended");
        assert_eq!(
            transition(&mut c, "screen_playback_receipt", &eof).unwrap_err(),
            "screen_playback_invalid_state"
        );
        transition(
            &mut c,
            "screen_playback_receipt",
            &receipt(&s, "playing", "playing"),
        )
        .unwrap();
        let advanced = transition(&mut c, "screen_playback_receipt", &eof).unwrap();
        assert_eq!(advanced["state"]["playlist"]["currentIndex"], 1);
        assert_eq!(
            transition(&mut c, "screen_playback_receipt", &eof).unwrap()["duplicate"],
            true
        );
        let mut late = eof.clone();
        late["requestID"] = json!("late");
        assert_eq!(
            transition(&mut c, "screen_playback_receipt", &late).unwrap_err(),
            "screen_playback_stale_session"
        );
        let mut conflict = eof;
        conflict["status"] = json!("failed");
        assert_eq!(
            transition(&mut c, "screen_playback_receipt", &conflict).unwrap_err(),
            "screen_playback_receipt_conflict"
        );
    }
    #[test]
    fn stop_attach_fences_old_output_and_explicit_resume_keeps_cursor() {
        let (mut c, p) = setup();
        let s = transition(&mut c, "screen_playback_begin", &p).unwrap()["state"].clone();
        let stop = receipt(&s, "stop", "stopped");
        let stopped = transition(&mut c, "screen_playback_stop", &stop).unwrap()["state"].clone();
        assert_eq!(stopped["status"], "stopped");
        let mut attach = p.clone();
        attach["hostSessionID"] = json!("new");
        attach["requestID"] = json!("attach");
        let bound = transition(&mut c, "screen_playback_attach", &attach).unwrap()["state"].clone();
        assert_eq!(
            transition(
                &mut c,
                "screen_playback_receipt",
                &receipt(&s, "late", "playing")
            )
            .unwrap_err(),
            "screen_playback_stale_session"
        );
        let resumed = transition(
            &mut c,
            "screen_playback_resume",
            &receipt(&bound, "resume", "ignored"),
        )
        .unwrap();
        assert_eq!(resumed["state"]["pageURL"], p["pageURL"]);
        assert!(resumed["ticket"].is_object());
    }
    #[test]
    fn stable_begin_is_persisted_before_import_and_unknown_does_not_replay() {
        let (mut c, mut p) = setup();
        p["isPlaylist"] = json!(true);
        p["pageURL"] = json!("https://www.youtube.com/playlist?list=PLfixture&index=2");
        let first = transition(&mut c, "screen_playback_begin", &p).unwrap();
        assert_eq!(first["state"]["status"], "preparing");
        assert_eq!(
            transition(&mut c, "screen_playback_begin", &p).unwrap()["state"]["playlistID"],
            first["state"]["playlistID"]
        );
        let mut changed = p.clone();
        changed["requestID"] = json!("other");
        assert_eq!(
            transition(&mut c, "screen_playback_begin", &changed).unwrap_err(),
            "screen_playback_unresolved_begin"
        );
        let mut uncertain = first["state"].clone();
        uncertain["status"] = json!("unknown");
        save(&c, &p, &uncertain).unwrap();
        assert_eq!(
            transition(&mut c, "screen_playback_begin", &changed).unwrap_err(),
            "screen_playback_unresolved_begin"
        );
    }

    #[test]
    fn persisted_eof_survives_reopen_without_second_advance() {
        let path = std::env::temp_dir().join(format!(
            "gmgn-screen-playback-{}.sqlite",
            uuid::Uuid::new_v4()
        ));
        let mut c = Connection::open(&path).unwrap();
        schema(&c).unwrap();
        let p = json!({"worldID":"w","screenID":"tv","hostSessionID":"h","requestID":"begin","pageURL":"https://www.youtube.com/playlist?list=PLfixture&index=1","isPlaylist":true});
        let mut state = transition(&mut c, "screen_playback_begin", &p).unwrap()["state"].clone();
        state["status"] = json!("loading");
        state["pageURL"] = json!("https://youtu.be/aaaaaaaaaaa");
        state["playlistID"] = json!("screen-private");
        state["playlist"] = json!({"playlistID":"screen-private","revision":1,"currentIndex":0,"items":[{"pageURL":"https://youtu.be/aaaaaaaaaaa"},{"pageURL":"https://youtu.be/bbbbbbbbbbb"}]});
        save(&c, &p, &state).unwrap();
        transition(
            &mut c,
            "screen_playback_receipt",
            &receipt(&state, "playing", "playing"),
        )
        .unwrap();
        let eof = receipt(&state, "eof", "ended");
        let before = transition(&mut c, "screen_playback_receipt", &eof).unwrap();
        drop(c);
        let mut reopened = Connection::open(&path).unwrap();
        let duplicate = transition(&mut reopened, "screen_playback_receipt", &eof).unwrap();
        assert_eq!(duplicate["state"], before["state"]);
        assert_eq!(duplicate["duplicate"], true);
        assert_eq!(duplicate["state"]["cacheAction"], "sync");
        let stopped = transition(
            &mut reopened,
            "screen_playback_stop",
            &receipt(&duplicate["state"], "stop", "ignored"),
        )
        .unwrap()["state"]
            .clone();
        let mut resume = p.clone();
        resume["requestID"] = json!("resume-by-play");
        resume["isPlaylist"] = json!(true);
        resume["pageURL"] = stopped["originalURL"].clone();
        let resumed = transition(&mut reopened, "screen_playback_begin", &resume).unwrap();
        assert_eq!(resumed["state"]["playlist"]["currentIndex"], 1);
        assert_eq!(resumed["state"]["pageURL"], stopped["pageURL"]);
        assert_eq!(resumed["state"]["cacheAction"], "sync");
        assert_eq!(resumed["state"]["playlistID"], stopped["playlistID"]);
    }

    #[test]
    fn rust_classifies_valid_playlist_urls_without_host_hint() {
        for url in [
            "https://www.youtube.com/playlist?list=PLfixture&index=2",
            "https://www.youtube.com/watch?v=bbbbbbbbbbb&list=PLfixture&index=2",
            "https://www.youtube.com/watch?v=bbbbbbbbbbb&list=RDMix&index=2",
        ] {
            let (mut c, mut p) = setup();
            p["pageURL"] = json!(url);
            p.as_object_mut().unwrap().remove("isPlaylist");
            let state = transition(&mut c, "screen_playback_begin", &p).unwrap()["state"].clone();
            assert_eq!(state["status"], "preparing");
            assert!(state["playlistID"].as_str().unwrap().starts_with("screen-"));
            let (_, video, index, limit) = crate::media::youtube_playlist_input(&p).unwrap();
            assert_eq!(index, 1);
            assert_eq!(video.is_some(), url.contains("watch"));
            assert_eq!(limit, if url.contains("RDMix") { 50 } else { 200 });
        }
        for url in [
            "https://www.youtube.com/playlist?list=",
            "https://www.youtube.com/playlist?list=PLfixture&index=0",
            "https://www.youtube.com/watch?v=bad&list=PLfixture",
            "https://www.youtube.com/other?list=PLfixture",
        ] {
            let (mut c, mut p) = setup();
            p["pageURL"] = json!(url);
            p.as_object_mut().unwrap().remove("isPlaylist");
            assert!(transition(&mut c, "screen_playback_begin", &p).is_err());
        }
        let (mut c, mut p) = setup();
        p["isPlaylist"] = json!(true);
        assert_eq!(
            transition(&mut c, "screen_playback_begin", &p).unwrap_err(),
            "screen_playback_invalid_input"
        );
    }
}
