//! Music-account decisions. Credentials never enter SQL, command receipts or UI projections.
use crate::{
    files,
    model::{digest, Result},
};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const SECRET_LIMIT: usize = 64 * 1024;
pub fn schema(c: &Connection) -> Result<()> {
    c.execute_batch("CREATE TABLE IF NOT EXISTS music_accounts(provider TEXT PRIMARY KEY,revision INTEGER NOT NULL,state TEXT NOT NULL,overridden INTEGER NOT NULL,tombstone INTEGER NOT NULL,secret_id TEXT,secret_sha TEXT);
CREATE TABLE IF NOT EXISTS music_account_attempts(id TEXT PRIMARY KEY,provider TEXT NOT NULL,host TEXT NOT NULL,request TEXT NOT NULL,input_sha TEXT NOT NULL,base_revision INTEGER NOT NULL,state TEXT NOT NULL,receipt TEXT,UNIQUE(host,request));
CREATE TABLE IF NOT EXISTS music_account_commands(host TEXT NOT NULL,request TEXT NOT NULL,input_sha TEXT NOT NULL,receipt TEXT NOT NULL,PRIMARY KEY(host,request));").map_err(|_| "storage_unavailable")
}
pub fn recover(c: &Connection) -> Result<()> {
    c.execute(
        "UPDATE music_account_attempts SET state='unknown' WHERE state='validating'",
        [],
    )
    .map_err(|_| "storage_unavailable")?;
    Ok(())
}
fn text<'a>(v: &'a Value, key: &str) -> Result<&'a str> {
    v[key]
        .as_str()
        .filter(|s| !s.is_empty() && s.len() <= 128)
        .ok_or("music_account_invalid_input")
}
fn provider(p: &str) -> Result<()> {
    if matches!(p, "netease" | "qq-music" | "apple-music") {
        Ok(())
    } else {
        Err("music_account_unsupported_provider")
    }
}
fn cookies(cookie: &str) -> std::collections::BTreeMap<&str, &str> {
    cookie
        .split(';')
        .filter_map(|item| item.trim().split_once('='))
        .map(|(k, v)| (k.trim(), v.trim()))
        .collect()
}
fn normalized_cookie(p: &str, input: &str) -> Result<String> {
    provider(p)?;
    let cookie = input.trim();
    if cookie.len() > SECRET_LIMIT || cookie.contains(['\r', '\n', '\0']) {
        return Err("music_account_invalid_cookie");
    }
    let values = cookies(cookie);
    let nonempty = |keys: &[&str]| {
        keys.iter()
            .any(|k| values.get(k).is_some_and(|v| !v.is_empty()))
    };
    let valid = match p {
        "netease" => nonempty(&["MUSIC_U"]),
        "qq-music" => {
            nonempty(&["uin", "qqmusic_uin", "wxuin", "p_uin"])
                && nonempty(&["qm_keyst", "qqmusic_key", "music_key", "wxskey"])
        }
        _ => return Err("music_account_unsupported_provider"),
    };
    if !valid {
        return Err("music_account_missing_required_cookie");
    }
    Ok(cookie.to_owned())
}
fn secret_dir(root: &Path) -> Result<PathBuf> {
    let dir = root.join("secrets/music-account-v1");
    files::directory(&dir)?;
    Ok(dir)
}
fn secret_path(root: &Path, id: &str) -> Result<PathBuf> {
    uuid::Uuid::parse_str(id).map_err(|_| "music_account_invalid_secret_identity")?;
    Ok(secret_dir(root)?.join(format!("{id}.json")))
}
fn encoded(v: &Value) -> Result<String> {
    crate::canonical_json::to_string(v).map_err(|_| "music_account_invalid_input")
}
fn cleanup_unused(c: &Connection, root: &Path, p: &str) -> Result<()> {
    let mut statement=c.prepare("SELECT id FROM music_account_attempts WHERE provider=?1 AND state IN ('rejected','failed','unknown','superseded') AND id NOT IN (SELECT secret_id FROM music_accounts WHERE secret_id IS NOT NULL)").map_err(|_|"storage_unavailable")?;
    let rows=statement.query_map([p],|r|r.get::<_,String>(0)).map_err(|_|"storage_unavailable")?;
    for id in rows {
        let path=secret_path(root,&id.map_err(|_|"storage_unavailable")?)?;
        match std::fs::remove_file(path) { Ok(())=>{},Err(e) if e.kind()==std::io::ErrorKind::NotFound=>{},Err(_)=>return Err("storage_unavailable") }
    }
    Ok(())
}
fn snapshot(c: &Connection, p: &str) -> Result<Value> {
    provider(p)?;
    c.query_row("SELECT revision,state,overridden,tombstone FROM music_accounts WHERE provider=?1", [p], |r| {
        Ok(json!({"providerID":p,"revision":r.get::<_,i64>(0)?,"state":r.get::<_,String>(1)?,"overridden":r.get::<_,bool>(2)?,"disabled":r.get::<_,bool>(3)?}))
    }).optional().map_err(|_| "storage_unavailable").map(|v| v.unwrap_or(json!({"providerID":p,"revision":0,"state":"disconnected","overridden":false,"disabled":false})))
}
fn valid_response(p: &str, responses: &Value) -> Result<bool> {
    if encoded(responses)?.len() > 2 * 1024 * 1024 {
        return Err("music_account_response_capacity");
    }
    let list = responses
        .as_array()
        .filter(|v| v.len() <= 2)
        .ok_or("music_account_invalid_response")?;
    for response in list {
        if !matches!(response["httpStatus"].as_u64(), Some(200..=299)) {
            continue;
        }
        let body = &response["body"];
        if encoded(body)?.len() > 1024 * 1024 {
            return Err("music_account_response_capacity");
        }
        match (p, response["transport"].as_str()) {
            ("netease", Some("netease-weapi" | "netease-legacy")) => {
                let id = body["profile"]["userId"]
                    .as_i64()
                    .or_else(|| body["data"]["profile"]["userId"].as_i64());
                if id.is_some_and(|n| n > 0) {
                    return Ok(true);
                }
            }
            ("qq-music", Some("qq-library")) => {
                // Same original account validation endpoint, without unrelated playlist-detail fetches.
                if body["code"].as_i64().unwrap_or(0) == 0
                    && body["data"].is_object()
                    && (body["data"]["disslist"].is_array() || body["data"]["disslist"].is_null())
                {
                    return Ok(true);
                }
            }
            _ => return Err("music_account_response_identity"),
        }
    }
    Ok(false)
}
fn validation_plan(p: &str, cookie: &str) -> Value {
    if p == "netease" {
        json!({"providerID":p,"probes":[{"transport":"netease-weapi"},{"transport":"netease-legacy"}]})
    } else {
        let values = cookies(cookie);
        let uin = ["uin", "qqmusic_uin", "wxuin", "p_uin"]
            .iter()
            .find_map(|k| values.get(k))
            .copied()
            .unwrap_or("")
            .trim_start_matches('o');
        json!({"providerID":p,"probes":[{"transport":"qq-library","uin":uin}]})
    }
}

/// The one guard every music-account entry point passes: a known provider and no
/// orphan private credential left behind by a previous attempt.
fn enter(c: &Connection, root: &Path, p: &str) -> Result<()> {
    provider(p)?;
    cleanup_unused(c, root, p)
}
pub fn request(c: &mut Connection, root: &Path, method: &str, v: &Value) -> Result<Value> {
    let p = text(v, "providerID")?;
    enter(c, root, p)?;
    match method {
        "music_account_import" => {
            // One-time observation of the original private files. No overwrite after Rust owns the provider.
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            let current = snapshot(&tx, p)?;
            if current["revision"].as_i64().unwrap_or(0) > 0 {
                return Ok(current);
            }
            let disabled = v["disabled"]
                .as_bool()
                .ok_or("music_account_invalid_input")?;
            let mut secret_id = None;
            let mut secret_sha = None;
            let state = if disabled {
                "disconnected"
            } else if !v["session"].is_null() {
                let raw = &v["session"];
                let cookie = raw["credential"]["cookieHeader"]["_0"]
                    .as_str()
                    .ok_or("music_account_invalid_stored_session")?;
                normalized_cookie(p, cookie)?;
                if !(raw["expiresAt"].is_null() || raw["expiresAt"].is_number()) {
                    return Err("music_account_invalid_stored_session");
                }
                let bytes = encoded(raw)?.into_bytes();
                if bytes.len() > SECRET_LIMIT {
                    return Err("music_account_capacity");
                }
                let id = uuid::Uuid::new_v4().to_string();
                files::publish(&secret_path(root, &id)?, &bytes)?;
                secret_sha = Some(digest(&bytes));
                secret_id = Some(id);
                "connected"
            } else {
                "disconnected"
            };
            tx.execute(
                "INSERT INTO music_accounts VALUES(?1,1,?2,1,?3,?4,?5)",
                params![p, state, disabled, secret_id, secret_sha],
            )
            .map_err(|_| "storage_unavailable")?;
            let reply = snapshot(&tx, p)?;
            tx.commit().map_err(|_| "storage_unavailable")?;
            Ok(reply)
        }
        "music_account_session" => {
            let view = snapshot(c, p)?;
            if !view["overridden"].as_bool().unwrap_or(false) {
                return Ok(json!({"account":view,"session":null,"useLegacy":true}));
            }
            if view["disabled"] == true {
                return Ok(json!({"account":view,"session":null,"useLegacy":false}));
            }
            let secret: Option<(String,String)>=c.query_row("SELECT secret_id,secret_sha FROM music_accounts WHERE provider=?1 AND secret_id IS NOT NULL",[p],|r| Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
            let Some((id, sha)) = secret else {
                return Ok(json!({"account":view,"session":null,"useLegacy":false}));
            };
            let bytes = files::read(&secret_path(root, &id)?, SECRET_LIMIT)?;
            if digest(&bytes) != sha {
                return Err("music_account_invalid_stored_session");
            }
            let session: Value = serde_json::from_slice(&bytes)
                .map_err(|_| "music_account_invalid_stored_session")?;
            Ok(json!({"account":view,"session":session,"useLegacy":false}))
        }
        "music_account_disconnect" | "music_account_apple_authorization" => {
            let host = text(v, "hostSessionID")?;
            let request_id = text(v, "requestID")?;
            let input_sha = digest(encoded(&json!({"method":method,"input":v}))?.as_bytes());
            let tx = c.transaction().map_err(|_| "storage_unavailable")?;
            let prior:Option<(String,String)>=tx.query_row("SELECT input_sha,receipt FROM music_account_commands WHERE host=?1 AND request=?2",params![host,request_id],|r|Ok((r.get(0)?,r.get(1)?))).optional().map_err(|_|"storage_unavailable")?;
            if let Some((sha, receipt)) = prior {
                if sha != input_sha {
                    return Err("music_account_request_conflict");
                }
                return serde_json::from_str(&receipt).map_err(|_| "storage_unavailable");
            }
            let view = snapshot(&tx, p)?;
            let expected = v["expectedRevision"]
                .as_i64()
                .ok_or("music_account_invalid_input")?;
            if expected != view["revision"].as_i64().unwrap_or(0) {
                return Err("music_account_revision_conflict");
            }
            let state = if method == "music_account_disconnect" {
                "disconnected"
            } else {
                if p != "apple-music" {
                    return Err("music_account_unsupported_provider");
                }
                if view["disabled"] == true && v["reconnect"] != true {
                    "disconnected"
                } else {
                    match v["authorization"].as_str() {
                        Some("authorized") => {
                            if v["hasPlayableSubscription"] == true {
                                "connected"
                            } else {
                                "unavailable"
                            }
                        }
                        Some("denied" | "restricted") => "denied",
                        Some("notDetermined") => "disconnected",
                        _ => return Err("music_account_invalid_authorization"),
                    }
                }
            };
            let disabled = method == "music_account_disconnect"
                || (view["disabled"] == true && v["reconnect"] != true);
            tx.execute("INSERT INTO music_accounts VALUES(?1,?2,?3,1,?4,NULL,NULL) ON CONFLICT(provider) DO UPDATE SET revision=excluded.revision,state=excluded.state,overridden=1,tombstone=excluded.tombstone,secret_id=NULL,secret_sha=NULL",params![p,expected+1,state,disabled]).map_err(|_|"storage_unavailable")?;
            tx.execute("UPDATE music_account_attempts SET state='superseded' WHERE provider=?1 AND state IN ('validating','unknown')",[p]).map_err(|_|"storage_unavailable")?;
            let reply = snapshot(&tx, p)?;
            tx.execute(
                "INSERT INTO music_account_commands VALUES(?1,?2,?3,?4)",
                params![host, request_id, input_sha, encoded(&reply)?],
            )
            .map_err(|_| "storage_unavailable")?;
            tx.commit().map_err(|_| "storage_unavailable")?;
            Ok(reply)
        }
        "music_account_session_state" => {
            // Expiry is a decision over the actual private session, never a host candidate state.
            let session = request(c, root, "music_account_session", v)?;
            let state = if session["session"].is_null() {
                session["account"]["state"]
                    .as_str()
                    .unwrap_or("disconnected")
            } else {
                let expires = session["session"]["expiresAt"].as_f64();
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map_err(|_| "music_account_invalid_clock")?
                    .as_secs_f64();
                if expires.is_some_and(|date| date + 978307200.0 <= now) {
                    "expired"
                } else {
                    "connected"
                }
            };
            let mut reply = session["account"].clone();
            reply["state"] = json!(state);
            Ok(reply)
        }
        _ => Err("method_not_found"),
    }
}

/// The storage half of `music_account_connect`. It is an internal step, never an
/// RPC method: the provider round-trip stays inside Rust, so a caller cannot
/// attest its own validation result.
fn begin_attempt(c: &mut Connection, root: &Path, p: &str, v: &Value) -> Result<Value> {
    enter(c, root, p)?;
    let host = text(v, "hostSessionID")?;
    let request = text(v, "requestID")?;
    let cookie = normalized_cookie(
        p,
        v["cookie"].as_str().ok_or("music_account_invalid_cookie")?,
    )?;
    let input_sha = digest(encoded(&json!({"providerID":p,"cookie":cookie}))?.as_bytes());
    let old: Option<(String,String,String)>=c.query_row("SELECT id,input_sha,state FROM music_account_attempts WHERE host=?1 AND request=?2",params![host,request],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional().map_err(|_|"storage_unavailable")?;
    if let Some((id, sha, state)) = old {
        if sha != input_sha {
            return Err("music_account_request_conflict");
        }
        if matches!(state.as_str(), "connected" | "rejected") {
            let receipt: String = c
                .query_row(
                    "SELECT receipt FROM music_account_attempts WHERE id=?1",
                    [&id],
                    |r| r.get(0),
                )
                .map_err(|_| "storage_unavailable")?;
            let receipt: Value =
                serde_json::from_str(&receipt).map_err(|_| "storage_unavailable")?;
            return Ok(json!({"attemptID":id,"receipt":receipt}));
        }
        if state != "validating" {
            return Err("music_account_attempt_not_replayable");
        }
        return Ok(json!({"attemptID":id,"plan":validation_plan(p,&cookie)}));
    }
    let id = uuid::Uuid::new_v4().to_string();
    let secret = json!({"credential":{"cookieHeader":{"_0":cookie}}});
    files::publish(&secret_path(root, &id)?, encoded(&secret)?.as_bytes())?;
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let view = snapshot(&tx, p)?;
    tx.execute(
        "INSERT INTO music_account_attempts VALUES(?1,?2,?3,?4,?5,?6,'validating',NULL)",
        params![
            id,
            p,
            host,
            request,
            input_sha,
            view["revision"].as_i64().unwrap_or(0)
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(json!({"attemptID":id,"plan":validation_plan(p,&cookie)}))
}

/// The storage half of `music_account_connect`. It is an internal step, never an
/// RPC method: the provider round-trip stays inside Rust, so a caller cannot
/// attest its own validation result.
fn finish_attempt(c: &mut Connection, root: &Path, p: &str, v: &Value) -> Result<Value> {
    enter(c, root, p)?;
    let id = text(v, "attemptID")?;
    let host = text(v, "hostSessionID")?;
    let request = text(v, "requestID")?;
    let tx = c.transaction().map_err(|_| "storage_unavailable")?;
    let old:(String,String,String,i64,String,Option<String>)=tx.query_row("SELECT provider,host,request,base_revision,state,receipt FROM music_account_attempts WHERE id=?1",[id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?))).map_err(|_|"music_account_unknown_attempt")?;
    if old.0 != p || old.1 != host || old.2 != request {
        return Err("music_account_attempt_identity");
    }
    let proof_sha = digest(encoded(&v["responses"])?.as_bytes());
    if old.4 == "connected" || old.4 == "rejected" {
        let receipt: Value =
            serde_json::from_str(old.5.as_deref().ok_or("storage_unavailable")?)
                .map_err(|_| "storage_unavailable")?;
        if receipt["proofSHA"] != proof_sha {
            return Err("music_account_receipt_conflict");
        }
        return Ok(receipt);
    }
    if old.4 != "validating" {
        return Err("music_account_attempt_not_replayable");
    }
    let current = snapshot(&tx, p)?;
    if current["revision"].as_i64() != Some(old.3) {
        return Err("music_account_revision_conflict");
    }
    let valid = valid_response(p, &v["responses"])?;
    let receipt = if valid {
        let bytes = files::read(&secret_path(root, id)?, SECRET_LIMIT)?;
        tx.execute("INSERT INTO music_accounts VALUES(?1,?2,'connected',1,0,?3,?4) ON CONFLICT(provider) DO UPDATE SET revision=excluded.revision,state=excluded.state,overridden=1,tombstone=0,secret_id=excluded.secret_id,secret_sha=excluded.secret_sha",params![p,old.3+1,id,digest(&bytes)]).map_err(|_|"storage_unavailable")?;
        json!({"account":snapshot(&tx,p)?,"proofSHA":proof_sha,"accepted":true})
    } else {
        json!({"account":current,"proofSHA":proof_sha,"accepted":false,"code":"music_account_account_cannot_play"})
    };
    tx.execute(
        "UPDATE music_account_attempts SET state=?2,receipt=?3 WHERE id=?1",
        params![
            id,
            if valid { "connected" } else { "rejected" },
            encoded(&receipt)?
        ],
    )
    .map_err(|_| "storage_unavailable")?;
    tx.commit().map_err(|_| "storage_unavailable")?;
    Ok(receipt)
}

/// All account HTTP and credential publishing remain inside Rust. Swift supplies only a browser cookie.
pub async fn connect(db: &crate::store::Database, input: Value) -> Result<Value> {
    let p = text(&input, "providerID")?.to_owned();
    let cookie = normalized_cookie(
        &p,
        input["cookie"]
            .as_str()
            .ok_or("music_account_invalid_cookie")?,
    )?;
    let initial = input.clone();
    let root = db.root.clone();
    let begin_provider = p.clone();
    let begin = db
        .call(move |s| begin_attempt(&mut s.connection, &root, &begin_provider, &initial))
        .await?;
    if let Some(receipt) = begin.get("receipt") {
        return Ok(receipt.clone());
    }
    let responses = match crate::music_account_http::validate(&p, &cookie).await {
        Ok(value) => value,
        Err(code) => {
            let id = text(&begin, "attemptID")?.to_owned();
            let host = text(&input, "hostSessionID")?.to_owned();
            let request_id = text(&input, "requestID")?.to_owned();
            db.call(move |s| {
                s.connection.execute("UPDATE music_account_attempts SET state='failed' WHERE id=?1 AND host=?2 AND request=?3 AND state='validating'",params![id,host,request_id]).map_err(|_|"storage_unavailable")?;
                Ok(())
            }).await?;
            return Err(code);
        }
    };
    let finish_provider = p.clone();
    let finish = json!({"providerID":p,"hostSessionID":input["hostSessionID"],"requestID":input["requestID"],"attemptID":begin["attemptID"],"responses":responses});
    let root = db.root.clone();
    db.call(move |s| finish_attempt(&mut s.connection, &root, &finish_provider, &finish))
        .await
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Fixture {
        c: Connection,
        root: PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let c = Connection::open_in_memory().unwrap();
            schema(&c).unwrap();
            Self {
                c,
                root: std::env::temp_dir()
                    .canonicalize()
                    .unwrap()
                    .join(format!("gmgn-music-account-{}", uuid::Uuid::new_v4())),
            }
        }
        fn call(&mut self, m: &str, v: Value) -> Result<Value> {
            request(&mut self.c, &self.root, m, &v)
        }
        /// The two storage steps `connect` drives. They exercise the same code the
        /// daemon runs, without pretending to be RPC methods.
        fn begin(&mut self, v: Value) -> Result<Value> {
            let p = text(&v, "providerID")?.to_owned();
            begin_attempt(&mut self.c, &self.root, &p, &v)
        }
        fn finish(&mut self, v: Value) -> Result<Value> {
            let p = text(&v, "providerID")?.to_owned();
            finish_attempt(&mut self.c, &self.root, &p, &v)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
    #[test]
    fn cookie_shape_is_real_values_not_substring() {
        assert!(normalized_cookie("netease", "fakeMUSIC_U=abc").is_err());
        assert!(normalized_cookie("netease", "MUSIC_U=").is_err());
        assert!(normalized_cookie("qq-music", "wxuin=42; wxskey=secret").is_ok());
        assert!(normalized_cookie("qq-music", "uin=1; qm_keyst=key\r\nInjected=1").is_err());
    }
    #[test]
    fn accepted_proof_and_disconnect_tombstone_are_sql_authority() {
        let mut f = Fixture::new();
        let begin=f.begin(json!({"providerID":"netease","hostSessionID":"host","requestID":"r","cookie":"MUSIC_U=private-test"})).unwrap();
        let finish = json!({"providerID":"netease","hostSessionID":"host","requestID":"r","attemptID":begin["attemptID"],"responses":[{"transport":"netease-legacy","httpStatus":200,"body":{"profile":{"userId":42}}}]});
        let done = f.finish(finish.clone()).unwrap();
        assert_eq!(done["account"]["state"], "connected");
        assert_eq!(f.finish(finish).unwrap(), done);
        let dump: String =
            f.c.query_row("SELECT input_sha FROM music_account_attempts", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert!(!dump.contains("private-test"));
        let disconnected = f
            .call(
                "music_account_disconnect",
                json!({"providerID":"netease","hostSessionID":"host","requestID":"disconnect","expectedRevision":1}),
            )
            .unwrap();
        assert_eq!(disconnected["disabled"], true);
        assert_eq!(
            f.call("music_account_session", json!({"providerID":"netease"}))
                .unwrap()["session"],
            Value::Null
        );
    }
    #[test]
    fn stale_attempt_and_restart_unknown_never_reconnect() {
        let mut f = Fixture::new();
        let b=f.begin(json!({"providerID":"netease","hostSessionID":"h","requestID":"r","cookie":"MUSIC_U=secret"})).unwrap();
        recover(&f.c).unwrap();
        let finish = json!({"providerID":"netease","hostSessionID":"h","requestID":"r","attemptID":b["attemptID"],"responses":[{"transport":"netease-legacy","httpStatus":200,"body":{"profile":{"userId":1}}}]});
        assert_eq!(
            f.finish(finish),
            Err("music_account_attempt_not_replayable")
        );
        assert_eq!(f.begin(json!({"providerID":"netease","hostSessionID":"h","requestID":"r","cookie":"MUSIC_U=changed"})),Err("music_account_request_conflict"));
    }
    #[test]
    fn denied_and_wrong_provider_responses_do_not_persist_connection() {
        let mut f = Fixture::new();
        let b=f.begin(json!({"providerID":"netease","hostSessionID":"h","requestID":"r","cookie":"MUSIC_U=secret"})).unwrap();
        let mut proof = json!({"providerID":"netease","hostSessionID":"h","requestID":"r","attemptID":b["attemptID"],"responses":[{"transport":"qq-library","httpStatus":200,"body":{"data":{}}}]});
        assert_eq!(
            f.finish(proof.clone()),
            Err("music_account_response_identity")
        );
        proof["responses"] = json!([{"transport":"netease-legacy","httpStatus":403,"body":{"profile":{"userId":1}}}]);
        assert_eq!(
            f.finish(proof).unwrap()["accepted"],
            false
        );
        assert_eq!(
            f.call("music_account_session_state", json!({"providerID":"netease"}))
                .unwrap()["revision"],
            0
        );
    }
    /// `request` accepts exactly the method names `daemon.rs` routes, no more and
    /// no less: the account view is `music_account_session_state`, and the two
    /// storage steps `connect` drives are functions, not wire methods.
    #[test]
    fn request_accepts_exactly_the_routed_method_names() {
        let mut f = Fixture::new();
        for method in [
            "music_account_read",
            "music_account_begin",
            "music_account_finish",
        ] {
            assert_eq!(
                f.call(method, json!({"providerID":"netease"})),
                Err("method_not_found"),
                "{method} 不该是一个可调用的方法名"
            );
        }
        for method in [
            "music_account_session_state",
            "music_account_session",
            "music_account_import",
            "music_account_disconnect",
            "music_account_apple_authorization",
        ] {
            assert_ne!(
                f.call(method, json!({"providerID":"netease"})),
                Err("method_not_found"),
                "{method} 必须是 request 接受的方法"
            );
        }
    }
}
